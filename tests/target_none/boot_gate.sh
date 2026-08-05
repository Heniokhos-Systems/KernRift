#!/bin/bash
# =============================================================================
# The bare-metal BOOT gate (sub-project B1; x86 legs re-pointed by B2 Task 5)
# =============================================================================
# SINCE B2 TASK 5 THE SUBJECT IS THE COMPILER'S OWN ENTRY STUB, NOT AN EXTERNAL
# LOADER. `--emit=image --stack-top=` now emits a self-sufficient artifact on
# both arches (B2 tasks 3 and 4), so:
#   * x86_64 boots as `qemu-system-x86_64 -kernel <image>` and NOTHING ELSE —
#     no loader ELF, no `-device loader`, no assembler on the machine;
#   * arm64 boots with the image and a reset-PC `-device loader,addr=…` and no
#     `file=` stub — make_stub.py is not invoked by L1, L2, L4 or L5.
# SUB-PROJECT C ADDED THE ARM64 `-kernel` FORM AS WELL, in L6: with the 64-byte
# `Image` header L6 hands the artifact to QEMU's own loader — no -device, no
# address — and QEMU decides where to put it by READING the header. That is the
# only invocation in this file where a header is recognised rather than merely
# present; see L6.
# WHAT THAT IS AND IS NOT, because the sentence that used to stand here
# ("the artifact is loadable by a real arm64 boot chain") asserted the untested
# headline as fact and this file contradicts it in L6's own block. What L6
# shows is that QEMU's `load_aarch64_image` READS our 64 bytes. It does not
# show they conform to the Linux `Image` specification — nothing in this tree
# does — and NO REAL BOOT CHAIN HAS RUN ANY OF THIS: no U-Boot `booti`, no EFI
# stub, no Android boot.img tooling, no hardware. Real-loader compatibility is
# sub-project C's design goal; one QEMU is its entire evidence.
# SUB-PROJECT D ADDED L7 AND L8, and they change what "loader" means again: no
# `-kernel` and no `-device loader` at all. The artifact is a PE32+ EFI
# application staged as `EFI/BOOT/BOOTX64.EFI` (or `BOOTAA64.EFI`) on a FAT
# volume, and the loader is edk2 — OVMF on q35, AAVMF on `virt` — which finds
# it by the removable-media path and parses the header the compiler emitted.
# The firmware images are a HARD DEPENDENCY of those two legs, resolved and
# asserted in their own block below rather than in the tool loop; see the
# comment there for why absence is still a counted FAILURE and still not a skip.
# Those two boots existed only as manual runs recorded in Task 3's and Task 4's
# reports until this file was changed — and sub-project D's OVMF/AAVMF boots
# existed only as prose in its Task 2 report until L7/L8. A result that lives
# only in a report is one refactor away from being unverified; every one of them
# is a leg now.
# SUB-PROJECT E ADDED L9, and it removes the loader entirely: `-bios <image>`,
# where the artifact IS the firmware. QEMU maps its 65536 bytes at 0xFFFF0000
# and the CPU comes out of reset fetching the last 16 of them, so the first
# instruction executed on the machine is one this compiler emitted, in 16-bit
# real mode. Same debt, same discharge: `--reset-vector`'s boot existed only as
# prose in E's Task 2 report until L9. See L9's own block for the four sentinel
# letters and for two proposed controls that were measured worthless.
#
# Discharges the bare-metal-execution debt recorded in prove_no_syscalls.sh's
# "WHAT A GREEN RUN DOES NOT CLAIM" note: every leg
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
# CI STATUS, stated precisely. Task 1 shipped with "CI cannot run this gate":
# ci.yml carried qemu-USER-static only. B1 Task 2 wired the gate into
# tests/run_tests.sh as a COUNTED test and added `qemu-system-x86 qemu-system-arm`
# to both jobs that invoke the suite (the ubuntu-latest x86_64 job and the
# ubuntu-24.04-arm job). THIS GATE NOW RUNS IN CI, and the clause that used to
# stand here — "NO CI RUN HAS EVER EXECUTED IT. Nothing in B1 is pushed" — is
# stale: B2's merge pushed both. origin/main is ee37196, and GitHub Actions run
# 30894588445 on that sha concluded success with `--- bare-metal boot gate ---`
# in the log of BOTH suite jobs (1032/1032 on ubuntu-latest x86_64, 1017/1017 on
# ubuntu-24.04-arm, 0 failed each). That also settles the two things B1 declared
# unverified from the dev machine: qemu-system-x86 does install on
# ubuntu-24.04-arm, and the emulated boots are affordable — on the x86_64
# runner ~24 s elapsed between this gate's banner and the suite summary, and
# the gate is the last section before it.
#
# WHAT IS STILL CI-UNRUN, RE-MEASURED AT E TASK 4 rather than inherited: this
# paragraph named L5 and L6, and that stopped being true when C and D merged.
# Checked, not assumed — `git show origin/main:tests/target_none/boot_gate.sh`
# at 07e0422 contains L6_kernel_boots and L7_uefi_x86_boots and does NOT contain
# L9_reset_vector_boots, and GitHub Actions run 30989294535 on that sha
# concluded success with both suite jobs (Linux x86_64 and Linux ARM64) green.
# So L0–L8 are on origin/main and CI executes them; the
# CI-unrun set is now exactly **L9's checks**, because sub-project E's branch is
# unpushed. NOTHING IN THIS FILE MAY SAY L9 HAS RUN IN CI UNTIL IT HAS. They run
# on the first push after E merges — nothing further is needed on the runners,
# which already carry qemu-system-x86 (⊃ qemu-system-x86_64) and python3. Until
# then, treat L9's evidence as produced on one developer machine. The failure
# mode is loud either way (a counted FAIL naming the missing tool, never a
# silent skip).
#
# Usage:  tests/target_none/boot_gate.sh
# Env:    KRC=<path>  compiler under test (default build/krc2)
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
KRC="${KRC:-$REPO/build/krc2}"

# STALE-BINARY WARNING, DELIBERATELY NOT A GATE (T5-M7).
#
# Under `make test` the compiler is rebuilt before the suite runs, so this is
# always silent there. The exposed path is the developer running this script
# standalone against a build/krc2 that predates their edit -- a false pass this
# project has already produced once (Task 1's `make` printing "Nothing to be
# done" while the gate reported green on the previous binary).
#
# WHY A WARNING AND NOT A REFUSAL: $KRC is an arbitrary path. Testing a
# release binary, a bisect build, or a copy from another worktree against this
# tree's src/ is a legitimate thing to do, and every one of those is "older
# than src/". A mtime comparison is a heuristic, not a proof of staleness, so
# it may not be allowed to turn a legitimate run red. It goes to stderr and
# names the file that is newer, so the message is actionable rather than a
# vague "might be stale".
if [ -e "$KRC" ]; then
    KRC_NEWER=$(find "$REPO/src" -name '*.kr' -newer "$KRC" -print -quit 2>/dev/null || true)
    if [ -n "$KRC_NEWER" ]; then
        echo "  WARNING: $KRC is OLDER than $KRC_NEWER -- this gate may be" >&2
        echo "  testing a stale compiler. Run 'make' first, or set KRC= deliberately." >&2
    fi
    unset KRC_NEWER
fi

BOOT="$DIR/boot"
PASS=0; FAIL=0; SKIP=0
SEEN=""
ok()   { PASS=$((PASS + 1)); SEEN="$SEEN $1"; echo "  $1: PASS${2:+ ($2)}"; }
bad()  { FAIL=$((FAIL + 1)); SEEN="$SEEN $1"; echo "FAIL: $1${2:+ ($2)}"; }

# A leg whose early check fails `return`s, so its SIBLING checks never run --
# and a red run then UNDER-REPORTS its own scope: breaking L1's compile step
# printed "1 pass, 1 FAIL" for a leg that contains five checks, so four
# assertions silently vanished from the tally rather than being named. That is
# fail-closed (the run is still red) but it hides how much is unverified.
#
# run_leg declares the checks a COMPLETE run of a leg reports, and names every
# one that did not run as SKIP. The roster deliberately omits failure-only
# names (L1_compile and friends report on the failure path only), so a green
# run has an empty skip set by construction.
run_leg() {
    local fn="$1"; shift
    "$fn"
    local c
    for c in "$@"; do
        case " $SEEN " in
            *" $c "*) ;;
            *) SKIP=$((SKIP + 1))
               echo "  $c: SKIP (an earlier failure in $fn stopped the leg before this check ran)" ;;
        esac
    done
}

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

# TASK 6 REMOVED readelf AND awk. Their only user in this file was one line
# inside build_image's ELF form (`readelf -h | awk '/Entry point/'`), and that
# body is now the compiler's own `image:` report — grep the file, there is no
# second call site. A hard dependency on a tool nothing runs is not harmless:
# absence is a FAILURE here by policy, so a dead entry false-fails the whole
# gate on a machine that never needed the tool. Removing them is therefore a
# correctness fix, not tidying.
#
# `cmp` was a PRE-EXISTING dead entry (no user in this file, and none in the
# external loader's build script either) and has been removed from the list
# below: a hard dependency on a tool nothing runs is the exact false-fail
# this comment block is about, so keeping it here would contradict the rule
# it states.
#
# B2 TASK 5 REMOVED `od` AND `wc` FOR THE SAME REASON. Their only users were
# build_loader.sh (od) and L0's build-log / sentinel counts (wc), and Task 5
# retired both — the x86 legs no longer build a loader at all. Same rule as
# above: a probed-but-unused tool false-fails the whole gate on a machine that
# never needed it.
#
# B2 TASK 6 RE-DERIVED THE WHOLE ROSTER after deleting boot.S, build_loader.sh
# and boot.ld, because that is precisely the edit that orphans a probe — and
# found NOTHING LEFT TO REMOVE: the loader's own tools (`as`, `ld`, `od`) had
# already gone with Task 5's retirement of L0's build legs, and every name
# below still has a live user in this file. The result is a non-change, which
# is worth recording: "the deletion changed no dependency" is a checked claim
# here, not an assumption.
#
# Still live, and where — verified by grep at Task 6, not inherited:
#   python3   make_stub.py (L3 only), qmp_pc.py, the image readers
#             loop_offset_a64 / halt_offset_x86 / mb_u32 / call_target_x86 /
#             img_bytes / rv_sites, the capture decoder rv_verdict, and
#             img_patch (L1's three patched controls, and every control in
#             L7, L8 and L9)
#   timeout   every boot, both arches
#   qemu-system-x86_64, qemu-system-aarch64   every boot
#   stat      build_image's on-disk size cross-check, L0's capture sizes,
#             L4's x86 artifact report
#   sed       build_image's `image:` report parse — the ONLY source of the
#             entry offset every leg branches to — build_uefi's `uefi:` one,
#             and build_reset_vector's `reset-vector:` one; all three are
#             DIFFERENT lines and each needs its own expression (see those two
#             functions' headers for why they are not arguments to build_image)
#   grep      boot_wait's expect match, every sentinel assertion
#   head      L1's `-c` log excerpts (one of them on the PASS path, in
#             L1_no_header_image_refused), L2's and L4's failure excerpts
#   tr        serial-capture flattening in L1/L2/L3/L4 diagnostics. NOTE this
#             one is reached only on failure paths, so a green run never
#             executes it. It stays a hard dependency deliberately: this gate's
#             red runs have to be readable, and a `tr: not found` inside a
#             failure message is a diagnostic lost exactly when it is needed.
#
# `as`/`ld` ARE NO LONGER A DEPENDENCY OF ANY KIND — they were the external
# loader's, that loader is deleted, and the compiler emits its own stub now.
for t in qemu-system-x86_64 qemu-system-aarch64 python3 timeout stat sed tr head grep; do
    if ! command -v "$t" >/dev/null 2>&1; then
        bad "boot_dep_$t" "$t not found — the boot gate REQUIRES it; absence is a failure, not a skip"
    fi
done
if [ "$FAIL" != 0 ]; then echo "boot gate: $PASS pass, $FAIL FAIL"; exit 1; fi

# Serial capture helper: run qemu, harvest COM1/PL011, stop as soon as the
# leg's evidence is in (or its window closes).
#
#   boot_run <arch: x86|a64> <serial file> <expect> [qemu args...]
#
# <expect> is one of three things, and it is mandatory and positional so that
# omitting it cannot silently degrade into "wait a while and hope" — a caller
# that forgets it hands qemu one fewer flag and the leg fails loudly:
#
#   <ERE>     the leg is WAITING FOR this; the run ends the instant it appears
#             on the wire, and gives up after the full deadline.
#   RUNOUT    no content trigger; short CALIBRATED window (absence controls).
#   SELFEXIT  no content trigger; wait up to the full deadline for qemu to end
#             by itself.
#
# WHY SELFEXIT EXISTS AND WHO USES IT NOW (rewritten at B2 Task 6 — the
# justification below it was B1's and described a check Task 4 retired: L0 used
# to count occurrences of the external loader's `KR-LDR|` sentinel, and there
# is no loader and no sentinel any more).
#
# Its three users today are the boots QEMU REFUSES: L0_deadboot_x86,
# L0_deadboot_a64, and L1_no_header_image_refused. None of them can wait for
# content — no guest instruction ever runs — and what each one reads is
# BOOT_QEMU_RC == 1, i.e. QEMU's OWN exit status. That is what rules out both
# other modes:
#   * an <ERE> would have nothing to match and would burn the full 10 s;
#   * RUNOUT would cap the wait at the CALIBRATED silence window, and if a slow
#     runner's qemu had not yet exited when that window closed, boot_run would
#     kill it and BOOT_QEMU_RC would be the KILL's status rather than qemu's
#     refusal — the discriminator these three controls are built on, silently
#     replaced by the harness's own signal.
# SELFEXIT costs nothing on the normal path (boot_wait's `kill -0` breaks the
# instant qemu is gone, ~2 ticks here) and leaves the full 10 s of headroom for
# a machine nobody has measured.
#
# RETURNS NONZERO IF THE BOOT DID NOT HAPPEN — AND CAPTURE-FILE EXISTENCE IS
# NOT HOW THAT IS DECIDED. It was, until B2 Task 5, and it was WRONG:
#
#   QEMU OPENS THE `file:` CHARDEV BEFORE IT PROCESSES `-device` AND `-kernel`.
#
# So a boot QEMU refuses to start — an unloadable `-device loader,file=`, a
# missing `-kernel`, an image with no valid multiboot header — still leaves an
# EXISTING, EMPTY capture behind, and `[ -f "$ser" ]` calls that a boot. Every
# control here that reads silence as evidence then passes on a QEMU that never
# executed a single guest instruction. MEASURED, all four cases, capture
# present and 0 bytes in each:
#   qemu-system-x86_64  -kernel /nonexistent.img      -> exit 1, "could not open kernel file"
#   qemu-system-x86_64  -kernel <no multiboot header> -> exit 1, "invalid kernel header"
#   qemu-system-aarch64 -device loader,file=/nonexistent -> exit 1, "Cannot load specified image"
#   (a boot that DID run, killed or self-exited)      -> exit 0
#
# THE DISCRIMINATOR IS QEMU'S EXIT STATUS, and specifically `== 1`, not `!= 0`.
# A guest that ran exits 0 whether we killed it (SIGTERM reaches qemu through
# `timeout`, which qemu handles as a clean shutdown) or it self-exited on a
# triple fault under -no-reboot — both measured. `!= 0` would additionally
# catch `timeout`'s own 124, which is REACHABLE: BOOT_DEADLINE_TICKS * BOOT_TICK
# is exactly the `timeout 10`, so a leg that waits the full deadline races the
# alarm. That race would false-FAIL a positive leg on a slow runner, which is
# the failure mode this gate exists to prevent, so the check is `== 1`.
# L0_alarm_not_a_dead_boot is what holds it at `== 1`: it drives a real boot to
# rc 124 with a one-second alarm and asserts boot_run still calls it a boot.
# Without it, `== 1` -> `!= 0` is a regression no check in this gate can see.
#
# UNTIL TASK 5 THE x86 HALF OF THIS WAS CLOSED A DIFFERENT WAY: every x86
# silence control also required the external loader's `KR-LDR|` liveness
# sentinel on the wire, which is real proof a guest ran. THAT SENTINEL BELONGED
# TO THE LOADER TASK 4 REPLACED. Under `-kernel <image>` nothing prints before
# the payload, so the shield died with the loader and x86 needed this same
# exit-status check — it is NOT already handled by the arm64 fix.
#
# THE CHECK IS ITSELF GATED, permanently, by L0's dead-boot legs: they run a
# boot QEMU refuses, assert boot_run reports failure, AND assert the capture
# file is present — i.e. they assert that the pre-fix predicate WOULD have
# passed. L0's liveboot leg is the other half: boot_run must NOT flag a boot
# that really ran, so "always return 1" cannot pass the gate either.
#
# BOOT_QEMU_RC is the raw status, exported for diagnostics and for L0.
#
# WHY NOT `sleep 4` (what task 1 shipped), AND WHY NOT PLAIN EXIT-POLLING
# (what task 2's first report proposed). Both were wrong, and MEASURED rather
# than argued this time. Only the boots QEMU REFUSES self-exit quickly (the
# three SELFEXIT users listed above); EVERY leg whose guest actually runs parks
# or spins until it is killed — L1's four x86 boots park on a halt or a landing
# pad, and all of L2's, L3's and L4's arm64 boots park in a `b .` or spin in
# the exception vector. (B1 wrote this paragraph with leg names — L1_sentinel,
# L1_no_image — that Tasks 4 and 5 retired; the shape of the argument survived
# the re-pointing, the names did not.) Therefore:
#   * exit-polling with the 10 s backstop is NOT semantically identical to the
#     sleep — it is strictly worse, because every spinning boot would then wait
#     the full 10 s (~60 s of gate against today's 36 s);
#   * a fixed `sleep 4` does not merely waste time, it CREATES a race. A boot
#     needing more than 4 s under TCG on a CI runner would false-fail a
#     POSITIVE leg, and no CI job has ever run this gate, so that risk is live
#     and unmeasured.
# Polling the CONTENT removes both: a positive leg ends as soon as its evidence
# is on the wire and only gives up after 10 s, so a slow runner costs latency
# instead of a false failure.
#
# x86 always runs -no-reboot, so a triple-faulting guest EXITS instead of
# reboot-looping. B1 needed this: its external loader replayed `KR-LDR|` on
# every reboot (observed: 25 repetitions in 3 s, V17) and L0 counted those
# occurrences. That loader and that count are both gone, so no leg depends on
# the flag today — it is kept because the alternative is a faulting guest
# spinning to the deadline with nothing on the wire, which costs 10 s per leg
# and tells a reader nothing. With -no-reboot QEMU exits by itself; the kill is
# then a no-op and the wait still reaps.
BOOT_TICK=0.05            # poll granularity, seconds
# `timeout`'s alarm, in seconds. A VARIABLE ONLY SO L0 CAN EXERCISE rc 124 --
# every real leg runs at the 10 s default and none of them touches it. L0's
# alarm check turns it down to 1 s, which is the only way to reach the 124 path
# without deliberately running a boot past the full deadline (10 s of gate time
# for one control). It is saved and restored around that one check.
BOOT_TIMEOUT=10
BOOT_DEADLINE_TICKS=200   # 10 s — hard ceiling on waiting for evidence
# Window for a RUNOUT leg. Seeded at 2 s and then RE-DERIVED by each leg from
# its own positive boot (8x the time that boot needed to reach the wire, capped
# at the deadline), so on a slow TCG runner the controls stretch in step with
# the thing they are controlling for. A fixed window would go vacuous exactly
# where the machine is slowest — the failure mode this gate exists to prevent.
BOOT_SILENCE_TICKS=40
BOOT_WAITED_TICKS=0       # out-param: ticks actually waited by the last run
BOOT_QEMU_RC=0            # out-param: qemu's exit status from the last run
# out-param of boot_run_qmp: the guest's parked PC, or one of the two LOUD
# non-values that function documents (QMPFAIL / MOVING:<pc>).
#
# THE RULE THAT GOVERNS IT LIVES HERE, ON THE DECLARATION, AND NOT ON ANY ONE
# HELPER (B2 Task 6, finding N2). It used to live on `x86_boot`, which Task 5
# left with no call sites -- so a routine "delete the dead helpers" pass would
# have taken the rule out with them. Attached to the variable, it cannot be
# orphaned: every future helper has to set this.
#
#   A NON-QMP BOOT MUST DESTROY THE PREVIOUS RUN'S PC.
#
# Without that, a control MOVED OFF a _qmp helper keeps reading the LAST QMP
# run's value and its parked-PC assertion silently becomes a no-op -- and on
# this gate the arm64 controls all park at the same 0x200, so it would go on
# passing with its discriminator switched off. NOQMPRUN fails every consumer's
# shape-check by design (the `case` guards in L2 and L3 reject it, and the `=`
# comparisons in L1/L2 fail closed against it).
#
# EVERY non-QMP helper below sets it: a64_self_boot (live, L4), x86_boot and
# a64_boot (no call sites today -- see their headers).
PARKED_PC=NOQMPRUN        # never a stale value
# The wait itself, factored out because boot_run_qmp (L3) needs the SAME
# semantics while the guest is still alive. Two copies of this loop would
# drift, and the mode that drifted would be the one nobody re-derived.
#   boot_wait <qemu pid> <serial file> <expect>
boot_wait() {
    local pid="$1" ser="$2" expect="$3" n=0
    local limit="$BOOT_DEADLINE_TICKS"
    [ "$expect" = "RUNOUT" ] && limit="$BOOT_SILENCE_TICKS"
    while [ "$n" -lt "$limit" ]; do
        if [ "$expect" != "RUNOUT" ] && [ "$expect" != "SELFEXIT" ] &&
           [ -s "$ser" ] && grep -qE "$expect" "$ser" 2>/dev/null; then
            break
        fi
        # Self-exit early-out: once qemu is gone no further byte can arrive,
        # so both kinds of leg can stop waiting immediately.
        kill -0 "$pid" 2>/dev/null || break
        sleep "$BOOT_TICK"
        n=$((n + 1))
    done
    BOOT_WAITED_TICKS="$n"
}
boot_run() {
    local arch="$1" ser="$2" expect="$3"; shift 3
    local qemu="qemu-system-x86_64" machine="-no-reboot"
    if [ "$arch" = "a64" ]; then qemu="qemu-system-aarch64"; machine="-M virt -cpu cortex-a57"; fi
    rm -f "$ser" "$ser.err"
    BOOT_QEMU_RC=0
    # qemu's stderr is KEPT, not discarded: it is the only place the reason for
    # a refused boot is written, and $WORK survives a red run.
    # shellcheck disable=SC2086
    timeout "$BOOT_TIMEOUT" "$qemu" $machine -display none -serial "file:$ser" "$@" >/dev/null 2>"$ser.err" &
    local pid=$!
    boot_wait "$pid" "$ser" "$expect"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    BOOT_QEMU_RC=$?
    # No capture file => qemu never opened it => no boot occurred.
    [ -f "$ser" ] || return 1
    # Capture present but qemu REFUSED the boot. See this function's header:
    # the chardev is opened before -device/-kernel, so this is the case that
    # hands a free pass to every control that reads silence as evidence.
    [ "$BOOT_QEMU_RC" != 1 ] || return 1
    return 0
}

# Re-derive the RUNOUT window from a positive boot that has just been observed
# reaching the wire in $BOOT_WAITED_TICKS. 8x margin, floor 2 s, cap 10 s.
calibrate_silence() {
    BOOT_SILENCE_TICKS=$(( BOOT_WAITED_TICKS * 8 ))
    [ "$BOOT_SILENCE_TICKS" -lt 40 ] && BOOT_SILENCE_TICKS=40
    [ "$BOOT_SILENCE_TICKS" -gt "$BOOT_DEADLINE_TICKS" ] && BOOT_SILENCE_TICKS="$BOOT_DEADLINE_TICKS"
    return 0
}

# Gate-wide fixed addresses (used by every leg; leg 4 shifts the arm64 one).
# A64_STUB is the load address of the EXTERNAL make_stub.py stub, which since
# Task 5 has exactly one user left: L3 (see leg3's header for why).
A64_LOAD=0x40400000; A64_STUB=0x40300000; A64_SP=0x40800000
X86_LOAD=0x400000
# --stack-top values handed to the compiler for the EMITTED stubs.
# arm64: 4 MiB above the image, 16-byte aligned, below 2^32.
# x86_64: BELOW the image (0x90000 < 0x400000) and below the 1 GiB identity
# map — both preconditions Task 4 validates and refuses on.
A64_STACK_TOP=0x40800000
X86_STACK_TOP=0x90000

# Compile a gate program to a RAW HEADERLESS IMAGE and echo the ENTRY FILE
# OFFSET (decimal) on stdout. Callers are unchanged from the Task-2 ELF form
# this replaced; everything else about the artifact changed.
#
# THIS IS THE FIRST TIME ANYTHING --emit=image PRODUCES HAS EXECUTED. Task 5
# proved the images look right — statics located by initialiser value, every
# arm64 ADRP pair resolving in image coordinates, entry cross-checked against
# the ELF's e_entry — and said so plainly: all 13 of its rows are static, and
# each can pass with the image broken. Every leg below is now a run.
#
# THE REPORT IS THE ONLY SOURCE OF THE ENTRY OFFSET, which is new. A flat
# image has no e_entry, no phdrs and no section table, so the number the gate
# branches to is a number the compiler printed and nothing can cross-check on
# the artifact. The gate therefore PROVES it instead of trusting it: legs 1
# and 2 each boot `load + entry` (must print a computed sentinel) alongside
# `load + 0` and `load + entry - 4` (must stay silent) — see those legs'
# headers for what each address actually is in image form.
#
# EXIT STATUS IS CHECKED, AND SO IS THE ARTIFACT'S SIZE. The `image:` line is
# printed BEFORE the file is written (src/main.kr, report ~:3204 vs
# codegen_write_output ~:3383), so a well-formed report can describe a file
# that does not exist and a grep-only parse goes green on it. Exit status
# alone does not close that either: codegen_write_output ignores file_write's
# return (src/codegen.kr:16126-16130), so a SHORT write exits 0. All three are
# required here — exit 0, a parsable line, and on-disk size == the reported
# filesz. The full compiler output is kept beside the artifact ($WORK survives
# a red run) instead of going to /dev/null as the ELF form did, so a failed
# compile leaves its diagnostic behind.
#
# --load-addr is MANDATORY for --emit=image and is validated and reported,
# never embedded (Task 5: image_load_addr_not_embedded_*). That is exactly
# what lets leg 4 compile at $A64_LOAD and then boot THE SAME BYTES at
# +0x100 — the artifact does not depend on the address it was compiled for,
# so the misaligned half of that pair is a load-time fact about arm64 ADRP
# arithmetic and not a different build.
#
# THE OPTIONAL 4th ARGUMENT IS `--stack-top=<v>`, and it is what makes the
# artifact SELF-SUFFICIENT (B2 tasks 3 and 4): with it the compiler emits its
# own entry stub — arm64 `movz/movk/mov sp,x0; bl <entry>; b .`, x86_64 a
# multiboot header plus a 32-bit long-mode trampoline — and the reported
# `entry` is the STUB, not the entry function. Without it the output is B1's
# bare blob for somebody else's loader, which is what L3 still uses.
#
# THE OPTIONAL 5th ARGUMENT IS EXTRA FLAGS, added by sub-project C Task 2 for
# `--image-header` (L5). It is a plain word-split string and NOT a general
# escape hatch: everything that must hold for the returned `entry` to be
# meaningful -- exit 0, a parsable `image:` line, on-disk size == reported
# filesz -- is asserted for the extended form exactly as for the plain one, so
# a flag that breaks any of those fails the caller rather than being waved
# through. Callers passing nothing get byte-for-byte the previous command line.
build_image() {
    local arch="$1" src="$2" out="$3" stop="${4:-}" extra="${5:-}"
    local aflag="x86_64" iload="$X86_LOAD"
    if [ "$arch" = "a64" ]; then aflag="arm64"; iload="$A64_LOAD"; fi
    local log="$out.rep"
    local sflag=""
    [ -n "$stop" ] && sflag="--stack-top=$stop"
    rm -f "$out"
    # shellcheck disable=SC2086
    if ! "$KRC" --arch=$aflag --target=none --emit=image $sflag $extra \
                --load-addr=$(printf 0x%x "$iload") "$src" -o "$out" >"$log" 2>&1; then
        echo "  build_image: $KRC exited nonzero for $src (see $log)" >&2
        return 1
    fi
    local entry filesz ondisk
    entry=$(sed -n 's/^image: .* entry=\([0-9][0-9]*\) .*$/\1/p' "$log")
    filesz=$(sed -n 's/^image: .* filesz=\([0-9][0-9]*\) .*$/\1/p' "$log")
    if [ -z "$entry" ] || [ -z "$filesz" ]; then
        echo "  build_image: no parsable 'image:' line for $src (see $log)" >&2
        return 1
    fi
    ondisk=$(stat -c%s "$out" 2>/dev/null)
    if [ "$ondisk" != "$filesz" ]; then
        echo "  build_image: report claims filesz=$filesz but $out is ${ondisk:-ABSENT} B" >&2
        return 1
    fi
    echo "$entry"
}

