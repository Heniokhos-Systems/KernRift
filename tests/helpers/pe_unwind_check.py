#!/usr/bin/env python3
"""pe_unwind_check.py -- independent checker for Windows unwind tables (#143).

This file is byte-identical in the KernRift and MLRift trees (spec 2026-10-26
section 8.1). It never trusts the compiler: it parses the PE image or COFF
object with `struct`, decodes .pdata/.xdata itself, cross-checks that decode
against `llvm-readobj --unwind`, and reads the compiler's `--emit=asm` listing
for LABELS, the BYTE COLUMN and the `; uw-...` annotation lines only (the
listing's mnemonic text is not trusted).

usage:
  pe_unwind_check.py --arch x86_64|arm64 FILE [--listing LST] [--rules C0,C1,...]
                     [--code-end HEX] [--no-readobj]

FILE is a PE32+ image (MZ) or a COFF object. One line per rule:
  <rule>: PASS | <rule>: FAIL <reason> | <rule>: N/A <reason>
Exit status: 0 if every requested rule is PASS (a rule named with --rules that
is N/A is a failure); 1 otherwise; 2 on a usage or input error.

Rules implemented here:
  C0  listing bytes == image .text bytes (rip-relative disp32 and arm64
      adrp/add/ldr page fields are relocations: the listing holds them
      unresolved, the image resolved)
  C1  exception directory well-formed: DataDirectory[3] inside .pdata, section
      flags, sizes, strictly ascending and non-overlapping entries, 4-aligned
      records, version/flags/counts, every code decodes; arm64: unpacked,
      FunctionLength == distance to the next entry (and to the end of code for
      the last one), epilog scopes inside the function, StartIndex inside the
      code bytes. The decode must equal llvm-readobj's.
  C2  records tile [first function, end of code) with no gap, one record per
      listed function at its label; the entry point, every direct call target
      and every function-address materialisation is a BeginAddress or a
      registered leaf begin inside the caller's own range.

Listing annotations read (emitted by the compiler for target_os == 2 only):
  ; uw-code-end <hex>                    end of code (start of strings/statics)
  ; uw-leaf <name> called|deadend <b>-<e>
  ; uw-loops <pl>-<ph> <ql>-<qh> <counter>
  ; uw-naked <fn>
  ; uw-asm <b>-<e>
All offsets are hex, relative to the start of .text (= listing offset 0).

--code-end HEX states the end of code for a listing made before the compiler
printed `; uw-code-end` (the committed prototype oracles); it overrides the
annotation.

Test-only knob: PE_UNWIND_CHECK_DISABLE=C1,C2 makes the named rules report PASS
without checking. It exists so the selftest's red run (a checker with a rule
disabled must fail that rule's negative) can be produced without editing this
file; nothing else sets it.
"""
import os
import re
import struct
import subprocess
import sys

IMAGE_REL_AMD64_ADDR32NB = 3
IMAGE_REL_AMD64_REL32 = 4
IMAGE_REL_ARM64_ADDR32NB = 2
IMAGE_REL_ARM64_BRANCH26 = 3
IMAGE_REL_ARM64_PAGEBASE_REL21 = 4
IMAGE_REL_ARM64_PAGEOFFSET_12A = 6
IMAGE_REL_ARM64_PAGEOFFSET_12L = 7

X64_REGS = ['RAX', 'RCX', 'RDX', 'RBX', 'RSP', 'RBP', 'RSI', 'RDI',
            'R8', 'R9', 'R10', 'R11', 'R12', 'R13', 'R14', 'R15']
X64_OPS = {0: 'PUSH_NONVOL', 1: 'ALLOC_LARGE', 2: 'ALLOC_SMALL', 3: 'SET_FPREG',
           4: 'SAVE_NONVOL', 5: 'SAVE_NONVOL_FAR', 8: 'SAVE_XMM128',
           9: 'SAVE_XMM128_FAR', 10: 'PUSH_MACHFRAME'}


class InputError(Exception):
    pass


class RuleFail(Exception):
    pass


def u16(b, o):
    return struct.unpack_from('<H', b, o)[0]


def u32(b, o):
    return struct.unpack_from('<I', b, o)[0]


def s32(b, o):
    return struct.unpack_from('<i', b, o)[0]


# --------------------------------------------------------------------------
# PE / COFF container
# --------------------------------------------------------------------------
class Section:
    def __init__(self, name, vsize, rva, rawsize, rawptr, relptr, nrel, flags):
        self.name, self.vsize, self.rva = name, vsize, rva
        self.rawsize, self.rawptr = rawsize, rawptr
        self.relptr, self.nrel, self.flags = relptr, nrel, flags
        self.data = b''
        self.relocs = []          # (offset, symbol index, type)


