#!/bin/bash
# native_suite.sh -- the whole Windows corpus of the suite, natively on the
# laptop (#143 A14b, spec 8.6 step 1, plan Task D step 1). KernRift tree.
#
#   native_suite.sh <out dir>
#
# Runs tests/run_tests.sh once with KR_WINE=tests/windows/native_exec.sh (so
# every Wine row -- t10_wine, t12_wine, c7_wine, the arsh/std rows -- runs its
# program natively through the wrapper, in one NATIVE_SESSION whose remote
# cache is removed at the end), then the per-family native scripts, and writes
# <out dir>/summary.txt: one line per Windows-corpus row,
#   <row>: PASS | FAIL (why) | SKIP (reason)
# Windows-corpus rows are the suite rows whose name contains "wine" plus the
# C7 rows that run a program through c7_wine (c7_native.sh lists them). A row
# the wrapper cannot carry is not reported as its native FAIL but as a counted
# SKIP with the reason, and its replacement proof is named:
#   * CP932 rows (c7_*_cp932*/c7_*_dbcs*_windows_wine: the laptop's ANSI code
#     page is not 932) -> c7_leaf_blobs_unchanged, c7_cp932_leaf_native_x86_64
#     and the Wine CP932 rows (user-approved locale switch only);
#   * the concurrent row sys_last_errno_windows_wine -> native_concurrent.sh,
#     whose result replaces it;
#   * Wine-only plumbing (rows that read Wine's +unwind trace, the winedbg
#     override row) -> cdb_chain.sh and the probes (Task D steps 3-4).
# Exit 0 when no row FAILed, 1 otherwise.
set -u
OUT="${1:?usage: native_suite.sh <out dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"; TREE="$(cd "$HERE/../.." && pwd)"
mkdir -p "$OUT" || exit 2
export NATIVE_SESSION="suite$$"
printf '#!/bin/bash\nexec "%s/build/krc2" --arch=x86_64 "$@"\n' "$TREE" > "$OUT/krc-test"; chmod +x "$OUT/krc-test"
( cd "$TREE" && KRC="$OUT/krc-test" KR_WINE="$HERE/native_exec.sh" NATIVE_SESSION="$NATIVE_SESSION" timeout 14400 bash tests/run_tests.sh ) > "$OUT/suite.log" 2>&1
"$HERE/native_exec.sh" --end-session || echo "native_suite.sh: session cleanup failed" >&2
bash "$HERE/native_concurrent.sh" "$TREE/build/krc2" "$TREE/tests/fixtures" > "$OUT/concurrent.txt" 2>&1
bash "$HERE/c7_native.sh" "$OUT/suite.log" > "$OUT/c7.txt" 2>&1
python3 -B - "$OUT" <<'PYEOF'
import re, sys
out = sys.argv[1]
log = open(out + '/suite.log', encoding='utf-8', errors='replace').read().split('\n')
conc = open(out + '/concurrent.txt', encoding='utf-8', errors='replace').read()
c7 = set(l.split()[1] for l in open(out + '/c7.txt', encoding='utf-8', errors='replace') if l.startswith('C7ROW '))
rows = {}
for l in log:
    m = re.match(r'^\s+([A-Za-z0-9_]+): (PASS|FAIL|SKIP)\b(.*)$', l) or re.match(r'^(FAIL): ([A-Za-z0-9_]+) (.*)$', l)
    if not m:
        continue
    if m.group(1) == 'FAIL' and l.startswith('FAIL:'):
        name, st, why = m.group(2), 'FAIL', m.group(3)
    else:
        name, st, why = m.group(1), m.group(2), m.group(3).strip()
    if 'wine' in name or name in c7:
        rows[name] = (st, why)
cp932 = re.compile(r'(cp932|dbcs|_ja_|_lead)', re.I)
plumbing = re.compile(r'^(pe_unwind_.*_fault.*_windows_wine|pe_unwind_no_unwind_switch|wine_crash_override_does_not_mask|pe_unwind_obj_link_windows_wine)$')
lines, nf = [], 0
for name in sorted(rows):
    st, why = rows[name]
    if name == 'sys_last_errno_windows_wine':
        m = re.search(r'sys_last_errno_windows_wine: (PASS|FAIL)(.*)', conc)
        st, why = (m.group(1), 'native_concurrent.sh' + m.group(2)) if m else ('FAIL', 'native_concurrent.sh gave no result')
    elif st == 'FAIL' and cp932.search(name):
        st, why = 'SKIP', '(ANSI code page is not 932; covered by c7_leaf_blobs_unchanged, c7_cp932_leaf_native_x86_64 and the Wine CP932 rows; native only after a user-approved locale switch) native: ' + why[:120]
    elif st == 'FAIL' and plumbing.match(name):
        st, why = 'SKIP', '(Wine-only plumbing: +unwind trace / winedbg / Wine exit counts; proven natively by cdb_chain.sh and the probes, Task D steps 3-4) native: ' + why[:120]
    if st == 'FAIL':
        nf += 1
    lines.append('%s: %s %s' % (name, st, why))
open(out + '/summary.txt', 'w').write('\n'.join(lines) + '\n')
n = {s: sum(1 for l in lines if (': %s ' % s) in l) for s in ('PASS', 'FAIL', 'SKIP')}
print('native corpus: %d rows -- PASS %d, FAIL %d, SKIP %d (see %s/summary.txt)' % (len(lines), n['PASS'], n['FAIL'], n['SKIP'], out))
sys.exit(1 if nf else 0)
PYEOF
