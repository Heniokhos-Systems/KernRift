#!/usr/bin/env python3
"""win_frame_classes.py <x86_64|arm64> <listing> [--ir]

#143 option C (spec 2.5.5, finding 21): the frame class of every function of
a Windows --test-listing, from its bytes. x86_64: SP-moving when the function
contains `mov rbp, rsp` (48 89 e5), else SP-fixed. arm64: SP-moving when it
contains `add x29, sp, #imm` (set_fp / add_fp), else SP-fixed; with --ir the
arm64 IR shape (D, S1, S2) from a64_win_frame_scan.py is printed too.
Prints `<function> <SP-fixed|SP-moving> <shape or ->`, one per line.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import a64_win_frame_scan as A  # noqa: E402

LABEL = re.compile(r'^([A-Za-z_.$][\w.$@]*):\s*$')
X86 = re.compile(r'^\s+([0-9a-f]{8}): ((?:[0-9a-f]{2} )*[0-9a-f]{2})(?:\s|$)')
A64 = re.compile(r'^\s+([0-9a-f]{8}): ([0-9a-f]{8})(?:\s|$)')


def main():
    arch, lst = sys.argv[1], sys.argv[2]
    ir = '--ir' in sys.argv[3:]
    fns, order, naked, cur = {}, [], set(), None
    for l in open(lst, encoding='latin-1'):
        l = l.rstrip('\n')
        m = LABEL.match(l)
        if m:
            cur = m.group(1)
            if cur not in fns:
                fns[cur] = []; order.append(cur)
            continue
        if l.startswith('; uw-naked '):
            naked.add(l.split()[2]); continue
        if cur is None:
            continue
        m = (A64 if arch == 'arm64' else X86).match(l)
        if m:
            fns[cur].append((int(m.group(1), 16), int(m.group(2), 16) if arch == 'arm64' else m.group(2)))
    for n in order:
        if n in naked or not fns[n]:
            continue
        if arch == 'arm64':
            moving = any((w & 0xFFC003FF) == 0x910003FD for _, w in fns[n])
            shape = '-'
            if ir:
                shape, _ = A.check(n, fns[n])
                shape = shape or '?'
        else:
            moving = any(b == '48 89 e5' for _, b in fns[n])
            shape = '-'
        print('%s %s %s' % (n, 'SP-moving' if moving else 'SP-fixed', shape))
    return 0


if __name__ == '__main__':
    sys.exit(main())
