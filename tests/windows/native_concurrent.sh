#!/bin/bash
# native_concurrent.sh -- the suite's concurrent Windows rows, natively (#143
# A14b, spec 8.6 (a) table: native_exec.sh runs one process at a time). The
# laptop side is inline PowerShell only (user ruling, phase 5). Each row's
# background process runs through Start-Process -PassThru (its own process),
# the foreground one through & while the other is alive.
#
#   native_concurrent.sh <compiler> <fixtures dir>
#
# Row sys_last_errno_windows_wine (run_tests.sh, "THE HELD FILE"): w32_hold.exe
# holds held.txt with share mode 0 while sys_lasterr.exe opens a missing file
# and the held one: it must print "missing 2" and "held 16" and exit 0, the
# holder must print "held" and exit 0.
# Row runner_windows_slots_are_claimed (run_tests.sh rws_row, "The Windows
# runner claims its slot"): the x86_64 PE runner (src/runner.kr + src/bcj.kr)
# runs slow.exe (exits 42 after 2 s). (1) While hold.exe holds
# .\kr-run-0.lock open for writing, kr.exe slow.exe must exit 42, write no
# kr-run-0.exe and write kr-run-1.exe, and the holder must exit 0; (2) with
# the kr-run-* files removed, two kr.exe slow.exe at once must both exit 42 and
# leave kr-run-0.exe and kr-run-1.exe.
# Row legacy_file_open_write_holds_the_file_wine (run_tests.sh, "A --legacy
# Windows file_open for writing holds the file"): both built --legacy; while
# hold.exe holds .\kr-share.lock open for writing, probe.exe (a second
# file_open(.\kr-share.lock, 1)) must exit 3; once the holder has exited (0),
# probe.exe must exit 0.
# The programs, build flags and assertions are the rows' own; a row whose
# build fails is reported FAIL (build ...) and the others still run.
# Prints "<row>: PASS|FAIL (detail)" per row and exits 0 when every row
# passed, 1 otherwise, 2 on a transport error.
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
kb() { ( ulimit -v 2000000; timeout 60 "$KRC" "$@" ) >> "$L/b.log" 2>&1; }   # one capped compiler run
bwhy() { echo "build: $(grep -m1 -i error "$L/b.log" || tail -1 "$L/b.log")"; }
FAILED=0; TERR=0
row() { echo "$1: $2"; [ "${2%% *}" = PASS ] || FAILED=1; }

# --- builds (each row's own programs and flags) ------------------------------
mkdir -p "$L/sle" "$L/rws" "$L/lsh"
SLE_OK=0; RWS_OK=0; LSH_OK=0
: > "$L/b.log"
if kb --arch=x86_64 --target=windows --emit=pe "$FX/w32_hold.kr" -o "$L/sle/w32_hold.exe" \
   && kb --arch=x86_64 --target=windows --emit=pe "$FX/sys_lasterr.kr" -o "$L/sle/sys_lasterr.exe"; then
    printf 'held' > "$L/sle/held.txt"; SLE_OK=1
else
    row sys_last_errno_windows_wine "FAIL ($(bwhy))"
fi
: > "$L/b.log"
TREE="$(cd "$(dirname "$0")/../.." && pwd)"
cat "$TREE/src/runner.kr" "$TREE/src/bcj.kr" > "$L/rws/runner.kr"
printf 'fn main() {\n    uint64 t0 = time_ns()\n    while time_ns() - t0 < 2000000000 { }\n    exit(42)\n}\n' > "$L/rws/slow.kr"
printf 'fn main() {\n    uint64 h = file_open(".\\\\kr-run-0.lock", 1)\n    if h >= 0xFFFFFFFFFFFFF000 { exit(9) }\n    uint64 t0 = time_ns()\n    while time_ns() - t0 < 6000000000 { }\n    exit(0)\n}\n' > "$L/rws/hold.kr"
if kb --arch=x86_64 --emit=windows "$L/rws/runner.kr" -o "$L/rws/kr.exe" \
   && kb --arch=x86_64 --emit=windows "$L/rws/slow.kr" -o "$L/rws/slow.exe" \
   && kb --arch=x86_64 --emit=windows "$L/rws/hold.kr" -o "$L/rws/hold.exe"; then
    RWS_OK=1
