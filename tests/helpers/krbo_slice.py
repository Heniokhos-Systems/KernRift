#!/usr/bin/env python3
"""Pull one slice out of a .krbo fat binary, exactly as the runner would.

  krbo_slice.py <krbo> <arch_id> <out>

Writes slice <arch_id> (KrboFat v2 ids: 1 linux-x64, 2 linux-arm64, 3 win-x64,
4 win-arm64, 5 macos-x64, 6 macos-arm64, 7 android-arm64, 8 android-x64),
decompressed and BCJ-unfiltered, to <out>. Only the single-slice layout that
`--targets=<one name>` writes is handled (pair_off 0); the default 8-slice
paired layout is refused rather than misread.

Decompression is KernRift's "LZ-Rift" block format (format_archive.kr,
lz4_compress_block): LZ4 framing and sequences, but a 24-bit match offset.
Exit status 2 on any malformed input, with the reason on stderr.
"""
import struct
import sys


def die(msg):
    sys.stderr.write("krbo_slice: " + msg + "\n")
    sys.exit(2)


def lzrift_block(src, out_len):
    out = bytearray()
    i = 0
    while i < len(src):
        tok = src[i]; i += 1
        lit = tok >> 4
        if lit == 15:
            while True:
                b = src[i]; i += 1; lit += b
                if b != 255:
                    break
        out += src[i:i + lit]; i += lit
        if i >= len(src):
            break
        off = src[i] | (src[i + 1] << 8) | (src[i + 2] << 16); i += 3
        if off == 0 or off > len(out):
            die("match offset %d outside %d decoded bytes" % (off, len(out)))
        ml = tok & 15
        if ml == 15:
            while True:
                b = src[i]; i += 1; ml += b
                if b != 255:
                    break
        ml += 4
        for _ in range(ml):
            out.append(out[-off])
    if len(out) != out_len:
        die("decoded %d bytes, header says %d" % (len(out), out_len))
    return bytes(out)


def frame(f, out_len):
    if struct.unpack_from("<I", f, 0)[0] != 0x184D2204:
        die("bad frame magic")
    p = 7  # magic + FLG + BD + HC
    out = b""
    while True:
        bs = struct.unpack_from("<I", f, p)[0]; p += 4
        if bs == 0:
            break
        n = bs & 0x7FFFFFFF
        blk = f[p:p + n]; p += n
        out += blk if bs >> 31 else lzrift_block(blk, out_len - len(out))
    if len(out) != out_len:
        die("frame decoded %d bytes, header says %d" % (len(out), out_len))
    return out


def bcj_x86_decode(b):   # inverse of bcj.kr filter_x86_64_bcj
    b = bytearray(b)
    i = 0
    while i < len(b) - 4:
        if b[i] in (0xE8, 0xE9):
            v = struct.unpack_from("<I", b, i + 1)[0]
            struct.pack_into("<I", b, i + 1, (v - (i + 5)) & 0xFFFFFFFF)
            i += 4
        i += 1
    return bytes(b)


def bcj_a64_decode(b):   # inverse of bcj.kr filter_aarch64_bcj
    b = bytearray(b)
    for i in range(0, len(b) - 3, 4):
        insn = struct.unpack_from("<I", b, i)[0]
        op = insn & 0xFC000000
        if op in (0x14000000, 0x94000000):
            target = ((insn & 0x3FFFFFF) << 2) & 0xFFFFFFFF
            rel = (target - i) & 0xFFFFFFFF
            struct.pack_into("<I", b, i, op | ((rel >> 2) & 0x3FFFFFF))
    return bytes(b)


def main():
    if len(sys.argv) != 4:
        die("usage: krbo_slice.py <krbo> <arch_id> <out>")
    d = open(sys.argv[1], "rb").read()
    aid = int(sys.argv[2])
    if d[:8] != b"KRBOFAT\0":
        die("not a KRBOFAT file")
    n = struct.unpack_from("<I", d, 12)[0]
    for i in range(n):
        a, comp, off, csize, usize = struct.unpack_from("<IIQQQ", d, 16 + i * 48)
        pair_off, pair_len = struct.unpack_from("<QQ", d, 16 + i * 48 + 32)
        if a != aid:
            continue
        if pair_off != 0 or pair_len != usize:
            die("slice %d is in a paired blob; build with --targets=<one>" % aid)
        raw = frame(d[off:off + csize], usize) if comp else d[off:off + usize]
        dec = bcj_x86_decode(raw) if aid in (1, 3, 5, 8) else bcj_a64_decode(raw)
        open(sys.argv[3], "wb").write(dec)
        return
    die("no slice with arch id %d" % aid)


if __name__ == "__main__":
    main()
