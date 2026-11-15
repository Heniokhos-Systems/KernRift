#!/bin/bash
# CI-BRANCH-ONLY (ci/kr-2-11-1-m3; never merged): passes a suite log whose
# only failure is the v2.11.1 known red #160 (M3 turned the #226 x30 rows and
# #235 green), so the jobs that `needs: build-test` run on an M3 test push.
# Since ubuntu-latest became ubuntu-26.04 (2026-11-15 run) the 14 xtensa boot
# rows are the #228 environment reds (qemu-system-xtensa 10.2; T1 fixes them)
# here too, so they are tolerated by name as well.
# Exit 0 iff every FAIL line names a known red and the summary's failed count
# equals the number of FAIL lines.
LOG="$1"
KNOWN=" pe_unwind_host_rsi_across_kr xtensa_asm_boot xtensa_bigframe_boot xtensa_bss_boot xtensa_callind_clobber_boot xtensa_capstone_boot xtensa_fnptr_boot xtensa_globals_boot xtensa_hello_boot xtensa_lx60_exit_42 xtensa_many_args_boot xtensa_memstack_boot xtensa_str_boot xtensa_stress_boot xtensa_strfmt_boot "
NAMES=$(sed -nE 's/^FAIL: ([A-Za-z0-9_]+).*/\1/p; s/^  ([A-Za-z0-9_]+): FAIL.*/\1/p' "$LOG")
N=$(printf '%s\n' "$NAMES" | grep -c .)
SUM=$(sed -nE 's/^=== Results: [0-9]+\/[0-9]+ passed, ([0-9]+) failed.*/\1/p' "$LOG" | tail -1)
bad=""
for n in $NAMES; do case "$KNOWN" in *" $n "*) ;; *) bad="$bad $n" ;; esac; done
echo "ci_known_reds: $N FAIL line(s): $(echo $NAMES); summary says ${SUM:-<none>} failed"
if [ -z "$bad" ] && [ -n "$SUM" ] && [ "$SUM" = "$N" ]; then echo "ci_known_reds: only known reds -- tolerated on this CI test branch"; exit 0; fi
echo "ci_known_reds: NOT only known reds:${bad:- (count mismatch)}"; exit 1
