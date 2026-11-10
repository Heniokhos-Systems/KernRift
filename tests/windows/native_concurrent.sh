#!/bin/bash
# native_concurrent.sh -- the suite's concurrent Windows rows, natively (#143
# A14b, spec 8.6 (a) table: native_exec.sh runs one process at a time). The
# laptop side is inline PowerShell only (user ruling, phase 5). Every program
# runs through [Diagnostics.Process]::Start (its own process, stdout and
# stderr read into memory); the background one is started first and the
# foreground one while it is alive. Every wait is bounded like the Wine rows'
# `timeout 60`: a program still running after 60 s is killed and reported
# TIMEOUT, one that Process.Start cannot launch LAUNCHFAIL (with its reason),
# and either is a FAIL naming it.
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
# The programs, build flags and assertions are the rows' own. A holder that
# has already exited when the foreground program returns (or a first runner
# that has exited when the second starts) makes the check inconclusive, which
# is a FAIL saying so, never a PASS. A row whose build fails is reported FAIL
# (build: <file>: rc=N; <first error: line>) and the others still run.
# Prints "<row>: PASS|FAIL (detail)" per row and exits 0 when every row
# passed, 1 otherwise, 2 on a transport error (ssh 255, or an ssh that timed
# out or was killed; a PowerShell failure on the laptop is a FAIL of its row). The laptop's
# scratch directory is removed at the end, on a transport error and on
# INT/TERM/HUP.
# Time bounds, each by `timeout -k 10` (TERM at the bound, KILL 10 s later):
# 7 compiles x (60+10) s = 490 s; the remote mkdir 300+10 s; 3 scp x (300+10)
# s = 930 s; 3 row runs x (600+10) s = 1830 s; the cleanup 300+10 s: 3870 s at
# most in all. native_suite.sh runs this under `timeout -k 60 4000` (3870 s +
# 130 s slack, then KILL 60 s after TERM).
set -u -o pipefail
NATIVE_HOST="${NATIVE_HOST:-laptop}"
KRC="${1:?usage: native_concurrent.sh <compiler> <fixtures dir>}"; FX="${2:?fixtures dir}"
L=$(mktemp -d "${TMPDIR:-$HOME/.cache/pe_unwind}/ncc.XXXXXX")
RD="C:\\Users\\pante\\pe_unwind_scratch\\ncc$$"; RDF="C:/Users/pante/pe_unwind_scratch/ncc$$"
rps() { timeout -k 10 "${2:-300}" ssh -o BatchMode=yes "$NATIVE_HOST" "powershell -NoProfile -NonInteractive -Command \"\$ProgressPreference='SilentlyContinue'; $1\"" < /dev/null; }
REMOTE=0; CLEANED=0
cleanup() {
    [ "$CLEANED" = 1 ] && return 0
    CLEANED=1; rm -rf "$L"
    [ "$REMOTE" = 1 ] || return 0
    rps "for (\$i=0; \$i -lt 120 -and (Test-Path -LiteralPath '$RD'); \$i++) { Remove-Item -LiteralPath '$RD' -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath '$RD') { Start-Sleep -Milliseconds 500 } }; if ((Test-Path 'C:\\Users\\pante\\pe_unwind_scratch') -and -not (Get-ChildItem -Force 'C:\\Users\\pante\\pe_unwind_scratch')) { Remove-Item -Force 'C:\\Users\\pante\\pe_unwind_scratch' }; if (Test-Path -LiteralPath '$RD') { exit 1 }; exit 0" \
        || { echo "native_concurrent.sh: remote $RD not removed" >&2; exit 2; }
}
trap 'cleanup; exit 2' INT TERM HUP
# one capped compiler run; on failure KB_WHY names the source, the exit code
# and the first "error:" line of THIS run's output
kb() {
    local o rc src
    src=$(printf '%s\n' "$@" | grep -m1 '\.kr$')
    o=$( ( ulimit -v 2000000; timeout -k 10 60 "$KRC" "$@" ) 2>&1 ); rc=$?
    [ "$rc" = 0 ] && return 0
    KB_WHY="${src##*/}: rc=$rc$(case "$rc" in 124) echo ' (timed out after 60 s)' ;; 137) echo ' (killed: KILL 10 s after the 60 s timeout, or from outside)' ;; esac)$(grep -m1 'error:' <<< "$o" | sed 's|^[^ ]*/||; s/^/; /')"
    return 1
}
FAILED=0; TERR=0
row() { echo "$1: $2"; [ "${2%% *}" = PASS ] || FAILED=1; }

