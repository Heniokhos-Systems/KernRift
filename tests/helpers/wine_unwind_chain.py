#!/usr/bin/env python3
"""wine_unwind_chain.py --runner=wine|native <wine stderr with WINEDEBUG=+unwind> <listing> <want>

#143: the faulting thread's walk, as Wine performed it. Takes the type 1
RtlVirtualUnwind lines of the first thread whose first such rip lies in the
image's code (base 0x140000000, .text at RVA 0x1000), maps each rip to the
listing function containing it, and requires the sequence to be exactly
<want> (comma-separated function names, faulting function first, main last)
followed by a rip OUTSIDE the image.

Exactly two trace shapes are known (#229), nothing looser:
  wine <= 9   `<tid>:trace:unwind:RtlVirtualUnwind type 1 rip <rip> rsp ...`
  wine 10     `<tid>:trace:unwind:RtlVirtualUnwind2 type 1 base <base> rip <rip> rva <rva> rsp ...`
A Wine 10 line must satisfy rva == rip - base: a format that changes meaning
must not pass.

--runner says who ran the program (#229 guard). natively there is no Wine
trace, and the native judge (tests/windows/native_judge.py, rule `fault`)
accepts exactly the text `FAIL: no RtlVirtualUnwind type 1 walk starting in
the image` as that expected native failure. Only --runner=native may print
it. Under Wine every way of finding no walk has its own text, so a Wine run
can never produce the failure the judge accepts as native:
  FAIL: Wine wrote no +unwind trace                (no :trace:unwind: line)
  FAIL: unrecognized Wine +unwind trace format: .. (unwind lines, none known)
  FAIL: Wine's type 1 walks never start in the image
"""
import re
import sys

LABEL = re.compile(r'^([A-Za-z_.$][\w.$@]*):\s*$')
LINE = re.compile(r'^\s+([0-9a-f]{8}): ')
RX9 = re.compile(r'^([0-9a-f]{4}):trace:unwind:RtlVirtualUnwind type 1 rip ([0-9a-f]+) rsp ')
RX10 = re.compile(r'^([0-9a-f]{4}):trace:unwind:RtlVirtualUnwind2 type 1 base ([0-9a-f]+) rip ([0-9a-f]+) '
                  r'rva ([0-9a-f]+) rsp ')
ANY_UNWIND = re.compile(r'^[0-9a-f]{4}:trace:unwind:')
NATIVE_TEXT = 'FAIL: no RtlVirtualUnwind type 1 walk starting in the image'


def main(argv):
    if len(argv) != 5 or argv[1] not in ('--runner=wine', '--runner=native'):
        print('FAIL: usage: wine_unwind_chain.py --runner=wine|native <trace> <listing> <want>')
        return 2
    runner = argv[1].split('=', 1)[1]
    trace, lst, want = argv[2], argv[3], argv[4].split(',')
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
    bythread = {}
    order = []
    first_unwind = None
    for line in open(trace, errors='replace'):
        if first_unwind is None and ANY_UNWIND.match(line):
            first_unwind = line.strip()[:120]
        m = RX9.match(line)
        if m:
            t, rip = m.group(1), int(m.group(2), 16)
        else:
            m = RX10.match(line)
            if not m:
                continue
            t, b, rip, rva = m.group(1), int(m.group(2), 16), int(m.group(3), 16), int(m.group(4), 16)
            if rip - b != rva:
                print('FAIL: inconsistent RtlVirtualUnwind2 line (rip - base != rva): %s' % line.strip()[:120])
                return 1
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
        if runner == 'native':
            print(NATIVE_TEXT)
        elif first_unwind is None:
            print('FAIL: Wine wrote no +unwind trace')
        elif not order:
            print('FAIL: unrecognized Wine +unwind trace format: %s' % first_unwind)
        else:
            print("FAIL: Wine's type 1 walks never start in the image")
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
    sys.exit(main(sys.argv))
