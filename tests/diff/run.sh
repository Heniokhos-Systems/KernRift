#!/bin/bash
# Differential harness: compile each corpus program two ways, run both,
# diff stdout + exit codes. Any divergence is a miscompile signal.
#
# Modes (set via DIFF_MODE):
#   backend  (default)  — legacy vs IR on the host arch. Programs that
#                         legacy can't compile (missing features) are
#                         SKIPped, not failed. Mismatches in compile
#                         output are real codegen drift.
#   crossarch           — IR x86_64 vs IR arm64 (run under qemu). Both
#                         emitters are expected to produce byte-identical
#                         stdout for every corpus program.
#
# Env knobs:
#   KRC=<path>      compiler under test (default: ../build/krc2)
#   KRC_ARCH=...    host arch flag (backend mode only)
#   DIFF_RUNNER=... binary wrapper for host-arch runs
#   QEMU_RUNNER=... arm64 runner (crossarch mode; default: tests/helpers/qemu_bin.sh's qemu-aarch64)
#
# Exits non-zero on any mismatch. SKIPs don't count as failures.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
KRC="${KRC:-$REPO/../build/krc2}"
if [ ! -x "$KRC" ]; then KRC="$REPO/build/krc2"; fi
if [ ! -x "$KRC" ]; then echo "diff: krc not found ($KRC)" >&2; exit 2; fi

MODE="${DIFF_MODE:-backend}"
if [ -z "${KRC_ARCH:-}" ]; then
    case "$(uname -m)" in
        x86_64|amd64)  KRC_ARCH="--arch=x86_64" ;;
        aarch64|arm64) KRC_ARCH="--arch=arm64" ;;
        *) echo "diff: unknown host arch $(uname -m)" >&2; exit 2 ;;
    esac
fi
RUNNER="${DIFF_RUNNER:-}"
. "$DIR/../helpers/qemu_bin.sh"
QEMU_RUNNER="${QEMU_RUNNER:-$(qemu_bin aarch64)}"

PASS=0
FAIL=0
SKIP=0
FAIL_LIST=""

# Run a compiled binary, capture stdout+stderr and exit code.
# Caps at 15s so a hung corpus entry can't wedge the harness.
run_bin() {
    local runner="$1" bin="$2" out="$3"
    local tmpwd="$(mktemp -d)"
    local code
    (cd "$tmpwd"; timeout 15s $runner "$bin" > "$out" 2>&1); code=$?
    rm -rf "$tmpwd"
    printf '%s' "$code"
}

