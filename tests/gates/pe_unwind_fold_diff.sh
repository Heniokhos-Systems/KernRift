#!/bin/bash
# pe_unwind_fold_diff.sh [<compiler>] [<out_dir>]
#
# #143 A19d(ii) differential gate (spec 2.5.7, plan A19d(ii)). NOT a suite
# row: run with every commit that touches the x86_64 legacy outgoing-area
# fold, output archived (~/.cache/pe_unwind/gates/A19d/ by default).
#
# 1. tests/fixtures/win_fold_diff/fold.kr: every sized-site family of the
#    x86_64 legacy backend (named calls and call_ptr with 0..8 arguments, a
#    struct by value, heap, file, output, environment builtins), each called
#    from a folded function f_<family> and from an SP-moving twin m_<family>.
#    Built for x86_64 Windows with --legacy and with the IR, each also with
#    --debug; all four run under Wine and must print the same stdout with the
#    same exit status, and in each the f_/m_ pair must agree line by line.
# 2. --test-out-audit on the legacy build: every f_<family> is SP-fixed,
#    every m_<family> SP-moving, and no audit violation is reported.
# 3. The exec family (exec_process, exec_process_argv), from a folded and
#    from an SP-moving function, legacy and IR: each process exits with the
#    child's status 7.
# 4. win-file-errors' p_*/s_* probe pairs: audit verdicts, and the Wine output
#    of the stdin-free ones against their .windows.expected (see section 4);
#    4b. the frame bias of emit_win_rsp_lea's slot addresses.
# Compiles run under ulimit -v 2000000 and timeout 120; Wine runs under a
# timeout only (Wine segfaults under ulimit -v). Last line "FOLD DIFF OK"
# (exit 0) or "FOLD DIFF FAILED: <reasons>" (exit 1).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KRC="$(readlink -f "${1:-$ROOT/build/krc2}")"
OUT="${2:-$HOME/.cache/pe_unwind/gates/A19d/fold_diff}"
FX="$ROOT/tests/fixtures/win_fold_diff"
WINE="$(command -v wine || true)"
[ -n "$WINE" ] || { echo "needs wine" >&2; exit 2; }
[ -x "$KRC" ] || { echo "compiler not executable: $KRC" >&2; exit 2; }
mkdir -p "$OUT/pfx"; OUT="$(cd "$OUT" && pwd)"
BAD=""
build() { # <src> <exe> <flags...>
    local src="$1" exe="$2"; shift 2
    ( ulimit -v 2000000; timeout 120 "$KRC" --arch=x86_64 --target=windows --emit=pe "$@" "$src" -o "$OUT/$exe" ) > "$OUT/$exe.build" 2>&1 \
        && [ "$(head -c 2 "$OUT/$exe")" = MZ ]
}
run() { # <exe> -> stdout (CR stripped) + "<rc=N>"
    (cd "$OUT" && WINEPREFIX="$OUT/pfx" WINEDLLOVERRIDES=winedbg.exe=d WINEDEBUG=-all timeout 120 "$WINE" "./$1" > "$OUT/$1.out" 2> "$OUT/$1.err"); local rc=$?
    printf '%s<rc=%s>' "$(tr -d '\r' < "$OUT/$1.out")" "$rc"
}
# 1. fold.kr, four builds
REF=""
for cfg in "lg|--legacy" "ir|" "lgd|--legacy --debug" "ird|--debug"; do
    tag="${cfg%%|*}"; flags="${cfg#*|}"
    if ! build "$FX/fold.kr" "fold_$tag.exe" $flags; then BAD="$BAD fold_$tag:build"; echo "fold_$tag: BUILD FAILED"; continue; fi
    r=$(run "fold_$tag.exe"); echo "fold_$tag: [$(tr '\n' ' ' <<< "$r")]"
    [[ "$r" == *"<rc=0>" ]] || BAD="$BAD fold_$tag:rc"
    # the f_/m_ pair of every family prints two equal numbers (14 lines);
    # f_out and m_out also print their own text, "F fs fl" then "M ms ml"
    nums=$(sed 's/<rc=.*>$//' <<< "$r" | grep -v '^[A-Za-z]')
    pairs=$(paste - - <<< "$nums" | awk '$1 != $2' | wc -l)
    [ "$pairs" = 0 ] || BAD="$BAD fold_$tag:pair-mismatch($pairs)"
    [ "$(wc -l <<< "$nums")" = 14 ] || BAD="$BAD fold_$tag:lines"
    [ "$(grep '^[A-Za-z]' <<< "$r" | tr '\n' ' ')" = "F fs fl M ms ml " ] || BAD="$BAD fold_$tag:out-text"
    if [ -z "$REF" ]; then REF="$r"; elif [ "$r" != "$REF" ]; then BAD="$BAD fold_$tag:differs-from-fold_lg"; fi
done
# 2. audit verdicts on the legacy build
( ulimit -v 2000000; timeout 120 "$KRC" --legacy --arch=x86_64 --target=windows --emit=pe --test-out-audit "$FX/fold.kr" -o "$OUT/fold_audit.exe" ) > "$OUT/fold_audit.log" 2>&1 || BAD="$BAD audit:build"
grep -q '^out-audit:' "$OUT/fold_audit.log" && BAD="$BAD audit:violations"
for fam in named ptr struct heap file out env; do
    grep -q "^out-audit-fn: 'f_$fam' SP-fixed " "$OUT/fold_audit.log" || BAD="$BAD audit:f_$fam-not-fixed"
    grep -q "^out-audit-fn: 'm_$fam' SP-moving " "$OUT/fold_audit.log" || BAD="$BAD audit:m_$fam-not-moving"
