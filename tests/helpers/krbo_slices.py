#!/usr/bin/env python3
"""krbo_slices.py FAT.krbo OUTDIR -- extract every slice of a KernRift fat binary.

An independent reimplementation of the runner's read path (spec 6.3, #143 A12):
- the KRBOFAT v2 container as compile_fat writes it (src/main.kr,
  src/format_archive.kr): "KRBOFAT\\0", u32 version 2, u32 entry count, then
  48-byte entries {u32 arch_id, u32 compression, u64 blob_offset,
  u64 blob_comp_size, u64 slice_uncomp_size, u64 slice_offset_in_pair,
  u64 pair_uncomp_size};
- LZ4 frames (magic 0x184D2204, FLG/BD/HC, blocks with the high bit marking
  an uncompressed block, end mark 0) and the LZ-Rift block format (LZ4's
  token/literal/match-length coding with 3-byte little-endian match offsets,
  src/runner.kr lz4_decompress_block_r);
- the inverse BCJ filter of src/bcj.kr (x86_64: e8/e9 rel32 back from absolute;
  arm64: b/bl imm26 back from absolute).

Writes OUTDIR/<name> for each slice (names below) and prints one line each:
"<name> <size> <sha256>". Exit 0 on success.
"""
import hashlib
import os
import struct
import sys

NAMES = {1: 'linux-x64', 2: 'linux-arm64', 3: 'win-x64', 4: 'win-arm64',
         5: 'mac-x64', 6: 'mac-arm64', 7: 'android-arm64', 8: 'android-x64'}
X86 = {1, 3, 5, 8}


def lz4_block(src, out_cap):
    out = bytearray()
    i = 0
    n = len(src)
    while i < n:
        tok = src[i]
        i += 1
        lit = tok >> 4
        if lit == 15:
            while True:
                b = src[i]
                i += 1
                lit += b
                if b != 255:
                    break
        out += src[i:i + lit]
        i += lit
        if i >= n:
            break
        off = src[i] | (src[i + 1] << 8) | (src[i + 2] << 16)       # LZ-Rift: 24-bit offsets
        i += 3
        if off == 0:
            raise ValueError('lz4: zero offset')
        ml = tok & 15
        if ml == 15:
            while True:
                b = src[i]
                i += 1
                ml += b
                if b != 255:
                    break
        ml += 4
        start = len(out) - off
        if start < 0:
            raise ValueError('lz4: offset before start')
        for k in range(ml):
            out.append(out[start + k])
    if len(out) > out_cap:
        raise ValueError('lz4: block larger than expected')
    return bytes(out)


def lz4_frame(b, cap):
    if struct.unpack_from('<I', b, 0)[0] != 0x184D2204:
        raise ValueError('lz4: bad frame magic')
    flg = b[4]
    pos = 6                                   # FLG, BD
    if flg & 0x08:
        pos += 8                              # content size
    pos += 1                                  # header checksum
    out = bytearray()
    while True:
        bs = struct.unpack_from('<I', b, pos)[0]
        pos += 4
        if bs == 0:
            break
        size = bs & 0x7FFFFFFF
        data = b[pos:pos + size]
        pos += size
        if bs & 0x80000000:
            out += data
        else:
            out += lz4_block(data, cap - len(out))
        if flg & 0x10:
            pos += 4                          # block checksum
        if pos >= len(b):
            break
    return bytes(out)


def unbcj_x86(buf):
    b = bytearray(buf)
    size = len(b)
    if size < 5:
        return bytes(b)
    i = 0
    while i < size - 4:
        if b[i] in (0xE8, 0xE9):
            rel = struct.unpack_from('<I', b, i + 1)[0]
            struct.pack_into('<I', b, i + 1, (rel - (i + 5)) & 0xFFFFFFFF)
            i += 4
        i += 1
    return bytes(b)


def unbcj_a64(buf):
    b = bytearray(buf)
    for i in range(0, len(b) - 3, 4):
        w = struct.unpack_from('<I', b, i)[0]
        op = w & 0xFC000000
        if op in (0x14000000, 0x94000000):
            target = ((w & 0x03FFFFFF) << 2) & 0xFFFFFFFF
            if w & 0x02000000:
                target |= 0xF0000000
            new = (((target - i) & 0xFFFFFFFF) >> 2) & 0x03FFFFFF
            struct.pack_into('<I', b, i, op | new)
    return bytes(b)


def slices(path):
    b = open(path, 'rb').read()
    if b[:8] != b'KRBOFAT\0' or struct.unpack_from('<I', b, 8)[0] != 2:
        raise SystemExit('error: %s is not a KRBOFAT v2 file' % path)
    n = struct.unpack_from('<I', b, 12)[0]
    out = {}
    cache = {}
    for k in range(n):
        aid, comp, off, csz, usz, roff, rlen = struct.unpack_from('<IIQQQQQ', b, 16 + 48 * k)
        if comp != 1:
            raise SystemExit('error: entry %d: compression %d' % (k, comp))
        if off not in cache:
            cache[off] = lz4_frame(b[off:off + csz], rlen)
        pair = cache[off]
        if len(pair) != rlen:
            raise SystemExit('error: entry %d: blob decodes to %d bytes, pair size %d' % (k, len(pair), rlen))
        raw = pair[roff:roff + usz]
        out[aid] = unbcj_x86(raw) if aid in X86 else unbcj_a64(raw)
    return out


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    os.makedirs(sys.argv[2], exist_ok=True)
    for aid, data in sorted(slices(sys.argv[1]).items()):
        name = NAMES.get(aid, 'arch%d' % aid)
        open(os.path.join(sys.argv[2], name), 'wb').write(data)
        print('%s %d %s' % (name, len(data), hashlib.sha256(data).hexdigest()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
