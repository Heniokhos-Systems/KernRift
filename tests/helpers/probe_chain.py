#!/usr/bin/env python3
"""probe_chain.py <lld /map> <probe stdout> <image name> [--style=native-probe]

#143 A13 / #327: names the frames the linked COFF probe printed
(tests/fixtures/pe_unwind_cprobe/host.c), one per line, as
`<pc:16 hex> <module base:16 hex | -> <module path | ->`, and prints them as
one comma-separated chain. The one place that names those frames: used by
the suite row pe_unwind_obj_link_windows_wine and by
tests/windows/native_probe.sh.

  * pc 0                      -> NULL
  * a frame in <image name>   -> the /map symbol containing
                                 pc - module base + preferred load address
  * a frame in another module -> its file name, lower case (kernel32.dll);
                                 with --style=native-probe the file name
                                 without its extension, upper case (KERNEL32)

The mapping is relative to the module's real load base, so it is exact under
ASLR (Windows) and at the preferred base (Wine) alike. Mapping the absolute
pc (the rule before #327) names every image frame `main` natively.

Refused, with one `FAIL: ...` line and exit 1 (never a guess, never a
traceback): a map without its "Preferred load address" line or without a
.text symbol, a probe line not of the three-field form (the two-field lines
of a host.c older than T1 included), and an image frame without a module base.
"""
import re
import sys

SYM = re.compile(r'^\s*0001:[0-9a-f]{8}\s+(\S+)\s+([0-9a-f]{16})\s+\S+\s*$')
PREF = re.compile(r'^\s*Preferred load address is ([0-9a-f]+)\s*$')
FRAME = re.compile(r'^([0-9a-f]{16}) ([0-9a-f]{16}|-) (\S.*)$')


def fail(msg):
    print('FAIL: ' + msg)
    return 1


def main(argv):
    args = [a for a in argv[1:] if not a.startswith('--')]
    opts = [a for a in argv[1:] if a.startswith('--')]
    if len(args) != 3 or any(o != '--style=native-probe' for o in opts):
        return fail('usage: probe_chain.py <map> <probe stdout> <image name> [--style=native-probe]')
    mapf, outf, image = args
    native_style = bool(opts)
    syms, pref = [], None
    try:
        maplines = open(mapf, encoding='latin-1').read().split('\n')
        outlines = open(outf, encoding='latin-1', errors='replace').read().split('\n')
    except OSError as ex:
        return fail('cannot read %s' % ex)
    for ln in maplines:
        m = SYM.match(ln)
        if m:
            syms.append((int(m.group(2), 16), m.group(1)))
        m = PREF.match(ln)
        if m:
            pref = int(m.group(1), 16)
    if pref is None:
        return fail('map %s has no "Preferred load address" line' % mapf)
    if not syms:
        return fail('map %s names no .text (0001:) symbol' % mapf)
    syms.sort()
    out = []
    for ln in outlines:
        ln = ln.replace('\r', '').strip()
        if not ln:
            continue
        m = FRAME.match(ln)
        if not m:
            return fail('probe line %r is not "<pc> <module base> <module>" (a host.c older than T1?)' % ln[:80])
        pc, base, mod = int(m.group(1), 16), m.group(2), m.group(3)
        if pc == 0:
            out.append('NULL')
            continue
        name = re.split(r'[\\/]', mod)[-1]
        if name.lower() == image.lower():
            if base == '-':
                return fail('image frame %s has no module base' % m.group(1))
            off = pc - int(base, 16) + pref
            own = [n for a, n in syms if a <= off]
            out.append(own[-1] if own else '?image')
        elif native_style:
            out.append(name.split('.')[0].upper())
        else:
            out.append(name.lower())
    print(','.join(out))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
