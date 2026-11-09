#!/usr/bin/env python3
"""a64_win_legacy_fold_scan.py <listing> [--want-folded=A,B] [--want-set-fp=C,D]

#143 A19d(iii) (spec 2.5.7, ruling Q11, option (a)): the shape of Windows
arm64 legacy functions, from the byte column of a --test-listing (the
mnemonics are not trusted; every word is decoded here).

  folded   no `add x29, sp, #0` (set_fp) anywhere in the function, and no
           word that writes SP (add/sub immediate with Rd = sp) between the
           prologue's `stp x19, x20, [sp, #k]` and the epilogue's
           `ldp x19, x20, [sp, #k]`; the two pairs at the same k, with
           x29/x30 at k - 16 (OUT = k - 16)
  set_fp   `add x29, sp, #0` present (an SP-moving function keeps it)

Prints one line per function checked (name, shape, OUT for folded ones) and
a summary; exit 0 when every named function was found and conforms.
"""
import re
import sys

LINE = re.compile(r'^\s+([0-9a-f]{8}): ([0-9a-f]{8})(?:\s|$)')
LABEL = re.compile(r'^([A-Za-z_.$][\w.$@]*):\s*$')
SET_FP = 0x910003FD


def writes_sp(w):
    return (w >> 24) in (0x91, 0xD1) and (w & 31) == 31


def pair(w, load):
    """stp/ldp x19, x20, [sp, #k] (signed offset) -> k, else None"""
    base = 0xA9400000 if load else 0xA9000000
    if (w & 0xFFC07FFF) == (base | (20 << 10) | (31 << 5) | 19):
        return ((w >> 15) & 0x7F) * 8
    return None


def fplr(w, load):
    base = 0xA9400000 if load else 0xA9000000
    if (w & 0xFFC07FFF) == (base | (30 << 10) | (31 << 5) | 29):
        return ((w >> 15) & 0x7F) * 8
    return None


def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    folded, setfp = set(), set()
    for a in sys.argv[2:]:
        if a.startswith('--want-folded='): folded |= {n for n in a.split('=', 1)[1].split(',') if n}
        elif a.startswith('--want-set-fp='): setfp |= {n for n in a.split('=', 1)[1].split(',') if n}
        else: print('unknown argument: %s' % a); return 2
    fns, cur = {}, None
    for l in open(sys.argv[1], encoding='latin-1'):
        m = LABEL.match(l.rstrip('\n'))
        if m:
            cur = m.group(1); fns.setdefault(cur, []); continue
        m = LINE.match(l)
        if m and cur is not None:
            fns[cur].append(int(m.group(2), 16))
    bad = 0
    for name in sorted(folded | setfp):
        ws = fns.get(name)
        if not ws:
            print('%s: not in the listing' % name); bad += 1; continue
        has_fp = SET_FP in ws
        if name in setfp:
            if has_fp: print('%s: set_fp (SP-moving)' % name)
            else: print('%s: want set_fp, none' % name); bad += 1
            continue
        why = []
        if has_fp: why.append('has set_fp')
        st = [i for i, w in enumerate(ws) if pair(w, False) is not None]
        ld = [i for i, w in enumerate(ws) if pair(w, True) is not None]
        if len(st) != 1 or len(ld) != 1:
            why.append('want one stp and one ldp of x19/x20, found %d/%d' % (len(st), len(ld)))
        else:
            k, k2 = pair(ws[st[0]], False), pair(ws[ld[0]], True)
            fs = [fplr(w, False) for w in ws if fplr(w, False) is not None]
            fl = [fplr(w, True) for w in ws if fplr(w, True) is not None]
            if k != k2 or fs != [k - 16] or fl != [k - 16]:
                why.append('save area: x19/x20 at %s/%s, x29/x30 at %s/%s' % (k, k2, fs, fl))
            n = sum(1 for w in ws[st[0] + 1:ld[0]] if writes_sp(w))
            if n: why.append('%d SP write(s) in the body' % n)
        if why: print('%s: want folded: %s' % (name, '; '.join(why))); bad += 1
        else: print('%s: folded, OUT %d' % (name, pair(ws[st[0]], False) - 16))
    print('%d functions checked, %d do not conform' % (len(folded | setfp), bad))
    return 1 if bad or not (folded | setfp) else 0


if __name__ == '__main__':
    sys.exit(main())