class Binary:
    """A PE image, or a COFF object laid out at synthetic RVAs with its
    relocations applied, so every consumer sees one address space (RVAs)."""

    def __init__(self, path, arch):
        self.path, self.arch = path, arch
        raw = open(path, 'rb').read()
        self.raw = raw
        if raw[:2] == b'MZ':
            self.is_image = True
            pe = u32(raw, 0x3C)
            if raw[pe:pe + 4] != b'PE\0\0':
                raise InputError('no PE signature')
            coff = pe + 4
        else:
            self.is_image = False
            coff = 0
        self.machine = u16(raw, coff)
        want = {'x86_64': 0x8664, 'arm64': 0xAA64}[arch]
        if self.machine != want:
            raise InputError('machine 0x%x is not %s' % (self.machine, arch))
        nsec = u16(raw, coff + 2)
        self.symptr, self.nsym = u32(raw, coff + 8), u32(raw, coff + 12)
        optsz = u16(raw, coff + 16)
        opt = coff + 20
        self.dd = {}
        if self.is_image:
            if u16(raw, opt) != 0x20B:
                raise InputError('not PE32+')
            self.entry = u32(raw, opt + 16)
            self.image_base = struct.unpack_from('<Q', raw, opt + 24)[0]
            ndd = u32(raw, opt + 108)
            for i in range(ndd):
                self.dd[i] = (u32(raw, opt + 112 + 8 * i), u32(raw, opt + 116 + 8 * i))
            self.dd_off = opt + 112
        else:
            self.entry = None
            self.image_base = 0
        st = opt + optsz
        self.sections = []
        for i in range(nsec):
            o = st + 40 * i
            name = raw[o:o + 8].rstrip(b'\0').decode('latin-1')
            vsize, rva, rawsize, rawptr, relptr = struct.unpack_from('<IIIII', raw, o + 8)
            nrel = u16(raw, o + 32)
            flags = u32(raw, o + 36)
            s = Section(name, vsize, rva, rawsize, rawptr, relptr, nrel, flags)
            s.hdr_off = o
            self.sections.append(s)
        if self.is_image:
            for s in self.sections:
                n = min(s.vsize, s.rawsize) if s.vsize else s.rawsize
                s.data = bytearray(raw[s.rawptr:s.rawptr + n]) + bytearray(max(0, s.vsize - n))
        else:
            self._load_object()
        self.text = self.section('.text')
        if self.text is None:
            raise InputError('no .text section')

    def section(self, name):
        for s in self.sections:
            if s.name == name:
                return s
        return None

    def section_at(self, rva):
        for s in self.sections:
            if s.rva <= rva < s.rva + max(len(s.data), s.vsize):
                return s
        return None

    def read(self, rva, n):
        s = self.section_at(rva)
        if s is None or rva + n > s.rva + len(s.data):
            raise RuleFail('RVA 0x%x+%d is outside every section' % (rva, n))
        o = rva - s.rva
        return bytes(s.data[o:o + n])

    # -- COFF object: synthetic layout + relocations ------------------------
    def _load_object(self):
        raw = self.raw
        self.symbols = []
        strtab = self.symptr + 18 * self.nsym
        i = 0
        while i < self.nsym:
            o = self.symptr + 18 * i
            if raw[o:o + 4] == b'\0\0\0\0':
                so = u32(raw, o + 4)
                e = raw.index(b'\0', strtab + so)
                name = raw[strtab + so:e].decode('latin-1')
            else:
                name = raw[o:o + 8].rstrip(b'\0').decode('latin-1')
            value, secno = u32(raw, o + 8), struct.unpack_from('<h', raw, o + 12)[0]
            typ, cls, naux = u16(raw, o + 14), raw[o + 16], raw[o + 17]
            self.symbols.append((name, value, secno, typ, cls))
            for _ in range(naux):
                self.symbols.append(None)
            i += 1 + naux
        rva = 0x1000
        for s in self.sections:
            s.rva = rva
            s.data = bytearray(raw[s.rawptr:s.rawptr + s.rawsize]) if s.rawptr else bytearray(s.rawsize)
            rva += (max(s.rawsize, 1) + 0xFFF) & ~0xFFF
            for k in range(s.nrel):
                ro = s.relptr + 10 * k
                s.relocs.append((u32(raw, ro), u32(raw, ro + 4), u16(raw, ro + 8)))
        for s in self.sections:
            for off, si, typ in s.relocs:
                sym = self.symbols[si] if si < len(self.symbols) else None
                if sym is None or sym[2] <= 0:
                    continue                      # undefined/absolute: leave as is
                tgt = self.sections[sym[2] - 1].rva + sym[1]
                if (self.arch == 'x86_64' and typ == IMAGE_REL_AMD64_ADDR32NB) or \
                   (self.arch == 'arm64' and typ == IMAGE_REL_ARM64_ADDR32NB):
                    struct.pack_into('<I', s.data, off, (u32(s.data, off) + tgt) & 0xFFFFFFFF)
                elif self.arch == 'x86_64' and typ == IMAGE_REL_AMD64_REL32:
                    v = s32(s.data, off) + tgt - (s.rva + off + 4)
                    struct.pack_into('<i', s.data, off, v)
                elif self.arch == 'arm64' and typ == IMAGE_REL_ARM64_BRANCH26:
                    w = u32(s.data, off)
                    imm = w & 0x3FFFFFF
                    if imm & 0x2000000:
                        imm -= 0x4000000
                    d = (tgt + imm * 4 - (s.rva + off)) >> 2
                    struct.pack_into('<I', s.data, off, (w & 0xFC000000) | (d & 0x3FFFFFF))

    def object_functions(self):
        """Function symbols defined in .text (objects only): {offset: name}."""
        ti = self.sections.index(self.text) + 1
        out = {}
        for sym in self.symbols:
            if sym is None:
                continue
            name, value, secno, typ, cls = sym
            if secno == ti and cls in (2, 3) and (typ >> 4) == 2:
                out.setdefault(value, name)
        return out


