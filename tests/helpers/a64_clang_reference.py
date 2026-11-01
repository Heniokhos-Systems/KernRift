#!/usr/bin/env python3
"""a64_clang_reference.py IMAGE LISTING -- #143 row pe_unwind_arm64_clang_reference.

An independent encoder for KernRift's Windows arm64 unwind codes: LLVM's.
For every DISTINCT prologue/epilogue shape among the image's non-naked
functions (the listing's labels give the functions; the prologue is the
instructions up to and including the low allocation, the epilogue the
single `sub sp, x29, #f` ... `ret`), an assembler file is written with the
same instruction words (`.inst`) and the `.seh_*` directive each one stands
for, and assembled by llvm-mc for aarch64-pc-windows-msvc. llvm-readobj's
decode of LLVM's .xdata for it must equal llvm-readobj's decode of KernRift's
record for the function: the same prologue opcodes and the same epilogue
opcodes (whether the epilog shares the prologue's codes or not).

Prints one line per mismatching shape and a summary; exit 0 when every
shape agrees.
"""
import os
import re
import struct
import subprocess
import sys
import tempfile

LINE = re.compile(r'^\s+([0-9a-f]{8}): ([0-9a-f]{8})(?:\s|$)')
LABEL = re.compile(r'^([A-Za-z_.$][\w.$@]*):\s*$')


def directive(w, x16):
    """(directive or None, new x16)"""
    if (w & 0xFFC003FF) == 0xD10003FF:                          # sub sp, sp, #imm
        return '.seh_stackalloc %d' % ((w >> 10) & 0xFFF), x16
    if (w & 0xFFC003FF) == 0x910003FF:                          # add sp, sp, #imm
        return '.seh_stackalloc %d' % ((w >> 10) & 0xFFF), x16
    if (w & 0xFFC003FF) == 0x910003FD:                          # add x29, sp, #f
        return '.seh_add_fp %d' % ((w >> 10) & 0xFFF), x16
    if (w & 0xFFC003FF) == 0xD10003BF:                          # sub sp, x29, #f
        return '.seh_add_fp %d' % ((w >> 10) & 0xFFF), x16
    if (w & 0xFF80001F) == 0xD2800010:                          # movz x16
        return '.seh_nop', ((w >> 5) & 0xFFFF) << (16 * ((w >> 21) & 3))
    if (w & 0xFF80001F) == 0xF2800010:                          # movk x16
        hw = (w >> 21) & 3
        return '.seh_nop', (x16 & ~(0xFFFF << (16 * hw))) | (((w >> 5) & 0xFFFF) << (16 * hw))
    if w in (0xCB3063FF, 0x8B3063FF):                           # sub/add sp, sp, x16
        return '.seh_stackalloc %d' % x16, x16
    if (w >> 5) & 31 == 31:
        imm7 = (w >> 15) & 0x7F
        imm7 = (imm7 - 128 if imm7 & 64 else imm7) * 8
        r1, r2 = w & 31, (w >> 10) & 31
        if (w & 0xFFC00000) in (0xA9000000, 0xA9400000):        # stp/ldp x
            if (r1, r2) == (29, 30):
                return '.seh_save_fplr %d' % imm7, x16
            return '.seh_save_regp x%d, %d' % (r1, imm7), x16
        if (w & 0xFFC00000) in (0x6D000000, 0x6D400000):        # stp/ldp d
            return '.seh_save_fregp d%d, %d' % (r1, imm7), x16
        if (w & 0xFFC00000) in (0xF9000000, 0xF9400000):        # str/ldr x
            return '.seh_save_reg x%d, %d' % (r1, ((w >> 10) & 0xFFF) * 8), x16
        if (w & 0xFFC00000) in (0xFD000000, 0xFD400000):        # str/ldr d
            return '.seh_save_freg d%d, %d' % (r1, ((w >> 10) & 0xFFF) * 8), x16
    return None, x16


def readobj(path):
    """{function start RVA or symbol: (prologue opcode list, [epilog opcode lists])}"""
    out = subprocess.run(['llvm-readobj', '--unwind', path], capture_output=True, text=True, check=True).stdout
    res, cur, sect = {}, None, None
    for line in out.split('\n'):
        s = line.strip()
        m = re.match(r'Function: (\S+)', s)
        if m:
            cur = [[], []]
            res[m.group(1)] = cur
            sect = None
            continue
        if cur is None:
            continue
        if s.startswith('Prologue ['):
            sect = 'p'
        elif s.startswith('Opcodes [') or s.startswith('Epilogue ['):
            sect = 'e'
            cur[1].append([])
        elif s == ']':
            sect = None
        m = re.match(r'(0x[0-9a-f]+)\s+;\s*(.*)$', s)
        if m and sect:
            (cur[0] if sect == 'p' else cur[1][-1]).append('%s %s' % (m.group(1), m.group(2).strip()))
    return res


PAIR = re.compile(r'^(stp|ldp) ([xd])(\d+), ([xd])(\d+), \[sp, #(\d+)\]$')


