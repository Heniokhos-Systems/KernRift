#!/bin/bash
# pe_unwind_identity.sh <base_compiler> <new_compiler> <out_dir>
#
# #143 (Windows PE unwind tables) merge gate, spec section 8.7 / plan Mi6. NOT a
# suite row: run at the end of every task that touches src/, output archived.
#
# Claim under test: every output whose target_os != 2 (not Windows) is
# byte-identical between the two compilers. Each corpus file is compiled by
# BOTH compilers for every non-Windows configuration below, IR and --legacy,
# and the pair must agree on: exit status, every output file (sha256), stdout
# (minus the timing/statistics line) and stderr. A configuration a compiler
# rejects is compared the same way (both must reject it identically).
#
# Works in either tree: the corpus extension and the extra configurations are
# chosen from the tree this script lives in (KernRift: src/main.kr; MLRift:
# src/main.mlr, which adds the NVPTX/AMDGPU emitters).
#
# Prints, last line: "IDENTICAL n/n" (exit 0) or "DIFFERENT d/n" (exit 1) and
# lists each differing (file, configuration) in <out_dir>/diffs.txt.
#
# Resource caps (plan section 0): every compile runs under ulimit -v 2000000
# and timeout 20 s (300 s for the serial re-run of a job that timed out under
# the parallel load). No Wine, no GPU.
set -u
if [ $# -ne 3 ]; then echo "usage: $0 <base_compiler> <new_compiler> <out_dir>" >&2; exit 2; fi
BASE="$(readlink -f "$1")"; NEW="$(readlink -f "$2")"; OUT="$3"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[ -x "$BASE" ] || { echo "base compiler not executable: $1" >&2; exit 2; }
[ -x "$NEW" ] || { echo "new compiler not executable: $2" >&2; exit 2; }
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
if [ -f "$ROOT/src/main.kr" ]; then EXT=kr; else EXT=mlr; fi

# Configurations: "<id>|<flags>". Every one has target_os != 2. The default
# fat build (.krbo/.mlrbo) is NOT here: it contains Windows slices; its
# non-Windows slices are compared once tests/helpers/krbo_slices.py exists (A12).
CFGS=(
  "lx|--arch=x86_64 --target=linux"
  "la|--arch=arm64 --target=linux"
  "mx|--arch=x86_64 --target=macos"
  "ma|--arch=arm64 --target=macos"
  "ax|--arch=x86_64 --target=android"
  "aa|--arch=arm64 --target=android"
  "fx|--arch=x86_64 --target=linux --freestanding"
  "fa|--arch=arm64 --target=linux --freestanding"
  "rv|--arch=riscv32"
  "xt|--arch=xtensa"
  "nimgx|--target=none --arch=x86_64 --emit=image --load-addr=0x400000"
  "nimga|--target=none --arch=arm64 --emit=image --load-addr=0x40000000"
  "nuefix|--target=none --arch=x86_64 --emit=uefi"
  "nuefia|--target=none --arch=arm64 --emit=uefi"
  "nfat|--target=none --emit=fatimage --arch=x86_64,arm64"
  "narxx|--target=none --arch=x86_64 --emit=arx"
  "narxa|--target=none --arch=arm64 --emit=arx"
  "nelfx|--target=none --arch=x86_64"
  "nelfa|--target=none --arch=arm64"
  "objlx|--arch=x86_64 --target=linux --emit=obj"
  "objla|--arch=arm64 --target=linux --emit=obj"
  "objmx|--arch=x86_64 --target=macos --emit=obj"
  "objma|--arch=arm64 --target=macos --emit=obj"
  "objnx|--target=none --arch=x86_64 --emit=obj"
  "lkm|--arch=x86_64 --emit=lkm"
  "asmlx|--arch=x86_64 --target=linux --emit=asm"
  "asmla|--arch=arm64 --target=linux --emit=asm"
  "asmmx|--arch=x86_64 --target=macos --emit=asm"
  "asmma|--arch=arm64 --target=macos --emit=asm"
  "asmax|--arch=x86_64 --target=android --emit=asm"
  "asmaa|--arch=arm64 --target=android --emit=asm"
  "asmrv|--arch=riscv32 --emit=asm"
  "asmxt|--arch=xtensa --emit=asm"
  "asmnx|--target=none --arch=x86_64 --emit=asm"
  "asmna|--target=none --arch=arm64 --emit=asm"
  "irlx|--arch=x86_64 --target=linux --emit=ir"
  "irla|--arch=arm64 --target=linux --emit=ir"
  "irmx|--arch=x86_64 --target=macos --emit=ir"
  "irma|--arch=arm64 --target=macos --emit=ir"
  "irax|--arch=x86_64 --target=android --emit=ir"
  "iraa|--arch=arm64 --target=android --emit=ir"
  "irrv|--arch=riscv32 --emit=ir"
  "irxt|--arch=xtensa --emit=ir"
  "irnx|--target=none --arch=x86_64 --emit=ir"
  "irna|--target=none --arch=arm64 --emit=ir"
)

# PEU_IDENTITY_SET=windows swaps in the Windows configurations instead: the
# refactor tasks that must leave Windows output byte-identical too (plan A4,
# A5) use it. Every output in that set is a Windows PE/COFF/listing/IR dump or
# a whole default fat .krbo.
if [ "${PEU_IDENTITY_SET:-nonwin}" = windows ]; then
    CFGS=(
      "wpx|--arch=x86_64 --target=windows --emit=pe"
      "wpa|--arch=arm64 --target=windows --emit=pe"
      "wex|--arch=x86_64 --target=windows"
      "wea|--arch=arm64 --target=windows"
      "wfx|--arch=x86_64 --target=windows --freestanding"
      "wfa|--arch=arm64 --target=windows --freestanding"
      "wsx|--arch=x86_64 --target=windows --emit=asm"
      "wsa|--arch=arm64 --target=windows --emit=asm"
      "wix|--arch=x86_64 --target=windows --emit=ir"
      "wia|--arch=arm64 --target=windows --emit=ir"
      "wox|--arch=x86_64 --target=windows --emit=obj"
      "woa|--arch=arm64 --target=windows --emit=obj"
      "fat|"
      "fatw|--targets=win-x64,win-arm64"
    )
elif [ "${PEU_IDENTITY_SET:-nonwin}" != nonwin ]; then
    echo "PEU_IDENTITY_SET must be nonwin or windows" >&2; exit 2
fi

CORPUS="$OUT/corpus.lst"
( cd "$ROOT" && for d in tests/fixtures tests/pe examples std tests/smoke; do
      [ -d "$d" ] && find "$d" -name "*.$EXT" -type f
  done | LC_ALL=C sort ) > "$CORPUS"

JOBS="$OUT/jobs.lst"; : > "$JOBS"
while IFS= read -r f; do
    for c in "${CFGS[@]}"; do
        printf '%s\t%s\t%s\n' "$f" "${c%%|*}" "${c#*|}" >> "$JOBS"
        printf '%s\t%s\t%s\n' "$f" "${c%%|*}L" "${c#*|} --legacy" >> "$JOBS"
    done
done < "$CORPUS"

# MLRift only: the GPU emitters (no Windows involvement at all).
if [ "$EXT" = mlr ] && [ "${PEU_IDENTITY_SET:-nonwin}" = nonwin ]; then
    while IFS= read -r f; do
        grep -q '@kernel' "$ROOT/$f" 2>/dev/null || continue
        printf '%s\t%s\t%s\n' "$f" ptx "--arch=x86_64 --target=nvptx" >> "$JOBS"
        printf '%s\t%s\t%s\n' "$f" amdn "--arch=x86_64 --target=amdgpu-native" >> "$JOBS"
        if command -v hipcc > /dev/null 2>&1; then
            printf '%s\t%s\t%s\n' "$f" hip "--arch=x86_64 --target=hip-amd" >> "$JOBS"
        fi
    done < "$CORPUS"
    # Source-less fixed-kernel emitters: --emit-amdgpu-<name>=<out path>.
    grep -o '"--emit-amdgpu-[a-z0-9-]*="' "$ROOT/src/main.mlr" | tr -d '"' | LC_ALL=C sort -u | while IFS= read -r fl; do
        printf '%s\t%s\t%s\n' "-" "amd:${fl#--emit-amdgpu-}" "$fl" >> "$JOBS"
    done
fi

export BASE NEW OUT ROOT
TMO=20; export TMO
# one_side <compiler> <side dir> <source|-> <flags...>: compile in a private
# directory with the SAME relative output path for both sides, then print one
# digest of status + output files + stdout (stats/timing lines dropped) + stderr.
one_side() {
    local cc="$1" d="$2" src="$3"; shift 3
    rm -rf "$d"; mkdir -p "$d"
    local rc
    if [ "$src" = "-" ]; then
        # source-less emitter: the flag value is the output path
        ( cd "$d" && ulimit -v 2000000 && timeout "$TMO" "$cc" "${1}out" > so 2> se ); rc=$?
    else
        ( cd "$d" && ulimit -v 2000000 && timeout "$TMO" "$cc" "$@" "$src" -o out > so 2> se ); rc=$?
    fi
    {
        echo "rc=$rc"
        ( cd "$d" && for x in $(ls -A | LC_ALL=C sort); do
              case "$x" in so|se) continue ;; esac
              if [ -f "$x" ]; then echo "file $x $(sha256sum < "$x" | cut -c1-64)"; fi
          done )
        echo "stdout $(grep -Ev '^[0-9]+ tokens, |\([0-9.]+ ms\)$' "$d/so" | sha256sum | cut -c1-64)"
        echo "stderr $(sha256sum < "$d/se" | cut -c1-64)"
    } | sha256sum | cut -c1-64 | sed "s/^/rc$rc:/"
}
export -f one_side
work() {
    local f="$1" id="$2" flags="$3" key src hb hn
    key="$(printf '%s_%s' "$f" "$id" | tr '/:' '__')"
    if [ "$f" = "-" ]; then src="-"; else src="$ROOT/$f"; fi
    # shellcheck disable=SC2086
    hb="$(one_side "$BASE" "$OUT/w/$key/b" "$src" $flags)"
    # shellcheck disable=SC2086
    hn="$(one_side "$NEW" "$OUT/w/$key/n" "$src" $flags)"
    if [ "$hb" = "$hn" ]; then
        printf 'SAME\t%s\t%s\t%s\n' "$f" "$id" "$hb"
        rm -rf "$OUT/w/$key"
    else
        printf 'DIFF\t%s\t%s\t%s\t%s\n' "$f" "$id" "$hb" "$hn"
    fi
}
export -f work
NPROC="$(nproc 2>/dev/null || echo 4)"
tr '\t' '\034' < "$JOBS" | xargs -d '\n' -P "$NPROC" -n 1 bash -c 'IFS=$'"'"'\034'"'"' read -r a b c <<< "$1"; work "$a" "$b" "$c"' _ > "$OUT/results.tsv"
# A timeout is not a verdict: under the parallel load a large program can miss
# the 20 s cap on one side only. Re-run every job in which either side timed
# out (status 124), one at a time with timeout 300; a job still timing out then
# stays a DIFF/TIMEOUT and fails the gate.
awk -F'\t' '$4 ~ /^rc124:/ || $5 ~ /^rc124:/' "$OUT/results.tsv" > "$OUT/timeouts.tsv"
if [ -s "$OUT/timeouts.tsv" ]; then
    TMO=300; export TMO
    grep -v -F -x -f "$OUT/timeouts.tsv" "$OUT/results.tsv" > "$OUT/results.tmp"
    cut -f2,3 "$OUT/timeouts.tsv" | while IFS=$'\t' read -r tf tid; do
        tflags="$(awk -F'\t' -v f="$tf" -v i="$tid" '$1 == f && $2 == i { print $3; exit }' "$JOBS")"
        work "$tf" "$tid" "$tflags"
    done >> "$OUT/results.tmp"
    mv "$OUT/results.tmp" "$OUT/results.tsv"
    echo "re-ran $(wc -l < "$OUT/timeouts.tsv") timed-out jobs serially with timeout 300" > "$OUT/retries.txt"