if [ "$MODE" = "backend" ]; then
    for src in "$DIR"/corpus/*.kr; do
        name="$(basename "$src" .kr)"
        leg_bin="$(mktemp /tmp/krc_diff_${name}_leg_XXXX)"; rm -f "$leg_bin"
        ir_bin="$(mktemp /tmp/krc_diff_${name}_ir_XXXX)"; rm -f "$ir_bin"
        leg_log="$(mktemp)"; ir_log="$(mktemp)"

        $KRC --legacy $KRC_ARCH "$src" -o "$leg_bin" > "$leg_log" 2>&1
        leg_compile=$?
        $KRC $KRC_ARCH "$src" -o "$ir_bin" > "$ir_log" 2>&1
        ir_compile=$?

        if [ "$ir_compile" != 0 ]; then
            echo "FAIL: $name (ir compile failed)"
            sed 's/^/  /' "$ir_log" | tail -3
            FAIL=$((FAIL + 1)); FAIL_LIST="$FAIL_LIST $name(ir-build)"
            rm -f "$leg_bin" "$ir_bin" "$leg_log" "$ir_log"; continue
        fi
        if [ "$leg_compile" != 0 ]; then
            echo "SKIP: $name (legacy can't compile — feature gap, not a miscompile)"
            SKIP=$((SKIP + 1))
            rm -f "$leg_bin" "$ir_bin" "$leg_log" "$ir_log"; continue
        fi
        chmod +x "$leg_bin" "$ir_bin" 2>/dev/null || true

        leg_out="$(mktemp)"; ir_out="$(mktemp)"
        leg_code="$(run_bin "$RUNNER" "$leg_bin" "$leg_out")"
        ir_code="$(run_bin "$RUNNER" "$ir_bin"  "$ir_out")"

        if [ "$leg_code" = "$ir_code" ] && cmp -s "$leg_out" "$ir_out"; then
            PASS=$((PASS + 1))
        else
            echo "FAIL: $name (legacy exit=$leg_code, ir exit=$ir_code)"
            if ! cmp -s "$leg_out" "$ir_out"; then
                echo "  stdout diff (- legacy, + ir):"
                diff "$leg_out" "$ir_out" | sed 's/^/    /' | head -20
            fi
            FAIL=$((FAIL + 1)); FAIL_LIST="$FAIL_LIST $name"
        fi
        rm -f "$leg_bin" "$ir_bin" "$leg_out" "$ir_out" "$leg_log" "$ir_log"
    done
    echo ""
    echo "=== diff (backend): $PASS passed, $FAIL failed, $SKIP skipped ($KRC_ARCH) ==="
elif [ "$MODE" = "crossarch" ]; then
    if [ -z "$QEMU_RUNNER" ] || ! command -v "$QEMU_RUNNER" > /dev/null 2>&1; then
        echo "diff: no qemu-aarch64 runner ('$QEMU_RUNNER'); install qemu-user (or qemu-user-static)" >&2
        exit 2
    fi
    # crossarch walks BOTH corpus/ (legacy-compatible) and ir-only/
    # (features that only the IR backend supports); both are expected
    # to behave identically across x86_64 and arm64 IR.
    for src in "$DIR"/corpus/*.kr "$DIR"/ir-only/*.kr; do
        name="$(basename "$src" .kr)"
        x64_bin="$(mktemp /tmp/krc_diff_${name}_x64_XXXX)"; rm -f "$x64_bin"
        a64_bin="$(mktemp /tmp/krc_diff_${name}_a64_XXXX)"; rm -f "$a64_bin"
        blog="$(mktemp)"

        if ! $KRC --arch=x86_64 "$src" -o "$x64_bin" > "$blog" 2>&1; then
            echo "FAIL: $name (x86_64 compile failed)"; sed 's/^/  /' "$blog" | tail -3
            FAIL=$((FAIL + 1)); FAIL_LIST="$FAIL_LIST $name(x64-build)"
            rm -f "$blog"; continue
        fi
        if ! $KRC --arch=arm64 "$src" -o "$a64_bin" > "$blog" 2>&1; then
            echo "FAIL: $name (arm64 compile failed)"; sed 's/^/  /' "$blog" | tail -3
            FAIL=$((FAIL + 1)); FAIL_LIST="$FAIL_LIST $name(a64-build)"
            rm -f "$x64_bin" "$blog"; continue
        fi
        chmod +x "$x64_bin" "$a64_bin" 2>/dev/null || true

        x64_out="$(mktemp)"; a64_out="$(mktemp)"
        x64_code="$(run_bin "" "$x64_bin" "$x64_out")"
        a64_code="$(run_bin "$QEMU_RUNNER" "$a64_bin" "$a64_out")"

        if [ "$x64_code" = "$a64_code" ] && cmp -s "$x64_out" "$a64_out"; then
            PASS=$((PASS + 1))
        else
            echo "FAIL: $name (x64 exit=$x64_code, arm64 exit=$a64_code)"
            if ! cmp -s "$x64_out" "$a64_out"; then
                echo "  stdout diff (- x86_64, + arm64):"
                diff "$x64_out" "$a64_out" | sed 's/^/    /' | head -20
            fi
            FAIL=$((FAIL + 1)); FAIL_LIST="$FAIL_LIST $name"
        fi
        rm -f "$x64_bin" "$a64_bin" "$x64_out" "$a64_out" "$blog"
    done
    echo ""
    echo "=== diff (crossarch): $PASS passed, $FAIL failed ==="
else
    echo "diff: unknown DIFF_MODE '$MODE' (want backend|crossarch)" >&2
    exit 2
fi

if [ "$FAIL" -gt 0 ]; then
    echo "  failed:$FAIL_LIST" >&2
    exit 1
fi
