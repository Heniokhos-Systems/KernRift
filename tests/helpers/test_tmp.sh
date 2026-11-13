# The ONE scratch-root resolver of the test scripts (#250, #262); POSIX sh,
# because Makefile recipes source it under /bin/sh (dash). Sourced by
# tests/run_tests.sh, the Makefile's bootstrap recipe and the standalone test
# scripts (diff_ir_legacy*.sh, diff/run.sh, smoke/run.sh, fuzz/run.sh).
#
# kr_test_root CHECKOUT prints the canonical scratch root on stdout:
#     $KR_TEST_TMP   if set and non-empty
#     else $TMPDIR   if set and non-empty
#     else /tmp
# resolved with `cd … && pwd -P` (absolute, symlinks resolved). It refuses --
# a FATAL line on stderr naming the variable, status 2, nothing on stdout --
# a root that does not exist, is not a directory or not writable; a relative
# value (the suite cd's, so it would mean different directories per row); a
# root inside CHECKOUT (git ls-files --others, the suite's find scans and
# import resolution would see the scratch); a character outside
# [A-Za-z0-9._/+@-] (paths are spliced into sed s#..#, qemu -serial file:,
# trap strings and kr string literals unescaped); and a root where an
# executable file cannot be run (rows execute the binaries they build there;
# a noexec mount). KR_TEST__EXEC_PROBE_MODE=0644 (test-only; exactly that
# value, anything else is FATAL) writes the probe without the x bit so a row
# can drive the noexec refusal where the host has no noexec directory.
# There is no fallback: a mistyped KR_TEST_TMP must not quietly fill /tmp.
kr_test_root() {
    if [ -n "${KR_TEST_TMP:-}" ]; then _ktr_raw=$KR_TEST_TMP; _ktr_from=KR_TEST_TMP
    elif [ -n "${TMPDIR:-}" ]; then _ktr_raw=$TMPDIR; _ktr_from=TMPDIR
    else _ktr_raw=/tmp; _ktr_from=default; fi
    _ktr_bad=""
    case $_ktr_raw in
        /*) ;;
        *) _ktr_bad="is a relative path" ;;
    esac
    if [ -z "$_ktr_bad" ]; then
        if [ ! -e "$_ktr_raw" ]; then _ktr_bad="does not exist"
        elif [ ! -d "$_ktr_raw" ]; then _ktr_bad="is not a directory"
        elif [ ! -w "$_ktr_raw" ]; then _ktr_bad="is not writable"
        fi
    fi
    _ktr_root=""
    if [ -z "$_ktr_bad" ]; then
        _ktr_root=$(cd "$_ktr_raw" 2> /dev/null && pwd -P) || _ktr_root=""
        [ -n "$_ktr_root" ] || _ktr_bad="cannot be entered"
    fi
    if [ -z "$_ktr_bad" ]; then
        case $_ktr_root in
            *[!A-Za-z0-9._/+@-]*) _ktr_bad="resolves to '$_ktr_root', which has a character outside [A-Za-z0-9._/+@-]" ;;
        esac
    fi
    if [ -z "$_ktr_bad" ] && [ -n "${1:-}" ]; then
        _ktr_co=$(cd "$1" 2> /dev/null && pwd -P) || _ktr_co=""
        if [ -n "$_ktr_co" ]; then
            case "$_ktr_root/" in
                "$_ktr_co"/*) _ktr_bad="resolves to '$_ktr_root', inside the checkout $_ktr_co" ;;
            esac
        fi
    fi
    if [ -z "$_ktr_bad" ]; then
        _ktr_mode=0755
        if [ -n "${KR_TEST__EXEC_PROBE_MODE:-}" ]; then
            if [ "$KR_TEST__EXEC_PROBE_MODE" = 0644 ]; then _ktr_mode=0644
            else
                echo "FATAL: KR_TEST__EXEC_PROBE_MODE='$KR_TEST__EXEC_PROBE_MODE': the only accepted value is 0644" >&2
                return 2
            fi
        fi
        _ktr_p=$(mktemp "$_ktr_root/.krc_exec_probe.XXXXXX" 2> /dev/null) || _ktr_p=""
        if [ -z "$_ktr_p" ]; then
            _ktr_bad="resolves to '$_ktr_root', where mktemp cannot create a file"
        else
            printf '#!/bin/sh\nexit 0\n' > "$_ktr_p" && chmod "$_ktr_mode" "$_ktr_p" \
                && "$_ktr_p" > /dev/null 2>&1 || _ktr_bad="resolves to '$_ktr_root', where a file cannot be executed (noexec mount?)"
            rm -f "$_ktr_p"
        fi
    fi
    if [ -n "$_ktr_bad" ]; then
        echo "FATAL: scratch root '$_ktr_raw' (from $_ktr_from) $_ktr_bad; set KR_TEST_TMP (or TMPDIR) to an absolute, writable, exec-capable directory outside the checkout" >&2
        return 2
    fi
    printf '%s\n' "$_ktr_root"
}
