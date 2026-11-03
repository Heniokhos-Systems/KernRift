#!/usr/bin/env python3
"""a64_win_frame_scan.py <listing> -- #143 row a64_win_frame_shape.

The Windows arm64 frame of every non-naked IR function (spec 5.1), checked on
an arm64 `--target=windows` listing from its byte column alone (the listing's
mnemonics are not trusted; every word is decoded here):

  prologue  sub sp, sp, #A                    A a multiple of 16
            stp/str of the save area at [sp, #k]: k = 0, 8, 16 ... in order,
              GPRs x19-x28 ascending, then x29/x30 as one pair, then d8-d15
              ascending; a pair only of CONSECUTIVE registers
            add x29, sp, #f                   f = the x29/x30 slot
            sub sp, sp, #L  |  mov x16 (movz/movk) ...; sub sp, sp, x16
                                              L a multiple of 16
  epilogue  sub sp, x29, #f
            the restores of exactly the same slots in EXACT REVERSE order
            add sp, sp, #A
            ret

Functions the listing marks `; uw-naked` are skipped. Prints one line per
offending function and a summary; exit 0 when every function conforms and at
least one was checked.
"""
import re
import sys

LINE = re.compile(r'^\s+([0-9a-f]{8}): ([0-9a-f]{8})(?:\s|$)')
LABEL = re.compile(r'^([A-Za-z_.$][\w.$@]*):\s*$')


def sub_sp_imm(w):
    """sub sp, sp, #imm (no shift) -> imm, else None"""
    if (w & 0xFFC003FF) == 0xD10003FF:
        return (w >> 10) & 0xFFF
    return None


def add_sp_imm(w):
    if (w & 0xFFC003FF) == 0x910003FF:
        return (w >> 10) & 0xFFF
    return None


def save(w, load):
    """stp/ldp/str/ldr (64-bit X or D, unsigned/signed offset) based on sp ->
    (class, r1, r2 or None, offset), else None"""
    if (w >> 5) & 31 != 31:
        return None
    lbit = 1 if load else 0
    # STP/LDP X, signed offset: 1010100100 L imm7 Rt2 Rn Rt
    if (w & 0xFFC00000) == (0xA9000000 | (lbit << 22)):
        imm = (w >> 15) & 0x7F
        imm = imm - 128 if imm & 64 else imm
        return ('x', w & 31, (w >> 10) & 31, imm * 8)
    # STP/LDP D: 0110110100 L ...
    if (w & 0xFFC00000) == (0x6D000000 | (lbit << 22)):
        imm = (w >> 15) & 0x7F
        imm = imm - 128 if imm & 64 else imm
        return ('d', w & 31, (w >> 10) & 31, imm * 8)
    # STR/LDR X unsigned offset: 1111100100 / 1111100101
    if (w & 0xFFC00000) == (0xF9000000 | (lbit << 22)):
        return ('x', w & 31, None, ((w >> 10) & 0xFFF) * 8)
    # STR/LDR D unsigned offset: 1111110100 / 1111110101
    if (w & 0xFFC00000) == (0xFD000000 | (lbit << 22)):
        return ('d', w & 31, None, ((w >> 10) & 0xFFF) * 8)
    return None


def lsl12_sp(w, add):
    """sub/add sp, sp, #imm, lsl #12 -> imm, else None"""
    want = 0x914003FF if add else 0xD14003FF
    if (w & 0xFFC003FF) == want:
        return (w >> 10) & 0xFFF
    return None


def saves_at(words, i, load):
    out = []
    while i < len(words):
        s = save(words[i][1], load)
        if s is None:
            break
        out.append(s)
        i += 1
    return out, i


