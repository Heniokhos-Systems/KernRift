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
                     [--code-end HEX] [--functions NAME,...] [--verbose]
                     [--no-readobj]

--functions restricts C3..C6 to the named functions; --verbose lists every
problem instead of the first three.

FILE is a PE32+ image (MZ) or a COFF object. One line per rule:
  <rule>: PASS | <rule>: FAIL <reason> | <rule>: N/A <reason>
Exit status: 0 if every requested rule is PASS (a rule named with --rules that
is N/A is a failure); 1 otherwise; 2 on a usage or input error.

Rules (spec section 8.1):
  C0  listing bytes == image .text bytes (rip-relative disp32 and arm64
      adrp/add/ldr page fields are relocations: the listing holds them
      unresolved, the image resolved)
  C1  exception directory well-formed: an image's .pdata is exactly
      DataDirectory[3] (the RUNTIME_FUNCTION array alone) and every UnwindInfo
      RVA lies in a read-only .xdata (split layout; --oracle exempts the
      combined-layout prototypes), section
      flags, sizes, strictly ascending and non-overlapping entries, 4-aligned
      records, version/flags/counts, every code decodes; arm64: unpacked,
      FunctionLength == distance to the next entry (and to the end of code for
      the last one), epilog scopes inside the function, StartIndex inside the
      code bytes. The decode must equal llvm-readobj's.
  C2  records tile [first function, end of code) with no gap, one record per
      listed function at its label; the entry point, every direct call target
      and every function-address materialisation is a BeginAddress or a
      registered leaf begin inside the caller's own range.
  C3  prologue instructions map 1:1 to the codes, in order, at their exact
      offsets; an x64 frame that calls keeps RSP 16-aligned at its calls
      (8 + 8 x pushes + ALLOC = 0 mod 16); the frame pointer is established (x64: SET_FPREG/RBP, with no
      SAVE_NONVOL before it and only SAVE_NONVOL stores -- [rsp+d] or [rbp+d],
      d = the code's offset x 8 -- after it, ruling (b); arm64: set_fp/add_fp,
      followed only by SP allocation); every arm64 SP adjustment is a
      multiple of 16.
  C4  after the prologue nothing writes rbp/x29 except the epilogue's restore;
      every ret outside a leaf is preceded by the canonical epilogue (x64) or
      ends an epilog scope whose instructions match its codes (arm64); leaves
      do not write the frame register and are entered only by call/jmp.
  C4b stack-depth dataflow over each body's CFG: every path returns at the
      entry depth; ExitProcess calls (by import name) and jumps into dead-end
      leaves end a path; called leaves return at their own entry depth; a
      `uw-loops` pair is summarised as depth-neutral only if its bytes satisfy
      the balanced-loop rule (counter zeroed; either bottom-tested -- one push
      + one inc, one pop + `dec; jnz` -- or guarded top-tested, ruling (c) --
      one exit test then one push + one inc and `jmp` back; `test R,R; jz
      exit`, one pop + one dec and `jmp` back).
  C5  kind-1 (zero-code, naked) records exactly for the listing's `uw-naked`
      functions, which write neither RSP/SP nor rbp/x29 outside `uw-asm` bytes.
  C6  at every reachable instruction offset an unwind simulator, run with
      both the documented Windows rules and wine-9.0's (is_inside_epilog,
      interpret_epilog, its establisher-frame rule), must recover the return
      address slot, SP = entry SP (+8 on x64) and every described register;
      inside a called leaf an epilogue-shaped unwind may land on the leaf's
      return site, from which a second unwind must reach the caller.

Listing annotations read (emitted by the compiler for target_os == 2 only):
  ; uw-code-end <hex>                    end of code (start of strings/statics)
  ; uw-leaf <name> called|deadend <b>-<e>
  ; uw-loops <pl>-<ph> <ql>-<qh> <counter>
  ; uw-naked <fn>
  ; uw-asm <b>-<e>
All offsets are hex, relative to the start of .text (= listing offset 0).

--code-end HEX states the end of code for a listing made before the compiler
printed `; uw-code-end` (the committed prototype oracles); it overrides the
annotation. --code-end and --functions are escape hatches for those oracles
only: they are refused unless --oracle is given, and a rule restricted by
--functions says so in its PASS line.

