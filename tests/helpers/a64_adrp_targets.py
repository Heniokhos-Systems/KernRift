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

  a64_adrp_targets.py --list IMAGE [SYMBOL]   (L1: #294 #298 #299 #301)

lists the references of SYMBOL's code (every function when absent or `*`)
in a linked image of any format llvm-objdump reads (Mach-O, ELF, PE): for
arm64 each `adrp` + `add`/`ldr`/`str` pair decoded as above, for x86_64 each
RIP-relative operand llvm-objdump resolves (its `# 0x...` comment). One line
per reference, `0x<pc> <kind> -> 0x<target> in <section>` (`?` = no section).
Exit 0 when at least one reference is listed.
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


def listing(path, sym):
    import re
    import subprocess
    secs = []
    for ln in subprocess.run(['llvm-objdump', '-h', path], capture_output=True, text=True).stdout.splitlines():
        m = re.match(r'\s*\d+\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)', ln)
        if m:
            secs.append((m.group(1), int(m.group(3), 16), int(m.group(2), 16)))

    def where(t):
        for n, a, sz in secs:
            if a <= t < a + sz:
                return n
        return '?'
    ins, out = [], []
    cur = None
    for ln in subprocess.run(['llvm-objdump', '-d', path], capture_output=True, text=True).stdout.splitlines():
        m = re.match(r'^([0-9a-f]+) <(.*)>:', ln)
        if m:
            cur = m.group(2)
            continue
        if sym not in (None, '*') and cur != sym:
            continue
        m = re.match(r'\s*([0-9a-f]+):\s+([0-9a-f]{8})\s', ln)
        if m:                                              # arm64: one word
            ins.append((int(m.group(1), 16), int(m.group(2), 16)))
            continue
        m = re.match(r'\s*([0-9a-f]+):\s+((?:[0-9a-f]{2} )+).*#+ 0x([0-9a-f]+)', ln)
        if m:                                              # x86_64: resolved RIP-relative operand
            t = int(m.group(3), 16)
            out.append('0x%x rip -> 0x%x in %s' % (int(m.group(1), 16), t, where(t)))
    for k, (a, w) in enumerate(ins):
        if (w & 0x9F000000) != 0x90000000 or k + 1 >= len(ins):
            continue
        imm = (((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3)
        if imm & (1 << 20):
            imm -= 1 << 21
        page = (a & ~0xFFF) + (imm << 12)
        a2, n = ins[k + 1]
        if (n >> 5) & 31 != w & 31:
            continue
        if (n & 0xFFC00000) == 0x91000000:
            lo, kind = (n >> 10) & 0xFFF, 'add'
        else:
            lo = None
            for mask, val, scale in LDST:
                if (n & mask) == val:
                    lo, kind = ((n >> 10) & 0xFFF) * scale, 'ldst'
                    break
            if lo is None:
                continue
        t = page + lo
        out.append('0x%x %s -> 0x%x in %s' % (a, kind, t, where(t)))
    for x in out:
        print(x)
    return 0 if out else 1


def main():
    if len(sys.argv) in (3, 4) and sys.argv[1] == '--list':
        return listing(sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else None)
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