def order(saves, base):
    """The D save order from `base`: slots in order, GPRs ascending, then
    x29/x30 once, then d-registers ascending, consecutive pairs only.
    Returns (problem or None, bytes saved, x29/x30 offset)."""
    slot = base
    phase = 0          # 0 GPRs, 1 after x29/x30, 2 d-regs
    last = None
    fp_off = None
    for cls, r1, r2, off in saves:
        if off != slot:
            return 'save of %s%d at #%d, want the next slot #%d' % (cls, r1, off, slot), 0, None
        regs = [r1] if r2 is None else [r1, r2]
        if r2 is not None and r2 != r1 + 1:
            return 'pair %s%d/%s%d is not consecutive' % (cls, r1, cls, r2), 0, None
        if cls == 'x' and regs == [29, 30]:
            if phase != 0:
                return 'x29/x30 saved twice or after the d-registers', 0, None
            phase, fp_off = 1, off
        elif cls == 'x':
            if phase != 0 or not all(19 <= r <= 28 for r in regs):
                return 'GPR save %s out of place' % regs, 0, None
            if last is not None and regs[0] <= last:
                return 'GPR saves not ascending', 0, None
            last = regs[-1]
        else:
            if phase == 0:
                return 'd-register save before x29/x30', 0, None
            if not all(8 <= r <= 15 for r in regs):
                return 'd-register save %s out of range' % regs, 0, None
            if phase == 2 and regs[0] <= last:
                return 'd-register saves not ascending', 0, None
            phase, last = 2, regs[-1]
        slot += 8 * len(regs)
    if fp_off is None:
        return 'x29/x30 not saved', 0, None
    return None, slot - base, fp_off


def no_x29_write(words, lo, hi):
    """option C (Q12): no body word writes x29 -- checked on the data-processing
    and load forms that name a destination in bits 0-4"""
    for k in range(lo, hi):
        w = words[k][1]
        if (w & 0x1F) == 29 and ((w >> 26) & 7) in (4, 5) and (w >> 24) & 0x1F not in (0x14, 0x15, 0x16, 0x17):
            return 'body writes x29 at word %d (%08x)' % (k, w)
    return None


def check(name, words):
    """words: [(offset, word)] of one function. Returns (shape, problem or None)."""
    if not words:
        return None, 'empty'
    a = sub_sp_imm(words[0][1])
    if a is None or a == 0 or a % 16:
        return None, 'does not start with `sub sp, sp, #A` (A a nonzero multiple of 16)'
    saves, i = saves_at(words, 1, False)
    if not saves:
        return None, 'no saves after `sub sp, sp, #%d`' % a
    rets = [k for k in range(len(words)) if words[k][1] == 0xD65F03C0]
    if not rets:
        return None, 'no ret'
    r = rets[-1]
    base = saves[0][3]
    if base != 0:
        # S1: one allocation, the saves at the top [sp, #low + k], no frame pointer
        p, size, fp_off = order(saves, base)
        if p:
            return 'S1', p
        if (base + size + 15) // 16 * 16 != a:
            return 'S1', 'save area at #%d, %d bytes, allocation %d (want the saves at the top)' % (base, size, a)
        if base + size - 8 > 504 + 8:
            return 'S1', 'save offset above 504'
        n = len(saves)
        if r < n + 1 or add_sp_imm(words[r - 1][1]) != a:
            return 'S1', 'epilogue does not end `add sp, sp, #%d; ret`' % a
        rest, _ = saves_at(words, r - 1 - n, True)
        if rest[:n] != list(reversed(saves)):
            return 'S1', 'restores %s are not the saves in exact reverse' % rest[:n]
        return 'S1', no_x29_write(words, i, r - 1 - n)
    p, size, fp_off = order(saves, 0)
    if p:
        return None, p
    if (size + 15) // 16 * 16 != a:
        return None, 'save area %d bytes, allocated %d (want it rounded to 16)' % (size, a)
    if i < len(words) and words[i][1] == (0x910003FD | ((fp_off & 0xFFF) << 10)):
        return 'D', check_d(words, i + 1, a, saves, fp_off)
    # S2: the split layout without add_fp; low = hi << 12 | lo
    hi = lsl12_sp(words[i][1], False) if i < len(words) else None
    if hi is not None:
        i += 1
    lo = sub_sp_imm(words[i][1]) if i < len(words) else None
    if lo is not None:
        i += 1
    if hi is None and lo is None:
        return 'S2', 'no low allocation after the saves (and no `add x29`)'
    if (lo or 0) % 16 or lo == 0 or hi == 0:
        return 'S2', 'low allocation hi %s lo %s (lo a nonzero multiple of 16, hi nonzero, each when present)' % (hi, lo)
    n = len(saves)
    k = r - 1
    if add_sp_imm(words[k][1]) != a:
        return 'S2', 'epilogue does not end `add sp, sp, #%d; ret`' % a
    rest, _ = saves_at(words, k - n, True)
    if k - n < 0 or rest[:n] != list(reversed(saves)):
        return 'S2', 'restores are not the saves in exact reverse'
    j = k - n - 1
    if hi is not None:
        if lsl12_sp(words[j][1], True) != hi:
            return 'S2', 'epilogue lacks `add sp, sp, #%d, lsl #12` before the restores' % hi
        j -= 1
    if lo is not None:
        if add_sp_imm(words[j][1]) != lo:
            return 'S2', 'epilogue does not start `add sp, sp, #%d`' % lo
        j -= 1
    return 'S2', no_x29_write(words, i, j + 1)