else
    row runner_windows_slots_are_claimed "FAIL ($(bwhy))"
fi
: > "$L/b.log"
printf 'fn main() {\n    uint64 h = file_open(".\\\\kr-share.lock", 1)\n    if h >= 0xFFFFFFFFFFFFF000 { exit(9) }\n    uint64 t0 = time_ns()\n    while time_ns() - t0 < 6000000000 { }\n    exit(0)\n}\n' > "$L/lsh/hold.kr"
printf 'fn main() {\n    uint64 h = file_open(".\\\\kr-share.lock", 1)\n    if h >= 0xFFFFFFFFFFFFF000 { exit(3) }\n    exit(0)\n}\n' > "$L/lsh/probe.kr"
if kb --arch=x86_64 --emit=windows --legacy "$L/lsh/hold.kr" -o "$L/lsh/hold.exe" \
   && kb --arch=x86_64 --emit=windows --legacy "$L/lsh/probe.kr" -o "$L/lsh/probe.exe"; then
    LSH_OK=1
else
    row legacy_file_open_write_holds_the_file_wine "FAIL ($(bwhy))"
fi
if [ $((SLE_OK + RWS_OK + LSH_OK)) = 0 ]; then rm -rf "$L"; exit 1; fi

# --- upload ------------------------------------------------------------------
rps "New-Item -ItemType Directory -Force '$RD\\sle','$RD\\rws','$RD\\lsh' | Out-Null; exit 0" > /dev/null || { rm -rf "$L"; echo "native_concurrent.sh: remote mkdir failed" >&2; exit 2; }
if [ "$SLE_OK" = 1 ]; then scp -q -o BatchMode=yes "$L/sle/w32_hold.exe" "$L/sle/sys_lasterr.exe" "$L/sle/held.txt" "$NATIVE_HOST:$RDF/sle/" < /dev/null || { cleanup; exit 2; }; fi
if [ "$RWS_OK" = 1 ]; then scp -q -o BatchMode=yes "$L/rws/kr.exe" "$L/rws/slow.exe" "$L/rws/hold.exe" "$NATIVE_HOST:$RDF/rws/" < /dev/null || { cleanup; exit 2; }; fi
if [ "$LSH_OK" = 1 ]; then scp -q -o BatchMode=yes "$L/lsh/hold.exe" "$L/lsh/probe.exe" "$NATIVE_HOST:$RDF/lsh/" < /dev/null || { cleanup; exit 2; }; fi

# --- sys_last_errno_windows_wine ---------------------------------------------
# the holder through Start-Process (its own process, stdout to a file), then
# the second program while it holds the file; both exit codes and outputs
if [ "$SLE_OK" = 1 ]; then
    D="$RD\\sle"
    OUT=$(rps "Set-Location '$D'; \$h=Start-Process -FilePath '$D\\w32_hold.exe' -ArgumentList 'held.txt','0','8' -WorkingDirectory '$D' -RedirectStandardOutput '$D\\hold.out' -NoNewWindow -PassThru; \$null=\$h.Handle; for (\$i=0; \$i -lt 300; \$i++) { if ((Test-Path '$D\\hold.out') -and ((Get-Content -Raw '$D\\hold.out') -match 'held')) { break }; Start-Sleep -Milliseconds 100 }; \$o=& '$D\\sys_lasterr.exe' no-such-file.txt held.txt; \$rc=\$LASTEXITCODE; \$h.WaitForExit(); 'LASTERR_RC=' + \$rc; 'HOLD_RC=' + \$h.ExitCode; 'HOLD_OUT=' + ((Get-Content -Raw '$D\\hold.out').Trim()); \$o | ForEach-Object { 'OUT=' + \$_ }; exit 0" | tr -d '\r')
    if [ $? != 0 ]; then TERR=1; echo "native_concurrent.sh: remote run of sys_last_errno_windows_wine failed" >&2
    else
        GOT=$(grep '^OUT=' <<< "$OUT" | cut -c5- | paste -sd'|')
        if grep -qx 'LASTERR_RC=0' <<< "$OUT" && grep -qx 'HOLD_RC=0' <<< "$OUT" && grep -qx 'HOLD_OUT=held' <<< "$OUT" && [ "$GOT" = 'missing 2|held 16' ]; then
            row sys_last_errno_windows_wine "PASS (natively: missing 2, held (share mode 0) 16; holder rc 0)"
        else
            row sys_last_errno_windows_wine "FAIL ($(tr '\n' ' ' <<< "$OUT"))"
        fi
    fi