# --------------------------------------------------------------------------
# Listing (labels, byte column, annotations)
# --------------------------------------------------------------------------
class Listing:
    LINE_X86 = re.compile(r'^\s+([0-9a-f]{8}): ((?:[0-9a-f]{2} )+)')
    LINE_A64 = re.compile(r'^\s+([0-9a-f]{8}): ([0-9a-f]{8})(?:\s|$)')
    LABEL = re.compile(r'^([A-Za-z_.$][\w.$@]*):\s*$')

    def __init__(self, path, arch):
        self.labels = []           # (offset, name) in listing order
        self.code = bytearray()
        self.code_end = None
        self.leaves = []           # (name, kind, b, e)
        self.loops = []            # (pl, ph, ql, qh, counter)
        self.naked = []            # names
        self.asm = []              # (b, e)
        self.problems = []
        for n, line in enumerate(open(path, encoding='latin-1'), 1):
            line = line.rstrip('\n')
            m = (self.LINE_A64 if arch == 'arm64' else self.LINE_X86).match(line)
            if m:
                off = int(m.group(1), 16)
                if off != len(self.code):
                    self.problems.append('line %d: offset 0x%x, expected 0x%x' % (n, off, len(self.code)))
                if arch == 'arm64':
                    self.code += struct.pack('<I', int(m.group(2), 16))
                else:
                    self.code += bytes(int(x, 16) for x in m.group(2).split())
                continue
            m = self.LABEL.match(line)
            if m:
                self.labels.append((len(self.code), m.group(1)))
                continue
            if line.startswith('; uw-'):
                self._annotation(n, line)

    def _annotation(self, n, line):
        f = line[2:].split()
        try:
            if f[0] == 'uw-code-end' and len(f) == 2:
                self.code_end = int(f[1], 16)
            elif f[0] == 'uw-leaf' and len(f) == 4 and f[2] in ('called', 'deadend'):
                b, e = (int(x, 16) for x in f[3].split('-'))
                self.leaves.append((f[1], f[2], b, e))
            elif f[0] == 'uw-loops' and len(f) == 4:
                pl, ph = (int(x, 16) for x in f[1].split('-'))
                ql, qh = (int(x, 16) for x in f[2].split('-'))
                self.loops.append((pl, ph, ql, qh, f[3]))
            elif f[0] == 'uw-naked' and len(f) == 2:
                self.naked.append(f[1])
            elif f[0] == 'uw-asm' and len(f) == 2:
                b, e = (int(x, 16) for x in f[1].split('-'))
                self.asm.append((b, e))
            else:
                self.problems.append('line %d: malformed annotation %r' % (n, line))
        except ValueError:
            self.problems.append('line %d: malformed annotation %r' % (n, line))


# --------------------------------------------------------------------------
# Unwind records: x64
# --------------------------------------------------------------------------
class X64Record:
    """One RUNTIME_FUNCTION and its UNWIND_INFO (decoded here, not by llvm)."""

    def __init__(self, begin, end, uw):
        self.begin, self.end, self.uw = begin, end, uw

    def decode(self, binr):
        h = binr.read(self.uw, 4)
        self.version, self.flags = h[0] & 7, h[0] >> 3
        self.prolog, self.count = h[1], h[2]
        self.frame_reg, self.frame_off = h[3] & 15, h[3] >> 4
        raw = binr.read(self.uw + 4, 2 * self.count)
        self.size = 4 + 2 * ((self.count + 1) & ~1)
        self.bytes = binr.read(self.uw, self.size)
        self.codes = []           # (code_offset, opname, info, operand)
        i = 0
        while i < self.count:
            off, opi = raw[2 * i], raw[2 * i + 1]
            op, info = opi & 15, opi >> 4
            if op not in X64_OPS:
                raise RuleFail('record 0x%x: unknown unwind op %d' % (self.begin, op))
            name = X64_OPS[op]
            if op == 1:
                n = 2 if info == 0 else 3
                if i + n > self.count:
                    raise RuleFail('record 0x%x: ALLOC_LARGE overruns CountOfCodes' % self.begin)
                operand = u16(raw, 2 * i + 2) * 8 if info == 0 else u32(raw, 2 * i + 2)
                if info > 1:
                    raise RuleFail('record 0x%x: ALLOC_LARGE info %d' % (self.begin, info))
            elif op == 2:
                n, operand = 1, info * 8 + 8
            elif op in (4, 8):
                n = 2
                if i + n > self.count:
                    raise RuleFail('record 0x%x: SAVE overruns CountOfCodes' % self.begin)
                operand = u16(raw, 2 * i + 2) * (8 if op == 4 else 16)
            elif op in (5, 9):
                n = 3
                if i + n > self.count:
                    raise RuleFail('record 0x%x: SAVE_FAR overruns CountOfCodes' % self.begin)
                operand = u32(raw, 2 * i + 2)
            else:
                n, operand = 1, None
            self.codes.append((off, name, info, operand))
            i += n


