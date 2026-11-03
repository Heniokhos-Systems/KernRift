#!/bin/bash
# diff_ir_legacy_stdout_win.sh [<compiler>] [<out_dir>]
#
# #143 A19d(ii) whole-program supplement (plan A19d(ii), re-review finding 8).
# NOT a suite row: a gate run with the legacy outgoing-area fold, output
# archived with the gate. The Windows/Wine variant of
# tests/diff_ir_legacy_stdout.sh: every std-free program of that file (its
# `dc` rows without an `import`) is built for x86_64 Windows with the IR and
# with --legacy, both images run under Wine (timeout only: Wine segfaults
# under ulimit -v), and the two must agree on stdout and exit status. The
# program list is read from tests/diff_ir_legacy_stdout.sh, so a row added
# there is covered here too.
#
# Both sides must be PE images that Wine ran to an exit status (a non-PE
# image is refused, since Wine exits 3 for it on both sides). Exit 0 only if
# every row agrees; last line "WIN PARITY OK n/n" or "WIN PARITY GAPS ...".
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KRC="$(readlink -f "${1:-$ROOT/build/krc2}")"
OUT="${2:-$HOME/.cache/pe_unwind/gates/A19d/diff_ir_legacy_stdout_win}"
WINE="$(command -v wine || true)"
[ -n "$WINE" ] || { echo "needs wine" >&2; exit 2; }
[ -x "$KRC" ] || { echo "compiler not executable: $KRC" >&2; exit 2; }
mkdir -p "$OUT/pfx"; OUT="$(cd "$OUT" && pwd)"
DIV=0; TOTAL=0
run_one() {
    local flags="$1" tag="$2" exe="$OUT/$NAME.$2.exe"
    if ! ( ulimit -v 2000000; timeout 120 "$KRC" --arch=x86_64 --target=windows --emit=pe $flags "$OUT/$NAME.kr" -o "$exe" ) > "$OUT/$NAME.$tag.build" 2>&1; then
        echo "<CERR>"; return; fi
    # A non-PE image (e.g. a missing --emit=pe) makes Wine exit 3 on both
    # sides, which would "agree": refuse it outright.
    [ "$(head -c 2 "$exe")" = MZ ] || { echo "<NOT-PE>"; return; }
    (cd "$OUT" && WINEPREFIX="$OUT/pfx" WINEDLLOVERRIDES=winedbg.exe=d WINEDEBUG=-all timeout 120 "$WINE" "./$NAME.$tag.exe" > "$OUT/$NAME.$tag.out" 2> "$OUT/$NAME.$tag.err"); local rc=$?
    printf '%s<rc=%s>' "$(tr -d '\r' < "$OUT/$NAME.$tag.out")" "$rc"
}
dc() {
    NAME="$1"; local src="$2"
    case "$src" in *import*) return;; esac
    TOTAL=$((TOTAL+1))
    printf '%s\n' "$src" > "$OUT/$NAME.kr"
    local a b; a=$(run_one "" ir); b=$(run_one "--legacy" lg)
    if [ "$a" = "$b" ] && [[ "$a" == *"<rc="* ]]; then echo "agree    $NAME: [$a]"; return; fi
    DIV=$((DIV+1)); echo "DIVERGE  $NAME"; echo "   IR    : [$a]"; echo "   legacy: [$b]"
}
SRC="$ROOT/tests/diff_ir_legacy_stdout.sh"
eval "$(sed -n '/^dc "/,/^echo "----"/p' "$SRC" | sed '$d')"
echo "----"
if [ "$DIV" = 0 ] && [ "$TOTAL" -gt 0 ]; then echo "WIN PARITY OK $TOTAL/$TOTAL"; exit 0
else echo "WIN PARITY GAPS: $DIV of $TOTAL diverged"; exit 1; fi
