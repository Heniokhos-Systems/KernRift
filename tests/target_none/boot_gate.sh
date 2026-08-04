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
# Those two boots existed only as manual runs recorded in Task 3's and Task 4's
# reports until this file was changed. A result that lives only in a report is
# one refactor away from being unverified; every one of them is a leg now.
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
# ci.yml carried qemu-USER-static only. Task 2 wires the gate into
# tests/run_tests.sh as a COUNTED test and adds `qemu-system-x86 qemu-system-arm`
# to both jobs that invoke the suite (the ubuntu-latest x86_64 job and the
# ubuntu-24.04-arm job). So the gate is now *expected* to run in CI —
# but NO CI RUN HAS EVER EXECUTED IT. Nothing in B1 is pushed, and two things
# are declared-unverified from the dev machine: whether qemu-system-x86 installs
# on ubuntu-24.04-arm, and what an emulated x86 boot costs in wall clock on
# either runner. Until a green CI run exists, treat this gate's evidence as
# produced on one developer machine. The failure mode is loud either way (a
# counted FAIL naming the missing tool, never a silent skip).
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
#             img_bytes, and img_patch (L1's three patched controls)
#   timeout   every boot, both arches
#   qemu-system-x86_64, qemu-system-aarch64   every boot
#   stat      build_image's on-disk size cross-check, L0's capture sizes,
#             L4's x86 artifact report
#   sed       build_image's `image:` report parse — the ONLY source of the
#             entry offset every leg branches to
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
# Used to read the emitted multiboot header's own fields off the artifact.
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
#   u32:<off>:<val>   little-endian u32 at <off>
#   hex:<off>:<bytes> raw hex at <off>
#   zero:<off>        zero everything from <off> to EOF
# Order matters and is used: L1's payload control zeroes to EOF and then plants
# a landing pad inside the zeroed region.
# Exits nonzero (and writes nothing) if an offset does not fit, so a control
# built on a mislocated patch site fails instead of quietly testing nothing.
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
    elif kind == "u32":
        o, v = rest.split(":")
        o, v = int(o), int(v)
        if o + 4 > len(d):
            sys.exit("img_patch: u32 at %d does not fit in %d bytes" % (o, len(d)))
        struct.pack_into("<I", d, o, v & 0xFFFFFFFF)
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
#      An arm64 image has no header and no e_entry, so `entry` is a number the
#      compiler printed with nothing on the artifact to check it against. The
#      subject (enter at the reported entry, must print) plus offset 0 and
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
    # what makes the reported `entry` load-bearing on an arch whose artifact
    # has no header to check it against.
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
#      standing obligation on code0: the placeholder branch is the same word,
#      so a missed patch-back would both hang the machine here AND break the
#      `loop_offset_a64` scan five other checks read a PC through.
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

# THE ROSTERS ARE THE SKIP ACCOUNTING, so every check added by B2 Task 5 is
# listed here. A check that is not on its leg's roster does not become a SKIP
# when an earlier failure returns past it — it simply vanishes from the tally,
# which is the under-reporting this mechanism exists to prevent.
#
# THE COUNT CHANGED AT TASK 5 AND THAT IS EXPECTED. B1's 19/0/0 is not a
# baseline any more: L0's four loader checks are retired, L1 lost three
# loader-shaped controls and gained five, L2 lost one and gained three. What
# must hold is 0 FAIL and 0 SKIP.
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