# One arm64 boot on the EXTERNAL make_stub.py stub: image file at $1's load
# addr, stub branching to entry.
# $1 load addr, $2 image, $3 entry off, $4 serial out, $5 expect (see boot_run).
# EVERY step propagates failure. A stub the generator refused to emit, or a
# qemu that never opened the capture, must not look like "the program stayed
# quiet" to a control that reads silence as a pass.
#
# NO CALL SITES TODAY, and that is why it kept its defect until B2 Task 6
# (finding N1): it was the third non-QMP helper and the only one that never
# got the PARKED_PC clobber. It is KEPT rather than deleted because L3 is
# still on the external stub (see leg3's header) and the QMP/non-QMP pair is
# where a demotion of an L3 control would land -- which is exactly the move
# that would have reopened the stale-PC hazard. A dead bash function cannot
# affect a result; a dead HARD DEPENDENCY can, and those are removed (see the
# dependency block above). The two are not the same class of dead thing.
a64_boot() {
    local load="$1" img="$2" entry="$3" ser="$4" expect="$5"
    PARKED_PC=NOQMPRUN   # see the PARKED_PC declaration above
    python3 "$BOOT/make_stub.py" $(( load + entry )) "$A64_STUB" "$A64_SP" "$WORK/stub.bin" || return 1
    boot_run a64 "$ser" "$expect" \
        -device loader,file="$WORK/stub.bin",addr=$A64_STUB,cpu-num=0 \
        -device loader,file="$img",addr=$(printf 0x%x "$load"),force-raw=on
}

# One arm64 SELF-boot: the compiler's own emitted stub, no stub FILE. The only
# file on the command line is the artifact under test; the second -device
# carries an ADDRESS ONLY and just parks the reset PC on the emitted stub.
# `make_stub.py` is not invoked. $1 load, $2 image, $3 entry off (the stub's,
# as reported), $4 serial, $5 expect.
a64_self_boot() {
    local load="$1" img="$2" entry="$3" ser="$4" expect="$5"
    PARKED_PC=NOQMPRUN   # see the PARKED_PC declaration above
    boot_run a64 "$ser" "$expect" \
        -device loader,file="$img",addr=$(printf 0x%x "$load"),force-raw=on \
        -device loader,addr=$(printf 0x%x $(( load + entry ))),cpu-num=0
}
a64_self_boot_qmp() {
    local load="$1" img="$2" entry="$3" ser="$4" expect="$5"
    PARKED_PC=QMPFAIL   # never let a leg read the PREVIOUS run's PC
    boot_run_qmp a64 "$ser" "$expect" \
        -device loader,file="$img",addr=$(printf 0x%x "$load"),force-raw=on \
        -device loader,addr=$(printf 0x%x $(( load + entry ))),cpu-num=0
}

# One arm64 boot handed to QEMU'S OWN IMAGE LOADER: `-kernel <image>` and
# NOTHING ELSE — no -device loader, no addr=, no load address, no entry offset.
# The arm64 twin of x86_boot/x86_boot_qmp, and the ONLY pair in this file where
# the placement and the start address are decisions QEMU makes by READING the
# artifact rather than parameters this script passed in. That difference is the
# whole subject of L6; see that leg's header.
# $1 image, $2 serial, $3 expect.
#
# THE NON-QMP FORM HAS ONE USER, L6's refusal control, for the reason
# boot_run's header gives: a boot QEMU never starts has no PC to read, and
# SELFEXIT + BOOT_QEMU_RC is what that control asserts on.
a64_kernel_boot() {
    local img="$1" ser="$2" expect="$3"
    PARKED_PC=NOQMPRUN   # see the PARKED_PC declaration above
    boot_run a64 "$ser" "$expect" -kernel "$img"
}
a64_kernel_boot_qmp() {
    local img="$1" ser="$2" expect="$3"
    PARKED_PC=QMPFAIL   # never let a leg read the PREVIOUS run's PC
    boot_run_qmp a64 "$ser" "$expect" -kernel "$img"
}

# One x86_64 SELF-boot. THE WHOLE COMMAND LINE IS `-kernel <image>` — no loader
# ELF, no `-device loader`, no load address (the emitted multiboot header
# carries it), no entry offset (the header carries that too). This pair
# replaced B1's x86_boot, which assembled an external multiboot long-mode
# loader (tests/target_none/boot/boot.S, deleted by B2 Task 6 along with
# build_loader.sh and boot.ld) and loaded the image beside it.
# $1 image, $2 serial, $3 expect.
#
# THE NON-QMP FORM HAS NO CALL SITES TODAY — all four L1 legs read a PC, so
# every one of them is on the _qmp twin. Kept for the same reason a64_boot is
# (see that function's header), and the rule its body used to carry now lives
# on the PARKED_PC declaration, where a delete-dead-code pass cannot take it.
x86_boot() {
    local img="$1" ser="$2" expect="$3"
    PARKED_PC=NOQMPRUN   # see the PARKED_PC declaration above
    boot_run x86 "$ser" "$expect" -kernel "$img"
}
x86_boot_qmp() {
    local img="$1" ser="$2" expect="$3"
    PARKED_PC=QMPFAIL
    boot_run_qmp x86 "$ser" "$expect" -kernel "$img"
}

# boot_run WITH a QMP socket, so the guest's PC can be read while it is still
# running. Same contract as boot_run — capture deleted before launch, and the
# SAME dead-boot rule (missing capture, or a qemu that exited 1 having refused
# to start the guest), same <expect> vocabulary via boot_wait — plus the
# out-param PARKED_PC.
#
# TASK 5 GAVE IT AN <arch>. It was arm64-only through B1 because only L3 read a
# PC; the x86 stub's halt is now read the same way (`RIP=` — qmp_pc.py already
# covered both), and duplicating this function per arch is exactly the drift
# its own header warns about for boot_wait.
#
#   boot_run_qmp <arch: x86|a64> <serial file> <expect> [qemu args...]
#
# PARKED_PC is lower-case hex without 0x or leading zeros, or one of two
# LOUD non-values:
#   QMPFAIL       the query did not produce a PC (socket, protocol, or qemu).
#   MOVING:<pc>   the PC never stopped changing, so nothing here is "parked";
#                 <pc> is the last sample taken.
# CONSUMERS MUST SHAPE-CHECK IT. L3's crash control asserts `!=` against the
# loop address, and both non-values satisfy a `!=` vacuously — a broken QMP
# path would paint that control green with the discriminator never having run
# (review round 1, I5). The `=` comparisons fail closed and need no guard, but
# get the same explicit check so a red run says which thing broke.
#
# WHY TWO SAMPLES AND NOT ONE. "Parked" is a claim that the machine has
# STOPPED, and a single sample cannot distinguish a halt loop from a PC that
# merely happened to be there as the guest ran through. Sampling until two
# consecutive reads agree makes parked an observed property. It also removes
# the race a fixed settle would have: the wait ends the instant MID reaches
# the wire, microseconds of guest time before the halt is entered.
# Re-sampling (rather than one fixed gap) is what keeps a slow TCG runner
# from FALSE-FAILING here — the same reasoning as the derived silence window.
#
# THE SOCKET LIVES UNDER /tmp, NOT $WORK. AF_UNIX paths cap at 107 bytes, and
# past that qemu exits 1 with its stderr discarded: every leg then reads
# QMPFAIL against an empty serial capture with no attribution.
BOOT_QMP_GAP=0.25         # seconds between consecutive PC samples
BOOT_QMP_TRIES=20         # give up (=> MOVING) after this many samples
boot_run_qmp() {
    local arch="$1" ser="$2" expect="$3"; shift 3
    local qemu="qemu-system-x86_64" machine="-no-reboot"
    if [ "$arch" = "a64" ]; then qemu="qemu-system-aarch64"; machine="-M virt -cpu cortex-a57"; fi
    QMPD="${QMPD:-$(mktemp -d /tmp/krcqmp.XXXXXX)}"
    local sock="$QMPD/qmp.sock"
    rm -f "$ser" "$ser.err" "$sock"
    PARKED_PC=QMPFAIL
    BOOT_QEMU_RC=0
    # shellcheck disable=SC2086
    timeout 15 "$qemu" $machine -display none \
        -serial "file:$ser" -qmp "unix:$sock,server,nowait" "$@" >/dev/null 2>"$ser.err" &
    local pid=$!
    boot_wait "$pid" "$ser" "$expect"
    local prev="" cur="" i=0
    while [ "$i" -lt "$BOOT_QMP_TRIES" ]; do
        cur=$(python3 "$BOOT/qmp_pc.py" "$sock" 2>>"$WORK/qmp_err.txt") || cur=QMPFAIL
        [ -z "$cur" ] && cur=QMPFAIL      # empty stdout is a failure, not a PC
        [ "$cur" = QMPFAIL ] && break
        [ "$cur" = "$prev" ] && break     # two consecutive reads agree => parked
        prev="$cur"; cur=""
        sleep "$BOOT_QMP_GAP"
        i=$((i + 1))
    done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    BOOT_QEMU_RC=$?
    if [ "$cur" = QMPFAIL ]; then
        PARKED_PC=QMPFAIL
    elif [ -z "$cur" ]; then
        PARKED_PC="MOVING:$prev"
    else
        PARKED_PC="$cur"
    fi
    # No capture file => qemu never opened it => no boot occurred.
    [ -f "$ser" ] || return 1
    # Capture present but qemu refused the boot — see boot_run's header.
    [ "$BOOT_QEMU_RC" != 1 ] || return 1
    return 0
}

# File offset of the UNIQUE arm64 self-branch (loop{} == word 0x14000000).
# Echoes the decimal offset; fails the calling leg if the count is not
# exactly 1.
#
# SINCE TASK 6 THE SCAN RUNS ON THE RAW IMAGE, so the offset it returns is
# already the image offset and L3's `A64_LOAD + offset` needs no header
# correction — measured, both forms: 0x314 = 788 under the Task-2 ELF, 668
# here, and 788 - 668 = 120, the Ehdr+Phdr that is no longer there. The scan
# still covers the whole file including static data (Task 3 concern 3): a
# coincidental 0x14000000 data word yields AMBIG:N and a FALSE FAILURE, never
# a false pass. Task 3 hoped Task 6 would let this be narrowed to .text; it
# does the opposite — an image has no section table at all, so whole-file is
# now the only possible scan, and the fail-safe direction is what makes that
# acceptable rather than a regression.
#
# THE UNIQUENESS IS ASSERTED, NOT ASSUMED, and that is the whole reason this
# is a separate check with its own PASS line. L3 reads "PC == load + offset"
# as "the machine is in heap_bump_halt's loop". A second self-branch anywhere
# in the image — another loop{}, a different inlining decision, a data word
# that happens to be 0x14000000 — makes that inference unsound, and it would
# do so SILENTLY: the leg would go on passing while no longer discriminating.
loop_offset_a64() {
    python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
offs = [i for i in range(0, len(d) - 3, 4) if d[i:i+4] == bytes.fromhex("00000014")]
if len(offs) != 1:
    print("AMBIG:%d" % len(offs)); sys.exit(1)
print(offs[0])
PY
}

# WHERE QEMU PUT A `-kernel` IMAGE, recovered from a boot that parked on the
# stub's own `b .`:  base = PARKED_PC - <that image's halt offset>.
#   $1 parked PC (lower-case hex, no 0x — PARKED_PC's shape), $2 halt offset.
# Echoes the base in DECIMAL, or a loud non-value (BADPC:<pc>, OUTSIDE:<base>)
# and a nonzero status.
#
# THE SHAPE CHECK IS HERE, ONCE, AND IT IS NOT OPTIONAL. Every L6 caller ends
# up comparing two bases, and `$(( 0x$pc ))` on a non-hex PARKED_PC — QMPFAIL,
# MOVING:4020040c, NOQMPRUN — is a bash arithmetic ERROR whose value is 0. Two
# broken boots would then produce equal bases and a `!=` control would go green
# with its discriminator switched off, which is precisely the vacuity B1's I5
# recorded for the raw `!=` comparisons.
#
# THE RAM BOUND IS THE SECOND HALF OF THAT. A guest that faulted parks in the
# exception vector at 0x200, and 0x200 - halt is NEGATIVE for every image this
# gate builds: a silent control must not be able to hand back a plausible-
# looking number. It is an assertion in its own right for the quiet controls,
# which use the FAILURE of this function as their evidence ("not parked in its
# stub at any legal load base") rather than asserting a bare `!=`.
A64_VIRT_RAM=0x40000000        # -M virt: base of DRAM
A64_VIRT_RAM_SIZE=134217728    # -M virt default, 128 MiB (quoted back by qemu
                               # itself in L6's too-large refusal message)
a64_kernel_base() {
    local pc="$1" halt="$2" base
    case "$pc" in
        "" | *[!0-9a-f]*) echo "BADPC:$pc"; return 1 ;;
    esac
    base=$(( 0x$pc - halt ))
    if [ "$base" -lt $(( A64_VIRT_RAM )) ] ||
       [ "$base" -ge $(( A64_VIRT_RAM + A64_VIRT_RAM_SIZE )) ]; then
        echo "OUTSIDE:$base"; return 1
    fi
    echo "$base"
}

# IS `$base` A BASE, OR IS IT ONE OF a64_kernel_base's NON-VALUES? (Task 3
# review, Minor 1.) The two `!=` controls in L6 compare their own mutant's base
# against the SUBJECT's, and the subject's is captured in a chain that calls
# bad() and keeps going -- so if the subject's boot breaks while the mutants'
# do not, `$base` holds BADPC:QMPFAIL or OUTSIDE:-1234 and `[ "$basebad" =
# "$base" ]` is trivially false. Both controls then PASS on a comparison
# against a non-value, printing it through printf %x as "0x0". The gate still
# reds -- L6_kernel_load_base_is_header_derived fails on the same condition, so
# NO FALSE-GREEN RUN IS POSSIBLE -- but a control must not print PASS for a
# discriminator that never ran, which is this file's rule everywhere else
# (a64_kernel_base's own shape check exists for the same reason one level
# down). Decimal digits only: that is exactly what a64_kernel_base echoes on
# success, and every non-value it echoes carries a colon and a prefix.
a64_base_is_value() {
    case "$1" in
        "" | *[!0-9]*) return 1 ;;
    esac
    return 0
}

# a64_boot's QMP twin: identical addressing and identical failure propagation,
# plus PARKED_PC. $1 load addr, $2 image, $3 entry off, $4 serial, $5 expect.
a64_boot_qmp() {
    local load="$1" img="$2" entry="$3" ser="$4" expect="$5"
    PARKED_PC=QMPFAIL   # never let a leg read the PREVIOUS run's PC
    python3 "$BOOT/make_stub.py" $(( load + entry )) "$A64_STUB" "$A64_SP" "$WORK/stub.bin" || return 1
    boot_run_qmp a64 "$ser" "$expect" \
        -device loader,file="$WORK/stub.bin",addr=$A64_STUB,cpu-num=0 \
        -device loader,file="$img",addr=$(printf 0x%x "$load"),force-raw=on
}

# File offset of the UNIQUE x86 stub halt (`hlt; jmp .` == f4 eb fd). Echoes
# the decimal offset; fails the calling leg if the count is not exactly 1, for
# the same reason loop_offset_a64 does: L1 reads "RIP == load + off + 1" as
# "the machine is parked on the stub's halt", and a second f4-eb-fd anywhere in
# the image would make that inference unsound SILENTLY.
#
# IT ALSO ASSERTS THE TWO BYTES IN FRONT OF IT ARE `ff d0` (`call *%rax`).
# That is not decoration — L1's no-return control OVERWRITES exactly those two
# bytes, and locating them by "two before the halt" instead of by a hardcoded
# offset is what keeps the control pointed at the call after the next edit to
# the stub. A mislocated patch would silently degrade the control into "some
# other two bytes changed and it stayed quiet".
halt_offset_x86() {
    python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
offs = [i for i in range(len(d) - 2) if d[i] == 0xF4 and d[i+1] == 0xEB and d[i+2] == 0xFD]
if len(offs) != 1:
    print("AMBIG:%d" % len(offs)); sys.exit(1)
o = offs[0]
if o < 2 or d[o-2] != 0xFF or d[o-1] != 0xD0:
    print("NOCALL:%s" % d[max(0, o-2):o].hex()); sys.exit(1)
print(o)
PY
}

# Echo the little-endian u32 at file offset $2 of image $1, in decimal.
# Used to read an emitted header's own fields off the artifact: L1 reads the
# multiboot header (which is what the `mb_` name records), and since
# sub-project C L6 reads the arm64 Image header's `code0` the same way. The
# body was never multiboot-specific; the name is kept because renaming it would
# churn L1's five call sites for nothing.
mb_u32() {
    python3 - "$1" "$2" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
o = int(sys.argv[2])
if o + 4 > len(d):
    print("SHORT"); sys.exit(1)
print(struct.unpack_from("<I", d, o)[0])
PY
}

# Copy $1 to $2, applying every spec from $3 onwards IN ORDER. A spec is one of:
#   u32:<off>:<val>              little-endian u32 at <off>
#   hex:<off>:<bytes>            raw hex at <off>
#   zero:<off>                   zero everything from <off> to EOF
#   zeron:<off>:<len>            zero exactly <len> bytes at <off>
#   u32was:<off>:<old>:<new>     u32, but only if <off> currently holds <old>
#   hexwas:<off>:<oldhex>:<new>  hex, but only if <off> currently holds <oldhex>
# Order matters and is used: L1's payload control zeroes to EOF and then plants
# a landing pad inside the zeroed region.
#
# `zeron` IS L9's, AND `zero` THERE IS A MISTAKE NOTHING WOULD CATCH. L1's
# artifact ends with its payload, so "zero to EOF" is exactly "zero the
# payload". L9's does not: a `--reset-vector` image is a FIXED 65536 bytes whose
# last 16 carry the RESET VECTOR, so `zero:<payoff>` erases the `jmp` the CPU
# fetches first, and all the fill between the payload and it, along with the
# payload.
# MEASURED, NOT REASONED, and the obvious prediction was wrong: substituting
# `zero:$payoff` for `zeron` leaves L9_control_zeroed_payload GREEN, because a
# zeroed reset jmp BOOTS NORMALLY (real-mode IP wraps within CS and re-enters
# the stage -- L9's header records the same trap for its own control). So the
# damage is not a false verdict, it is a FALSE CLAIM: the row would go on
# printing "payload [payoff,payoff+paylen) zeroed" while having zeroed the whole
# tail of the file, which is the class of mistake img_patch's `was` forms exist
# for one level down. The length is the compiler's published `paylen`, which is
# the reason that number is on the report line at all.
# Exits nonzero (and writes nothing) if an offset does not fit, so a control
# built on a mislocated patch site fails instead of quietly testing nothing.
#
# THE `was` FORMS EXIST BECAUSE "THE OFFSET FITS" IS NOT "THE OFFSET IS RIGHT"
# (D Task 3 review, Important 1). Every offset this file patches sits comfortably
# inside the file, so a mislocated constant writes real bytes into inert padding
# and img_patch reports success. A control whose EXPECTED VERDICT DIFFERS FROM
# THE PRISTINE ONE still reds when that happens -- the mutant behaves like the
# original, which is not what the row wanted -- but a control that expects the
# pristine verdict stays GREEN while printing a claim about a byte it never
# changed. That is measured, not hypothetical: mislocating UEFI_OFF_SECTCHARS to
# offset 6000 left L7_control_read_only_section_still_runs passing and asserting
# "the same byte change that makes the arm64 twin abort".
#
# Naming the OLD value turns a mislocated offset into a refusal, which
# uefi_control reports as "the control never ran". It is checked BEFORE any
# write in the same spec, and specs are applied in order, so a later spec sees
# the earlier one's result -- an expectation is about the file as it stands at
# that point, not about the pristine input.
img_patch() {
    python3 - "$@" <<'PY'
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
d = bytearray(open(src, "rb").read())
for spec in sys.argv[3:]:
    kind, rest = spec.split(":", 1)
    if kind == "zero":
        o = int(rest)
        if o >= len(d):
            sys.exit("img_patch: zero offset %d is past EOF (%d)" % (o, len(d)))
        for i in range(o, len(d)):
            d[i] = 0
    elif kind == "zeron":
        o, n = rest.split(":")
        o, n = int(o), int(n)
        if o < 0 or n < 0 or o + n > len(d):
            sys.exit("img_patch: zeron [%d,%d) does not fit in %d bytes" % (o, o + n, len(d)))
        for i in range(o, o + n):
            d[i] = 0
    elif kind == "u32":
        o, v = rest.split(":")
        o, v = int(o), int(v)
        if o + 4 > len(d):
            sys.exit("img_patch: u32 at %d does not fit in %d bytes" % (o, len(d)))
        struct.pack_into("<I", d, o, v & 0xFFFFFFFF)
    elif kind == "u32was":
        o, w, v = rest.split(":")
        o, w, v = int(o), int(w), int(v)
        if o + 4 > len(d):
            sys.exit("img_patch: u32was at %d does not fit in %d bytes" % (o, len(d)))
        cur = struct.unpack_from("<I", d, o)[0]
        if cur != (w & 0xFFFFFFFF):
            sys.exit("img_patch: u32was at %d expected %d, found %d -- the offset is "
                     "wrong, or the artifact changed; refusing to patch" % (o, w, cur))
        struct.pack_into("<I", d, o, v & 0xFFFFFFFF)
    elif kind == "hexwas":
        o, wh, h = rest.split(":")
        o, wb, b = int(o), bytes.fromhex(wh), bytes.fromhex(h)
        if len(wb) != len(b):
            sys.exit("img_patch: hexwas at %d: old is %d bytes, new is %d" % (o, len(wb), len(b)))
        if o + len(b) > len(d):
            sys.exit("img_patch: hexwas at %d does not fit in %d bytes" % (o, len(d)))
        if bytes(d[o:o+len(wb)]) != wb:
            sys.exit("img_patch: hexwas at %d expected %s, found %s -- the offset is "
                     "wrong, or the artifact changed; refusing to patch"
                     % (o, wh, bytes(d[o:o+len(wb)]).hex()))
        d[o:o+len(b)] = b
    elif kind == "hex":
        o, h = rest.split(":")
        o, b = int(o), bytes.fromhex(h)
        if o + len(b) > len(d):
            sys.exit("img_patch: %d hex bytes at %d do not fit in %d" % (len(b), o, len(d)))
        d[o:o+len(b)] = b
    else:
        sys.exit("img_patch: unknown spec %r" % spec)
open(dst, "wb").write(d)
PY
}

# File offset the x86 stub's `call *%rax` transfers to, i.e. the ENTRY FUNCTION
# — read out of the `movabs $entry,%rax` immediate and converted to a file
# offset with the image's load address ($2).
#
# LOCATED BY ANCHOR, NOT BY CONSTANT, and the anchor is the halt this file
# already locates: the trampoline's tail is `48 b8 <imm64> ff d0 f4 eb fd`, so
# the immediate sits at halt-10 and `48 b8` must be at halt-12. Both are
# asserted. A whole-file search for `48 b8` would false-hit any payload byte
# pair, and a hardcoded offset would be wrong by the next edit to the stub.
call_target_x86() {
    python3 - "$1" "$2" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
load = int(sys.argv[2])
offs = [i for i in range(len(d) - 2) if d[i] == 0xF4 and d[i+1] == 0xEB and d[i+2] == 0xFD]
if len(offs) != 1:
    print("AMBIG:%d" % len(offs)); sys.exit(1)
h = offs[0]
if h < 12 or d[h-12] != 0x48 or d[h-11] != 0xB8:
    print("NOMOVABS:%s" % d[max(0, h-12):h-10].hex()); sys.exit(1)
va = struct.unpack_from("<Q", d, h - 10)[0]
off = va - load
if off < 0 or off >= len(d):
    print("OUTSIDE:%d" % off); sys.exit(1)
print(off)
PY
}

# Echo $3 bytes of image $1 starting at file offset $2, as lower-case hex.
# Echoes SHORT (and exits nonzero) rather than a truncated string if the range
# runs past EOF, so a mislocated read cannot compare equal to nothing.
img_bytes() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
o, n = int(sys.argv[2]), int(sys.argv[3])
if o < 0 or o + n > len(d):
    print("SHORT"); sys.exit(1)
print(d[o:o+n].hex())
PY
}

# Multiboot header field offsets, from the emitting code (src/main.kr,
# emit_x86_image_stub) and re-read off the artifact by L1. MB_HEADER_SIZE is a
# fact about the FORMAT, not about this compiler: the AOUT-kludge header is
# eight u32s, so `entry_addr` must point one header past `header_addr`.
MB_MAGIC_OFF=0; MB_HEADER_ADDR_OFF=12; MB_LOAD_ADDR_OFF=16; MB_ENTRY_ADDR_OFF=28
MB_HEADER_SIZE=32
MB_MAGIC=464367618          # 0x1BADB002
# The trampoline's first two instructions, at the published entry: cli; cld.
X86_TRAMPOLINE_FIRST=fafc
# The stub's tail, past the code: a 3-quad GDT and the 10-byte GDTR the
# trampoline LGDTs. Both are INSIDE the stub and both are load-bearing at run
# time — see L1_control_zeroed_payload for what happens when they are not.
X86_GDT_BYTES=24; X86_GDTR_BYTES=10

# arm64 Linux `Image` header field offsets (sub-project C), from the emitting
# code in src/main.kr and from Documentation/arm64/booting.rst. Used by L6 to
# patch single fields of a REAL artifact — the same "one variable at a time"
# discipline L1 applies to the multiboot header.
#
# THE u64 FIELDS ARE PATCHED AS TWO u32s. img_patch has no u64 spec, and adding
# one to write two values this file needs is more surface than writing the low
# and high halves explicitly; every value L6 plants fits in 32 bits, so the
# high half is always `u32:<off>+4:0` and is written anyway rather than left
# alone, so a patch is a full field assignment and not a partial one.
# ONLY THE FIELDS L6 ACTUALLY PATCHES ARE DEFINED. text_offset (8) and flags
# (24) are measured in L6's header and named there, but no check here writes
# them, and a constant nothing uses is the same dead-entry rot as a probed-but-
# unused tool — it reads as coverage that does not exist.
A64H_CODE0_OFF=0; A64H_IMAGE_SIZE_OFF=16; A64H_MAGIC_OFF=56
A64H_SIZE=64
# 2 MiB. THE ALIGNMENT THE HEADER'S text_offset=0 BUYS — see L6's header for
# the measurement that establishes this is a header-derived property and not a
# constant of QEMU's.
A64_IMAGE_ALIGN=0x200000

