#!/usr/bin/env python3
"""arm64 reset stub: set SP, branch to the image entry. 16 bytes.

Loaded with `-device loader,file=...,addr=<base>,cpu-num=0` so the CPU
resets into it. The branch is a plain B (26-bit imm), so |entry - base|
must stay within +-128 MiB -- the gate's fixed addresses are 1 MiB apart.
Usage: make_stub.py <entry_va> <stub_base> <sp> <out.bin>
"""
import struct, sys

def stub(entry_va, base, sp):
    words = [
        0xd2a00000 | ((sp >> 16) & 0xffff) << 5,   # movz x0, #sp[31:16], lsl 16
        0xf2800000 | (sp & 0xffff) << 5,           # movk x0, #sp[15:0]
        0x9100001f,                                # mov sp, x0
    ]
    delta = (entry_va - (base + 12)) >> 2
    words.append(0x14000000 | (delta & 0x3ffffff)) # b <entry>
    return b"".join(struct.pack("<I", w) for w in words)

if __name__ == "__main__":
    entry, base, sp = (int(a, 0) for a in sys.argv[1:4])
    open(sys.argv[4], "wb").write(stub(entry, base, sp))
