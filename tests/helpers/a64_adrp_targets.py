#!/usr/bin/env python3
"""a64_adrp_targets.py IMAGE [IMAGE2] -- #143 row pe_a64_adrp_targets.

Every `adrp Xd, page` in a Windows arm64 image's .text, together with the
instruction right after it that uses Xd as its base -- `add Xd, Xd, #lo12`
(an address), `ldr Xt, [Xd, #off]` (an import slot or a static), `str Xt,
[Xd, #off]` (a static), and the 32/16/8-bit and d-register load/store forms
-- is decoded from the bytes, its target address computed from the image
base and the PC, and resolved through the section table. Each target must
land inside .data, inside .text (strings live there), or on an 8-byte slot
of .idata (an import). A wrong ADRP bias -- the header-size change of #143
(SizeOfHeaders 0x400 on arm64) applied to the headers but not to the
address arithmetic -- puts every target 0x200 off and fails here; no other
static check notices, and the image would load and fault.

An `adrp` not followed by such a use is counted as unpaired (data words in
.text can look like one) and not checked.

With IMAGE2 (the same program built with the other header size) the
decoded (pc, target) RVAs of the two must be identical: .text keeps RVA
0x1000 whatever the headers' size, so every address the code computes must
be the same.

Exit 0 when every pair resolves (and, with two images, the lists agree).
"""
import struct
import sys

BASE = 0x140000000


def load(path):
    b = open(path, 'rb').read()
    lfa = struct.unpack_from('<I', b, 60)[0]
    if b[lfa:lfa + 4] != b'PE\0\0' or struct.unpack_from('<H', b, lfa + 4)[0] != 0xAA64:
        raise SystemExit('error: %s is not an arm64 PE' % path)
    ns = struct.unpack_from('<H', b, lfa + 6)[0]
    opt = struct.unpack_from('<H', b, lfa + 20)[0]
    base = struct.unpack_from('<Q', b, lfa + 24 + 24)[0]
    soh = struct.unpack_from('<I', b, lfa + 24 + 60)[0]
    tab = lfa + 24 + opt
    secs = []
    for i in range(ns):
        h = tab + 40 * i
        name = b[h:h + 8].rstrip(b'\0').decode('latin-1')
        vs, va, raw, ptr = struct.unpack_from('<IIII', b, h + 8)
        secs.append((name, va, max(vs, raw), ptr, raw))
    return b, base, soh, secs


# load/store (unsigned offset) forms: (mask, value, scale)
LDST = [
    (0xFFC00000, 0xF9400000, 8), (0xFFC00000, 0xF9000000, 8),     # ldr/str x
    (0xFFC00000, 0xB9400000, 4), (0xFFC00000, 0xB9000000, 4),     # ldr/str w
    (0xFFC00000, 0x79400000, 2), (0xFFC00000, 0x79000000, 2),     # ldrh/strh
    (0xFFC00000, 0x39400000, 1), (0xFFC00000, 0x39000000, 1),     # ldrb/strb
    (0xFFC00000, 0xFD400000, 8), (0xFFC00000, 0xFD000000, 8),     # ldr/str d
    (0xFFC00000, 0xBD400000, 4), (0xFFC00000, 0xBD000000, 4),     # ldr/str s
]


def pairs(path):
    b, base, soh, secs = load(path)
    text = [s for s in secs if s[0] == '.text']
    if not text:
        raise SystemExit('error: %s has no .text' % path)
    _, tva, tsize, tptr, traw = text[0]
    code = b[tptr:tptr + traw]
    out, bad, unpaired = [], [], 0
    for o in range(0, len(code) - 7, 4):
        w = struct.unpack_from('<I', code, o)[0]
        if (w & 0x9F000000) != 0x90000000:
            continue
        rd = w & 31
        imm = (((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3)
        if imm & (1 << 20):
            imm -= 1 << 21
        pc = base + tva + o
        page = (pc & ~0xFFF) + (imm << 12)
        n = struct.unpack_from('<I', code, o + 4)[0]
        lo = None
        if (n >> 5) & 31 == rd:
            if (n & 0xFFC00000) == 0x91000000:                 # add xd, xn, #imm12
                lo = (n >> 10) & 0xFFF
            else:
                for mask, val, scale in LDST:
                    if (n & mask) == val:
                        lo = ((n >> 10) & 0xFFF) * scale
                        break
        if lo is None:
            unpaired += 1
            continue
        tgt = page + lo - base
        sec = [s for s in secs if s[1] <= tgt < s[1] + s[2]]
        where = sec[0][0] if sec else None
        ok = where in ('.data', '.text') or (where == '.idata' and tgt % 8 == 0)
        if not ok:
            bad.append('adrp at RVA 0x%x -> 0x%x lands in %s' % (tva + o, tgt,
                       'no section' if where is None else where + (' (not 8-aligned)' if where == '.idata' else '')))
        out.append((tva + o, tgt))
    return out, bad, unpaired, soh


def main():
    if len(sys.argv) not in (2, 3):
        raise SystemExit(__doc__)
    a, bad, unp, soh = pairs(sys.argv[1])
    for x in bad[:10]:
        print(x)
    rc = 1 if bad or not a else 0
    msg = '%d adrp pairs (SizeOfHeaders 0x%x), %d off target, %d unpaired' % (len(a), soh, len(bad), unp)
    if len(sys.argv) == 3:
        b2, bad2, unp2, soh2 = pairs(sys.argv[2])
        for x in bad2[:10]:
            print('second image: ' + x)
        if bad2:
            rc = 1
        if a != b2:
            diff = [(x, y) for x, y in zip(a, b2) if x != y]
            print('the two layouts decode different targets: %d of %d/%d pairs differ%s'
                  % (len(diff) + abs(len(a) - len(b2)), len(a), len(b2),
                     ('; first: 0x%x->0x%x vs 0x%x->0x%x' % (diff[0][0] + diff[0][1])) if diff else ''))
            rc = 1
        msg += '; identical to the SizeOfHeaders 0x%x image' % soh2 if a == b2 else ''
    print(msg)
    return rc


if __name__ == '__main__':
    sys.exit(main())
