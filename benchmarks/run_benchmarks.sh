#!/bin/bash
# KernRift vs C vs Rust Benchmark Suite
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
KRC="${KRC:-$DIR/../build/krc2}"
RESULTS="$DIR/results.md"

echo "=== KernRift Benchmark Suite ===" | tee "$RESULTS"
echo "Date: $(date -u)" | tee -a "$RESULTS"
echo "CPU: $(lscpu | grep 'Model name' | sed 's/.*: *//')" | tee -a "$RESULTS"
echo "" | tee -a "$RESULTS"

# Warm the toolchains before timing anything. Compile timings are single-shot,
# so without this the FIRST benchmark absorbs the cold page-cache cost of
# loading gcc/rustc/krc and reports 2-3x its true figure — fib used to claim
# gcc -O0 at 73ms against a true ~26ms, and rustc debug at 307ms against ~130ms.
echo "  (warming toolchains...)" >&2
gcc -O0 -o /tmp/.bench_warm "$DIR/fib.c" 2>/dev/null || true
gcc -O2 -o /tmp/.bench_warm "$DIR/fib.c" 2>/dev/null || true
rustc -o /tmp/.bench_warm "$DIR/fib.rs" 2>/dev/null || true
rustc -C opt-level=2 -o /tmp/.bench_warm "$DIR/fib.rs" 2>/dev/null || true
$KRC --arch=x86_64 "$DIR/fib.kr" -o /tmp/.bench_warm 2>/dev/null || true
rm -f /tmp/.bench_warm

# Time a command, print result in ms
bench() {
    local label="$1"
    shift
    # Run 3 times, take median
    local times=()
    for run in 1 2 3; do
        local start=$(date +%s%N)
        if [ ! -x "$1" ]; then echo "$label: MISSING BINARY"; return; fi
        "$@" >/dev/null 2>&1 || true
        local end=$(date +%s%N)
        local ms=$(( (end - start) / 1000000 ))
        times+=($ms)
    done
    # Sort and take median
    IFS=$'\n' sorted=($(sort -n <<<"${times[*]}")); unset IFS
    # Emit a real markdown row: the header is "| Binary | Time |", so the row
    # needs the same two columns. It used to print "| krc: 423ms (runs: ...)",
    # which renders as prose rather than a table.
    echo "| $label | ${sorted[1]}ms (${times[0]}, ${times[1]}, ${times[2]}) |"
}

compile_bench() {
    local name="$1"
    echo "--- $name ---" | tee -a "$RESULTS"

    # Compile KernRift
    echo "  Compiling KernRift..."
    local start=$(date +%s%N)
    $KRC --arch=x86_64 "$DIR/$name.kr" -o "$DIR/$name.krc.bin" 2>/dev/null
    local end=$(date +%s%N)
    local kr_compile_ms=$(( (end - start) / 1000000 ))
    chmod +x "$DIR/$name.krc.bin"

    # Compile C (-O0 for fair comparison, -O2 for optimized)
    local start=$(date +%s%N)
    gcc -O0 -o "$DIR/$name.c.O0.bin" "$DIR/$name.c" 2>/dev/null
    local end=$(date +%s%N)
    local c_O0_compile_ms=$(( (end - start) / 1000000 ))

    local start=$(date +%s%N)
    gcc -O2 -o "$DIR/$name.c.O2.bin" "$DIR/$name.c" 2>/dev/null
    local end=$(date +%s%N)
    local c_O2_compile_ms=$(( (end - start) / 1000000 ))

    # Compile Rust (debug and release)
    local start=$(date +%s%N)
    rustc -o "$DIR/$name.rs.dbg.bin" "$DIR/$name.rs" 2>/dev/null
    local end=$(date +%s%N)
    local rs_dbg_compile_ms=$(( (end - start) / 1000000 ))

    local start=$(date +%s%N)
    rustc -C opt-level=2 -o "$DIR/$name.rs.rel.bin" "$DIR/$name.rs" 2>/dev/null
    local end=$(date +%s%N)
    local rs_rel_compile_ms=$(( (end - start) / 1000000 ))

    # Binary sizes
    local kr_size=$(stat -c%s "$DIR/$name.krc.bin" 2>/dev/null || echo 0)
    local c_O0_size=$(stat -c%s "$DIR/$name.c.O0.bin" 2>/dev/null || echo 0)
    local c_O2_size=$(stat -c%s "$DIR/$name.c.O2.bin" 2>/dev/null || echo 0)
    local rs_dbg_size=$(stat -c%s "$DIR/$name.rs.dbg.bin" 2>/dev/null || echo 0)
    local rs_rel_size=$(stat -c%s "$DIR/$name.rs.rel.bin" 2>/dev/null || echo 0)

    echo "" | tee -a "$RESULTS"
    echo "### $name" | tee -a "$RESULTS"
    echo "" | tee -a "$RESULTS"
    echo "**Compile time:**" | tee -a "$RESULTS"
    echo "| Compiler | Time |" | tee -a "$RESULTS"
    echo "|----------|------|" | tee -a "$RESULTS"
    echo "| krc (self-hosted) | ${kr_compile_ms}ms |" | tee -a "$RESULTS"
    echo "| gcc -O0 | ${c_O0_compile_ms}ms |" | tee -a "$RESULTS"
    echo "| gcc -O2 | ${c_O2_compile_ms}ms |" | tee -a "$RESULTS"
    echo "| rustc (debug) | ${rs_dbg_compile_ms}ms |" | tee -a "$RESULTS"
    echo "| rustc -O2 | ${rs_rel_compile_ms}ms |" | tee -a "$RESULTS"
    echo "" | tee -a "$RESULTS"

    echo "**Binary size:**" | tee -a "$RESULTS"
    echo "| Binary | Size |" | tee -a "$RESULTS"
    echo "|--------|------|" | tee -a "$RESULTS"
    echo "| krc | ${kr_size} B |" | tee -a "$RESULTS"
    echo "| gcc -O0 | ${c_O0_size} B |" | tee -a "$RESULTS"
    echo "| gcc -O2 | ${c_O2_size} B |" | tee -a "$RESULTS"
    echo "| rustc debug | ${rs_dbg_size} B |" | tee -a "$RESULTS"
    echo "| rustc -O2 | ${rs_rel_size} B |" | tee -a "$RESULTS"
    echo "" | tee -a "$RESULTS"

    echo "**Runtime (median of 3):**" | tee -a "$RESULTS"
    echo "| Binary | Time |" | tee -a "$RESULTS"
    echo "|--------|------|" | tee -a "$RESULTS"
    bench "krc" "$DIR/$name.krc.bin" | tee -a "$RESULTS"
    bench "gcc -O0" "$DIR/$name.c.O0.bin" | tee -a "$RESULTS"
    bench "gcc -O2" "$DIR/$name.c.O2.bin" | tee -a "$RESULTS"
    bench "rustc debug" "$DIR/$name.rs.dbg.bin" | tee -a "$RESULTS"
    bench "rustc -O2" "$DIR/$name.rs.rel.bin" | tee -a "$RESULTS"
    echo "" | tee -a "$RESULTS"
}

compile_bench "fib"
compile_bench "sort"
compile_bench "sieve"
compile_bench "matmul"
compile_bench "mandelbrot"
compile_bench "sha256"

# Cleanup binaries
rm -f "$DIR"/*.bin

echo "=== Done ===" | tee -a "$RESULTS"
echo "Results saved to $RESULTS"
