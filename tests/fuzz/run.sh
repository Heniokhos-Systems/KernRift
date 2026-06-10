#!/bin/bash
# Tier 2: differential fuzzer.
#
# 1. Generate N pseudo-random valid KernRift programs via generate.py.
#    Python computes the expected output for each (three-way oracle).
# 2. For each program, compile with --legacy and the default IR backend.
# 3. Run both binaries (with 15s timeout each) and compare stdout+exit
#    to the Python oracle.
# 4. A program whose three sources (oracle, legacy, IR) disagree is a
#    miscompile witness. The .kr + .expected pair gets copied into
#    tests/fuzz/regressions/ so it becomes a permanent test case on
#    every future fuzz run — the regression DB.
#
# The permanent regressions are also run every time (before random),
# so a regression never re-slips through even if fuzz coverage moves
# away from its specific shape.
#
# Env knobs:
#   KRC=<path>         compiler to test (default: ../build/krc2)
#   FUZZ_COUNT=<N>     programs to generate (default: 50)
#   FUZZ_SEED=<S>      rng seed (default: 0xDEADBEEF, so CI runs are
#                      reproducible unless explicitly overridden)
#   KRC_ARCH=...       arch flag (default: --arch=host)
#   FUZZ_RUNNER=<cmd>  wrapper to exec binaries under (e.g. qemu-...)

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
KRC="${KRC:-$REPO/../build/krc2}"
if [ ! -x "$KRC" ]; then KRC="$REPO/build/krc2"; fi
if [ ! -x "$KRC" ]; then echo "fuzz: krc not found ($KRC)" >&2; exit 2; fi

FUZZ_COUNT="${FUZZ_COUNT:-50}"
FUZZ_SEED="${FUZZ_SEED:-3735928559}"   # 0xDEADBEEF
if [ -z "${KRC_ARCH:-}" ]; then
    case "$(uname -m)" in
        x86_64|amd64)  KRC_ARCH="--arch=x86_64" ;;
        aarch64|arm64) KRC_ARCH="--arch=arm64" ;;
        *) echo "fuzz: unknown host arch $(uname -m)" >&2; exit 2 ;;
    esac
fi
RUNNER="${FUZZ_RUNNER:-}"

PASS=0
FAIL=0
FAIL_LIST=""

# Copy a failing case into the regressions dir for permanent coverage.
# Named after the run's seed + original idx so two fuzz runs don't
# collide; the generator's own `idx` prefix in the filename stays.
record_regression() {
    local src_kr="$1"
    local src_exp="$2"
    local base="$(basename "$src_kr" .kr)"
    # Ensure the regression DB exists — otherwise this cp fails exactly when
    # the fuzzer finds its first witness, losing the very case we need.
    mkdir -p "$DIR/regressions"
    local dst="$DIR/regressions/seed${FUZZ_SEED}_${base}"
    cp "$src_kr" "${dst}.kr"
    cp "$src_exp" "${dst}.expected"
    echo "  regression recorded: ${dst}.kr"
}

