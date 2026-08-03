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
# what this gate must not copy.
#
# CI CANNOT RUN THIS GATE TODAY. .github/workflows/ci.yml installs only
# qemu-USER-static (:82, :250) and binutils-x86-64-linux-gnu (:382) — there is
# no qemu-system-x86_64 or qemu-system-aarch64 on any job, so every run of this
# script under CI as it stands would stop at the dependency loop below.
# Installing them and wiring this gate into a job is a later task's work; it is
# deliberately not done here. The failure mode meanwhile is loud and correct (a
# counted FAIL naming the missing tool, never a silent skip), so nothing is
# unsafe — but do not go looking for a CI job that already runs this.
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
#
# ON FAILURE THE WORK DIR IS KEPT, and its path is printed. Deleting it
# unconditionally destroyed the only copy of every build log, serial capture
# and qemu stderr the gate had just asserted against, so a red run left
# nothing to diagnose from — the same destroy-the-evidence mistake as
# truncating the output you are asserting against.
WORK=$(mktemp -d "$REPO/krc_boot_gate_XXXXXX")
cleanup() {
    rm -rf ${QMPD:+"$QMPD"}
    if [ "$FAIL" != 0 ]; then
        echo "  (work dir kept for diagnosis: $WORK)" >&2
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT INT TERM

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

# Gate-wide fixed addresses (used by every leg; leg 4 shifts the arm64 one).
A64_LOAD=0x40400000; A64_STUB=0x40300000; A64_SP=0x40800000
X86_LOAD=0x400000

# Compile a gate program and echo the ENTRY FILE OFFSET (decimal) on stdout.
# Task-2 form: --target=none ELF; the whole file is loaded at $*_LOAD, and
# because the ELF LOAD phdr maps file offset 0 to VA 0x400000, the entry's
# file offset is e_entry - 0x400000. (Task 6 swaps this body for --emit=image
# and the compiler's own report line; callers stay unchanged.)
#
# DERIVED, not assumed: both arches really do emit a single LOAD at offset 0 /
# VA 0x400000 with FileSiz == MemSiz (observed: x86 0x470, arm64 0x490), so
# there is no BSS tail that raw loading would leave unzeroed, and the file
# offset arithmetic is exact rather than approximately right.
build_image() {
    local arch="$1" src="$2" out="$3"
    local aflag="x86_64"
    [ "$arch" = "a64" ] && aflag="arm64"
    if ! "$KRC" --arch=$aflag --target=none "$src" -o "$out" >/dev/null 2>&1; then
        return 1
    fi
    local eva
    eva=$(readelf -h "$out" | awk '/Entry point/{print $4}')
    echo $(( eva - 0x400000 ))
}

# One arm64 boot: image file at $1's load addr, stub branching to entry.
# $1 load addr, $2 image, $3 entry off, $4 serial out.
a64_boot() {
    local load="$1" img="$2" entry="$3" ser="$4"
    python3 "$BOOT/make_stub.py" $(( load + entry )) "$A64_STUB" "$A64_SP" "$WORK/stub.bin"
    boot_run a64 "$ser" \
        -device loader,file="$WORK/stub.bin",addr=$A64_STUB,cpu-num=0 \
        -device loader,file="$img",addr=$(printf 0x%x "$load"),force-raw=on
}

# One x86 boot: loader built for the entry VA, image via -device loader.
x86_boot() {
    local load="$1" img="$2" entry="$3" ser="$4"
    "$BOOT/build_loader.sh" $(printf 0x%x $(( load + entry ))) "$WORK/ldr.elf" >/dev/null 2>&1 || return 1
    boot_run x86 "$ser" -kernel "$WORK/ldr.elf" \
        -device loader,file="$img",addr=$(printf 0x%x "$load"),force-raw=on
}

# =============================================================================
# L0 — the multiboot loader itself: builds, is loadable, and its liveness
#      sentinel is on the wire. Controls: a magic-corrupted build must be
#      REJECTED by qemu -kernel, and the missing-as path must FAIL loudly.
# =============================================================================
leg0() {
    echo "--- L0: x86_64 multiboot loader self-test ---"
    if ! "$BOOT/build_loader.sh" 0xdead0000 "$WORK/l0.elf" >"$WORK/l0.log" 2>&1; then
        # Print the WHOLE log, not head -1: for an assembler error line 1 is
        # only "…/boot.S: Assembler messages:" and the actual diagnostic is on
        # line 2, so head -1 named the file and nothing else. The work dir
        # survives a red run (see cleanup), so l0.log is still on disk too.
        echo "  build log ($WORK/l0.log, $(wc -l <"$WORK/l0.log") lines):"
        sed 's/^/    | /' "$WORK/l0.log"
        bad "L0_loader_builds" "build failed; full log printed above"; return
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
    # KNOWN RESIDUAL, stated exactly: a HANG on the good half still passes this
    # check, because `timeout`'s own stderr does not match the pattern either
    # (observed: it is "qemu-system-x86_64: terminating on signal 15 from pid N
    # (timeout)", exit 124 after the full 10 s).
    # The liveness count above only NARROWS that — it catches a hang BEFORE the
    # sentinel (count 0), not one after it. A loader whose entry spins in a hlt
    # loop prints exactly one sentinel, PASSES the liveness leg, and then passes
    # this check too. Built and observed: entry = the loader's own hlt loop
    # (0x1000b9) gives sentinel count 1 and a non-matching stderr, so the whole
    # of L0 goes green on a loader that hangs after the sentinel.
    # Nothing in L0 detects a post-sentinel hang; an earlier version of this
    # comment wrongly claimed the count covered it. Tasks 2-3 close the gap for
    # free: from there something after the call has to print for a leg to pass,
    # which a hung image cannot do.
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
    # `type -P`, not `command -v`: the latter answers with the bare NAME for a
    # shell builtin (pwd) or a shell function (some shells define one for
    # grep), which silently created a dangling self-symlink and left the
    # sandbox missing a tool the test never meant to remove.
    # `command -v -p` does NOT fix this — verified: with a grep function
    # defined, `command -v -p grep` still answers "grep", while `type -P grep`
    # answers /usr/bin/grep. bash-only, and this gate is bash-only already.
    SB="$WORK/sandbox_path"; mkdir -p "$SB"
    for t in bash dirname pwd mktemp head od tr grep rm; do
        p=$(type -P "$t" 2>/dev/null) && [ -n "$p" ] && ln -sf "$p" "$SB/$t"
    done
    if PATH="$SB" bash "$BOOT/build_loader.sh" 0x400000 "$WORK/l0_noas.elf" >"$WORK/l0_noas.log" 2>&1; then
        bad "L0_missing_as_fails" "build succeeded with no assembler on PATH"
    elif grep -q "no x86-capable GNU assembler found" "$WORK/l0_noas.log"; then
        ok "L0_missing_as_fails" "refused, naming every probed candidate"
    else
        bad "L0_missing_as_fails" "failed, but not with the named-probe message: $(head -1 "$WORK/l0_noas.log")"
    fi
}

# =============================================================================
# L1 — x86_64 boots and prints the computed sentinel. Controls: (a) no image
#      loaded => loader sentinel only; (b) entry replaced by OFFSET 0 — the
#      pre-B1 default wrong answer (O1/O2) => no sentinel; (c) entry - 4 — the
#      previous function's tail => no sentinel. NOT entry + 4: main's first
#      instructions are stack bookkeeping and +4/+8/+12 all still print (V16,
#      review round 1 C1).
#
#      WHAT OFFSET 0 ACTUALLY IS, stated as observed rather than as planned:
#      in TODAY's --target=none form the image is an ELF file loaded raw, so
#      file offset 0 is the ELF HEADER (`7f 45 4c 46 …`) executed as
#      instructions — not the UART provider's first helper, which is where it
#      will land once Task 6 makes the image headerless. Either way it is the
#      wrong answer the gate must reject, and it was observed silent here
#      (serial held the loader sentinel `KR-LDR|` and nothing else).
#
#      THE SENTINEL IS COMPUTED, not echoed: `2000000016` is `2000000007`
#      (a static written in main) plus 9 (returned from a call), formatted at
#      runtime. Verified on the artifacts: `strings -a` over sx.img, sa.img
#      and the loader ELF finds ZERO occurrences of either digit string, so
#      the wire cannot be carrying a copied literal.
# =============================================================================
leg1() {
    echo "--- L1: x86_64 boot + computed sentinel ---"
    cp "$BOOT/sentinel_x86.kr" "$WORK/sentinel_x86.kr"
    local entry
    if ! entry=$(build_image x86 "$WORK/sentinel_x86.kr" "$WORK/sx.img"); then
        bad "L1_compile" "sentinel_x86.kr did not compile"; return
    fi
    x86_boot "$X86_LOAD" "$WORK/sx.img" "$entry" "$WORK/l1_ser.txt"
    if grep -q "2000000016" "$WORK/l1_ser.txt" && grep -q "KR-LDR|" "$WORK/l1_ser.txt"; then
        ok "L1_sentinel" "computed 2000000016 + loader liveness on COM1"
    else
        bad "L1_sentinel" "serial held: '$(cat "$WORK/l1_ser.txt")'"
    fi
    # Control (a): same loader, NO image. The loader must still prove itself
    # alive and the program sentinel must be impossible.
    "$BOOT/build_loader.sh" $(printf 0x%x $(( X86_LOAD + entry ))) "$WORK/ldr.elf" >/dev/null 2>&1
    boot_run x86 "$WORK/l1_noimg.txt" -kernel "$WORK/ldr.elf"
    if grep -q "KR-LDR|" "$WORK/l1_noimg.txt" && ! grep -q "2000000016" "$WORK/l1_noimg.txt"; then
        ok "L1_control_no_image" "loader alive, program sentinel absent"
    else
        bad "L1_control_no_image" "serial held: '$(cat "$WORK/l1_noimg.txt")'"
    fi
    # Controls (b)/(c): offset 0 and entry-4 must not print — both observed
    # silent on this machine against these exact artifacts (see the header
    # note on what offset 0 really is today). They prove the entry value is
    # load-bearing at function granularity; instruction-level +4 is NOT
    # observable (V16), which is why it is not used as a control.
    x86_boot "$X86_LOAD" "$WORK/sx.img" 0 "$WORK/l1_off0.txt"
    if grep -q "2000000016" "$WORK/l1_off0.txt"; then
        bad "L1_control_offset0" "sentinel printed from offset 0"
    else
        ok "L1_control_offset0" "offset 0 => no sentinel"
    fi
    x86_boot "$X86_LOAD" "$WORK/sx.img" $(( entry - 4 )) "$WORK/l1_offm.txt"
    if grep -q "2000000016" "$WORK/l1_offm.txt"; then
        bad "L1_control_entry_minus4" "sentinel printed from the previous function's tail"
    else
        ok "L1_control_entry_minus4" "entry-4 => no sentinel"
    fi
}

# =============================================================================
# L2 — arm64 boots and prints the computed sentinel. Same three controls
#      (no-image; offset 0; entry - 4 — never entry + 4, see V16).
#
#      Position independence is what makes the 0x40400000 load address legal
#      even though the ELF is linked at 0x400000: every static access in the
#      arm64 output is `adrp x16, …` + a fixed displacement and every call is
#      a PC-relative `bl` (checked in the disassembly: 18 adrp, zero absolute
#      addresses). The x86 image is loaded at its link address, so the
#      question does not arise there.
# =============================================================================
leg2() {
    echo "--- L2: arm64 boot + computed sentinel ---"
    cp "$BOOT/sentinel_a64.kr" "$WORK/sentinel_a64.kr"
    local entry
    if ! entry=$(build_image a64 "$WORK/sentinel_a64.kr" "$WORK/sa.img"); then
        bad "L2_compile" "sentinel_a64.kr did not compile"; return
    fi
    a64_boot "$A64_LOAD" "$WORK/sa.img" "$entry" "$WORK/l2_ser.txt"
    if grep -q "1000000016" "$WORK/l2_ser.txt"; then
        ok "L2_sentinel" "computed 1000000016 on the PL011"
    else
        bad "L2_sentinel" "serial held: '$(cat "$WORK/l2_ser.txt")'"
    fi
    # Control (a): stub with NO image => silence (arm64 has no loader
    # sentinel; the stub is 4 instructions). This control exists to pin the
    # observation that silence CANNOT be a pass condition on this arch —
    # legs assert presence, never absence alone (review 2, O5).
    python3 "$BOOT/make_stub.py" $(( A64_LOAD + entry )) "$A64_STUB" "$A64_SP" "$WORK/stub.bin"
    boot_run a64 "$WORK/l2_noimg.txt" -device loader,file="$WORK/stub.bin",addr=$A64_STUB,cpu-num=0
    if grep -q "1000000016" "$WORK/l2_noimg.txt"; then
        bad "L2_control_no_image" "sentinel printed with no image loaded"
    else
        ok "L2_control_no_image" "no image => no sentinel"
    fi
    # Controls (b)/(c): offset 0 and entry-4 — both observed silent on this
    # machine against these exact artifacts (empty PL011 capture in each case).
    a64_boot "$A64_LOAD" "$WORK/sa.img" 0 "$WORK/l2_off0.txt"
    if grep -q "1000000016" "$WORK/l2_off0.txt"; then
        bad "L2_control_offset0" "sentinel printed from offset 0"
    else
        ok "L2_control_offset0" "offset 0 => no sentinel"
    fi
    a64_boot "$A64_LOAD" "$WORK/sa.img" $(( entry - 4 )) "$WORK/l2_offm.txt"
    if grep -q "1000000016" "$WORK/l2_offm.txt"; then
        bad "L2_control_entry_minus4" "sentinel printed from the previous function's tail"
    else
        ok "L2_control_entry_minus4" "entry-4 => no sentinel"
    fi
}

leg0
leg1
leg2

echo ""
echo "boot gate: $PASS pass, $FAIL FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
