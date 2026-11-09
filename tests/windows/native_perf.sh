#!/bin/bash
# native_perf.sh -- the native timing half of #143's perf gate (spec 9, plan
# A15 "native timing", Task D step 6; the instruction-count half is
# tests/gates/pe_unwind_perf.sh). KernRift tree. Laptop side: inline
# PowerShell only (user ruling, phase 5); the images and a data file travel by
# scp, no script file does.
#
#   native_perf.sh <base krc> <new krc> <out dir> [samples]
#
# Every port of tests/perf/ x {IR, --legacy} is built as an x86_64 Windows PE
# by both compilers, each with tests/perf/exit_windows.kr (ExitProcess through
# the exit builtin). On the laptop each base/new pair is run INTERLEAVED:
# <samples> (default 15) rounds, the order alternating base-first /
# new-first, each sample timing 10 back-to-back runs with a Stopwatch; every
# run must exit 0 (the ports check their own results). Per pair, the delta of
# a round is new/base - 1; the verdict is on the median delta, against the
# spread of the deltas (IQR):
#   median <= 3 %                         PASS
#   else rerun the pair at 45 rounds, then
#   median <= min(max(3 %, IQR), 6 %)     PASS, else FAIL.
# Process start-up is part of every sample, so small ports are noisy; the
# IQR term is what keeps that noise from failing the gate, and the 6 % cap
# what keeps it from hiding a real regression.
# Writes <out dir>/samples.txt (S <pair> <round> <base ms> <new ms>) and
# summary.txt; exits 0 when every pair passes, 1 otherwise, 2 on a build or
# transport error. The remote directory is removed and its absence asserted.
set -u -o pipefail
NATIVE_HOST="${NATIVE_HOST:-laptop}"
BASE="${1:?usage: native_perf.sh <base krc> <new krc> <out dir> [samples]}"; NEW="${2:?new krc}"; OUT="${3:?out dir}"; N="${4:-15}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
RD="C:\\Users\\pante\\pe_unwind_scratch\\perf$$"; RDF="C:/Users/pante/pe_unwind_scratch/perf$$"
rps() { ssh -o BatchMode=yes "$NATIVE_HOST" "powershell -NoProfile -NonInteractive -Command \"\$ProgressPreference='SilentlyContinue'; $1\"" < /dev/null; }
cleanup() {
    rps "for (\$i=0; \$i -lt 120 -and (Test-Path -LiteralPath '$RD'); \$i++) { Remove-Item -LiteralPath '$RD' -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath '$RD') { Start-Sleep -Milliseconds 500 } }; if ((Test-Path 'C:\\Users\\pante\\pe_unwind_scratch') -and -not (Get-ChildItem -Force 'C:\\Users\\pante\\pe_unwind_scratch')) { Remove-Item -Force 'C:\\Users\\pante\\pe_unwind_scratch' }; if (Test-Path -LiteralPath '$RD') { exit 1 }; exit 0" \
        || { echo "native_perf.sh: remote $RD not removed" >&2; return 1; }
}
mkdir -p "$OUT/img" || exit 2
: > "$OUT/pairs.txt"
for P in fib sort matmul sieve sha256; do
    for L in ir legacy; do
        F=""; [ "$L" = legacy ] && F=--legacy
        for W in b n; do
            K="$BASE"; [ "$W" = n ] && K="$NEW"
            cat "$HERE/perf/$P.kr" "$HERE/perf/exit_windows.kr" > "$OUT/img/src.kr"
            if ! ( ulimit -v 2000000; timeout 120 "$K" --arch=x86_64 --target=windows --emit=pe $F "$OUT/img/src.kr" -o "$OUT/img/${P}_${L}_$W.exe" ) > "$OUT/img/build.log" 2>&1; then
                echo "native_perf.sh: build of $P $L ($W) failed: $(grep -m1 error "$OUT/img/build.log")" >&2; exit 2
            fi
        done
        echo "${P}_$L" >> "$OUT/pairs.txt"
    done
