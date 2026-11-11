# xtcount.py <code.bin> [--list]
#
# Counts the real memory loads in an xtensa code blob (an --arch=xtensa
# --freestanding ELF with its header stripped, as xtensa_call_disasm strips
# it). Used by the unused_load_kept_xtensa_*, plain_load_not_merged xtensa and
# plain_load_not_hoisted xtensa rows (#199); xtensa_load_counter_selftest is
# this script's own guard.
#
# A linear disassembly of the blob is wrong in two ways: the l32r literal
# pools are data that objdump decodes as instructions (a pool word can look
# like `l32i.n a13, a0, 0`), and objdump runs on from the end of a pool or
# from the zero padding after a `ret.n` into the next function at a byte that
# is not an instruction boundary, so real loads vanish and garbage appears.
# So the blob is disassembled in segments, to a fixed point:
#   1. every l32r target word [t, t+4) is a pool byte;
#   2. the 4-byte-aligned address after every ret/ret.n is a restart point
#      (functions are 4-aligned);
#   3. the blob is split into segments that hold no pool byte and that begin
#      at a pool's end or a restart point, and each segment is disassembled
#      on its own (--start-address/--stop-address), so every segment starts on
#      an instruction boundary and never runs into a pool;
#   4. 1-3 repeat until no new l32r target and no new restart point appears.
# Counted: l8ui, l16ui, l16si, l32i and l32i.n whose base is not a1 (the stack
# pointer). Prints the count.
#
# --list also prints, before the count, one line per counted load
# (`L <addr>`) and per backward branch (`B <addr> <target>`, target < addr),
# all addresses in decimal: the hoisting row checks that the load lies inside
# a loop span.
#
# Needs xtensa-lx106-elf-objdump on PATH. Run it with python3 -I.
import re
import subprocess
import sys

OBJ = "xtensa-lx106-elf-objdump"
LINE = re.compile(r"\s*([0-9a-f]+):\s+([0-9a-f]+)\s+(\S+)\s*(.*)")
LOAD = re.compile(r"l32i(\.n)?|l8ui|l16ui|l16si")
BRANCH = re.compile(r"j|b(eq|ne|lt|ge|ltu|geu|any|none|all|nall|bc|bs)|"
                    r"b(eq|ne|lt|ge)z(\.n)?|b(eq|ne|lt|ge|ltu|geu)i|bb[cs]i")


def main():
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != "--list"):
        sys.stderr.write("usage: xtcount.py <code.bin> [--list]\n")
        return 2
    blob = sys.argv[1]
    listing = len(sys.argv) == 3
    with open(blob, "rb") as fh:
        size = len(fh.read())

    def dis(start, stop):
        out = subprocess.run([OBJ, "-b", "binary", "-m", "xtensa", "-D",
                              "--start-address=%d" % start, "--stop-address=%d" % stop, blob],
                             capture_output=True, text=True, check=True).stdout
        res = []
        for ln in out.split("\n"):
            m = LINE.match(ln)
            if m:
                res.append((int(m.group(1), 16), len(m.group(2)) // 2, m.group(3), m.group(4)))
        return res

    pool = set()
    cuts = set()
    ins = []
    for _ in range(50):
        segs = []
        a = 0
        while a < size:
            if a in pool:
                a += 1
                continue
            b = a
            while b < size and b not in pool and (b == a or b not in cuts):
                b += 1
            segs.append((a, b))
            a = b
        ins = []
        for s, e in segs:
            ins += dis(s, e)
        new_pool = set()
        new_cuts = set()
        for a, n, mn, ops in ins:
            if mn == "l32r":
                t = re.search(r",\s*0x([0-9a-f]+)", ops)
                if t:
                    ta = int(t.group(1), 16)
                    new_pool |= {k for k in range(ta, ta + 4) if k not in pool}
            if mn in ("ret", "ret.n"):
                c = (a + n + 3) & ~3
                if c not in cuts and c < size:
                    new_cuts.add(c)
        if not new_pool and not new_cuts:
            break
        pool |= new_pool
        cuts |= new_cuts
    else:
        sys.stderr.write("xtcount.py: no fixed point after 50 rounds\n")
        return 1

    n = 0
    for a, sz, mn, ops in ins:
        if LOAD.fullmatch(mn) and not re.match(r"a\d+, a1,", ops.strip()):
            n += 1
            if listing:
                print("L %d" % a)
        elif listing and BRANCH.fullmatch(mn):
            t = re.search(r"0x([0-9a-f]+)\s*$", ops)
            if t and int(t.group(1), 16) < a:
                print("B %d %d" % (a, int(t.group(1), 16)))
    print(n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