# The PowerShell helpers every row's command starts with ($D: the row's
# remote directory). Process.Start (UseShellExecute off) keeps the
# CreateProcess handle, so a program that exits at once still has its exit
# code; only Process.Start's own exception is LAUNCHFAIL. Both pipes are read
# asynchronously from the moment it starts (no pipe can fill and stall it).
#   NcStart <tag> <exe> [<args> [<first line>]]: the process, or $null (the
#     reason in $NcWhy[<tag>]). With <first line> $true it first waits (up to
#     30 s) for the program's first stdout line -- w32_hold.exe prints "held"
#     once it holds the file, so this is its readiness, without polling a
#     file -- and only then reads the rest.
#   NcWait <key> <process> <tag>: waits up to 60 s; prints <key>=<exit code>,
#     or <key>=TIMEOUT (then killed), or <key>=LAUNCHFAIL and <key>_WHY=.
#   NcAlive <process>: True while it runs.
#   NcText <tag> out|err: what it wrote there (waited for up to 10 s).
#   NcOut <tag> [<streams>]: the same, whitespace folded to one space.
# Written one statement per line, joined into one line; no " and no % (the
# command travels inside cmd's double quotes).
read -r -d '' PSF <<'PS'
$NcO=@{}; $NcE=@{}; $NcF=@{}; $NcWhy=@{};
function NcStart($t,$e,$a,$line) { $si=New-Object Diagnostics.ProcessStartInfo; $si.FileName=$D+'\'+$e; $si.WorkingDirectory=$D; $si.UseShellExecute=$false; $si.RedirectStandardOutput=$true; $si.RedirectStandardError=$true; $si.CreateNoWindow=$true; if ($a) { $si.Arguments=($a -join ' ') }; try { $p=[Diagnostics.Process]::Start($si) } catch { $NcWhy[$t]=($_.Exception.Message -replace '\s+',' '); return $null }; $NcE[$t]=$p.StandardError.ReadToEndAsync(); if ($line) { $r=$p.StandardOutput.ReadLineAsync(); if ($r.Wait(30000)) { $NcF[$t]=[string]$r.Result; $NcO[$t]=$p.StandardOutput.ReadToEndAsync() } else { $NcF[$t]='(no first line within 30 s)' } } else { $NcO[$t]=$p.StandardOutput.ReadToEndAsync() }; $p };
function NcWait($k,$p,$t) { if ($null -eq $p) { $k+'=LAUNCHFAIL'; $k+'_WHY='+$NcWhy[$t] } elseif (-not $p.WaitForExit(60000)) { try { $p.Kill() } catch { }; $null=$p.WaitForExit(10000); $k+'=TIMEOUT' } else { $p.WaitForExit(); $k+'='+$p.ExitCode } };
function NcAlive($p) { (($null -ne $p) -and (-not $p.HasExited)) };
function NcText($t,$x) { $s=''; if ($x -eq 'out') { if ($NcF.ContainsKey($t)) { $s=$NcF[$t]+[char]10 }; $k=$NcO[$t] } else { $k=$NcE[$t] }; try { if ($k -and $k.Wait(10000)) { $s+=[string]$k.Result } } catch { }; $s };
function NcOut($t,$xs) { if (-not $xs) { $xs='out','err' }; $s=''; foreach ($x in $xs) { $s+=(NcText $t $x)+' ' }; ($s -replace '\s+',' ').Trim() };
PS
# psrow <remote dir> <body>: the line rps sends for a row
psrow() {
    local s="\$D='$1'; $PSF $2 'END=1'; exit 0"
    s=${s//$'\n'/ }
    case "$s" in *'"'*|*%*) echo "native_concurrent.sh: a remote command holds \" or %" >&2; exit 2 ;; esac
    printf '%s' "$s"
}
# rcw <key> <want> <label> [<detail>]: a FAIL detail unless <key> is <want>
rcw() {
    local g; g=$(v "$1")
    case "$g" in
        "$2") ;;
        TIMEOUT) WHY="$WHY [$3: still running after 60 s, killed${4:+; $4}]" ;;
        LAUNCHFAIL) WHY="$WHY [$3: could not be launched: $(v "$1_WHY" | cut -c1-120)]" ;;
        '') WHY="$WHY [$3: no result]" ;;
        *) WHY="$WHY [$3: exit $g, want $2${4:+; $4}]" ;;
    esac
}
v() { grep -m1 "^$1=" <<< "$OUT" | cut -d= -f2-; }
# runrow <row> <command>: runs it (600 s); 0 with OUT set, else 1 after
# reporting: ssh's 255, 124 (timed out: TERM after 600 s) and 137 (KILLed:
# by timeout -k 10 s after that TERM, or from outside) are a transport error,
# any other status (PowerShell's 1 on a parse or runtime error) a FAIL of the
# row
runrow() {
    local rc
    rps "$2" 600 > "$L/r.out" 2> "$L/r.err"; rc=$?
    OUT=$(tr -d '\r' < "$L/r.out")
    case "$rc" in
        0) return 0 ;;
        124|137|255) TERR=1
            echo "native_concurrent.sh: remote run of $1: transport failure (rc=$rc$(case "$rc" in 124) echo ': ssh timed out after 600 s' ;; 137) echo ': ssh killed, 10 s after the 600 s timeout or from outside' ;; esac)): $(tr -d '\r' < "$L/r.err" | tr '\n' ' ' | cut -c1-200)" >&2 ;;
        *) row "$1" "FAIL (remote PowerShell failed (rc=$rc): $(tr -d '\r' < "$L/r.err" | tr '\n' ' ' | cut -c1-200))" ;;
    esac
    return 1
}
done_or_incomplete() { grep -qx 'END=1' <<< "$OUT" || WHY="$WHY [incomplete remote output: $(tr '\n' ' ' <<< "$OUT" | cut -c1-200)]"; }