# =============================================================================
# L0 — boot_run's DEAD-BOOT DETECTOR. This is not a subject leg; it is the gate
#      testing its own instrument, and it exists because eleven checks below
#      read SILENCE as evidence.
#
#      B1 SHIPPED L0 AS THE EXTERNAL LOADER'S SELF-TEST — it builds, its
#      `KR-LDR|` liveness sentinel is on the wire, a magic-corrupted build is
#      rejected, and the missing-assembler path fails loudly. B2 Task 4 made
#      the compiler emit its own multiboot header and trampoline, so there is
#      no loader to build: all four of those checks are RETIRED, named
#      individually in this task's report. The corrupt-magic idea is not lost —
#      it survives re-pointed at the EMITTED header, as L1's
#      `L1_no_header_image_refused`, where a no-`--stack-top` image (no header
#      at all) must be refused by `qemu -kernel`.
#
#      WHAT REPLACES THEM IS THE THING THE LOADER'S SENTINEL WAS ACTUALLY DOING
#      FOR THE GATE: proving a guest ran. Every x86 silence control used to
#      require `KR-LDR|` on the wire, which is real liveness evidence — and
#      that sentinel belonged to the loader. Under `-kernel <image>` nothing
#      prints before the payload, so the shield is gone and the exit-status
#      rule in boot_run's header is what stands in its place, on BOTH arches.
#
#      THESE THREE CHECKS ARE THAT RULE'S OWN NEGATIVE AND POSITIVE CONTROLS,
#      permanently, rather than a mutation someone ran once:
#        * the two dead-boot checks assert boot_run reports FAILURE for a boot
#          qemu refused — AND that the capture file is PRESENT, i.e. that the
#          pre-Task-5 predicate would have said "the boot ran". If a future
#          qemu ever stopped creating the capture, the checks would go green
#          for the wrong reason, so that half is asserted too and named.
#        * the liveboot check asserts boot_run does NOT flag a boot that really
#          ran. Without it "return 1 always" satisfies both dead-boot checks.
# =============================================================================
leg0() {
    echo "--- L0: boot_run's dead-boot detector (the I1 rule, gated) ---"
    local gone="$WORK/this_image_does_not_exist.img"
    rm -f "$gone"
    # x86: qemu exits 1 with "could not open kernel file" before any guest
    # instruction runs. SELFEXIT, not RUNOUT — qemu is gone in milliseconds.
    if boot_run x86 "$WORK/l0_dead_x86.txt" SELFEXIT -kernel "$gone"; then
        bad "L0_deadboot_x86" "boot_run called it a boot; qemu exit=$BOOT_QEMU_RC"
    elif [ ! -f "$WORK/l0_dead_x86.txt" ]; then
        bad "L0_deadboot_x86" "the capture file is ABSENT, so this control no longer exercises the defect it exists for (qemu used to create it before failing)"
    else
        ok "L0_deadboot_x86" "qemu exit $BOOT_QEMU_RC, capture PRESENT at $(stat -c%s "$WORK/l0_dead_x86.txt") B — a silence-only predicate would have passed"
    fi
    # arm64: same shape through -device loader,file=, which is how every arm64
    # leg puts its image in memory.
    if boot_run a64 "$WORK/l0_dead_a64.txt" SELFEXIT \
           -device loader,file="$gone",addr=$A64_LOAD,force-raw=on; then
        bad "L0_deadboot_a64" "boot_run called it a boot; qemu exit=$BOOT_QEMU_RC"
    elif [ ! -f "$WORK/l0_dead_a64.txt" ]; then
        bad "L0_deadboot_a64" "the capture file is ABSENT, so this control no longer exercises the defect it exists for"
    else
        ok "L0_deadboot_a64" "qemu exit $BOOT_QEMU_RC, capture PRESENT at $(stat -c%s "$WORK/l0_dead_a64.txt") B — a silence-only predicate would have passed"
    fi
    # Non-vacuity. Bare machines, no image: the guest runs (whatever the reset
    # vector holds) and qemu exits 0 when killed. boot_run must say "ran".
    # Measured on both: exit 0, capture present, empty.
    local lx=1 la=1
    boot_run x86 "$WORK/l0_live_x86.txt" RUNOUT && lx=0
    boot_run a64 "$WORK/l0_live_a64.txt" RUNOUT && la=0
    if [ "$lx" = 0 ] && [ "$la" = 0 ]; then
        ok "L0_liveboot_not_flagged" "both bare machines reported as boots — the detector is not 'always fail'"
    else
        bad "L0_liveboot_not_flagged" "x86 ok=$lx a64 ok=$la (a boot that RAN was reported as dead; every positive leg below is now unreachable)"
    fi
    # THE DISCRIMINATOR IS `== 1`, NOT `!= 0`, AND THIS IS THE ONLY THING THAT
    # HOLDS IT THERE. The two checks above pin the two ends boot_run cares
    # about — a refused boot (qemu's own exit 1) and a boot that ran (0) — and
    # BOTH of them stay green under `!= 0`. The third status is `timeout`'s own
    # 124, which means "the guest was still running when the alarm fired": a
    # boot that RAN, and the case a `!= 0` regression would report as dead. The
    # consequence is measured, not argued — Task 5 shipped `!= 0` and three
    # positive legs false-failed on it.
    #
    # WHY THIS IS NOT A FLAKINESS SOURCE, which is the objection that kept it
    # queued. The obvious construction — run a real leg past the full 10 s
    # deadline — races the harness against the alarm and costs 10 s. This one
    # inverts the race instead of running it: the alarm is turned down to 1 s
    # while boot_wait's own window is opened to 10 s, so `timeout` ALWAYS wins,
    # by a factor of ten, on any machine. The guest only has to still be alive
    # after one second, and this is the same bare machine L0_liveboot_not_flagged
    # just watched survive its own two-second window. Nothing here depends on
    # how fast the runner is; a slower one makes the guest MORE likely to
    # outlive the alarm, not less.
    #
    # BOTH HALVES ARE ASSERTED. `boot_run returned 0` is the claim; `rc == 124`
    # is what keeps the claim from going vacuous — if the alarm ever stops
    # firing (a `timeout` that behaves differently, a guest that self-exits
    # inside a second) the status would be 0, boot_run would return 0 for a
    # different reason, and this control would pass while testing nothing.
    #
    # WHAT IT DOES NOT COVER, stated rather than left to be discovered:
    # boot_run_qmp carries the SAME `!= 1` literal against its own `timeout 15`
    # and is not exercised here. Its alarm is not on a variable, and reaching
    # it would mean standing up a QMP session purely to be killed. The two
    # copies are one rule spelled twice, so a regression that edits one would
    # almost certainly edit both and this check would see it — "almost
    # certainly" being exactly as strong as that argument is.
    local sv_timeout="$BOOT_TIMEOUT" sv_silence="$BOOT_SILENCE_TICKS"
    BOOT_TIMEOUT=1
    BOOT_SILENCE_TICKS=200        # 10 s — the harness must OUTLAST the alarm
    local alarm_ok=1
    boot_run x86 "$WORK/l0_alarm.txt" RUNOUT && alarm_ok=0
    local alarm_rc="$BOOT_QEMU_RC"
    BOOT_TIMEOUT="$sv_timeout"; BOOT_SILENCE_TICKS="$sv_silence"
    if [ "$alarm_rc" != 124 ]; then
        bad "L0_alarm_not_a_dead_boot" "the 1 s alarm did not fire (qemu exit=$alarm_rc, not 124) — this control did not exercise the 124 path at all, so it proves nothing about == 1 vs != 0"
    elif [ "$alarm_ok" != 0 ]; then
        bad "L0_alarm_not_a_dead_boot" "timeout's own 124 was read as a refused boot — the discriminator has regressed from '== 1' to '!= 0', and every leg whose guest outlives the deadline now false-fails"
    else
        ok "L0_alarm_not_a_dead_boot" "qemu exit 124 (the alarm), reported as a boot — '!= 0' would have called it dead"
    fi
}

# =============================================================================
# L1 — x86_64 SELF-BOOT. `qemu-system-x86_64 -kernel <image>` and nothing else:
#      no loader ELF, no `-device loader`, no assembler, no load address and no
#      entry offset on the command line. The artifact carries all of it in the
#      multiboot header the compiler emits (B2 Task 4). This leg IS the x86
#      self-sufficiency leg — the plan's Step 4 asked for one, and MOVING L1
#      onto the emitted form rather than adding a sixth leg beside it is the
#      point: the old form's checks would otherwise have gone on passing until
#      Task 6 deleted boot.S out from under them.
#
#      WHAT WAS RETIRED FROM B1's L1, AND WHY — each re-observed, none assumed:
#
#      * `L1_control_no_image` (loader alone, no image => loader sentinel only,
#        program sentinel impossible). NOT CONSTRUCTIBLE: there is no loader to
#        run alone. Its job — "the sentinel cannot come from whatever boots the
#        program" — is done here by `L1_control_zeroed_payload`, which is
#        strictly sharper: same stub, same command, payload zeroed and a halt
#        planted at the address the stub calls, so the guest PARKS THERE — which
#        is positive proof the trampoline built its page tables, loaded its GDT
#        and entered long mode before finding nothing to run.
#
#      * `L1_control_offset0`. RETIRED BECAUSE IT INVERTS, and this was
#        measured, not predicted. Under the emitted form file offset 0 is the
#        MULTIBOOT HEADER. Its bytes decode as harmless 32-bit instructions
#        (`02 b0 ad 1b …` = add dh,[eax+0x1bad] …) that neither fault nor
#        branch, so control FALLS THROUGH into the trampoline at offset 32.
#        Observed: entering at load+0 PRINTS `2000000016`. A silence control
#        that prints is not a weak control, it is a red leg, and re-pointing it
#        at some other offset would only be picking an address that happens to
#        be quiet today.
#
#      * `L1_control_entry_minus4`. NOT CONSTRUCTIBLE, and it inverts for the
#        same reason. `-kernel` enters at the header's `entry_addr`; there is
#        no command-line entry to shift. Patching `entry_addr` to load+entry-4
#        is the closest reconstruction and it lands at file offset 28 — inside
#        the header — which likewise falls through into the trampoline and
#        PRINTS (observed).
#
#      WHAT REPLACES entry-4 AS THE REPORT-ACCURACY CHECK. B1 needed those two
#      controls because a flat image has no e_entry and the reported `entry`
#      was therefore uncheckable against the artifact. THAT IS NO LONGER TRUE
#      ON x86: the emitted multiboot header carries `entry_addr`, and QEMU
#      jumps to it. So the report is cross-checked against the artifact
#      directly (`L1_multiboot_header`), and two runtime legs make that
#      cross-check load-bearing rather than a fact about two numbers:
#        * `L1_control_entry_addr_honoured` moves `entry_addr` — ONE u32, no
#          other byte changed — to the stub's own halt. The boot goes silent
#          and parks THERE. If QEMU ignored the field this run would print, so
#          silence here is what proves the field steers the boot. The parked
#          register is EIP, not RIP: entering past the trampoline means long
#          mode is never entered (observed EIP=004000b1, CS32, HLT=1), which
#          is a second, independent witness that the jump really did skip it.
#          qmp_pc.py was taught EIP for this leg; with RIP only it returned
#          QMPFAIL, which is indistinguishable from a broken QMP path.
#        * `L1_no_header_image_refused` builds the same source with no
#          `--stack-top`, hence no header at all, and QEMU refuses it.
#
#      THE SENTINEL IS COMPUTED, not echoed: `2000000016` is `2000000007`
#      (a static written in main) plus 9 (returned from a call), formatted at
#      runtime. Verified on the artifacts: `strings -a` over sx.img and sa.img
#      finds ZERO occurrences of either digit string, so the wire cannot be
#      carrying a copied literal. (B1 checked the external loader ELF here
#      too; there is no third artifact to check since Task 4 — the two images
#      ARE the whole command line now.)
#
#      D5, THE RETURN-TO-HALT: `L1_halt_parked`. After `main` returns, the
#      trampoline's `call *%rax` falls into `hlt; jmp .`, so RIP must PARK on
#      that address — read over QMP exactly as L3 reads the arm64 one.
#      Continued silence cannot tell "halted correctly" from "faulted", which
#      is why the address is asserted and not the quiet.
# =============================================================================
leg1() {
    echo "--- L1: x86_64 self-boot (-kernel <image>, nothing else) ---"
    cp "$BOOT/sentinel_x86.kr" "$WORK/sentinel_x86.kr"
    local entry img="$WORK/sx.img"
    if ! entry=$(build_image x86 "$WORK/sentinel_x86.kr" "$img" "$X86_STACK_TOP"); then
        bad "L1_compile" "sentinel_x86.kr did not compile with --stack-top=$X86_STACK_TOP"; return
    fi
    # ---- BLOCKING, AND BEFORE THE RUNTIME PAIRS ON PURPOSE -----------------
    # B1 measured that appending a blocking assertion after a runtime pair
    # turns it into a SKIP the moment the runtime half fails. These two depend
    # on nothing a boot produces, so they run first and a red run still reports
    # the leg's primary static claim.
    # WHAT THIS CHECK DOES AND DOES NOT COVER, stated exactly, because an
    # earlier version of this comment claimed independence the code did not
    # have (review I2).
    #
    # THE REPORT-vs-entry_addr CLAUSE IS A TAUTOLOGY WITH RESPECT TO THE
    # COMPILER. Both numbers are the SAME variable: `xs_start32` in
    # emit_x86_image_stub feeds `patch_u32(xs_hdr_entry, ld + xs_start32)`
    # (src/main.kr:2537) AND `x86stub_start32_off` -> `img_stub_off` ->
    # `entry_off` (:2403, :3119, :3586), which is what the `image:` line
    # prints. They cannot disagree, so on its own this clause catches a
    # spelling or parsing mistake in THIS SCRIPT and nothing about the
    # compiler. Demonstrated: publishing the entry two bytes late — skipping
    # `cli; cld` — leaves it green.
    #
    # WHAT ACTUALLY BITES IS THE FORMAT ANCHOR, and it is derived from the
    # ARTIFACT rather than from that variable:
    #   * a multiboot header is 32 bytes and `header_addr` says where it is,
    #     so the trampoline must start at exactly `header_addr + 32` — no
    #     hardcoded 32-as-an-entry-offset, and no compiler value on the
    #     right-hand side;
    #   * the two bytes AT the published entry must be `fa fc` (`cli; cld`),
    #     the trampoline's first instructions, read out of the image.
    # A published entry that drifts by any amount reds both: the arithmetic
    # first, and the opcode check second with the bytes it actually found.
    #
    # mb_u32 answers in DECIMAL and $X86_LOAD is written in hex, so every
    # comparison below is against $(( X86_LOAD )) — a `=` between "4194304"
    # and "0x400000" is false for two spellings of the same address, which is
    # a false FAIL, and the mirror-image mistake would be a false pass.
    local mb_magic mb_hdr mb_load mb_entry halt want_entry want_load
    local want_start entry_bytes
    mb_magic=$(mb_u32 "$img" $MB_MAGIC_OFF)
    mb_hdr=$(mb_u32 "$img" $MB_HEADER_ADDR_OFF)
    mb_load=$(mb_u32 "$img" $MB_LOAD_ADDR_OFF)
    mb_entry=$(mb_u32 "$img" $MB_ENTRY_ADDR_OFF)
    want_load=$(( X86_LOAD ))
    want_entry=$(( X86_LOAD + entry ))
    want_start=$(( mb_hdr + MB_HEADER_SIZE ))
    entry_bytes=$(img_bytes "$img" $(( mb_entry - want_load )) 2)
    if [ "$mb_magic" = "$MB_MAGIC" ] && [ "$mb_hdr" = "$want_load" ] \
       && [ "$mb_load" = "$want_load" ] && [ "$mb_entry" = "$want_entry" ] \
       && [ "$mb_entry" = "$want_start" ] && [ "$entry_bytes" = "$X86_TRAMPOLINE_FIRST" ]; then
        ok "L1_multiboot_header" "magic at offset 0, header_addr=load_addr=$want_load, entry_addr=$mb_entry == header_addr + $MB_HEADER_SIZE and holds $entry_bytes (cli; cld); the report's entry ($entry) agrees, though that clause shares xs_start32 and is not independent"
    else
        bad "L1_multiboot_header" "magic=$mb_magic (want $MB_MAGIC) header_addr=$mb_hdr load_addr=$mb_load (want $want_load) entry_addr=$mb_entry (want $want_entry = $want_load + reported $entry; and want $want_start = header_addr + $MB_HEADER_SIZE) bytes-at-entry=$entry_bytes (want $X86_TRAMPOLINE_FIRST = cli; cld)"
    fi
    # The halt is located, not written down, and its uniqueness is asserted —
    # `L1_halt_parked` reads RIP == load + halt + 1 as "parked on the stub's
    # halt", and a second f4-eb-fd would make that unsound without a symptom.
    if ! halt=$(halt_offset_x86 "$img"); then
        bad "L1_halt_parked" "cannot locate a unique 'hlt; jmp .' preceded by 'call *%rax': $halt"; return
    fi
    # Control for the header being what makes the image bootable AT ALL: the
    # same source without --stack-top emits no stub and therefore no header,
    # and qemu -kernel must refuse it. This is also a second, independent
    # exercise of boot_run's dead-boot rule (L0) on a REAL artifact rather
    # than a missing file.
    if ! build_image x86 "$WORK/sentinel_x86.kr" "$WORK/sx_noflag.img" >/dev/null; then
        bad "L1_no_header_image_refused" "the no-flag build failed — control never ran"
    elif boot_run x86 "$WORK/l1_nohdr.txt" SELFEXIT -kernel "$WORK/sx_noflag.img"; then
        bad "L1_no_header_image_refused" "qemu accepted a headerless image (exit=$BOOT_QEMU_RC): '$(head -c 120 "$WORK/l1_nohdr.txt.err")'"
    else
        ok "L1_no_header_image_refused" "no --stack-top => no multiboot header => qemu exit $BOOT_QEMU_RC: '$(head -c 60 "$WORK/l1_nohdr.txt.err")'"
    fi
    # ---- the subject, and D5 --------------------------------------------
    local want_pc
    want_pc=$(printf %x $(( X86_LOAD + halt + 1 )))
    if ! x86_boot_qmp "$img" "$WORK/l1_ser.txt" "2000000016"; then
        bad "L1_self_boot_sentinel" "the boot did not run (qemu exit=$BOOT_QEMU_RC): '$(head -c 120 "$WORK/l1_ser.txt.err")'"
        bad "L1_halt_parked" "no boot to read a PC from"; return
    fi
    if grep -q "2000000016" "$WORK/l1_ser.txt"; then
        ok "L1_self_boot_sentinel" "computed 2000000016 on COM1 from '-kernel $(basename "$img")' alone — no loader file (${BOOT_WAITED_TICKS} ticks)"
    else
        bad "L1_self_boot_sentinel" "serial held: '$(tr '\n' ' ' <"$WORK/l1_ser.txt")'"
    fi
    if [ "$PARKED_PC" = "$want_pc" ]; then
        ok "L1_halt_parked" "RIP parked at 0x$want_pc == load + $halt + 1, the stub's own 'hlt; jmp .' — so main RETURNED into it (D5)"
    else
        bad "L1_halt_parked" "pc=$PARKED_PC want=$want_pc"
    fi
    # Every control below asserts ABSENCE, so its window must be long enough
    # that a working boot would certainly have printed by now. Derived from the
    # positive boot just observed rather than guessed — see calibrate_silence.
    calibrate_silence
    # Control: entry_addr is what QEMU jumps to. ONE u32 changed, pointed at
    # the halt this leg just proved the address of. Silence proves the field
    # steered the boot (entering anywhere in the header or the trampoline
    # PRINTS — measured), and the parked RIP is positive evidence of where it
    # went rather than an inference from the quiet.
    if ! img_patch "$img" "$WORK/sx_ea.img" "u32:$MB_ENTRY_ADDR_OFF:$(( X86_LOAD + halt ))"; then
        bad "L1_control_entry_addr_honoured" "could not patch entry_addr — control never ran"
    elif ! x86_boot_qmp "$WORK/sx_ea.img" "$WORK/l1_ea.txt" RUNOUT; then
        bad "L1_control_entry_addr_honoured" "the boot did not run (qemu exit=$BOOT_QEMU_RC) — silence proves nothing"
    elif grep -q "2000000016" "$WORK/l1_ea.txt"; then
        bad "L1_control_entry_addr_honoured" "sentinel printed with entry_addr pointing at the halt — qemu is NOT using the field, so L1_multiboot_header is not load-bearing"
    elif [ "$PARKED_PC" != "$want_pc" ]; then
        bad "L1_control_entry_addr_honoured" "silent, but pc=$PARKED_PC is not the halt at 0x$want_pc — where it actually went is unaccounted for"
    else
        ok "L1_control_entry_addr_honoured" "entry_addr -> the halt: no sentinel, parked at 0x$PARKED_PC (32-bit mode — the trampoline was skipped, so the field steers the boot)"
    fi
    # Control: main must RETURN for the halt to be reached. Two bytes of the
    # artifact — the `call *%rax` that `halt_offset_x86` located and asserted —
    # become `jmp .`, so the machine parks THREE BYTES EARLIER, at a known,
    # stationary address that is not the halt. This is what makes the PC in
    # L1_halt_parked discriminating: drop that assertion and "boots, prints,
    # then goes quiet" would pass for a machine parked anywhere.
    local no_ret_pc
    no_ret_pc=$(printf %x $(( X86_LOAD + halt - 2 )))
    if ! img_patch "$img" "$WORK/sx_nr.img" "hex:$(( halt - 2 )):ebfe"; then
        bad "L1_control_no_return" "could not patch the call site — control never ran"
    elif ! x86_boot_qmp "$WORK/sx_nr.img" "$WORK/l1_nr.txt" RUNOUT; then
        bad "L1_control_no_return" "the boot did not run (qemu exit=$BOOT_QEMU_RC) — silence proves nothing"
    elif grep -q "2000000016" "$WORK/l1_nr.txt"; then
        bad "L1_control_no_return" "sentinel printed with the call to main replaced by 'jmp .'"
    elif [ "$PARKED_PC" != "$no_ret_pc" ]; then
        bad "L1_control_no_return" "pc=$PARKED_PC, want 0x$no_ret_pc (the patched call site)"
    else
        ok "L1_control_no_return" "call *%rax -> jmp .: no sentinel and RIP parks at 0x$no_ret_pc, 3 bytes short of the halt — the halt address discriminates"
    fi
    # Control: the sentinel comes from KernRift's compiled code, not the stub.
    # The whole payload is zeroed and a `hlt; jmp .` landing pad is planted at
    # the address the stub's `call *%rax` transfers to. The guest must then
    # PARK ON THAT PAD with nothing on the wire.
    #
    # THE STUB DOES NOT END AT THE HALT — that was this control's defect
    # (review I1). `halt + 3` is the end of the CODE; the stub continues with
    # `.align 16` padding, a 3-quad GDT and a 10-byte GDTR, and the trampoline
    # LGDTs that table on its way to long mode. Zeroing from 179 destroys the
    # descriptor tables and the guest TRIPLE-FAULTS INSIDE THE STUB, never
    # reaching the payload at all — and the old form passed on exactly that.
    # The end is DERIVED, not written down: align the code end to 16 (what the
    # emitter's `while (out_len & 15)` loop does), then the GDT and the GDTR.
    #
    # WHY A LANDING PAD RATHER THAN "IS THE GUEST STILL ALIVE". Because a guest
    # executing zeroes is not a stable observable and MUST NOT be one this gate
    # depends on. Zeroes decode as `add %al,(%rax)`, which is SELF-MODIFYING at
    # the address it is executing, so the walk is chaotic. Observed on one
    # image, one command line: across twelve runs a single survivor reached the
    # full 2 s window in long mode at RIP 0x7453e8, while the other eleven died
    # inside ~100 ms — and that survivor COULD NOT BE REPRODUCED in 40 further
    # runs of the same image and command line, which got 0. So this is one
    # observation, not a measured rate, and the number of runs it would take to
    # see another is unknown. Task 4's CS64/EFER observation is that survivor.
    # A liveness assertion built on it would have been a gate that is red
    # almost always and green on nobody's schedule — and stating the rate as
    # "one in twelve" would itself have been a correction that was wrong, which
    # is the recurring failure of this sub-project. Note that 0/40 makes the
    # conclusion STRONGER, not weaker: the less reproducible the survival, the
    # less admissible it is as an observable. The landing pad makes the same
    # claim DETERMINISTICALLY:
    # 5/5 runs park at load + <call target> + 1, and with the GDT destroyed
    # (the review-I1 form) 3/3 give QMPFAIL because qemu is already gone.
    #
    # WHAT PARKING THERE PROVES, and it is more than silence did: the
    # trampoline built its page tables, LGDT'd the GDT this control kept,
    # ljmp'd into long mode, set RSP and transferred to the address its
    # `movabs` carries. Every one of those is required to reach the pad.
    local stub_end=$(( ((halt + 3 + 15) / 16) * 16 + X86_GDT_BYTES + X86_GDTR_BYTES ))
    local calltgt pad_pc
    if ! calltgt=$(call_target_x86 "$img" $(( X86_LOAD ))); then
        bad "L1_control_zeroed_payload" "cannot read the call target out of the movabs: $calltgt"; return
    fi
    pad_pc=$(printf %x $(( X86_LOAD + calltgt + 1 )))
    if ! img_patch "$img" "$WORK/sx_zero.img" "zero:$stub_end" "hex:$calltgt:f4ebfd"; then
        bad "L1_control_zeroed_payload" "could not build the zeroed image — control never ran"
    elif ! x86_boot_qmp "$WORK/sx_zero.img" "$WORK/l1_zero.txt" RUNOUT; then
        bad "L1_control_zeroed_payload" "the boot did not run (qemu exit=$BOOT_QEMU_RC) — silence proves nothing"
    elif grep -q "2000000016" "$WORK/l1_zero.txt"; then
        bad "L1_control_zeroed_payload" "sentinel printed from an image whose payload is all zeroes"
    elif [ "$PARKED_PC" != "$pad_pc" ]; then
        bad "L1_control_zeroed_payload" "pc=$PARKED_PC, want 0x$pad_pc (the pad at the call target, file offset $calltgt) — the guest never reached the payload, so its silence says nothing about where the sentinel comes from. Stub kept through offset $stub_end."
    else
        ok "L1_control_zeroed_payload" "stub kept through the GDTR (offset $stub_end), payload zeroed, pad at the call target (offset $calltgt): parked at 0x$pad_pc with no sentinel"
    fi
}

# =============================================================================
# L2 — arm64 SELF-BOOT. The compiler's own emitted stub (B2 Task 3) sets SP,
#      `bl`s the entry and halts, so the only FILE on the command line is the
#      artifact under test. `make_stub.py` is NOT invoked by this leg — the
#      second `-device loader` carries an ADDRESS ONLY and merely parks the
#      reset PC on the emitted stub, which is the arm64 equivalent of QEMU
#      reading `entry_addr` out of x86's multiboot header.
#
#      This is the arm64 self-sufficiency leg, and like L1 it REPLACES the
#      external-stub form rather than sitting beside it. B1's L2 booted the
#      same image with a 4-instruction stub loaded at $A64_STUB; that stub is
#      exactly what Task 3 moved into the compiler.
#
#      RETIRED FROM B1's L2: `L2_control_no_image` (stub file, no image =>
#      silence). Not constructible without an external stub, and its job is
#      done strictly better by `L2_control_no_stub`: the SAME source built
#      WITHOUT --stack-top, so no stub is emitted, entered at its own reported
#      entry. That is one variable — is there a stub — instead of two, and it
#      is Task 3's own control A.
#
#      SILENCE IS NEVER THE WHOLE OF A CONTROL HERE. arm64 has no pre-payload
#      liveness sentinel of any kind, so ALL THREE quiet controls read the PC
#      over QMP as well — `L2_control_no_stub`, `L2_control_offset0` and
#      `L2_control_entry_minus4`, every one of them through
#      `a64_self_boot_qmp`. They park at 0x200, the exception vector, which is
#      POSITIVE evidence that the guest executed and faulted on the garbage SP
#      rather than never having started. Combined with boot_run's exit-status
#      rule (L0), "quiet" has two independent witnesses behind it. (Two of the
#      three asserted silence ALONE when this header was first written, so the
#      0x200 fact was still living in a report rather than in the gate — review
#      I3. If a control here is ever moved back to `a64_self_boot`, this
#      paragraph becomes false again.)
#
#      REPORT ACCURACY IS STILL THESE CONTROLS' JOB ON THIS ARCH, unlike x86.
#      An arm64 image without `--image-header` -- which is every image this
#      leg builds -- has no header and no e_entry, so `entry` is a number the
#      compiler printed with nothing on the artifact to check it against.
#      (With the flag there IS something on the artifact -- the header's own
#      branch, which is what L6 tests. That is a fact about L6's images, not
#      about this leg's.)
#      The subject (enter at the reported entry, must print) plus offset 0 and
#      entry-4 either side of it (must not) are jointly what makes the report
#      load-bearing. Both re-observed under the EMITTED stub, not inherited:
#      with the stub the reported entry is 956 where the entry function is at
#      620, so entry-4 is now the last word of the PRECEDING function rather
#      than the entry function's own tail — measured silent, PC 0x200.
#
#      OFFSET 0 IS ASSERTED NOT TO BE THE ENTRY, AND THAT ASSERTION IS THE
#      POINT OF `L2_entry_is_not_offset0`. The control assumes offset 0 is not
#      where the program starts, and that assumption holds for a reason that
#      can change without warning: the entry is usually the FIRST live
#      top-level function, so a source reorder — or a decision to PREPEND the
#      stub the way x86 must — would silently invert the control into a
#      duplicate of the subject. x86's twin already inverted for exactly this
#      class of reason (see L1's header), so it is checked rather than trusted.
#      Position independence is what makes the 0x40400000 load address legal:
#      every static access in the arm64 output is `adrp x16, …` + a fixed
#      displacement and every call is PC-relative (18 adrp, zero absolute
#      addresses in the disassembly). Offset 0 is `pl011_reg_write`
#      (std/uart_pl011.kr's first helper) — `sub sp,…`, an `adrp` load of the
#      PL011 base, `str w20,[x19]` through a garbage x0/x1 pair, then `ret` to
#      an x30 the reset never set. No formatted digits can come out of it.
#
#      D5, THE RETURN-TO-HALT: `L2_halt_parked`. The stub's fifth word is
#      `b .`, so after `main` returns the PC must PARK on it. The address is
#      not written down — it is the UNIQUE 0x14000000 in the image, found by
#      the same `loop_offset_a64` L3 uses, and cross-checked against
#      `entry + 16` so that a stub whose halt moved cannot pass by accident.
# =============================================================================
leg2() {
    echo "--- L2: arm64 self-boot (no stub file) + computed sentinel ---"
    cp "$BOOT/sentinel_a64.kr" "$WORK/sentinel_a64.kr"
    local entry img="$WORK/sa.img"
    if ! entry=$(build_image a64 "$WORK/sentinel_a64.kr" "$img" "$A64_STACK_TOP"); then
        bad "L2_compile" "sentinel_a64.kr did not compile with --stack-top=$A64_STACK_TOP"; return
    fi
    # ---- BLOCKING, BEFORE THE RUNTIME PAIRS (see L1's note on ordering) ----
    if [ "$entry" != 0 ]; then
        ok "L2_entry_is_not_offset0" "reported entry $entry != 0, so the offset-0 control is testing a DIFFERENT address from the subject"
    else
        bad "L2_entry_is_not_offset0" "the reported entry IS file offset 0 — L2_control_offset0 would silently become a duplicate of the subject and stop discriminating"
    fi
    local halt want_pc
    if ! halt=$(loop_offset_a64 "$img"); then
        bad "L2_halt_parked" "self-branch count: $halt"; return
    fi
    if [ "$halt" != $(( entry + 16 )) ]; then
        bad "L2_halt_parked" "the unique 'b .' is at $halt, but the stub's halt must be at entry + 16 = $(( entry + 16 ))"; return
    fi
    want_pc=$(printf %x $(( A64_LOAD + halt )))
    # ---- the subject, and D5 ----------------------------------------------
    if ! a64_self_boot_qmp "$A64_LOAD" "$img" "$entry" "$WORK/l2_ser.txt" "1000000016"; then
        bad "L2_self_boot_sentinel" "the boot did not run (qemu exit=$BOOT_QEMU_RC): '$(head -c 120 "$WORK/l2_ser.txt.err")'"
        bad "L2_halt_parked" "no boot to read a PC from"; return
    fi
    if grep -q "1000000016" "$WORK/l2_ser.txt"; then
        ok "L2_self_boot_sentinel" "computed 1000000016 on the PL011 with NO stub file loaded (${BOOT_WAITED_TICKS} ticks)"
    else
        bad "L2_self_boot_sentinel" "serial held: '$(tr '\n' ' ' <"$WORK/l2_ser.txt")'"
    fi
    if [ "$PARKED_PC" = "$want_pc" ]; then
        ok "L2_halt_parked" "PC parked at 0x$want_pc == load + entry + 16, the stub's own 'b .' — so main RETURNED into it (D5)"
    else
        bad "L2_halt_parked" "pc=$PARKED_PC want=$want_pc"
    fi
    # Absence windows derived from the arm64 positive boot just observed —
    # separately from L1's, because the two arches do not run at the same speed.
    calibrate_silence
    # Control: no stub. Same source, no --stack-top, entered at ITS OWN
    # reported entry — one variable. Silence AND a parked PC that is not the
    # halt: 0x200 is the exception vector, i.e. the guest ran and faulted on
    # the SP the stub would have set. This is also what makes L2_halt_parked's
    # address assertion discriminating; drop it and "quiet after the sentinel"
    # passes for any fault.
    local e0
    if ! e0=$(build_image a64 "$WORK/sentinel_a64.kr" "$WORK/sa_noflag.img"); then
        bad "L2_control_no_stub" "the no-flag build failed — control never ran"
    elif ! a64_self_boot_qmp "$A64_LOAD" "$WORK/sa_noflag.img" "$e0" "$WORK/l2_nostub.txt" RUNOUT; then
        bad "L2_control_no_stub" "the boot did not run (qemu exit=$BOOT_QEMU_RC) — silence proves nothing"
    elif grep -q "1000000016" "$WORK/l2_nostub.txt"; then
        bad "L2_control_no_stub" "sentinel printed from an image with no emitted stub"
    else
        # SHAPE-CHECK BEFORE THE `!=`. QMPFAIL and MOVING:* both satisfy it
        # vacuously, so without this the control goes green precisely when the
        # discriminator is broken (review round 1, I5).
        case "$PARKED_PC" in
            "" | *[!0-9a-f]*)
                bad "L2_control_no_stub" "no parked PC (PARKED_PC='$PARKED_PC') — the discriminator never ran" ;;
            "$want_pc")
                bad "L2_control_no_stub" "parked at the halt 0x$want_pc with no stub emitted" ;;
            *)
                ok "L2_control_no_stub" "no --stack-top => entry $e0 is the FUNCTION: no sentinel, parked at 0x$PARKED_PC (not the halt 0x$want_pc)" ;;
        esac
    fi
    # Controls: offset 0 and entry-4 must not print. Both re-observed under the
    # EMITTED stub (PC 0x200 in each case), not carried over from B1. They are
    # what makes the reported `entry` load-bearing on an artifact that has no
    # header to check it against -- which every image built here is, the flag
    # being absent from all of leg2's builds.
    # BOTH READ THE PC, and that is review I3: they used to assert silence
    # alone while this leg's header claimed otherwise, so their 0x200 evidence
    # lived only in a report — the exact debt Task 5 exists to retire. The
    # shape-check comes first for the reason B1's I5 records: QMPFAIL and
    # MOVING:* satisfy a `!=` vacuously, so without it the control goes green
    # precisely when the discriminator is broken.
    if ! a64_self_boot_qmp "$A64_LOAD" "$img" 0 "$WORK/l2_off0.txt" RUNOUT; then
        bad "L2_control_offset0" "the boot did not run (qemu exit=$BOOT_QEMU_RC) — silence proves nothing"
    elif grep -q "1000000016" "$WORK/l2_off0.txt"; then
        bad "L2_control_offset0" "sentinel printed from offset 0"
    else
        case "$PARKED_PC" in
            "" | *[!0-9a-f]*)
                bad "L2_control_offset0" "no parked PC (PARKED_PC='$PARKED_PC') — the discriminator never ran" ;;
            "$want_pc")
                bad "L2_control_offset0" "parked at the halt 0x$want_pc having entered at offset 0" ;;
            *)
                ok "L2_control_offset0" "offset 0 => no sentinel, parked at 0x$PARKED_PC (not the halt 0x$want_pc) — the guest RAN and faulted" ;;
        esac
    fi
    if ! a64_self_boot_qmp "$A64_LOAD" "$img" $(( entry - 4 )) "$WORK/l2_offm.txt" RUNOUT; then
        bad "L2_control_entry_minus4" "the boot did not run (qemu exit=$BOOT_QEMU_RC) — silence proves nothing"
    elif grep -q "1000000016" "$WORK/l2_offm.txt"; then
        bad "L2_control_entry_minus4" "sentinel printed from the word before the stub"
    else
        case "$PARKED_PC" in
            "" | *[!0-9a-f]*)
                bad "L2_control_entry_minus4" "no parked PC (PARKED_PC='$PARKED_PC') — the discriminator never ran" ;;
            "$want_pc")
                bad "L2_control_entry_minus4" "parked at the halt 0x$want_pc having entered at entry-4" ;;
            *)
                ok "L2_control_entry_minus4" "entry-4 (the preceding function's tail, not the entry function's) => no sentinel, parked at 0x$PARKED_PC (not the halt 0x$want_pc)" ;;
        esac
    fi
}

