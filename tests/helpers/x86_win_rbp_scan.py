#!/usr/bin/env python3
"""x86_win_rbp_scan.py <listing> -- #143 row ir_x86_win_no_rbp_colour.

Option C (#143, spec 2.5.2 / 2.5.5): on Windows an x86_64 IR function that
moves RSP after its prologue establishes rbp as its frame pointer and never
hands rbp to a value; an SP-fixed one has no frame pointer and may use rbp as
an ordinary callee-saved colour (ruling Q12). This scan checks that on a
`--target=windows --emit=asm` listing, using only its labels and byte column
(the listing's own mnemonics are not trusted): each function's bytes are
disassembled with objdump, its prologue is `push` r64..., an optional
`sub rsp, imm`, and then

  * SP-moving shape: the pushes end with `push rbp` and `mov rbp, rsp` follows;
    after that nothing writes rbp/ebp/bp/bpl until the function's epilogue
    (the first `pop rbp` that is followed only by pops and `ret`);
  * SP-fixed shape: no `mov rbp, rsp`; the body may write rbp only if the
    prologue pushed it (and then the epilogue pops it); without a `push rbp`
    nothing writes rbp at all.

The summary counts both shapes; --want-sp-fixed=NAME[,NAME] and
--want-sp-moving=NAME[,NAME] additionally require those functions to have
that shape, and --want-rbp-colour=NAME requires NAME to be SP-fixed and to
write rbp in its body (rbp allocated as a colour).

The byte column must be gap-free (every line starts where the previous one
ended); a gap is reported, because it means the printer dropped bytes. A
function's bytes run to the next label; the last function's to the end of its
epilogue (strings and statics follow it in the listing). Prints one line per
offending function and a summary; exit 0 when every function conforms.
"""
import re
import subprocess
import sys
import tempfile

LINE = re.compile(r'^\s+([0-9a-f]{8}): ((?:[0-9a-f]{2}(?: |$))+)')
LABEL = re.compile(r'^([A-Za-z_.$][\w.$@]*):\s*$')
RBP = {'rbp', 'ebp', 'bp', 'bpl'}
RO = {'cmp', 'test', 'push', 'bt', 'call', 'jmp'}


def disasm(code, base):
    with tempfile.NamedTemporaryFile(suffix='.bin') as f:
        f.write(code)
        f.flush()
        out = subprocess.run(['objdump', '-D', '-b', 'binary', '-m', 'i386:x86-64', '-M', 'intel',
                              '--adjust-vma=0x%x' % base, f.name],
                             capture_output=True, text=True, check=True).stdout
    insns = []
    for line in out.split('\n'):
        m = re.match(r'^\s*([0-9a-f]+):\t((?:[0-9a-f]{2} )+)\s*\t?(.*)$', line)
        if m:
            insns.append((int(m.group(1), 16), m.group(3).split('#')[0].strip()))
    return insns


def mn_ops(t):
    p = t.split(None, 1)
    mn = p[0] if p else ''
    ops = [o.strip() for o in p[1].split(',')] if len(p) > 1 else []
    return mn, ops


def writes_rbp(t):
    mn, ops = mn_ops(t)
    if mn in ('leave', 'enter'):
        return True
    if mn in ('xchg', 'xadd', 'cmpxchg') and any(o in RBP for o in ops):
        return True
    return bool(ops) and ops[0] in RBP and mn not in RO


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    opts = dict(a[2:].split('=', 1) for a in sys.argv[1:] if a.startswith('--') and '=' in a)
    want_fixed = set(x for x in opts.get('want-sp-fixed', '').split(',') if x)
    want_moving = set(x for x in opts.get('want-sp-moving', '').split(',') if x)
    want_colour = set(x for x in opts.get('want-rbp-colour', '').split(',') if x)
    code = bytearray()
    labels = []
    gaps = []
    for n, line in enumerate(open(args[0], encoding='latin-1'), 1):
        line = line.rstrip('\n')
        m = LINE.match(line)
        if m:
            if int(m.group(1), 16) != len(code):
                gaps.append('listing line %d: offset 0x%s, expected 0x%x (the printer dropped bytes)'
                            % (n, m.group(1), len(code)))
            code += bytes(int(x, 16) for x in m.group(2).split())
            continue
        m = LABEL.match(line)
        if m:
            labels.append((len(code), m.group(1)))
    if gaps:
        for g in gaps[:5]:
            print(g)
        print('%d gaps in the byte column' % len(gaps))
        return 1
    bad = []
    nfn = 0
    shapes = {}
    colour = set()
    for k, (start, name) in enumerate(labels):
        end = labels[k + 1][0] if k + 1 < len(labels) else len(code)
        if end <= start:
            continue
        nfn += 1
        ins = disasm(bytes(code[start:end]), start)
        i = 0
        while i < len(ins) and mn_ops(ins[i][1])[0] == 'push':
            i += 1
        pushed_rbp = any(ins[j][1].replace(' ', '') == 'pushrbp' for j in range(i))
        if i < len(ins) and re.match(r'^sub\s+rsp,', ins[i][1]):
            i += 1
        if i < len(ins) and ins[i][1].replace(' ', '') == 'movrbp,rsp':
            shapes[name] = 'moving'
            if i == 0 or not pushed_rbp or ins[[j for j in range(i) if mn_ops(ins[j][1])[0] == 'push'][-1]][1].replace(' ', '') != 'pushrbp':
                bad.append('%s: SP-moving prologue does not end its pushes with push rbp' % name)
                continue
        else:
            # SP-fixed (option C): rbp is a nonvolatile; written only if pushed
            shapes[name] = 'fixed'
            for a, t in ins[i:]:
                if writes_rbp(t):
                    if not pushed_rbp:
                        bad.append('%s+0x%x: writes rbp (%s) in an SP-fixed function that did not push it'
                                   % (name, a - start, t))
                        break
                    colour.add(name)
            continue
        i += 1
        ok_end = False
        while i < len(ins):
            a, t = ins[i]
            if t.replace(' ', '') == 'poprbp':
                j = i + 1
                while j < len(ins) and mn_ops(ins[j][1])[0] == 'pop':
                    j += 1
                if j < len(ins) and mn_ops(ins[j][1])[0] == 'ret':
                    ok_end = True
                    break
            if writes_rbp(t):
                bad.append('%s+0x%x: writes rbp (%s)' % (name, a - start, t))
                break
            i += 1
        else:
            if not ok_end and not any(b.startswith(name + '+') for b in bad):
                bad.append('%s: no epilogue (pop rbp ... ret) found' % name)
    for n in sorted(want_fixed):
        if shapes.get(n) != 'fixed':
            bad.append('%s: want SP-fixed (no `mov rbp, rsp`), got %s' % (n, shapes.get(n, 'no such function')))
    for n in sorted(want_moving):
        if shapes.get(n) != 'moving':
            bad.append('%s: want SP-moving (`mov rbp, rsp`), got %s' % (n, shapes.get(n, 'no such function')))
    for n in sorted(want_colour):
        if shapes.get(n) != 'fixed' or n not in colour:
            bad.append('%s: want rbp allocated as a colour (SP-fixed, body writes rbp after `push rbp`)' % n)
    for b in bad[:20]:
        print(b)
    nm = sum(1 for v in shapes.values() if v == 'moving')
    print('%d functions scanned (%d SP-moving with mov rbp,rsp, %d SP-fixed, %d of them with rbp as a colour), '
          '%d do not conform' % (nfn, nm, nfn - nm, len(colour), len(bad)))
    return 0 if not bad and nfn else 1


if __name__ == '__main__':
    sys.exit(main())
