#!/bin/bash
# native_exec.sh -- run a Windows executable natively on the laptop, as a
# drop-in for the Wine binary the suite's Wine rows call (#143, spec 8.6 (a);
# byte-identical in the KernRift and MLRift trees).
#
#   T10_WINE=tests/windows/native_exec.sh   (KR; ML: MLR_WINE=...)
#   native_exec.sh <exe> [args...]          run from the row's working directory
#   native_exec.sh --end-session            remove the session's remote tree
#   native_exec.sh --selftest-cmdline <fixtures dir>
#   native_exec.sh --env-forward            print NAME=<base64 value> of every variable it would forward
#   native_exec.sh --stdin-probe            print how stdin would be forwarded (no laptop contact)
#   native_exec.sh --selftest-stdin         stdin classification + runner-text checks (no laptop contact)
#
# Laptop side (user ruling, phase 5): INLINE PowerShell only. No script file is
# ever copied to the laptop and -EncodedCommand is never used (the laptop's
# antivirus deleted a staged runner script, then PowerShell over ssh was
# refused for a while). Each laptop step is one
#   ssh laptop "powershell -NoProfile -NonInteractive -Command \"<code>\""
# whose code uses single quotes only, no double quote and no %, so cmd.exe
# (the laptop sshd's shell) hands it to PowerShell unchanged. Everything
# variable -- the command line, the environment, the file manifest -- travels
# in DATA files (job.txt, manifest.txt) inside the staged archive, never in the
# command: no value meets cmd.exe's 8191-character limit or its quoting.
#
# Staging: the exe plus the cwd's contents, recursively (regular files up to
# 16 MiB and directories; the Wine prefixes pfx* are left out), keep their
# names and relative paths in a fresh remote run tree
# C:\Users\pante\pe_unwind_scratch\<session>\<job>\run. Files are copied by
# content: the session keeps a remote cache keyed by sha256, so only files the
# cache lacks travel (Mi8). NATIVE_SESSION names the session (default: one per
# invocation, removed at its end); a driver that sets it calls --end-session
# last.
#
# Command line: built here with the MSVC/UCRT quoting rules (argv_quote below,
# the inverse of the UCRT parser), or taken verbatim from NATIVE_RAW_CMDLINE
# (base64 of the whole line, argv[0] included). System.Diagnostics.Process
# starts the exe with lpCommandLine = "<absolute exe path>" + " " + Arguments,
# Arguments being the line after its argv[0] token VERBATIM (base64 in
# job.txt). So argv[0] is always the quoted absolute path; argv[1..] are exact.
#
# Environment: an allow-list -- every name in NATIVE_ENV (space-separated) and
# every exported KR_* / MLR_* variable -- is forwarded (values base64) through
# ProcessStartInfo.Environment with UseShellExecute=$false. Every KR_* / MLR_*
# variable the laptop process would otherwise pass on, and every NATIVE_ENV
# name that is unset here, is removed there (an unset name reads unset, never
# as the laptop's own value). A value that is not UTF-8 refuses the run (125).
# NATIVE_TEST_LAPTOP_ENV=NAME=VALUE (test hook, Task D) sets a variable in the
# laptop's PowerShell process before the start info is built.
#
# Stdin (merge-train step 8, the win_file_std* rows): the wrapper forwards its
# own stdin, keeping the KIND of handle the program sees. A regular file on
# stdin (`< file`) -> "file": the bytes travel as stdin.bin in the job archive
# and the program is started by Start-Process -RedirectStandardInput, so it
# gets a FILE handle (file_size(0) works, as under `cmd /c "x.exe < f"`). A
# pipe (`printf hi | ...`) -> "pipe": the bytes are written into the
# program's stdin pipe, which is then closed (the last read sees the writer
# gone: ERROR_BROKEN_PIPE). Anything else (a terminal, /dev/null, a device)
# -> "none": stdin is a pipe closed at once, as before. A pipe is read for at
# most NATIVE_STDIN_TIMEOUT seconds (default 60); one still open then refuses
# the run (125), never forwards a truncated input.
#
# Results: the program's stdout and stderr go to this script's stdout and
# stderr byte for byte; every file new or changed in the remote run tree (by
# sha256) and every new directory is copied back into the cwd; the exit status
# is the low byte of the program's (-1073741819 -> 5), 124 on a timeout
# (NATIVE_TIMEOUT seconds, default 300), and 125 when the wrapper itself
# failed (message on stderr). The run tree is removed and its absence asserted
# on the laptop, then the job tree (rrm).
set -u
NATIVE_HOST="${NATIVE_HOST:-laptop}"
REMOTE_ROOT='C:\Users\pante\pe_unwind_scratch'
REMOTE_ROOT_FWD='C:/Users/pante/pe_unwind_scratch'
LOCAL_STATE="${NATIVE_STATE_DIR:-$HOME/.cache/pe_unwind/native_sessions}"