# =============================================================================
# L3 — heap exhaustion, DISCRIMINATED: PRE+MID on the wire, POST absent, and
#      the machine parked INSIDE heap_bump_halt's loop (QMP PC == load +
#      unique self-branch offset). Controls prove each assertion load-bearing:
#      (a) uninitialised variant parks at the SAME loop but never prints MID;
#      (b) crash variant prints MID but parks AWAY from the loop.
#
#      WHY THE PC IS NEEDED AT ALL. Exhaustion and heap_bump_halt(1, ...) end
#      in the SAME `loop { }` (std/heap_bump.kr:59-67), so "it halted" carries
#      no information about WHY. Reading the parked PC turns the halt site
#      itself into the evidence, without touching the stdlib module under test.
#
#      ABSENCE OF POST, honestly stated. The run's wait ends the instant MID
#      reaches the wire, so on its own "no POST yet" would be vacuous. It is
#      not vacuous here for two reasons that are both observed rather than
#      argued: the capture is read AFTER the parked-PC sampling and the kill,
#      so the absence window covers the settle too; and a machine proven
#      stationary in a one-instruction self-branch cannot subsequently print.
#
#      THIS IS THE ONE LEG B2 TASK 5 LEFT ON THE EXTERNAL make_stub.py STUB,
#      and the reason is `loop_offset_a64` itself. All three heap programs
#      contain a `loop { }`, which IS the word this helper counts; the emitted
#      arm64 stub ends in `b .`, the SAME word. Building these with
#      --stack-top therefore gives two self-branches and the helper returns
#      AMBIG:2 (confirmed live at Task 3: offsets [668, 1732] for heap_a64.kr).
#      It fails safe — the leg goes RED, never falsely green — but a leg that
#      cannot run is not a check, so L3 keeps the no-stack-top build and the
#      external stub. Weakening the uniqueness assertion to "exactly one
#      besides the stub's" would make the PC inference this leg is built on
#      ("the machine is in heap_bump_halt's loop") depend on knowing which of
#      two self-branches it parked in, which is precisely what uniqueness buys.
#      make_stub.py is therefore NOT dead code now that Task 6 removed boot.S
#      and build_loader.sh — it is a different file and a different stub; L3
#      is its sole remaining user, and the arm64 self-boot is gated by L2, L4
#      and their controls instead.
# =============================================================================
leg3() {
    echo "--- L3: heap exhaustion, discriminated ---"
    local entry loopoff want_pc
    cp "$BOOT/heap_a64.kr" "$BOOT/heap_uninit_a64.kr" "$BOOT/heap_crash_a64.kr" "$WORK/"
    if ! entry=$(build_image a64 "$WORK/heap_a64.kr" "$WORK/h.img"); then
        bad "L3_compile" "heap_a64.kr did not compile"; return
    fi
    if ! loopoff=$(loop_offset_a64 "$WORK/h.img"); then
        bad "L3_unique_halt_loop" "self-branch count: $loopoff"; return
    fi
    ok "L3_unique_halt_loop" "single loop{} at file offset $loopoff"
    if ! a64_boot_qmp "$A64_LOAD" "$WORK/h.img" "$entry" "$WORK/l3_ser.txt" "MID"; then
        bad "L3_exhaustion_halt" "the boot did not run (stub generation or qemu launch failed)"; return
    fi
    want_pc=$(printf %x $(( A64_LOAD + loopoff )))
    if [ "$PARKED_PC" = "$want_pc" ] && grep -q "PRE" "$WORK/l3_ser.txt" \
       && grep -q "MID" "$WORK/l3_ser.txt" && ! grep -q "POST" "$WORK/l3_ser.txt"; then
        ok "L3_exhaustion_halt" "PRE+MID, no POST, parked at 0x$want_pc == heap_bump_halt's loop"
    else
        bad "L3_exhaustion_halt" "serial='$(tr '\n' ' ' <"$WORK/l3_ser.txt")' pc=$PARKED_PC want=$want_pc"
    fi
    # Control (a): uninitialised => SAME park, but MID must be ABSENT. This is
    # what proves the MID assertion load-bearing: drop it from the subject and
    # this program satisfies everything that is left.
    local e2 l2 pc2
    if ! e2=$(build_image a64 "$WORK/heap_uninit_a64.kr" "$WORK/hu.img"); then
        bad "L3_control_uninit" "heap_uninit_a64.kr did not compile"; return
    fi
    if ! l2=$(loop_offset_a64 "$WORK/hu.img"); then
        bad "L3_control_uninit" "self-branch count: $l2"; return
    fi
    if ! a64_boot_qmp "$A64_LOAD" "$WORK/hu.img" "$e2" "$WORK/l3a_ser.txt" "PRE"; then
        bad "L3_control_uninit" "the boot did not run"; return
    fi
    pc2=$(printf %x $(( A64_LOAD + l2 )))
    if [ "$PARKED_PC" = "$pc2" ] && grep -q "PRE" "$WORK/l3a_ser.txt" \
       && ! grep -q "MID" "$WORK/l3a_ser.txt"; then
        ok "L3_control_uninit" "reason-1 halt parks at the SAME loop (0x$pc2) with MID absent — MID is what discriminates"
    else
        bad "L3_control_uninit" "serial='$(tr '\n' ' ' <"$WORK/l3a_ser.txt")' pc=$PARKED_PC loop=$pc2"
    fi
    # Control (b): crash after MID => parked AWAY from the loop. This proves
    # the PC assertion load-bearing: drop it and "PRE+MID then hang" passes
    # for any crash whatsoever.
    local e3 l3off pc3
    if ! e3=$(build_image a64 "$WORK/heap_crash_a64.kr" "$WORK/hc.img"); then
        bad "L3_control_crash" "heap_crash_a64.kr did not compile"; return
    fi
    if ! l3off=$(loop_offset_a64 "$WORK/hc.img"); then
        bad "L3_control_crash" "self-branch count: $l3off"; return
    fi
    if ! a64_boot_qmp "$A64_LOAD" "$WORK/hc.img" "$e3" "$WORK/l3b_ser.txt" "MID"; then
        bad "L3_control_crash" "the boot did not run"; return
    fi
    # SHAPE-CHECK BEFORE THE COMPARISON. This control's PC assertion is a
    # `!=`, which both QMPFAIL and MOVING:* satisfy vacuously, so without this
    # the control goes green precisely when the discriminator is broken —
    # observed: with qmp_pc.py's socket argument corrupted, L3_control_crash
    # passed while the other two failed (review round 1, I5).
    case "$PARKED_PC" in
        "" | *[!0-9a-f]*)
            bad "L3_control_crash" "no parked PC (PARKED_PC='$PARKED_PC') — the discriminator never ran"; return ;;
    esac
    pc3=$(printf %x $(( A64_LOAD + l3off )))
    if [ "$PARKED_PC" != "$pc3" ] && grep -q "MID" "$WORK/l3b_ser.txt" \
       && ! grep -q "POST" "$WORK/l3b_ser.txt"; then
        ok "L3_control_crash" "abort parks at 0x$PARKED_PC, not the halt loop at 0x$pc3 — the PC check is what discriminates"
    else
        bad "L3_control_crash" "serial='$(tr '\n' ' ' <"$WORK/l3b_ser.txt")' pc=$PARKED_PC loop=$pc3"
    fi
}

# =============================================================================
# L4 — arm64 alignment. THE BLOCKING ASSERTION IS THE COMPILE-TIME REFUSAL of
#      an unaligned --load-addr (per the spec's leg-4 correction): delete that
#      check and the leg exits 0, which is what makes it the one that can be
#      shown to fail. The RUNTIME PAIR — one image, two runs, aligned prints
#      and +0x100 silent — is the SUPPORTING observation: it is why the
#      refusal exists at all, since it shows what an unaligned load actually
#      does to a real boot. The aligned half must PRINT, because a
#      silence-only assertion once passed with no image loaded at all
#      (review 2, O5).
#
#      THE TWO COMPILE-TIME CHECKS RUN FIRST, DELIBERATELY, and that is a
#      departure from the brief's "append after the runtime pair". leg4's
#      runtime half has two early `return`s, so appending would have made the
#      BLOCKING assertion the first thing hidden by a failure of the
#      supporting one. run_leg would name both as SKIP (Task 4's fix), so
#      nothing would go silently missing either way — but a red run should
#      still report the leg's primary assertion rather than skip it, and these
#      two checks depend on nothing the runtime pair produces.
#
#      WHY 0x100 AND NOT SOME LARGER SHIFT. arm64 position independence here
#      is real but PAGE-GRANULAR: every static reaches its data through
#      `adrp` + displacement, and adrp resolves a 4 KiB page, so a shift that
#      preserves the low 12 bits preserves the map and a shift that does not
#      destroys it. Measured on this exact image: +0x0 prints, +0x1000 prints,
#      and +0x100 / +0x200 / +0x400 / +0x4100 are all silent. 0x100 is
#      therefore the SMALLEST interesting failure, and it is chosen because it
#      is the one an unaligned --load-addr would most plausibly produce.
#
#      Note what this leg does NOT assert: nothing about x86_64. That image is
#      fully position-independent — the same bytes printed at 0x400000,
#      0x800000 and 0x800123 — so an x86 misalignment control would be
#      asserting a falsehood.
# =============================================================================
leg4() {
    echo "--- L4: arm64 misalignment (compile refusal + runtime pair) ---"
    cp "$BOOT/sentinel_a64.kr" "$WORK/sentinel_a64.kr"
    cp "$BOOT/sentinel_x86.kr" "$WORK/sentinel_x86_l4.kr"
    # BLOCKING: the unaligned --load-addr must be refused AT COMPILE TIME.
    # THREE things are asserted, and each covers a way the other two pass on
    # something that is not the refusal:
    #   * nonzero exit    — a refusal that exits 0 is not a refusal;
    #   * the NAMED message — an exit-code-only check passes on a typo'd path,
    #     a missing file, or any unrelated diagnostic (review round 1 I4);
    #   * NO ARTIFACT     — "it complained and emitted anyway" is the failure
    #     this leg exists to prevent, and neither of the other two sees it.
    # The compiler writes this diagnostic to STDERR (verified: with 2>/dev/null
    # the message vanishes and only the exit status is left), so the capture
    # must merge it. The log is kept in $WORK, which survives a red run.
    rm -f "$WORK/l4_ref.img"
    "$KRC" --arch=arm64 --target=none --emit=image --load-addr=0x40400100 \
           "$WORK/sentinel_a64.kr" -o "$WORK/l4_ref.img" >"$WORK/l4_ref.log" 2>&1
    local rc4=$?
    if [ "$rc4" != 0 ] && grep -q "must be 4096-aligned on arm64" "$WORK/l4_ref.log" \
       && [ ! -f "$WORK/l4_ref.img" ]; then
        ok "L4_unaligned_refused_at_compile" "exit $rc4, named diagnostic, no artifact written"
    else
        bad "L4_unaligned_refused_at_compile" "exit=$rc4 artifact=$([ -f "$WORK/l4_ref.img" ] && echo WRITTEN || echo absent) log='$(head -c 120 "$WORK/l4_ref.log")'"
    fi
    # The asymmetry is what makes the refusal a STATEMENT ABOUT arm64 rather
    # than a blanket restriction: x86_64 takes the same low-12-bit offset and
    # must EMIT. Artifact presence is asserted, not just exit 0 — Task 5's
    # print-before-write hazard means a zero exit alone does not prove a file.
    rm -f "$WORK/l4_x.img"
    if "$KRC" --arch=x86_64 --target=none --emit=image --load-addr=0x400100 \
              "$WORK/sentinel_x86_l4.kr" -o "$WORK/l4_x.img" >"$WORK/l4_x.log" 2>&1 \
       && [ -f "$WORK/l4_x.img" ]; then
        ok "L4_x86_same_offset_accepted" "asymmetry holds: x86_64 took +0x100 and wrote $(stat -c%s "$WORK/l4_x.img") B"
    else
        bad "L4_x86_same_offset_accepted" "x86_64 refused (or wrote nothing) at an address it can run at: '$(head -c 120 "$WORK/l4_x.log")'"
    fi
    # The runtime pair runs on the EMITTED stub since B2 Task 5 — same image,
    # same self-boot invocation as L2, only the load address differs. That is
    # what keeps the pair's "one number different" claim honest: with an
    # external stub the two runs also differed in a stub built for a different
    # branch target. Re-observed on this form: 0x40400000 prints, +0x100 silent.
    local entry
    if ! entry=$(build_image a64 "$WORK/sentinel_a64.kr" "$WORK/s4.img" "$A64_STACK_TOP"); then
        bad "L4_aligned_prints_misaligned_silent" "sentinel_a64.kr did not compile"; return
    fi
    if ! a64_self_boot "$A64_LOAD" "$WORK/s4.img" "$entry" "$WORK/l4_ok.txt" "1000000016"; then
        bad "L4_aligned_prints_misaligned_silent" "the ALIGNED boot did not run (qemu exit=$BOOT_QEMU_RC)"; return
    fi
    # The misaligned half asserts absence, so its window is derived from the
    # aligned half just observed — same rule as every other silence here.
    calibrate_silence
    if ! a64_self_boot $(( A64_LOAD + 0x100 )) "$WORK/s4.img" "$entry" "$WORK/l4_mis.txt" RUNOUT; then
        bad "L4_aligned_prints_misaligned_silent" "the MISALIGNED boot did not run (qemu exit=$BOOT_QEMU_RC) — silence proves nothing"; return
    fi
    if grep -q "1000000016" "$WORK/l4_ok.txt" && ! grep -q "1000000016" "$WORK/l4_mis.txt"; then
        ok "L4_aligned_prints_misaligned_silent" "same bytes, same invocation: 0x$(printf %x $A64_LOAD) prints, +0x100 is silent"
    else
        bad "L4_aligned_prints_misaligned_silent" "aligned='$(tr '\n' ' ' <"$WORK/l4_ok.txt")' mis='$(tr '\n' ' ' <"$WORK/l4_mis.txt")'"
    fi
}

# =============================================================================
# L5 — the arm64 Linux `Image` header actually BRANCHES (sub-project C, Task 2)
#
#      THE SUBJECT IS FILE OFFSET 0, and that is the whole leg. With
#      `--image-header` the compiler prefixes 64 bytes whose FIRST WORD is
#      `b <stub>`; every other byte of the header is inert data that no
#      instruction ever reads. So the one thing a boot can prove about this
#      header — and the one thing no static check can — is that entering the
#      artifact at its first byte reaches the stub and the program runs.
#
#      WHAT THIS LEG DOES NOT SHOW, STATED HERE SO ITS PASS IS NOT OVER-READ
#      (sub-project C, Task 2 review, I1). NOTHING IN L5 RECOGNISES THE HEADER.
#      The artifact is placed with `-device loader,force-raw=on` at an address
#      this script chose and the reset PC is parked on another address this
#      script chose, so the 64 bytes are never parsed by anything — the leg
#      proves the file's first word is a branch a machine will follow, and no
#      more. The loader-recognition half is L6, which runs `-kernel` and lets
#      QEMU read the header. Both are needed and neither substitutes: L5 is the
#      only leg that enters at byte 0 with an address under our control, and L6
#      is the only one where the header decides anything.
#
#      WHAT THE STATIC ROWS CANNOT SEE. tests/run_tests.sh decodes code0 and
#      asserts its imm26 lands on the reported entry. That is arithmetic on a
#      number the compiler printed, checked against a word the compiler wrote;
#      both come from the same emitter and are wrong together if the emitter's
#      idea of the stub offset is wrong. Only a machine executing the word
#      settles it. This is the same division of labour as L2: the static rows
#      say the image LOOKS right, the leg says it RUNS.
#
#      OFFSET 0 IS ASSERTED NOT TO BE THE REPORTED ENTRY, for the reason L2's
#      header spells out and which is SHARPER here: with the header the
#      reported entry is the stub at 64 + its old offset, so if it ever came
#      back as 0 the subject would be entering the stub directly and the
#      header's branch would go untested while the leg stayed green. Checked,
#      not assumed.
#
#      THE HALT ASSERTION IS WHAT RULES OUT "PRINTED SOME OTHER WAY". A
#      sentinel on the wire proves the program ran; it does not prove control
#      arrived through `bl <entry>` from the stub. Parking on the stub's own
#      `b .` after main returns does — the PC is read over QMP and cross-checked
#      against `entry + 16`, so a stub whose halt moved cannot pass by accident.
#      That `b .` is also still the UNIQUE 0x14000000 in the image, which is a
#      standing obligation on code0 — but NOT because the placeholder is the
#      same word. It is not: the placeholder is 0 (`udf #0`), and 0x14000000
#      was deliberately rejected as one for exactly this reason (src/main.kr;
#      restated in this leg's own AMBIG:2 note, below). The obligation is
#      on the PATCHED value: if code0's computed displacement ever came out 0,
#      the branch would encode as 0x14000000, hang here AND break the
#      `loop_offset_a64` scan five other checks read a PC through. A MISSED
#      patch is a different, louder failure — `udf` on the first word.
#
#      THE CONTROL DELIBERATELY DUPLICATES L2_control_offset0's SHAPE. Same
#      source, same --stack-top, same entry address (0), only `--image-header`
#      removed — silence, and a parked PC that is NOT the halt. L2 already runs
#      that exact boot, so this is a duplicate run and it is on purpose: this
#      leg's inference ("offset 0 printed BECAUSE of the header") must not
#      depend on another leg having executed. A control borrowed from a leg
#      that returned early is not a control.
# =============================================================================
leg5() {
    echo "--- L5: arm64 Image header — boot from file offset 0 ---"
    cp "$BOOT/sentinel_a64.kr" "$WORK/sentinel_a64_l5.kr"
    local entry img="$WORK/s5.img"
    if ! entry=$(build_image a64 "$WORK/sentinel_a64_l5.kr" "$img" "$A64_STACK_TOP" "--image-header"); then
        bad "L5_header_entry_is_not_offset0" "sentinel_a64.kr did not compile with --image-header"; return
    fi
    # ---- BLOCKING, BEFORE THE RUNTIME PAIRS (see L1's note on ordering) ----
    if [ "$entry" != 0 ]; then
        ok "L5_header_entry_is_not_offset0" "reported entry $entry != 0, so booting at offset 0 exercises the header's branch and not the stub itself"
    else
        bad "L5_header_entry_is_not_offset0" "the reported entry IS file offset 0 — the subject would enter the stub directly and code0 would go untested"
    fi
    local halt want_pc
    if ! halt=$(loop_offset_a64 "$img"); then
        # AMBIG:2 here would mean the header contributed a second self-branch.
        # It cannot come from an UNPATCHED code0 -- that placeholder is 0, i.e.
        # `udf #0`, chosen precisely so a missed patch is not this word -- so it
        # would mean the patch computed a displacement of 0 and branched to
        # itself, which is a different defect from the one L2 guards.
        bad "L5_halt_parked" "self-branch count: $halt (AMBIG:2 means code0 was patched to branch to ITSELF)"; return
    fi
    if [ "$halt" != $(( entry + 16 )) ]; then
        bad "L5_halt_parked" "the unique 'b .' is at $halt, but the stub's halt must be at entry + 16 = $(( entry + 16 ))"; return
    fi
    want_pc=$(printf %x $(( A64_LOAD + halt )))
    # ---- the subject: enter at the HEADER, not at the stub -----------------
    if ! a64_self_boot_qmp "$A64_LOAD" "$img" 0 "$WORK/l5_ser.txt" "1000000016"; then
        bad "L5_header_boots_from_offset0" "the boot did not run (qemu exit=$BOOT_QEMU_RC): '$(head -c 120 "$WORK/l5_ser.txt.err")'"
        bad "L5_halt_parked" "no boot to read a PC from"; return
    fi
    if grep -q "1000000016" "$WORK/l5_ser.txt"; then
        ok "L5_header_boots_from_offset0" "entered at load + 0 (code0) and computed 1000000016 on the PL011 (${BOOT_WAITED_TICKS} ticks)"
    else
        bad "L5_header_boots_from_offset0" "serial held: '$(tr '\n' ' ' <"$WORK/l5_ser.txt")'"
    fi
    if [ "$PARKED_PC" = "$want_pc" ]; then
        ok "L5_halt_parked" "PC parked at 0x$want_pc == load + entry + 16, the stub's own 'b .' — so code0 branched to the stub and main RETURNED into it"
    else
        bad "L5_halt_parked" "pc=$PARKED_PC want=$want_pc"
    fi
    # Absence window derived from the arm64 positive boot just observed.
    calibrate_silence
    # ---- the control: the same image WITHOUT the header, same entry (0) ----
    #
    # THE CONTROL COMPARES AGAINST ITS OWN IMAGE'S HALT, not the subject's.
    # The two artifacts differ by a 64-byte prefix, so the unflagged image's
    # `b .` sits 64 bytes BELOW $want_pc. Testing the control's parked PC
    # against $want_pc — as the first version of this leg did — asks whether
    # it stopped at an address that is not in its stub at all: it would go
    # green on any outcome including the one it exists to catch (offset 0
    # reaching the stub without a header, which would park at
    # $want_pc - 64 and read as "not the halt"). It passed, for the wrong
    # reason. $want_pc5 is derived from the control's own file.
    #
    # AND THE 64-BYTE RELATION IS ASSERTED, not assumed: if the two halts are
    # not exactly 64 apart, the two images differ by more than the header and
    # "one flag is the whole difference" is not a claim this leg may make.
    local e5 halt5 want_pc5
    if ! e5=$(build_image a64 "$WORK/sentinel_a64_l5.kr" "$WORK/s5_noh.img" "$A64_STACK_TOP"); then
        bad "L5_control_no_header_offset0_silent" "the no-header build failed — control never ran"
    elif ! halt5=$(loop_offset_a64 "$WORK/s5_noh.img"); then
        bad "L5_control_no_header_offset0_silent" "self-branch count in the no-header image: $halt5 — no address to discriminate against"
    elif [ "$halt5" != $(( halt - 64 )) ]; then
        bad "L5_control_no_header_offset0_silent" "the no-header halt is at $halt5 but the headered one is at $halt — the two images differ by something other than the 64-byte prefix, so this is not a control"
    elif ! a64_self_boot_qmp "$A64_LOAD" "$WORK/s5_noh.img" 0 "$WORK/l5_noh.txt" RUNOUT; then
        bad "L5_control_no_header_offset0_silent" "the boot did not run (qemu exit=$BOOT_QEMU_RC) — silence proves nothing"
    elif grep -q "1000000016" "$WORK/l5_noh.txt"; then
        bad "L5_control_no_header_offset0_silent" "sentinel printed from offset 0 of an image with NO header — the subject's pass says nothing about code0"
    else
        want_pc5=$(printf %x $(( A64_LOAD + halt5 )))
        # SHAPE-CHECK BEFORE THE `!=` (B1 review I5): QMPFAIL and MOVING:*
        # satisfy it vacuously, so without this the control goes green
        # precisely when the discriminator is broken.
        case "$PARKED_PC" in
            "" | *[!0-9a-f]*)
                bad "L5_control_no_header_offset0_silent" "no parked PC (PARKED_PC='$PARKED_PC') — the discriminator never ran" ;;
            "$want_pc5")
                bad "L5_control_no_header_offset0_silent" "parked at its OWN halt 0x$want_pc5 having entered at offset 0 with no header — offset 0 reached the stub without code0" ;;
            *)
                ok "L5_control_no_header_offset0_silent" "no --image-header => offset 0 is the first FUNCTION (entry $e5): no sentinel, parked at 0x$PARKED_PC (not its own halt 0x$want_pc5, which is $want_pc minus the 64-byte prefix) — one flag is the whole difference" ;;
        esac
    fi
}

# One of L6's SILENCE controls: boot a patched image under `-kernel`, require
# no sentinel, and require the parked PC not to be this image's stub halt at
# ANY legal load base.
#   $1 check name, $2 image, $3 capture file, $4 halt offset, $5 PASS detail.
#
# WHY THE QUIET IS NOT THE EVIDENCE. Under `-kernel` this script does not choose
# the load address, so "parked at 0x200" cannot be compared against a constant
# the way L2's and L5's controls do — the address the stub WOULD have parked at
# is only known after the fact. a64_kernel_base inverts that: it asks whether
# the observed PC can be read as "this image's halt, at some base inside DRAM",
# and its FAILURE is the assertion. A guest that faulted parks in the exception
# vector at 0x200, and 0x200 - halt is negative for every image this gate
# builds, so the failure is loud rather than incidental.
#
# TAKEN AS AN EXPLICIT PARAMETER, NOT READ FROM THE CALLER'S SCOPE. bash's
# dynamic scoping would have handed it leg6's `local halt` for free, and the
# next control that needs a DIFFERENT image's halt (the no-header one does)
# would then have silently measured against the wrong file — the same class of
# defect as L5's control comparing against the subject's halt (Task 2, M2).
l6_quiet_control() {
    local name="$1" img="$2" ser="$3" halt="$4" detail="$5" b
    if ! a64_kernel_boot_qmp "$img" "$ser" RUNOUT; then
        bad "$name" "the boot did not run (qemu exit=$BOOT_QEMU_RC) — silence proves nothing"
        return
    fi
    if grep -q "1000000016" "$ser"; then
        bad "$name" "the sentinel printed anyway: '$(tr '\n' ' ' <"$ser")'"
        return
    fi
    case "$PARKED_PC" in
        "" | *[!0-9a-f]*)
            bad "$name" "no parked PC (PARKED_PC='$PARKED_PC') — the discriminator never ran"
            return ;;
    esac
    if b=$(a64_kernel_base "$PARKED_PC" "$halt"); then
        bad "$name" "silent, but 0x$PARKED_PC IS this image's halt at load base $(printf 0x%x "$b") — it reached the stub anyway"
    else
        ok "$name" "$detail: no sentinel, parked at 0x$PARKED_PC (not this image's stub at any legal load base)"
    fi
}