# --- builds (each row's own programs and flags) ------------------------------
mkdir -p "$L/sle" "$L/rws" "$L/lsh"
SLE_OK=0; RWS_OK=0; LSH_OK=0
if kb --arch=x86_64 --target=windows --emit=pe "$FX/w32_hold.kr" -o "$L/sle/w32_hold.exe" \
   && kb --arch=x86_64 --target=windows --emit=pe "$FX/sys_lasterr.kr" -o "$L/sle/sys_lasterr.exe"; then
    printf 'held' > "$L/sle/held.txt"; SLE_OK=1
else
    row sys_last_errno_windows_wine "FAIL (build: $KB_WHY)"
fi
TREE="$(cd "$(dirname "$0")/../.." && pwd)"
cat "$TREE/src/runner.kr" "$TREE/src/bcj.kr" > "$L/rws/runner.kr"
printf 'fn main() {\n    uint64 t0 = time_ns()\n    while time_ns() - t0 < 2000000000 { }\n    exit(42)\n}\n' > "$L/rws/slow.kr"
printf 'fn main() {\n    uint64 h = file_open(".\\\\kr-run-0.lock", 1)\n    if h >= 0xFFFFFFFFFFFFF000 { exit(9) }\n    uint64 t0 = time_ns()\n    while time_ns() - t0 < 6000000000 { }\n    exit(0)\n}\n' > "$L/rws/hold.kr"
if kb --arch=x86_64 --emit=windows "$L/rws/runner.kr" -o "$L/rws/kr.exe" \
   && kb --arch=x86_64 --emit=windows "$L/rws/slow.kr" -o "$L/rws/slow.exe" \
   && kb --arch=x86_64 --emit=windows "$L/rws/hold.kr" -o "$L/rws/hold.exe"; then
    RWS_OK=1
else
    row runner_windows_slots_are_claimed "FAIL (build: $KB_WHY)"
fi
printf 'fn main() {\n    uint64 h = file_open(".\\\\kr-share.lock", 1)\n    if h >= 0xFFFFFFFFFFFFF000 { exit(9) }\n    uint64 t0 = time_ns()\n    while time_ns() - t0 < 6000000000 { }\n    exit(0)\n}\n' > "$L/lsh/hold.kr"
printf 'fn main() {\n    uint64 h = file_open(".\\\\kr-share.lock", 1)\n    if h >= 0xFFFFFFFFFFFFF000 { exit(3) }\n    exit(0)\n}\n' > "$L/lsh/probe.kr"
if kb --arch=x86_64 --emit=windows --legacy "$L/lsh/hold.kr" -o "$L/lsh/hold.exe" \
   && kb --arch=x86_64 --emit=windows --legacy "$L/lsh/probe.kr" -o "$L/lsh/probe.exe"; then
    LSH_OK=1
else
    row legacy_file_open_write_holds_the_file_wine "FAIL (build: $KB_WHY)"
fi
if [ $((SLE_OK + RWS_OK + LSH_OK)) = 0 ]; then cleanup; exit 1; fi

