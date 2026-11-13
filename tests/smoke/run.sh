#!/bin/bash
# Per-platform smoke corpus for KernRift.
#
# Runs every *.kr under tests/smoke/ against the current host target,
# prints PASS / FAIL per test, and exits non-zero if any test fails.
#
# Optional env knobs:
#   KRC=<path>     — compiler to test (default: ../build/krc2)
#   KRC_FLAGS=...  — extra flags (e.g. "--arch=x86_64 --emit=elfexe" for
#                    cross-compile + host-run, or "--arch=arm64 --emit=android"
#                    for Android)
#   SMOKE_RUNNER=<cmd>  — wrapper to invoke binaries under (e.g.
#                         "qemu-aarch64" for ARM64 via emulation).
#
# Expected exit code for each test is encoded in a single-line comment at
# the top of each .kr as "// expected: <N>". Defaults to 0.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
# Scratch under the one scratch root (#250): $KR_TEST_TMP, else $TMPDIR,
# else /tmp (tests/helpers/test_tmp.sh; refuses a bad root, exit 2).
. "$DIR/../helpers/test_tmp.sh"
KRT_R=$(kr_test_root "$REPO") || exit 2
KRC="${KRC:-$REPO/../build/krc2}"
# Default resolution: prefer build/krc2 if KRC wasn't explicitly set and
# the default doesn't exist.
if [ ! -x "$KRC" ]; then
    KRC="$REPO/build/krc2"
fi
KRC_FLAGS="${KRC_FLAGS:-}"
RUNNER="${SMOKE_RUNNER:-}"

# Default to host-native single-arch output if the caller didn't specify.
# Without --arch/--emit, krc produces a .krbo fat bundle which isn't
# directly runnable — that's the right default for end users but wrong
# for a smoke harness that exec()s the output.
if [ -z "$KRC_FLAGS" ]; then
    host_arch="$(uname -m)"
    host_os="$(uname -s)"
    case "$host_arch" in
        x86_64|amd64)  KRC_FLAGS="--arch=x86_64" ;;
        aarch64|arm64) KRC_FLAGS="--arch=arm64" ;;
        *) echo "smoke: unrecognised host arch $host_arch, defaulting to x86_64" >&2; KRC_FLAGS="--arch=x86_64" ;;
    esac
    case "$host_os" in
        Darwin)  KRC_FLAGS="$KRC_FLAGS --emit=macho" ;;
        Linux)   : ;;   # default ELF
        *)       : ;;
    esac
fi

if [ ! -x "$KRC" ]; then
    echo "smoke: krc not found (tried: $KRC)" >&2
    exit 2
fi

PASS=0
FAIL=0
TOTAL=0
FAIL_LIST=""

for src in "$DIR"/*.kr; do
    name="$(basename "$src" .kr)"
    TOTAL=$((TOTAL + 1))
    expected="$(grep -oE '// expected:[[:space:]]*[0-9]+' "$src" | head -1 | grep -oE '[0-9]+$')"
    expected="${expected:-0}"
    out="$(mktemp "$KRT_R/krc_smoke_${name}_XXXX")"
    rm -f "$out"
    build_log="$(mktemp)"
    if ! $KRC $KRC_FLAGS "$src" -o "$out" > "$build_log" 2>&1; then
        echo "FAIL: $name (compile failed)"
        sed 's/^/  /' "$build_log" | tail -5
        FAIL=$((FAIL + 1))
        FAIL_LIST="$FAIL_LIST $name"
        rm -f "$build_log"
        continue
    fi
    rm -f "$build_log"
    chmod +x "$out" 2>/dev/null || true
    abs_out="$(readlink -f "$out" 2>/dev/null || echo "$out")"
    tmpwd="$(mktemp -d)"
    (
        cd "$tmpwd"   # fresh tmpdir so file_rw / file_size side-files
                     # don't collide between runs
        $RUNNER "$abs_out" > /dev/null 2>&1
    )
    got=$?
    rm -rf "$tmpwd"
    if [ "$got" = "$expected" ]; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name (expected $expected, got $got)"
        FAIL=$((FAIL + 1))
        FAIL_LIST="$FAIL_LIST $name"
    fi
    rm -f "$out"
done

echo ""
echo "=== smoke: $PASS passed, $FAIL failed (total $TOTAL) ==="
if [ "$FAIL" -gt 0 ]; then
    echo "  failed:$FAIL_LIST" >&2
    exit 1
fi
