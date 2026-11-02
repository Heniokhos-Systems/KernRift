#!/bin/bash
# native_probe.sh -- run an in-process stack-walk probe natively, 3 times
# (#143 A14b, plan Task D step 4; byte-identical in the KernRift and MLRift
# trees). Laptop side: inline PowerShell only (user ruling, phase 5).
#
#   native_probe.sh <image.exe> <want> [<map> <chain>]
#
# <want> is the exit code every run must give (`!N`: any code but N). With a
# lld-link /map and a comma-separated <chain>, the probe's printed frames
# ("<address> <module path>" lines, as tests/fixtures/pe_unwind_cprobe/host.c
# prints them) must name exactly <chain>: frames in the image are named by the
# map's symbols, the others by their module's file name (KERNEL32.DLL ->
# KERNEL32), a null frame as NULL. The image is relocated natively (ASLR), so
# image frames are mapped by their offset from the image base, which the
# script takes from the first frame's module (the image itself).
# Prints each run and PASS/FAIL; exits 0 on PASS, 1 on FAIL, 2 on a transport
# error.
set -u -o pipefail
NATIVE_HOST="${NATIVE_HOST:-laptop}"
EXE="${1:?usage: native_probe.sh <image.exe> <want> [<map> <chain>]}"; WANT="${2:?want}"; MAP="${3:-}"; CHAIN="${4:-}"
NAME=$(basename "$EXE")
RD="C:\\Users\\pante\\pe_unwind_scratch\\prb$$"; RDF="C:/Users/pante/pe_unwind_scratch/prb$$"
rps() { ssh -o BatchMode=yes "$NATIVE_HOST" "powershell -NoProfile -NonInteractive -Command \"\$ProgressPreference='SilentlyContinue'; $1\"" < /dev/null; }
cleanup() {
    rps "for (\$i=0; \$i -lt 120 -and (Test-Path -LiteralPath '$RD'); \$i++) { Remove-Item -LiteralPath '$RD' -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath '$RD') { Start-Sleep -Milliseconds 500 } }; if ((Test-Path 'C:\\Users\\pante\\pe_unwind_scratch') -and -not (Get-ChildItem -Force 'C:\\Users\\pante\\pe_unwind_scratch')) { Remove-Item -Force 'C:\\Users\\pante\\pe_unwind_scratch' }; if (Test-Path -LiteralPath '$RD') { exit 1 }; exit 0" \
        || { echo "native_probe.sh: remote $RD not removed" >&2; exit 2; }
}
rps "New-Item -ItemType Directory -Force '$RD' | Out-Null; exit 0" > /dev/null || { echo "native_probe.sh: remote mkdir failed" >&2; exit 2; }
scp -q -o BatchMode=yes "$EXE" "$NATIVE_HOST:$RDF/$NAME" < /dev/null || { cleanup; exit 2; }
# three runs; each prints RUN <k> <LASTEXITCODE>, then the probe's own lines,
# and the image base of the probe's module for the address mapping
OUT=$(rps "Set-Location '$RD'; for (\$k=1; \$k -le 3; \$k++) { \$o=& '$RD\\$NAME' 2>&1; 'RUN ' + \$k + ' ' + \$LASTEXITCODE; \$o | ForEach-Object { 'P ' + \$_ } }; exit 0" | tr -d '\r')
TRC=$?
cleanup
[ "$TRC" = 0 ] || { echo "native_probe.sh: remote run failed ($TRC)" >&2; exit 2; }
printf '%s\n' "$OUT"
TF=$(mktemp); printf '%s\n' "$OUT" > "$TF"
python3 -B - "$NAME" "$WANT" "$MAP" "$CHAIN" "$TF" <<'PYEOF'
import re, sys
name, want, mapf, chain = sys.argv[1:5]
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
    syms = []
    for ln in open(mapf, encoding='latin-1'):
        m = re.match(r'^\s*0001:[0-9a-f]{8}\s+(\S+)\s+([0-9a-f]{16})\s+\S+\s*$', ln)
        if m:
            syms.append((int(m.group(2), 16), m.group(1)))
    syms.sort()
    pref = None
    for ln in open(mapf, encoding='latin-1'):
        m = re.match(r'^\s*Preferred load address is ([0-9a-f]+)', ln)
        if m:
            pref = int(m.group(1), 16)
    for k, r in enumerate(runs):
        frames = [l.split(' ', 1) for l in r['lines'] if re.match(r'^[0-9a-f]{16} ', l)]
        # ASLR moves the image by a multiple of 64 KiB and the probe image is
        # far smaller than that, so an address's low 16 bits are its offset
        # from the image base: map address = preferred base + those bits
        named = []
        for addr, mod in frames:
            a = int(addr, 16)
            if a == 0:
                named.append('NULL')
            elif mod.lower().endswith('\\' + name.lower()):
                off = pref + (a & 0xFFFF)
                own = [n for s, n in syms if s <= off]
                named.append(own[-1] if own else '?image')
            else:
                named.append(re.split(r'[\\/]', mod)[-1].split('.')[0].upper())
        if named != chain.split(','):
            bad.append('run %d chain %s, want %s' % (k + 1, ','.join(named), chain))
print('FAIL: ' + '; '.join(bad) if bad else 'PASS')
sys.exit(1 if bad else 0)
PYEOF
RC=$?
rm -f "$TF"
exit $RC
