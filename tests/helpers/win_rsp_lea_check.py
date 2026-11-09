#!/usr/bin/env python3
"""win_rsp_lea_check.py LISTING... -- the frame-bias check of win-file-errors
(#136/#138/#170; its merge, spec 7.2 rule 3) on x86_64 --legacy Windows
listings (--test-listing): emit_win_rsp_lea gets final, cg_slot_off-biased
offsets and must add no bias of its own. In every p_*/s_* function, each
slot `lea` emitted by emit_win_rsp_lea must address the slot the function then
loads through the slot accessor (same displacement): a missing bias makes it
too small, a double bias too large by OUT; and disp32 must be used whenever the
offset is >= 0x80. The sites are found by their byte context, from the
function's bytes as the listing gives them:
  R2 (file_read):  41 89 c0 (mov r8d, eax) then lea r9, [rsp+D]
  S2 (file_size):  48 89 c1 (mov rcx, rax) then lea rdx, [rsp+D], then the
                   GetFileSizeEx call (ff 15), with or without sub rsp, 0x20
and the load is mov rax, [rsp+D] (48 8b 44 24 D / 48 8b 84 24 D32).
Exits 1 on any mismatch, or if no site was found."""
import re, sys
bad = n = 0
def le32(b): return int(''.join(reversed(b)), 16)
for path in sys.argv[1:]:
    funcs = {}; fn = None
    for l in open(path):
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*):\s*$', l)
        if m: fn = m.group(1); funcs[fn] = []; continue
        m = re.match(r'^\s+[0-9a-f]{8}:\s+((?:[0-9a-f]{2} ?)+)', l)
        if fn and m: funcs[fn] += m.group(1).split()
    for f, b in funcs.items():
        if not re.match(r'^[ps]_', f): continue
        s = ' '.join(b)
        for kind, pre, op8, op32 in (('R2 lea r9', '41 89 c0', '4c 8d 4c 24', '4c 8d 8c 24'),
                                     ('S2 lea rdx', '48 89 c1', '48 8d 54 24', '48 8d 94 24')):
            for m in re.finditer(pre + ' (' + op8 + ' ([0-9a-f]{2})|' + op32 + ' ((?:[0-9a-f]{2} ){3}[0-9a-f]{2}))', s):
                if m.group(2): d = int(m.group(2), 16); wide = False
                else: d = le32(m.group(3).split()); wide = True
                tail = s[m.end():]
                if kind.startswith('S2') and not re.match(r' (48 83 ec 20 )?ff 15', tail): continue
                ld = ('48 8b 84 24 ' + ' '.join('%02x' % ((d >> (8 * k)) & 255) for k in range(4))) if d >= 0x80 else ('48 8b 44 24 %02x' % d)
                ok = (ld in tail) and (wide == (d >= 0x80))
                n += 1; bad += not ok
                print('%s %s %s [rsp+0x%x] %s, load of the same slot later: %s -> %s' % (path.split('/')[-1], f, kind, d, 'disp32' if wide else 'disp8', 'yes' if ld in tail else 'NO', 'ok' if ok else 'BAD'))
print('win_rsp_lea_check: %d emit_win_rsp_lea sites checked, %d bad' % (n, bad))
sys.exit(1 if bad or n == 0 else 0)
