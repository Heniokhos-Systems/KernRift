#!/bin/bash
# fat_slice_identity.sh <krc> <out_dir> [file ...]
#
# C1 (#244) gate: a --targets= build compiles only the slices it ships, and
# every slice it ships is BYTE-IDENTICAL to the same slice of the default fat
# build. Self-contained: both builds come from the SAME compiler, so no base
# compiler is needed; run it at the end of every task that touches
# compile_fat. The suite row c1_f244_slice_identity runs it on two files.
#
# Corpus: the files given, else the pe_unwind_identity.sh corpus (every .kr
# under tests/fixtures, tests/pe, examples, std and tests/smoke -- which holds
# the #254 fixtures fat_builtin_overrides_9.kr, fat_signed_returns_70.kr and
# fat_annotations_50.kr). Each file is built IR and --legacy: once as the
# default fat binary, and once per list below (the 8 single-slice lists and
# three that skip slice 0). Every (mode, list, file) gets one verdict:
#
#   SAME       both built; the list build holds exactly the listed slices
#              (krbo_slices.py names), each byte-identical to the default's
#   BOTHREF    both refused
#   EXPLAINED  the default refused and the list built, and the default's
#              refusal ends with C1's note naming a slice the list does not
#              ship (the failure is confined to a slice left out)
#   DIFF       both built, but a slice differs or the slice set is wrong
#   NEWREFUSE  the default built and the list refused
#   NEWACCEPT  the default refused, the list built, and no note places the
#              failure outside the list (a front-end error, a main-less file,
#              or a note naming a listed slice)
#   TIMEOUT    a build ran out of time twice (120 s, then 600 s serially)
#
# PASS (exit 0) only with 0 DIFF, 0 NEWREFUSE, 0 NEWACCEPT, 0 TIMEOUT.
# Output: <out_dir>/results.txt (one verdict per line), summary.txt.
# Every compile runs under ulimit -v 2000000.
set -u
if [ $# -lt 2 ]; then echo "usage: $0 <krc> <out_dir> [file ...]" >&2; exit 2; fi
KRC_FSI="$(readlink -f "$1")"; OUT="$2"; shift 2
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[ -x "$KRC_FSI" ] || { echo "compiler not executable: $KRC_FSI" >&2; exit 2; }
command -v python3 > /dev/null 2>&1 || { echo "fat_slice_identity: needs python3 (krbo_slices.py)" >&2; exit 2; }
mkdir -p "$OUT" || exit 2; OUT="$(cd "$OUT" && pwd)"
CORPUS="$OUT/corpus.lst"
if [ $# -gt 0 ]; then
    for f in "$@"; do
        case "$f" in /*) printf '%s\n' "$f" ;; *) printf '%s\n' "$ROOT/$f" ;; esac
    done > "$CORPUS"
else
    ( cd "$ROOT" && for d in tests/fixtures tests/pe examples std tests/smoke; do
          [ -d "$d" ] && find "$d" -name '*.kr' -type f
      done | LC_ALL=C sort | sed "s|^|$ROOT/|" ) > "$CORPUS"
fi
while IFS= read -r f; do [ -f "$f" ] || { echo "fat_slice_identity: no such file: $f" >&2; exit 2; }; done < "$CORPUS"
FSI_LISTS="linux-x64 linux-arm64 win-x64 win-arm64 mac-x64 mac-arm64 android-arm64 android-x64 linux-arm64,win-x64 mac-arm64,android-x64 win-arm64,android-arm64"
export KRC_FSI OUT ROOT FSI_LISTS
TMO=120; export TMO

# fsi_build <dir> <stem> <flags...> <file>: rc in <dir>/<stem>.rc, stderr in
# <dir>/<stem>.err, slices (name size sha256) in <dir>/<stem>.sl.
fsi_build() {
    local d="$1" s="$2"; shift 2
    rm -rf "$d/$s.krbo" "$d/$s.x"
    ( cd "$d" && ulimit -v 2000000 && timeout "$TMO" "$KRC_FSI" "$@" -o "$d/$s.krbo" ) > /dev/null 2> "$d/$s.err"
    local rc=$?; echo "$rc" > "$d/$s.rc"; : > "$d/$s.sl"
    if [ "$rc" = 0 ]; then
        python3 -B "$ROOT/tests/helpers/krbo_slices.py" "$d/$s.krbo" "$d/$s.x" > "$d/$s.sl" 2>> "$d/$s.err" || echo 99 > "$d/$s.rc"
    fi
    rm -rf "$d/$s.krbo" "$d/$s.x"
}
export -f fsi_build
# the slice C1's note names on the LAST stderr line, or nothing
fsi_note_slice() {
    tail -1 "$1" | sed -n 's/^note: the error above is in the \([a-z0-9-]*\) slice of the fat binary; .*/\1/p'
}
export -f fsi_note_slice
fsi_job() {
    local f="$1" m="$2" mf="" d L s a b bad want got nsl
    [ "$m" = legacy ] && mf="--legacy"
    d=$(mktemp -d "$OUT/w.XXXXXX")
    fsi_build "$d" base $mf "$f"
    local brc; brc=$(cat "$d/base.rc")
    for L in $FSI_LISTS; do
        fsi_build "$d" n $mf --targets=$L "$f"
        local nrc; nrc=$(cat "$d/n.rc")
        if [ "$brc" = 124 ] || [ "$nrc" = 124 ]; then echo "TIMEOUT $m $L $f"; continue; fi
        if [ "$brc" = 0 ] && [ "$nrc" = 0 ]; then
            bad=""
            want=$(tr ',' '\n' <<< "$L" | LC_ALL=C sort | tr '\n' ' ')
            got=$(awk '{print $1}' "$d/n.sl" | LC_ALL=C sort | tr '\n' ' ')
            [ "$want" = "$got" ] || bad=" slices [$got] want [$want]"
            for s in ${L//,/ }; do
                a=$(awk -v s="$s" '$1 == s {print $3}' "$d/base.sl"); b=$(awk -v s="$s" '$1 == s {print $3}' "$d/n.sl")
                [ -n "$a" ] && [ "$a" = "$b" ] || bad="$bad $s"
            done
            if [ -z "$bad" ]; then echo "SAME $m $L $f"; else echo "DIFF $m $L $f :$bad"; fi
        elif [ "$brc" != 0 ] && [ "$nrc" != 0 ]; then
            echo "BOTHREF $m $L $f"
        elif [ "$brc" = 0 ]; then
            echo "NEWREFUSE $m $L $f : $(grep -m1 'error' "$d/n.err" | cut -c1-160)"
        else
            nsl=$(fsi_note_slice "$d/base.err")
            if [ -n "$nsl" ] && ! tr ',' '\n' <<< "$L" | grep -qxF -- "$nsl"; then
                echo "EXPLAINED $m $L $f : default fails in $nsl"
            else
                echo "NEWACCEPT $m $L $f : default note '${nsl:-none}': $(grep -m1 'error' "$d/base.err" | cut -c1-160)"
            fi
        fi
    done
    rm -rf "$d"
}
export -f fsi_job
JOBS="$OUT/jobs.lst"
while IFS= read -r f; do printf '%s\tir\n%s\tlegacy\n' "$f" "$f"; done < "$CORPUS" > "$JOBS"
NPROC="$(nproc 2> /dev/null || echo 4)"
xargs -d '\n' -P "$NPROC" -n 1 bash -c 'IFS=$'"'"'\t'"'"' read -r a b <<< "$1"; fsi_job "$a" "$b"' _ < "$JOBS" > "$OUT/results.raw"
# a timeout is not a verdict: re-run those jobs serially with 600 s
grep '^TIMEOUT ' "$OUT/results.raw" | awk '{print $4 "\t" $2}' | LC_ALL=C sort -u > "$OUT/timeouts.lst"
if [ -s "$OUT/timeouts.lst" ]; then
    TMO=600; export TMO
    awk 'NR == FNR { t[$1 " " $2] = 1; next } !(($4 " " $2) in t)' FS='\t' "$OUT/timeouts.lst" FS=' ' "$OUT/results.raw" > "$OUT/results.tmp"
    while IFS=$'\t' read -r a b; do fsi_job "$a" "$b"; done < "$OUT/timeouts.lst" >> "$OUT/results.tmp"
    mv "$OUT/results.tmp" "$OUT/results.raw"
fi
sed "s| $ROOT/| |" "$OUT/results.raw" | LC_ALL=C sort > "$OUT/results.txt"; rm -f "$OUT/results.raw"
nlists=$(wc -w <<< "$FSI_LISTS"); nf=$(wc -l < "$CORPUS"); want=$((nf * 2 * nlists)); got=$(wc -l < "$OUT/results.txt")
cnt() { grep -c "^$1 " "$OUT/results.txt"; }
{
    echo "compiler: $KRC_FSI $(sha256sum < "$KRC_FSI" | cut -c1-64)"
    echo "corpus: $nf files x IR/--legacy x $nlists lists = $want comparisons; $got results"
    echo "SAME $(cnt SAME), BOTHREF $(cnt BOTHREF), EXPLAINED $(cnt EXPLAINED), DIFF $(cnt DIFF), NEWREFUSE $(cnt NEWREFUSE), NEWACCEPT $(cnt NEWACCEPT), TIMEOUT $(cnt TIMEOUT)"
} | tee "$OUT/summary.txt"
if [ "$got" = "$want" ] && [ "$(cnt DIFF)" = 0 ] && [ "$(cnt NEWREFUSE)" = 0 ] && [ "$(cnt NEWACCEPT)" = 0 ] && [ "$(cnt TIMEOUT)" = 0 ]; then
    echo "PASS: every listed slice byte-identical to the default fat build's; nothing newly refused; every newly accepted list leaves out the slice the default build fails in" | tee -a "$OUT/summary.txt"; exit 0
fi
echo "FAIL: see $OUT/results.txt (DIFF / NEWREFUSE / NEWACCEPT / TIMEOUT lines)" | tee -a "$OUT/summary.txt"; exit 1