# --------------------------------------------------------------------------
# Unwind records: arm64
# --------------------------------------------------------------------------
def a64_decode_codes(cb, start, stop_at_end=True):
    """Decode arm64 unwind code bytes from index `start`. Returns a list of
    (index, length, name, args); stops after `end`/`end_c`."""
    out = []
    i = start
    while i < len(cb):
        b = cb[i]
        if b < 0x20:
            out.append((i, 1, 'alloc_s', (b & 0x1F) * 16))
        elif b < 0x40:
            out.append((i, 1, 'save_r19r20_x', (b & 0x1F) * 8))
        elif b < 0x80:
            out.append((i, 1, 'save_fplr', (b & 0x3F) * 8))
        elif b < 0xC0:
            out.append((i, 1, 'save_fplr_x', ((b & 0x3F) + 1) * 8))
        elif b < 0xC8:
            if i + 1 >= len(cb):
                raise RuleFail('truncated alloc_m')
            out.append((i, 2, 'alloc_m', (((b & 7) << 8) | cb[i + 1]) * 16))
        elif b < 0xE0:
            if i + 1 >= len(cb):
                raise RuleFail('truncated two-byte code 0x%02x' % b)
            w = (b << 8) | cb[i + 1]
            z = w & 0x3F
            if b < 0xCC:
                out.append((i, 2, 'save_regp', (19 + ((w >> 6) & 0xF), z * 8)))
            elif b < 0xD0:
                out.append((i, 2, 'save_regp_x', (19 + ((w >> 6) & 0xF), (z + 1) * 8)))
            elif b < 0xD4:
                out.append((i, 2, 'save_reg', (19 + ((w >> 6) & 0xF), z * 8)))
            elif b < 0xD6:
                out.append((i, 2, 'save_reg_x', (19 + ((w >> 5) & 0xF), ((w & 0x1F) + 1) * 8)))
            elif b < 0xD8:
                out.append((i, 2, 'save_lrpair', (19 + 2 * ((w >> 6) & 7), z * 8)))
            elif b < 0xDA:
                out.append((i, 2, 'save_fregp', (8 + ((w >> 6) & 7), z * 8)))
            elif b < 0xDC:
                out.append((i, 2, 'save_fregp_x', (8 + ((w >> 6) & 7), (z + 1) * 8)))
            elif b < 0xDE:
                out.append((i, 2, 'save_freg', (8 + ((w >> 6) & 7), z * 8)))
            elif b == 0xDE:
                out.append((i, 2, 'save_freg_x', (8 + ((w >> 5) & 7), ((w & 0x1F) + 1) * 8)))
            else:
                raise RuleFail('unsupported code 0x%02x (alloc_z)' % b)
        elif b == 0xE0:
            if i + 3 >= len(cb):
                raise RuleFail('truncated alloc_l')
            out.append((i, 4, 'alloc_l', ((cb[i + 1] << 16) | (cb[i + 2] << 8) | cb[i + 3]) * 16))
        elif b == 0xE1:
            out.append((i, 1, 'set_fp', None))
        elif b == 0xE2:
            if i + 1 >= len(cb):
                raise RuleFail('truncated add_fp')
            out.append((i, 2, 'add_fp', cb[i + 1] * 8))
        elif b == 0xE3:
            out.append((i, 1, 'nop', None))
        elif b == 0xE4:
            out.append((i, 1, 'end', None))
        elif b == 0xE5:
            out.append((i, 1, 'end_c', None))
        elif b == 0xE6:
            out.append((i, 1, 'save_next', None))
        else:
            raise RuleFail('unsupported or reserved code 0x%02x' % b)
        i += out[-1][1]
        if stop_at_end and out[-1][2] in ('end', 'end_c'):
            return out
    raise RuleFail('code list from index %d has no end' % start)


class A64Record:
    def __init__(self, begin, unwind):
        self.begin, self.unwind = begin, unwind

    def decode(self, binr):
        if self.unwind & 3:
            raise RuleFail('function 0x%x: packed unwind data (flag %d); only full .xdata records are emitted'
                           % (self.begin, self.unwind & 3))
        x = self.unwind
        w = u32(binr.read(x, 4), 0)
        self.flen = w & 0x3FFFF
        self.vers, self.xbit, self.ebit = (w >> 18) & 3, (w >> 20) & 1, (w >> 21) & 1
        epc, cw = (w >> 22) & 0x1F, (w >> 27) & 0x1F
        o = x + 4
        if epc == 0 and cw == 0:
            e = u32(binr.read(o, 4), 0)
            epc, cw = e & 0xFFFF, (e >> 16) & 0xFF
            o += 4
        self.scopes = []
        if self.ebit:
            self.single_epilog_index = epc
        else:
            self.single_epilog_index = None
            for k in range(epc):
                s = u32(binr.read(o, 4), 0)
                if (s >> 18) & 0xF:
                    raise RuleFail('function 0x%x: epilog scope %d reserved bits set' % (self.begin, k))
                self.scopes.append((s & 0x3FFFF, (s >> 22) & 0x3FF))
                o += 4
        self.codebytes = binr.read(o, 4 * cw)
        o += 4 * cw
        if self.xbit:
            o += 4
        self.size = o - x
        self.bytes = binr.read(x, self.size)
        self.prolog = a64_decode_codes(self.codebytes, 0)
        self.end = self.begin + 4 * self.flen


