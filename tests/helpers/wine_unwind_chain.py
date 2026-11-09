#!/usr/bin/env python3
"""wine_unwind_chain.py <wine stderr with WINEDEBUG=+unwind> <listing> <want>

#143: the faulting thread's walk, as Wine performed it. Takes the
`RtlVirtualUnwind type 1 rip X` lines of the first thread whose first such
rip lies in the image's code (base 0x140000000, .text at RVA 0x1000), maps
each rip to the listing function containing it, and requires the sequence to
be exactly <want> (comma-separated function names, faulting function first,
main last) followed by a rip OUTSIDE the image. A trace without such lines is
a FAIL: a change in Wine's trace format must not pass silently.
"""
import re
import sys

LABEL = re.compile(r'^([A-Za-z_.$][\w.$@]*):\s*$')
LINE = re.compile(r'^\s+([0-9a-f]{8}): ')


def main():
    trace, lst, want = sys.argv[1], sys.argv[2], sys.argv[3].split(',')
    labels, end, code_end = [], 0, None
    for line in open(lst, encoding='latin-1'):
        line = line.rstrip('\n')
        m = LABEL.match(line)
        if m:
            labels.append((end, m.group(1)))
        m = LINE.match(line)
        if m:
            end = int(m.group(1), 16) + 1
        if line.startswith('; uw-code-end '):
            code_end = int(line.split()[2], 16)
    if code_end is None:
        print('FAIL: listing has no uw-code-end')
        return 1
    base = 0x140001000
    rx = re.compile(r'^([0-9a-f]{4}):trace:unwind:RtlVirtualUnwind type 1 rip ([0-9a-f]+) rsp')
    bythread = {}
    order = []
    for line in open(trace, errors='replace'):
        m = rx.match(line)
        if m:
            t, rip = m.group(1), int(m.group(2), 16)
            if t not in bythread:
                bythread[t] = []
                order.append(t)
            bythread[t].append(rip)
    chain = None
    for t in order:
        r = bythread[t]
        if r and base <= r[0] < base + code_end:
            chain = r
            break
    if chain is None:
        print('FAIL: no RtlVirtualUnwind type 1 walk starting in the image')
        return 1
    names = []
    for rip in chain:
        off = rip - base
        if not 0 <= off < code_end:
            break
        fn = None
        for o, n in labels:
            if o <= off:
                fn = n
        names.append(fn)
    else:
        print('FAIL: the walk never left the image: %s' % names)
        return 1
    if names != want:
        print('FAIL: walk %s, want %s' % ('>'.join(map(str, names)), '>'.join(want)))
        return 1
    print('walk %s > outside the image' % '>'.join(names))
    return 0


if __name__ == '__main__':
    sys.exit(main())
