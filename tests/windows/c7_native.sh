#!/bin/bash
# c7_native.sh -- the C7 rows of a native suite run (#143 A14b, spec 8.6 (a)
# table, C7 row family). KernRift tree.
#
#   c7_native.sh <native_suite out dir>
#
# KR_WINE redirects C7_WINE too (run_tests.sh: both come from wine_path), so
# in a native_suite.sh run every C7 row that runs a program through c7_wine /
# c7_wine_child ran it natively. This prints those rows as tests/windows/
# native_judge.py judges them -- the same rules and the same CP932 rule
# ("ANSI code page is not 932" in the reason) as the whole-corpus summary --
# and exits 1 when one of them FAILed.
set -u
exec python3 -B "$(cd "$(dirname "$0")" && pwd)/native_judge.py" "${1:?usage: c7_native.sh <native_suite out dir>}" --c7
