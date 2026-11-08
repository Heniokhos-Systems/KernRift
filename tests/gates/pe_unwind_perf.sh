#!/bin/bash
# pe_unwind_perf.sh <base compiler> <new compiler> <out dir>
# #143's binding performance gate (spec 9, plan A15), instruction counts only
# (the native timing half is Task D step 6). For every port of tests/perf/ x
# {x86_64, arm64} x {IR, --legacy}: the guest instructions the Windows-ABI
# freestanding ELF executes under qemu-user, base vs new; both must exit 0
# (the ports check their results) and the new count may exceed the base by at
# most 3 %. First the calibration: calib.kr at N = 1000 and 2000 must differ
# by exactly 1000 x the loop body's disassembled length, on both arches.
# Writes <out dir>/counts.tsv and summary.txt; exits 0 when every row passes.
# With --calibration-only <new krc> <out dir> it runs the calibration alone
# (row perf_insn_count_calibration).
set -u
CAL_ONLY=0
if [ "${1:-}" = --calibration-only ]; then CAL_ONLY=1; shift; set -- "" "$@"; fi
BASE="${1-}"; NEW="${2:?usage: pe_unwind_perf.sh <base krc> <new krc> <out dir> | --calibration-only <krc> <out dir>}"; OUT="${3:?out dir}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CNT="$HERE/perf/count_insns.sh"
mkdir -p "$OUT" || exit 2
: > "$OUT/counts.tsv"
bad=0
# scratch: PEU_PERF_TMP (the suite row sets it), else ~/.cache/pe_unwind --
# created if absent (a fresh CI runner has no ~/.cache/pe_unwind: CI run
# 42513155266 failed the calibration there)
TMPROOT="${PEU_PERF_TMP:-$HOME/.cache/pe_unwind}"
mkdir -p "$TMPROOT" || { echo "pe_unwind_perf: cannot create scratch root $TMPROOT"; exit 2; }
command -v llvm-objdump > /dev/null 2>&1 || { echo "pe_unwind_perf: calibration needs llvm-objdump (not found)"; exit 2; }
# calibration
for A in x86_64 arm64; do
    c1=$(PEU_N=1000 bash "$CNT" "$NEW" "$HERE/perf/calib.kr" $A); c2=$(PEU_N=2000 bash "$CNT" "$NEW" "$HERE/perf/calib.kr" $A)
    W=$(mktemp -d "$TMPROOT/cal.XXXXXX") || { echo "calibration $A: FAIL (mktemp in $TMPROOT failed)" | tee -a "$OUT/summary.txt"; bad=1; continue; }
    { sed 's/PEU_N/1000/g' "$HERE/perf/calib.kr"; cat "$HERE/perf/exit_$A.kr"; } > "$W/c.kr"
    why=""
    ( ulimit -v 2000000; timeout 120 "$NEW" --freestanding --target=windows --arch=$A "$W/c.kr" -o "$W/c.elf" ) > "$W/b.log" 2>&1 || why="ELF build failed: $(grep -m1 -i error "$W/b.log" | cut -c1-120)"
    ( ulimit -v 2000000; timeout 120 "$NEW" --freestanding --target=windows --arch=$A --emit=asm "$W/c.kr" -o "$W/c.s" ) > "$W/a.log" 2>&1 || why="$why${why:+; }listing build failed: $(grep -m1 -i error "$W/a.log" | cut -c1-120)"
    body=$(python3 -B - "$W/c.elf" "$W/c.s" "$A" 2> "$W/py.err" <<'PYEOF'
import re, subprocess, sys
# work()'s bytes from the listing's byte column; found in the ELF (one PT_LOAD
# from file offset 0, so address = load base + file offset); disassembled by
# llvm-objdump from there; the loop body is the backward branch's target ..
# the branch, inclusive
lst = open(sys.argv[2], encoding='latin-1').read().split('\n')
code, inwork = bytearray(), False
for l in lst:
    if re.match(r'^[A-Za-z_][\w.]*:\s*$', l):
        inwork = (l.strip() == 'work:')
        if not inwork and code:
            break
        continue
    m = re.match(r'^\s+[0-9a-f]{8}: ((?:[0-9a-f]{2,8}(?: |$))+)', l)
    if inwork and m:
        for t in m.group(1).split():
            code += bytes.fromhex(t) if len(t) == 2 else int(t, 16).to_bytes(4, 'little')
elf = open(sys.argv[1], 'rb').read()
# the listing's call/branch fields may be unresolved, so only work()'s first
# 8 bytes (its prologue) locate it; its length comes from the listing
fo = elf.find(bytes(code[:8]))
if fo < 0 or not code or elf.find(bytes(code[:8]), fo + 1) >= 0:
    print('none'); sys.exit(0)
vbase = 0x400000
lo, hi = vbase + fo, vbase + fo + len(code)
d = subprocess.run(['llvm-objdump', '-d', '--no-show-raw-insn', '--start-address=%d' % lo, '--stop-address=%d' % hi, sys.argv[1]],
                   capture_output=True, text=True).stdout
fn = []
for l in d.split('\n'):
    m = re.match(r'^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$', l)
    if m:
        fn.append((int(m.group(1), 16), m.group(2), m.group(3)))
for a, op, args in fn:
    m = re.search(r'0x([0-9a-f]+)', args)
    if (op.startswith('j') or op == 'b' or op.startswith('b.') or op in ('cbz', 'cbnz')) and m:
        t = int(m.group(1), 16)
        if lo <= t < a:
            print(sum(1 for x in fn if t <= x[0] <= a)); sys.exit(0)
print('none')
PYEOF
)
    # a python failure must be reported, never read as a body length
    if [ -s "$W/py.err" ] || ! [[ "$body" =~ ^([0-9]+|none)$ ]]; then
        why="$why${why:+; }body parser failed: $(grep -v '^ ' "$W/py.err" | tail -1 | cut -c1-160)${body:+ (printed '$body')}"
    fi
    rm -rf "$W"
    n1=${c1%% *}; n2=${c2%% *}
    if [ -n "$why" ]; then
        echo "calibration $A: FAIL ($c1 / $c2; $why)" | tee -a "$OUT/summary.txt"; bad=1
    elif [ "${c1#* }" = 0 ] && [ "${c2#* }" = 0 ] && [ "$body" != none ] && [ $((n2 - n1)) = $((1000 * body)) ]; then
        echo "calibration $A: PASS ($n1 / $n2 instructions, slope $(( (n2 - n1) / 1000 )) = loop body $body)" | tee -a "$OUT/summary.txt"
    else
        echo "calibration $A: FAIL ($c1 / $c2, loop body '$body')" | tee -a "$OUT/summary.txt"; bad=1
    fi