# --- upload ------------------------------------------------------------------
REMOTE=1
rps "New-Item -ItemType Directory -Force '$RD\\sle','$RD\\rws','$RD\\lsh' | Out-Null; exit 0" > /dev/null; MRC=$?
[ "$MRC" = 0 ] || { echo "native_concurrent.sh: remote mkdir failed (rc=$MRC)" >&2; cleanup; exit 2; }
up() { timeout -k 10 300 scp -q -o BatchMode=yes "$@" < /dev/null; local rc=$?; [ "$rc" = 0 ] || { echo "native_concurrent.sh: scp failed (rc=$rc)" >&2; cleanup; exit 2; }; }
if [ "$SLE_OK" = 1 ]; then up "$L/sle/w32_hold.exe" "$L/sle/sys_lasterr.exe" "$L/sle/held.txt" "$NATIVE_HOST:$RDF/sle/"; fi
if [ "$RWS_OK" = 1 ]; then up "$L/rws/kr.exe" "$L/rws/slow.exe" "$L/rws/hold.exe" "$NATIVE_HOST:$RDF/rws/"; fi
if [ "$LSH_OK" = 1 ]; then up "$L/lsh/hold.exe" "$L/lsh/probe.exe" "$NATIVE_HOST:$RDF/lsh/"; fi

