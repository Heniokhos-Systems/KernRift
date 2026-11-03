#!/usr/bin/env python3
"""a64_win_exec_words.py <listing> <function> exec_process|exec_process_argv

#143 #174: the literal words of the Windows arm64 legacy exec builtins (site
G1), decoded from the byte column of a --test-listing. In <function>:
  1. no load/store (unsigned immediate or pair) and no add/sub immediate takes
     x7 as its base: every SP-relative word has Rn = sp (x7 only ever holds an
     argument there);
  2. no ldp whose two destinations are both xzr (the old "zeroing" word);
  3. exactly 8 `stp xzr, xzr, [x0], #16` after an `add x0, sp, #0x60`;
  4. `add x9, sp, #0x60` (&si) and `add x9, sp, #0xc8` (&pi) present, and
     hProcess read from [sp, #0xc8] -- twice for exec_process (the
     exec_process_argv sequence reads it twice as well);
  5. exec_process only: the path reload after the allocation reads the slot
     the path was stored to, moved by the bytes SP moved (0xe0, or 0 when the
     site is folded and there is no `sub sp, sp, #0xe0`).
Prints the problems and a summary; exit 0 only when there are none.
"""
import re
import sys

LINE = re.compile(r'^\s+([0-9a-f]{8}): ([0-9a-f]{8})(?:\s|$)')
LABEL = re.compile(r'^([A-Za-z_.$][\w.$@]*):\s*$')


def words(lst, fn):
    cur, out = None, []
    for l in open(lst, encoding='latin-1'):
        m = LABEL.match(l.rstrip('\n'))
        if m:
            cur = m.group(1); continue
        m = LINE.match(l)
        if m and cur == fn:
            out.append(int(m.group(2), 16))
    return out


def base(w):
    """Rn of an addressing or add/sub-immediate word, else None"""
    if (w & 0x3B000000) == 0x39000000: return (w >> 5) & 31      # ld/st unsigned imm
    if (w & 0x3A000000) == 0x28000000: return (w >> 5) & 31      # ld/st pair (any index)
    if (w & 0x1F000000) == 0x11000000: return (w >> 5) & 31      # add/sub imm
    return None


def main():
    lst, fn, kind = sys.argv[1:4]
    ws = words(lst, fn)
    bad = []
    if not ws: print('%s: not in the listing' % fn); return 1
    for i, w in enumerate(ws):
        if base(w) == 7: bad.append('word %d %08x addresses through x7' % (i, w))
        if (w & 0x7FC00000) in (0x28C00000, 0x29400000, 0x29C00000) and (w & 31) == 31 and ((w >> 10) & 31) == 31:
            bad.append('word %d %08x is an ldp into xzr, xzr' % (i, w))
    z = [i for i, w in enumerate(ws) if w == 0xA8817C1F]
    a0 = [i for i, w in enumerate(ws) if w == 0x910183E0]
    if len(z) != 8 or not a0 or z[0] != a0[0] + 1 or z != list(range(z[0], z[0] + 8)):
        bad.append('want add x0, sp, #0x60 then 8 stp xzr, xzr, [x0], #16; found %d stp at %s' % (len(z), z[:2]))
    for w, what in ((0x910183E9, 'add x9, sp, #0x60 (&si)'), (0x910323E9, 'add x9, sp, #0xc8 (&pi)')):
        if w not in ws: bad.append('no %s' % what)
    n = ws.count(0xF94067E0)
    if n != 2: bad.append('hProcess read from [sp, #0xc8] %d times, want 2' % n)
    if kind == 'exec_process' and a0:
        subs = [i for i, w in enumerate(ws[:a0[0]]) if w == 0xD10383FF]
        moved = 0xE0 if subs else 0
        lim = subs[-1] if subs else a0[0]
        st = [((w >> 10) & 0xFFF) * 8 for w in ws[:lim] if (w & 0xFFC003FF) == 0xF90003E0]
        ld = [((w >> 10) & 0xFFF) * 8 for w in ws[z[-1] + 1:] if (w & 0xFFC003FF) == 0xF94003E0] if z else []
        if not st or not ld: bad.append('path store/reload not found')
        elif ld[0] != st[-1] + moved:
            bad.append('path stored at [sp, #%d], reloaded from [sp, #%d] after SP moved %d' % (st[-1], ld[0], moved))
    for b in bad: print('%s: %s' % (fn, b))
    print('%s (%s): %d words, %d problems' % (fn, kind, len(ws), len(bad)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
