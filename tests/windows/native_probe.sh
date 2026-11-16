#!/bin/bash
# native_probe.sh -- run an in-process stack-walk probe natively, 3 times
# (#143 A14b, plan Task D step 4). Laptop side: inline PowerShell only (user
# ruling, phase 5).
#
#   native_probe.sh <image.exe> <want> [<map> <chain>]
#
# <want> is the exit code every run must give (`!N`: any code but N). With a
# lld-link /map and a comma-separated <chain>, the probe's printed frames
# ("<address> <module base> <module path>" lines, as
# tests/fixtures/pe_unwind_cprobe/host.c prints them) must name exactly
# <chain>, as tests/helpers/probe_chain.py --style=native-probe names them
# (#327; the suite row pe_unwind_obj_link_windows_wine uses the same helper):
# frames in the image by the map's symbols, at their offset from the module
# base the image was really loaded at (ASLR), the others by their module's
# file name (KERNEL32.DLL -> KERNEL32), a null frame as NULL.
# Prints each run and PASS/FAIL; exits 0 on PASS, 1 on FAIL, 2 on a transport
# error.
set -u -o pipefail
NATIVE_HOST="${NATIVE_HOST:-laptop}"
EXE="${1:?usage: native_probe.sh <image.exe> <want> [<map> <chain>]}"; WANT="${2:?want}"; MAP="${3:-}"; CHAIN="${4:-}"
NAME=$(basename "$EXE")
RD="C:\\Users\\pante\\pe_unwind_scratch\\prb$$"; RDF="C:/Users/pante/pe_unwind_scratch/prb$$"
SSH_OPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SSH_OPTS_DIR/ssh_opts.sh"   # NATIVE_SSH_OPTS (#268)
rps() { ssh "${NATIVE_SSH_OPTS[@]}" "$NATIVE_HOST" "powershell -NoProfile -NonInteractive -Command \"\$ProgressPreference='SilentlyContinue'; $1\"" < /dev/null; }
cleanup() {
    rps "for (\$i=0; \$i -lt 120 -and (Test-Path -LiteralPath '$RD'); \$i++) { Remove-Item -LiteralPath '$RD' -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath '$RD') { Start-Sleep -Milliseconds 500 } }; if ((Test-Path 'C:\\Users\\pante\\pe_unwind_scratch') -and -not (Get-ChildItem -Force 'C:\\Users\\pante\\pe_unwind_scratch')) { Remove-Item -Force 'C:\\Users\\pante\\pe_unwind_scratch' }; if (Test-Path -LiteralPath '$RD') { exit 1 }; exit 0" \
        || { echo "native_probe.sh: remote $RD not removed" >&2; exit 2; }
}
rps "New-Item -ItemType Directory -Force '$RD' | Out-Null; exit 0" > /dev/null || { echo "native_probe.sh: remote mkdir failed" >&2; exit 2; }
scp -q "${NATIVE_SSH_OPTS[@]}" "$EXE" "$NATIVE_HOST:$RDF/$NAME" < /dev/null || { cleanup; exit 2; }
# three runs; each prints RUN <k> <LASTEXITCODE>, then the probe's own lines,
# and the image base of the probe's module for the address mapping
OUT=$(rps "Set-Location '$RD'; for (\$k=1; \$k -le 3; \$k++) { \$o=& '$RD\\$NAME' 2>&1; 'RUN ' + \$k + ' ' + \$LASTEXITCODE; \$o | ForEach-Object { 'P ' + \$_ } }; exit 0" | tr -d '\r')
TRC=$?
cleanup
[ "$TRC" = 0 ] || { echo "native_probe.sh: remote run failed ($TRC)" >&2; exit 2; }
printf '%s\n' "$OUT"
TF=$(mktemp); printf '%s\n' "$OUT" > "$TF"
python3 -B - "$NAME" "$WANT" "$MAP" "$CHAIN" "$TF" "$(cd "$(dirname "$0")/../helpers" && pwd)" <<'PYEOF'
import re, sys
name, want, mapf, chain = sys.argv[1:5]
helpers = sys.argv[6]
runs, cur = [], None
for l in open(sys.argv[5], encoding='latin-1').read().split('\n'):
    m = re.match(r'^RUN (\d+) (-?\d+)$', l)
    if m:
        cur = {'rc': int(m.group(2)), 'lines': []}; runs.append(cur); continue
    if l.startswith('P ') and cur is not None:
        cur['lines'].append(l[2:])
bad = []
if len(runs) != 3:
    bad.append('%d runs, want 3' % len(runs))
for k, r in enumerate(runs):
    ok = (r['rc'] != int(want[1:])) if want.startswith('!') else (r['rc'] == int(want))
    if not ok:
        bad.append('run %d exit %d, want %s' % (k + 1, r['rc'], want))
if mapf and chain:
    import os, subprocess, tempfile
    helper = os.path.join(helpers, 'probe_chain.py')
    for k, r in enumerate(runs):
        frames = [l for l in r['lines'] if re.match(r'^[0-9a-f]{16} ', l)]
        with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as f:
            f.write('\n'.join(frames) + '\n')
        try:
            p = subprocess.run([sys.executable, '-B', helper, mapf, f.name, name, '--style=native-probe'],
                               capture_output=True, text=True, timeout=60)
        finally:
            os.unlink(f.name)
        named = p.stdout.strip()
        if p.returncode != 0 or named != chain:
            bad.append('run %d chain %s, want %s' % (k + 1, named or p.stderr.strip()[-120:], chain))
print('FAIL: ' + '; '.join(bad) if bad else 'PASS')
sys.exit(1 if bad else 0)
PYEOF
RC=$?
rm -f "$TF"
exit $RC
