#!/bin/bash
# native_suite.sh -- the whole Windows corpus of the suite, natively on the
# laptop (#143 A14b, spec 8.6 step 1, plan Task D step 1). KernRift tree.
#
#   native_suite.sh <out dir>
#   native_suite.sh --summary-only <out dir>   (re-judge an existing run)
#
# Runs tests/run_tests.sh once with KR_WINE=tests/windows/native_exec.sh (so
# every Wine row -- t10_wine, t12_wine, c7_wine, the arsh/std rows -- runs its
# program natively through the wrapper, in one NATIVE_SESSION whose remote
# cache is removed at the end), then the per-family native scripts, and writes
# <out dir>/summary.txt through tests/windows/native_judge.py, whose rules
# cannot pass vacuously: the log must be complete (its "=== Results:" line),
# every row of tests/windows/native_corpus.lst must appear exactly once, every
# FAIL anywhere in the log is a native FAIL unless tests/windows/
# native_reclass.lst reclassifies the row AND its failure reason is the one the
# class allows (fault rows: exit code and stdout as wanted, checker PASS, only
# the Wine-trace clause failed; CP932 rows: "ANSI code page is not 932"; ...),
# and the per-row scripts (native_concurrent.sh, native_hostrows.sh) replace
# their rows and must PASS. The reclass list names each skipped row's native
# proof (cdb_chain.sh, native_probe.sh).
# KRC_RAW is the bare compiler, as `make test` sets it (the lexer/import rows
# and compiler_builds_itself_every_target_and_mode need it).
# The suite's stdin is /dev/null: native_exec.sh forwards its stdin to the
# program, so only a row that redirects stdin itself (the win_file_std* rows)
# may hand it input; an inherited open pipe would stall every job.
# native_concurrent.sh bounds itself, every call under timeout -k 10 (KILL
# 10 s after the TERM): 7 compiles x 70 s + mkdir 310 s + 3 scp x 310 s + 3
# row runs x 610 s + cleanup 310 s = 3870 s at most. It runs under
# timeout -k 60 4000 (130 s of slack, then KILL 60 s after the TERM) as a
# backstop only; killed, it leaves its rows without a result, which the judge
# FAILs.
# Exit: the judge's (0 when nothing FAILed).
set -u
SUMONLY=0; if [ "${1:-}" = --summary-only ]; then SUMONLY=1; shift; fi
OUT="${1:?usage: native_suite.sh [--summary-only] <out dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"; TREE="$(cd "$HERE/../.." && pwd)"
mkdir -p "$OUT" || exit 2
if [ "$SUMONLY" = 0 ]; then
export NATIVE_SESSION="suite$$"
printf '#!/bin/bash\nexec "%s/build/krc2" --arch=x86_64 "$@"\n' "$TREE" > "$OUT/krc-test"; chmod +x "$OUT/krc-test"
( cd "$TREE" && KRC="$OUT/krc-test" KRC_RAW="$TREE/build/krc2" KR_WINE="$HERE/native_exec.sh" NATIVE_SESSION="$NATIVE_SESSION" timeout 14400 bash tests/run_tests.sh < /dev/null ) > "$OUT/suite.log" 2>&1
"$HERE/native_exec.sh" --end-session || echo "native_suite.sh: session cleanup failed" >&2
timeout -k 60 4000 bash "$HERE/native_concurrent.sh" "$TREE/build/krc2" "$TREE/tests/fixtures" > "$OUT/concurrent.txt" 2>&1
bash "$HERE/native_hostrows.sh" "$TREE/build/krc2" "$TREE/tests/fixtures" > "$OUT/hostrows.txt" 2>&1
fi
python3 -B "$HERE/native_judge.py" "$OUT"
