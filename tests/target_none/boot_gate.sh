#!/bin/bash
# =============================================================================
# The bare-metal BOOT gate (sub-project B1)
# =============================================================================
# Closes the TODO(sub-project B) recorded in prove_no_syscalls.sh: every leg
# here is an OBSERVED RUN under qemu-system-*, and every leg ships with a
# negative control that has itself been observed failing. A leg that has only
# ever been seen passing is not a check — three of four legs of this gate's
# first design passed with the subject broken or absent (review 2, O5).
#
# HARD DEPENDENCIES — absence of any is a FAILURE, never a skip. The suite's
# existing qemu skips (tests/run_tests.sh:5240, :5720) do not increment TOTAL,
# so a skip there is indistinguishable from a pass; that pattern is exactly
# what this gate must not copy. CI installs qemu-system-x86 + qemu-system-arm
# for the suite jobs (.github/workflows/ci.yml).
#
# Usage:  tests/target_none/boot_gate.sh
# Env:    KRC=<path>  compiler under test (default build/krc2)
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
KRC="${KRC:-$REPO/build/krc2}"
BOOT="$DIR/boot"
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  $1: PASS${2:+ ($2)}"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $1${2:+ ($2)}"; }

# Import resolution: programs must sit in-repo so "../std/…" hits the tree
# under test, not the installed stdlib (same reasoning as prove_no_syscalls).
# Trap covers INT/TERM too; a SIGKILL can still strand a krc_boot_gate_*
# dir at repo root (same residue class as prove_no_syscalls' INREPO dir) —
# it is untracked and the never-add-all rule keeps it out of commits.
WORK=$(mktemp -d "$REPO/krc_boot_gate_XXXXXX")
trap 'rm -rf "$WORK" ${QMPD:+"$QMPD"}' EXIT INT TERM

# readelf leaves this list in Task 6 (its last user, build_image's ELF
# form, is replaced by the compiler's image: report there). as/ld are NOT
# probed here — build_loader.sh does its own FUNCTIONAL probe, because on
# an aarch64 host `command -v as` answers "yes" and means "no" (review round 1 C4).
for t in qemu-system-x86_64 qemu-system-aarch64 python3 readelf timeout od stat cmp awk sed; do
    if ! command -v "$t" >/dev/null 2>&1; then
        bad "boot_dep_$t" "$t not found — the boot gate REQUIRES it; absence is a failure, not a skip"
    fi
done
if [ "$FAIL" != 0 ]; then echo "boot gate: $PASS pass, $FAIL FAIL"; exit 1; fi

# Serial capture helper: run qemu for a bounded time, harvest COM1/PL011.
# $1 = arch (x86|a64), $2 = serial output file, rest = extra qemu args.
# x86 always runs -no-reboot: a triple fault otherwise REBOOT-LOOPS and
# replays the loader sentinel indefinitely (observed: 25 repetitions in
# 3 s, V17). With -no-reboot QEMU exits by itself; the kill is then a
# no-op and the wait still reaps.
boot_run() {
    local arch="$1" ser="$2"; shift 2
    local qemu="qemu-system-x86_64" machine="-no-reboot"
    if [ "$arch" = "a64" ]; then qemu="qemu-system-aarch64"; machine="-M virt -cpu cortex-a57"; fi
    # shellcheck disable=SC2086
    timeout 10 "$qemu" $machine -display none -serial "file:$ser" "$@" >/dev/null 2>&1 &
    local pid=$!
    sleep 4
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    return 0
}