done
echo "audit: $(grep -c "^out-audit-fn: '[fm]_" "$OUT/fold_audit.log") f_/m_ verdicts, $(grep -c '^out-audit:' "$OUT/fold_audit.log") violations"
# 3. exec family
build "$FX/child.kr" child.exe || BAD="$BAD child:build"
for p in exec_process_f exec_process_m exec_process_argv_f exec_process_argv_m; do
    for cfg in "lg|--legacy" "ir|"; do
        tag="${cfg%%|*}"; flags="${cfg#*|}"
        if ! build "$FX/$p.kr" "${p}_$tag.exe" $flags; then BAD="$BAD ${p}_$tag:build"; continue; fi
        r=$(run "${p}_$tag.exe"); echo "${p}_$tag: [$r]"
        [ "$r" = "<rc=7>" ] || BAD="$BAD ${p}_$tag:$r"
    done
done
# 4. win-file-errors' probe pairs (its merge, Task 9 / spec 7.4, review #7):
#    every p_* probe is print-free (SP-fixed when folded) and its s_* twin
#    prints (SP-moving). On the five --legacy fixtures (win_file_errors_read is
#    IR-only: read() has no legacy builtin), --test-out-audit on the x86_64
#    --legacy build reports no violation, every p_* SP-fixed and every s_*
#    SP-moving. win_file_errors.kr and win_alloc_wrap.kr (no stdin) also run
#    under Wine, IR and --legacy: each must print its .windows.expected, and
#    every `name V` line must equal its `name_m V` line.
for wf in win_file_errors win_file_std win_file_std_pipe win_file_std_write win_alloc_wrap; do
    ( ulimit -v 2000000; timeout 120 "$KRC" --legacy --arch=x86_64 --target=windows --emit=pe --test-out-audit "$ROOT/tests/fixtures/$wf.kr" -o "$OUT/${wf}_audit.exe" ) > "$OUT/${wf}_audit.log" 2>&1 || BAD="$BAD $wf:audit-build"
    grep -q '^out-audit:' "$OUT/${wf}_audit.log" && BAD="$BAD $wf:audit-violations"
    np=$(grep -c "^out-audit-fn: 'p_" "$OUT/${wf}_audit.log"); ns=$(grep -c "^out-audit-fn: 's_" "$OUT/${wf}_audit.log")
    [ "$np" -gt 0 ] && [ "$(grep -c "^out-audit-fn: 'p_[A-Za-z0-9_]*' SP-fixed" "$OUT/${wf}_audit.log")" = "$np" ] || BAD="$BAD $wf:p-not-all-fixed"
    [ "$ns" -gt 0 ] && [ "$(grep -c "^out-audit-fn: 's_[A-Za-z0-9_]*' SP-moving" "$OUT/${wf}_audit.log")" = "$ns" ] || BAD="$BAD $wf:s-not-all-moving"
    echo "$wf audit: $np p_ SP-fixed, $ns s_ SP-moving, $(grep -c '^out-audit:' "$OUT/${wf}_audit.log") violations"
done
for wf in win_file_errors win_alloc_wrap; do
    for cfg in "lg|--legacy" "ir|"; do
        tag="${cfg%%|*}"; flags="${cfg#*|}"
        if ! build "$ROOT/tests/fixtures/$wf.kr" "${wf}_$tag.exe" $flags; then BAD="$BAD ${wf}_$tag:build"; continue; fi
        r=$(run "${wf}_$tag.exe")
        [[ "$r" == *"<rc=0>" ]] || BAD="$BAD ${wf}_$tag:rc"
        out=$(sed 's/<rc=.*>$//' <<< "$r")
        [ "$out" = "$(tr -d '\r' < "$ROOT/tests/fixtures/$wf.windows.expected")" ] || BAD="$BAD ${wf}_$tag:not-expected"
        mism=$(awk '{v[$1]=$2} END {for (k in v) if (k !~ /_m$/ && (k "_m") in v && v[k] != v[k "_m"]) print k}' <<< "$out" | tr '\n' ' ')
        [ -z "$mism" ] || BAD="$BAD ${wf}_$tag:pair-mismatch($mism)"
        echo "${wf}_$tag: $(wc -l <<< "$out") lines, $(awk '$1 ~ /_m$/' <<< "$out" | wc -l) p/s pairs${mism:+, mismatched: $mism}"
    done
done
# 4b. ...and emit_win_rsp_lea's slot addresses carry the cg_slot_off bias
#    exactly once (spec 7.2 rule 3; merge review r19, finding 7): in every
#    p_*/s_* function of the x86_64 --legacy builds of win_file_errors.kr and
#    win_file_std.kr, each ReadFile byte-count / GetFileSizeEx size `lea`
#    addresses the slot the function then loads, with disp32 from 0x80 up
#    (tests/helpers/win_rsp_lea_check.py; a missing bias is too small, a
#    double one too large by the OUT area).
for wf in win_file_errors win_file_std; do
    ( cd "$ROOT"; ulimit -v 2000000; timeout 120 "$KRC" --legacy --arch=x86_64 --target=windows --emit=pe --test-listing="$OUT/${wf}_lea.lst" "tests/fixtures/$wf.kr" -o "$OUT/${wf}_lea.exe" ) > "$OUT/${wf}_lea.log" 2>&1 || BAD="$BAD $wf:lea-build"
done
python3 "$ROOT/tests/helpers/win_rsp_lea_check.py" "$OUT/win_file_errors_lea.lst" "$OUT/win_file_std_lea.lst" > "$OUT/rsp_lea_check.log" 2>&1 || BAD="$BAD rsp-lea-bias"
tail -1 "$OUT/rsp_lea_check.log"
echo "----"
if [ -z "$BAD" ]; then echo "FOLD DIFF OK"; exit 0; else echo "FOLD DIFF FAILED:$BAD"; exit 1; fi