# =============================================================================
# L6 — THE HEADER HANDED TO A LOADER. This is the leg sub-project C exists for,
#      and L5 is not it.
#
#      L5 places the artifact with `-device loader,force-raw=on` and parks the
#      reset PC on an address THIS SCRIPT chose. That proves the file's first
#      word is a branch a machine will follow. It proves nothing about anything
#      RECOGNISING the header, because in that invocation nothing reads it —
#      QEMU is copying bytes to an address it was told. C exists precisely to be
#      recognised by a boot chain (U-Boot `booti`, an EFI stub, `boot.img`), so
#      a gate without this leg does not test C's purpose.
#
#      `qemu-system-aarch64 -M virt -cpu cortex-a57 -kernel <image>` is the only
#      invocation in this file that hands the 64 bytes to a loader: no -device,
#      no addr=, no entry offset, no --load-addr echoed back. QEMU parses the
#      header and decides both where to put the image and where to start it.
#      (-cpu cortex-a57 is not optional and its absence is not a subtle failure:
#      -M virt defaults to a CPU that is silent for EVERY artifact here, valid
#      or not, so a leg missing it looks exactly like a real regression.)
#
#      WHAT QEMU DECIDED IS THE OBSERVABLE, AND IT IS READ OFF THE PARKED PC.
#      The guest parks on the stub's own `b .` at file offset `halt`, so
#      `base = PC - halt` is the address QEMU chose (a64_kernel_base). Measured
#      on this machine, qemu 8.2.2, one field changed at a time from the real
#      artifact:
#
#        header as emitted (text_offset=0, image_size=1128)  base 0x40200000
#        text_offset := 0x300000                             base 0x40300000
#        text_offset := 0x1000                               base 0x40001000
#        magic := 0xDEADBEEF                                 base 0x40080000
#        image_size := 0                                     base 0x40080000
#
#      So text_offset IS honoured, verbatim, except that a request under 4 KiB
#      is moved up by 2 MiB — QEMU writes its own five-instruction bootloader at
#      the bottom of DRAM and the Image format asks for an offset from a 2 MiB
#      boundary rather than an absolute address, so it may legally do this. That
#      is why the subject asserts the base is 2 MiB-ALIGNED rather than equal to
#      a constant: the alignment is what `text_offset = 0` buys and it survives
#      a QEMU that drops or resizes the bump, whereas 0x40200000 would not.
#
#      AND IT IS WHY THE MAGIC AND image_size CONTROLS ARE NOT SILENCE CONTROLS.
#      QEMU reads text_offset and image_size ONLY when the magic matches AND
#      image_size is nonzero; otherwise it falls back to a fixed +0x80000 and
#      never looks at the header again. Both mutants therefore STILL BOOT AND
#      STILL PRINT — this compiler's arm64 output is position-independent, so
#      being loaded somewhere else costs it nothing — and a control written as
#      "corrupt the magic, expect silence" would pass no matter what the
#      compiler emitted. What discriminates is 0x40080000 vs 0x40200000: the
#      loader stopped using our header. That is asserted, and the PASS lines say
#      out loud that the boot itself is not the discriminator.
#
#      COVERAGE, DERIVED FIELD BY FIELD rather than claimed. Each row below was
#      measured by corrupting exactly that field of a real artifact and running
#      both oracles:
#
#        code0        BOOT.  nop -> silent; branch to entry-4 -> silent.
#        text_offset  BOOT.  changes the load base verbatim (table above).
#        image_size   BOOT.  0 -> header abandoned; 0x10000000 -> qemu REFUSES
#                            ("too large to fit in RAM ... RAM size 134217728").
#        magic        BOOT (load base) AND file(1) (-> `data`).
#        flags        file(1) ONLY, and only bit 0 and bits 1-2: 0x1 reads
#                     "big-endian", 0x0 drops the page-size clause, 0x4 reads
#                     "16K pages". THE EMITTED VALUE IS NOT COVERED — 0xA and
#                     0x2 give an IDENTICAL file(1) line AND an identical parked
#                     PC, so bit 3 (physical placement) has NO oracle here.
#                     Re-measured in Task 4 with a SECOND bit-3-only pair,
#                     0x8 vs 0x0: also identical in both oracles. 0x8 vs 0xA
#                     is NOT a bit-3 experiment — it drops bits 1-2 too and
#                     file(1) loses the "4K pages" clause, which is what
#                     makes 0xA/0x2 and 0x8/0x0 the pairs worth quoting.
#        code1        NO ORACLE. 0xDEADBEEF boots identically, file(1) unchanged.
#        res2..res4   NO ORACLE.
#        res5         NO ORACLE. 0xDEADBEEF boots identically, file(1) unchanged.
#
#      The four no-oracle rows are covered ONLY by the static assertion
#      `imghdr_reserved_are_zero` in tests/run_tests.sh, which checks what the
#      compiler wrote and cannot check that anything cares. That is not a gap
#      this leg can close: nothing observable depends on them.
#
#      WHAT A GREEN L6 DOES NOT CLAIM (sub-project C, Task 4). Every number
#      above is `load_aarch64_image` in qemu's hw/arm/boot.c doing what it
#      does. That makes this leg proof THAT QEMU READS OUR HEADER — the
#      strongest evidence in this project, and still not evidence that the
#      header is CONFORMANT to the Linux Image specification. No test here
#      compares the bytes to the spec; no spec-conformance claim is available
#      from anything in this tree.
#
#      AND NO REAL BOOT CHAIN HAS RUN ANY OF IT. No U-Boot `booti`, no EFI
#      stub, no Android boot.img tooling, no hardware: qemu 8.2.2 on one
#      developer machine is the entire boot evidence for a sub-project whose
#      stated purpose is real-loader compatibility. Read every PASS line below
#      with that bound attached.
#
#      CI, PRECISELY — and it is not "never" (see the CI STATUS block in this
#      file's header). The gate is a COUNTED test in tests/run_tests.sh and ran
#      green in CI at the branch point, on both suite runners. What has never
#      run in CI is narrower: L5 and L6 specifically, because sub-project C's
#      branch is unpushed. Both run on the first push after it merges.
#
#      A LIVE GAP IN EXACTLY THAT DIRECTION: B2's entry stub materialises the
#      stack top IN x0 (movz/movk) as its first instruction, and the arm64
#      boot protocol requires a loader to pass the FDT's physical address in
#      x0. Every boot in this leg therefore DISCARDS the device tree qemu
#      handed it, and that qemu DOES hand one over was measured, not assumed:
#      with code0 repointed at the stub's halt so the movz/movk never run, the
#      guest parks with x0 = 0x44000000 and the word there is 0xd00dfeed.
#      Nothing here reds on that — the sentinel wants no FDT — so
#      it is recorded at the stub in src/main.kr and again in
#      docs/LANGUAGE.md, and it is out of scope for C to fix.
#
#      file(1) IS DELIBERATELY NOT RUN HERE. `imghdr_file_recognises_image`
#      already runs it, in the suite, in both directions. This gate's rule is
#      that a missing tool is a FAILURE and never a skip, so adding `file` to
#      the dependency probe would red the WHOLE gate on a machine that has qemu
#      but not file — for a check that is already covered elsewhere.
# =============================================================================
leg6() {
    echo "--- L6: arm64 Image header — qemu's OWN loader (-kernel) ---"
    cp "$BOOT/sentinel_a64.kr" "$WORK/sentinel_a64_l6.kr"
    local entry img="$WORK/s6.img"
    if ! entry=$(build_image a64 "$WORK/sentinel_a64_l6.kr" "$img" "$A64_STACK_TOP" "--image-header"); then
        bad "L6_kernel_boots" "sentinel_a64.kr did not compile with --image-header"; return
    fi
    # ---- BLOCKING: locate the halt, and anchor the mutants on the ARTIFACT --
    local halt code0 want_code0
    if ! halt=$(loop_offset_a64 "$img"); then
        bad "L6_kernel_boots" "self-branch count: $halt (no address to read a load base through)"; return
    fi
    if [ "$halt" != $(( entry + 16 )) ]; then
        bad "L6_kernel_boots" "the unique 'b .' is at $halt, but the stub's halt must be at entry + 16 = $(( entry + 16 ))"; return
    fi
    # The two code0 mutants below are derived from the WORD THAT IS IN THE FILE,
    # not from the compiler's reported entry: `b <stub>` is asserted here so
    # that "same branch, one word short" is a statement about the artifact. A
    # mutant computed from the report alone would still be a valid `b` even if
    # code0 held something else entirely, and the control would then be testing
    # a byte the boot never reads.
    code0=$(mb_u32 "$img" "$A64H_CODE0_OFF") || {
        bad "L6_kernel_boots" "could not read code0: $code0"; return
    }
    want_code0=$(( 0x14000000 + entry / 4 ))
    if [ "$code0" != "$want_code0" ]; then
        bad "L6_kernel_boots" "code0 is $code0, not the 'b +$entry' ($want_code0) the mutants are derived from"; return
    fi
    # ---- the subject: qemu reads the header and boots the image -------------
    if ! a64_kernel_boot_qmp "$img" "$WORK/l6_ser.txt" "1000000016"; then
        bad "L6_kernel_boots" "the boot did not run (qemu exit=$BOOT_QEMU_RC): '$(head -c 120 "$WORK/l6_ser.txt.err")'"
        bad "L6_kernel_load_base_is_header_derived" "no boot to read a PC from"; return
    fi
    if grep -q "1000000016" "$WORK/l6_ser.txt"; then
        ok "L6_kernel_boots" "computed 1000000016 on the PL011 from '-kernel ${img##*/}' alone — no -device, no addr, no entry offset (${BOOT_WAITED_TICKS} ticks)"
    else
        bad "L6_kernel_boots" "serial held: '$(tr '\n' ' ' <"$WORK/l6_ser.txt")'"
    fi
    local base
    if ! base=$(a64_kernel_base "$PARKED_PC" "$halt"); then
        bad "L6_kernel_load_base_is_header_derived" "cannot recover a load base from PARKED_PC='$PARKED_PC' and halt $halt: $base"
    elif [ $(( base % A64_IMAGE_ALIGN )) != 0 ]; then
        bad "L6_kernel_load_base_is_header_derived" "qemu put the image at $(printf 0x%x "$base"), which is not 2 MiB-aligned — text_offset=0 was not honoured"
    else
        ok "L6_kernel_load_base_is_header_derived" "parked at 0x$PARKED_PC => qemu placed the image at $(printf 0x%x "$base"), 2 MiB-aligned per text_offset=0 (an address NOTHING on the command line named)"
    fi
    # Absence window derived from the arm64 -kernel boot just observed.
    calibrate_silence
    # ---- control: image_size is READ, not merely written --------------------
    # 256 MiB against -M virt's 128 MiB. qemu refuses the boot outright, so this
    # is the one field whose ORACLE IS THE REFUSAL. It is also the only proof in
    # this project that a loader consults image_size at all: L5 cannot see it
    # (it chose the address) and the static row only checks the compiler wrote
    # the file's own length there.
    if ! img_patch "$img" "$WORK/s6_big.img" \
            "u32:$A64H_IMAGE_SIZE_OFF:268435456" "u32:$(( A64H_IMAGE_SIZE_OFF + 4 )):0"; then
        bad "L6_control_image_size_too_large_refused" "could not patch image_size — control never ran"
    elif a64_kernel_boot "$WORK/s6_big.img" "$WORK/l6_big.txt" SELFEXIT; then
        bad "L6_control_image_size_too_large_refused" "qemu accepted image_size = 256 MiB on a 128 MiB machine (exit=$BOOT_QEMU_RC) — the field is not being read"
    elif ! grep -q "too large to fit in RAM" "$WORK/l6_big.txt.err"; then
        # EXIT 1 ALONE IS NOT THE ASSERTION. qemu exits 1 for every refusal it
        # has -- an unreadable file, a bad -M, a machine option it does not know
        # -- so a status-only check would credit this control for a refusal that
        # had nothing to do with image_size. The message is the only thing that
        # says the SIZE FIELD is what qemu objected to. If a future qemu rewords
        # it this reds loudly with the real text, which is the right direction:
        # the alternative is passing on a refusal nobody looked at.
        bad "L6_control_image_size_too_large_refused" "qemu exited $BOOT_QEMU_RC but not over the size: '$(tr '\n' ' ' <"$WORK/l6_big.txt.err")'"
    else
        ok "L6_control_image_size_too_large_refused" "image_size := 256 MiB on a 128 MiB machine => qemu exit $BOOT_QEMU_RC, 'too large to fit in RAM' — so a loader READS this field, which neither L5 nor any static row can show"
    fi
    # ---- control: the magic is what makes qemu read the header at all -------
    # SILENCE IS NOT THE DISCRIMINATOR AND MUST NOT BE ASSERTED. Measured: this
    # mutant boots and prints, because the payload is position-independent. The
    # header is abandoned, which shows up as a DIFFERENT load base.
    # $base COMES FROM THE SUBJECT, WHICH CAN HAVE FAILED WITHOUT RETURNING:
    # see a64_base_is_value. A `!=` against BADPC:* or OUTSIDE:* is not a
    # discriminator, so refuse to print PASS for one.
    local pcbad basebad
    if ! a64_base_is_value "$base"; then
        bad "L6_control_magic_makes_qemu_read_the_header" "the subject produced no load base ('$base'), so there is nothing to compare against — this control's discriminator cannot run"
    elif ! img_patch "$img" "$WORK/s6_magic.img" "u32:$A64H_MAGIC_OFF:3735928559"; then
        bad "L6_control_magic_makes_qemu_read_the_header" "could not patch the magic — control never ran"
    elif ! a64_kernel_boot_qmp "$WORK/s6_magic.img" "$WORK/l6_magic.txt" "1000000016"; then
        bad "L6_control_magic_makes_qemu_read_the_header" "the boot did not run (qemu exit=$BOOT_QEMU_RC)"
    else
        pcbad="$PARKED_PC"
        if ! basebad=$(a64_kernel_base "$pcbad" "$halt"); then
            bad "L6_control_magic_makes_qemu_read_the_header" "no load base from PARKED_PC='$pcbad': $basebad — the discriminator never ran"
        elif [ "$basebad" = "$base" ]; then
            # WORDED FOR THE DEFUSED-HARNESS CASE TOO (Task 3 review, Minor 3).
            # img_patch reports success for a write that changed nothing (a
            # no-op value, or the right value at the wrong offset), so an equal
            # base has TWO causes and this message must not assert the one it
            # cannot see. It names the file it booted, not the patch it hoped
            # for.
            bad "L6_control_magic_makes_qemu_read_the_header" "s6_magic.img (the copy this control writes 0xDEADBEEF into, intending the magic) and the unpatched image both loaded at $(printf 0x%x "$base") — either that write did not reach the magic or qemu does not read it; either way L6_kernel_load_base_is_header_derived is not about our header"
        else
            ok "L6_control_magic_makes_qemu_read_the_header" "magic := 0xDEADBEEF => qemu ABANDONS the header and falls back to $(printf 0x%x "$basebad") instead of $(printf 0x%x "$base") (it still boots and still prints — the load base, not silence, is what discriminates; file(1) is the second oracle, in imghdr_file_recognises_image)"
        fi
    fi
    # ---- control: image_size = 0 abandons the header the same way -----------
    # Same shape, different field, and the same warning applies: MEASURED to
    # boot and print. The Image spec says a zero image_size means "size unknown,
    # use the default offset", and that is exactly what qemu does.
    local base0
    if ! a64_base_is_value "$base"; then
        bad "L6_control_image_size_zero_abandons_header" "the subject produced no load base ('$base'), so there is nothing to compare against — this control's discriminator cannot run"
    elif ! img_patch "$img" "$WORK/s6_sz0.img" \
            "u32:$A64H_IMAGE_SIZE_OFF:0" "u32:$(( A64H_IMAGE_SIZE_OFF + 4 )):0"; then
        bad "L6_control_image_size_zero_abandons_header" "could not patch image_size — control never ran"
    elif ! a64_kernel_boot_qmp "$WORK/s6_sz0.img" "$WORK/l6_sz0.txt" "1000000016"; then
        bad "L6_control_image_size_zero_abandons_header" "the boot did not run (qemu exit=$BOOT_QEMU_RC)"
    elif ! base0=$(a64_kernel_base "$PARKED_PC" "$halt"); then
        bad "L6_control_image_size_zero_abandons_header" "no load base from PARKED_PC='$PARKED_PC': $base0 — the discriminator never ran"
    elif [ "$base0" = "$base" ]; then
        bad "L6_control_image_size_zero_abandons_header" "image_size = 0 loaded at the same $(printf 0x%x "$base") as the real one — the field is not being read"
    else
        ok "L6_control_image_size_zero_abandons_header" "image_size := 0 => text_offset ignored, fell back to $(printf 0x%x "$base0") instead of $(printf 0x%x "$base") (again: it still boots and still prints)"
    fi
    # ---- controls: code0 must be a branch, AND must aim at the stub ---------
    # See l6_quiet_control's header for what "silent" is required to mean here.
    if ! img_patch "$img" "$WORK/s6_nop.img" "u32:$A64H_CODE0_OFF:3573751839"; then
        bad "L6_control_code0_nop_silent" "could not patch code0 — control never ran"
    else
        l6_quiet_control L6_control_code0_nop_silent "$WORK/s6_nop.img" "$WORK/l6_nop.txt" "$halt" \
            "code0 := nop (0xd503201f), every other byte identical"
    fi
    if ! img_patch "$img" "$WORK/s6_off.img" "u32:$A64H_CODE0_OFF:$(( code0 - 1 ))"; then
        bad "L6_control_code0_off_by_one_word_silent" "could not patch code0 — control never ran"
    else
        l6_quiet_control L6_control_code0_off_by_one_word_silent "$WORK/s6_off.img" "$WORK/l6_off.txt" "$halt" \
            "code0 := the same branch with imm26 - 1, i.e. entry - 4 — a valid 'b' aimed one word short"
    fi
    # ---- control: one flag is the whole difference, under -kernel too -------
    # The same source, the same --stack-top, the same command line, ONLY
    # --image-header removed. Without the header qemu finds no magic, loads at
    # its default offset and starts at byte 0 — which is the first FUNCTION, not
    # a stub — and the machine faults. This is L6's own version of L5's control
    # and is deliberately not borrowed from it: L5 boots through -device loader,
    # so it says nothing about what `-kernel` does with a headerless file.
    local e6 halt6
    if ! e6=$(build_image a64 "$WORK/sentinel_a64_l6.kr" "$WORK/s6_noh.img" "$A64_STACK_TOP"); then
        bad "L6_control_no_header_kernel_silent" "the no-header build failed — control never ran"
    elif ! halt6=$(loop_offset_a64 "$WORK/s6_noh.img"); then
        bad "L6_control_no_header_kernel_silent" "self-branch count in the no-header image: $halt6 — no address to discriminate against"
    elif [ "$halt6" != $(( halt - A64H_SIZE )) ]; then
        bad "L6_control_no_header_kernel_silent" "the no-header halt is at $halt6 but the headered one is at $halt — the two images differ by something other than the ${A64H_SIZE}-byte prefix, so this is not a control"
    else
        l6_quiet_control L6_control_no_header_kernel_silent "$WORK/s6_noh.img" "$WORK/l6_noh.txt" "$halt6" \
            "no --image-header (entry $e6) => qemu finds no magic, loads at its default offset and starts at byte 0, which is the first FUNCTION and not a stub"
    fi
}

# =============================================================================
# THE UEFI HALF (sub-project D). Everything from here to the rosters is L7/L8.
# =============================================================================
# WHAT IS DIFFERENT ABOUT THESE TWO LEGS, in one sentence: L0-L6 hand QEMU an
# artifact and QEMU is the loader, whereas L7 and L8 hand a FIRMWARE an ESP and
# edk2 is the loader. Nothing on the command line names an address, an entry
# offset or even a file — the firmware finds `EFI/BOOT/BOOTX64.EFI` by the
# removable-media path, parses the PE32+ header the compiler emitted, maps the
# image and calls it. That is the whole claim of sub-project D, and until this
# block existed the only record of it was prose in Task 2's report.
#
# WHAT A GREEN L7/L8 CLAIMS, and nothing more: a UEFI application built by this
# compiler loads and prints under QEMU's OVMF (q35) and AAVMF (`virt`) on the
# machine that ran the gate. NOT real hardware, NOT vendor firmware, NOT Secure
# Boot — Secure Boot is off in the non-secboot builds selected below, and these
# artifacts are unsigned.
#
# THE FIRMWARE IS A HARD DEPENDENCY, LIKE EVERY OTHER TOOL HERE, but it is
# resolved here and asserted INSIDE leg7/leg8 rather than in the dependency loop
# at the top of the file. The reason is scope: the loop's failure exits before
# L0 runs, and a machine with qemu but without ovmf can still produce every one
# of L0-L6's results. A missing firmware is still a counted FAILURE naming the
# paths that were tried — never a silent pass — it just does not take the other
# seven legs down with it. Be precise about what that means, because the run is
# NOT skip-free: the FAILURE is the dependency check, and every check downstream
# of it in the same leg is then reported as SKIP by run_leg. MEASURED, with both
# firmwares forced unresolved: 0 pass, 2 FAIL, 12 SKIP (9 from L7, 3 from L8).
#
# TRAPS, ALL MEASURED ON THIS MACHINE, none inherited:
#
#   * `-net none` IS REQUIRED. Without it OVMF spends its timeout on PXE before
#     touching the disk, and every leg here pays for it.
#   * A FRESH VARS COPY PER RUN. The firmware writes BootOrder and BootNNNN
#     into the VARS pflash. A shared copy makes each run depend on the one
#     before it, and the "boot the pristine image, then a mutant" ordering these
#     legs use is exactly the shape that goes wrong. `uefi_boot` copies one per
#     tag; the OVMF vars are 528 KiB (540672 B -- the `4M` in OVMF_VARS_4M.fd
#     names the CODE flash size, not this file) and the AAVMF vars 64 MiB,
#     ~0.02 s each.
#   * LANDING IN THE SETUP UI IS COMPATIBLE WITH SUCCESS. A UEFI application
#     that RETURNS hands control back to BDS, which then runs the next boot
#     option — UiApp (the setup browser) on a zero return, or the EFI shell on a
#     non-zero one. The verdict is the SENTINEL, never where the firmware ends
#     up; the only thing the trailing option is used for is the DONE marker.
#   * `mmx64.efi` IS A USELESS POSITIVE CONTROL. MokManager exits immediately,
#     which is indistinguishable from failing to load. The positive control here
#     is our own sentinel, which prints.
#
# THE THING THAT MAKES THE NEGATIVE CONTROLS MEAN ANYTHING — read this before
# adding a leg. Measured under BOTH firmwares, in this session:
#
#     empty ESP                  -> BdsDxe: failed to load Boot0001 …: Not Found
#     correct app, wrong filename-> BdsDxe: failed to load Boot0001 …: Not Found
#     genuine `Subsystem 3`      -> BdsDxe: failed to load Boot0001 …: Not Found
#
# BYTE-IDENTICAL. "Not loaded" therefore does not distinguish a real rejection
# from a staging bug, and under any staging defect EVERY negative control here
# would pass. That is why `uefi_batch_positive` exists and why every control
# checks it: a rejection is evidence only in a batch where something else got
# through, and it is an assertion in the harness rather than a note in a
# comment. The x86 controls that produce `Unsupported` rather than `Not Found`
# get a second, independent oracle (the status word itself cannot be produced by
# a missing file) and assert that too — but `Subsystem 3` is not one of them.

# Where the firmware images live. TRIED IN ORDER, AND CODE/VARS ARE PAIRED:
# mixing an OVMF_CODE from one packaging with an OVMF_VARS from another is a
# silent way to boot a firmware whose variable store it does not understand.
# Debian/Ubuntu first because that is what this gate has been measured on.
UEFI_X86_CODE=""; UEFI_X86_VARS=""
UEFI_A64_CODE=""; UEFI_A64_VARS=""
UEFI_X86_TRIED=""; UEFI_A64_TRIED=""
uefi_pick_firmware() {
    local pair c v
    for pair in "$@"; do
        c="${pair%%|*}"; v="${pair#*|}"
        if [ -f "$c" ] && [ -f "$v" ]; then echo "$c|$v"; return 0; fi
    done
    return 1
}
UEFI_X86_TRIED="/usr/share/OVMF/OVMF_CODE_4M.fd+VARS_4M, /usr/share/OVMF/OVMF_CODE.fd+VARS, /usr/share/edk2/ovmf/OVMF_CODE.fd+VARS, /usr/share/qemu/edk2-x86_64-code.fd+edk2-i386-vars.fd"
if UEFI_X86_PAIR=$(uefi_pick_firmware \
        "/usr/share/OVMF/OVMF_CODE_4M.fd|/usr/share/OVMF/OVMF_VARS_4M.fd" \
        "/usr/share/OVMF/OVMF_CODE.fd|/usr/share/OVMF/OVMF_VARS.fd" \
        "/usr/share/edk2/ovmf/OVMF_CODE.fd|/usr/share/edk2/ovmf/OVMF_VARS.fd" \
        "/usr/share/qemu/edk2-x86_64-code.fd|/usr/share/qemu/edk2-i386-vars.fd"); then
    UEFI_X86_CODE="${UEFI_X86_PAIR%%|*}"; UEFI_X86_VARS="${UEFI_X86_PAIR#*|}"
fi
UEFI_A64_TRIED="/usr/share/AAVMF/AAVMF_CODE.fd+VARS, /usr/share/AAVMF/AAVMF_CODE.no-secboot.fd+VARS, /usr/share/qemu-efi-aarch64/QEMU_EFI.fd+QEMU_VARS.fd, /usr/share/edk2/aarch64/QEMU_EFI-pflash.raw+vars-template-pflash.raw"
if UEFI_A64_PAIR=$(uefi_pick_firmware \
        "/usr/share/AAVMF/AAVMF_CODE.fd|/usr/share/AAVMF/AAVMF_VARS.fd" \
        "/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd|/usr/share/AAVMF/AAVMF_VARS.fd" \
        "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd|/usr/share/qemu-efi-aarch64/QEMU_VARS.fd" \
        "/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw|/usr/share/edk2/aarch64/vars-template-pflash.raw"); then
    UEFI_A64_CODE="${UEFI_A64_PAIR%%|*}"; UEFI_A64_VARS="${UEFI_A64_PAIR#*|}"
fi

# THE RUN IS OVER WHEN BDS HAS MOVED PAST OUR BOOT OPTION, OR THE MACHINE HAS
# FAULTED. This is `<expect>` for every boot below, and getting it wrong is
# expensive in both directions:
#   * stopping at the SENTINEL would make `printed, then faulted` unobservable —
#     the fault text arrives after the sentinel, so a harness that stops on the
#     sentinel can only ever report RAN. The six outcomes would then be five
#     with an unreachable case, which is the exact defect the ordering below is
#     written against.
#   * stopping only at UiApp burns the full deadline on every rejected boot,
#     because a rejection falls through to the EFI shell (Boot0002) instead —
#     measured: 767 ticks against 29 once `failed to load` was added here.
# `Boot000[^1]` is "any boot option that is not ours"; our app is Boot0001 under
# both firmwares, and a capture in which Boot0001 never appears at all is a
# HARNESS_ERROR below rather than a verdict.
UEFI_DONE_RE='Exception|BdsDxe: failed to load Boot|BdsDxe: loading Boot000[^1]'
# What a fault looks like. x86_64/OVMF: `!!!! X64 Exception Type - 06(#UD …)`.
# arm64/AAVMF: `Synchronous Exception at 0x…`. Both measured this session, and
# `ASSERT` is included because an edk2 assertion is also "the firmware stopped
# because of us". Checked against clean captures: 0 occurrences of either word
# in a run that RAN, on both arches.
UEFI_FAULT_RE='Exception|ASSERT'
# out-param of uefi_boot: the serial capture of the run it just did.
UEFI_SER=""
# The two markers the CURRENT leg's sentinel prints, set by each leg before its
# first boot. Globals rather than parameters because uefi_control passes them to
# uefi_verdict on the caller's behalf; declared here so `set -u` catches a leg
# that forgets to set them instead of a control silently grepping for "".
UEFI_LIT=""; UEFI_COMP=""
# The firmware legs get their OWN deadline, saved and restored around each boot
# by uefi_boot. MEASURED on this machine, from qemu launch to the DONE marker:
# 1.4 s under OVMF and 5.3 s under AAVMF. The gate-wide 10 s would leave the
# arm64 leg less than 2x of headroom, and a false-failed POSITIVE leg on a slow
# runner is the failure mode this gate exists to prevent -- so the firmware
# boots get 60 s, better than 10x the slower of the two. It costs nothing on the
# normal path (boot_wait breaks the tick the marker appears).
UEFI_BOOT_TIMEOUT=60
UEFI_BOOT_TICKS=1200
# The batch's positive control. Set by each leg from its FIRST boot — the
# pristine artifact — and read by every control in that leg. "" until set, so a
# control that runs before any positive fails closed.
UEFI_BATCH_POS=""