# =============================================================================
# L0 — the multiboot loader itself: builds, is loadable, and its liveness
#      sentinel is on the wire. Controls: a magic-corrupted build must be
#      REJECTED by qemu -kernel, and the missing-as path must FAIL loudly.
# =============================================================================
leg0() {
    echo "--- L0: x86_64 multiboot loader self-test ---"
    if ! "$BOOT/build_loader.sh" 0xdead0000 "$WORK/l0.elf" >"$WORK/l0.log" 2>&1; then
        bad "L0_loader_builds" "$(head -1 "$WORK/l0.log")"; return
    fi
    ok "L0_loader_builds" "$(stat -c%s "$WORK/l0.elf") B"
    # Liveness: loader alone, entry 0xdead0000 (outside the identity map).
    # It prints the sentinel, triple-faults on the call, and -no-reboot
    # makes QEMU exit — observed: ONE sentinel, exit in ~80 ms (V17).
    # The assertion is an occurrence COUNT: without -no-reboot the fault
    # reboot-loops and replays the sentinel (25 times in 3 s observed),
    # and exact string equality could never pass.
    boot_run x86 "$WORK/l0_ser.txt" -kernel "$WORK/l0.elf"
    L0N=$(grep -o "KR-LDR|" "$WORK/l0_ser.txt" | wc -l)
    if [ "$L0N" = "1" ]; then
        ok "L0_loader_liveness_sentinel" "exactly one KR-LDR| with no image loaded"
    else
        bad "L0_loader_liveness_sentinel" "sentinel count $L0N, serial: '$(head -c 64 "$WORK/l0_ser.txt")'"
    fi
    # Negative control: corrupt the multiboot magic; qemu must refuse to
    # load it. THE DISCRIMINATOR IS STDERR, NOT THE EXIT CODE — a good
    # loader under a timeout kill also exits nonzero, so an exit-code
    # assertion passes for every input (review round 1 C3). Both halves
    # run here: the corrupt loader must draw the load-failure message and
    # the good loader, same command, must not. Both exit fast on their own
    # (-no-reboot; entry 0xdead0000 triple-faults the good one — V18).
    # KNOWN RESIDUAL: a HANG on the good half still passes this check, because
    # `timeout`'s own stderr does not match the pattern either. That is
    # tolerable only because the liveness count above catches hangs directly.
    cp "$WORK/l0.elf" "$WORK/l0_bad.elf"
    python3 - "$WORK/l0_bad.elf" <<'PY'
import sys
p = sys.argv[1]; d = bytearray(open(p, "rb").read())
i = d.find(bytes.fromhex("02b0ad1b"))
assert i >= 0, "magic not found — self-test and this control disagree"
d[i] ^= 0xFF
open(p, "wb").write(d)
PY
    timeout 10 qemu-system-x86_64 -display none -no-reboot -kernel "$WORK/l0_bad.elf" >/dev/null 2>"$WORK/l0_bad.err"
    timeout 10 qemu-system-x86_64 -display none -no-reboot -kernel "$WORK/l0.elf"     >/dev/null 2>"$WORK/l0_good.err"
    if grep -qE "PVH ELF Note|multiboot" "$WORK/l0_bad.err" && ! grep -qE "PVH ELF Note|multiboot" "$WORK/l0_good.err"; then
        ok "L0_corrupt_magic_rejected" "load failure named on the corrupt loader only (observed: 'Error loading uncompressed kernel without PVH ELF Note')"
    else
        bad "L0_corrupt_magic_rejected" "bad_err='$(head -c 80 "$WORK/l0_bad.err")' good_err='$(head -c 80 "$WORK/l0_good.err")'"
    fi
    # Negative control for the dependency policy: with every x86-capable
    # assembler candidate hidden, the build must FAIL naming what it
    # probed (never skip). The sandbox PATH carries only the tools
    # build_loader.sh itself needs.
    SB="$WORK/sandbox_path"; mkdir -p "$SB"
    for t in bash dirname pwd mktemp head od tr grep rm; do
        p=$(command -v $t 2>/dev/null) && ln -sf "$p" "$SB/$t"
    done
    if PATH="$SB" bash "$BOOT/build_loader.sh" 0x400000 "$WORK/l0_noas.elf" >"$WORK/l0_noas.log" 2>&1; then
        bad "L0_missing_as_fails" "build succeeded with no assembler on PATH"
    elif grep -q "no x86-capable GNU assembler found" "$WORK/l0_noas.log"; then
        ok "L0_missing_as_fails" "refused, naming every probed candidate"
    else
        bad "L0_missing_as_fails" "failed, but not with the named-probe message: $(head -1 "$WORK/l0_noas.log")"
    fi
}

leg0

echo ""
echo "boot gate: $PASS pass, $FAIL FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