fi

# --- runner_windows_slots_are_claimed ----------------------------------------
# (1) hold.exe through Start-Process holds kr-run-0.lock (waited for as the
# row does: up to 10 s for the file, then 0.5 s), kr.exe slow.exe meanwhile;
# (2) the kr-run-* files removed (retried for up to 10 s; a leftover is
# reported), one kr.exe slow.exe through Start-Process, 1 s later a second
# through &
if [ "$RWS_OK" = 1 ]; then
    D="$RD\\rws"
    OUT=$(rps "Set-Location '$D'; \$h=Start-Process -FilePath '$D\\hold.exe' -WorkingDirectory '$D' -NoNewWindow -PassThru; \$null=\$h.Handle; for (\$i=0; \$i -lt 100 -and -not (Test-Path '$D\\kr-run-0.lock'); \$i++) { Start-Sleep -Milliseconds 100 }; Start-Sleep -Milliseconds 500; \$o=& '$D\\kr.exe' slow.exe; \$r1=\$LASTEXITCODE; if (-not \$h.WaitForExit(60000)) { \$h.Kill(); \$h.WaitForExit() }; 'R1_RC=' + \$r1; 'HOLD_RC=' + \$h.ExitCode; 'R1_SLOT0=' + (Test-Path '$D\\kr-run-0.exe'); 'R1_SLOT1=' + (Test-Path '$D\\kr-run-1.exe'); 'R1_OUT=' + (\$o -join ' '); for (\$i=0; \$i -lt 20 -and (Test-Path '$D\\kr-run-*'); \$i++) { Remove-Item -Path '$D\\kr-run-*' -Force -ErrorAction SilentlyContinue; if (Test-Path '$D\\kr-run-*') { Start-Sleep -Milliseconds 500 } }; 'LEFT=' + ((Get-ChildItem -Name -Path '$D\\kr-run-*') -join ' '); \$a=Start-Process -FilePath '$D\\kr.exe' -ArgumentList 'slow.exe' -WorkingDirectory '$D' -NoNewWindow -PassThru; \$null=\$a.Handle; Start-Sleep -Seconds 1; \$o=& '$D\\kr.exe' slow.exe; \$rb=\$LASTEXITCODE; if (-not \$a.WaitForExit(60000)) { \$a.Kill(); \$a.WaitForExit() }; 'A_RC=' + \$a.ExitCode; 'B_RC=' + \$rb; 'SLOT0=' + (Test-Path '$D\\kr-run-0.exe'); 'SLOT1=' + (Test-Path '$D\\kr-run-1.exe'); 'FILES=' + ((Get-ChildItem -Name -Path '$D\\kr-run-*') -join ' '); exit 0" | tr -d '\r')
    if [ $? != 0 ]; then TERR=1; echo "native_concurrent.sh: remote run of runner_windows_slots_are_claimed failed" >&2
    else
        v() { grep -m1 "^$1=" <<< "$OUT" | cut -d= -f2-; }
        WHY=""
        [ "$(v R1_RC)" = 42 ] || WHY="$WHY [slot 0 held: exit $(v R1_RC), want 42; $(v R1_OUT | cut -c1-80)]"
        [ "$(v HOLD_RC)" = 0 ] || WHY="$WHY [the lock holder could not take slot 0's lock: exit $(v HOLD_RC)]"
        [ "$(v R1_SLOT0)" = False ] || WHY="$WHY [kr-run-0.exe was written while slot 0's lock was held]"
        [ "$(v R1_SLOT1)" = True ] || WHY="$WHY [no kr-run-1.exe: slot 1 was not used]"
        [ -z "$(v LEFT)" ] || WHY="$WHY [kr-run-* not removable before the two-at-once run: $(v LEFT)]"
        [ "$(v A_RC)" = 42 ] && [ "$(v B_RC)" = 42 ] || WHY="$WHY [two at once: exits $(v A_RC) and $(v B_RC), want 42 42]"
        [ "$(v SLOT0)" = True ] && [ "$(v SLOT1)" = True ] || WHY="$WHY [two at once did not use two slots: $(v FILES)]"
        grep -q '^SLOT1=' <<< "$OUT" || WHY="$WHY [incomplete remote output: $(tr '\n' ' ' <<< "$OUT")]"
        if [ -z "$WHY" ]; then
            row runner_windows_slots_are_claimed "PASS (natively: a held slot is passed over (kr-run-1.exe, no kr-run-0.exe), two runs at once use two slots, all exit 42; holder rc 0)"
        else
            row runner_windows_slots_are_claimed "FAIL ($(sed 's/^ //' <<< "$WHY"))"
        fi
    fi