# Compile a gate program to a UEFI APPLICATION and echo the reported entry RVA
# (decimal) on stdout.
#
# THE `image:` SED AT :474-475 DOES NOT MATCH THIS BUILD, and that is the reason
# this is a separate function rather than a fifth argument to build_image. The
# --emit=uefi report line is
#     uefi: arch=x86_64 entry=4772 filesz=8192 memsz=8192 hdr=4096
# so `sed -n 's/^image: …/'` yields the empty string, and build_image's own
# emptiness check would then call it "no parsable line" — fail-closed, but for a
# reason that has nothing to do with the artifact. Everything build_image
# asserts is asserted here for the same reasons (see its header): exit 0, a
# parsable line, and on-disk size == the reported filesz, because the report is
# printed BEFORE the file is written and codegen ignores file_write's status.
#
# `hdr` IS PARSED AND CHECKED TOO. The header region and the payload are the two
# halves of the geometry Task 2 fixed, and `entry < hdr` would mean the entry
# point lands inside the PE header — an artifact that cannot run and whose
# report still looks well-formed.
build_uefi() {
    local arch="$1" src="$2" out="$3"
    local aflag="x86_64"
    [ "$arch" = "a64" ] && aflag="arm64"
    local log="$out.rep"
    rm -f "$out"
    if ! "$KRC" --arch=$aflag --target=none --emit=uefi "$src" -o "$out" >"$log" 2>&1; then
        echo "  build_uefi: $KRC exited nonzero for $src (see $log)" >&2
        return 1
    fi
    local entry filesz hdr ondisk
    entry=$(sed -n 's/^uefi: .* entry=\([0-9][0-9]*\) .*$/\1/p' "$log")
    filesz=$(sed -n 's/^uefi: .* filesz=\([0-9][0-9]*\) .*$/\1/p' "$log")
    hdr=$(sed -n 's/^uefi: .* hdr=\([0-9][0-9]*\).*$/\1/p' "$log")
    if [ -z "$entry" ] || [ -z "$filesz" ] || [ -z "$hdr" ]; then
        echo "  build_uefi: no parsable 'uefi:' line for $src (see $log)" >&2
        return 1
    fi
    ondisk=$(stat -c%s "$out" 2>/dev/null)
    if [ "$ondisk" != "$filesz" ]; then
        echo "  build_uefi: report claims filesz=$filesz but $out is ${ondisk:-ABSENT} B" >&2
        return 1
    fi
    if [ "$entry" -lt "$hdr" ]; then
        echo "  build_uefi: entry=$entry is inside the ${hdr}-byte header region" >&2
        return 1
    fi
    echo "$entry"
}

# Stage one artifact on a fresh ESP and boot it under the firmware.
#   uefi_boot <arch: x86|a64> <artifact> <tag>
# Returns nonzero if the boot did not happen (boot_run's rule, unchanged), and
# sets UEFI_SER to the capture either way.
#
# ONE STAGING PATH FOR EVERY ARTIFACT IN THIS FILE, and that is load-bearing
# rather than tidy. The batch's positive control reaches the firmware through
# exactly these four lines — same directory construction, same filename, same
# `fat:rw:` drive — so "the positive RAN" is evidence that the staging works for
# the mutants too. Give a control its own staging and that inference is gone.
uefi_boot() {
    local arch="$1" art="$2" tag="$3"
    PARKED_PC=NOQMPRUN   # see the PARKED_PC declaration above
    local esp="$WORK/uefi_esp_$tag" ser="$WORK/uefi_$tag.txt"
    local name="BOOTX64.EFI"
    [ "$arch" = "a64" ] && name="BOOTAA64.EFI"
    UEFI_SER="$ser"
    rm -rf "$esp"
    mkdir -p "$esp/EFI/BOOT" || return 1
    cp "$art" "$esp/EFI/BOOT/$name" || return 1
    local vars="$WORK/uefi_vars_$tag.fd"
    local sv_t="$BOOT_TIMEOUT" sv_d="$BOOT_DEADLINE_TICKS" rc=0
    BOOT_TIMEOUT="$UEFI_BOOT_TIMEOUT"; BOOT_DEADLINE_TICKS="$UEFI_BOOT_TICKS"
    if [ "$arch" = "a64" ]; then
        if cp "$UEFI_A64_VARS" "$vars"; then
            boot_run a64 "$ser" "$UEFI_DONE_RE" -m 256 -net none \
                -drive if=pflash,format=raw,unit=0,readonly=on,file="$UEFI_A64_CODE" \
                -drive if=pflash,format=raw,unit=1,file="$vars" \
                -drive format=raw,file=fat:rw:"$esp" || rc=1
        else
            rc=1
        fi
    else
        if cp "$UEFI_X86_VARS" "$vars"; then
            boot_run x86 "$ser" "$UEFI_DONE_RE" -M q35 -m 256 -net none \
                -drive if=pflash,format=raw,unit=0,readonly=on,file="$UEFI_X86_CODE" \
                -drive if=pflash,format=raw,unit=1,file="$vars" \
                -drive format=raw,file=fat:rw:"$esp" || rc=1
        else
            rc=1
        fi
    fi
    BOOT_TIMEOUT="$sv_t"; BOOT_DEADLINE_TICKS="$sv_d"
    return $rc
}

# THE VERDICT FUNCTION. SIX OUTCOMES, AND THE ORDER IS THE WHOLE DESIGN.
#   uefi_verdict <serial file> <literal marker> <computed marker>
#
# WHY NOT FIVE. The plan asked for five, ordering LOADED_FAULTED before
# LOADED_SILENT. That ordering is necessary and NOT sufficient: it does not
# order RAN, and a payload that PRINTS ITS SENTINEL AND THEN FAULTS is exactly
# the shape a RAN-first verdict scores as success. That shape is not
# hypothetical — it is how the read-only-section experiment presents on arm64
# (first line and computed value on the wire, then a Synchronous Exception on
# the store), and it is L8_control_read_only_section_printed_then_faulted below.
# PRINTED_THEN_FAULTED is therefore its OWN outcome and is tested FIRST of the
# three, so it can be absorbed into neither RAN nor LOADED_FAULTED. If you
# "simplify" this back to five by folding it into either, that control reds —
# which is the point, and is why it is a control and not a comment.
#
# THE HARNESS ERRORS COME BEFORE EVERYTHING because none of the six is
# interpretable without them:
#   no capture / empty        — qemu never wrote a byte; nothing ran.
#   no `BdsDxe:`              — the firmware never reached the boot manager, so
#                               "our app did not print" says nothing about it.
#   no `Boot0001`             — BDS never considered the disk. Our app is
#                               Boot0001 under both firmwares measured here; if
#                               a future firmware orders the options differently
#                               this must be loud, not a silent NOT_LOADED.
#   no DONE marker            — the run hit the DEADLINE instead of ending. See
#                               below; this one is not obvious and it is the one
#                               that could produce a FALSE GREEN.
#
# THE DEADLINE CHECK, AND WHY IT IS THE MARKER AND NOT THE CLOCK (Task 3
# re-review). `boot_wait` returns when its tick budget runs out without saying
# so, and `boot_run` only rejects qemu's exit 1 — `timeout`'s own 124 is a
# BOOT, deliberately (L0_alarm_not_a_dead_boot pins that). So an image that
# STARTS, never prints, never faults and never returns runs out the 60 s and
# lands on exactly the evidence `LOADED_SILENT` is defined by: started, no
# markers, no fault. A hang would score as the silent case, and
# L7_control_entry_at_section_start_silent — the row that exists to protect the
# crashed-vs-silent distinction — would go green on it.
#
# Requiring the DONE marker closes it for every row at once, because every one
# of the five outcomes below leaves one behind: `Exception` for both faulted
# shapes, `failed to load Boot` for NOT_LOADED, `loading Boot000[^1]` for RAN
# and for the genuine silent case (BDS moving to the next option is what "the
# application returned" looks like). A run with none of them did not end, and
# nothing about it is a verdict.
#
# THE ALTERNATIVE — assert BOOT_WAITED_TICKS is well under UEFI_BOOT_TICKS —
# WAS REJECTED, and the reason matters. It needs a threshold, and a threshold
# is a claim about how fast the machine is: the genuine case is 28 ticks here
# against a 1200-tick ceiling, but nothing in this gate knows how slow a TCG
# runner may be, and a false-failed positive on a slow machine is the failure
# mode this whole file is written against (see the derived silence window and
# boot_run's `== 1`). The marker is a statement about the EVIDENCE instead: a
# slow machine still produces it WITHIN THE DEADLINE, and a hung one never does
# at any speed. Past the deadline the capture has no marker either and the row
# reds — the check is not immune to a slow machine, it is just strictly better
# than a threshold: a threshold reds runs that genuinely finished, the marker
# reds only runs that genuinely did not. And a machine that slow fails the
# positives anyway (no sentinel, so not RAN), so no passing row becomes a flake.
#
# PRINTED_PARTIAL is the seventh name and it is a FAIL BUCKET, not a seventh
# outcome: the literal reached the wire, the computed value did not, and nothing
# faulted. No leg expects it, so any occurrence reds. It exists so that shape
# cannot be filed as LOADED_SILENT (it printed) or as RAN (it did not compute).
uefi_verdict() {
    local ser="$1" lit="$2" comp="$3"
    [ -f "$ser" ] || { echo "HARNESS_ERROR:no-capture"; return 0; }
    [ -s "$ser" ] || { echo "HARNESS_ERROR:empty-capture"; return 0; }
    grep -qa 'BdsDxe:' "$ser" || { echo "HARNESS_ERROR:no-bds"; return 0; }
    grep -qa 'Boot0001' "$ser" || { echo "HARNESS_ERROR:no-boot0001"; return 0; }
    grep -qaE "$UEFI_DONE_RE" "$ser" || { echo "HARNESS_ERROR:no-terminator"; return 0; }
    local sawlit=1 sawcomp=1 sawfault=1
    grep -qa "$lit"  "$ser" && sawlit=0
    grep -qa "$comp" "$ser" && sawcomp=0
    grep -qaE "$UEFI_FAULT_RE" "$ser" && sawfault=0
    # 1. printed AND faulted — before both of the outcomes that would swallow it.
    if [ "$sawfault" = 0 ] && { [ "$sawlit" = 0 ] || [ "$sawcomp" = 0 ]; }; then
        echo PRINTED_THEN_FAULTED; return 0
    fi
    # 2. faulted having printed nothing.
    if [ "$sawfault" = 0 ]; then echo LOADED_FAULTED; return 0; fi
    # 3. the full sentinel, no fault.
    if [ "$sawcomp" = 0 ] && [ "$sawlit" = 0 ]; then echo RAN; return 0; fi
    # 4. some of it, no fault. Nobody expects this; see the header.
    if [ "$sawlit" = 0 ] || [ "$sawcomp" = 0 ]; then echo PRINTED_PARTIAL; return 0; fi
    # 5. the firmware said no, or never started the image.
    if grep -qa 'failed to load Boot0001' "$ser"; then echo NOT_LOADED; return 0; fi
    grep -qa 'starting Boot0001' "$ser" || { echo NOT_LOADED; return 0; }
    # 6. loaded, started, and produced nothing. EXERCISED by
    # L7_control_entry_at_section_start_silent -- it was not, until the Task 3
    # review pointed out that this was the one arm of the crashed-vs-silent
    # distinction (the distinction that produced this sub-project's Critical)
    # that no row reached, so a regression collapsing it would have been
    # invisible. PRINTED_PARTIAL is deliberately still unexercised: it is a fail
    # bucket, not a claim, and no artifact is known to produce it.
    echo LOADED_SILENT; return 0
}

# FIRST MATCH OF <ere> IN <file>, CR stripped, or the empty string.
#   uefi_first_match <file> <ere>
# NO PIPELINE, DELIBERATELY. This script does not set `pipefail` (deliberately:
# several existing legs pipe into `head`, which closes the pipe and would make a
# SIGPIPE-killed producer fail the leg), so in a pipeline a failing grep is
# invisible and the reader gets an empty string with no attribution. Here the
# grep's status is the only thing that decides, and the CR strip is a parameter
# expansion rather than a `tr`.
uefi_first_match() {
    local m
    m=$(grep -m1 -aoE "$2" "$1" 2>/dev/null) || { printf '%s' "(no match for $2)"; return 0; }
    m="${m%%$'\n'*}"
    printf '%s' "${m//$'\r'/}"
}

# THE ASSERTION THE WHOLE NEGATIVE HALF RESTS ON. Fails (nonzero) unless this
# leg's positive control RAN, so a control can refuse to credit a rejection in a
# batch where nothing got through. See the block comment above for the three
# byte-identical `Not Found` cases this closes.
uefi_batch_positive() { [ "$UEFI_BATCH_POS" = RAN ]; }

# One negative control, end to end: patch a copy of the subject, boot it, and
# require BOTH the batch positive AND the expected verdict.
#   uefi_control <name> <arch> <src artifact> <tag> <expected verdict> <what> [img_patch specs...]
# The status-word oracle is separate (uefi_status_is) because only some of these
# have one.
uefi_control() {
    local name="$1" arch="$2" src="$3" tag="$4" want="$5" what="$6"; shift 6
    local mut="$WORK/uefi_$tag.efi"
    if ! uefi_batch_positive; then
        bad "$name" "the batch positive control did NOT run (verdict '$UEFI_BATCH_POS'), so the outcome of '$what' is not evidence -- an empty ESP, a misnamed file and a genuine header rejection are byte-identical on this firmware"
        return 1
    fi
    if ! img_patch "$src" "$mut" "$@"; then
        bad "$name" "could not patch the artifact ($what) -- the control never ran"
        return 1
    fi
    if ! uefi_boot "$arch" "$mut" "$tag"; then
        bad "$name" "the boot did not happen (qemu exit=$BOOT_QEMU_RC): '$(head -c 200 "$UEFI_SER.err")'"
        return 1
    fi
    local got
    got=$(uefi_verdict "$UEFI_SER" "$UEFI_LIT" "$UEFI_COMP")
    if [ "$got" != "$want" ]; then
        bad "$name" "$what => verdict $got, wanted $want (capture: $UEFI_SER)"
        return 1
    fi
    return 0
}
# The SECOND oracle for the five x86 rejections that produce `Unsupported`. A
# missing or misnamed file cannot produce that word — it produces `Not Found` —
# so for those five the status text discriminates a real header rejection from a
# staging bug on its own, without leaning on the batch positive. `Subsystem 3`
# is deliberately NOT one of them: it produces `Not Found`, and it is the row
# that shows why the batch positive has to exist.
uefi_status_is() { grep -qa "failed to load Boot0001.*: $2" "$1"; }

# =============================================================================
# L7 — x86_64 UEFI APPLICATION under OVMF (q35). Nine boots: the subject, five
#      header rejections, two loads that fault, and the read-only-section case
#      that x86 TOLERATES — which is what makes L8's arm64 twin a controlled
#      experiment rather than "some mutation broke it".
#
#      MEASURED STATUS WORDS, this session, and they are not all the same:
#        Subsystem 10 -> 3                       : Not Found
#        Magic 0x20b -> 0x10b                    : Unsupported
#        Machine 0x8664 -> 0xaa64                : Unsupported
#        NumberOfRvaAndSizes 16 -> 8             : Unsupported
#        SizeOfImage 8192 -> 4096                : Unsupported
#        VirtualSize (1136 here) -> 1            : LOADED, then #UD
#        SizeOfRawData 4096 -> 0                 : LOADED, then #UD
#        AddressOfEntryPoint 4772 -> 4096        : LOADED, STARTED, silent
#
#      THE `1136` IS THIS SENTINEL'S PAYLOAD LENGTH AND IS READ OFF THE
#      ARTIFACT, not written down: an earlier draft of this comment said 1112
#      and no check asserted on it, so it was simply wrong (Task 3 review,
#      Minor 1). The two rows that name it interpolate `$vsz`.
#
#      THE FAULT IS `#UD`, NOT `#PF`. The plan said `#PF` for both fault
#      controls; on this firmware both produce `!!!! X64 Exception Type -
#      06(#UD - Invalid Opcode)`, because the loader maps a page it copied
#      nothing into and the guest executes zeros. The rows assert the OUTCOME
#      (LOADED_FAULTED, i.e. `starting Boot0001` and then a fault) and not the
#      vector, so a firmware that reports it differently reds on the text of the
#      capture rather than on a number nothing here derives.
#
#      THE HEADER OFFSETS ARE FIXED BY TASK 2's ONE-SECTION LAYOUT (verified
#      against the artifact this session with an independent PE reader): the
#      optional header starts at 0x58 and the single section table entry at
#      0x148. They are constants of THIS emitter, not of PE, and a second
#      section would move the section-table offsets — which is why the leg
#      re-reads NumberOfSections, Magic AND SizeOfOptionalHeader off the
#      artifact before it patches anything, and why every patch below names the
#      value it expects to find (`u32was`/`hexwas`). "The offset fits" is not
#      "the offset is right"; see img_patch's header for the row that was
#      measured passing on a patch that landed in padding.
# =============================================================================
# PE32+ field offsets in an --emit=uefi artifact, one section, e_lfanew = 0x40.
UEFI_OFF_NSECTIONS=70       # 0x46 u16
UEFI_OFF_MACHINE=68         # 0x44 u16
UEFI_OFF_SIZEOFOPTHDR=84    # 0x54 u16
UEFI_OFF_MAGIC=88           # 0x58 u16
UEFI_OFF_ENTRY=104          # 0x68 u32
UEFI_OFF_SIZEOFIMAGE=144    # 0x90 u32
UEFI_OFF_SUBSYSTEM=156      # 0x9C u16
UEFI_OFF_NUMRVA=196         # 0xC4 u32
UEFI_OFF_VIRTUALSIZE=336    # 0x150 u32
UEFI_OFF_SECTCHARS=364      # 0x16C u32
UEFI_OFF_SIZEOFRAWDATA=344  # 0x158 u32
UEFI_SECTCHARS=3758096416   # 0xE0000020 -- read, write, execute, code
leg7() {
    echo "--- L7: x86_64 UEFI application under OVMF (q35) ---"
    UEFI_BATCH_POS=""
    UEFI_LIT="KRUEFI-X86"; UEFI_COMP="3000000016"
    if [ -z "$UEFI_X86_CODE" ]; then
        bad "L7_uefi_x86_boots" "no OVMF firmware found. Tried: $UEFI_X86_TRIED. This gate treats a missing dependency as a counted FAILURE, never a silent pass (install ovmf). The other 9 L7 checks are then reported as SKIP -- measured: 1 FAIL + 9 SKIP here, 1 FAIL + 3 SKIP on L8"
        return
    fi
    cp "$BOOT/uefi_sentinel_x86.kr" "$WORK/uefi_sentinel_x86.kr"
    local img="$WORK/u7.efi" entry
    if ! entry=$(build_uefi x86 "$WORK/uefi_sentinel_x86.kr" "$img"); then
        bad "L7_uefi_x86_boots" "uefi_sentinel_x86.kr did not build as a UEFI application"; return
    fi
    # The mutants are anchored on the ARTIFACT, not on the emitter's source: if
    # this is not a one-section PE32+ with the DOS stub the offsets above assume,
    # every patch below lands somewhere else and the controls test nothing.
    # SizeOfOptionalHeader IS PART OF THIS (Task 3 review, Minor 4): the three
    # section-table offsets (336/344/364) are `0x58 + SizeOfOptionalHeader + k`,
    # so a 240 that became something else moves all three while
    # NumberOfSections and Magic still look right.
    local nsec magic soh vsz
    nsec=$(mb_u32 "$img" "$UEFI_OFF_NSECTIONS") || nsec="READFAIL"
    magic=$(mb_u32 "$img" "$UEFI_OFF_MAGIC") || magic="READFAIL"
    soh=$(mb_u32 "$img" "$UEFI_OFF_SIZEOFOPTHDR") || soh="READFAIL"
    # mb_u32 reads 4 bytes; NumberOfSections, Magic and SizeOfOptionalHeader
    # are u16, so mask.
    if [ "$nsec" = READFAIL ] || [ $(( nsec & 0xFFFF )) != 1 ] \
       || [ "$magic" = READFAIL ] || [ $(( magic & 0xFFFF )) != 523 ] \
       || [ "$soh" = READFAIL ] || [ $(( soh & 0xFFFF )) != 240 ]; then
        bad "L7_uefi_x86_boots" "the artifact is not the one-section PE32+ these offsets assume (NumberOfSections=$nsec Magic=$magic SizeOfOptionalHeader=$soh) -- every control below would patch the wrong bytes"; return
    fi
    # VirtualSize is READ rather than written down: the two rows that name it
    # would otherwise carry a number that goes stale the next time the sentinel
    # changes, which is how `1112` survived into two shipped comments while the
    # artifact said 1136 (Task 3 review, Minor 1). Nothing asserts on the value,
    # so nothing catches it -- deriving it means it cannot be wrong.
    vsz=$(mb_u32 "$img" "$UEFI_OFF_VIRTUALSIZE") || vsz="READFAIL"
    if [ "$vsz" = READFAIL ] || [ "$vsz" -lt 2 ]; then
        bad "L7_uefi_x86_boots" "could not read a plausible VirtualSize ($vsz) -- the fault controls below would be patching it to a value it may already hold"; return
    fi
    # The entry point must NOT already be the section start, or the
    # LOADED_SILENT control below plants a value the artifact already has and
    # tests nothing. (An `--emit=uefi` build of a `_start`-only program really
    # does report entry=4096; this sentinel has functions in front of it.)
    if [ "$entry" = 4096 ]; then
        bad "L7_uefi_x86_boots" "the reported entry is already 4096, the section start -- L7_control_entry_at_section_start_silent would be a no-op patch"; return
    fi
    # ---- the subject, and this leg's positive control -----------------------
    if ! uefi_boot x86 "$img" "x7_pos"; then
        bad "L7_uefi_x86_boots" "the boot did not happen (qemu exit=$BOOT_QEMU_RC): '$(head -c 200 "$UEFI_SER.err")'"; return
    fi
    UEFI_BATCH_POS=$(uefi_verdict "$UEFI_SER" "$UEFI_LIT" "$UEFI_COMP")
    if [ "$UEFI_BATCH_POS" = RAN ]; then
        ok "L7_uefi_x86_boots" "OVMF loaded EFI/BOOT/BOOTX64.EFI off a fat:rw: ESP by the removable-media path and ran it: '$UEFI_LIT' and the computed $UEFI_COMP on COM1, entry RVA $entry (${BOOT_WAITED_TICKS} ticks)"
    else
        bad "L7_uefi_x86_boots" "verdict $UEFI_BATCH_POS, wanted RAN (capture: $UEFI_SER)"
    fi
    # ---- five header rejections --------------------------------------------
    # Subsystem: the field that says "this is an EFI application". 3 is the
    # Windows console subsystem. THE ONE WHOSE STATUS IS `Not Found`, i.e. the
    # one indistinguishable from an empty ESP -- it is evidence only because
    # L7_uefi_x86_boots ran in this same batch, through this same staging.
    if uefi_control L7_control_subsystem_3_not_loaded x86 "$img" x7_sub3 NOT_LOADED \
            "Subsystem 10 -> 3 (Windows console)" "hexwas:$UEFI_OFF_SUBSYSTEM:0a00:0300"; then
        ok "L7_control_subsystem_3_not_loaded" "Subsystem := 3 => NOT_LOADED ('$(uefi_first_match "$UEFI_SER" 'failed to load Boot0001[^[:cntrl:]]*')') -- the status is 'Not Found', the SAME text an empty ESP and a misnamed file produce, so the batch positive above is what makes this a rejection and not a staging bug"
    fi
    if uefi_control L7_control_magic_pe32_not_loaded x86 "$img" x7_magic NOT_LOADED \
            "optional header Magic 0x20b (PE32+) -> 0x10b (PE32)" "hexwas:$UEFI_OFF_MAGIC:0b02:0b01"; then
        if uefi_status_is "$UEFI_SER" "Unsupported"; then
            ok "L7_control_magic_pe32_not_loaded" "Magic := 0x10b => NOT_LOADED, status 'Unsupported' -- a word no missing file can produce, so this row discriminates on its own"
        else
            bad "L7_control_magic_pe32_not_loaded" "NOT_LOADED but not with 'Unsupported': '$(uefi_first_match "$UEFI_SER" 'failed to load Boot0001[^[:cntrl:]]*')'"
        fi
    fi
    if uefi_control L7_control_machine_arm64_not_loaded x86 "$img" x7_mach NOT_LOADED \
            "Machine 0x8664 (AMD64) -> 0xaa64 (ARM64) on X64 firmware" "hexwas:$UEFI_OFF_MACHINE:6486:64aa"; then
        if uefi_status_is "$UEFI_SER" "Unsupported"; then
            ok "L7_control_machine_arm64_not_loaded" "Machine := 0xaa64 => NOT_LOADED, status 'Unsupported' -- the field is read, and a defaulted Machine would not be"
        else
            bad "L7_control_machine_arm64_not_loaded" "NOT_LOADED but not with 'Unsupported': '$(uefi_first_match "$UEFI_SER" 'failed to load Boot0001[^[:cntrl:]]*')'"
        fi
    fi
    # SizeOfOptionalHeader and NumberOfRvaAndSizes must satisfy
    # `SizeOfOptionalHeader - 112 == NumberOfRvaAndSizes * 8`. Patching the
    # count alone (16 -> 8) breaks the relation while leaving both fields
    # individually plausible -- which is what the suite's static row checks and
    # what this row shows the firmware also checks.
    if uefi_control L7_control_rva_count_inconsistent_not_loaded x86 "$img" x7_nrva NOT_LOADED \
            "NumberOfRvaAndSizes 16 -> 8 with SizeOfOptionalHeader still 240" "u32was:$UEFI_OFF_NUMRVA:16:8"; then
        if uefi_status_is "$UEFI_SER" "Unsupported"; then
            ok "L7_control_rva_count_inconsistent_not_loaded" "NumberOfRvaAndSizes := 8 (240-112 != 8*8) => NOT_LOADED, status 'Unsupported'"
        else
            bad "L7_control_rva_count_inconsistent_not_loaded" "NOT_LOADED but not with 'Unsupported': '$(uefi_first_match "$UEFI_SER" 'failed to load Boot0001[^[:cntrl:]]*')'"
        fi
    fi
    if uefi_control L7_control_size_of_image_too_small_not_loaded x86 "$img" x7_szimg NOT_LOADED \
            "SizeOfImage 8192 -> 4096, i.e. smaller than the section it must cover" "u32was:$UEFI_OFF_SIZEOFIMAGE:8192:4096"; then
        if uefi_status_is "$UEFI_SER" "Unsupported"; then
            ok "L7_control_size_of_image_too_small_not_loaded" "SizeOfImage := 4096 (the section ends at 8192) => NOT_LOADED, status 'Unsupported'"
        else
            bad "L7_control_size_of_image_too_small_not_loaded" "NOT_LOADED but not with 'Unsupported': '$(uefi_first_match "$UEFI_SER" 'failed to load Boot0001[^[:cntrl:]]*')'"
        fi
    fi
    # ---- two that LOAD and then fault --------------------------------------
    # These are the pair the plan had misfiled as ignored. They are not
    # rejections: `starting Boot0001` is on the wire, so the firmware mapped and
    # entered the image -- with a section whose contents it was told were 1 byte
    # (or 0 bytes) long. Nothing of ours prints, and the machine faults.
    if uefi_control L7_control_virtual_size_too_small_faults x86 "$img" x7_vsize LOADED_FAULTED \
            "VirtualSize -> 1 (the loader copies one byte of a ${vsz}-byte payload)" "u32was:$UEFI_OFF_VIRTUALSIZE:$vsz:1"; then
        ok "L7_control_virtual_size_too_small_faults" "VirtualSize := 1 => the image LOADS ('starting Boot0001' present) and then faults with nothing of ours on the wire: '$(uefi_first_match "$UEFI_SER" 'X64 Exception Type[^!]*')'"
    fi
    if uefi_control L7_control_size_of_raw_data_zero_faults x86 "$img" x7_srd0 LOADED_FAULTED \
            "SizeOfRawData -> 0 (nothing is copied from the file at all)" "u32was:$UEFI_OFF_SIZEOFRAWDATA:4096:0"; then
        ok "L7_control_size_of_raw_data_zero_faults" "SizeOfRawData := 0 => LOADS and faults: '$(uefi_first_match "$UEFI_SER" 'X64 Exception Type[^!]*')'"
    fi
    # ---- one that LOADS, RUNS AND SAYS NOTHING ------------------------------
    # THE SIXTH OUTCOME. Every other row here lands on one of five verdicts;
    # without this one `LOADED_SILENT` is a branch of uefi_verdict that nothing
    # reaches, and a regression collapsing it into NOT_LOADED or RAN would not
    # red the gate (Task 3 review, Important 2). It is also the arm of the
    # crashed-vs-silent distinction that produced this sub-project's Critical,
    # so leaving it unexercised is exactly the wrong gap to leave.
    #
    # AddressOfEntryPoint := the section start. That is the plan's Step 4 case:
    # the firmware maps the image and calls RVA 0x1000, which is the first
    # FUNCTION of the payload rather than the program's entry, so it returns
    # without ever reaching main. MEASURED: loaded, `starting Boot0001`, zero
    # fault hits, neither marker, control back to BDS.
    if uefi_control L7_control_entry_at_section_start_silent x86 "$img" x7_ent0 LOADED_SILENT \
            "AddressOfEntryPoint $entry -> 4096 (the section start, i.e. the first function and not the entry)" "u32was:$UEFI_OFF_ENTRY:$entry:4096"; then
        ok "L7_control_entry_at_section_start_silent" "entry := 4096 => the image LOADS and STARTS ('starting Boot0001' on the wire), faults NOWHERE, prints NEITHER marker and returns to BDS -- the one outcome no other row here reaches"
    fi
    # ---- the asymmetry that makes L8's printed-then-faulted row a control ----
    # Same mutation, other arch. Clearing the write bit is fatal on arm64 and
    # not on x86_64, which is the correction Task 2 made to the derivation
    # reference ("arm64 needs a writable .text" is too broad -- the image loads
    # and executes; the abort is on the STORE). Without this row, L8's fault
    # could be "any change to the characteristics word breaks the load".
    #
    # THE ONLY ROW HERE WHOSE EXPECTED VERDICT IS THE PRISTINE ONE, which makes
    # it the only one a mislocated patch leaves GREEN -- measured, by pointing
    # UEFI_OFF_SECTCHARS at inert padding: it went on passing and went on
    # printing the claim below, which at that point was false. `u32was` is what
    # closes it: name the old value and a wrong offset becomes a refusal that
    # uefi_control reports as "the control never ran". Do not weaken it back to
    # `u32`; there is no verdict this row could compare against instead.
    if uefi_control L7_control_read_only_section_still_runs x86 "$img" x7_ro RAN \
            "section characteristics 0xE0000020 -> 0x60000020 (write bit cleared)" "u32was:$UEFI_OFF_SECTCHARS:$UEFI_SECTCHARS:1610612768"; then
        ok "L7_control_read_only_section_still_runs" "write bit cleared (the old value 0xE0000020 was asserted at the patch site, so this is that byte and not another) => x86_64 STILL RUNS ('$UEFI_LIT' and $UEFI_COMP) -- the same change that makes the arm64 twin abort on its store"
    fi
}

