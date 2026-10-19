#!/usr/bin/env bash
# kr — KernRift fat binary launcher
#
# Termux on Android 14+ denies raw execve of files in /data/data/<app>/.
# Our runner binary (kr-bin) does a raw syscall and gets EACCES when it
# tries to launch the extracted slice. To work around this, this wrapper
# makes a file of its own for the run (mktemp, under $TMPDIR -- which Termux
# always sets -- else /tmp, never the current directory) and names it in
# $KR_EXEC_FALLBACK; when kr-bin cannot exec, it writes the slice there,
# chmods it and exits 120. We catch that
# here and run the file from the user's shell, where the Termux libc
# LD_PRELOAD wrapper makes exec succeed, then remove it. Two runs at once
# get two files, and none is left behind.
#
# Other platforms (Linux/macOS) raise no such restriction; the runner
# exec's directly, never touches the file, and we only remove it.

set -u

KRBIN="${KRBIN:-${0%/*}/kr-bin}"
[ -x "$KRBIN" ] || KRBIN=$(command -v kr-bin)
if [ -z "${KRBIN:-}" ] || [ ! -x "$KRBIN" ]; then
    echo "kr: kr-bin not found alongside this wrapper" >&2
    exit 1
fi

fb=$(mktemp "${TMPDIR:-/tmp}/kr-exec.XXXXXX" 2>/dev/null) || fb=""
[ -z "$fb" ] || trap 'rm -f "$fb"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

KR_EXEC_FALLBACK="$fb" "$KRBIN" "$@"
status=$?

# Termux fallback: 120 = "wrote the slice to $KR_EXEC_FALLBACK, exec was denied"
if [ "$status" -eq 120 ] && [ -n "$fb" ] && [ -s "$fb" ] && [ -x "$fb" ]; then
    shift  # drop the .krbo path; remaining args go to the slice
    "$fb" "$@"
    status=$?
fi

exit $status