done
rm -f "$OUT/img/src.kr" "$OUT/img/build.log"
# run <rounds> <pairs file>: appends the samples to samples.txt; 0 on success
run() {
    rps "New-Item -ItemType Directory -Force '$RD' | Out-Null; exit 0" > /dev/null || { echo "native_perf.sh: remote mkdir failed" >&2; return 2; }
    local p
    for p in $(cat "$2"); do
        scp -q -o BatchMode=yes "$OUT/img/${p}_b.exe" "$OUT/img/${p}_n.exe" "$NATIVE_HOST:$RDF/" < /dev/null || { cleanup; echo "native_perf.sh: scp failed" >&2; return 2; }
    done
    scp -q -o BatchMode=yes "$2" "$NATIVE_HOST:$RDF/pairs.txt" < /dev/null || { cleanup; return 2; }
    rps "\$ErrorActionPreference='Stop'; Set-Location '$RD'; \$pairs = Get-Content 'pairs.txt'; \$sw = [Diagnostics.Stopwatch]::new(); for (\$k=1; \$k -le $1; \$k++) { foreach (\$p in \$pairs) { \$order = @('b','n'); if ((\$k -band 1) -eq 0) { \$order = @('n','b') }; \$t = @{}; foreach (\$w in \$order) { \$exe = Join-Path '$RD' (\$p + '_' + \$w + '.exe'); \$sw.Restart(); for (\$i=0; \$i -lt 10; \$i++) { & \$exe; if (\$LASTEXITCODE -ne 0) { [Console]::Out.WriteLine('BADEXIT ' + \$p + ' ' + \$w + ' ' + \$LASTEXITCODE); exit 3 } }; \$sw.Stop(); \$t[\$w] = \$sw.Elapsed.TotalMilliseconds }; [Console]::Out.WriteLine('S ' + \$p + ' ' + \$k + ' ' + \$t['b'] + ' ' + \$t['n']) } }; exit 0" \
        | tr -d '\r' >> "$OUT/samples.txt"
    local rc=$?
    cleanup || return 2
    [ "$rc" = 0 ] || { echo "native_perf.sh: the timing run failed ($(grep -m1 BADEXIT "$OUT/samples.txt"))" >&2; return 2; }
}
: > "$OUT/samples.txt"
run "$N" "$OUT/pairs.txt" || exit 2
judge() {
    python3 -B - "$OUT/samples.txt" "$1" <<'PYEOF'
import sys
from statistics import median
s = {}
for l in open(sys.argv[1]):
    f = l.split()
    if len(f) == 5 and f[0] == 'S':
        s.setdefault(f[1], []).append((int(f[2]), float(f[3]), float(f[4])))
final = sys.argv[2] == 'final'
for p in sorted(s):
    d = sorted((n / b - 1) * 100 for _, b, n in s[p])
    q = lambda x: d[min(len(d) - 1, int(x * (len(d) - 1) + 0.5))]
    med, iqr = median(d), q(0.75) - q(0.25)
    thr = min(max(3.0, iqr), 6.0) if final else 3.0
    v = 'PASS' if med <= thr else ('FAIL' if final else 'RERUN')
    print('%s %s: %d rounds, median %+.2f %%, IQR %.2f %%, limit %.2f %% (base median %.2f ms, new %.2f ms per 10 runs)'
          % (v, p, len(d), med, iqr, thr, median(b for _, b, _ in s[p]), median(n for _, _, n in s[p])))
PYEOF
}
judge first > "$OUT/first.txt"
grep '^RERUN ' "$OUT/first.txt" | awk '{print $2}' | tr -d ':' > "$OUT/rerun.txt"
if [ -s "$OUT/rerun.txt" ]; then
    # the pairs above 3 % again, at 45 rounds; judged on the 45 alone
    mv "$OUT/samples.txt" "$OUT/samples_first.txt"; : > "$OUT/samples.txt"
    run 45 "$OUT/rerun.txt" || exit 2
    judge final > "$OUT/rerun_verdict.txt"
    cp "$OUT/samples.txt" "$OUT/samples_rerun.txt"; mv "$OUT/samples_first.txt" "$OUT/samples.txt"
fi
{ grep -v '^RERUN ' "$OUT/first.txt"; [ -s "$OUT/rerun.txt" ] && sed 's/^/(rerun at 45) /' "$OUT/rerun_verdict.txt"; } > "$OUT/summary.txt"
cat "$OUT/summary.txt"
if grep -q 'FAIL ' "$OUT/summary.txt"; then echo "native_perf: FAIL"; exit 1; fi
echo "native_perf: PASS"; exit 0