def check_d(words, i, a, saves, fp_off):
    low = sub_sp_imm(words[i][1]) if i < len(words) else None
    if low is not None:
        if low % 16:
            return 'low allocation %d is not a multiple of 16' % low
        i += 1
    else:
        # mov x16, #L (movz/movk x16 ...) then sub sp, sp, x16
        val = 0
        nmov = 0
        while i < len(words):
            w = words[i][1]
            if (w & 0xFF80001F) == 0xD2800010:          # movz x16, #imm16, lsl #hw
                hw = (w >> 21) & 3
                val = ((w >> 5) & 0xFFFF) << (16 * hw)
            elif (w & 0xFF80001F) == 0xF2800010:        # movk x16
                hw = (w >> 21) & 3
                val = (val & ~(0xFFFF << (16 * hw))) | (((w >> 5) & 0xFFFF) << (16 * hw))
            else:
                break
            nmov += 1
            i += 1
        if nmov == 0 or i >= len(words) or words[i][1] != 0xCB3063FF:
            return 'no low allocation after `add x29`'
        if val % 16:
            return 'low allocation %d is not a multiple of 16' % val
        i += 1
    # epilogue: the unique `sub sp, x29, #f`
    want = 0xD1000000 | ((fp_off & 0xFFF) << 10) | (29 << 5) | 31
    eps = [k for k in range(i, len(words)) if words[k][1] == want]
    if len(eps) != 1:
        return '%d epilogues (`sub sp, x29, #%d`), want 1' % (len(eps), fp_off)
    k = eps[0] + 1
    rest, k = saves_at(words, k, True)
    if rest != list(reversed(saves)):
        return 'restores %s are not the saves in exact reverse %s' % (rest, list(reversed(saves)))
    if k + 1 >= len(words) or add_sp_imm(words[k][1]) != a or words[k + 1][1] != 0xD65F03C0:
        return 'restores are not followed by `add sp, sp, #%d; ret`' % a
    return None


def main():
    labels, words, naked = [], [], set()
    for line in open(sys.argv[1], encoding='latin-1'):
        line = line.rstrip('\n')
        m = LABEL.match(line)
        if m:
            labels.append((len(words), m.group(1)))
            continue
        if line.startswith('; uw-naked '):
            naked.add(line.split()[2])
            continue
        m = LINE.match(line)
        if m:
            words.append((int(m.group(1), 16), int(m.group(2), 16)))
    bad, n = [], 0
    shapes = {}
    for k, (start, name) in enumerate(labels):
        end = labels[k + 1][0] if k + 1 < len(labels) else len(words)
        if end <= start or name in naked:
            continue
        n += 1
        shape, p = check(name, words[start:end])
        shapes[name] = shape
        if p:
            bad.append('%s: %s' % (name, p))
    if '--shapes' in sys.argv[2:]:
        for name in sorted(shapes):
            print('shape %s %s' % (name, shapes[name]))
    for b in bad[:20]:
        print(b)
    cnt = {s: sum(1 for v in shapes.values() if v == s) for s in ('D', 'S1', 'S2')}
    print('%d functions checked (D %d, S1 %d, S2 %d), %d do not conform' % (n, cnt['D'], cnt['S1'], cnt['S2'], len(bad)))
    return 0 if n and not bad else 1


if __name__ == '__main__':
    sys.exit(main())