die() { echo "native_exec.sh: $*" >&2; exit 125; }
# rps CODE: run inline PowerShell CODE on the laptop (single quotes only, no
# double quote, no %); the exit status is PowerShell's ($LASTEXITCODE there).
rps() { ssh -o BatchMode=yes "$NATIVE_HOST" "powershell -NoProfile -NonInteractive -Command \"\$ProgressPreference='SilentlyContinue'; $1\"" < /dev/null; }
# rrm PATH: remove PATH and assert it is gone. A file a program just wrote may
# be held for a moment by the laptop's antivirus scan, so removal retries for
# up to 60 s.
rrm() { rps "for (\$i=0; \$i -lt 120 -and (Test-Path -LiteralPath '$1'); \$i++) { Remove-Item -LiteralPath '$1' -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath '$1') { Start-Sleep -Milliseconds 500 } }; if (Test-Path -LiteralPath '$1') { exit 1 }; exit 0"; }

# runner SESSIONDIR JOB: the inline PowerShell that unpacks up-JOB.tar, stages
# the run tree from the cache, starts the program and packs JOB\out.tar.
runner() {
    local code
    code=$(cat <<'PSEOF'
$ErrorActionPreference='Stop';
$Ses='@S@'; $Job=Join-Path $Ses '@J@'; $Up=Join-Path $Ses 'up-@J@.tar';
tar.exe -xf $Up -C $Ses; if ($LASTEXITCODE) { exit 3 }; Remove-Item -LiteralPath $Up;
$Cache=Join-Path $Ses 'cache'; $Run=Join-Path $Job 'run'; $Out=Join-Path $Job 'out';
New-Item -ItemType Directory -Force $Cache,$Run,$Out | Out-Null;
$BlobTar=Join-Path $Job 'blobs.tar'; if (Test-Path $BlobTar) { tar.exe -xf $BlobTar -C $Cache; if ($LASTEXITCODE) { exit 3 } };
$kv=@{}; $ev=@{};
foreach ($l in [IO.File]::ReadAllLines((Join-Path $Job 'job.txt'))) { if (-not $l) { continue }; $i=$l.IndexOf('='); $k=$l.Substring(0,$i); $v=$l.Substring($i+1); if ($k -eq 'ENV') { $q=$v.IndexOf('='); $ev[$v.Substring(0,$q)]=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($v.Substring($q+1))) } else { $kv[$k]=$v } };
$Base=@{}; $Dirs=@{};
foreach ($l in [IO.File]::ReadAllLines((Join-Path $Job 'manifest.txt'))) { if (-not $l) { continue }; $h=$l.Substring(0,$l.IndexOf(' ')); $r=$l.Substring($l.IndexOf(' ')+1); $t=Join-Path $Run $r.Replace('/','\'); if ($h -eq 'D') { New-Item -ItemType Directory -Force $t | Out-Null; $Dirs[$r]=1; continue }; New-Item -ItemType Directory -Force (Split-Path $t) | Out-Null; Copy-Item -LiteralPath (Join-Path $Cache $h) $t; $Base[$r]=$h; $d=$r; while ($d.Contains('/')) { $d=$d.Substring(0,$d.LastIndexOf('/')); $Dirs[$d]=1 } };
if ($kv['LAPTOPENV']) { $q=$kv['LAPTOPENV'].IndexOf('='); [Environment]::SetEnvironmentVariable($kv['LAPTOPENV'].Substring(0,$q),$kv['LAPTOPENV'].Substring($q+1)) };
$p=New-Object Diagnostics.ProcessStartInfo; $p.FileName=Join-Path $Run $kv['EXE'].Replace('/','\');
$p.Arguments=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($kv['ARGS64']));
$p.WorkingDirectory=$Run; $p.UseShellExecute=$false; $p.RedirectStandardOutput=$true; $p.RedirectStandardError=$true; $p.RedirectStandardInput=$true;
foreach ($n in @($p.Environment.Keys)) { if (($n -like 'KR_*' -or $n -like 'MLR_*') -and -not $ev.ContainsKey($n)) { [void]$p.Environment.Remove($n) } };
if ($kv['NAMES']) { foreach ($n in $kv['NAMES'].Split(' ')) { if ($n -and -not $ev.ContainsKey($n)) { [void]$p.Environment.Remove($n) } } };
foreach ($n in $ev.Keys) { $p.Environment[$n]=$ev[$n] };
$In=Join-Path $Job 'stdin.bin';
if ($kv['STDIN'] -eq 'file') {
foreach ($n in @([Environment]::GetEnvironmentVariables().Keys)) { if (-not $p.Environment.ContainsKey($n)) { [Environment]::SetEnvironmentVariable($n,$null) } };
foreach ($n in @($p.Environment.Keys)) { [Environment]::SetEnvironmentVariable($n,$p.Environment[$n]) };
$sa=@{FilePath=$p.FileName; WorkingDirectory=$Run; RedirectStandardInput=$In; RedirectStandardOutput=(Join-Path $Out 'stdout.bin'); RedirectStandardError=(Join-Path $Out 'stderr.bin'); NoNewWindow=$true; PassThru=$true};
if ($p.Arguments) { $sa['ArgumentList']=$p.Arguments };
$x=Start-Process @sa; $null=$x.Handle;
if ($x.WaitForExit(1000*[int]$kv['TIMEOUT'])) { $x.WaitForExit(); $e=[string]$x.ExitCode } else { try { $x.Kill() } catch {}; $x.WaitForExit(); $e='TIMEOUT' }
} else {
$x=[Diagnostics.Process]::Start($p); $so=[IO.File]::Create((Join-Path $Out 'stdout.bin')); $se=[IO.File]::Create((Join-Path $Out 'stderr.bin'));
$a=$x.StandardOutput.BaseStream.CopyToAsync($so); $b=$x.StandardError.BaseStream.CopyToAsync($se);
if ($kv['STDIN'] -eq 'pipe') { $ib=[IO.File]::ReadAllBytes($In); try { $x.StandardInput.BaseStream.Write($ib,0,$ib.Length); $x.StandardInput.BaseStream.Flush() } catch {} };
try { $x.StandardInput.Close() } catch {};
if ($x.WaitForExit(1000*[int]$kv['TIMEOUT'])) { $x.WaitForExit(); $e=[string]$x.ExitCode } else { try { $x.Kill() } catch {}; $x.WaitForExit(); $e='TIMEOUT' };
[void]$a.Wait(30000); [void]$b.Wait(30000); $so.Close(); $se.Close()
};
[IO.File]::WriteAllText((Join-Path $Out 'exit.txt'),$e);
$sha=[Security.Cryptography.SHA256]::Create(); $ch=New-Object Collections.Generic.List[string]; $root=(Resolve-Path $Run).Path.TrimEnd('\')+'\';
foreach ($it in Get-ChildItem -LiteralPath $Run -Recurse -Force) { $r=$it.FullName.Substring($root.Length).Replace('\','/'); if ($it.PSIsContainer) { if (-not $Dirs.ContainsKey($r)) { $ch.Add('D '+$r) }; continue }; $f=[IO.File]::OpenRead($it.FullName); $h=[BitConverter]::ToString($sha.ComputeHash($f)).Replace('-','').ToLower(); $f.Close(); if ($Base[$r] -ne $h) { $ch.Add('F '+$r) } };
[IO.File]::WriteAllLines((Join-Path $Out 'changed.txt'),[string[]]$ch);
$fl=@($ch | Where-Object { $_.StartsWith('F ') } | ForEach-Object { $_.Substring(2) });
if ($fl.Count) { [IO.File]::WriteAllLines((Join-Path $Out 'changed.lst'),[string[]]$fl); tar.exe -cf (Join-Path $Out 'changed.tar') -C $Run -T (Join-Path $Out 'changed.lst'); if ($LASTEXITCODE) { exit 3 } };
tar.exe -cf (Join-Path $Job 'out.tar') -C $Out .; if ($LASTEXITCODE) { exit 3 };
for ($i=0; $i -lt 120 -and (Test-Path -LiteralPath $Run); $i++) { Remove-Item -LiteralPath $Run -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath $Run) { Start-Sleep -Milliseconds 500 } };
if (Test-Path -LiteralPath $Run) { exit 4 }; exit 0
PSEOF
)
    code=${code//@S@/$1}; code=${code//@J@/$2}
    printf '%s' "$code" | tr '\n' ' '
}

py() { python3 -B - "$@" <<'PYEOF'
import base64, hashlib, os, re, sys

def argv_quote(argv):
    """The Windows command line whose UCRT parse is argv (argv[0] by the
    program-name rule: quotes cannot be represented and are dropped; quoted
    when empty or containing a space or tab)."""
    a0 = argv[0].replace('"', '')
    parts = ['"%s"' % a0 if (a0 == '' or ' ' in a0 or '\t' in a0) else a0]
    for a in argv[1:]:
        if a != '' and not any(c in a for c in ' \t\n\v"'):
            parts.append(a)
            continue
        out, bs = '"', 0
        for c in a:
            if c == '\\':
                bs += 1
            elif c == '"':
                out += '\\' * (2 * bs + 1) + '"'
                bs = 0
            else:
                out += '\\' * bs + c
                bs = 0
        out += '\\' * (2 * bs) + '"'
        parts.append(out)
    return ' '.join(parts)

def ucrt_parse(line):
    """Reference parser: the UCRT's parse_cmdline (argv[0]: up to the closing
    quote or the first space/tab, no escapes; then the 2008+ rules: 2n
    backslashes + quote -> n backslashes and a quote toggle, 2n+1 -> n and a
    literal quote, "" inside quotes -> a literal quote)."""
    i, n, argv = 0, len(line), []
    a0, q = '', False
    while i < n:
        c = line[i]
        if c == '"':
            q = not q; i += 1; continue
        if not q and c in ' \t':
            break
        a0 += c; i += 1
    argv.append(a0)
    while True:
        while i < n and line[i] in ' \t':
            i += 1
        if i >= n:
            break
        cur, q = '', False
        while i < n:
            c = line[i]
            if c == '\\':
                j = i
                while j < n and line[j] == '\\':
                    j += 1
                k = j - i
                if j < n and line[j] == '"':
                    cur += '\\' * (k // 2)
                    if k % 2:
                        cur += '"'; i = j + 1
                    else:
                        i = j
                    continue
                cur += '\\' * k; i = j; continue
            if c == '"':
                if q and i + 1 < n and line[i + 1] == '"':
                    cur += '"'; i += 2; continue
                q = not q; i += 1; continue
            if not q and c in ' \t':
                break
            cur += c; i += 1
        argv.append(cur)
    return argv

def rawrest(line):
    """The bytes of a raw command line after its argv[0] token (the UCRT
    program-name rule: up to the closing quote or the first space/tab) and the
    one space or tab that ends it."""
    i, q = 0, False
    while i < len(line):
        if line[i] == 0x22:
            q = not q
        elif not q and line[i] in (0x20, 0x09):
            break
        i += 1
    return line[i + 1:]

def read_expected(path):
    """argv_table.expected / argv_roundtrip.expected: blocks of
    '#k rc=N', 'argc=N', '<arg>' lines, 'raw=<line>'."""
    blocks, cur = [], None
    for l in open(path, encoding='latin-1').read().split('\n'):
        if l.startswith('#'):
            cur = {'argv': []}; blocks.append(cur)
        elif l.startswith('raw=<') and cur is not None:
            cur['raw'] = l[5:-1]
        elif l.startswith('<') and l.endswith('>') and cur is not None:
            cur['argv'].append(l[1:-1])
    return blocks

cmd = sys.argv[1]
if cmd == 'quote':                    # quote ARGS... -> base64 of the line after its argv[0]
    line = argv_quote(sys.argv[2:])
    a0 = argv_quote(sys.argv[2:3])
    print(base64.b64encode(line[len(a0) + 1:].encode('utf-8')).decode())
elif cmd == 'rawrest':                # rawrest B64 -> base64 of the raw line after its argv[0]
    print(base64.b64encode(rawrest(base64.b64decode(sys.argv[2]))).decode())
elif cmd == 'manifest':               # manifest CWD EXE -> lines "<sha|D> <rel>"; blobs list
    cwd, exe = sys.argv[2], sys.argv[3]
    seen = {}
    out = []
    for root, dirs, files in os.walk(cwd):
        rel_root = os.path.relpath(root, cwd)
        if rel_root == '.':
            dirs[:] = [d for d in dirs if not d.startswith('pfx')]
        dirs.sort(); files.sort()
        for d in dirs:
            out.append('D ' + os.path.normpath(os.path.join(rel_root, d)).replace(os.sep, '/'))
        for f in files:
            p = os.path.join(root, f)
            if os.path.islink(p) or not os.path.isfile(p) or os.path.getsize(p) > 16 << 20:
                continue
            h = hashlib.sha256(open(p, 'rb').read()).hexdigest()
            rel = os.path.normpath(os.path.join(rel_root, f)).replace(os.sep, '/')
            out.append('%s %s' % (h, rel)); seen[h] = p
    ap = os.path.abspath(exe)
    if not ap.startswith(os.path.abspath(cwd) + os.sep):
        h = hashlib.sha256(open(ap, 'rb').read()).hexdigest()
        out.append('%s %s' % (h, os.path.basename(ap))); seen[h] = ap
    open(sys.argv[4], 'w').write('\n'.join(out) + '\n')
    open(sys.argv[5], 'w').write('\n'.join('%s %s' % (h, p) for h, p in sorted(seen.items())) + '\n')
elif cmd == 'envlist':                # envlist -> NAME=base64 lines (the allow-list)
    names = set((os.environ.get('NATIVE_ENV') or '').split())
    names |= set(k for k in os.environ if k.startswith('KR_') or k.startswith('MLR_'))
    out = []
    for k in sorted(names):
        if k in os.environ:
            try:
                out.append('%s=%s' % (k, base64.b64encode(os.environ[k].encode('utf-8')).decode()))
            except UnicodeEncodeError:
                # a value that is not UTF-8 cannot be given to the laptop
                # exactly: refuse the whole run, never forward a partial list
                sys.stderr.write('native_exec.sh: %s is not UTF-8; it cannot be forwarded exactly\n' % k)
                sys.exit(125)
    print('\n'.join(out))
elif cmd == 'envnames':               # envnames -> the NATIVE_ENV names, one line
    print(' '.join(sorted(set((os.environ.get('NATIVE_ENV') or '').split()))))
elif cmd == 'selftest-cmdline':       # selftest-cmdline FIXTURES
    fx, bad, n = sys.argv[2], [], 0
    # 1. the reference parser reproduces the C7 table (raw line -> argv)
    lines = open(os.path.join(fx, 'argv_table.txt'), encoding='latin-1').read().split('\n')
    exp = read_expected(os.path.join(fx, 'argv_table.expected'))
    for k, (l, e) in enumerate(zip(lines, exp)):
        got = ucrt_parse(l)
        n += 1
        if got != e['argv']:
            bad.append('table #%d: parse %r, expected %r' % (k, got, e['argv']))
    # 2. the builder reproduces the compiler's quoter (argv -> raw line) on
    #    the round-trip vectors, and the reference parser returns their argv
    for k, e in enumerate(read_expected(os.path.join(fx, 'argv_roundtrip.expected'))):
        line = argv_quote(e['argv'])
        n += 1
        if line != e['raw']:
            bad.append('roundtrip #%d: built %r, the quoter %r' % (k, line, e['raw']))
        if ucrt_parse(line) != e['argv']:
            bad.append('roundtrip #%d: %r parses to %r' % (k, line, ucrt_parse(line)))
    # 3. every table argv (from argv[1] on) survives build -> parse
    for k, e in enumerate(exp):
        argv = ['p.exe'] + e['argv'][1:]
        n += 1
        if ucrt_parse(argv_quote(argv)) != argv:
            bad.append('table #%d argv: %r -> %r' % (k, argv, ucrt_parse(argv_quote(argv))))
    # 4. NATIVE_RAW_CMDLINE: the program sees '"<exe path>"' + ' ' + rawrest
    #    (ProcessStartInfo), so argv[1..] of every raw table line must parse
    #    exactly as the line's own; the separator after argv[0] and trailing
    #    whitespace after a lone argv[0] are not carried (argv-level exact).
    for k, l in enumerate(lines):
        if not l and k == len(lines) - 1:
            continue
        rest = rawrest(l.encode('latin-1')).decode('latin-1')
        seen = '"C:\\s\\p.exe"' + (' ' + rest if rest else '')
        n += 1
        if ucrt_parse(seen)[1:] != ucrt_parse(l)[1:]:
            bad.append('raw table #%d: rest %r parses to %r, the line to %r' % (k, rest, ucrt_parse(seen)[1:], ucrt_parse(l)[1:]))
    for b in bad[:5]:
        print('FAIL ' + b)
    print('%d vectors, %d mismatches' % (n, len(bad)))
    sys.exit(1 if bad else 0)
else:
    sys.exit('native_exec.sh: unknown helper %s' % cmd)
PYEOF
}

# stdin_mode: how this process's stdin is forwarded -- file | pipe | none
stdin_mode() {
    if [ -t 0 ]; then echo none
    elif [ -f /dev/stdin ]; then echo file
    elif [ -p /dev/stdin ]; then echo pipe
    else echo none; fi
}
# stdin_capture MODE OUT: the bytes of stdin into OUT (file, pipe); 1 when a
# pipe stays open past NATIVE_STDIN_TIMEOUT seconds
stdin_capture() {
    case "$1" in
        file) cat > "$2" ;;
        pipe) timeout "${NATIVE_STDIN_TIMEOUT:-60}" cat > "$2" || return 1 ;;
        *) : ;;
    esac
}

case "${1:-}" in
    --selftest-cmdline) py selftest-cmdline "${2:?fixtures dir}"; exit $? ;;
    --stdin-probe)
        m=$(stdin_mode); t=$(mktemp); stdin_capture "$m" "$t" || { rm -f "$t"; echo "mode=$m refused (still open after ${NATIVE_STDIN_TIMEOUT:-60} s)"; exit 125; }
        echo "mode=$m bytes=$( [ "$m" = none ] && echo 0 || stat -c %s "$t") sha=$( [ "$m" = none ] && echo - || sha256sum "$t" | cut -c1-16)"; rm -f "$t"; exit 0 ;;
    --selftest-stdin)
        me="$0"; bad=0; n=0; d=$(mktemp -d); printf 'abcd' > "$d/f"
        chk() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "  case $1: $2"; else echo "  case $1: got '$2' want '$3'  <-- WRONG"; bad=$((bad + 1)); fi; }
        chk 'regular file (< file)' "$(bash "$me" --stdin-probe < "$d/f")" "mode=file bytes=4 sha=$(sha256sum < "$d/f" | cut -c1-16)"
        chk 'pipe (printf hi |)' "$(printf hi | bash "$me" --stdin-probe)" "mode=pipe bytes=2 sha=$(printf hi | sha256sum | cut -c1-16)"
        chk 'empty pipe' "$(printf '' | bash "$me" --stdin-probe)" "mode=pipe bytes=0 sha=$(printf '' | sha256sum | cut -c1-16)"
        chk '/dev/null' "$(bash "$me" --stdin-probe < /dev/null)" "mode=none bytes=0 sha=-"
        chk 'empty regular file' "$(: > "$d/e"; bash "$me" --stdin-probe < "$d/e")" "mode=file bytes=0 sha=$(sha256sum < "$d/e" | cut -c1-16)"
        chk 'pipe left open (refused)' "$( (sleep 5) | NATIVE_STDIN_TIMEOUT=1 bash "$me" --stdin-probe; echo "rc=$?")" "mode=pipe refused (still open after 1 s)
