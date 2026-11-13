#!/bin/bash
# CI-BRANCH-ONLY (ci/kr-2-11-1-t0; never merged): passes a suite log whose
# only failures are the v2.11.1 known reds that M3 removes (#226 x30 rows,
# #235) and #160, so the jobs that `needs: build-test` run on a T0 test push.
# Exit 0 iff every FAIL line names a known red and the summary's failed count
# equals the number of FAIL lines.
LOG="$1"
KNOWN=" asm_live_across_out_x30_arm64_legacy asm_live_across_inw_x30_arm64_legacy asm_live_across_clob_x30_arm64_legacy asm_legacy_obj_callee_saved_x86_64 pe_unwind_host_rsi_across_kr "
NAMES=$(sed -nE 's/^FAIL: ([A-Za-z0-9_]+).*/\1/p; s/^  ([A-Za-z0-9_]+): FAIL.*/\1/p' "$LOG")
N=$(printf '%s\n' "$NAMES" | grep -c .)
SUM=$(sed -nE 's/^=== Results: [0-9]+\/[0-9]+ passed, ([0-9]+) failed.*/\1/p' "$LOG" | tail -1)
bad=""
for n in $NAMES; do case "$KNOWN" in *" $n "*) ;; *) bad="$bad $n" ;; esac; done
echo "ci_known_reds: $N FAIL line(s): $(echo $NAMES); summary says ${SUM:-<none>} failed"
if [ -z "$bad" ] && [ -n "$SUM" ] && [ "$SUM" = "$N" ]; then echo "ci_known_reds: only known reds -- tolerated on this CI test branch"; exit 0; fi
echo "ci_known_reds: NOT only known reds:${bad:- (count mismatch)}"; exit 1