done
if [ "$CAL_ONLY" = 1 ]; then
    if [ "$bad" = 0 ]; then echo "pe_unwind_perf calibration: PASS" | tee -a "$OUT/summary.txt"; else echo "pe_unwind_perf calibration: FAIL" | tee -a "$OUT/summary.txt"; fi
    exit $bad
fi
for P in fib sort matmul sieve sha256; do
    for A in x86_64 arm64; do
        for L in "" --legacy; do
            b=$(bash "$CNT" "$BASE" "$HERE/perf/$P.kr" $A $L); n=$(bash "$CNT" "$NEW" "$HERE/perf/$P.kr" $A $L)
            printf '%s\t%s\t%s\t%s\t%s\n' "$P" "$A" "${L:-ir}" "$b" "$n" >> "$OUT/counts.tsv"
            line=$(python3 -c '
import sys
p, a, l, b, n = sys.argv[1:6]
bc, br = b.split(); nc, nr = n.split()
if br != "0" or nr != "0":
    print("FAIL %s %s %s: exit base %s new %s (a port checks its own result)" % (p, a, l, br, nr)); sys.exit()
d = (int(nc) / int(bc) - 1) * 100
print("%s %s %s %s: base %s new %s %+.2f%%" % ("PASS" if d <= 3.0 else "FAIL", p, a, l, bc, nc, d))' "$P" "$A" "${L:-ir}" "$b" "$n")
            echo "$line" | tee -a "$OUT/summary.txt"
            [[ "$line" == PASS* ]] || bad=1
        done
    done
done
if [ "$bad" = 0 ]; then echo "pe_unwind_perf: PASS" | tee -a "$OUT/summary.txt"; else echo "pe_unwind_perf: FAIL" | tee -a "$OUT/summary.txt"; fi
exit $bad