rc=125"
        # the runner text: inline PowerShell constraints (single quotes only:
        # no double quote, no %) and every stdin mode present
        rt=$(runner 'C:\S' 'J1')
        case "$rt" in *'"'*|*%*) chk 'runner text has no double quote and no %' bad ok ;; *) chk 'runner text has no double quote and no %' ok ok ;; esac
        for k in "STDIN'] -eq 'file'" "STDIN'] -eq 'pipe'" 'RedirectStandardInput=$In' 'StandardInput.BaseStream.Write'; do
            case "$rt" in *"$k"*) chk "runner has $k" ok ok ;; *) chk "runner has $k" missing ok ;; esac
        done
        rm -rf "$d"; echo "native_exec stdin selftest: $n cases, $bad wrong"; [ "$bad" = 0 ]; exit $? ;;
    --env-forward) py envlist; exit $? ;;
    --end-session)
        [ -n "${NATIVE_SESSION:-}" ] || die "--end-session needs NATIVE_SESSION"
        rrm "$REMOTE_ROOT\\$NATIVE_SESSION" || die "remote session tree $NATIVE_SESSION still exists"
        # the scratch root goes too once no session uses it
        rps "if ((Test-Path '$REMOTE_ROOT') -and -not (Get-ChildItem -Force '$REMOTE_ROOT')) { Remove-Item -Force '$REMOTE_ROOT' }; exit 0" \
            || die "could not remove the empty $REMOTE_ROOT"
        rm -rf "$LOCAL_STATE/$NATIVE_SESSION"
        exit 0 ;;
    "") die "usage: native_exec.sh <exe> [args...]" ;;
