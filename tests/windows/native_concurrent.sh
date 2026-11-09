#!/bin/bash
# native_concurrent.sh -- the suite's concurrent Windows rows, natively (#143
# A14b, spec 8.6 (a) table: native_exec.sh runs one process at a time). The
# laptop side is inline PowerShell only (user ruling, phase 5).
#
#   native_concurrent.sh <compiler> <fixtures dir>
#
# Row sys_last_errno_windows_wine (run_tests.sh, "THE HELD FILE"): w32_hold.exe
# holds held.txt with share mode 0 while sys_lasterr.exe opens a missing file
# and the held one: it must print "missing 2" and "held 16" and exit 0, the
# holder must print "held" and exit 0. Prints "<row>: PASS|FAIL (detail)" and
# exits 0 when every row passed, 1 otherwise, 2 on a transport error.
set -u -o pipefail
NATIVE_HOST="${NATIVE_HOST:-laptop}"
KRC="${1:?usage: native_concurrent.sh <compiler> <fixtures dir>}"; FX="${2:?fixtures dir}"
L=$(mktemp -d "${TMPDIR:-$HOME/.cache/pe_unwind}/ncc.XXXXXX")
RD="C:\\Users\\pante\\pe_unwind_scratch\\ncc$$"; RDF="C:/Users/pante/pe_unwind_scratch/ncc$$"
rps() { ssh -o BatchMode=yes "$NATIVE_HOST" "powershell -NoProfile -NonInteractive -Command \"\$ProgressPreference='SilentlyContinue'; $1\"" < /dev/null; }
cleanup() {
    rm -rf "$L"
    rps "for (\$i=0; \$i -lt 120 -and (Test-Path -LiteralPath '$RD'); \$i++) { Remove-Item -LiteralPath '$RD' -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath '$RD') { Start-Sleep -Milliseconds 500 } }; if ((Test-Path 'C:\\Users\\pante\\pe_unwind_scratch') -and -not (Get-ChildItem -Force 'C:\\Users\\pante\\pe_unwind_scratch')) { Remove-Item -Force 'C:\\Users\\pante\\pe_unwind_scratch' }; if (Test-Path -LiteralPath '$RD') { exit 1 }; exit 0" \
        || { echo "native_concurrent.sh: remote $RD not removed" >&2; exit 2; }
}
if ! ( ulimit -v 2000000; timeout 60 "$KRC" --arch=x86_64 --target=windows --emit=pe "$FX/w32_hold.kr" -o "$L/w32_hold.exe" ) > "$L/b.log" 2>&1 \
   || ! ( ulimit -v 2000000; timeout 60 "$KRC" --arch=x86_64 --target=windows --emit=pe "$FX/sys_lasterr.kr" -o "$L/sys_lasterr.exe" ) >> "$L/b.log" 2>&1; then
    echo "sys_last_errno_windows_wine: FAIL (build: $(grep -m1 error "$L/b.log"))"; rm -rf "$L"; exit 1
fi
printf 'held' > "$L/held.txt"
rps "New-Item -ItemType Directory -Force '$RD' | Out-Null; exit 0" > /dev/null || { rm -rf "$L"; echo "native_concurrent.sh: remote mkdir failed" >&2; exit 2; }
scp -q -o BatchMode=yes "$L/w32_hold.exe" "$L/sys_lasterr.exe" "$L/held.txt" "$NATIVE_HOST:$RDF/" < /dev/null || { cleanup; exit 2; }
# the holder through Start-Process (its own process, stdout to a file), then
# the second program while it holds the file; both exit codes and outputs
OUT=$(rps "Set-Location '$RD'; \$h=Start-Process -FilePath '$RD\\w32_hold.exe' -ArgumentList 'held.txt','0','8' -WorkingDirectory '$RD' -RedirectStandardOutput '$RD\\hold.out' -NoNewWindow -PassThru; \$null=\$h.Handle; for (\$i=0; \$i -lt 300; \$i++) { if ((Test-Path '$RD\\hold.out') -and ((Get-Content -Raw '$RD\\hold.out') -match 'held')) { break }; Start-Sleep -Milliseconds 100 }; \$o=& '$RD\\sys_lasterr.exe' no-such-file.txt held.txt; \$rc=\$LASTEXITCODE; \$h.WaitForExit(); 'LASTERR_RC=' + \$rc; 'HOLD_RC=' + \$h.ExitCode; 'HOLD_OUT=' + ((Get-Content -Raw '$RD\\hold.out').Trim()); \$o | ForEach-Object { 'OUT=' + \$_ }; exit 0" | tr -d '\r')
TRC=$?
cleanup
[ "$TRC" = 0 ] || { echo "native_concurrent.sh: remote run failed ($TRC)" >&2; exit 2; }
GOT=$(grep '^OUT=' <<< "$OUT" | cut -c5- | paste -sd'|')
if grep -qx 'LASTERR_RC=0' <<< "$OUT" && grep -qx 'HOLD_RC=0' <<< "$OUT" && grep -qx 'HOLD_OUT=held' <<< "$OUT" && [ "$GOT" = 'missing 2|held 16' ]; then
    echo "sys_last_errno_windows_wine: PASS (natively: missing 2, held (share mode 0) 16; holder rc 0)"; exit 0
fi
echo "sys_last_errno_windows_wine: FAIL ($(tr '\n' ' ' <<< "$OUT"))"; exit 1