# --------------------------------------------------------------------------
# Exception directory
# --------------------------------------------------------------------------
def exception_table(binr, rules_out):
    """Locate and decode the table; raises RuleFail (C1) on structural errors."""
    entsz = 12 if binr.arch == 'x86_64' else 8
    pdata = binr.section('.pdata')
    if binr.is_image:
        rva, size = binr.dd.get(3, (0, 0))
        if rva == 0 or size == 0:
            raise RuleFail('no exception directory (DataDirectory[3] is empty)')
        s = binr.section_at(rva)
        if s is None or s.name != '.pdata':
            raise RuleFail('DataDirectory[3] RVA 0x%x is not inside a .pdata section' % rva)
        if rva + size > s.rva + max(s.vsize, len(s.data)):
            raise RuleFail('DataDirectory[3] (0x%x+0x%x) overruns .pdata' % (rva, size))
        if s.flags != 0x40000040:
            raise RuleFail('.pdata characteristics 0x%08x, want 0x40000040' % s.flags)
    else:
        if pdata is None:
            raise RuleFail('no .pdata section')
        if pdata.flags != 0x40300040:
            raise RuleFail('.pdata characteristics 0x%08x, want 0x40300040' % pdata.flags)
        xdata = binr.section('.xdata')
        if xdata is not None and xdata.flags != 0x40300040:
            raise RuleFail('.xdata characteristics 0x%08x, want 0x40300040' % xdata.flags)
        rva, size = pdata.rva, pdata.rawsize
    if size % entsz:
        raise RuleFail('exception directory size %d is not a multiple of %d' % (size, entsz))
    if rva % 4:
        raise RuleFail('exception directory RVA 0x%x is not 4-aligned' % rva)
    raw = binr.read(rva, size)
    recs = []
    for k in range(size // entsz):
        if binr.arch == 'x86_64':
            b, e, u = struct.unpack_from('<III', raw, k * entsz)
            r = X64Record(b, e, u)
            if u % 4:
                raise RuleFail('entry %d: UnwindInfoAddress 0x%x is not 4-aligned' % (k, u))
            if not b < e:
                raise RuleFail('entry %d: Begin 0x%x >= End 0x%x' % (k, b, e))
        else:
            b, u = struct.unpack_from('<II', raw, k * entsz)
            r = A64Record(b, u)
            if (u & 3) == 0 and u % 4:
                raise RuleFail('entry %d: .xdata RVA 0x%x is not 4-aligned' % (k, u))
            if b % 4:
                raise RuleFail('entry %d: BeginAddress 0x%x is not 4-aligned' % (k, b))
        try:
            r.decode(binr)
        except RuleFail as ex:
            raise RuleFail('entry %d (0x%x): %s' % (k, b, ex))
        recs.append(r)
    return recs


def check_c1(binr, lst, recs):
    t = binr.text
    tend = t.rva + max(t.vsize, len(t.data)) if binr.is_image else t.rva + t.rawsize
    for k, r in enumerate(recs):
        if not (t.rva <= r.begin and r.end <= tend):
            raise RuleFail('entry %d: [0x%x,0x%x) is outside .text' % (k, r.begin, r.end))
        if k and not recs[k - 1].begin < r.begin:
            raise RuleFail('entries %d/%d not strictly ascending (0x%x, 0x%x)' % (k - 1, k, recs[k - 1].begin, r.begin))
        if k and recs[k - 1].end > r.begin:
            raise RuleFail('entries %d/%d overlap ([..,0x%x) and [0x%x,..))' % (k - 1, k, recs[k - 1].end, r.begin))
        if binr.arch == 'x86_64':
            if r.version != 1 or r.flags != 0:
                raise RuleFail('entry %d: UNWIND_INFO version %d flags %d, want 1/0' % (k, r.version, r.flags))
            if r.prolog > r.end - r.begin:
                raise RuleFail('entry %d: SizeOfProlog %d exceeds the function' % (k, r.prolog))
            for off, name, info, opnd in r.codes:
                if off > r.prolog:
                    raise RuleFail('entry %d: %s at offset %d is past SizeOfProlog %d' % (k, name, off, r.prolog))
            has_fp = any(c[1] == 'SET_FPREG' for c in r.codes)
            if has_fp != (r.frame_reg != 0):
                raise RuleFail('entry %d: FrameRegister %d but %s SET_FPREG code'
                               % (k, r.frame_reg, 'a' if has_fp else 'no'))
            if r.frame_reg == 0 and r.frame_off != 0:
                raise RuleFail('entry %d: FrameOffset %d without a frame register' % (k, r.frame_off))
        else:
            if r.vers != 0 or r.xbit != 0:
                raise RuleFail('entry %d: .xdata Vers %d X %d, want 0/0' % (k, r.vers, r.xbit))
            if r.flen == 0:
                raise RuleFail('entry %d: FunctionLength 0' % k)
            nxt = recs[k + 1].begin if k + 1 < len(recs) else None
            if nxt is None and lst is not None and lst.code_end is not None:
                nxt = t.rva + lst.code_end
            if nxt is None and not binr.is_image:
                nxt = t.rva + t.rawsize
            if nxt is not None and r.end != nxt:
                raise RuleFail('entry %d: FunctionLength %d words ends at 0x%x, the range ends at 0x%x'
                               % (k, r.flen, r.end, nxt))
            ncb = len(r.codebytes)
            for si, (so, sx) in enumerate(r.scopes):
                if so >= r.flen:
                    raise RuleFail('entry %d: epilog scope %d starts at word %d >= FunctionLength %d' % (k, si, so, r.flen))
                if sx >= ncb:
                    raise RuleFail('entry %d: epilog scope %d StartIndex %d >= %d code bytes' % (k, si, sx, ncb))
                a64_decode_codes(r.codebytes, sx)
            if r.single_epilog_index is not None:
                if r.single_epilog_index >= ncb:
                    raise RuleFail('entry %d: E-bit epilog index %d >= %d code bytes' % (k, r.single_epilog_index, ncb))
                a64_decode_codes(r.codebytes, r.single_epilog_index)
    return '%d records' % len(recs)


# --------------------------------------------------------------------------
# llvm-readobj cross-check (part of C1: our decode must equal llvm's)
# --------------------------------------------------------------------------
def readobj_records(binr):
    """llvm-readobj's decode. llvm-readobj (18) dumps a PE's whole .pdata
    SECTION, not the DataDirectory[3] extent, so with the .xdata records in the
    same section (spec ruling Q10) it prints the .xdata words as further
    "entries" after the real ones. The caller compares only the first
    DataDirectory[3].size / entry-size records; the rest are llvm reading past
    the table and are ignored (an llvm-readobj failure still fails the check)."""
    try:
        p = subprocess.run(['llvm-readobj', '--unwind', binr.path], capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        return None
    arch = binr.arch
    if p.returncode != 0:
        raise RuleFail('llvm-readobj --unwind failed: %s' % p.stderr.strip()[:200])
    out, cur = [], None
    for line in p.stdout.split('\n'):
        s = line.strip()
        if s == 'RuntimeFunction {':
            cur = {'codes': [], 'epi': [], 'scopes': [], 'packed': False}
            out.append(cur)
            continue
        if cur is None:
            continue
        if arch == 'x86_64':
            m = re.match(r'(PrologSize|UnwindCodeCount|Version): (\d+)', s)
            if m:
                cur[m.group(1)] = int(m.group(2))
            m = re.match(r'FrameRegister: \S+ \((0x[0-9A-Fa-f]+)\)', s)
            if m:
                cur['FrameRegister'] = int(m.group(1), 16)
            m = re.match(r'FrameOffset: (0x[0-9A-Fa-f]+)', s)
            if m:
                cur['FrameOffset'] = int(m.group(1), 16)
            m = re.match(r'0x([0-9A-F]{2}): ([A-Z_0-9]+)(.*)', s)
            if m:
                cur['codes'].append((int(m.group(1), 16), m.group(2), m.group(3).strip()))
            m = re.match(r'(StartAddress|EndAddress): .*\((0x[0-9A-Fa-f]+)\)$', s)
            if m:
                cur[m.group(1)] = int(m.group(2), 16)
        else:
            if s.startswith('Fragment:') or s.startswith('RegF:') or s.startswith('CR:'):
                cur['packed'] = True
            m = re.match(r'(FunctionLength|Version|EpilogueOffset|ByteCodeLength): (\d+)', s)
            if m:
                cur[m.group(1)] = int(m.group(2))
            m = re.match(r'Function: .*\((0x[0-9A-Fa-f]+)\)$', s)
            if m:
                cur['Function'] = int(m.group(1), 16)
            if s.startswith('Prologue ['):
                cur['_sect'] = 'codes'
            elif s.startswith('Epilogue ['):
                cur['_sect'] = 'epi'
            elif s.startswith('EpilogueScopes ['):
                cur['_sect'] = 'scopes'
            m = re.match(r'(0x[0-9a-f]+)\s+;', s)
            if m and cur.get('_sect') in ('codes', 'epi'):
                cur[cur['_sect']].append(m.group(1))
            m = re.match(r'StartOffset: (\d+)', s)
            if m:
                cur['scopes'].append([int(m.group(1))])
            m = re.match(r'EpilogueStartIndex: (\d+)', s)
            if m and cur['scopes']:
                cur['scopes'][-1].append(int(m.group(1)))
    return out


def a64_code_hex(cb, codes):
    return ['0x' + cb[i:i + n].hex() for i, n, _, _ in codes]


def check_readobj(binr, recs):
    lr = readobj_records(binr)
    if lr is None:
        raise RuleFail('llvm-readobj not available (use --no-readobj only where the row says why)')
    if len(lr) < len(recs) or (not binr.is_image and len(lr) != len(recs)):
        raise RuleFail('llvm-readobj sees %d records, we decode %d' % (len(lr), len(recs)))
    lr = lr[:len(recs)]
    for k, (r, l) in enumerate(zip(recs, lr)):
        if binr.arch == 'x86_64':
            mine = [(o, n) for o, n, _, _ in r.codes]
            theirs = [(o, n) for o, n, _ in l['codes']]
            if (l.get('PrologSize'), l.get('UnwindCodeCount'), l.get('FrameRegister', 0), l.get('FrameOffset', 0)) != \
               (r.prolog, r.count, r.frame_reg, r.frame_off) or mine != theirs:
                raise RuleFail('record %d (0x%x): decode differs from llvm-readobj (ours %s/%d/%d/%d, llvm %s)'
                               % (k, r.begin, mine, r.prolog, r.count, r.frame_reg, l))
            if binr.is_image and (l.get('StartAddress'), l.get('EndAddress')) != \
               (binr.image_base + r.begin, binr.image_base + r.end):
                raise RuleFail('record %d: llvm-readobj range differs' % k)
        else:
            if l['packed']:
                raise RuleFail('record %d: llvm-readobj decodes a packed record' % k)
            if l.get('FunctionLength') != r.flen * 4:
                raise RuleFail('record %d: FunctionLength llvm %s, ours %d' % (k, l.get('FunctionLength'), r.flen * 4))
            if l['codes'] != a64_code_hex(r.codebytes, r.prolog):
                raise RuleFail('record %d: prologue codes llvm %s, ours %s' % (k, l['codes'], a64_code_hex(r.codebytes, r.prolog)))
            if r.single_epilog_index is None:
                if [tuple(x) for x in l['scopes']] != [(so, sx) for so, sx in r.scopes]:
                    raise RuleFail('record %d: epilog scopes llvm %s, ours %s' % (k, l['scopes'], r.scopes))
            elif l.get('EpilogueOffset') != r.single_epilog_index:
                raise RuleFail('record %d: E-bit epilog index llvm %s, ours %d' % (k, l.get('EpilogueOffset'), r.single_epilog_index))


# --------------------------------------------------------------------------
# C0
# --------------------------------------------------------------------------
def check_c0(binr, lst):
    if lst.problems:
        raise RuleFail('listing: ' + '; '.join(lst.problems[:3]))
    t = binr.text.data
    a = lst.code
    if len(a) > len(t):
        raise RuleFail('listing has %d bytes, .text %d' % (len(a), len(t)))
    nrel = 0
    if binr.arch == 'x86_64':
        i = 0
        while i < len(a):
            if a[i] == t[i]:
                i += 1
                continue
            # a rip-relative disp32: the listing holds 0, the byte before it is a
            # ModRM with mod=00 rm=101, and the image value lands in the image.
            w = None
            for st in range(max(0, i - 3), i + 1):
                if st >= 1 and st + 4 <= len(a) and a[st:st + 4] == b'\0\0\0\0' and (a[st - 1] & 0xC7) == 0x05:
                    w = st
                    break
            if w is None:
                raise RuleFail('.text+0x%x: listing %02x, image %02x' % (i, a[i], t[i]))
            tgt = binr.text.rva + w + 4 + s32(t, w)
            if binr.section_at(tgt) is None:
                raise RuleFail('.text+0x%x: rip-relative field resolves outside the image (0x%x)' % (w, tgt))
            nrel += 1
            i = w + 4
    else:
        for i in range(0, len(a) - 3, 4):
            la, ta = u32(a, i), u32(t, i)
            if la == ta:
                continue
            ok = False
            if (la & 0x9F000000) == 0x90000000 and (la & 0x9F00001F) == (ta & 0x9F00001F):
                ok = True              # adrp: page delta
            elif i >= 4 and (u32(a, i - 4) & 0x9F000000) == 0x90000000 and (la & ~(0xFFF << 10)) & 0xFFFFFFFF == (ta & ~(0xFFF << 10)) & 0xFFFFFFFF:
                ok = True              # add/ldr/str imm12 after an adrp
            if not ok:
                raise RuleFail('.text+0x%x: listing %08x, image %08x' % (i, la, ta))
            nrel += 1
    return '%d bytes, %d relocated fields' % (len(a), nrel)


# --------------------------------------------------------------------------
# Disassembly (llvm-objdump; instruction boundaries + text) for C2..C6
# --------------------------------------------------------------------------
def disassemble(binr):
    args = ['llvm-objdump', '-d', '--section=.text']
    if binr.arch == 'x86_64':
        args.append('--x86-asm-syntax=intel')
    try:
        p = subprocess.run(args + [binr.path], capture_output=True, text=True, timeout=300)
    except FileNotFoundError:
        raise RuleFail('llvm-objdump not available')
    if p.returncode != 0:
        raise RuleFail('llvm-objdump failed: %s' % p.stderr.strip()[:200])
    base = binr.image_base if binr.is_image else 0
    tbase = binr.text.rva if binr.is_image else 0
    insns = []
    pat = re.compile(r'^\s*([0-9a-f]+):\s+((?:[0-9a-f]{2} )+|[0-9a-f]{8})\s*\t?(.*)$')
    for line in p.stdout.split('\n'):
        m = pat.match(line)
        if not m:
            continue
        addr = int(m.group(1), 16) - base
        if not binr.is_image:
            addr = addr - tbase + binr.text.rva
        hx = m.group(2).split()
        n = 4 if binr.arch == 'arm64' else len(hx)
        insns.append((addr, n, m.group(3).strip()))
    return insns


def direct_targets(binr, insns, code_lo, code_hi):
    """(site, target, kind) for every direct call / function-address
    materialisation inside [code_lo, code_hi), decoded from the bytes."""
    out = []
    t = binr.text
    if binr.arch == 'x86_64':
        for a, n, txt in insns:
            if not code_lo <= a < code_hi:
                continue
            b = binr.read(a, n)
            if b[0] == 0xE8 and n == 5:
                out.append((a, a + 5 + s32(b, 1), 'call'))
            elif n >= 7 and b[0] in (0x48, 0x4C) and b[1] == 0x8D and (b[2] & 0xC7) == 0x05:
                tgt = a + n + s32(b, 3)
                if code_lo <= tgt < code_hi:
                    out.append((a, tgt, 'lea'))
    else:
        page = {}
        for a, n, txt in insns:
            if not code_lo <= a < code_hi:
                continue
            w = u32(binr.read(a, 4), 0)
            if (w & 0xFC000000) == 0x94000000:
                imm = w & 0x3FFFFFF
                if imm & 0x2000000:
                    imm -= 0x4000000
                out.append((a, a + imm * 4, 'bl'))
            elif (w & 0x9F000000) == 0x90000000:
                imm = (((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3)
                if imm & 0x100000:
                    imm -= 0x200000
                pc = binr.image_base + a
                page[w & 31] = ((pc & ~0xFFF) + (imm << 12)) - binr.image_base
            elif (w & 0xFF800000) == 0x91000000 and ((w >> 5) & 31) in page:
                tgt = page.pop((w >> 5) & 31) + ((w >> 10) & 0xFFF)
                if code_lo <= tgt < code_hi:
                    out.append((a, tgt, 'adrp+add'))
        if not binr.is_image:
            # objects: branch/page relocations to .text symbols carry the target
            ti = binr.sections.index(t) + 1
            for off, si, typ in t.relocs:
                sym = binr.symbols[si] if si < len(binr.symbols) else None
                if sym is None or sym[2] != ti:
                    continue
                if typ in (IMAGE_REL_ARM64_PAGEBASE_REL21,):
                    out.append((t.rva + off, t.rva + sym[1], 'adrp-reloc'))
    return out


def check_c2(binr, lst, recs, insns):
    t = binr.text
    if lst is not None:
        if lst.code_end is None:
            raise RuleFail('the listing has no `; uw-code-end` annotation')
        fns = [(t.rva + o, n) for o, n in lst.labels]
        code_end = t.rva + lst.code_end
        leaves = [(n, k, t.rva + b, t.rva + e) for n, k, b, e in lst.leaves]
    elif not binr.is_image:
        fns = sorted((t.rva + o, n) for o, n in binr.object_functions().items())
        code_end = t.rva + t.rawsize
        leaves = []
    else:
        raise RuleFail('needs the listing (labels and end of code)')
    if not fns:
        raise RuleFail('no functions')
    begins = [r.begin for r in recs]
    if len(recs) != len(fns):
        raise RuleFail('%d records for %d functions' % (len(recs), len(fns)))
    for (fa, fname), r in zip(fns, recs):
        if r.begin != fa:
            raise RuleFail('function %s at 0x%x has no record starting there (record begins 0x%x)' % (fname, fa, r.begin))
    for k, r in enumerate(recs):
        nxt = recs[k + 1].begin if k + 1 < len(recs) else code_end
        if r.end != nxt:
            raise RuleFail('gap or overrun after %s: record ends 0x%x, next range starts 0x%x'
                           % (fns[k][1], r.end, nxt))
    for n, k, b, e in leaves:
        own = [r for r in recs if r.begin <= b and e <= r.end]
        if not own or b == own[0].begin:
            raise RuleFail('leaf %s [0x%x,0x%x) is not strictly inside one function' % (n, b, e))

    def owner(a):
        for r in recs:
            if r.begin <= a < r.end:
                return r
        return None
    bset = set(begins)
    if binr.is_image and binr.entry not in bset:
        raise RuleFail('entry point 0x%x is not a BeginAddress' % binr.entry)
    ntg = 0
    for site, tgt, kind in direct_targets(binr, insns, recs[0].begin, code_end):
        ntg += 1
        if tgt in bset:
            continue
        o = owner(site)
        if any(b == tgt and o is not None and o.begin <= b < o.end for _, _, b, _ in leaves):
            continue
        raise RuleFail('%s at 0x%x targets 0x%x, which is neither a BeginAddress nor a leaf of its function'
                       % (kind, site, tgt))
    return '%d records tile [0x%x,0x%x), %d direct targets' % (len(recs), recs[0].begin, code_end, ntg)


# --------------------------------------------------------------------------
# driver
# --------------------------------------------------------------------------
ALL_RULES = ['C0', 'C1', 'C2']


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument('--arch', required=True, choices=['x86_64', 'arm64'])
    ap.add_argument('--listing')
    ap.add_argument('--rules')
    ap.add_argument('--no-readobj', action='store_true')
    ap.add_argument('--code-end')
    ap.add_argument('file')
    a = ap.parse_args(argv)
    requested = a.rules.split(',') if a.rules else None
    rules = requested or [r for r in ALL_RULES if r != 'C0' or a.listing]
    for r in rules:
        if r not in ALL_RULES:
            print('unknown rule %s' % r, file=sys.stderr)
            return 2
    disabled = set(x for x in os.environ.get('PE_UNWIND_CHECK_DISABLE', '').split(',') if x)
    try:
        binr = Binary(a.file, a.arch)
        lst = Listing(a.listing, a.arch) if a.listing else None
        if a.code_end is not None:
            if lst is None:
                raise InputError('--code-end needs --listing')
            lst.code_end = int(a.code_end, 16)
    except (InputError, OSError, struct.error, ValueError) as ex:
        print('error: %s: %s' % (a.file, ex), file=sys.stderr)
        return 2
    ok = True
    recs = None
    c1_err = None
    insns = None
    for rule in rules:
        if rule in disabled:
            print('%s: PASS (disabled by PE_UNWIND_CHECK_DISABLE)' % rule)
            continue
        try:
            if rule == 'C0':
                if lst is None:
                    raise RuleFail('needs --listing')
                msg = check_c0(binr, lst)
            elif rule in ('C1', 'C2'):
                if recs is None and c1_err is None:
                    try:
                        recs = exception_table(binr, None)
                    except RuleFail as ex:
                        c1_err = str(ex)
                if c1_err is not None:
                    raise RuleFail(c1_err if rule == 'C1' else 'no usable table (C1: %s)' % c1_err)
                if rule == 'C1':
                    msg = check_c1(binr, lst, recs)
                    if not a.no_readobj:
                        check_readobj(binr, recs)
                        msg += ', llvm-readobj agrees'
                else:
                    if insns is None:
                        insns = disassemble(binr)
                    msg = check_c2(binr, lst, recs, insns)
            print('%s: PASS (%s)' % (rule, msg))
        except RuleFail as ex:
            ok = False
            print('%s: FAIL %s' % (rule, ex))
        except (struct.error, IndexError) as ex:
            ok = False
            print('%s: FAIL malformed data (%s)' % (rule, ex))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