esac

EXE="$1"
[ -f "$EXE" ] || die "no such exe: $EXE"
OWN_SESSION=0
if [ -z "${NATIVE_SESSION:-}" ]; then NATIVE_SESSION="s$$-$(date +%s%N | tail -c 7)"; OWN_SESSION=1; export NATIVE_SESSION; fi
JOB="j$$-$(date +%s%N | tail -c 9)"
ST="$LOCAL_STATE/$NATIVE_SESSION"; LJ="$ST/jobs/$JOB"
mkdir -p "$LJ/blobs" "$LJ/up/$JOB" || die "cannot create $LJ"
touch "$ST/cached.lst"
cleanup_local() { rm -rf "$LJ"; if [ "$OWN_SESSION" = 1 ]; then "$0" --end-session; fi; }

# the command line, and its rest after argv[0]
if [ -n "${NATIVE_RAW_CMDLINE:-}" ]; then
    ARGS64=$(py rawrest "$NATIVE_RAW_CMDLINE") || die "bad NATIVE_RAW_CMDLINE"
else
    ARGS64=$(py quote "$(basename "$EXE")" "${@:2}") || die "quoting failed"
fi
EXEREL=$(python3 -c 'import os,sys; a=os.path.abspath(sys.argv[1]); c=os.getcwd()+os.sep; print(a[len(c):] if a.startswith(c) else os.path.basename(a))' "$EXE")
py manifest "$PWD" "$EXE" "$LJ/manifest.txt" "$LJ/blobs.lst" || die "manifest failed"
NEW=0
while read -r h p; do
    [ -n "$h" ] || continue
    grep -qx "$h" "$ST/cached.lst" && continue
    cp "$p" "$LJ/blobs/$h"; NEW=$((NEW + 1))