Test-only knob: PE_UNWIND_CHECK_DISABLE=C1,C2 makes the named rules report PASS
without checking (`C6wine` instead drops only C6's Wine rule set). It exists so the selftest's red run (a checker with a rule
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
    # the last byte of a line may lack its trailing space (e.g. a lone `f3`)
    LINE_X86 = re.compile(r'^\s+([0-9a-f]{8}): ((?:[0-9a-f]{2}(?: |$))+)')
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
def exception_table(binr, rules_out, oracle=False):
    """Locate and decode the table; raises RuleFail (C1) on structural errors.
    An image must use the split layout (spec 6.1 as amended after the phase-2
    review, M1): .pdata holds exactly the RUNTIME_FUNCTION array (it starts at
    DataDirectory[3] and its VirtualSize is the directory size), and every
    UnwindInfo RVA lies in a read-only .xdata section. Only the committed
    prototype oracles (--oracle) predate it: they keep the records inside
    .pdata."""
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
        if not oracle and (rva != s.rva or s.vsize != size):
            raise RuleFail('.pdata (RVA 0x%x, VirtualSize 0x%x) is not exactly the exception directory '
                           '(0x%x+0x%x): it must hold only the RUNTIME_FUNCTION array' % (s.rva, s.vsize, rva, size))
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
            # (UnwindData's low two bits are the packed-record flag; a nonzero
            # flag is refused by A64Record.decode, so an unpacked .xdata RVA is
            # 4-aligned by construction and needs no separate check)
            if b % 4:
                raise RuleFail('entry %d: BeginAddress 0x%x is not 4-aligned' % (k, b))
        if binr.is_image and not oracle:
            xs = binr.section_at(u & ~3)
            if xs is None or xs.name != '.xdata' or xs.flags != 0x40000040:
                raise RuleFail('entry %d: UnwindInfo RVA 0x%x is in %s, want a .xdata section with '
                               'characteristics 0x40000040' % (k, u, 'no section' if xs is None else
                                                               '%s (0x%08x)' % (xs.name, xs.flags)))
        try:
            r.decode(binr)
        except RuleFail as ex:
            raise RuleFail('entry %d (0x%x): %s' % (k, b, ex))
        recs.append(r)
    return recs


def check_c1(binr, lst, recs):
    t = binr.text
    tend = t.rva + max(t.vsize, len(t.data)) if binr.is_image else t.rva + t.rawsize
    # order and overlap first, over the whole table, so a mis-sorted table is
    # reported as such rather than as a by-product (e.g. an arm64
    # FunctionLength that no longer reaches the next entry)
    for k, r in enumerate(recs):
        if k and not recs[k - 1].begin < r.begin:
            raise RuleFail('entries %d/%d not strictly ascending (0x%x, 0x%x)' % (k - 1, k, recs[k - 1].begin, r.begin))
    for k, r in enumerate(recs):
        if k and recs[k - 1].end > r.begin:
            raise RuleFail('entries %d/%d overlap ([..,0x%x) and [0x%x,..))' % (k - 1, k, recs[k - 1].end, r.begin))
    for k, r in enumerate(recs):
        if not (t.rva <= r.begin and r.end <= tend):
            raise RuleFail('entry %d: [0x%x,0x%x) is outside .text' % (k, r.begin, r.end))
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
    """llvm-readobj's decode of the image or object as it is. With .pdata
    holding exactly the RUNTIME_FUNCTION array (split layout, M1), llvm-readobj
    -- which dumps every section named .pdata as a RUNTIME_FUNCTION array --
    decodes exactly the real records; check_readobj requires the same count.
    An llvm-readobj failure fails the check."""
    arch = binr.arch
    try:
        p = subprocess.run(['llvm-readobj', '--unwind', binr.path], capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        return None
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
    if len(lr) != len(recs):
        raise RuleFail('llvm-readobj sees %d records, we decode %d' % (len(lr), len(recs)))
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
    if lst is not None and (lst.labels or binr.is_image):
        if lst.code_end is None:
            raise RuleFail('the listing has no `; uw-code-end` annotation')
        fns = [(t.rva + o, n) for o, n in lst.labels]
        code_end = t.rva + lst.code_end
        leaves = [(n, k, t.rva + b, t.rva + e) for n, k, b, e in lst.leaves]
    elif not binr.is_image:
        # an object: functions from its symbol table; a listing given with an
        # object carries annotations only
        fns = sorted((t.rva + o, n) for o, n in binr.object_functions().items())
        code_end = t.rva + t.rawsize
        leaves = [(n, k, t.rva + b, t.rva + e) for n, k, b, e in lst.leaves] if lst else []
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
# Imports (ExitProcess dead ends are decoded BY NAME, as pe_calls does)
# --------------------------------------------------------------------------
def import_slots(binr):
    """Images: {IAT slot RVA: imported name}. Objects: {} (see import_relocs)."""
    out = {}
    if not binr.is_image:
        return out
    rva, size = binr.dd.get(1, (0, 0))
    if not rva:
        return out
    k = 0
    while True:
        d = binr.read(rva + 20 * k, 20)
        ilt, _, _, name, iat = struct.unpack('<IIIII', d)
        if name == 0 and iat == 0:
            break
        src = ilt or iat
        j = 0
        while True:
            e = struct.unpack('<Q', binr.read(src + 8 * j, 8))[0]
            if e == 0:
                break
            if not e >> 63:
                hn = e & 0x7FFFFFFF
                nm = b''
                p = hn + 2
                while True:
                    c = binr.read(p, 1)
                    if c == b'\0':
                        break
                    nm += c
                    p += 1
                out[iat + 8 * j] = nm.decode('latin-1')
            j += 1
        k += 1
    return out


def import_relocs(binr):
    """Objects: {.text RVA of a relocated field: symbol name} for every
    relocation whose symbol is undefined (an import such as __imp_ExitProcess)."""
    out = {}
    if binr.is_image:
        return out
    t = binr.text
    for off, si, typ in t.relocs:
        sym = binr.symbols[si] if si < len(binr.symbols) else None
        if sym is not None and sym[2] == 0:
            out[t.rva + off] = sym[0]
    return out


def is_exitprocess(name):
    return name in ('ExitProcess', '__imp_ExitProcess')


# --------------------------------------------------------------------------
# x86_64 instruction semantics (bytes for control flow, llvm-objdump text for
# operands). Only what the frame rules need: RSP motion, frame-register and
# callee-saved writes, stack stores/loads, control transfers.
# --------------------------------------------------------------------------
X64_R64 = {}
for _i, _n in enumerate(['rax', 'rcx', 'rdx', 'rbx', 'rsp', 'rbp', 'rsi', 'rdi',
                         'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15']):
    X64_R64[_n] = _i
for _i, _n in enumerate(['eax', 'ecx', 'edx', 'ebx', 'esp', 'ebp', 'esi', 'edi']):
    X64_R64[_n] = _i
for _i, _n in enumerate(['ax', 'cx', 'dx', 'bx', 'sp', 'bp', 'si', 'di']):
    X64_R64[_n] = _i
for _i, _n in enumerate(['al', 'cl', 'dl', 'bl', 'spl', 'bpl', 'sil', 'dil']):
    X64_R64[_n] = _i
X64_R64.update({'ah': 0, 'ch': 1, 'dh': 2, 'bh': 3})
for _i in range(8, 16):
    for _s in ('d', 'w', 'b'):
        X64_R64['r%d%s' % (_i, _s)] = _i
X64_CALLEE = (3, 5, 6, 7, 12, 13, 14, 15)          # Win64 nonvolatile GPRs
X64_VOLATILE = (0, 1, 2, 8, 9, 10, 11)
X64_RO_FIRST = {'cmp', 'test', 'bt', 'push', 'ucomisd', 'ucomiss', 'comisd', 'comiss',
                'call', 'jmp', 'ret', 'nop', 'prefetcht0', 'prefetchnta', 'clflush',
                'ptest', 'vptest', 'lfence', 'mfence', 'sfence', 'pause', 'int3', 'ud2',
                'hlt', 'cpuid', 'rdtsc', 'syscall', 'leave', 'enter', 'pushfq', 'popfq'}


class XI:
    """One decoded x86_64 instruction."""
    __slots__ = ('a', 'n', 'b', 'mn', 'ops', 'kind', 'arg', 'tgt', 'writes')

    def __init__(self, a, n, b, text):
        self.a, self.n, self.b = a, n, b
        t = text.split('#')[0].strip()
        parts = t.split(None, 1)
        mn = parts[0] if parts else ''
        while mn in ('lock', 'rep', 'repe', 'repne', 'rex64', 'data16', 'cs', 'ds', 'notrack') and len(parts) > 1:
            parts = parts[1].split(None, 1)
            mn = parts[0]
        self.mn = mn
        self.ops = [o.strip() for o in parts[1].split(',')] if len(parts) > 1 else []
        self.kind, self.arg, self.tgt = 'other', None, None
        self.writes = set()
        self._classify()

    def reg(self, o):
        return X64_R64.get(o)

    def _classify(self):
        b, mn, ops = self.b, self.mn, self.ops
        end = self.a + self.n
        # control flow, from the bytes
        if b[0] == 0xE8 and self.n == 5:
            self.kind, self.tgt = 'call', end + s32(b, 1)
        elif b[0] == 0xE9 and self.n == 5:
            self.kind, self.tgt = 'jmp', end + s32(b, 1)
        elif b[0] == 0xEB and self.n == 2:
            self.kind, self.tgt = 'jmp', end + struct.unpack('<b', b[1:2])[0]
        elif 0x70 <= b[0] <= 0x7F and self.n == 2:
            self.kind, self.tgt = 'jcc', end + struct.unpack('<b', b[1:2])[0]
        elif b[0] == 0x0F and self.n == 6 and 0x80 <= b[1] <= 0x8F:
            self.kind, self.tgt = 'jcc', end + s32(b, 2)
        elif b[0] in (0xE3,) or mn in ('loop', 'loope', 'loopne', 'jrcxz', 'jecxz'):
            self.kind, self.tgt = 'jcc', end + struct.unpack('<b', b[-1:])[0]
            self.writes.add(1)
        elif b[0] == 0xFF and self.n == 6 and b[1] == 0x15:
            self.kind, self.arg = 'call_iat', (self.a + 2, end + s32(b, 2))
        elif b[0] == 0xFF and self.n == 6 and b[1] == 0x25:
            self.kind, self.arg = 'jmp_iat', (self.a + 2, end + s32(b, 2))
        elif mn == 'call':
            self.kind = 'call_ind'
        elif mn == 'jmp':
            self.kind = 'jmp_ind'
        elif b[0] in (0xC3, 0xC2) or (b[0] == 0xF3 and self.n == 2 and b[1] == 0xC3):
            self.kind = 'ret'
        elif mn == 'push':
            self.kind = 'push'
            r64 = ['rax', 'rcx', 'rdx', 'rbx', 'rsp', 'rbp', 'rsi', 'rdi'] + ['r%d' % k for k in range(8, 16)]
            self.arg = r64.index(ops[0]) if ops and ops[0] in r64 else None
        elif mn in ('pushfq', 'pushf'):
            self.kind, self.arg = 'push', None
        elif mn == 'pop':
            self.kind = 'pop'
            r = self.reg(ops[0]) if ops else None
            self.arg = r
            if r is not None:
                self.writes.add(r)
        elif mn in ('popfq', 'popf'):
            self.kind, self.arg = 'pop', None
        elif mn == 'leave':
            self.kind = 'rsp_other'
            self.writes.add(5)
        elif mn == 'enter':
            self.kind = 'rsp_other'
            self.writes.add(5)
        else:
            dst = ops[0] if ops else None
            if dst == 'rsp' and mn in ('sub', 'add') and len(ops) == 2 and re.match(r'^-?(0x[0-9a-f]+|\d+)$', ops[1]):
                v = int(ops[1], 0)
                self.kind, self.arg = ('sub_rsp' if mn == 'sub' else 'add_rsp'), v
            elif dst == 'rsp' and mn == 'and':
                self.kind = 'and_rsp'
            elif dst == 'rsp' and mn == 'lea' and len(ops) == 2:
                m = re.match(r'^\[(\w+)( ([+-]) (0x[0-9a-f]+|\d+))?\]$', ops[1].replace('qword ptr ', ''))
                if m and self.reg(m.group(1)) is not None:
                    d = int(m.group(4), 0) if m.group(2) else 0
                    self.kind, self.arg = 'lea_rsp', (self.reg(m.group(1)), -d if m.group(3) == '-' else d)
                else:
                    self.kind = 'rsp_other'
            elif dst == 'rsp' and mn == 'mov' and len(ops) == 2 and ops[1] in X64_R64:
                self.kind, self.arg = 'mov_rsp_reg', self.reg(ops[1])
            elif dst in ('rsp', 'esp', 'sp', 'spl') and mn not in X64_RO_FIRST:
                self.kind = 'rsp_other'
            elif mn == 'mov' and len(ops) == 2 and dst in X64_R64 and ops[1] == 'rsp':
                self.kind, self.arg = 'mov_reg_rsp', self.reg(dst)
                self.writes.add(self.reg(dst))
            elif mn == 'mov' and len(ops) == 2 and dst and dst.startswith('qword ptr [rsp') and ops[1] in X64_R64:
                m = re.match(r'^qword ptr \[rsp( \+ (0x[0-9a-f]+|\d+))?\]$', dst)
                if m:
                    self.kind, self.arg = 'store_rsp', (int(m.group(2), 0) if m.group(2) else 0, self.reg(ops[1]))
            elif mn == 'mov' and len(ops) == 2 and dst and dst.startswith('qword ptr [rbp') and ops[1] in X64_R64:
                # [rbp+d] store: a SAVE_NONVOL only in a prologue after
                # `mov rbp,rsp` (rbp == rsp there; C3 checks the position)
                m = re.match(r'^qword ptr \[rbp( \+ (0x[0-9a-f]+|\d+))?\]$', dst)
                if m:
                    self.kind, self.arg = 'store_rbp', (int(m.group(2), 0) if m.group(2) else 0, self.reg(ops[1]))
            elif mn == 'mov' and len(ops) == 2 and dst in X64_R64 and ops[1].startswith('qword ptr [rsp'):
                m = re.match(r'^qword ptr \[rsp( \+ (0x[0-9a-f]+|\d+))?\]$', ops[1])
                self.writes.add(self.reg(dst))
                if m:
                    self.kind, self.arg = 'load_rsp', (self.reg(dst), int(m.group(2), 0) if m.group(2) else 0)
            elif mn == 'xor' and len(ops) == 2 and ops[0] == ops[1] and ops[0] in X64_R64:
                self.kind, self.arg = 'zero', self.reg(ops[0])
                self.writes.add(self.reg(ops[0]))
            elif mn == 'mov' and len(ops) == 2 and dst in X64_R64 and ops[1] in X64_R64:
                self.kind, self.arg = 'mov_rr', (self.reg(dst), self.reg(ops[1]))
                self.writes.add(self.reg(dst))
            else:
                if dst in X64_R64 and mn not in X64_RO_FIRST:
                    self.writes.add(self.reg(dst))
                if mn in ('xchg', 'xadd', 'cmpxchg') and len(ops) == 2 and ops[1] in X64_R64:
                    self.writes.add(self.reg(ops[1]))
                if mn in ('cmpxchg',):
                    self.writes.add(0)
                if mn in ('div', 'idiv', 'mul', 'imul') and len(ops) == 1:
                    self.writes.update((0, 2))
                if mn in ('cqo', 'cdq', 'cwd'):
                    self.writes.add(2)
                if mn in ('cdqe', 'cwde', 'cbw'):
                    self.writes.add(0)
                if mn == 'cpuid':
                    self.writes.update((0, 1, 2, 3))
                if mn in ('rdtsc', 'rdtscp', 'rdmsr'):
                    self.writes.update((0, 2))
                if mn == 'syscall':
                    self.writes.update((0, 1, 11))
                if mn.startswith(('movs', 'stos', 'lods', 'scas', 'cmps')) and not ops:
                    self.writes.update((6, 7, 1))
        if self.kind in ('sub_rsp', 'add_rsp', 'and_rsp', 'lea_rsp', 'rsp_other', 'mov_rsp_reg', 'push', 'pop'):
            self.writes.add(4)


# --------------------------------------------------------------------------
# Symbolic machine state (x86_64 and arm64 share the shape)
#   sp   : int offset from S (the entry SP; S holds the return address on x64)
#          or None (unknown, e.g. after `and rsp,-16`)
#   regs : {reg: value}; value = ('orig', r) | ('sp', k) | ('ra',) | ('lr', a)
#          | ('zero',) | ('const', v) | ('unk',)
#   mem  : {offset: value}
# --------------------------------------------------------------------------
UNK = ('unk',)


class St:
    __slots__ = ('sp', 'regs', 'mem')

    def __init__(self, sp, regs, mem):
        self.sp, self.regs, self.mem = sp, regs, mem

    def copy(self):
        return St(self.sp, dict(self.regs), dict(self.mem))

    def key(self):
        return (self.sp, tuple(sorted(self.regs.items())))

    def r(self, k):
        return self.regs.get(k, UNK)


def st_join(old, new):
    """Join at a CFG merge. sp and registers must agree exactly (else the
    caller reports an inconsistent join); memory keeps the agreeing slots.
    Returns (state, changed) or None on disagreement."""
    if old.sp != new.sp:
        return None
    regs = {}
    for k in set(old.regs) | set(new.regs):
        a, b = old.r(k), new.r(k)
        regs[k] = a if a == b else UNK
    mem = {k: v for k, v in old.mem.items() if new.mem.get(k) == v}
    changed = regs != old.regs or mem != old.mem
    return St(old.sp, regs, mem), changed


class FnReport:
    """Per-rule problems found while analysing one function."""

    def __init__(self):
        self.p = {}

    def add(self, rule, msg):
        self.p.setdefault(rule, []).append(msg)


# --------------------------------------------------------------------------
# x86_64 analysis of one record
# --------------------------------------------------------------------------
class X64Fn:
    def __init__(self, ctx, rec, name, insns):
        self.ctx, self.r, self.name = ctx, rec, name
        self.insns = insns                      # [XI] inside [begin,end)
        self.at = {i.a: i for i in insns}
        self.rep = ctx.rep
        self.leaves = [lf for lf in ctx.leaves if rec.begin <= lf[2] and lf[3] <= rec.end]
        self.loops = [lp for lp in ctx.loops if rec.begin <= lp[0] and lp[3] <= rec.end]
        self.naked = rec.count == 0 and rec.prolog == 0 and rec.frame_reg == 0
        self.states = {}                        # addr -> St (function context)
        self.leaf_states = []                   # (leaf, callsite, {addr: St})

    def leaf_of(self, a):
        for lf in self.leaves:
            if lf[2] <= a < lf[3]:
                return lf
        return None

    # ---- C3: prologue == codes ---------------------------------------
    def c3(self):
        r = self.r
        if self.naked:
            return
        add = lambda m: self.rep.add('C3', '%s: %s' % (self.name, m))
        if r.frame_reg != 5 or r.frame_off != 0:
            add('FrameRegister %d / FrameOffset %d, want RBP / 0' % (r.frame_reg, r.frame_off))
        want = []          # (end offset, code) in prologue order
        ins = [i for i in self.insns if i.a < r.begin + r.prolog]
        if ins and ins[-1].a + ins[-1].n != r.begin + r.prolog:
            add('SizeOfProlog %d does not end on an instruction boundary' % r.prolog)
        fp_set = False
        for i in ins:
            off = i.a + i.n - r.begin
            # amended C3 (ruling (b)): with a frame register, SET_FPREG may be
            # followed only by SAVE_NONVOL stores ([rsp+d] or [rbp+d], rbp ==
            # rsp there), and no SAVE_NONVOL may come before it
            if fp_set and i.kind not in ('store_rsp', 'store_rbp'):
                add('prologue instruction at +0x%x (%s) follows SET_FPREG and is not a SAVE_NONVOL store'
                    % (i.a - r.begin, i.mn))
                return
            if i.kind == 'push' and i.arg is not None and i.b[0] != 0xFF:
                want.append((off, 'PUSH_NONVOL', i.arg))
            elif i.kind == 'sub_rsp':
                want.append((off, 'ALLOC', i.arg))
            elif i.kind in ('store_rsp', 'store_rbp'):
                if r.frame_reg != 0 and not fp_set:
                    add('SAVE_NONVOL store at +0x%x comes before SET_FPREG' % (i.a - r.begin))
                    return
                if i.kind == 'store_rbp' and not fp_set:
                    add('prologue [rbp+d] store at +0x%x before `mov rbp, rsp`' % (i.a - r.begin))
                    return
                want.append((off, 'SAVE_NONVOL', i.arg))
            elif i.kind == 'mov_reg_rsp' and i.arg == 5:
                want.append((off, 'SET_FPREG', 5))
                fp_set = True
            else:
                add('prologue instruction at +0x%x (%s) has no unwind code' % (i.a - r.begin, i.mn))
                return
        have = []
        for off, name, info, opnd in reversed(r.codes):
            if name == 'PUSH_NONVOL':
                have.append((off, name, info))
            elif name in ('ALLOC_SMALL', 'ALLOC_LARGE'):
                have.append((off, 'ALLOC', opnd))
            elif name == 'SAVE_NONVOL':
                have.append((off, name, (opnd, info)))
            elif name == 'SET_FPREG':
                have.append((off, name, r.frame_reg))
            else:
                have.append((off, name, info))
        if have != want:
            add('codes %s do not describe the prologue %s' % (have, want))
            return
        if not fp_set:
            add('the prologue has no SET_FPREG')
        # alignment (phase-2 review, M2): a frame that calls keeps RSP
        # 16-aligned at its call sites -- entry RSP is 8 mod 16, so the return
        # address, the pushes and the allocation must sum to 0 mod 16
        if any(i.kind in ('call', 'call_iat', 'call_ind') for i in self.insns):
            npush = sum(1 for _, name, _ in want if name == 'PUSH_NONVOL')
            alloc = sum(v for _, name, v in want if name == 'ALLOC')
            if (8 + 8 * npush + alloc) % 16 != 0:
                add('frame misaligns RSP at its calls: 8 + 8*%d pushes + ALLOC %d = %d, not 0 mod 16'
                    % (npush, alloc, 8 + 8 * npush + alloc))
        for off, name, info, opnd in r.codes:
            if name == 'ALLOC_SMALL' and not 8 <= opnd <= 128:
                add('ALLOC_SMALL %d out of range' % opnd)
            if name == 'ALLOC_LARGE' and info == 0 and opnd <= 128:
                add('ALLOC_LARGE/0 for a small size %d' % opnd)

    # ---- dataflow (C4b; states for C6) --------------------------------
    def entry_state(self):
        regs = {k: ('orig', k) for k in range(16)}
        regs[4] = ('sp', 0)
        return St(0, regs, {0: ('ra',)})

    def step(self, i, s, ctx_leaf):
        """Execute i on a copy of s. Returns (state_after, successors) where
        successors is a list of (addr, state); [] for a dead end/return."""
        t = s.copy()
        end = i.a + i.n
        k = i.kind

        def wr(r):
            t.regs[r] = UNK
        if k == 'push':
            if t.sp is not None:
                t.sp -= 8
                v = t.r(i.arg) if i.arg is not None else UNK
                t.mem[t.sp] = v
            return t, [(end, t)]
        if k == 'pop':
            if t.sp is not None:
                v = t.mem.get(t.sp, UNK)
                t.sp += 8
            else:
                v = UNK
            if i.arg is not None:
                t.regs[i.arg] = v
            return t, [(end, t)]
        if k == 'sub_rsp':
            t.sp = None if t.sp is None else t.sp - i.arg
            return t, [(end, t)]
        if k == 'add_rsp':
            t.sp = None if t.sp is None else t.sp + i.arg
            return t, [(end, t)]
        if k == 'and_rsp' or k == 'rsp_other':
            t.sp = None
            for w in i.writes:
                if w != 4:
                    wr(w)
            return t, [(end, t)]
        if k == 'lea_rsp':
            base, d = i.arg
            v = t.r(base)
            t.sp = v[1] + d if v[0] == 'sp' else None
            return t, [(end, t)]
        if k == 'mov_rsp_reg':
            v = t.r(i.arg)
            t.sp = v[1] if v[0] == 'sp' else None
            return t, [(end, t)]
        if k == 'mov_reg_rsp':
            t.regs[i.arg] = ('sp', t.sp) if t.sp is not None else UNK
            return t, [(end, t)]
        if k == 'store_rsp':
            d, rg = i.arg
            if t.sp is not None:
                t.mem[t.sp + d] = t.r(rg)
            return t, [(end, t)]
        if k == 'store_rbp':
            d, rg = i.arg
            fp = t.r(5)
            if fp[0] == 'sp' and fp[1] is not None:
                t.mem[fp[1] + d] = t.r(rg)
            return t, [(end, t)]
        if k == 'load_rsp':
            rg, d = i.arg
            t.regs[rg] = t.mem.get(t.sp + d, UNK) if t.sp is not None else UNK
            return t, [(end, t)]
        if k == 'mov_rr':
            d, sr = i.arg
            t.regs[d] = t.r(sr)
            return t, [(end, t)]
        if k == 'zero':
            t.regs[i.arg] = ('zero',)
            return t, [(end, t)]
        if k in ('call', 'call_iat', 'call_ind'):
            if k == 'call_iat' and self.ctx.iat_name(i) is not None and is_exitprocess(self.ctx.iat_name(i)):
                return t, []                         # ExitProcess: the path ends
            for v in X64_VOLATILE:
                wr(v)
            if t.sp is not None:
                for o in [o for o in t.mem if o < t.sp]:
                    del t.mem[o]
            return t, [(end, t)]
        if k == 'jmp':
            return t, [(i.tgt, t)]
        if k == 'jcc':
            for w in i.writes:
                wr(w)
            return t, [(end, t), (i.tgt, t)]
        if k in ('ret', 'jmp_ind', 'jmp_iat'):
            return t, []
        for w in i.writes:
            if w != 4:
                wr(w)
        return t, [(end, t)]

    def flow(self, entry_addr, entry, lo, hi, ctx_leaf=None):
        """Worklist dataflow from entry_addr inside [lo,hi). Returns
        ({addr: St}, [problems], [ret addrs reached with their state])."""
        states = {entry_addr: entry}
        work = [entry_addr]
        probs, rets = [], []
        loopmap = {lp[0]: lp for lp in self.loops}
        while work:
            a = work.pop()
            s = states[a]
            i = self.at.get(a)
            if i is None:
                probs.append('control reaches 0x%x, which is not an instruction of %s' % (a, self.name))
                continue
            if a in loopmap and ctx_leaf is None:
                lp = loopmap[a]
                if s.r(X64_R64[lp[4]]) != ('zero',):
                    probs.append('balanced loop at 0x%x entered with %s not known to be zero' % (a, lp[4]))
                t = s.copy()
                for x in self.insns:
                    if lp[0] <= x.a < lp[3]:
                        for w in x.writes:
                            if w != 4:
                                t.regs[w] = UNK
                # inside the region the depth is data-dependent: C6 still checks
                # every offset there, with RSP unknown (the frame pointer must
                # carry the unwind)
                inner = t.copy()
                inner.sp = None
                for x in self.insns:
                    if lp[0] < x.a < lp[3] and x.a not in states:
                        states[x.a] = inner
                succ = [(lp[3], t)]
                out = []
            else:
                t, succ = self.step(i, s, ctx_leaf)
                if i.kind == 'call' and ctx_leaf is None:
                    lf = self.leaf_of(i.tgt)
                    if lf is not None and lf[2] == i.tgt and lf[1] == 'called':
                        self.pending_leaf_calls.append((lf, i, s))
                if i.kind == 'ret':
                    rets.append((a, s))
                if i.kind == 'jmp' and ctx_leaf is None:
                    lf = self.leaf_of(i.tgt)
                    if lf is not None and lf[2] == i.tgt and lf[1] == 'deadend':
                        self.deadend_entries.append((lf, i, t))
            for na, ns in succ:
                if not lo <= na < hi:
                    probs.append('control leaves %s at 0x%x -> 0x%x' % (self.name, a, na))
                    continue
                if ctx_leaf is None:
                    lf = self.leaf_of(na)
                    if lf is not None and not (lf[2] <= a < lf[3]):
                        if na != lf[2] or self.at[a].kind not in ('jmp', 'jcc', 'call'):
                            probs.append('0x%x enters leaf %s at 0x%x other than by call/jmp to its begin' % (a, lf[0], na))
                            continue
                if na in states:
                    j = st_join(states[na], ns)
                    if j is None:
                        probs.append('inconsistent stack depth at 0x%x: %s vs %s (from 0x%x)'
                                     % (na, self._d(states[na].sp), self._d(ns.sp), a))
                        continue
                    js, ch = j
                    if ch:
                        states[na] = js
                        work.append(na)
                else:
                    states[na] = ns
                    work.append(na)
        return states, probs, rets

    def _d(self, sp):
        return 'unknown' if sp is None else '%d' % sp

    def analyse(self):
        """C4, C4b and the state model for C6."""
        r = self.r
        self.pending_leaf_calls, self.deadend_entries = [], []
        add4 = lambda m: self.rep.add('C4', '%s: %s' % (self.name, m))
        add4b = lambda m: self.rep.add('C4b', '%s: %s' % (self.name, m))
        # leaves are analysed from their own entries; the main flow must not
        # walk into them except through call/jmp at their begin
        states, probs, rets = self.flow(r.begin, self.entry_state(), r.begin, r.end)
        self.states = states
        for p in probs:
            add4b(p)
        # every function-level return: depth 0 at the epilogue, canonical shape
        for a, s in rets:
            if self.leaf_of(a) is not None:
                continue
            if s.sp != 0:
                add4b('ret at 0x%x with RSP at S%+d, want S (unbalanced path)' % (a, s.sp if s.sp is not None else 0))
            if not self.naked:
                self._canonical_epilogue(a, add4)
        # called leaves: from their own entry, bare ret at depth 0
        done = set()
        for lf, ci, s in self.pending_leaf_calls:
            key = (lf, ci.a)
            if key in done:
                continue
            done.add(key)
            e = s.copy()
            if e.sp is not None:
                e.sp -= 8
                e.mem[e.sp] = ('lr', ci.a + ci.n)
            ls, lp, lr = self.flow(lf[2], e, lf[2], lf[3], ctx_leaf=lf)
            for p in lp:
                add4b('leaf %s: %s' % (lf[0], p))
            for a, st in lr:
                if e.sp is None or st.sp != e.sp:
                    add4b('leaf %s: ret at 0x%x at depth %s relative to its entry, want 0'
                          % (lf[0], a, 'unknown' if st.sp is None or e.sp is None else st.sp - e.sp))
            self.leaf_states.append((lf, ci, ls))
        for lf, ji, s in self.deadend_entries:
            for a, st in states.items():
                if lf[2] <= a < lf[3] and self.at[a].kind == 'ret':
                    add4b('dead-end leaf %s reaches ret at 0x%x' % (lf[0], a))
        # C4: no frame-register write after the prologue except the epilogue's pop
        if not self.naked:
            for i in self.insns:
                if i.a < r.begin + r.prolog or 5 not in i.writes:
                    continue
                if i.kind == 'pop' and i.arg == 5 and self._in_canonical_epilogue(i.a):
                    continue
                add4('writes rbp at 0x%x (%s %s)' % (i.a, i.mn, ','.join(i.ops)))
        for lf in self.leaves:
            prev = [i for i in self.insns if i.a + i.n == lf[2]]
            if prev and prev[0].kind not in ('jmp', 'ret', 'jmp_iat', 'jmp_ind') and not \
               (prev[0].kind == 'call_iat' and is_exitprocess(self.ctx.iat_name(prev[0]) or '')):
                add4('falls through into leaf %s at 0x%x' % (lf[0], lf[2]))
            for i in self.insns:
                if lf[2] <= i.a < lf[3] and 5 in i.writes:
                    add4('leaf %s writes rbp at 0x%x' % (lf[0], i.a))

    def _epilogue_seq(self):
        """The canonical epilogue as (kind, arg) before `ret`."""
        r = self.r
        seq = []
        alloc = sum(c[3] for c in r.codes if c[1] in ('ALLOC_SMALL', 'ALLOC_LARGE'))
        if alloc:
            seq.append(('add_rsp', alloc))
        for off, name, info, opnd in r.codes:          # codes are reverse order
            if name == 'PUSH_NONVOL':
                seq.append(('pop', info))
        return seq

    def _canonical_epilogue(self, reta, add):
        seq = self._epilogue_seq()
        a = reta
        for kind, arg in reversed(seq):
            prev = [i for i in self.insns if i.a + i.n == a]
            if not prev or prev[0].kind != kind or prev[0].arg != arg:
                add('ret at 0x%x is not preceded by the canonical epilogue %s' % (reta, seq))
                return
            a = prev[0].a

    def _in_canonical_epilogue(self, addr):
        seq = self._epilogue_seq()
        for i in self.insns:
            if i.kind != 'ret' or self.leaf_of(i.a) is not None:
                continue
            a, ok, addrs = i.a, True, []
            for kind, arg in reversed(seq):
                prev = [x for x in self.insns if x.a + x.n == a]
                if not prev or prev[0].kind != kind or prev[0].arg != arg:
                    ok = False
                    break
                a = prev[0].a
                addrs.append(a)
            if ok and addr in addrs:
                return True
        return False

    # ---- C6: unwind simulation at every offset -----------------------
    def c6(self):
        add = lambda m: self.rep.add('C6', '%s: %s' % (self.name, m))
        r = self.r
        n = 0
        described = {c[2] for c in r.codes if c[1] in ('PUSH_NONVOL', 'SAVE_NONVOL')}
        if r.frame_reg:
            described.add(r.frame_reg)
        for a in sorted(self.states):
            s = self.states[a]
            lf = self.leaf_of(a)
            if lf is not None and lf[1] == 'called':
                continue                                # leaf contexts below
            for rule in self.ctx.c6_rules:
                n += 1
                msg = self._check_one(a, s, rule, described)
                if msg:
                    add('%s rule at +0x%x: %s' % (rule, a - r.begin, msg))
        for lf, ci, ls in self.leaf_states:
            for a in sorted(ls):
                s = ls[a]
                for rule in self.ctx.c6_rules:
                    n += 1
                    res = x64_unwind(self.ctx, r, a, s, rule)
                    if isinstance(res, str):
                        add('%s rule in leaf %s at 0x%x: %s' % (rule, lf[0], a, res))
                        continue
                    rip, rsp, regs = res
                    if rip == ('lr', ci.a + ci.n):
                        # R3-M4: one unwind lands on the leaf's return site;
                        # a second, from that state, must reach S
                        st2 = St(rsp[1] if rsp[0] == 'sp' else None, dict(s.regs), s.mem)
                        st2.regs.update(regs)
                        msg = self._check_one(ci.a + ci.n, st2, rule, described)
                        if msg:
                            add('%s rule in leaf %s at 0x%x (second unwind from the return site): %s'
                                % (rule, lf[0], a, msg))
                    else:
                        msg = self._verdict(res, described)
                        if msg:
                            add('%s rule in leaf %s at 0x%x: %s' % (rule, lf[0], a, msg))
        return n

    def _check_one(self, a, s, rule, described):
        res = x64_unwind(self.ctx, self.r, a, s, rule)
        if isinstance(res, str):
            return res
        return self._verdict(res, described)

    def _verdict(self, res, described):
        rip, rsp, regs = res
        if rip != ('ra',):
            return 'return address read as %s, want the slot at S' % (rip,)
        if rsp != ('sp', 8):
            return 'RSP after unwind %s, want S+8' % (rsp,)
        for g in sorted(described):
            if regs.get(g) != ('orig', g):
                return '%s restored as %s' % (X64_REGS[g], regs.get(g))
        return None


def x64_unwind(ctx, rec, pc, s, rule):
    """One RtlVirtualUnwind step at pc on state s. rule 'native' = documented
    Windows semantics; 'wine' = wine-9.0 dlls/ntdll/signal_x86_64.c
    (is_inside_epilog / interpret_epilog / RtlVirtualUnwind) transcribed.
    Returns (rip, rsp, regs) or an error string."""
    regs = dict(s.regs)
    rsp = ('sp', s.sp) if s.sp is not None else UNK

    def rd(v):
        if v[0] != 'sp':
            return UNK
        return s.mem.get(v[1], UNK)

    def add(v, d):
        return ('sp', v[1] + d) if v[0] == 'sp' else UNK
    b0 = rec.begin
    in_prolog = b0 <= pc < b0 + rec.prolog
    if not in_prolog and rec.count:
        ep = x64_epilogue(ctx, rec, pc, rule)
        if ep is not None:
            for kind, arg in ep:
                if kind == 'pop':
                    regs[arg] = rd(rsp)
                    rsp = add(rsp, 8)
                elif kind == 'add':
                    rsp = add(rsp, arg)
                elif kind == 'lea':
                    base, d = arg
                    v = regs.get(base, UNK)
                    rsp = ('sp', v[1] + d) if v[0] == 'sp' else UNK
                elif kind == 'ret':
                    rip = rd(rsp)
                    return rip, add(rsp, 8), regs
            return 'epilogue simulation fell off'
    poff = pc - b0 if in_prolog else 1 << 30
    if rec.frame_reg:
        fpv = s.regs.get(rec.frame_reg, UNK)
        frame_fp = ('sp', fpv[1] - 16 * rec.frame_off) if fpv[0] == 'sp' else ('reg', fpv)
    else:
        frame_fp = None
    if rule == 'wine':
        frame = frame_fp if frame_fp is not None else rsp
    else:
        setfp = [c[0] for c in rec.codes if c[1] == 'SET_FPREG']
        if frame_fp is not None and (not in_prolog or (setfp and poff >= setfp[0])):
            frame = frame_fp
        else:
            frame = rsp
    for off, name, info, opnd in rec.codes:
        if poff < off:
            continue
        if name == 'PUSH_NONVOL':
            regs[info] = rd(rsp)
            rsp = add(rsp, 8)
        elif name in ('ALLOC_SMALL', 'ALLOC_LARGE'):
            rsp = add(rsp, opnd)
        elif name == 'SET_FPREG':
            rsp = frame if frame[0] == 'sp' else UNK
        elif name == 'SAVE_NONVOL':
            regs[info] = rd(add(frame, opnd)) if frame[0] == 'sp' else UNK
        else:
            return 'unwind op %s not modelled' % name
    return rd(rsp), add(rsp, 8), regs


def x64_epilogue(ctx, rec, pc, rule):
    """If pc is inside an epilogue under `rule`, the epilogue as a list of
    (kind, arg) steps from pc; else None."""
    def byte(a, k=1):
        # bytes at a, zero-padded past the end of the section (a `ret` can be
        # the last byte of .text)
        sec = ctx.binr.section_at(a)
        if sec is None:
            return None
        o = a - sec.rva
        got = bytes(sec.data[o:o + k])
        return got + bytes(k - len(got))
    steps = []
    a = pc
    b = byte(a, 7)
    if b is None:
        return None
    if (b[0] & 0xF8) == 0x48:
        if b[1] == 0x81 and b[0] == 0x48 and b[2] == 0xC4:
            steps.append(('add', s32(b, 3)))
            a += 7
        elif b[1] == 0x83 and b[0] == 0x48 and b[2] == 0xC4:
            steps.append(('add', struct.unpack('<b', b[3:4])[0]))
            a += 4
        elif b[1] == 0x8D:
            if b[0] & 0x06 or ((b[2] >> 3) & 7) != 4 or (b[2] & 7) == 4:
                return None
            base = (b[2] & 7) + (b[0] & 1) * 8
            if rule == 'native' and base != rec.frame_reg:
                return None
            if (b[2] >> 6) == 1:
                steps.append(('lea', (base, struct.unpack('<b', b[3:4])[0])))
                a += 4
            elif (b[2] >> 6) == 2:
                steps.append(('lea', (base, s32(b, 3))))
                a += 7
            else:
                return None
    guard = 0
    while guard < 64:
        guard += 1
        c = byte(a, 2)
        if c is None:
            return None
        rex = 0
        if (c[0] & 0xF0) == 0x40:
            rex = c[0] & 0x0F
            a += 1
            c = byte(a, 2)
        if 0x58 <= c[0] <= 0x5F:
            steps.append(('pop', c[0] - 0x58 + (rex & 1) * 8))
            a += 1
            continue
        if c[0] in (0xC2, 0xC3) or (c[0] == 0xF3 and c[1] == 0xC3):
            steps.append(('ret', None))
            return steps
        if c[0] in (0xE9, 0xEB):
            d = byte(a, 5)
            tgt = a + 5 + s32(d, 1) if c[0] == 0xE9 else a + 2 + struct.unpack('<b', d[1:2])[0]
            inside = rec.begin <= tgt < rec.end
            if rule == 'wine':
                if inside:
                    a = tgt
                    continue
                return None
            # native: a jmp that leaves the function ends an epilogue (a tail
            # call: the return address is then at [rsp]); one that stays inside
            # is not an epilogue
            if inside:
                return None
            steps.append(('ret', None))
            return steps
        return None
    return None


# --------------------------------------------------------------------------
# C5 (both arches): naked records
# --------------------------------------------------------------------------
def in_asm(lst, t, a):
    return any(t.rva + b <= a < t.rva + e for b, e in lst.asm) if lst else False


# --------------------------------------------------------------------------
# arm64 analysis of one record
# --------------------------------------------------------------------------
def a64_sx(v, bits):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


class AI:
    """One decoded arm64 instruction (from the word)."""
    __slots__ = ('a', 'w', 'text', 'kind', 'arg', 'tgt', 'writes')

    def __init__(self, a, w, text):
        self.a, self.w, self.text = a, w, text
        self.kind, self.arg, self.tgt = 'other', None, None
        self.writes = set()
        self._classify()

    def _classify(self):
        w, a = self.w, self.a
        rd, rn = w & 31, (w >> 5) & 31
        top = w & 0xFF000000
        if (w & 0xFC000000) == 0x94000000:
            self.kind, self.tgt = 'bl', a + 4 * a64_sx(w & 0x3FFFFFF, 26)
            self.writes.add(30)
        elif (w & 0xFC000000) == 0x14000000:
            self.kind, self.tgt = 'b', a + 4 * a64_sx(w & 0x3FFFFFF, 26)
        elif (w & 0xFF000010) == 0x54000000:
            self.kind, self.tgt = 'bcc', a + 4 * a64_sx((w >> 5) & 0x7FFFF, 19)
        elif (w & 0x7E000000) == 0x34000000:
            self.kind, self.tgt = 'bcc', a + 4 * a64_sx((w >> 5) & 0x7FFFF, 19)
        elif (w & 0x7E000000) == 0x36000000:
            self.kind, self.tgt = 'bcc', a + 4 * a64_sx((w >> 5) & 0x3FFF, 14)
        elif (w & 0xFFFFFC1F) == 0xD63F0000:
            self.kind, self.arg = 'blr', rn
            self.writes.add(30)
        elif (w & 0xFFFFFC1F) == 0xD61F0000:
            self.kind = 'br'
        elif (w & 0xFFFFFC1F) == 0xD65F0000:
            self.kind = 'ret'
        elif top in (0x91000000, 0xD1000000) and (rd == 31 or rn == 31):
            imm = ((w >> 10) & 0xFFF) << (12 if (w >> 22) & 1 else 0)
            neg = top == 0xD1000000
            if rd == 31 and rn == 31:
                self.kind, self.arg = 'sp_add', -imm if neg else imm
            elif rd == 29 and rn == 31:
                self.kind, self.arg = 'fp_from_sp', -imm if neg else imm
                self.writes.add(29)
            elif rd == 31 and rn == 29:
                self.kind, self.arg = 'sp_from_fp', -imm if neg else imm
            elif rd == 31:
                self.kind = 'sp_other'
            else:
                self.kind, self.arg = 'reg_from_sp', (rd, -imm if neg else imm)
                self.writes.add(rd)
        elif (w & 0xFFE0FFFF) == 0xCB2063FF:
            self.kind, self.arg = 'sp_sub_reg', (w >> 16) & 31
        elif (w & 0xFF800000) in (0xD2800000, 0xF2800000, 0x92800000):
            hw = (w >> 21) & 3
            imm = ((w >> 5) & 0xFFFF) << (16 * hw)
            op = {0xD2800000: 'movz', 0xF2800000: 'movk', 0x92800000: 'movn'}[w & 0xFF800000]
            self.kind, self.arg = 'mov_imm', (rd, op, imm, 0xFFFF << (16 * hw))
            self.writes.add(rd)
        elif ((w >> 27) & 7) == 5 and ((w >> 25) & 1) == 0:
            # load/store pair: opc(31:30) V(26) mode(24:23) L(22)
            opc, v, mode, l = (w >> 30) & 3, (w >> 26) & 1, (w >> 23) & 3, (w >> 22) & 1
            scale = 8 if (opc == 2 and v == 0) or (opc == 1 and v == 1) else (16 if opc == 2 and v == 1 else 4)
            imm = a64_sx((w >> 15) & 0x7F, 7) * scale
            rt2 = (w >> 10) & 31
            if scale == 8 and mode in (1, 2, 3):
                self.kind = 'ldp' if l else 'stp'
                self.arg = ('d' if v else 'x', rd, rt2, rn, imm, {1: 'post', 2: 'off', 3: 'pre'}[mode])
                if l and not v:
                    self.writes.update((rd, rt2))
                if rn == 31 and mode != 2:
                    self.writes.add(31)
            else:
                if l and not v:
                    self.writes.update((rd, rt2))
        elif (w & 0xFFC00000) in (0xF9000000, 0xF9400000, 0xFD000000, 0xFD400000):
            l = (w >> 22) & 1
            v = (w >> 26) & 1
            self.kind = 'ldr' if l else 'str'
            self.arg = ('d' if v else 'x', rd, rn, ((w >> 10) & 0xFFF) * 8, 'off')
            if l and not v:
                self.writes.add(rd)
        elif (w & 0xFFE00400) in (0xF8000400, 0xF8400400, 0xFC000400, 0xFC400400):
            l = (w >> 22) & 1
            v = (w >> 26) & 1
            self.kind = 'ldr' if l else 'str'
            self.arg = ('d' if v else 'x', rd, rn, a64_sx((w >> 12) & 0x1FF, 9), 'pre' if (w >> 11) & 1 else 'post')
            if l and not v:
                self.writes.add(rd)
            if rn == 31:
                self.writes.add(31)
        elif (w & 0x9F000000) == 0x90000000:
            self.kind = 'adrp'
            imm = (((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3)
            self.arg = (rd, a64_sx(imm, 21) << 12)
            self.writes.add(rd)
        elif w == 0xD503201F:
            self.kind = 'nop'
        else:
            # generic data processing: Rd is written unless it is a store/compare
            t = self.text.split()
            mn = t[0] if t else ''
            if mn.startswith(('st', 'cmp', 'cmn', 'tst', 'b.', 'cb', 'tb', 'prfm', 'dmb', 'dsb', 'isb', 'hint', 'svc', 'msr', 'brk')):
                if mn.startswith(('stp', 'stx', 'stlx')) or mn in ('stxr', 'stlxr'):
                    if mn in ('stxr', 'stlxr', 'stxp', 'stlxp'):
                        self.writes.add(rd if False else (w >> 16) & 31)
            else:
                self.writes.add(rd)
            if mn.startswith('ld') and ((w >> 10) & 31) != rd and 'p' in mn[:3]:
                self.writes.add((w >> 10) & 31)
            if 'sp' in self.text.split(',')[0] and mn not in ('cmp', 'cmn', 'tst') and not mn.startswith('st'):
                self.kind = 'sp_other'
                self.writes.add(31)


def a64_insn_code(i, x16):
    """The unwind code an instruction stands for, as a comparable tuple."""
    k, g = i.kind, i.arg
    if k == 'sp_add':
        return ('alloc', abs(g))
    if k == 'sp_sub_reg' and g == 16 and x16 is not None:
        return ('alloc', x16)
    if k == 'mov_imm' and g[0] == 16:
        return ('nop',)
    if k == 'nop':
        return ('nop',)
    if k == 'fp_from_sp':
        return ('set_fp',) if g == 0 else ('add_fp', g)
    if k == 'sp_from_fp':
        return ('set_fp',) if g == 0 else ('add_fp', -g)
    if k in ('stp', 'ldp') and g[3] == 31:
        cls, r1, r2, _, imm, mode = g
        if cls == 'x' and (r1, r2) == (29, 30):
            if mode == 'off':
                return ('save_fplr', imm)
            return ('save_fplr_x', abs(imm))
        if cls == 'x' and r2 == r1 + 1 and 19 <= r1 <= 28:
            if mode == 'off':
                return ('save_regp', r1, imm)
            return ('save_regp_x', r1, abs(imm))
        if cls == 'd' and r2 == r1 + 1 and 8 <= r1 <= 14:
            if mode == 'off':
                return ('save_fregp', r1, imm)
            return ('save_fregp_x', r1, abs(imm))
        return ('bad-pair', g)
    if k in ('str', 'ldr') and g[2] == 31:
        cls, r1, _, imm, mode = g
        if cls == 'x' and 19 <= r1 <= 30:
            return ('save_reg', r1, imm) if mode == 'off' else ('save_reg_x', r1, abs(imm))
        if cls == 'd' and 8 <= r1 <= 15:
            return ('save_freg', r1, imm) if mode == 'off' else ('save_freg_x', r1, abs(imm))
    if k == 'ret':
        return ('end',)
    return None


def a64_harmless(i):
    """An instruction a `nop` unwind code may stand for: it moves no SP and
    writes no register the unwinder restores (x19-x30, d8-d15) nor x29."""
    if i.kind in ('sp_add', 'sp_other', 'sp_from_fp', 'sp_sub_reg', 'fp_from_sp', 'bl', 'blr', 'b', 'bcc',
                  'ret', 'br', 'stp', 'ldp', 'str', 'ldr'):
        return False
    return not any(19 <= w <= 31 for w in i.writes)


def a64_code_tuple(c):
    _, _, name, g = c
    if name in ('alloc_s', 'alloc_m', 'alloc_l'):
        return ('alloc', g)
    if name == 'save_r19r20_x':
        return ('save_regp_x', 19, g)
    if name in ('save_regp', 'save_regp_x', 'save_reg', 'save_reg_x', 'save_fregp', 'save_fregp_x',
                'save_freg', 'save_freg_x'):
        return (name,) + tuple(g)
    if name in ('save_fplr', 'save_fplr_x', 'add_fp'):
        return (name, g)
    return (name,)


A64_CALLEE = tuple(range(19, 31))
A64_D = tuple(range(8, 16))


class A64Fn:
    def __init__(self, ctx, rec, name, insns):
        self.ctx, self.r, self.name = ctx, rec, name
        self.insns = insns
        self.at = {i.a: i for i in insns}
        self.rep = ctx.rep
        self.leaves = [lf for lf in ctx.leaves if rec.begin <= lf[2] and lf[3] <= rec.end]
        self.pro = [c for c in rec.prolog if c[2] not in ('end', 'end_c')]
        self.naked = len(self.pro) == 0 and not rec.scopes and rec.single_epilog_index is None
        self.states = {}
        self.leaf_states = []

    def leaf_of(self, a):
        for lf in self.leaves:
            if lf[2] <= a < lf[3]:
                return lf
        return None

    def epilogs(self):
        """[(start addr, [code tuples incl. end])] for every epilog scope."""
        r = self.r
        out = []
        sc = list(r.scopes)
        if r.single_epilog_index is not None:
            codes = a64_decode_codes(r.codebytes, r.single_epilog_index)
            sc = [(r.flen - len(codes), r.single_epilog_index)]
        for so, sx in sc:
            codes = a64_decode_codes(r.codebytes, sx)
            out.append((r.begin + 4 * so, codes))
        return out

    def c3(self):
        r = self.r
        add = lambda m: self.rep.add('C3', '%s: %s' % (self.name, m))
        if self.naked:
            return
        n = len(self.pro)
        ins = self.insns[:n]
        x16 = None
        want = []
        for i in ins:
            if i.kind == 'mov_imm' and i.arg[0] == 16:
                x16 = i.arg[2] if i.arg[1] == 'movz' else ((x16 or 0) & ~i.arg[3]) | i.arg[2]
            c = a64_insn_code(i, x16)
            if c is None and a64_harmless(i):
                c = ('nop',)
            if c is None or c[0] == 'end':
                add('prologue instruction at +0x%x (%s) has no unwind code' % (i.a - r.begin, i.text))
                return
            want.append(c)
        have = [a64_code_tuple(c) for c in reversed(self.pro)]
        if have != want:
            add('prologue codes %s do not describe the prologue %s' % (have, want))
            return
        fr = [k for k, c in enumerate(want) if c[0] in ('set_fp', 'add_fp')]
        if not fr:
            add('no set_fp/add_fp: the frame pointer is not established')
        else:
            for c in want[fr[-1] + 1:]:
                if c[0] not in ('alloc', 'nop'):
                    add('%s follows the frame-establishing code' % (c,))
        for c in want:
            if c[0] == 'alloc' and c[1] % 16:
                add('SP adjustment %d is not a multiple of 16' % c[1])
        for start, codes in self.epilogs():
            for c in codes:
                t = a64_code_tuple(c)
                if t[0] == 'alloc' and t[1] % 16:
                    add('epilog SP adjustment %d is not a multiple of 16' % t[1])

    def entry_state(self):
        regs = {k: ('orig', k) for k in A64_CALLEE}
        regs[30] = ('ra',)
        for d in A64_D:
            regs[100 + d] = ('orig', 100 + d)
        return St(0, regs, {})

    def step(self, i, s):
        t = s.copy()
        nxt = i.a + 4
        k, g = i.kind, i.arg

        def addr(base, imm):
            if base == 31:
                return None if t.sp is None else t.sp + imm
            v = t.r(base)
            return v[1] + imm if v[0] == 'sp' else None

        def regv(cls, r):
            return t.r(100 + r) if cls == 'd' else (t.r(r) if r != 31 else ('zero',))

        def setr(cls, r, v):
            if cls == 'd':
                t.regs[100 + r] = v
            elif r != 31:
                t.regs[r] = v
        if k == 'sp_add':
            t.sp = None if t.sp is None else t.sp + g
        elif k == 'sp_from_fp':
            v = t.r(29)
            t.sp = v[1] + g if v[0] == 'sp' else None
        elif k == 'fp_from_sp':
            t.regs[29] = ('sp', t.sp + g) if t.sp is not None else UNK
        elif k == 'reg_from_sp':
            t.regs[g[0]] = ('sp', t.sp + g[1]) if t.sp is not None else UNK
        elif k == 'sp_sub_reg':
            v = t.r(g)
            t.sp = t.sp - v[1] if (t.sp is not None and v[0] == 'const') else None
        elif k == 'mov_imm':
            rd, op, imm, mask = g
            if op == 'movz':
                t.regs[rd] = ('const', imm)
            elif op == 'movk' and t.r(rd)[0] == 'const':
                t.regs[rd] = ('const', (t.r(rd)[1] & ~mask) | imm)
            else:
                t.regs[rd] = UNK
        elif k in ('stp', 'ldp'):
            cls, r1, r2, base, imm, mode = g
            ea = addr(base, 0 if mode == 'post' else imm)
            if k == 'stp':
                if ea is not None:
                    t.mem[ea] = regv(cls, r1)
                    t.mem[ea + 8] = regv(cls, r2)
            else:
                setr(cls, r1, t.mem.get(ea, UNK) if ea is not None else UNK)
                setr(cls, r2, t.mem.get(ea + 8, UNK) if ea is not None else UNK)
            if mode in ('pre', 'post') and base == 31:
                t.sp = None if t.sp is None else t.sp + imm
        elif k in ('str', 'ldr'):
            cls, r1, base, imm, mode = g
            ea = addr(base, 0 if mode == 'post' else imm)
            if k == 'str':
                if ea is not None:
                    t.mem[ea] = regv(cls, r1)
            else:
                setr(cls, r1, t.mem.get(ea, UNK) if ea is not None else UNK)
            if mode in ('pre', 'post') and base == 31:
                t.sp = None if t.sp is None else t.sp + imm
        elif k == 'sp_other':
            t.sp = None
        elif k in ('bl', 'blr'):
            if k == 'blr' and self.ctx.a64_iat_name(self, i) is not None and is_exitprocess(self.ctx.a64_iat_name(self, i)):
                return t, []
            for r in list(range(0, 19)) + [30]:
                t.regs[r] = UNK
            if t.sp is not None:
                for o in [o for o in t.mem if o < t.sp]:
                    del t.mem[o]
            return t, [(nxt, t)]
        elif k == 'b':
            return t, [(i.tgt, t)]
        elif k == 'bcc':
            return t, [(nxt, t), (i.tgt, t)]
        elif k in ('ret', 'br'):
            return t, []
        else:
            for wv in i.writes:
                if wv != 31:
                    t.regs[wv] = UNK
        return t, [(nxt, t)]

    def flow(self, entry_addr, entry, lo, hi, ctx_leaf=None):
        states = {entry_addr: entry}
        work = [entry_addr]
        probs, rets = [], []
        while work:
            a = work.pop()
            s = states[a]
            i = self.at.get(a)
            if i is None:
                probs.append('control reaches 0x%x outside %s' % (a, self.name))
                continue
            t, succ = self.step(i, s)
            if i.kind == 'ret':
                rets.append((a, s))
            if i.kind == 'bl' and ctx_leaf is None:
                lf = self.leaf_of(i.tgt)
                if lf is not None and lf[2] == i.tgt and lf[1] == 'called':
                    self.pending_leaf_calls.append((lf, i, s))
            for na, ns in succ:
                if not lo <= na < hi:
                    probs.append('control leaves %s at 0x%x -> 0x%x' % (self.name, a, na))
                    continue
                if ctx_leaf is None:
                    lf = self.leaf_of(na)
                    if lf is not None and not (lf[2] <= a < lf[3]):
                        if na != lf[2] or i.kind not in ('b', 'bcc', 'bl'):
                            probs.append('0x%x enters leaf %s at 0x%x other than by a branch to its begin' % (a, lf[0], na))
                            continue
                if na in states:
                    j = st_join(states[na], ns)
                    if j is None:
                        probs.append('inconsistent SP at 0x%x (%s vs %s, from 0x%x)' % (na, states[na].sp, ns.sp, a))
                        continue
                    js, ch = j
                    if ch:
                        states[na] = js
                        work.append(na)
                else:
                    states[na] = ns
                    work.append(na)
        return states, probs, rets

    def analyse(self):
        r = self.r
        self.pending_leaf_calls = []
        add4 = lambda m: self.rep.add('C4', '%s: %s' % (self.name, m))
        add4b = lambda m: self.rep.add('C4b', '%s: %s' % (self.name, m))
        states, probs, rets = self.flow(r.begin, self.entry_state(), r.begin, r.end)
        self.states = states
        for p in probs:
            add4b(p)
        eps = self.epilogs() if not self.naked else []
        ends = {}
        for start, codes in eps:
            ends[start + 4 * (len(codes) - 1)] = (start, codes)
        for a, s in rets:
            if self.leaf_of(a) is not None:
                continue
            if s.sp != 0:
                add4b('ret at 0x%x with SP at S%+d' % (a, s.sp if s.sp is not None else 0))
            if s.r(30) != ('ra',):
                add4b('ret at 0x%x with x30 = %s, not the return address' % (a, s.r(30)))
            if self.naked:
                continue
            if a not in ends:
                add4('ret at 0x%x is not the end of an epilog scope' % a)
                continue
            start, codes = ends[a]
            x16 = None
            for k, c in enumerate(codes):
                ins = self.at.get(start + 4 * k)
                got = a64_insn_code(ins, x16) if ins else None
                if got is None and ins is not None and a64_harmless(ins):
                    got = ('nop',)
                if got != a64_code_tuple(c):
                    add4('epilog at 0x%x: instruction %d is %s, its code says %s'
                         % (start, k, ins.text if ins else '?', a64_code_tuple(c)))
                    break
        n_pro = len(self.pro)
        epi_addrs = set()
        for start, codes in eps:
            epi_addrs.update(range(start, start + 4 * len(codes), 4))
        if not self.naked:
            for i in self.insns[n_pro:]:
                if 29 in i.writes and i.a not in epi_addrs:
                    add4('writes x29 at 0x%x (%s)' % (i.a, i.text))
        for lf in self.leaves:
            for i in self.insns:
                if lf[2] <= i.a < lf[3] and 29 in i.writes:
                    add4('leaf %s writes x29 at 0x%x' % (lf[0], i.a))
        done = set()
        for lf, ci, s in self.pending_leaf_calls:
            if (lf, ci.a) in done:
                continue
            done.add((lf, ci.a))
            e = s.copy()
            e.regs[30] = ('lr', ci.a + 4)
            ls, lp, lr = self.flow(lf[2], e, lf[2], lf[3], ctx_leaf=lf)
            for p in lp:
                add4b('leaf %s: %s' % (lf[0], p))
            for a, st in lr:
                if st.sp != e.sp or st.r(30) != ('lr', ci.a + 4):
                    add4b('leaf %s: ret at 0x%x unbalanced' % (lf[0], a))
            self.leaf_states.append((lf, ci, ls))

    def c6(self):
        add = lambda m: self.rep.add('C6', '%s: %s' % (self.name, m))
        r = self.r
        n = 0
        described = set()
        for c in self.pro:
            t = a64_code_tuple(c)
            if t[0] in ('save_regp', 'save_regp_x'):
                described.update((t[1], t[1] + 1))
            elif t[0] in ('save_reg', 'save_reg_x'):
                described.add(t[1])
            elif t[0] in ('save_fplr', 'save_fplr_x'):
                described.update((29,))
            elif t[0] in ('save_fregp', 'save_fregp_x'):
                described.update((100 + t[1], 101 + t[1]))
            elif t[0] in ('save_freg', 'save_freg_x'):
                described.add(100 + t[1])
        allst = [(a, s, None) for a, s in self.states.items()]
        for lf, ci, ls in self.leaf_states:
            allst += [(a, s, lf) for a, s in ls.items()]
        for a, s, lf in sorted(allst, key=lambda x: x[0]):
            if lf is None and self.leaf_of(a) is not None:
                continue
            n += 1
            res = a64_unwind(self, a, s)
            if isinstance(res, str):
                add('at +0x%x: %s' % (a - r.begin, res))
                continue
            pc, sp, regs = res
            if pc != ('ra',):
                add('at +0x%x%s: pc unwinds to %s' % (a - r.begin, ' (leaf %s)' % lf[0] if lf else '', pc))
            elif sp != ('sp', 0):
                add('at +0x%x: SP unwinds to %s, want S' % (a - r.begin, sp))
            else:
                for g in sorted(described):
                    if regs.get(g) != ('orig', g):
                        add('at +0x%x: %s restored as %s' % (a - r.begin, ('x%d' % g) if g < 100 else ('d%d' % (g - 100)), regs.get(g)))
                        break
        return n


def a64_unwind(fn, pc, s):
    r = fn.r
    regs = dict(s.regs)
    sp = ('sp', s.sp) if s.sp is not None else UNK

    def rd(v, o):
        return s.mem.get(v[1] + o, UNK) if v[0] == 'sp' else UNK

    def add(v, d):
        return ('sp', v[1] + d) if v[0] == 'sp' else UNK
    k = (pc - r.begin) // 4
    n_pro = len(fn.pro)
    codes = None
    if k < n_pro:
        codes = fn.r.prolog[n_pro - k:]
    else:
        for start, ecodes in fn.epilogs():
            so = (start - r.begin) // 4
            if so <= k < so + len(ecodes):
                codes = ecodes[k - so:]
                break
        if codes is None:
            codes = fn.r.prolog
    for c in codes:
        t = a64_code_tuple(c)
        nm = t[0]
        if nm == 'alloc':
            sp = add(sp, t[1])
        elif nm in ('save_regp', 'save_fregp'):
            b = t[1] + (100 if nm == 'save_fregp' else 0)
            regs[b], regs[b + 1] = rd(sp, t[2]), rd(sp, t[2] + 8)
        elif nm in ('save_regp_x', 'save_fregp_x'):
            b = t[1] + (100 if nm == 'save_fregp_x' else 0)
            regs[b], regs[b + 1] = rd(sp, 0), rd(sp, 8)
            sp = add(sp, t[2])
        elif nm in ('save_reg', 'save_freg'):
            regs[t[1] + (100 if nm == 'save_freg' else 0)] = rd(sp, t[2])
        elif nm in ('save_reg_x', 'save_freg_x'):
            regs[t[1] + (100 if nm == 'save_freg_x' else 0)] = rd(sp, 0)
            sp = add(sp, t[2])
        elif nm == 'save_fplr':
            regs[29], regs[30] = rd(sp, t[1]), rd(sp, t[1] + 8)
        elif nm == 'save_fplr_x':
            regs[29], regs[30] = rd(sp, 0), rd(sp, 8)
            sp = add(sp, t[1])
        elif nm == 'set_fp':
            v = regs.get(29, UNK)
            sp = v if v[0] == 'sp' else UNK
        elif nm == 'add_fp':
            v = regs.get(29, UNK)
            sp = ('sp', v[1] - t[1]) if v[0] == 'sp' else UNK
        elif nm == 'nop':
            pass
        elif nm in ('end', 'end_c'):
            return regs.get(30, UNK), sp, regs
        else:
            return 'code %s not modelled' % nm
    return 'no end code'


# --------------------------------------------------------------------------
# rule driver for C3..C6 (one pass over all functions, results per rule)
# --------------------------------------------------------------------------
class Ctx:
    def __init__(self, binr, lst, recs, insns, only):
        self.binr, self.lst, self.recs = binr, lst, recs
        self.rep = FnReport()
        t = binr.text
        self.leaves = [(n, k, t.rva + b, t.rva + e) for n, k, b, e in lst.leaves] if lst else []
        self.loops = [(t.rva + pl, t.rva + ph, t.rva + ql, t.rva + qh, c) for pl, ph, ql, qh, c in lst.loops] if lst else []
        self.slots = import_slots(binr)
        self.irel = import_relocs(binr)
        names = {}
        if lst is not None and lst.labels:
            names = {t.rva + o: n for o, n in lst.labels}
        elif not binr.is_image:
            names = {t.rva + o: n for o, n in binr.object_functions().items()}
        self.names = names
        self.only = only
        # test-only: PE_UNWIND_CHECK_DISABLE=C6wine drops the Wine rule set
        # (the A2 red run: a Wine-only case must then stop failing)
        dis = os.environ.get('PE_UNWIND_CHECK_DISABLE', '').split(',')
        self.c6_rules = ('native',) if 'C6wine' in dis else ('native', 'wine')
        self.fns = []
        for r in recs:
            nm = names.get(r.begin, 'fn@0x%x' % r.begin)
            if only and nm not in only:
                continue
            body = [x for x in insns if r.begin <= x[0] < r.end]
            if binr.arch == 'x86_64':
                f = X64Fn(self, r, nm, [XI(a, n, binr.read(a, n), txt) for a, n, txt in body])
            else:
                f = A64Fn(self, r, nm, [AI(a, u32(binr.read(a, 4), 0), txt) for a, n, txt in body])
            self.fns.append(f)

    def iat_name(self, i):
        field, tgt = i.arg
        if field in self.irel:
            return self.irel[field]
        return self.slots.get(tgt)

    def a64_iat_name(self, fn, i):
        # adrp x16, page; ldr x16, [x16, #off]; blr x16
        a = i.a
        p1, p2 = fn.at.get(a - 8), fn.at.get(a - 4)
        if p1 is None or p2 is None or p1.kind != 'adrp' or p2.kind != 'ldr':
            return None
        if a - 8 in self.irel:
            return self.irel[a - 8]
        rd, pagedelta = p1.arg
        page = ((self.binr.image_base + p1.a) & ~0xFFF) + pagedelta - self.binr.image_base
        return self.slots.get(page + p2.arg[3])

    def run(self, rules):
        self.counts = {}
        for f in self.fns:
            if 'C3' in rules:
                f.c3()
            if rules & {'C4', 'C4b', 'C6'}:
                f.analyse()
            if 'C6' in rules:
                self.counts['C6'] = self.counts.get('C6', 0) + f.c6()
        if 'C5' in rules:
            self.c5()
        if 'C4b' in rules:
            self.loop_rule()

    def c5(self):
        t = self.binr.text
        marked = set(self.lst.naked) if self.lst else set()
        for f in self.fns:
            if f.naked != (f.name in marked):
                self.rep.add('C5', '%s: %s record but %s in the listing' % (
                    f.name, 'kind-1 (naked)' if f.naked else 'frame', 'marked naked' if f.name in marked else 'not marked naked'))
                continue
            if not f.naked:
                continue
            for i in f.insns:
                if in_asm(self.lst, t, i.a):
                    continue
                if self.binr.arch == 'x86_64':
                    bad = 4 in i.writes or 5 in i.writes
                else:
                    bad = 31 in i.writes or 29 in i.writes or i.kind in ('sp_add', 'sp_other', 'sp_from_fp', 'sp_sub_reg')
                if bad:
                    self.rep.add('C5', '%s: naked body writes the stack/frame pointer at 0x%x' % (f.name, i.a))

    def loop_rule(self):
        """The byte rule of an annotated balanced loop pair (spec 8.1 C4b)."""
        if self.binr.arch != 'x86_64':
            for lp in self.loops:
                self.rep.add('C4b', 'uw-loops annotation on arm64 at 0x%x (no such loops exist)' % lp[0])
            return
        for pl, ph, ql, qh, cn in self.loops:
            f = [x for x in self.fns if x.r.begin <= pl < x.r.end]
            if not f:
                continue
            f = f[0]
            c = X64_R64.get(cn)
            add = lambda m: self.rep.add('C4b', '%s: loops at 0x%x: %s' % (f.name, pl, m))
            if c is None or c in (4, 5):
                add('counter %r' % cn)
                continue
            push = [i for i in f.insns if pl <= i.a < ph]
            pop = [i for i in f.insns if ql <= i.a < qh]
            mid = [i for i in f.insns if ph <= i.a < ql]
            if not push or not pop or push[-1].a + push[-1].n != ph or pop[-1].a + pop[-1].n != qh:
                add('annotation does not match instruction boundaries')
                continue

            def is_inc(i, d):
                return i.mn == ('inc' if d > 0 else 'dec') and i.ops == [cn]

            def is_step(i, d):
                # guarded form: `inc R` / `add R,1` (d>0), `dec R` / `sub R,1`
                return is_inc(i, d) or (i.mn == ('add' if d > 0 else 'sub') and len(i.ops) == 2
                                        and i.ops[0] == cn and i.ops[1] in ('1', '0x1'))

            def is_branch(i):
                return i.kind in ('jcc', 'jmp', 'call', 'call_iat', 'call_ind', 'ret')

            def one_push(body):
                return sum(1 for i in body if i.kind == 'push' and i.arg is not None) == 1 and \
                    sum(1 for i in body if 4 in i.writes) == 1

            def one_pop(body):
                return sum(1 for i in body if i.kind == 'pop' and i.arg is not None) == 1 and \
                    sum(1 for i in body if 4 in i.writes) == 1
            guarded = push[-1].kind == 'jmp' and push[-1].tgt == pl
            pop_exit = None
            if not guarded:
                # bottom-tested: the conditional back-edge is the last
                # instruction and the only branch; one 8-byte push, one inc
                if push[-1].kind != 'jcc' or push[-1].tgt != pl:
                    add('push loop is neither bottom-tested (a conditional branch back to its top as its last '
                        'instruction) nor guarded top-tested (an unconditional `jmp` back to its top)')
                if any(is_branch(i) for i in push[:-1]):
                    add('push loop has a branch or call before its back-edge')
                if not one_push(push):
                    add('push loop must contain exactly one 8-byte register push and no other RSP write')
                if sum(1 for i in push if is_inc(i, 1)) != 1 or sum(1 for i in push if c in i.writes) != 1:
                    add('push loop must increment %s exactly once and write it nowhere else' % cn)
                # pop loop: one pop, one dec, `dec c; jnz top` at the bottom
                if pop[-1].kind != 'jcc' or pop[-1].tgt != ql or pop[-1].b[0] not in (0x75,) and pop[-1].b[:2] != b'\x0f\x85':
                    add('pop loop does not end in `jnz` back to its top')
                if len(pop) < 2 or not is_inc(pop[-2], -1):
                    add('pop loop back-edge is not taken on `dec %s`' % cn)
                if any(is_branch(i) for i in pop[:-1]):
                    add('pop loop has a branch or call before its back-edge')
                if not one_pop(pop):
                    add('pop loop must contain exactly one 8-byte register pop and no other RSP write')
                if sum(1 for i in pop if c in i.writes) != 1:
                    add('pop loop must write %s only in its dec' % cn)
            else:
                # guarded top-tested (spec 8.1 C4b, ruling (c)). Push loop: a
                # single cycle -- one exit test (any condition) leaving to the
                # code after the loop, then a straight line holding the one
                # 8-byte push and the one `inc R`, ending in `jmp` to the top.
                ex = [k for k, i in enumerate(push[:-1]) if is_branch(i)]
                if len(ex) != 1 or push[ex[0]].kind != 'jcc' or push[ex[0]].tgt != ph:
                    add('guarded push loop must have exactly one branch before its back-edge: a conditional '
                        'exit to 0x%x' % ph)
                else:
                    after = push[ex[0] + 1:-1]
                    if not one_push(push) or not one_push(after):
                        add('guarded push loop must contain exactly one 8-byte register push, after its exit '
                            'test, and no other RSP write')
                    if sum(1 for i in push if c in i.writes) != 1 or sum(1 for i in after if is_step(i, 1)) != 1:
                        add('guarded push loop must write %s only by one `inc %s` after its exit test' % (cn, cn))
                # pop loop: `test R,R` (or `cmp R,0`), then `jz`/`je` to its
                # only exit; a straight-line body with one 8-byte pop and one
                # `dec R`; an unconditional `jmp` back to the header.
                hd = pop[0] if pop else None
                if hd is None or not ((hd.mn == 'test' and hd.ops == [cn, cn]) or
                                      (hd.mn == 'cmp' and len(hd.ops) == 2 and hd.ops[0] == cn
                                       and hd.ops[1] in ('0', '0x0'))):
                    add('guarded pop loop does not start with `test %s, %s` (or `cmp %s, 0`)' % (cn, cn, cn))
                if len(pop) < 3 or pop[1].kind != 'jcc' or pop[1].tgt != qh or \
                   (pop[1].b[0] != 0x74 and pop[1].b[:2] != b'\x0f\x84'):
                    add('guarded pop loop header is not followed by `jz` to its exit 0x%x' % qh)
                else:
                    pop_exit = pop[1].a
                if pop[-1].kind != 'jmp' or pop[-1].tgt != ql:
                    add('guarded pop loop does not end in `jmp` back to its header')
                if any(is_branch(i) for i in pop[2:-1]):
                    add('guarded pop loop body is not straight-line')
                if not one_pop(pop):
                    add('pop loop must contain exactly one 8-byte register pop and no other RSP write')
                if sum(1 for i in pop if c in i.writes) != 1 or sum(1 for i in pop[2:-1] if is_step(i, -1)) != 1:
                    add('guarded pop loop must write %s only by one `dec %s` in its body' % (cn, cn))
            for i in mid:
                if c in i.writes or 4 in i.writes:
                    add('%s or RSP written between the loops at 0x%x' % (cn, i.a))
                if is_branch(i):
                    add('control transfer between the loops at 0x%x' % i.a)
            # single entry: nothing outside the region branches into it
            for g in f.insns:
                if g.tgt is not None and pl < g.tgt < qh and not (pl <= g.a < qh):
                    add('0x%x branches into the loop region at 0x%x' % (g.a, g.tgt))
                if g.tgt is not None and pl <= g.a < qh and not (pl <= g.tgt < qh) \
                   and not (g.a == pop_exit and g.tgt == qh):
                    add('0x%x branches out of the loop region' % g.a)


# --------------------------------------------------------------------------
# driver
# --------------------------------------------------------------------------
ALL_RULES = ['C0', 'C1', 'C2', 'C3', 'C4', 'C4b', 'C5', 'C6']


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument('--arch', required=True, choices=['x86_64', 'arm64'])
    ap.add_argument('--listing')
    ap.add_argument('--rules')
    ap.add_argument('--no-readobj', action='store_true')
    ap.add_argument('--code-end')
    ap.add_argument('--functions')
    ap.add_argument('--verbose', action='store_true')
    ap.add_argument('--oracle', action='store_true')
    ap.add_argument('file')
    a = ap.parse_args(argv)
    if (a.functions or a.code_end is not None) and not a.oracle:
        print('error: --functions and --code-end are for the committed prototype oracles only '
              '(listings made before the compiler printed annotations); add --oracle to use them',
              file=sys.stderr)
        return 2
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
    ctx = None
    only = set(a.functions.split(',')) if a.functions else None
    for rule in rules:
        if rule in disabled:
            print('%s: PASS (disabled by PE_UNWIND_CHECK_DISABLE)' % rule)
            continue
        try:
            if rule == 'C0':
                if lst is None:
                    raise RuleFail('needs --listing')
                msg = check_c0(binr, lst)
            else:
                if recs is None and c1_err is None:
                    try:
                        recs = exception_table(binr, None, a.oracle)
                    except RuleFail as ex:
                        c1_err = str(ex)
                if c1_err is not None:
                    raise RuleFail(c1_err if rule == 'C1' else 'no usable table (C1: %s)' % c1_err)
                if rule == 'C1':
                    msg = check_c1(binr, lst, recs)
                    if a.oracle and binr.is_image:
                        # the prototype oracles keep their records inside
                        # .pdata, which llvm-readobj walks as more entries
                        msg += ', combined-layout prototype (--oracle): no split rule, no llvm-readobj cross-check'
                    elif not a.no_readobj:
                        check_readobj(binr, recs)
                        msg += ', llvm-readobj agrees'
                else:
                    if insns is None:
                        insns = disassemble(binr)
                    if rule == 'C2':
                        msg = check_c2(binr, lst, recs, insns)
                    else:
                        if ctx is None:
                            ctx = Ctx(binr, lst, recs, insns, only)
                            ctx.run(set(rules) - disabled)
                        probs = ctx.rep.p.get(rule, [])
                        if probs and a.verbose:
                            for pr in probs:
                                print('  %s problem: %s' % (rule, pr))
                        if probs:
                            more = ' (+%d more)' % (len(probs) - 3) if len(probs) > 3 else ''
                            raise RuleFail('; '.join(probs[:3]) + more)
                        msg = '%d functions' % len(ctx.fns)
                        if only:
                            msg = 'restricted to %d functions by --functions (--oracle)' % len(ctx.fns)
                        if rule == 'C6':
                            msg += ', %d offset x rule-set unwinds' % ctx.counts.get('C6', 0)
            print('%s: PASS (%s)' % (rule, msg))
        except RuleFail as ex:
            ok = False
            print('%s: FAIL %s' % (rule, ex))
        except (struct.error, IndexError, KeyError, TypeError) as ex:
            ok = False
            print('%s: FAIL malformed data or unmodelled code (%s: %s)' % (rule, type(ex).__name__, ex))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