def meaning(codes):
    """The codes' meanings as llvm-readobj prints them (hex dropped), with
    LLVM's `save next` / `restore next` (0xE6: the register pair after the one the NEXT listed
    code saves, 16 bytes up) expanded -- an equivalent compression KernRift
    does not use."""
    out = [c.split(' ', 1)[1] if ' ' in c else c for c in codes]
    for k in range(len(out) - 1, -1, -1):
        if out[k] in ('save next', 'restore next'):
            if k + 1 >= len(out):
                return out
            m = PAIR.match(out[k + 1])
            if not m:
                return out
            op, c1, r1, c2, r2, off = m.groups()
            out[k] = '%s %s%d, %s%d, [sp, #%d]' % (op, c1, int(r1) + 2, c2, int(r2) + 2, int(off) + 16)
    return out


def main():
    image, listing = sys.argv[1], sys.argv[2]
    labels, words, naked = [], [], set()
    for line in open(listing, encoding='latin-1'):
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
            words.append(int(m.group(2), 16))
    ours = readobj(image)
    # our records keyed by function start: llvm-readobj prints "Function: 0x... ", map by order
    keys = list(ours.keys())
    shapes = {}
    fn_index = 0
    for k, (start, name) in enumerate(labels):
        end = labels[k + 1][0] if k + 1 < len(labels) else len(words)
        if end <= start:
            continue
        if name in naked:
            fn_index += 1
            continue
        w = words[start:end]
        # prologue: up to the low allocation (sub sp imm or sub sp, sp, x16) after add x29
        try:
            fp = next(i for i, x in enumerate(w) if (x & 0xFFC003FF) == 0x910003FD)
        except StopIteration:
            print('%s: no add x29, sp' % name)
            return 1
        p_end = fp + 1
        if p_end < len(w) and (w[p_end] & 0xFFC003FF) == 0xD10003FF:
            p_end += 1
        else:
            while p_end < len(w) and (w[p_end] & 0xFF00001F) in (0xD2800010, 0xF2800010) or \
                    (p_end < len(w) and (w[p_end] & 0xFF80001F) in (0xD2800010, 0xF2800010)):
                p_end += 1
            p_end += 1
        f = (w[fp] >> 10) & 0xFFF
        ep = [i for i, x in enumerate(w) if x == (0xD10003BF | (f << 10))]
        if len(ep) != 1:
            print('%s: %d epilogues' % (name, len(ep)))
            return 1
        e_end = ep[0]
        while e_end < len(w) and w[e_end] != 0xD65F03C0:
            e_end += 1
        shape = (tuple(w[:p_end]), tuple(w[ep[0]:e_end + 1]))
        if keys and fn_index < len(keys):
            shapes.setdefault(shape, (name, keys[fn_index]))
        fn_index += 1
    bad = 0
    with tempfile.TemporaryDirectory() as td:
        src = []
        for n, (shape, (name, key)) in enumerate(shapes.items()):
            pro, epi = shape
            src.append('        .text\n        .def s%d; .scl 2; .type 32; .endef\n        .globl s%d\n'
                       '        .p2align 2\n        .seh_proc s%d\ns%d:' % (n, n, n, n))
            x16 = 0
            for x in pro:
                d, x16 = directive(x, x16)
                src.append('        .inst 0x%08x' % x)
                if d is None:
                    print('%s: prologue word 0x%08x has no directive' % (name, x))
                    return 1
                src.append('        ' + d)
            src.append('        .seh_endprologue\n        .seh_startepilogue')
            for x in epi[:-1]:
                d, x16 = directive(x, x16)
                src.append('        .inst 0x%08x' % x)
                if d is None:
                    print('%s: epilogue word 0x%08x has no directive' % (name, x))
                    return 1
                src.append('        ' + d)
            src.append('        .seh_endepilogue\n        ret\n        .seh_endproc')
        s_path = os.path.join(td, 'ref.s')
        o_path = os.path.join(td, 'ref.obj')
        open(s_path, 'w').write('\n'.join(src) + '\n')
        p = subprocess.run(['llvm-mc', '-triple=aarch64-pc-windows-msvc', '-filetype=obj', s_path, '-o', o_path],
                           capture_output=True, text=True)
        if p.returncode != 0:
            print('llvm-mc failed: %s' % p.stderr[:300])
            return 1
        theirs = readobj(o_path)
        for n, (shape, (name, key)) in enumerate(shapes.items()):
            t = theirs.get('s%d' % n)
            o = ours.get(key)
            if t is None or o is None:
                print('%s: no record (%s)' % (name, 'llvm' if t is None else 'ours'))
                bad += 1
                continue
            if meaning(t[0]) != meaning(o[0]):
                print('%s: prologue codes differ: ours %s, llvm %s' % (name, o[0], t[0]))
                bad += 1
            # llvm may emit the epilog as its own codes or share them: compare the opcode lists
            te, oe = [meaning(x) for x in t[1]], [meaning(x) for x in o[1]]
            if te != oe:
                print('%s: epilogue codes differ: ours %s, llvm %s' % (name, oe, te))
                bad += 1
    print('%d distinct prologue/epilogue shapes, %d differ from LLVM\'s encoding' % (len(shapes), bad))
    return 0 if shapes and not bad else 1


if __name__ == '__main__':
    sys.exit(main())
