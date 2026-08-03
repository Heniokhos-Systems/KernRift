#!/usr/bin/env python3
"""arm64 reset stub: set SP, branch to the image entry. 16 bytes.

Loaded with `-device loader,file=...,addr=<base>,cpu-num=0` so the CPU
resets into it. The branch is a plain B (26-bit imm), so |entry - base|
must stay within +-128 MiB -- the gate's fixed addresses are 1 MiB apart.
Usage: make_stub.py <entry_va> <stub_base> <sp> <out.bin>
"""
import struct, sys

def stub(entry_va, base, sp):
    # REFUSE rather than wrap. Every one of these limits is silently
    # satisfiable today and stops being so the moment a leg moves an address
    # (leg 4 shifts the arm64 load address), at which point a wrapped
    # immediate would produce a stub that assembles fine and branches
    # somewhere arbitrary -- a boot failure presenting as "the program stayed
    # quiet", which is exactly what the absence controls would swallow.
    if not 0 <= sp < (1 << 32):
        raise SystemExit("make_stub: sp 0x%x needs more than 32 bits; movz/movk "
                         "here cover bits 31:0 only" % sp)
    if sp % 16:
        raise SystemExit("make_stub: sp 0x%x is not 16-byte aligned; aarch64 "
                         "faults on the first stack access" % sp)
    if entry_va % 4 or base % 4:
        raise SystemExit("make_stub: entry 0x%x / base 0x%x must be 4-byte "
                         "aligned" % (entry_va, base))
    delta = (entry_va - (base + 12)) >> 2
    if not -(1 << 25) <= delta < (1 << 25):
        raise SystemExit("make_stub: entry 0x%x is %d bytes from the stub at "
                         "0x%x; B reaches +-128 MiB" % (entry_va, entry_va - base, base))
    words = [
        0xd2a00000 | ((sp >> 16) & 0xffff) << 5,   # movz x0, #sp[31:16], lsl 16
        0xf2800000 | (sp & 0xffff) << 5,           # movk x0, #sp[15:0]
        0x9100001f,                                # mov sp, x0
        0x14000000 | (delta & 0x3ffffff),          # b <entry>
    ]
    return b"".join(struct.pack("<I", w) for w in words)

if __name__ == "__main__":
    entry, base, sp = (int(a, 0) for a in sys.argv[1:4])
    open(sys.argv[4], "wb").write(stub(entry, base, sp))