# =============================================================================
# L8 — arm64 UEFI APPLICATION under AAVMF (`virt`). Four boots, and the fourth
#      is the reason the verdict function has six outcomes rather than five.
#
#      MEASURED, this session:
#        pristine                                : RAN  (KRUEFI-A64, 4000000016)
#        Subsystem 10 -> 3                       : NOT_LOADED, `Not Found`
#        VirtualSize -> 1                        : LOADED_FAULTED, Synchronous
#                                                  Exception, nothing printed
#        characteristics -> 0x60000020           : PRINTED_THEN_FAULTED --
#          KRUEFI-A64 and 4000000016 on the PL011, THEN
#          `Synchronous Exception at 0x000000004CB573E0`
#
#      THE LAST TWO ARE A PAIR AND MUST BOTH STAY. One faults having printed
#      nothing and one faults having printed everything; a verdict function that
#      cannot tell them apart passes exactly one of the two, whichever way it is
#      wrong. Together they pin the ordering in uefi_verdict from both sides.
#
#      WHY THE arm64 LEG IS THE SHORT ONE. Its firmware costs ~5.3 s to reach
#      the sentinel against OVMF's ~1.4 s (measured, both), so the five
#      header-rejection controls live on L7 where they are four times cheaper.
#      What CANNOT move is anything about the write bit: on x86_64 the read-only
#      section runs (L7's last row), so the printed-then-faulted shape does not
#      exist there.
# =============================================================================
leg8() {
    echo "--- L8: arm64 UEFI application under AAVMF (virt) ---"
    UEFI_BATCH_POS=""
    UEFI_LIT="KRUEFI-A64"; UEFI_COMP="4000000016"
    if [ -z "$UEFI_A64_CODE" ]; then
        bad "L8_uefi_a64_boots" "no AAVMF firmware found. Tried: $UEFI_A64_TRIED. This gate treats a missing dependency as a counted FAILURE, never a silent pass (install qemu-efi-aarch64). The other 3 L8 checks are then reported as SKIP"
        return
    fi
    cp "$BOOT/uefi_sentinel_a64.kr" "$WORK/uefi_sentinel_a64.kr"
    local img="$WORK/u8.efi" entry
    if ! entry=$(build_uefi a64 "$WORK/uefi_sentinel_a64.kr" "$img"); then
        bad "L8_uefi_a64_boots" "uefi_sentinel_a64.kr did not build as a UEFI application"; return
    fi
    # Same pre-flight as L7, SizeOfOptionalHeader included -- see that leg for
    # why each of the three is here rather than assumed.
    local nsec machine soh vsz
    nsec=$(mb_u32 "$img" "$UEFI_OFF_NSECTIONS") || nsec="READFAIL"
    machine=$(mb_u32 "$img" "$UEFI_OFF_MACHINE") || machine="READFAIL"
    soh=$(mb_u32 "$img" "$UEFI_OFF_SIZEOFOPTHDR") || soh="READFAIL"
    if [ "$nsec" = READFAIL ] || [ $(( nsec & 0xFFFF )) != 1 ] \
       || [ "$machine" = READFAIL ] || [ $(( machine & 0xFFFF )) != 43620 ] \
       || [ "$soh" = READFAIL ] || [ $(( soh & 0xFFFF )) != 240 ]; then
        bad "L8_uefi_a64_boots" "the artifact is not the one-section AArch64 PE32+ these offsets assume (NumberOfSections=$nsec Machine=$machine SizeOfOptionalHeader=$soh)"; return
    fi
    vsz=$(mb_u32 "$img" "$UEFI_OFF_VIRTUALSIZE") || vsz="READFAIL"
    if [ "$vsz" = READFAIL ] || [ "$vsz" -lt 2 ]; then
        bad "L8_uefi_a64_boots" "could not read a plausible VirtualSize ($vsz)"; return
    fi
    # ---- the subject, and this leg's positive control -----------------------
    if ! uefi_boot a64 "$img" "a8_pos"; then
        bad "L8_uefi_a64_boots" "the boot did not happen (qemu exit=$BOOT_QEMU_RC): '$(head -c 200 "$UEFI_SER.err")'"; return
    fi
    UEFI_BATCH_POS=$(uefi_verdict "$UEFI_SER" "$UEFI_LIT" "$UEFI_COMP")
    if [ "$UEFI_BATCH_POS" = RAN ]; then
        ok "L8_uefi_a64_boots" "AAVMF loaded EFI/BOOT/BOOTAA64.EFI off a fat:rw: ESP and ran it: '$UEFI_LIT' and the computed $UEFI_COMP on the PL011, entry RVA $entry (${BOOT_WAITED_TICKS} ticks)"
    else
        bad "L8_uefi_a64_boots" "verdict $UEFI_BATCH_POS, wanted RAN (capture: $UEFI_SER)"
    fi
    # ---- the rejection whose status is the ambiguous one --------------------
    if uefi_control L8_control_subsystem_3_not_loaded a64 "$img" a8_sub3 NOT_LOADED \
            "Subsystem 10 -> 3 (Windows console)" "hexwas:$UEFI_OFF_SUBSYSTEM:0a00:0300"; then
        ok "L8_control_subsystem_3_not_loaded" "Subsystem := 3 => NOT_LOADED ('$(uefi_first_match "$UEFI_SER" 'failed to load Boot0001[^[:cntrl:]]*')') -- measured byte-identical to an empty ESP and to a misnamed file on this firmware, so L8_uefi_a64_boots in this same batch is the entire reason it counts"
    fi
    # ---- faulted having printed NOTHING ------------------------------------
    if uefi_control L8_control_virtual_size_too_small_faults a64 "$img" a8_vsize LOADED_FAULTED \
            "VirtualSize $vsz -> 1" "u32was:$UEFI_OFF_VIRTUALSIZE:$vsz:1"; then
        ok "L8_control_virtual_size_too_small_faults" "VirtualSize := 1 => LOADS and faults with NOTHING of ours on the wire: '$(uefi_first_match "$UEFI_SER" 'Synchronous Exception at [0-9A-Fa-fx]*')'"
    fi
    # ---- faulted having printed EVERYTHING: the six-outcome control ---------
    # THIS ROW IS WHY uefi_verdict IS NOT FIVE OUTCOMES. Clearing the section's
    # write bit leaves an image that loads, runs, prints its literal AND its
    # computed value, and then aborts on `usink = v`. Score RAN before checking
    # for a fault and this is a green run of a machine that crashed; score
    # LOADED_FAULTED first and the two arm64 fault rows become the same row.
    if uefi_control L8_control_read_only_section_printed_then_faulted a64 "$img" a8_ro PRINTED_THEN_FAULTED \
            "section characteristics 0xE0000020 -> 0x60000020 (write bit cleared)" "u32was:$UEFI_OFF_SECTCHARS:$UEFI_SECTCHARS:1610612768"; then
        ok "L8_control_read_only_section_printed_then_faulted" "write bit cleared => '$UEFI_LIT' AND $UEFI_COMP reach the wire and THEN '$(uefi_first_match "$UEFI_SER" 'Synchronous Exception at [0-9A-Fa-fx]*')' -- a RAN-first verdict scores this as success and a FAULTED-first one loses it into the row above; both red here"
    fi
}

# =============================================================================
# THE RESET-VECTOR HALF (sub-project E). Everything from here to the rosters is
# L9.
# =============================================================================
# WHAT IS DIFFERENT ABOUT THIS LEG, in one sentence: L0-L6 hand QEMU an artifact
# and QEMU is the loader, L7/L8 hand a FIRMWARE an ESP and edk2 is the loader --
# and L9 has NO LOADER AT ALL. The artifact IS the firmware: `-bios <image>` maps
# its 65536 bytes at 0xFFFF0000 and the CPU comes out of reset fetching from
# 0xFFFFFFF0, i.e. from the last 16 bytes of the file. Everything that runs
# afterwards is bytes this compiler emitted, starting in 16-bit real mode.
#
# UNTIL THIS BLOCK EXISTED THE ONLY RECORD OF THAT BOOT WAS PROSE IN SUB-PROJECT
# E's TASK 2 REPORT -- the same debt L7/L8 discharged for the UEFI boots, and the
# reason the header at the top of this file says a result that lives only in a
# report is one refactor away from being unverified.
#
# WHAT A GREEN L9 CLAIMS, and nothing more: a `--reset-vector` image built by
# this compiler takes an emulated x86_64 from the reset vector through protected
# mode into long mode and runs a KernRift program there, under QEMU on the
# machine that ran the gate. NOT real hardware and NOT a real chipset -- and the
# distinction is sharper here than anywhere else in this file, because the region
# this image is mapped into is exactly the one a real board write-protects and
# shadow-copies.
#
# THE FOUR SENTINELS ARE THE WHOLE INSTRUMENT, and each letter is a distinct
# claim about a mode transition rather than decoration:
#   R  the reset vector ran: real mode, COM1 programmed 8N1
#   P  protected mode reached: CR0.PE set and the 32-bit far jump taken
#   L  long mode reached: PAE + EFER.LME + CR0.PG and the 64-bit far jump taken
#   <computed>  the PAYLOAD ran: sentinel_x86.kr's 2000000007 + 9, printed by
#      KernRift code that was COPIED from the BIOS region down to 0x100000
# `rv_verdict` below decodes a capture into one of six names; the positive row
# asserts the full `RPL<computed>` and no row asserts a prefix by grep.
#
# TRAPS, ALL MEASURED ON THIS MACHINE IN THIS SESSION, none inherited. Two of
# them are controls that were PROPOSED for this leg and are worthless:
#
#   * A ZEROED RESET JMP BOOTS NORMALLY. `00 00 00` at 0xFFF0 is not "the CPU
#     goes nowhere": real-mode IP wraps within CS, so the guest walks the 13
#     zero bytes of padding off the end of the segment, wraps to offset 0 and
#     RE-ENTERS THE STAGE. Measured: `RPL2000000016`, byte-identical to
#     pristine. The control here plants `EB FE` (`jmp .`) instead, which is
#     measured SILENT with RIP parked at 0xfff0.
#   * `KENTOFF + 4` IS BYTE-IDENTICAL TO PRISTINE on the wire and was measured
#     so. The control here re-points the call at a NAMED target -- a landing pad
#     this script plants at a derived offset inside the payload -- and asserts
#     the guest parks ON it.
#   * `-no-reboot` CHANGES WHAT THE 1 GiB CONTROL LOOKS LIKE, and boot_run
#     passes it on every x86 boot. Task 2 measured `RPRPRPRP...` for that mutant
#     on a bare command line, because the triple fault RESETS the CPU back into
#     the stage. Under this gate's `-no-reboot` the same image gives exactly
#     `RP` and QEMU EXITS BY ITSELF -- both measured here, same image, the flag
#     the only difference. `rv_verdict` accepts either shape under one name,
#     because what discriminates the map fault is that **`L` NEVER PRINTS**, not
#     the tail of the capture. A control that grepped for a capture ENDING in
#     `RP` would pass on a correct compiler too (tests/run_tests.sh:9116 carries
#     the same warning).
#   * THE RAM CEILING IS NOT THE MAP CEILING. `--stack-top` is validated against
#     the 4 GiB identity map, and the compiler cannot know how much RAM the
#     machine has, so a stack top inside the map but outside INSTALLED RAM is
#     accepted and faults on the payload's first push. Measured, same image:
#     `--stack-top=0x80000000` gives the full sequence at `-m 4096` and `RPL`
#     with no sentinel at `-m 128`. That is the two-sided evidence
#     L9_stack_top_above_2_31_boots asserts. (Task 2's report calls this shape
#     `RPLRPLRPL...`; that was measured without `-no-reboot`. Same fault, and
#     `rv_verdict` names both -- see its header.)
#
# THE PAYLOAD-REGION LANDING PAD IS A TEST-TIME PATCH AND HAS TO BE. A compiler
# cannot plant `hlt; jmp .` inside its own payload without corrupting the
# payload, so Task 2 deliberately did not -- it published `payoff`/`paylen`/
# `kentoff` so that THIS file can. Same shape as L1's zeroed-payload control:
# zero the payload, plant the pad at the address the stage's call transfers to,
# and require the guest to PARK ON IT. Without the pad, zeroes decode as
# `add %al,(%rax)`, which is self-modifying at the address it is executing; L1's
# header records the measurement that killed that idea (one survivor in twelve
# runs, then 0 in 40).
#
# WHY THERE IS NO `PAYLEN := 0` ROW (the spec's §7 forces an explicit choice).
# DROPPED, as subsumed by L9_control_zeroed_payload. With the copy suppressed
# nothing is written to 0x100000 at all, so the landing pad -- which lives in the
# UNCOPIED payload region -- never reaches the guest, and the call lands in
# uninitialised RAM. The only assertion left would be "no sentinel", i.e. an
# absence, and the row that already exists makes the same claim (the sentinel
# comes from the copied payload) with a POSITIVE observable: a parked RIP on a
# known pad. Asserting `0x100000` over QMP was the alternative the spec offers;
# it would be asserting the CONTENTS of guest RAM, which this gate has no reader
# for and which says nothing the parked PC does not.
#
# THE SOURCE IS L1's SENTINEL, unchanged and uncopied: the same
# `tests/target_none/boot/sentinel_x86.kr`, so `2000000016` here and in L1 are
# the same program reached two completely different ways -- multiboot `-kernel`
# there, the reset vector here.

# The program under test is L1's, so the computed value is L1's.
RV_SENTINEL=2000000016
# --stack-top for the ordinary rows. NOT $X86_STACK_TOP's value by accident:
# 0x90000 is below the payload's 0x100000 base and inside the low 640 KiB, which
# is what Task 2's own smoke boots used.
RV_STACK_TOP=0x90000
# The ≥ 2^31 row. This is the value the 10-byte `movabs` exists for: the 7-byte
# `mov $imm32,%rsp` the reference stage uses SIGN-EXTENDS, so this value would
# become 0xFFFFFFFF80000000 -- outside the identity map, i.e. a fault on the
# payload's first push. Task 2 asserted that statically and could not boot it;
# this row boots it.
RV_STACK_TOP_HI=0x80000000
# The `-m` that row needs, and the `-m` that proves it needs it. See the RAM
# trap above.
RV_HI_RAM=4096
RV_LOW_RAM=128
# The batch's positive control, set by leg9 from its FIRST boot -- the pristine
# artifact -- and read by every control. "" until set, so a control that runs
# before any positive fails closed. Same rule as UEFI_BATCH_POS: a mutant's
# rejection is evidence only in a batch where something else got through.
RV_BATCH_POS=""
rv_batch_positive() { [ "$RV_BATCH_POS" = RPL_SENTINEL ]; }

# Build a `--reset-vector` image and echo `<payoff> <paylen> <kentoff> <stack>`.
#   build_reset_vector <src> <out> <stack-top>
#
# ITS OWN PARSER, NOT build_image's. Two lines are printed, not one:
#     image: arch=x86_64 entry=0 filesz=65536 memsz=65536 load=0
#     reset-vector: payoff=304 paylen=1016 kentoff=676 stack=589824
# and build_image's `sed -n 's/^image: …'` cannot see the second one at all --
# it would silently return the entry from the first while every number this leg
# actually patches with went unread. build_uefi is a separate function for
# exactly the same reason; see its header.
#
# EVERYTHING build_image ASSERTS IS ASSERTED HERE, for its reasons: exit 0, a
# parsable line, and on-disk size == the reported filesz, because the report is
# printed BEFORE the file is written and codegen ignores file_write's status.
# `--load-addr` is NOT passed and must not be: it is REFUSED under
# `--reset-vector` (the payload's base is a fixed 0x100000), which is why this
# cannot be a fifth argument to build_image either.
build_reset_vector() {
    local src="$1" out="$2" stop="$3"
    local log="$out.rep"
    rm -f "$out"
    if ! "$KRC" --arch=x86_64 --target=none --emit=image --reset-vector \
                --stack-top="$stop" "$src" -o "$out" >"$log" 2>&1; then
        echo "  build_reset_vector: $KRC exited nonzero for $src --stack-top=$stop (see $log)" >&2
        return 1
    fi
    local filesz payoff paylen kentoff stack ondisk
    filesz=$(sed -n 's/^image: .* filesz=\([0-9][0-9]*\) .*$/\1/p' "$log")
    payoff=$(sed -n 's/^reset-vector: payoff=\([0-9][0-9]*\) .*$/\1/p' "$log")
    paylen=$(sed -n 's/^reset-vector: .* paylen=\([0-9][0-9]*\) .*$/\1/p' "$log")
    kentoff=$(sed -n 's/^reset-vector: .* kentoff=\([0-9][0-9]*\) .*$/\1/p' "$log")
    stack=$(sed -n 's/^reset-vector: .* stack=\([0-9][0-9]*\).*$/\1/p' "$log")
    if [ -z "$filesz" ] || [ -z "$payoff" ] || [ -z "$paylen" ] || [ -z "$kentoff" ] || [ -z "$stack" ]; then
        echo "  build_reset_vector: no parsable 'image:'+'reset-vector:' pair for $src (see $log)" >&2
        return 1
    fi
    ondisk=$(stat -c%s "$out" 2>/dev/null)
    if [ "$ondisk" != "$filesz" ]; then
        echo "  build_reset_vector: report claims filesz=$filesz but $out is ${ondisk:-ABSENT} B" >&2
        return 1
    fi
    # The stage echoes back the --stack-top it was given; if it does not, every
    # row below is testing a different machine from the one it names.
    if [ "$stack" != "$(( stop ))" ]; then
        echo "  build_reset_vector: asked for --stack-top=$stop ($(( stop ))) but the report says stack=$stack" >&2
        return 1
    fi
    echo "$payoff $paylen $kentoff $stack"
}

# EVERY PATCH SITE L9 USES, LOCATED BY ANCHOR AND CROSS-CHECKED AGAINST THE
# REPORT. Echoes `<halt> <payoff-imm> <movsl-count> <pd-count> <pdpt1> <pdpt2>
# <pdpt3> <gdt-flags>` as decimal FILE OFFSETS (except <movsl-count>, which is a
# value), or `ERR:<why>` on stdout with a nonzero status.
#   rv_sites <img> <payoff> <paylen> <kentoff>
#
# NOT ONE HARDCODED OFFSET, and that is not tidiness. The gate cannot edit the
# emitter's source, so the 1 GiB mutant has to be built by byte-patching the
# emitted image -- and a written-down offset there rots on the first instruction
# added to the stage, with a TRIPLE FAULT as the symptom rather than a
# diagnostic. Every site below is found by searching for the byte pattern of the
# instruction that owns it, the way `halt_offset_x86` already does, and a search
# that matches zero times or more than once is a loud failure that stops the leg.
#
# THE ANCHORS ARE INSTRUCTION ENCODINGS, so a change to the value an instruction
# carries changes the pattern and the search finds nothing -- which is the
# fail-closed direction. Specifically:
#   halt        the unique `f4 eb fd`, required to be preceded by
#               `48 c7 c0 <imm32>` + `ff d0` -- i.e. the stage's
#               `mov $(0x100000+KENTOFF),%rax; call *%rax; hlt; jmp .`. The
#               immediate is the KENTOFF site, at halt-6.
#   payoff-imm  anchored on `bf 00 00 10 00` + `b9` (`mov $0x100000,%edi` then
#               `mov $count,%ecx`), with `be` required 5 bytes in front: the
#               copy block's `mov $(0xFFFF0000+PAYOFF),%esi`.
#   pd-count    anchored on `bf 00 30 00 00 b8 83 00 00 00 b9` -- PD0's address,
#               the 2 MiB page attribute, and the loop count's opcode.
#   pdpt1..3    the three `movl $0x<n>003,0x<2008|2010|2018>` stores, each its
#               own unique 10-byte encoding.
#   gdt-flags   the whole 32-byte GDT -- null, 32-bit code, data, 64-bit code --
#               matched as one literal, so the site returned is the FLAGS byte
#               of GDT[1] in a table whose other three entries are already known
#               to be what the stage emitted. The returned offset is gdt+12,
#               the u32 whose high half carries that flags nibble.
#
# AND THE REPORT IS CHECKED AGAINST THE ARTIFACT HERE, in both directions:
# `0x100000+kentoff` must be the immediate the call actually uses,
# `0xFFFF0000+payoff` must be the address the copy actually reads from, and
# `ceil(paylen/4)` must be the dword count it actually copies. Those three
# numbers are what every patch below is computed from; taking them on trust from
# a printed line would make a mislocated landing pad look like a silent guest.
rv_sites() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
payoff, paylen, kentoff = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])


def die(msg):
    print("ERR:" + msg)
    sys.exit(1)


def uniq(pat, what):
    o = [i for i in range(len(d) - len(pat) + 1) if d[i:i + len(pat)] == pat]
    if len(o) != 1:
        die("%s: the byte pattern %s matches %d times in the image, not exactly 1"
            % (what, pat.hex(), len(o)))
    return o[0]


halt = uniq(bytes.fromhex("f4ebfd"), "the stage's landing pad 'hlt; jmp .'")
if halt < 9 or d[halt - 9:halt - 6] != bytes.fromhex("48c7c0") \
        or d[halt - 2:halt] != bytes.fromhex("ffd0"):
    die("the halt at %d is not preceded by 'mov $imm32,%%rax; call *%%rax' (found %s)"
        % (halt, d[max(0, halt - 9):halt].hex()))
kimm = halt - 6
got = struct.unpack_from("<I", d, kimm)[0]
if got != 0x100000 + kentoff:
    die("the call transfers to 0x%x, but the report says kentoff=%d, i.e. 0x%x"
        % (got, kentoff, 0x100000 + kentoff))
m = uniq(bytes.fromhex("bf00001000") + b"\xb9",
         "the payload copy 'mov $0x100000,%edi; mov $count,%ecx'")
if m < 5 or d[m - 5] != 0xBE:
    die("the copy block at %d is not preceded by 'mov $imm32,%%esi'" % m)
pimm = m - 4
got = struct.unpack_from("<I", d, pimm)[0]
if got != 0xFFFF0000 + payoff:
    die("the copy reads from 0x%x, but the report says payoff=%d, i.e. 0x%x"
        % (got, payoff, 0xFFFF0000 + payoff))
