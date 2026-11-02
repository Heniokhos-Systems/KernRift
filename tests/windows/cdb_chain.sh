#!/bin/bash
# cdb_chain.sh -- the asserting native call-chain check (#143 A14b, spec 8.6
# step 2 / plan Task D step 3; byte-identical in the KernRift and MLRift
# trees). The laptop side is inline PowerShell only (user ruling, phase 5):
# the exe is copied, cdb is started by an inline `-Command`, and the transcript
# comes back on stdout; no script file reaches the laptop.
#
#   cdb_chain.sh <image.exe> <listing> <want> [--bp "SYMBOL [PASSES]"]
#
# Runs the image under cdb (the WinDbg package's amd64\cdb.exe) with
#   default:   g; .lastevent; k 30; q          (stops at the first-chance fault)
#   --bp SYM:  bp $exentry; g; bp SYM; g; .lastevent; k 30; q  (stops at
#              the first call of SYM, e.g. KERNELBASE!GetStdHandle, after the
#              image's entry: the image's frames are live)
# then parses the `k` stack. Every frame in the image (module+0xRVA) is named
# by the listing (--test-listing of the same build; .text at RVA 0x1000). The
# assertion: the image frames, in order, are exactly <want> (comma-separated,
# innermost first; a leading `...,` allows any image frames before the rest),
# and they are followed directly by KERNEL32!BaseThreadInitThunk and then
# ntdll!RtlUserThreadStart -- for --bp, frames above the image (KERNELBASE's
# own) come first and are skipped.
# Prints the named chain and exits 0 when it holds, 1 when it does not, 2 on a
# usage or transport error. The transcript is kept in $CDB_TRANSCRIPT if set.
set -u -o pipefail
NATIVE_HOST="${NATIVE_HOST:-laptop}"
EXE="${1:?usage: cdb_chain.sh <image.exe> <listing> <want> [--bp SYMBOL]}"; LST="${2:?listing}"; WANT="${3:?want}"
BP=""
if [ "${4:-}" = --bp ]; then BP="${5:?--bp needs a symbol}"; fi
RD="C:\\Users\\pante\\pe_unwind_scratch\\cdb$$"; RDF="C:/Users/pante/pe_unwind_scratch/cdb$$"
NAME=$(basename "$EXE")
rps() { ssh -o BatchMode=yes "$NATIVE_HOST" "powershell -NoProfile -NonInteractive -Command \"\$ProgressPreference='SilentlyContinue'; $1\"" < /dev/null; }
cleanup() {
    rps "for (\$i=0; \$i -lt 120 -and (Test-Path -LiteralPath '$RD'); \$i++) { Remove-Item -LiteralPath '$RD' -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath '$RD') { Start-Sleep -Milliseconds 500 } }; if ((Test-Path 'C:\\Users\\pante\\pe_unwind_scratch') -and -not (Get-ChildItem -Force 'C:\\Users\\pante\\pe_unwind_scratch')) { Remove-Item -Force 'C:\\Users\\pante\\pe_unwind_scratch' }; if (Test-Path -LiteralPath '$RD') { exit 1 }; exit 0" \
        || { echo "cdb_chain.sh: remote $RD not removed" >&2; exit 2; }
}
rps "New-Item -ItemType Directory -Force '$RD' | Out-Null; exit 0" > /dev/null || { echo "cdb_chain.sh: remote mkdir failed" >&2; exit 2; }
scp -q -o BatchMode=yes "$EXE" "$NATIVE_HOST:$RDF/$NAME" < /dev/null || { cleanup; echo "cdb_chain.sh: scp failed" >&2; exit 2; }
CMDS='g; .lastevent; k 30; q'
# --bp: run to the image's entry first, so a breakpoint in a system DLL only
# hits once the image's own code calls it (not during loader/CRT start-up)
[ -n "$BP" ] && CMDS="bp \$exentry; g; bp $BP; g; .lastevent; k 30; q"
OUT=$(rps "\$c=Join-Path (Get-AppxPackage *WinDbg*).InstallLocation 'amd64\\cdb.exe'; Set-Location '$RD'; & \$c -lines -c '$CMDS' '$RD\\$NAME' 2>&1; exit 0" | tr -d '\r')
TRC=$?
cleanup
[ "$TRC" = 0 ] || { echo "cdb_chain.sh: remote cdb run failed ($TRC)" >&2; exit 2; }
TF="${CDB_TRANSCRIPT:-$(mktemp)}"
printf '%s\n' "$OUT" > "$TF"
python3 -B - "$LST" "${NAME%.*}" "$WANT" "$TF" <<'PYEOF'
import re, sys
lst, mod, want = sys.argv[1], sys.argv[2].lower(), sys.argv[3].split(',')
labels, code_end = [], None
for l in open(lst, encoding='latin-1'):
    m = re.match(r'^([A-Za-z_.$][\w.$@]*):\s*$', l)
    m2 = re.match(r'^\s+([0-9a-f]{8}): ', l)
    if m and not m2:
        labels.append([None, m.group(1)])
    if m2 and labels and labels[-1][0] is None:
        labels[-1][0] = int(m2.group(1), 16)
    if l.startswith('; uw-code-end '):
        code_end = int(l.split()[2], 16)
labels = [(o, n) for o, n in labels if o is not None]
def name_of(rva):
    off = rva - 0x1000
    if off < 0 or (code_end is not None and off >= code_end):
        return '?+0x%x' % rva
    own = [n for o, n in labels if o <= off]
    return own[-1] if own else '?+0x%x' % rva
out = open(sys.argv[4], encoding='latin-1').read()
frames, ink = [], False
for l in out.split('\n'):
    if re.match(r'^\s*#?\s*Child-SP\s+RetAddr\s+Call Site', l):
        ink = True; frames = []; continue
    if ink:
        m = re.match(r'^\s*(?:[0-9a-f]+\s+)?[0-9a-f\`]+\s+[0-9a-f\`]+\s+(\S+)', l)
        if not m:
            if frames:
                ink = False
            continue
        site = m.group(1)
        mm = re.match(r'^([^!+]+)(?:!([^+]+))?(?:\+0x([0-9a-f]+))?$', site, re.I)
        if not mm:
            frames.append(('?', site)); continue
        mo, fn, off = mm.group(1), mm.group(2), mm.group(3)
        if mo.lower() == mod and fn is None and off:
            frames.append(('img', name_of(int(off, 16))))
        else:
            frames.append(('ext', '%s!%s' % (mo, fn) if fn else site))
names = [n for _, n in frames]
print('chain: ' + ' > '.join(names) if names else 'chain: (no k output)')
i = 0
while i < len(frames) and frames[i][0] != 'img':
    i += 1
j = i
while j < len(frames) and frames[j][0] == 'img':
    j += 1
img = [n for _, n in frames[i:j]]
rest = [n.lower() for _, n in frames[j:j + 2]]
if want and want[0] == '...':
    ok_img = img[-(len(want) - 1):] == want[1:] if len(want) > 1 else bool(img)
else:
    ok_img = img == want
ok_tail = rest == ['kernel32!basethreadinitthunk', 'ntdll!rtluserthreadstart']
if not (ok_img and ok_tail):
    print('FAIL: image frames %s (want %s), then %s (want KERNEL32!BaseThreadInitThunk, ntdll!RtlUserThreadStart)'
          % (img, want, rest))
    sys.exit(1)
print('OK')
PYEOF
RC=$?
[ -n "${CDB_TRANSCRIPT:-}" ] || rm -f "$TF"
exit $RC