# Run one <name>.kr, compare legacy / IR / oracle three ways.
#   $1 = path to .kr
#   $2 = path to .expected (Python oracle)
#   $3 = source category (for reporting only)
run_one() {
    local src="$1" expected="$2" category="$3"
    local name="$(basename "$src" .kr)"
    local leg_bin="$(mktemp /tmp/krc_fuzz_${name}_leg_XXXX)"; rm -f "$leg_bin"
    local ir_bin="$(mktemp /tmp/krc_fuzz_${name}_ir_XXXX)"; rm -f "$ir_bin"
    local blog="$(mktemp)"

    if ! $KRC --legacy $KRC_ARCH "$src" -o "$leg_bin" > "$blog" 2>&1; then
        # Legacy compile failure on an IR-only feature is fine for the diff
        # harness (SKIP), but fuzz doesn't emit legacy-incompatible code.
        # So any legacy failure here is a real regression in the legacy
        # frontend/codegen — report it.
        echo "FAIL[$category]: $name (legacy compile failed)"
        sed 's/^/  /' "$blog" | tail -3
        FAIL=$((FAIL + 1)); FAIL_LIST="$FAIL_LIST $name(leg-build)"
        record_regression "$src" "$expected"
        rm -f "$leg_bin" "$ir_bin" "$blog"; return
    fi
    if ! $KRC $KRC_ARCH "$src" -o "$ir_bin" > "$blog" 2>&1; then
        echo "FAIL[$category]: $name (ir compile failed)"
        sed 's/^/  /' "$blog" | tail -3
        FAIL=$((FAIL + 1)); FAIL_LIST="$FAIL_LIST $name(ir-build)"
        record_regression "$src" "$expected"
        rm -f "$leg_bin" "$ir_bin" "$blog"; return
    fi
    chmod +x "$leg_bin" "$ir_bin" 2>/dev/null || true

    local leg_out="$(mktemp)" ir_out="$(mktemp)"
    local tmpwd="$(mktemp -d)"
    (cd "$tmpwd"; timeout 15s $RUNNER "$leg_bin" > "$leg_out" 2>&1); local leg_code=$?
    (cd "$tmpwd"; timeout 15s $RUNNER "$ir_bin"  > "$ir_out"  2>&1); local ir_code=$?
    rm -rf "$tmpwd"

    # Three-way: legacy, ir, oracle must all match.
    # exit code: both should be 0 (programs end with exit(0)).
    local legacy_ok=1 ir_ok=1 match_ok=1
    [ "$leg_code" = 0 ] || legacy_ok=0
    [ "$ir_code"  = 0 ] || ir_ok=0
    cmp -s "$leg_out" "$ir_out" || match_ok=0
    cmp -s "$leg_out" "$expected" || legacy_ok=0   # legacy vs oracle
    cmp -s "$ir_out"  "$expected" || ir_ok=0       # ir vs oracle

    if [ "$legacy_ok$ir_ok$match_ok" = "111" ]; then
        PASS=$((PASS + 1))
    else
        echo "FAIL[$category]: $name (leg_code=$leg_code ir_code=$ir_code leg_vs_oracle=$legacy_ok ir_vs_oracle=$ir_ok leg_vs_ir=$match_ok)"
        if ! cmp -s "$leg_out" "$ir_out"; then
            echo "  legacy vs ir diff:"
            diff "$leg_out" "$ir_out" | sed 's/^/    /' | head -10
        fi
        if ! cmp -s "$leg_out" "$expected"; then
            echo "  legacy vs oracle diff (- legacy, + oracle):"
            diff "$leg_out" "$expected" | sed 's/^/    /' | head -10
        fi
        FAIL=$((FAIL + 1)); FAIL_LIST="$FAIL_LIST $name"
        record_regression "$src" "$expected"
    fi
    rm -f "$leg_bin" "$ir_bin" "$leg_out" "$ir_out" "$blog"
}

# --- Permanent regressions first ---
reg_count=0
for reg_kr in "$DIR"/regressions/*.kr; do
    [ -e "$reg_kr" ] || continue
    reg_count=$((reg_count + 1))
    run_one "$reg_kr" "${reg_kr%.kr}.expected" "reg"
done
if [ "$reg_count" -gt 0 ]; then
    echo "--- replayed $reg_count regression cases ---"
fi

# --- Fresh random programs ---
FUZZ_TMP="$(mktemp -d /tmp/krc_fuzz_corpus_XXXX)"
if ! python3 "$DIR/generate.py" --out "$FUZZ_TMP" --count "$FUZZ_COUNT" --seed "$FUZZ_SEED" > /dev/null 2>&1; then
    echo "fuzz: generate.py failed (seed=$FUZZ_SEED is probably non-decimal — use a plain integer)" >&2
    rm -rf "$FUZZ_TMP"
    exit 2
fi
# Skip the loop entirely if nothing was generated, to avoid the bash
# glob expanding to the literal "*" and producing a misleading FAIL.
if compgen -G "$FUZZ_TMP/*.kr" > /dev/null; then
    for src in "$FUZZ_TMP"/*.kr; do
        run_one "$src" "${src%.kr}.expected" "fuzz"
    done
fi
rm -rf "$FUZZ_TMP"

echo ""
echo "=== fuzz: $PASS passed, $FAIL failed (seed=$FUZZ_SEED, count=$FUZZ_COUNT + $reg_count regressions) ==="
if [ "$FAIL" -gt 0 ]; then
    echo "  failed:$FAIL_LIST" >&2
    exit 1
fi
