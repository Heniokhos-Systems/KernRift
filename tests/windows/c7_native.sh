#!/bin/bash
# c7_native.sh -- the C7 rows natively (#143 A14b, spec 8.6 (a) table, C7
# row family). KernRift tree.
#
#   c7_native.sh <suite.log>
#
# <suite.log> is a run of tests/run_tests.sh with KR_WINE pointing at
# tests/windows/native_exec.sh (native_suite.sh makes it): C7_WINE follows
# KR_WINE, so every C7 row that runs a program through c7_wine / c7_wine_child
# ran it natively. Prints one line per C7 Windows row,
#   C7ROW <row> PASS|FAIL|SKIP <detail>
# The CP932 rows (C7_JA=1: the Japanese-locale prefix) are SKIP: the laptop's
# ANSI code page is not 932 and changing it needs the user's approval; their
# proof is c7_leaf_blobs_unchanged, c7_cp932_leaf_native_x86_64 and the Wine
# CP932 rows. Exit 0 when no non-CP932 C7 row FAILed, 1 otherwise.
set -u
LOG="${1:?usage: c7_native.sh <suite.log>}"
bad=0; n=0
while IFS= read -r l; do
    if [[ "$l" =~ ^\ +(c7_[a-z0-9_]+_wine):\ (PASS|FAIL|SKIP)(.*)$ ]]; then
        r=${BASH_REMATCH[1]}; st=${BASH_REMATCH[2]}; d=${BASH_REMATCH[3]}
        n=$((n + 1))
        if [[ "$r" =~ (cp932|_ja_) ]]; then
            echo "C7ROW $r SKIP (CP932: the laptop's ANSI code page is not 932; native result was $st$d)"
        else
            echo "C7ROW $r $st$d"
            [ "$st" = PASS ] || bad=1
        fi
    fi
done < "$LOG"
[ "$n" -gt 0 ] || { echo "c7_native.sh: no C7 Windows rows in $LOG"; exit 1; }
exit $bad