done < "$LJ/blobs.lst"
py envlist > "$LJ/env.lst" || { cleanup_local; exit 125; }
STDIN_MODE=$(stdin_mode)
if [ "$STDIN_MODE" != none ]; then
    stdin_capture "$STDIN_MODE" "$LJ/up/$JOB/stdin.bin" || { cleanup_local; die "stdin is a pipe still open after ${NATIVE_STDIN_TIMEOUT:-60} s"; }
fi
{
    echo "EXE=$EXEREL"
    echo "ARGS64=$ARGS64"
    echo "TIMEOUT=${NATIVE_TIMEOUT:-300}"
    echo "STDIN=$STDIN_MODE"
    echo "NAMES=$(py envnames)"
    sed '/^$/d; s/^/ENV=/' "$LJ/env.lst"
    if [ -n "${NATIVE_TEST_LAPTOP_ENV:-}" ]; then echo "LAPTOPENV=$NATIVE_TEST_LAPTOP_ENV"; fi
} > "$LJ/up/$JOB/job.txt"
cp "$LJ/manifest.txt" "$LJ/up/$JOB/"
if [ "$NEW" -gt 0 ]; then tar -C "$LJ/blobs" -cf "$LJ/up/$JOB/blobs.tar" . || die "tar blobs failed"; fi
tar -C "$LJ/up" -cf "$LJ/up.tar" . || die "tar up failed"
# one mkdir, one upload, one run, one download, one removal
R="$REMOTE_ROOT\\$NATIVE_SESSION"; RF="$REMOTE_ROOT_FWD/$NATIVE_SESSION"
rps "New-Item -ItemType Directory -Force '$R' | Out-Null; exit 0" > /dev/null || { cleanup_local; die "remote mkdir failed"; }
scp -q -o BatchMode=yes "$LJ/up.tar" "$NATIVE_HOST:$RF/up-$JOB.tar" < /dev/null || { cleanup_local; die "scp up failed"; }
rps "$(runner "$R" "$JOB")" >&2
RC=$?
[ "$RC" = 0 ] || { cleanup_local; die "remote run failed (status $RC)"; }
scp -q -o BatchMode=yes "$NATIVE_HOST:$RF/$JOB/out.tar" "$LJ/out.tar" < /dev/null || { cleanup_local; die "scp down failed"; }
rrm "$R\\$JOB" || { cleanup_local; die "remote job tree $R\\$JOB not removed"; }
awk '{print $1}' "$LJ/blobs.lst" >> "$ST/cached.lst"
mkdir -p "$LJ/out" && tar -m -C "$LJ/out" -xf "$LJ/out.tar" || { cleanup_local; die "bad result archive"; }
cat "$LJ/out/stdout.bin"
cat "$LJ/out/stderr.bin" >&2
while read -r k rel; do if [ "$k" = D ]; then mkdir -p "./$rel"; fi; done < "$LJ/out/changed.txt"
if [ -f "$LJ/out/changed.tar" ]; then tar -m -xf "$LJ/out/changed.tar" -C . || { cleanup_local; die "copy-back failed"; }; fi
CODE=$(cat "$LJ/out/exit.txt")
if [ -n "${NATIVE_DEBUG:-}" ]; then echo "native_exec.sh: exit $CODE; changed: $(tr '\n' ' ' < "$LJ/out/changed.txt")" >&2; fi
cleanup_local
if [ "$CODE" = TIMEOUT ]; then exit 124; fi
exit $(( (CODE % 256 + 256) % 256 ))