cnt = struct.unpack_from("<I", d, m + 6)[0]
if cnt != (paylen + 3) // 4:
    die("'rep movsl' copies %d dwords, but the report says paylen=%d, i.e. %d dwords"
        % (cnt, paylen, (paylen + 3) // 4))
pd = uniq(bytes.fromhex("bf00300000b883000000b9"),
          "the PD fill loop 'mov $0x3000,%edi; mov $0x83,%eax; mov $count,%ecx'")
pdcnt = pd + 11
n = struct.unpack_from("<I", d, pdcnt)[0]
if n != 2048:
    die("the PD loop count is %d, not the 2048 entries x 2 MiB = 4 GiB this leg's "
        "1 GiB control mutates" % n)
pdpt = []
for slot, (a, v) in enumerate(((0x2008, 0x4003), (0x2010, 0x5003), (0x2018, 0x6003)), 1):
    o = uniq(b"\xc7\x05" + struct.pack("<II", a, v), "the PDPT[%d] store" % slot)
    pdpt.append(o + 6)
# The GDT, matched WHOLE. Anchoring on GDT[1] alone would match a 16-byte
# window that says nothing about which table it is in; the 32-byte literal
# below is null + 32-bit code + data + 64-bit code, i.e. the stage's own table
# and no other, so gdt+12 is GDT[1]'s flags/limit-high dword by construction.
gdt = uniq(bytes.fromhex("0000000000000000"      # 0x00 null
                         "ffff0000009acf00"      # 0x08 32-bit code, ring 0
                         "ffff00000092cf00"      # 0x10 data
                         "ffff0000009aaf00"),    # 0x18 64-bit code, ring 0
           "the stage's four-entry GDT")
gdtfl = gdt + 12
if struct.unpack_from("<I", d, gdtfl)[0] != 0x00CF9A00:
    die("GDT[1]'s high dword at %d is 0x%08x, not 0x00CF9A00" % (gdtfl, struct.unpack_from("<I", d, gdtfl)[0]))
if gdt >= payoff:
    die("the GDT at %d is not inside the stage (payoff=%d)" % (gdt, payoff))
if halt >= payoff:
    die("the halt at %d is not inside the stage (payoff=%d) -- it was found in the "
        "payload, so it is not the stage's landing pad" % (halt, payoff))
if payoff + paylen > len(d) - 16:
    die("the payload [%d,%d) overruns the reset vector at %d" % (payoff, payoff + paylen, len(d) - 16))
print("%d %d %d %d %d %d %d %d" % (halt, pimm, cnt, pdcnt, pdpt[0], pdpt[1], pdpt[2], gdtfl))
PY
}

# DECODE ONE CAPTURE INTO EXACTLY ONE VERDICT.  rv_verdict <serial file>
#
# The capture is flattened (CR and LF removed) and matched WHOLE, never grepped
# for a prefix. SEVEN names -- six verdicts and one harness state:
#   SILENT         nothing reached the wire at all
#   R              one or more `R`s and NO `P` and NO `L`, with any non-sentinel
#                  bytes between them: real mode ran, protected mode did not.
#                  The GDT-width fault, under either reboot policy.
#                  THE "ANY NON-SENTINEL BYTES" PART IS NOT SLACK, IT IS THE
#                  MEASUREMENT. Task 2's report and this leg's brief both call
#                  this shape a bare `R` / `RRRR...`; the capture on this machine
#                  is `R\x10` and `(R\x10)+` -- 52794 exact pairs in 6 s without
#                  `-no-reboot`, and nothing else in the file. A stage executing
#                  its 32-bit half as 16-bit code still reaches an `out` to COM1
#                  with 0x10 in %al. So a whole-string `R+` scores the real
#                  artifact `UNEXPECTED` -- measured, it did, on the first green
#                  run of the control below. What the row is entitled to claim is
#                  that **`P` NEVER PRINTED**, and that is what this matches;
#                  pinning the garbage byte itself would make a QEMU upgrade red
#                  a row about the compiler.
#   RP             `RP` one or more times: **`L` NEVER PRINTED**. The map fault,
#                  under either reboot policy -- see this block's header.
#   RPL            exactly one `RPL`: all three modes, and the payload printed
#                  nothing
#   RPL_LOOP       `RPL` two or more times: the payload FAULTED and the machine
#                  reset. The RAM-ceiling shape.
#   RPL_SENTINEL   exactly `RPL` + the computed sentinel: the full sequence
#   UNEXPECTED:<flattened capture, truncated>
# ...and the seventh, which is not a verdict about a guest at all:
#   HARNESS_ERROR:no-capture   the capture file could not be opened, i.e. qemu
#                  never created it. Emitted INSTEAD OF `SILENT`, because "no
#                  boot happened" and "the boot printed nothing" are different
#                  claims and every control here is entitled to the second one.
#                  It fails closed -- no row accepts it -- so this header saying
#                  "six" was a documentation defect and not a live hole.
#
# `R` IS EXPECTED BY EXACTLY ONE ROW, L9_control_gdt_08_64bit_no_protected_mode,
# and by nothing else -- so it is still the bucket that keeps Task 2's measured
# symptom for a 64-bit `0x08` descriptor from reading as a prefix of a passing
# capture. It was a pure fail bucket until that control existed.
#
# `RPL_LOOP` IS UNREACHABLE UNDER THIS GATE AND IS KEPT ANYWAY, which is a
# deliberate choice and not an oversight. boot_run passes `-no-reboot` on every
# x86 boot, so a triple-faulting guest EXITS instead of re-running the stage:
# measured, the stack-outside-RAM case gives `RPL` here where Task 2's bare
# command line gave `RPLRPLRPL...`. The name stays so that a future leg (or a
# reader reproducing a capture by hand, without the flag) cannot have the reboot
# shape scored as the single-pass `RPL` that L9_control_zeroed_payload expects.
# The same reasoning gives the map fault ONE name covering both shapes -- see
# `RP` above: there the discriminator is the absent `L`, not the repetition.
#
# WHOLE-STRING MATCHING IS THE POINT. Every letter is a separate claim about a
# mode transition, so "the capture contains RPL" is not the same statement as
# "the capture IS RPL followed by the sentinel" -- and it is the second one the
# positive row is entitled to make.
rv_verdict() {
    python3 - "$1" "$RV_SENTINEL" <<'PY'
import re, sys
try:
    s = open(sys.argv[1], "rb").read()
except OSError:
    print("HARNESS_ERROR:no-capture")
    sys.exit(0)
s = s.replace(b"\r", b"").replace(b"\n", b"").decode("latin-1")
sent = sys.argv[2]
if s == "":
    print("SILENT")
elif s == "RPL" + sent:
    print("RPL_SENTINEL")
elif s == "RPL":
    print("RPL")
elif re.fullmatch(r"(RP)+", s):
    print("RP")
elif re.fullmatch(r"(RPL)+", s):
    print("RPL_LOOP")
elif re.fullmatch(r"(R[^RPL]*)+", s):
    print("R")
else:
    print("UNEXPECTED:" + s[:120])
PY
}

# One `-bios` boot. THE WHOLE COMMAND LINE IS `-bios <image> -net none` plus
# whatever `-m` the caller needs: no `-kernel`, no `-device loader`, no load
# address, no entry offset, and no firmware of anyone else's. `-net none` is
# carried over from L7/L8's measurement (without it QEMU can spend its window on
# PXE); there is no option ROM here to do that, and it costs nothing.
# $1 image, $2 serial, $3 expect (see boot_run), $4.. extra qemu args.
rv_boot_qmp() {
    local img="$1" ser="$2" expect="$3"; shift 3
    PARKED_PC=QMPFAIL
    boot_run_qmp x86 "$ser" "$expect" -bios "$img" -net none "$@"
}
rv_boot() {
    local img="$1" ser="$2" expect="$3"; shift 3
    PARKED_PC=NOQMPRUN   # see the PARKED_PC declaration above
    boot_run x86 "$ser" "$expect" -bios "$img" -net none "$@"
}

# =============================================================================
# L9 — x86_64 RESET-VECTOR BOOT (`-bios <image>`, nothing else). Eight boots:
#      the subject, five controls, and the ≥ 2^31 stack top from both sides.
#      See the block comment above for what each sentinel letter claims and for
#      the two proposed controls that were measured worthless.
# =============================================================================
leg9() {
    echo "--- L9: x86_64 reset-vector boot (-bios <image>, no loader at all) ---"
    RV_BATCH_POS=""
    cp "$BOOT/sentinel_x86.kr" "$WORK/rv_sentinel_x86.kr"
    local img="$WORK/rv.img" rep payoff paylen kentoff stack
    if ! rep=$(build_reset_vector "$WORK/rv_sentinel_x86.kr" "$img" "$RV_STACK_TOP"); then
        bad "L9_reset_vector_report_and_anchors" "sentinel_x86.kr did not build with --reset-vector --stack-top=$RV_STACK_TOP"; return
    fi
    set -- $rep
    payoff="$1"; paylen="$2"; kentoff="$3"; stack="$4"
    # ---- BLOCKING, AND BEFORE THE BOOTS (see L1's note on ordering) ---------
    # Every patch below is computed from payoff/paylen/kentoff, so if any of
    # them is wrong the controls patch inert bytes and their mutants behave like
    # the original. rv_sites is where that is caught, against the artifact.
    local sites halt pimm movsl pdcnt pdpt1 pdpt2 pdpt3 gdtfl
    if ! sites=$(rv_sites "$img" "$payoff" "$paylen" "$kentoff"); then
        bad "L9_reset_vector_report_and_anchors" "$sites"; return
    fi
    set -- $sites
    halt="$1"; pimm="$2"; movsl="$3"; pdcnt="$4"; pdpt1="$5"; pdpt2="$6"; pdpt3="$7"; gdtfl="$8"
    ok "L9_reset_vector_report_and_anchors" "payoff=$payoff paylen=$paylen kentoff=$kentoff stack=$stack, all three cross-checked against the artifact's own immediates (copy source at file offset $pimm, $movsl dwords, call target at $(( halt - 6 ))); the halt is the unique f4ebfd at $halt, the PD loop count at $pdcnt, the three PDPT stores at $pdpt1/$pdpt2/$pdpt3 and GDT[1]'s flags dword at $gdtfl -- every one located by byte pattern, none written down"
    # ---- the subject, and this leg's positive control ------------------------
    # THE FULL SEQUENCE, matched whole. `RPL` + the computed value is four
    # separate claims -- reset vector, protected mode, long mode, and KernRift
    # code running at 0x100000 -- and rv_verdict refuses to let any prefix of it
    # be scored as this.
    local want_pc verdict
    want_pc=$(printf %x $(( 0xFFFF0000 + halt + 1 )))
    if ! rv_boot_qmp "$img" "$WORK/l9_ser.txt" "RPL$RV_SENTINEL"; then
        bad "L9_reset_vector_boots" "the boot did not run (qemu exit=$BOOT_QEMU_RC): '$(head -c 200 "$WORK/l9_ser.txt.err")'"
        bad "L9_halt_parked" "no boot to read a PC from"; return
    fi
    RV_BATCH_POS=$(rv_verdict "$WORK/l9_ser.txt")
    if [ "$RV_BATCH_POS" = RPL_SENTINEL ]; then
        ok "L9_reset_vector_boots" "'-bios $(basename "$img")' and nothing else: RPL$RV_SENTINEL on COM1 -- R at the reset vector in real mode, P in 32-bit protected mode, L in long mode, then the payload copied to 0x100000 computing $RV_SENTINEL (${BOOT_WAITED_TICKS} ticks)"
    else
        bad "L9_reset_vector_boots" "verdict $RV_BATCH_POS, wanted RPL_SENTINEL (capture: $WORK/l9_ser.txt)"
    fi
    # D5, THE RETURN-TO-HALT, and the address the other rows are measured
    # against: `main` returns into the stage's own `hlt; jmp .`, one byte past
    # the `hlt`, at 0xFFFF0000 + the halt this leg located.
    if [ "$PARKED_PC" = "$want_pc" ]; then
        ok "L9_halt_parked" "RIP parked at 0x$want_pc == 0xFFFF0000 + $halt + 1, the stage's own 'hlt; jmp .' -- so main RETURNED into it, and the guest is in long mode at the top of the address space"
    else
        bad "L9_halt_parked" "pc=$PARKED_PC want=$want_pc"
    fi
    # Every control below asserts something about an ABSENT sentinel, so its
    # window must be long enough that a working boot would certainly have
    # printed. Derived from the positive boot just observed, not guessed.
    calibrate_silence
    # ---- control: the 4 GiB identity map ------------------------------------
    # THE HISTORICAL BUG, NOW A PERMANENT PIN. B2's stub maps 1 GiB because its
    # code runs low; this stage runs at 0xFFFF0000, so a 1 GiB map has no
    # translation for the instruction after `mov %eax,%cr0` and the machine
    # triple-faults BEFORE `L`. Built here as a real 1 GiB map, not just a short
    # loop: the count 2048 -> 512 (512 x 2 MiB = 1 GiB) AND the three PDPT
    # entries for the 2nd, 3rd and 4th GiB made not-present.
    # `u32was` names the old value at every one of the four sites, so a
    # mislocated patch is a REFUSAL ("the control never ran") instead of four
    # writes into padding and a mutant that behaves like the original.
    if ! rv_batch_positive; then
        bad "L9_control_map_1gib_no_long_mode" "the batch positive control did NOT run (verdict '$RV_BATCH_POS'), so a mutant's silence is not evidence"
    elif ! img_patch "$img" "$WORK/rv_1gib.img" "u32was:$pdcnt:2048:512" \
            "u32was:$pdpt1:16387:0" "u32was:$pdpt2:20483:0" "u32was:$pdpt3:24579:0"; then
        bad "L9_control_map_1gib_no_long_mode" "could not build the 1 GiB mutant -- the control never ran"
    elif ! rv_boot "$WORK/rv_1gib.img" "$WORK/l9_1gib.txt" SELFEXIT; then
        bad "L9_control_map_1gib_no_long_mode" "the boot did not run (qemu exit=$BOOT_QEMU_RC) -- an absent 'L' proves nothing"
    else
        verdict=$(rv_verdict "$WORK/l9_1gib.txt")
        if [ "$verdict" != RP ]; then
            bad "L9_control_map_1gib_no_long_mode" "verdict $verdict, wanted RP (i.e. 'L' never printed) -- capture: $WORK/l9_1gib.txt"
        elif [ "$BOOT_WAITED_TICKS" -ge "$BOOT_DEADLINE_TICKS" ]; then
            bad "L9_control_map_1gib_no_long_mode" "verdict RP, but qemu never exited (waited the full $BOOT_DEADLINE_TICKS ticks) -- the guest is quiet rather than faulted, which is a different claim"
        else
            ok "L9_control_map_1gib_no_long_mode" "map 4 GiB -> 1 GiB (PD count 512, PDPT[1..3] not present): verdict RP, so R and P reached the wire and **L NEVER DID**; qemu self-exited after ${BOOT_WAITED_TICKS} ticks on the triple fault (-no-reboot). The missing L is the discriminator, not the tail of the capture"
        fi
    fi
    # ---- control: the GDT's own width ---------------------------------------
    # THE SECOND TRIPLE-FAULT CLASS TASK 2 MEASURED, AND UNTIL NOW THE ONLY ONE
    # WITH NO BOOT BEHIND IT. Task 2 found two ways to build a stage that resets
    # and then dies: a map too small for the address the stage runs at (the row
    # above), and a GDT whose 0x08 descriptor is 64-bit rather than 32-bit. The
    # first got a permanent boot control; the second was covered STATICALLY only,
    # by resetvec_stage_decodes in tests/run_tests.sh, which asserts the emitted
    # descriptor's bytes and can say nothing about what the CPU does with them.
    #
    # WHY 0x08 HAS TO BE 32-BIT HERE AND IS 64-BIT IN B2's STUB: this stage is
    # entered in 16-bit real mode, so it needs a 32-bit code segment to enter
    # PROTECTED mode with before it can build the long-mode one. B2's stub is
    # entered by a multiboot loader already in protected mode and needs only the
    # second. Copying B2's table into this stage is therefore a plausible edit
    # with no compile-time symptom, which is what a control is for.
    #
    # ONE u32, THE FLAGS/LIMIT-HIGH DWORD OF GDT[1]: 0x00CF9A00 -> 0x00AF9A00,
    # i.e. the flags nibble C (G=1, D/B=1, L=0) -> A (G=1, D/B=0, L=1) that
    # separates this table's 0x08 from its own 0x18. With EFER.LMA still 0 the
    # L bit is ignored and D/B=0 makes it a 16-BIT code segment, so the 32-bit
    # half of the stage executes as 16-bit garbage and faults BEFORE `P`.
    #
    # MEASURED ON THIS MACHINE, same image, the flag the only difference:
    # `-no-reboot` gives the two bytes `52 10` and qemu EXITS BY ITSELF; without
    # it, `(52 10)` repeated 52794 times (105588 B in 6 s) and nothing else.
    # NOT the bare `R` / `RRRR...` this control's brief and Task 2's report both
    # state -- see rv_verdict's header for why that difference cost the first
    # green run of this row and what the matcher does about it. rv_verdict names
    # both shapes `R`, for the same reason it gives the map fault one name: the
    # discriminator is that `P` NEVER PRINTS, not the tail of the capture.
    if ! rv_batch_positive; then
        bad "L9_control_gdt_08_64bit_no_protected_mode" "the batch positive control did NOT run (verdict '$RV_BATCH_POS'), so a mutant's silence is not evidence"
    elif ! img_patch "$img" "$WORK/rv_gdt64.img" "u32was:$gdtfl:13605376:11508224"; then
        bad "L9_control_gdt_08_64bit_no_protected_mode" "could not widen GDT[1] to 64-bit -- the control never ran"
    elif ! rv_boot "$WORK/rv_gdt64.img" "$WORK/l9_gdt64.txt" SELFEXIT; then
        bad "L9_control_gdt_08_64bit_no_protected_mode" "the boot did not run (qemu exit=$BOOT_QEMU_RC) -- an absent 'P' proves nothing"
    else
        verdict=$(rv_verdict "$WORK/l9_gdt64.txt")
        if [ "$verdict" != R ]; then
            bad "L9_control_gdt_08_64bit_no_protected_mode" "verdict $verdict, wanted R (i.e. 'P' never printed) -- capture: $WORK/l9_gdt64.txt"
        elif [ "$BOOT_WAITED_TICKS" -ge "$BOOT_DEADLINE_TICKS" ]; then
            bad "L9_control_gdt_08_64bit_no_protected_mode" "verdict R, but qemu never exited (waited the full $BOOT_DEADLINE_TICKS ticks) -- the guest is quiet rather than faulted, which is a different claim"
        else
            ok "L9_control_gdt_08_64bit_no_protected_mode" "GDT[1] flags 0xCF -> 0xAF at file offset $gdtfl (32-bit code -> 64-bit code, the width B2's stub uses at the same selector): verdict R, so R reached the wire and **P NEVER DID**; qemu self-exited after ${BOOT_WAITED_TICKS} ticks on the triple fault (-no-reboot)"
        fi
    fi
    # ---- control: the reset vector itself -----------------------------------
    # THE THREE BYTES AT 0xFFFFFFF0 ARE WHAT THE CPU FETCHES FIRST. Their file
    # offset is `filesz - 16`, which is an ARCHITECTURAL fact about `-bios`
    # geometry rather than an emitter constant -- and `hexwas` names the near
    # jump that must be there, so a wrong location is a refusal.
    # `EB FE`, NOT ZEROES: see this block's header for the measurement.
    local rvoff nop_pc
    rvoff=$(( $(stat -c%s "$img") - 16 ))
    nop_pc=fff0
    if ! rv_batch_positive; then
        bad "L9_control_reset_jmp_spins_silent" "the batch positive control did NOT run (verdict '$RV_BATCH_POS'), so silence is not evidence"
    elif ! img_patch "$img" "$WORK/rv_ebfe.img" "hexwas:$rvoff:e90d00:ebfe90"; then
        bad "L9_control_reset_jmp_spins_silent" "could not patch the reset vector at $rvoff -- the control never ran"
    elif ! rv_boot_qmp "$WORK/rv_ebfe.img" "$WORK/l9_ebfe.txt" RUNOUT; then
        bad "L9_control_reset_jmp_spins_silent" "the boot did not run (qemu exit=$BOOT_QEMU_RC) -- silence proves nothing"
    else
        verdict=$(rv_verdict "$WORK/l9_ebfe.txt")
        if [ "$verdict" != SILENT ]; then
            bad "L9_control_reset_jmp_spins_silent" "verdict $verdict, wanted SILENT -- capture: $WORK/l9_ebfe.txt"
        elif [ "$PARKED_PC" != "$nop_pc" ]; then
            bad "L9_control_reset_jmp_spins_silent" "silent, but pc=$PARKED_PC is not 0x$nop_pc (the reset vector) -- where the machine actually is is unaccounted for"
        else
            ok "L9_control_reset_jmp_spins_silent" "reset jmp at file offset $rvoff -> 'jmp .': NOTHING on the wire and the CPU parked at 0x$nop_pc, still in real mode at the reset vector (a ZEROED jmp instead boots normally -- IP wraps within CS and re-enters the stage)"
        fi
    fi
    # ---- control: the sentinel comes from the COPIED PAYLOAD -----------------
    # L1's shape, and it needs the landing pad for L1's reason. The payload
    # region [payoff, payoff+paylen) is zeroed -- EXACTLY that range, because
    # zeroing to EOF would take the reset vector with it -- and `hlt; jmp .` is
    # planted at the offset the stage's call transfers to. The stage is
    # untouched, so R, P and L must still print, and the guest must PARK ON THE
    # PAD at 0x100000 + kentoff + 1.
    # WHAT PARKING THERE PROVES, and it is more than silence: the stage
    # programmed COM1, entered protected mode, ran `rep movsl` over the region
    # this control zeroed, built the 4 GiB map, entered long mode, loaded rsp
    # and transferred to the address its own immediate carries.
    local pad_pc
    pad_pc=$(printf %x $(( 0x100000 + kentoff + 1 )))
    if ! rv_batch_positive; then
        bad "L9_control_zeroed_payload" "the batch positive control did NOT run (verdict '$RV_BATCH_POS'), so this mutant's behaviour is not evidence"
    elif ! img_patch "$img" "$WORK/rv_zero.img" "zeron:$payoff:$paylen" "hex:$(( payoff + kentoff )):f4ebfd"; then
        bad "L9_control_zeroed_payload" "could not build the zeroed image -- the control never ran"
    elif ! rv_boot_qmp "$WORK/rv_zero.img" "$WORK/l9_zero.txt" RUNOUT; then
        bad "L9_control_zeroed_payload" "the boot did not run (qemu exit=$BOOT_QEMU_RC) -- silence proves nothing"
    else
        verdict=$(rv_verdict "$WORK/l9_zero.txt")
        if [ "$verdict" != RPL ]; then
            bad "L9_control_zeroed_payload" "verdict $verdict, wanted RPL (the stage runs, the payload prints nothing) -- capture: $WORK/l9_zero.txt"
        elif [ "$PARKED_PC" != "$pad_pc" ]; then
            bad "L9_control_zeroed_payload" "pc=$PARKED_PC, want 0x$pad_pc (the pad at payload offset $kentoff) -- the guest never reached the copied payload, so the absent sentinel says nothing about where it comes from"
        else
            ok "L9_control_zeroed_payload" "payload [$payoff,$(( payoff + paylen ))) zeroed with a pad at the call target: RPL and no sentinel, parked at 0x$pad_pc -- the stage is intact and the $RV_SENTINEL comes from the payload it copied"
        fi
    fi
    # ---- control: KENTOFF is what the call transfers to ----------------------
    # A NAMED TARGET, NOT A WRONG ONE. `KENTOFF + 4` was measured BYTE-IDENTICAL
    # TO PRISTINE on the wire -- a vacuous control. Here the immediate is
    # re-pointed at a landing pad this script plants at a DERIVED offset inside
    # the payload, and the row asserts the guest parks on that pad: positive
    # evidence about an address, not an inference from quiet.
    # The offset is `paylen - 16`: inside the region `rep movsl` copies, and far
    # enough from the end that the 3-byte pad fits. It must not BE kentoff, or
    # the patch is a no-op -- asserted, not assumed, the same way L7 refuses to
    # plant an entry the artifact already has.
    local alt alt_pc
    alt=$(( paylen - 16 ))
    if ! rv_batch_positive; then
        bad "L9_control_kentoff_steers_the_call" "the batch positive control did NOT run (verdict '$RV_BATCH_POS'), so this mutant's behaviour is not evidence"
    elif [ "$alt" = "$kentoff" ] || [ "$alt" -lt 0 ]; then
        bad "L9_control_kentoff_steers_the_call" "the alternate target paylen-16 = $alt is not a usable second address (kentoff=$kentoff, paylen=$paylen) -- the patch would be a no-op"
    else
        alt_pc=$(printf %x $(( 0x100000 + alt + 1 )))
        if ! img_patch "$img" "$WORK/rv_kent.img" "hex:$(( payoff + alt )):f4ebfd" \
                "u32was:$(( halt - 6 )):$(( 0x100000 + kentoff )):$(( 0x100000 + alt ))"; then
            bad "L9_control_kentoff_steers_the_call" "could not re-point the call immediate at $(( halt - 6 )) -- the control never ran"
        elif ! rv_boot_qmp "$WORK/rv_kent.img" "$WORK/l9_kent.txt" RUNOUT; then
            bad "L9_control_kentoff_steers_the_call" "the boot did not run (qemu exit=$BOOT_QEMU_RC) -- silence proves nothing"
        else
            verdict=$(rv_verdict "$WORK/l9_kent.txt")
            if [ "$verdict" != RPL ]; then
                bad "L9_control_kentoff_steers_the_call" "verdict $verdict, wanted RPL -- capture: $WORK/l9_kent.txt"
            elif [ "$PARKED_PC" != "$alt_pc" ]; then
                bad "L9_control_kentoff_steers_the_call" "pc=$PARKED_PC, want 0x$alt_pc (the pad at payload offset $alt) -- the call did not go where the immediate says"
            else
                ok "L9_control_kentoff_steers_the_call" "call immediate 0x$(printf %x $(( 0x100000 + kentoff ))) -> 0x$(printf %x $(( 0x100000 + alt ))), a pad planted at payload offset $alt: RPL, no sentinel, parked at 0x$alt_pc -- the immediate steers the call, which KENTOFF+4 could not show (byte-identical to pristine)"
            fi
        fi
    fi
    # ---- the >= 2^31 stack top, booted from both sides -----------------------
    # TASK 2 COULD ONLY ASSERT THIS STATICALLY. `--stack-top` >= 2^31 is what
    # forced the 10-byte `movabs $imm64,%rsp`: the reference stage's 7-byte
    # `mov $imm32,%rsp` SIGN-EXTENDS, so this value would land at
    # 0xFFFFFFFF80000000, outside the identity map, and the payload's first push
    # would fault. Only 0x90000 and 0x80000 had ever been booted.
    # TWO BOOTS, BECAUSE ONE IS NOT DISCRIMINATING ENOUGH. At `-m $RV_HI_RAM` the
    # full sequence must appear; at `-m $RV_LOW_RAM` the SAME IMAGE must reach
    # `L` and then die, because 0x80000000 is inside the 4 GiB map but outside
    # 128 MiB of installed RAM. The second boot is what shows rsp really is up
    # there and is really being pushed to -- an rsp the payload never touched
    # would boot at both. It is also the RAM ceiling itself, which the compiler
    # does not and cannot refuse (see docs/LANGUAGE.md).
    local himg="$WORK/rv_hi.img" hrep hpayoff hpaylen hkentoff hstack hsites hhalt hpc
    if ! hrep=$(build_reset_vector "$WORK/rv_sentinel_x86.kr" "$himg" "$RV_STACK_TOP_HI"); then
        bad "L9_stack_top_above_2_31_boots" "the --stack-top=$RV_STACK_TOP_HI build failed -- the row never ran"; return
    fi
    set -- $hrep
    hpayoff="$1"; hpaylen="$2"; hkentoff="$3"; hstack="$4"
    if ! hsites=$(rv_sites "$himg" "$hpayoff" "$hpaylen" "$hkentoff"); then
        bad "L9_stack_top_above_2_31_boots" "$hsites"; return
    fi
    set -- $hsites
    hhalt="$1"
    hpc=$(printf %x $(( 0xFFFF0000 + hhalt + 1 )))
    if ! rv_boot_qmp "$himg" "$WORK/l9_hi.txt" "RPL$RV_SENTINEL" -m "$RV_HI_RAM"; then
        bad "L9_stack_top_above_2_31_boots" "the -m $RV_HI_RAM boot did not run (qemu exit=$BOOT_QEMU_RC): '$(head -c 200 "$WORK/l9_hi.txt.err")'"
    else
        verdict=$(rv_verdict "$WORK/l9_hi.txt")
        local hi_pc="$PARKED_PC" lo_verdict
        if [ "$verdict" != RPL_SENTINEL ]; then
            bad "L9_stack_top_above_2_31_boots" "--stack-top=$RV_STACK_TOP_HI at -m $RV_HI_RAM: verdict $verdict, wanted RPL_SENTINEL (capture: $WORK/l9_hi.txt)"
        elif [ "$hi_pc" != "$hpc" ]; then
            bad "L9_stack_top_above_2_31_boots" "printed the full sequence but parked at $hi_pc, not 0x$hpc (that image's own halt at $hhalt)"
        elif ! rv_boot "$himg" "$WORK/l9_lo.txt" SELFEXIT -m "$RV_LOW_RAM"; then
            bad "L9_stack_top_above_2_31_boots" "the -m $RV_LOW_RAM half did not run (qemu exit=$BOOT_QEMU_RC) -- without it the row cannot show rsp is really at $RV_STACK_TOP_HI"
        else
            lo_verdict=$(rv_verdict "$WORK/l9_lo.txt")
            if [ "$lo_verdict" != RPL ] && [ "$lo_verdict" != RPL_LOOP ]; then
                bad "L9_stack_top_above_2_31_boots" "the same image at -m $RV_LOW_RAM gave verdict $lo_verdict; wanted RPL or RPL_LOOP (long mode reached, then the first push faults outside installed RAM). Capture: $WORK/l9_lo.txt"
            else
                ok "L9_stack_top_above_2_31_boots" "--stack-top=$RV_STACK_TOP_HI (stack=$hstack, >= 2^31, the value the 10-byte movabs exists for): RPL$RV_SENTINEL at -m $RV_HI_RAM parked at 0x$hpc, and the SAME image at -m $RV_LOW_RAM gives $lo_verdict -- so rsp really is at 0x$(printf %x "$hstack") and is really pushed to; a sign-extending 7-byte mov would have failed both"
            fi
        fi
    fi
}

# THE ROSTERS ARE THE SKIP ACCOUNTING, so every check added by B2 Task 5 is
# listed here. A check that is not on its leg's roster does not become a SKIP
# when an earlier failure returns past it — it simply vanishes from the tally,
# which is the under-reporting this mechanism exists to prevent.
#
# THE COUNT CHANGED AT TASK 5 AND THAT IS EXPECTED. B1's 19/0/0 is not a
# baseline any more: L0's four loader checks are retired, L1 lost three
# loader-shaped controls and gained five, L2 lost one and gained three. What
# must hold is 0 FAIL and 0 SKIP. Sub-project C moved it twice more — 24 -> 28
# with L5 (Task 2), 28 -> 36 with L6 (Task 3) — and no check was retired or
# renamed by either. SUB-PROJECT D moved it once more, 36 -> 49, adding L7's
# nine x86_64/OVMF checks and L8's four arm64/AAVMF ones; again nothing was
# retired or renamed, so a run that reports fewer than 49 has lost a check
# rather than tightened one. D's Task 3 REVIEW then took it to 50 with L7's
# LOADED_SILENT control -- the one outcome of uefi_verdict that no row reached.
# SUB-PROJECT E moved it once more, 50 -> 58, adding L9's eight reset-vector
# checks; again nothing was retired or renamed. E's Task 4 then took it to 59
# with L9_control_gdt_08_64bit_no_protected_mode -- the second of the two
# triple-fault classes Task 2 measured, which until then had static coverage
# only.
run_leg leg0 L0_deadboot_x86 L0_deadboot_a64 L0_liveboot_not_flagged L0_alarm_not_a_dead_boot
run_leg leg1 L1_multiboot_header L1_no_header_image_refused L1_self_boot_sentinel \
             L1_halt_parked L1_control_entry_addr_honoured L1_control_no_return \
             L1_control_zeroed_payload
run_leg leg2 L2_entry_is_not_offset0 L2_self_boot_sentinel L2_halt_parked \
             L2_control_no_stub L2_control_offset0 L2_control_entry_minus4
run_leg leg3 L3_unique_halt_loop L3_exhaustion_halt L3_control_uninit L3_control_crash
run_leg leg4 L4_unaligned_refused_at_compile L4_x86_same_offset_accepted L4_aligned_prints_misaligned_silent
run_leg leg5 L5_header_entry_is_not_offset0 L5_header_boots_from_offset0 L5_halt_parked \
             L5_control_no_header_offset0_silent
run_leg leg6 L6_kernel_boots L6_kernel_load_base_is_header_derived \
             L6_control_image_size_too_large_refused \
             L6_control_magic_makes_qemu_read_the_header \
             L6_control_image_size_zero_abandons_header \
             L6_control_code0_nop_silent L6_control_code0_off_by_one_word_silent \
             L6_control_no_header_kernel_silent
run_leg leg7 L7_uefi_x86_boots L7_control_subsystem_3_not_loaded \
             L7_control_magic_pe32_not_loaded L7_control_machine_arm64_not_loaded \
             L7_control_rva_count_inconsistent_not_loaded \
             L7_control_size_of_image_too_small_not_loaded \
             L7_control_virtual_size_too_small_faults \
             L7_control_size_of_raw_data_zero_faults \
             L7_control_entry_at_section_start_silent \
             L7_control_read_only_section_still_runs
run_leg leg8 L8_uefi_a64_boots L8_control_subsystem_3_not_loaded \
             L8_control_virtual_size_too_small_faults \
             L8_control_read_only_section_printed_then_faulted
run_leg leg9 L9_reset_vector_report_and_anchors L9_reset_vector_boots L9_halt_parked \
             L9_control_map_1gib_no_long_mode L9_control_gdt_08_64bit_no_protected_mode \
             L9_control_reset_jmp_spins_silent \
             L9_control_zeroed_payload L9_control_kentoff_steers_the_call \
             L9_stack_top_above_2_31_boots

echo ""
echo "boot gate: $PASS pass, $FAIL FAIL, $SKIP SKIP"
[ "$FAIL" = 0 ] || exit 1
# A SKIP with no FAIL cannot happen by the design above -- every skip is
# downstream of an early return, and every early return calls bad(). If it
# does happen, a roster name is misspelled or a check was renamed, and the
# gate would otherwise report a smaller suite as green. Fail loudly.
if [ "$SKIP" != 0 ]; then
    echo "FAIL: boot_gate_roster ($SKIP checks skipped with no failure to explain them -- a run_leg roster name no longer matches any ok/bad call)"
    exit 1
fi
exit 0