fi
rmdir "$OUT/w" 2> /dev/null

n=$(wc -l < "$JOBS"); got=$(wc -l < "$OUT/results.tsv"); d=$(grep -c '^DIFF' "$OUT/results.tsv")
ok=$(awk -F'\t' '$4 ~ /^rc0:/' "$OUT/results.tsv" | wc -l)
grep '^DIFF' "$OUT/results.tsv" > "$OUT/diffs.txt"
{
    echo "base: $BASE $(sha256sum < "$BASE" | cut -c1-64)"
    echo "new:  $NEW $(sha256sum < "$NEW" | cut -c1-64)"
    echo "set: ${PEU_IDENTITY_SET:-nonwin}"
    echo "tree: $ROOT ($EXT), corpus $(wc -l < "$CORPUS") files, $n jobs, $ok of them compile (base rc 0)"
} | tee "$OUT/summary.txt"
if [ "$got" != "$n" ]; then echo "INCOMPLETE $got/$n results" | tee -a "$OUT/summary.txt"; exit 1; fi
[ -f "$OUT/retries.txt" ] && cat "$OUT/retries.txt" | tee -a "$OUT/summary.txt"
if [ "$d" = 0 ]; then echo "IDENTICAL $n/$n" | tee -a "$OUT/summary.txt"; exit 0; fi
echo "DIFFERENT $d/$n (see $OUT/diffs.txt; per-pair outputs kept under $OUT/w/)" | tee -a "$OUT/summary.txt"; exit 1
