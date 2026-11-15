#!/usr/bin/env python3
"""container_kind.py FILE -- print one token naming the container of FILE.

Used by the c1_* rows of tests/run_tests.sh (tests/c1_matrix.lst) to say what a
krc command line produced. The token is read from the headers alone:

  elf-exec-<arch>     ELF ET_EXEC
  elf-android-<arch>  ELF ET_DYN whose PT_INTERP (found by walking the program
                      headers, not by searching the bytes) is /system/bin/linker
                      or /system/bin/linker64
  elf-dyn-<arch>      any other ET_DYN
  elf-rel-<arch>      ELF ET_REL (.o, .ko)
  macho-exe-<arch>    64-bit Mach-O MH_EXECUTE (magic 0xfeedfacf)
  macho-obj-<arch>    64-bit Mach-O MH_OBJECT
  pe-exe-<arch>       MZ + e_lfanew + "PE\\0\\0", by the COFF Machine field
  coff-obj-<arch>     a COFF object: Machine at offset 0
  krbo-<N>            a KernRift fat binary ("KRBOFAT\\0", N = entry count at +12)
  text                anything that decodes as ASCII (--emit=asm/ir listings)
  missing             FILE cannot be read
  unknown:<hex>       anything else, with its first 8 bytes

<arch> is x86_64, arm64, riscv32 or xtensa (other machines print their number).
krc emits no 32-bit or fat (universal) Mach-O, so 0xfeedface and 0xcafebabe are
"unknown" and fail any row expecting a Mach-O -- stated, not handled.
"""
import struct
import sys

ELF_MACHINE = {62: 'x86_64', 183: 'arm64', 243: 'riscv32', 94: 'xtensa'}
ANDROID_INTERP = (b'/system/bin/linker', b'/system/bin/linker64')


def elf_interp(b):
    """The PT_INTERP string of a little-endian ELF64/ELF32 image, or None."""
    cls = b[4]
    try:
        if cls == 2:
            phoff, = struct.unpack_from('<Q', b, 32)
            phentsize, phnum = struct.unpack_from('<HH', b, 54)
            for i in range(phnum):
                o = phoff + i * phentsize
                p_type, = struct.unpack_from('<I', b, o)
                if p_type == 3:
                    off, = struct.unpack_from('<Q', b, o + 8)
                    size, = struct.unpack_from('<Q', b, o + 32)
                    return b[off:off + size].rstrip(b'\0')
        elif cls == 1:
            phoff, = struct.unpack_from('<I', b, 28)
            phentsize, phnum = struct.unpack_from('<HH', b, 42)
            for i in range(phnum):
                o = phoff + i * phentsize
                p_type, off = struct.unpack_from('<II', b, o)
                if p_type == 3:
                    size, = struct.unpack_from('<I', b, o + 16)
                    return b[off:off + size].rstrip(b'\0')
    except struct.error:
        return None
    return None


def kind(path):
    try:
        with open(path, 'rb') as f:
            b = f.read()
    except OSError:
        return 'missing'
    if len(b) < 4:
        return 'unknown:' + b.hex()
    if b[:4] == b'\x7fELF' and len(b) >= 20:
        et, em = struct.unpack_from('<HH', b, 16)
        arch = ELF_MACHINE.get(em, 'em%d' % em)
        if et == 1:
            return 'elf-rel-' + arch
        if et == 2:
            return 'elf-exec-' + arch
        if et == 3:
            return ('elf-android-' if elf_interp(b) in ANDROID_INTERP else 'elf-dyn-') + arch
        return 'elf-type%d-%s' % (et, arch)
    if b[:8] == b'KRBOFAT\0' and len(b) >= 16:
        return 'krbo-%d' % struct.unpack_from('<I', b, 12)[0]
    magic, = struct.unpack_from('<I', b, 0)
    if magic == 0xfeedfacf and len(b) >= 16:
        cpu, _, filetype = struct.unpack_from('<iiI', b, 4)
        arch = {0x01000007: 'x86_64', 0x0100000c: 'arm64'}.get(cpu, 'cpu%x' % cpu)
        return {1: 'macho-obj-', 2: 'macho-exe-'}.get(filetype, 'macho-type%d-' % filetype) + arch
    if b[:2] == b'MZ' and len(b) >= 0x40:
        pe, = struct.unpack_from('<I', b, 0x3c)
        if b[pe:pe + 4] == b'PE\0\0' and len(b) >= pe + 6:
            mach, = struct.unpack_from('<H', b, pe + 4)
            return 'pe-exe-' + {0x8664: 'x86_64', 0xaa64: 'arm64'}.get(mach, 'm%x' % mach)
    if len(b) >= 20:
        mach, = struct.unpack_from('<H', b, 0)
        if mach == 0x8664:
            return 'coff-obj-x86_64'
        if mach == 0xaa64:
            return 'coff-obj-arm64'
    try:
        b.decode('ascii')
        return 'text'
    except UnicodeDecodeError:
        return 'unknown:' + b[:8].hex()


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.stderr.write('usage: container_kind.py FILE\n')
        sys.exit(2)
    print(kind(sys.argv[1]))