fi

# --- legacy_file_open_write_holds_the_file_wine ------------------------------
# hold.exe through Start-Process holds kr-share.lock (waited for as the row
# does), probe.exe meanwhile, then probe.exe again once the holder has exited
if [ "$LSH_OK" = 1 ]; then
    D="$RD\\lsh"
    OUT=$(rps "Set-Location '$D'; \$h=Start-Process -FilePath '$D\\hold.exe' -WorkingDirectory '$D' -NoNewWindow -PassThru; \$null=\$h.Handle; for (\$i=0; \$i -lt 100 -and -not (Test-Path '$D\\kr-share.lock'); \$i++) { Start-Sleep -Milliseconds 100 }; Start-Sleep -Milliseconds 500; \$null=& '$D\\probe.exe'; \$held=\$LASTEXITCODE; if (-not \$h.WaitForExit(60000)) { \$h.Kill(); \$h.WaitForExit() }; \$null=& '$D\\probe.exe'; \$free=\$LASTEXITCODE; 'HOLD_RC=' + \$h.ExitCode; 'HELD_RC=' + \$held; 'FREE_RC=' + \$free; exit 0" | tr -d '\r')
    if [ $? != 0 ]; then TERR=1; echo "native_concurrent.sh: remote run of legacy_file_open_write_holds_the_file_wine failed" >&2
    else
        v() { grep -m1 "^$1=" <<< "$OUT" | cut -d= -f2-; }
        WHY=""
        [ "$(v HOLD_RC)" = 0 ] || WHY="$WHY [the holder could not open the file: exit $(v HOLD_RC)]"
        [ "$(v HELD_RC)" = 3 ] || WHY="$WHY [while held: exit $(v HELD_RC), want 3 (a second writer must be refused)]"
        [ "$(v FREE_RC)" = 0 ] || WHY="$WHY [after the holder exited: exit $(v FREE_RC), want 0]"
        if [ -z "$WHY" ]; then
            row legacy_file_open_write_holds_the_file_wine "PASS (natively: a second --legacy writer is refused (3) while the file is held, and opens it (0) once it is free; holder rc 0)"
        else
            row legacy_file_open_write_holds_the_file_wine "FAIL ($(sed 's/^ //' <<< "$WHY"))"
        fi
    fi
fi

cleanup
[ "$TERR" = 0 ] || exit 2
exit "$FAILED"
