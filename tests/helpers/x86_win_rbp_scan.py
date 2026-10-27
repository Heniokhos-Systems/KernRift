#!/usr/bin/env python3
"""x86_win_rbp_scan.py <listing> -- #143 row ir_x86_win_no_rbp_colour.

On Windows every non-naked x86_64 IR function establishes rbp as its frame
pointer and never hands rbp to a value (it is not a colour there). This scan
checks that on a `--target=windows --emit=asm` listing, using only its labels
and byte column (the listing's own mnemonics are not trusted): each function's
bytes are disassembled with objdump, and

  * the prologue is `push` r64... (ending with `push rbp`), an optional
    `sub rsp, imm`, then `mov rbp, rsp`;
  * after that, nothing writes rbp/ebp/bp/bpl until the function's epilogue:
    the first `pop rbp` that is followed only by pops and `ret`.

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
    code = bytearray()
    labels = []
    gaps = []
    for n, line in enumerate(open(sys.argv[1], encoding='latin-1'), 1):
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
    for k, (start, name) in enumerate(labels):
        end = labels[k + 1][0] if k + 1 < len(labels) else len(code)
        if end <= start:
            continue
        nfn += 1
        ins = disasm(bytes(code[start:end]), start)
        i = 0
        while i < len(ins) and mn_ops(ins[i][1])[0] == 'push':
            i += 1
        if i == 0 or ins[i - 1][1].replace(' ', '') != 'pushrbp':
            bad.append('%s: prologue does not end its pushes with push rbp' % name)
            continue
        if i < len(ins) and re.match(r'^sub\s+rsp,', ins[i][1]):
            i += 1
        if i >= len(ins) or ins[i][1].replace(' ', '') != 'movrbp,rsp':
            bad.append('%s: no `mov rbp, rsp` after the pushes and the frame allocation' % name)
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
    for b in bad[:20]:
        print(b)
    print('%d functions scanned, %d do not conform' % (nfn, len(bad)))
    return 0 if not bad and nfn else 1


if __name__ == '__main__':
    sys.exit(main())
