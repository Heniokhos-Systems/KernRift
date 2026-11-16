#!/usr/bin/env python3
"""a64_asm_reference.py STRINGS WORKDIR KRC -- A1 rows asm_a64_*_encoding_llvm.

An independent encoder for the arm64 inline assembler: LLVM's. STRINGS holds
one asm string per line (no quotes; blank lines ignored). Each string is
built twice by KRC -- the IR path and --legacy -- as the only instruction
between two marker words (movz x17, #0xbeef / #0xfeed) of an asm block, with
--emit=asm; the listing word(s) between the markers must equal the encoding
`llvm-mc -triple=aarch64 -show-encoding` gives for the same text, and llvm-mc
must accept it without a warning (an UNPREDICTABLE form it merely warns about
is not a reference).

Prints one line per string ("ok", or what differs) and a summary; exit 0
when every string agrees in both modes, 1 otherwise, 2 on a tool failure.
"""
import os
import re
import subprocess
import sys

M1, M2 = 'd297ddf1', 'd29fddb1'        # movz x17, #0xbeef / movz x17, #0xfeed
LINE = re.compile(r'^\s+[0-9a-f]{8}: ([0-9a-f]{8})(?:\s|$)')


def llvm(s):
    p = subprocess.run(['llvm-mc', '-triple=aarch64', '-show-encoding'],
                       input=s + '\n', capture_output=True, text=True)
    if p.returncode != 0 or 'error' in p.stderr or 'warning' in p.stderr:
        return None, (p.stderr.strip().splitlines() or ['rc %d' % p.returncode])[0][:160]
    words = []
    for m in re.finditer(r'encoding: \[([^\]]*)\]', p.stdout):
        b = [int(x, 16) for x in m.group(1).split(',')]
        words.append('%08x' % (b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24))
    return words, None


def krc(krc_cmd, wd, s, legacy):
    src = ('fn f(uint64 a) -> uint64 {\n    uint64 v = a\n'
           '    asm { "movz x17, #0xbeef"; "%s"; "movz x17, #0xfeed" } '
           'in(v -> x9) clobbers(x0, x1, x2, x17, x29)\n    return v\n}\n'
           'fn main() { exit(f(7)) }\n') % s
    kr, out = os.path.join(wd, 'f.kr'), os.path.join(wd, 'o.s')
    open(kr, 'w').write(src)
    if os.path.exists(out):
        os.unlink(out)
    cmd = [krc_cmd, '--arch=arm64', '--target=linux'] + (['--legacy'] if legacy else []) + ['--emit=asm', kr, '-o', out]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if p.returncode != 0 or not os.path.exists(out):
        return None, (p.stderr.strip().splitlines() or ['rc %d' % p.returncode])[0][:160]
    words, on = [], False
    for line in open(out):
        m = LINE.match(line)
        if not m:
            continue
        w = m.group(1)
        if w == M1:
            on = True
            continue
        if w == M2:
            break
        if on:
            words.append(w)
    return words, None


def main():
    if len(sys.argv) != 4:
        print(__doc__.strip().splitlines()[0])
        return 2
    strings = [l.rstrip('\n') for l in open(sys.argv[1]) if l.strip()]
    wd = sys.argv[2]
    os.makedirs(wd, exist_ok=True)
    if not strings:
        print('no strings in %s' % sys.argv[1])
        return 2
    bad = 0
    for s in strings:
        ref, err = llvm(s)
        if ref is None:
            print('llvm-mc does not accept %r: %s' % (s, err))
            bad += 1
            continue
        line = []
        for legacy in (False, True):
            got, kerr = krc(sys.argv[3], wd, s, legacy)
            mode = 'legacy' if legacy else 'ir'
            if got is None:
                line.append('%s: krc refused (%s)' % (mode, kerr))
            elif got != ref:
                line.append('%s: krc %s, llvm-mc %s' % (mode, ' '.join(got) or '(none)', ' '.join(ref)))
        if line:
            bad += 1
            print('%r: %s' % (s, '; '.join(line)))
        else:
            print('ok %r %s' % (s, ' '.join(ref)))
    if bad:
        print('%d of %d strings differ from llvm-mc' % (bad, len(strings)))
        return 1
    print('%d strings, IR and --legacy, word == llvm-mc' % len(strings))
    return 0


if __name__ == '__main__':
    sys.exit(main())