# --- sys_last_errno_windows_wine ---------------------------------------------
# the holder (ready once its first stdout line has arrived, up to 30 s: it
# prints "held" after CreateFileA succeeded), then sys_lasterr.exe while it
# holds the file
if [ "$SLE_OK" = 1 ]; then
    C=$(psrow "$RD\\sle" "Set-Location \$D;
\$h=NcStart 'hold' 'w32_hold.exe' @('held.txt','0','8') \$true;
\$p=NcStart 'le' 'sys_lasterr.exe' @('no-such-file.txt','held.txt');
NcWait 'LASTERR_RC' \$p 'le';
'ALIVE='+(NcAlive \$h);
NcWait 'HOLD_RC' \$h 'hold';
'HOLD_OUT='+(NcOut 'hold' @('out'));
'LE_ERR='+(NcOut 'le' @('err'));
\$x=(NcText 'le' 'out').TrimEnd(); if (\$x) { \$x -split '\r?\n' | ForEach-Object { 'OUT='+\$_ } };") || { cleanup; exit 2; }
    if runrow sys_last_errno_windows_wine "$C"; then
        WHY=""
        GOT=$(grep '^OUT=' <<< "$OUT" | cut -c5- | paste -sd'|')
        rcw LASTERR_RC 0 sys_lasterr.exe "$(v LE_ERR | cut -c1-80)"
        rcw HOLD_RC 0 "the holder"
        [ "$(v HOLD_OUT)" = held ] || WHY="$WHY [the holder printed '$(v HOLD_OUT)', want 'held']"
        [ "$(v ALIVE)" = True ] || WHY="$WHY [the holder exited before sys_lasterr.exe finished: inconclusive]"
        [ "$GOT" = 'missing 2|held 16' ] || WHY="$WHY [sys_lasterr.exe printed '$GOT', want 'missing 2|held 16']"
        done_or_incomplete
        if [ -z "$WHY" ]; then
            row sys_last_errno_windows_wine "PASS (natively: missing 2, held (share mode 0) 16; holder rc 0)"
        else
            row sys_last_errno_windows_wine "FAIL (${WHY# })"
        fi
    fi
fi

# --- runner_windows_slots_are_claimed ----------------------------------------
# (1) hold.exe holds kr-run-0.lock (waited for as the row does: up to 10 s for
# the file, then 0.5 s), kr.exe slow.exe meanwhile; (2) the kr-run-* files
# removed (retried for up to 10 s; a leftover is reported), one kr.exe
# slow.exe, 1 s later a second while the first still runs
if [ "$RWS_OK" = 1 ]; then
    C=$(psrow "$RD\\rws" "Set-Location \$D;
\$h=NcStart 'hold' 'hold.exe';
if (\$h) { for (\$i=0; \$i -lt 100 -and -not (Test-Path (\$D+'\\kr-run-0.lock')); \$i++) { Start-Sleep -Milliseconds 100 } };
Start-Sleep -Milliseconds 500;
\$p=NcStart 'r1' 'kr.exe' @('slow.exe');
NcWait 'R1_RC' \$p 'r1';
'ALIVE='+(NcAlive \$h);
NcWait 'HOLD_RC' \$h 'hold';
'R1_SLOT0='+(Test-Path (\$D+'\\kr-run-0.exe'));
'R1_SLOT1='+(Test-Path (\$D+'\\kr-run-1.exe'));
'R1_OUT='+(NcOut 'r1');
for (\$i=0; \$i -lt 20 -and (Test-Path (\$D+'\\kr-run-*')); \$i++) { Remove-Item -Path (\$D+'\\kr-run-*') -Force -ErrorAction SilentlyContinue; if (Test-Path (\$D+'\\kr-run-*')) { Start-Sleep -Milliseconds 500 } };
'LEFT='+((Get-ChildItem -Name -Path (\$D+'\\kr-run-*')) -join ' ');
\$a=NcStart 'a' 'kr.exe' @('slow.exe');
Start-Sleep -Seconds 1;
\$b=NcStart 'b' 'kr.exe' @('slow.exe');
'A_ALIVE='+(NcAlive \$a);
NcWait 'B_RC' \$b 'b';
NcWait 'A_RC' \$a 'a';
'SLOT0='+(Test-Path (\$D+'\\kr-run-0.exe'));
'SLOT1='+(Test-Path (\$D+'\\kr-run-1.exe'));
'FILES='+((Get-ChildItem -Name -Path (\$D+'\\kr-run-*')) -join ' ');") || { cleanup; exit 2; }
    if runrow runner_windows_slots_are_claimed "$C"; then
        WHY=""
        rcw R1_RC 42 "slot 0 held" "$(v R1_OUT | cut -c1-80)"
        rcw HOLD_RC 0 "the lock holder" "it could not take slot 0's lock"
        [ "$(v ALIVE)" = True ] || WHY="$WHY [the lock holder exited before kr.exe finished: inconclusive]"
        [ "$(v R1_SLOT0)" = False ] || WHY="$WHY [kr-run-0.exe was written while slot 0's lock was held]"
        [ "$(v R1_SLOT1)" = True ] || WHY="$WHY [no kr-run-1.exe: slot 1 was not used]"
        [ -z "$(v LEFT)" ] || WHY="$WHY [kr-run-* not removable before the two-at-once run: $(v LEFT)]"
        [ "$(v A_ALIVE)" = True ] || WHY="$WHY [the first kr.exe exited before the second started: not two at once, inconclusive]"
        rcw A_RC 42 "two at once, first"
        rcw B_RC 42 "two at once, second"
        [ "$(v SLOT0)" = True ] && [ "$(v SLOT1)" = True ] || WHY="$WHY [two at once did not use two slots: $(v FILES)]"
        done_or_incomplete
        if [ -z "$WHY" ]; then
            row runner_windows_slots_are_claimed "PASS (natively: a held slot is passed over (kr-run-1.exe, no kr-run-0.exe), two runs at once use two slots, all exit 42; holder rc 0)"
        else
            row runner_windows_slots_are_claimed "FAIL (${WHY# })"
        fi
    fi
fi

# --- legacy_file_open_write_holds_the_file_wine ------------------------------
# hold.exe holds kr-share.lock (waited for as the row does), probe.exe
# meanwhile, then probe.exe again once the holder has exited
if [ "$LSH_OK" = 1 ]; then
    C=$(psrow "$RD\\lsh" "Set-Location \$D;
\$h=NcStart 'hold' 'hold.exe';
if (\$h) { for (\$i=0; \$i -lt 100 -and -not (Test-Path (\$D+'\\kr-share.lock')); \$i++) { Start-Sleep -Milliseconds 100 } };
Start-Sleep -Milliseconds 500;
\$p=NcStart 'held' 'probe.exe';
NcWait 'HELD_RC' \$p 'held';
'ALIVE='+(NcAlive \$h);
NcWait 'HOLD_RC' \$h 'hold';
\$p=NcStart 'free' 'probe.exe';
NcWait 'FREE_RC' \$p 'free';") || { cleanup; exit 2; }
    if runrow legacy_file_open_write_holds_the_file_wine "$C"; then
        WHY=""
        rcw HOLD_RC 0 "the holder" "it could not open the file"
        [ "$(v ALIVE)" = True ] || WHY="$WHY [the holder exited before the probe finished: inconclusive]"
        rcw HELD_RC 3 "while held" "a second writer must be refused"
        rcw FREE_RC 0 "after the holder exited"
        done_or_incomplete
        if [ -z "$WHY" ]; then
            row legacy_file_open_write_holds_the_file_wine "PASS (natively: a second --legacy writer is refused (3) while the file is held, and opens it (0) once it is free; holder rc 0)"
        else
            row legacy_file_open_write_holds_the_file_wine "FAIL (${WHY# })"
        fi
    fi
fi

cleanup
[ "$TERR" = 0 ] || exit 2
exit "$FAILED"
