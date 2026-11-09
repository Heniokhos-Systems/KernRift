#!/bin/bash
# require_rows.sh <suite.log> <manifest> <known_reds>
#
# The LOCAL merge gate for #143 (plan rev 4, section 0 "Row manifest"); GitHub CI
# does not run it, because CI may legitimately SKIP rows whose tools it lacks.
# Byte-identical in the KernRift and MLRift trees.
#
# Fails (exit 1, one line per problem) unless ALL of these hold:
#   1. every name in <manifest> appears EXACTLY ONCE in the log, and that one
#      line is `  <name>: PASS` (optionally followed by ` (detail)`). A SKIP, a
#      FAIL, a duplicate or an absent name fails -- a tool guard with no else
#      branch shows up here as "absent";
#   2. no line reports SKIP for a row whose name contains `wine`, `qemu`,
#      `windows`, `win_`, `_win` or starts with `c7_` (the Windows/emulator
#      rows that exist before this work): locally every such tool is present,
#      so a SKIP there means a row quietly stopped running;
#   3. every name in <known_reds> appears EXACTLY ONCE, as a FAIL line
#      (`FAIL: <name> (...)` or `  <name>: FAIL (...)`). A PASS, a SKIP or an
#      absence fails: a known red that turns green must leave the file in the
#      same commit, and one that silently stops running is caught too;
#   4. no line of the log says a checker rule was "disabled by" the test-only
#      PE_UNWIND_CHECK_DISABLE knob (a disabled rule prints PASS);
#   5. no FAIL line names a row outside <known_reds>, and the suite's own
#      failure count (`=== Results: X/Y passed, N failed ===`, or with
#      suite-skip-hygiene's `, S skipped` counter, which must then be 0)
#      equals the number of known reds, which also catches a FAIL printed in
#      some other shape.
set -u
LOG="${1:?usage: require_rows.sh <suite.log> <manifest> <known_reds>}"
MAN="${2:?manifest}"; RED="${3:?known reds}"
for f in "$LOG" "$MAN" "$RED"; do [ -r "$f" ] || { echo "require_rows: cannot read $f"; exit 1; }; done
names() { grep -v '^[[:space:]]*#' "$1" | grep -v '^[[:space:]]*$' | sed 's/[[:space:]]*$//'; }
bad=0
problem() { echo "require_rows: $1"; bad=1; }
esc() { printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g'; }

# 1. manifest rows: exactly once, as PASS
nman=0
while IFS= read -r n; do
    nman=$((nman + 1))
    e=$(esc "$n")
    all=$(grep -cE "^  $e: |^FAIL: $e( |\$)" "$LOG")
    pass=$(grep -cE "^  $e: PASS( \(.*\))?\$" "$LOG")
    if [ "$all" = 0 ]; then problem "manifest row '$n' is absent from the log"
    elif [ "$all" != 1 ]; then problem "manifest row '$n' reports $all times"
    elif [ "$pass" != 1 ]; then problem "manifest row '$n': $(grep -m1 -E "^  $e: |^FAIL: $e( |\$)" "$LOG" | cut -c1-200)"
    fi
done < <(names "$MAN")

# 2. no SKIP on Windows/emulator rows
while IFS= read -r l; do
    problem "Windows/emulator row skipped: $(printf '%s' "$l" | cut -c1-200)"
done < <(grep -E '^  [^ ]+: SKIP' "$LOG" | grep -E '^  ([^ :]*(wine|qemu|windows|win_|_win)[^ :]*|c7_[^ :]*): SKIP')

# 3. known reds: exactly once, as FAIL
nred=0
declare -A ISRED=()
while IFS= read -r n; do
    nred=$((nred + 1)); ISRED["$n"]=1
    e=$(esc "$n")
    all=$(grep -cE "^  $e: |^FAIL: $e( |\$)" "$LOG")
    fl=$(grep -cE "^FAIL: $e( |\$)|^  $e: FAIL( |\$)" "$LOG")
    if [ "$all" = 0 ]; then problem "known red '$n' is absent from the log (it must still run, and fail)"
    elif [ "$all" != 1 ] || [ "$fl" != 1 ]; then problem "known red '$n' did not fail exactly once: $(grep -m1 -E "^  $e: |^FAIL: $e( |\$)" "$LOG" | cut -c1-200)"
    fi
done < <(names "$RED")

# 4. no rule switched off by the test-only knob anywhere in the log
while IFS= read -r l; do
    problem "a checker rule ran disabled: $(printf '%s' "$l" | cut -c1-200)"
done < <(grep -E 'disabled by PE_UNWIND_CHECK_DISABLE' "$LOG")

# 5. no other FAIL, and the suite's own count agrees
while IFS= read -r n; do
    [ -n "${ISRED[$n]+x}" ] || problem "row '$n' FAILED and is not a known red"
done < <( { grep -oE '^FAIL: [^ (]+' "$LOG" | sed 's/^FAIL: //'; grep -oE '^  [^ ]+: FAIL' "$LOG" | sed 's/^  //; s/: FAIL$//'; } | sed 's/:$//' | sort -u)
res=$(grep -E '^=== Results: [0-9]+/[0-9]+ passed, [0-9]+ failed(, [0-9]+ skipped)? ===' "$LOG" | tail -1)
if [ -z "$res" ]; then problem "no '=== Results' line: the suite did not finish"
else
    nf=$(sed -E 's/.* ([0-9]+) failed.*/\1/' <<< "$res")
    [ "$nf" = "$nred" ] || problem "the suite reports $nf failed, the known-red list has $nred"
    # suite-skip-hygiene's counter: every SKIP is counted, and REQUIRE_FULL_RUN=1
    # (the local gate's mode) turns each into a FAIL, so a local run has none.
    ns=$(sed -nE 's/.* ([0-9]+) skipped ===$/\1/p' <<< "$res")
    [ -z "$ns" ] || [ "$ns" = 0 ] || problem "the suite reports $ns skipped; the local gate runs with REQUIRE_FULL_RUN=1, which allows none"
fi
if [ "$bad" = 0 ]; then
    echo "require_rows: OK ($nman manifest rows PASS once each; $nred known reds FAIL once each; $res)"
    exit 0
fi
exit 1
