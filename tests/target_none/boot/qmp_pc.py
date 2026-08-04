#!/usr/bin/env python3
"""Print the guest's parked PC via a QMP unix socket.

Covers qemu-system-aarch64 (PC=) and qemu-system-x86_64 in BOTH modes:
RIP= in long mode, EIP= in 32-bit protected mode. Output is lower-case hex
WITHOUT 0x and without leading zeros, so callers compare against printf %x.
Exits 1 if no PC-shaped field is found.

WHY EIP IS ACCEPTED (B2 Task 5). The x86 entry stub starts in 32-bit
protected mode and only reaches long mode through its own trampoline, so a
boot that ENTERS PAST the trampoline never leaves 32-bit mode and `info
registers` prints EIP=, not RIP=. boot_gate.sh's L1_control_entry_addr_honoured
is exactly that boot: it re-points the multiboot header's entry_addr at the
stub's halt, and the guest parks there in 32-bit mode (observed: EIP=004000b1,
CS32, HLT=1). With RIP= only, that control read QMPFAIL and could not tell a
guest halted at a known address from a broken QMP path.

The two spellings are never both present, so this cannot pick the wrong one:
QEMU prints RIP= in long mode and EIP= otherwise. The alternation is anchored
so a longer register name ending in these letters cannot match.

EVERY FAILURE PATH EXITS NONZERO WITH NOTHING ON STDOUT. Callers turn a
failure into the literal string QMPFAIL and must shape-check it: the
crash control's assertion is a `!=` comparison, which QMPFAIL satisfies
vacuously, so a broken QMP path would otherwise paint that control green
with the discriminator never having run (review round 1, I5).
"""
import socket, json, re, sys

s = socket.socket(socket.AF_UNIX)
s.settimeout(10)
s.connect(sys.argv[1])
f = s.makefile("rw")
json.loads(f.readline())                     # QMP greeting


def cmd(c, **a):
    f.write(json.dumps({"execute": c, "arguments": a}) + "\n")
    f.flush()
    while True:
        line = f.readline()
        if not line:
            sys.exit("qmp_pc: connection closed while waiting for a reply to %s" % c)
        r = json.loads(line)
        if "return" in r or "error" in r:
            return r


cmd("qmp_capabilities")
r = cmd("human-monitor-command", **{"command-line": "info registers"})
if "error" in r:
    sys.exit("qmp_pc: %s" % r["error"])
m = re.search(r"(?:^|[^A-Za-z])(?:PC|RIP|EIP)=([0-9a-f]+)", r["return"])
if not m:
    sys.exit(1)
print(m.group(1).lstrip("0") or "0")
