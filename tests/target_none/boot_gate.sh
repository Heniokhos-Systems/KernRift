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
# `cmp` is a PRE-EXISTING dead entry (no user in this file or in
# build_loader.sh — it predates Task 6). Left in place deliberately so this
# task's diff contains only what this task orphaned; recorded here so the next
# reader does not have to re-derive it.
#
# Still live, and where: python3 (make_stub.py / qmp_pc.py / loop_offset_a64),
# timeout + both qemu-system binaries (every boot), stat (L0's size report),
# sed (L0's indented build log, build_image's report parse), od (build_loader.sh).
#
# as/ld are NOT probed here — build_loader.sh does its own FUNCTIONAL probe,
# because on an aarch64 host `command -v as` answers "yes" and means "no"
# (review round 1 C4).
for t in qemu-system-x86_64 qemu-system-aarch64 python3 timeout od stat cmp sed; do
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
# WHY L0 NEEDS SELFEXIT AND NOT EITHER OF THE OTHER TWO. Its assertion is an
# occurrence COUNT of exactly 1. Content-polling would stop that run at the
# FIRST sentinel and thereby hide the very regression the count exists to
# detect: with -no-reboot removed the loader reboot-loops and replays the
# sentinel (34 observed), which an early-out would truncate back to 1 and PASS.
# And the short RUNOUT window would be wrong in the other direction — it is
# sized for legs that expect nothing, so a slow runner whose qemu takes longer
# to start than the window would score count 0 and FALSE-FAIL a positive leg.
# SELFEXIT costs nothing on the normal path (the loader triple-faults and
# -no-reboot exits it in ~80 ms, 2 ticks) and leaves 10 s of headroom for a
# machine nobody here has measured. Reaching that conclusion by nearly
# introducing the first mistake is the reason it is written down.
#
# RETURNS NONZERO IF THE BOOT DID NOT HAPPEN. The capture file is deleted
# before launch, so its existence afterwards is proof that qemu started and
# opened it. Silence from a boot that never ran is not evidence of anything,
# and six controls here assert silence — see their call sites.
#
# WHY NOT `sleep 4` (what task 1 shipped), AND WHY NOT PLAIN EXIT-POLLING
# (what task 2's first report proposed). Both were wrong, and MEASURED rather
# than argued this time. Only the three FAULT-terminating boots self-exit
# quickly; L1_sentinel parks in the loader's hlt loop, and L1_no_image plus
# ALL FOUR arm64 boots busy-spin until they are killed. Therefore:
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
# x86 always runs -no-reboot: a triple fault otherwise REBOOT-LOOPS and
# replays the loader sentinel indefinitely (observed: 25 repetitions in
# 3 s, V17). With -no-reboot QEMU exits by itself; the kill is then a
# no-op and the wait still reaps.
BOOT_TICK=0.05            # poll granularity, seconds
BOOT_DEADLINE_TICKS=200   # 10 s — hard ceiling on waiting for evidence
# Window for a RUNOUT leg. Seeded at 2 s and then RE-DERIVED by each leg from
# its own positive boot (8x the time that boot needed to reach the wire, capped
# at the deadline), so on a slow TCG runner the controls stretch in step with
# the thing they are controlling for. A fixed window would go vacuous exactly
# where the machine is slowest — the failure mode this gate exists to prevent.
BOOT_SILENCE_TICKS=40
BOOT_WAITED_TICKS=0       # out-param: ticks actually waited by the last run
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
    rm -f "$ser"
    # shellcheck disable=SC2086
    timeout 10 "$qemu" $machine -display none -serial "file:$ser" "$@" >/dev/null 2>&1 &
    local pid=$!
    boot_wait "$pid" "$ser" "$expect"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    # No capture file => qemu never opened it => no boot occurred.
    [ -f "$ser" ] || return 1
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
A64_LOAD=0x40400000; A64_STUB=0x40300000; A64_SP=0x40800000
X86_LOAD=0x400000

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
build_image() {
    local arch="$1" src="$2" out="$3"
    local aflag="x86_64" iload="$X86_LOAD"
    if [ "$arch" = "a64" ]; then aflag="arm64"; iload="$A64_LOAD"; fi
    local log="$out.rep"
    rm -f "$out"
    if ! "$KRC" --arch=$aflag --target=none --emit=image \
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

# One arm64 boot: image file at $1's load addr, stub branching to entry.
# $1 load addr, $2 image, $3 entry off, $4 serial out, $5 expect (see boot_run).
# EVERY step propagates failure. A stub the generator refused to emit, or a
# qemu that never opened the capture, must not look like "the program stayed
# quiet" to a control that reads silence as a pass.
a64_boot() {
    local load="$1" img="$2" entry="$3" ser="$4" expect="$5"
    python3 "$BOOT/make_stub.py" $(( load + entry )) "$A64_STUB" "$A64_SP" "$WORK/stub.bin" || return 1
    boot_run a64 "$ser" "$expect" \
        -device loader,file="$WORK/stub.bin",addr=$A64_STUB,cpu-num=0 \
        -device loader,file="$img",addr=$(printf 0x%x "$load"),force-raw=on
}

# One x86 boot: loader built for the entry VA, image via -device loader.
# $1 load addr, $2 image, $3 entry off, $4 serial out, $5 expect.
x86_boot() {
    local load="$1" img="$2" entry="$3" ser="$4" expect="$5"
    "$BOOT/build_loader.sh" $(printf 0x%x $(( load + entry ))) "$WORK/ldr.elf" >/dev/null 2>&1 || return 1
    boot_run x86 "$ser" "$expect" -kernel "$WORK/ldr.elf" \
        -device loader,file="$img",addr=$(printf 0x%x "$load"),force-raw=on
}

# boot_run for arm64 WITH a QMP socket, so the guest's PC can be read while it
# is still running. Same contract as boot_run — capture deleted before launch,
# nonzero return if it is missing afterwards, same <expect> vocabulary via
# boot_wait — plus the out-param PARKED_PC.
#
#   boot_run_qmp <serial file> <expect> [qemu args...]
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
    local ser="$1" expect="$2"; shift 2
    QMPD="${QMPD:-$(mktemp -d /tmp/krcqmp.XXXXXX)}"
    local sock="$QMPD/qmp.sock"
    rm -f "$ser" "$sock"
    PARKED_PC=QMPFAIL
    timeout 15 qemu-system-aarch64 -M virt -cpu cortex-a57 -display none \
        -serial "file:$ser" -qmp "unix:$sock,server,nowait" "$@" >/dev/null 2>&1 &
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
    if [ "$cur" = QMPFAIL ]; then
        PARKED_PC=QMPFAIL
    elif [ -z "$cur" ]; then
        PARKED_PC="MOVING:$prev"
    else
        PARKED_PC="$cur"
    fi
    # No capture file => qemu never opened it => no boot occurred.
    [ -f "$ser" ] || return 1
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
    boot_run_qmp "$ser" "$expect" \
        -device loader,file="$WORK/stub.bin",addr=$A64_STUB,cpu-num=0 \
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
    # SELFEXIT, deliberately NOT a content trigger — see boot_run's header.
    # This assertion is a COUNT, and stopping at the first sentinel would
    # truncate the reboot-loop it exists to detect back to a passing 1.
    if ! boot_run x86 "$WORK/l0_ser.txt" SELFEXIT -kernel "$WORK/l0.elf"; then
        bad "L0_loader_liveness_sentinel" "the boot did not run (no capture file)"; return
    fi
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
#      WHAT OFFSET 0 ACTUALLY IS — RE-OBSERVED AT TASK 6, NOT INHERITED. Under
#      the Task-2 ELF form, offset 0 was the ELF HEADER (`7f 45 4c 46 …`)
#      executed as instructions. `--emit=image` emits no header, so offset 0 is
#      now REAL CODE and the control survives for a DIFFERENT REASON. Read off
#      the artifact under test (capstone, x86 image, offset 0): it is
#      `uart16550_outb` (std/uart_16550.kr:54), the UART provider's first
#      helper — push/push/…,
#      `mov rbx,rdi; mov r12,rsi`, `out dx,al` with whatever the loader left in
#      rdi/rsi, then epilogue + `ret` back into the loader, which hlt-loops.
#      One garbage byte may go to one garbage I/O port; the sentinel is ten
#      formatted digits that only main computes, so it cannot appear. Observed
#      silent in image form, not assumed to carry over.
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
    if ! x86_boot "$X86_LOAD" "$WORK/sx.img" "$entry" "$WORK/l1_ser.txt" "2000000016"; then
        bad "L1_sentinel" "the boot did not run (loader build or qemu launch failed)"; return
    fi
    if grep -q "2000000016" "$WORK/l1_ser.txt" && grep -q "KR-LDR|" "$WORK/l1_ser.txt"; then
        ok "L1_sentinel" "computed 2000000016 + loader liveness on COM1 (${BOOT_WAITED_TICKS} ticks)"
    else
        bad "L1_sentinel" "serial held: '$(cat "$WORK/l1_ser.txt")'"
    fi
    # Every control below asserts ABSENCE, so its window must be long enough
    # that a working boot would certainly have printed by now. Derived from the
    # positive boot just observed rather than guessed — see calibrate_silence.
    calibrate_silence
    # Control (a): same loader, NO image. The loader must still prove itself
    # alive and the program sentinel must be impossible.
    if ! "$BOOT/build_loader.sh" $(printf 0x%x $(( X86_LOAD + entry ))) "$WORK/ldr.elf" >/dev/null 2>&1; then
        bad "L1_control_no_image" "loader build failed — control never ran"
    elif ! boot_run x86 "$WORK/l1_noimg.txt" RUNOUT -kernel "$WORK/ldr.elf"; then
        bad "L1_control_no_image" "the boot did not run (no capture file)"
    elif grep -q "KR-LDR|" "$WORK/l1_noimg.txt" && ! grep -q "2000000016" "$WORK/l1_noimg.txt"; then
        ok "L1_control_no_image" "loader alive, program sentinel absent"
    else
        bad "L1_control_no_image" "serial held: '$(cat "$WORK/l1_noimg.txt")'"
    fi
    # Controls (b)/(c): offset 0 and entry-4 must not print — both re-observed
    # silent in IMAGE form (see the header note; offset 0 is now uart16550_outb,
    # not the ELF header it was through Task 5). They prove the entry value is
    # load-bearing at function granularity; instruction-level +4 is NOT
    # observable (V16), which is why it is not used as a control.
    #
    # SINCE TASK 6 THESE ARE ALSO THE REPORT-ACCURACY CONTROLS. `entry` no
    # longer comes from a header the loader could be trusted to agree with — it
    # is parsed from the compiler's own `image:` line, and a flat image has no
    # e_entry to check it against. So the leg's subject (boot at the REPORTED
    # entry, must print) and these two (boot at values either side of it, must
    # not) are jointly what makes the report load-bearing.
    #
    # HOW SHARP THAT ACTUALLY IS — MEASURED AT TASK 6, and SHARPER than the
    # plan assumed. The plan (D1) recorded "instruction-level drift entry+4/8/12
    # is not observable", reasoning from V16: main's first instructions are
    # stack bookkeeping, so BRANCHING to entry+4 still prints. V16 is right, and
    # this leg's subject alone really is blind to a +4 report. THE entry-4
    # CONTROL IS NOT. With the report N bytes too high the control boots at
    # real_entry + (N - 4), which is inside main and prints — so it goes RED.
    # Five report drifts were built into the compiler and run: -4 and 0 kill the
    # SUBJECT (silence); +4, +8 and +16 light THIS CONTROL; +16 kills both.
    # Every drift constructed reddened at least one check. That is five points,
    # not a proof of coverage — a drift landing on some other silent address
    # remains possible and is not claimed to be caught.
    #
    # THE BOOT'S EXIT STATUS IS CHECKED FIRST, AND THAT IS THE WHOLE POINT.
    # These three legs read silence as evidence, so a boot that never happened
    # would hand them a free PASS: with the return value ignored (as it was
    # until review 3), deleting the capture file or breaking the loader build
    # passed all six absence controls with no qemu ever started. Silence only
    # means something once the run it came from is known to have occurred.
    if ! x86_boot "$X86_LOAD" "$WORK/sx.img" 0 "$WORK/l1_off0.txt" RUNOUT; then
        bad "L1_control_offset0" "the boot did not run — silence proves nothing"
    elif grep -q "2000000016" "$WORK/l1_off0.txt"; then
        bad "L1_control_offset0" "sentinel printed from offset 0"
    else
        ok "L1_control_offset0" "offset 0 => no sentinel (boot ran, capture present)"
    fi
    if ! x86_boot "$X86_LOAD" "$WORK/sx.img" $(( entry - 4 )) "$WORK/l1_offm.txt" RUNOUT; then
        bad "L1_control_entry_minus4" "the boot did not run — silence proves nothing"
    elif grep -q "2000000016" "$WORK/l1_offm.txt"; then
        bad "L1_control_entry_minus4" "sentinel printed from the previous function's tail"
    else
        ok "L1_control_entry_minus4" "entry-4 => no sentinel (boot ran, capture present)"
    fi
}

# =============================================================================
# L2 — arm64 boots and prints the computed sentinel. Same three controls
#      (no-image; offset 0; entry - 4 — never entry + 4, see V16).
#
#      Position independence is what makes the 0x40400000 load address legal:
#      every static access in the arm64 output is `adrp x16, …` + a fixed
#      displacement and every call is a PC-relative `bl` (checked in the
#      disassembly: 18 adrp, zero absolute addresses). Since Task 6 the image
#      is also COMPILED with --load-addr=0x40400000, but that address is only
#      validated and echoed — Task 5's image_load_addr_not_embedded_arm64
#      proves two different aligned addresses yield one byte-identical
#      artifact, so position independence is still what is doing the work.
#      The x86 image is loaded at the address it was built for, so the
#      question does not arise there.
#
#      OFFSET 0 IN IMAGE FORM, re-observed here too: `pl011_reg_write`
#      (std/uart_pl011.kr's first helper) — `sub sp,…`, an `adrp` load of the
#      PL011 base, `str w20,[x19]` through a garbage x0/x1 pair, then `ret` to
#      x30, which the reset stub never set (it branches with `b`, not `bl`).
#      No formatted digits can come out of it.
# =============================================================================
leg2() {
    echo "--- L2: arm64 boot + computed sentinel ---"
    cp "$BOOT/sentinel_a64.kr" "$WORK/sentinel_a64.kr"
    local entry
    if ! entry=$(build_image a64 "$WORK/sentinel_a64.kr" "$WORK/sa.img"); then
        bad "L2_compile" "sentinel_a64.kr did not compile"; return
    fi
    if ! a64_boot "$A64_LOAD" "$WORK/sa.img" "$entry" "$WORK/l2_ser.txt" "1000000016"; then
        bad "L2_sentinel" "the boot did not run (stub generation or qemu launch failed)"; return
    fi
    if grep -q "1000000016" "$WORK/l2_ser.txt"; then
        ok "L2_sentinel" "computed 1000000016 on the PL011 (${BOOT_WAITED_TICKS} ticks)"
    else
        bad "L2_sentinel" "serial held: '$(cat "$WORK/l2_ser.txt")'"
    fi
    # Absence windows derived from the arm64 positive boot just observed —
    # separately from L1's, because the two arches do not run at the same speed.
    calibrate_silence
    # Control (a): stub with NO image => silence (arm64 has no loader
    # sentinel; the stub is 4 instructions). This control exists to pin the
    # observation that silence CANNOT be a pass condition on this arch —
    # legs assert presence, never absence alone (review 2, O5). Which is
    # precisely why the boot's own status is checked before its silence is
    # read: see the note in leg1.
    if ! python3 "$BOOT/make_stub.py" $(( A64_LOAD + entry )) "$A64_STUB" "$A64_SP" "$WORK/stub.bin"; then
        bad "L2_control_no_image" "stub generation failed — control never ran"
    elif ! boot_run a64 "$WORK/l2_noimg.txt" RUNOUT -device loader,file="$WORK/stub.bin",addr=$A64_STUB,cpu-num=0; then
        bad "L2_control_no_image" "the boot did not run — silence proves nothing"
    elif grep -q "1000000016" "$WORK/l2_noimg.txt"; then
        bad "L2_control_no_image" "sentinel printed with no image loaded"
    else
        ok "L2_control_no_image" "no image => no sentinel (boot ran, capture present)"
    fi
    # Controls (b)/(c): offset 0 (pl011_reg_write with garbage args, `ret`ing
    # to an x30 the stub never set) and entry-4 (the previous function's `ret`)
    # — both re-observed silent in IMAGE form, empty PL011 capture in each case.
    # SINCE TASK 6 THESE ARE ALSO THE REPORT-ACCURACY CONTROLS: `entry` is
    # parsed from the compiler's `image:` line and a flat image has no e_entry,
    # so a report that drifts from the artifact turns the subject silent or
    # lights one of these up. See leg 1's note on the same controls for the
    # measured sharpness — briefly: a -4 or 0 report kills the subject, and a
    # +4/+8/+16 report reds the entry-4 control, which is finer than D1's
    # "instruction-level drift is not observable" allowed for. Both arches were
    # injected and both behaved identically.
    if ! a64_boot "$A64_LOAD" "$WORK/sa.img" 0 "$WORK/l2_off0.txt" RUNOUT; then
        bad "L2_control_offset0" "the boot did not run — silence proves nothing"
    elif grep -q "1000000016" "$WORK/l2_off0.txt"; then
        bad "L2_control_offset0" "sentinel printed from offset 0"
    else
        ok "L2_control_offset0" "offset 0 => no sentinel (boot ran, capture present)"
    fi
    if ! a64_boot "$A64_LOAD" "$WORK/sa.img" $(( entry - 4 )) "$WORK/l2_offm.txt" RUNOUT; then
        bad "L2_control_entry_minus4" "the boot did not run — silence proves nothing"
    elif grep -q "1000000016" "$WORK/l2_offm.txt"; then
        bad "L2_control_entry_minus4" "sentinel printed from the previous function's tail"
    else
        ok "L2_control_entry_minus4" "entry-4 => no sentinel (boot ran, capture present)"
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
    local entry
    if ! entry=$(build_image a64 "$WORK/sentinel_a64.kr" "$WORK/s4.img"); then
        bad "L4_aligned_prints_misaligned_silent" "sentinel_a64.kr did not compile"; return
    fi
    if ! a64_boot "$A64_LOAD" "$WORK/s4.img" "$entry" "$WORK/l4_ok.txt" "1000000016"; then
        bad "L4_aligned_prints_misaligned_silent" "the ALIGNED boot did not run"; return
    fi
    # The misaligned half asserts absence, so its window is derived from the
    # aligned half just observed — same rule as every other silence here.
    calibrate_silence
    if ! a64_boot $(( A64_LOAD + 0x100 )) "$WORK/s4.img" "$entry" "$WORK/l4_mis.txt" RUNOUT; then
        bad "L4_aligned_prints_misaligned_silent" "the MISALIGNED boot did not run — silence proves nothing"; return
    fi
    if grep -q "1000000016" "$WORK/l4_ok.txt" && ! grep -q "1000000016" "$WORK/l4_mis.txt"; then
        ok "L4_aligned_prints_misaligned_silent" "same bytes, same invocation: 0x$(printf %x $A64_LOAD) prints, +0x100 is silent"
    else
        bad "L4_aligned_prints_misaligned_silent" "aligned='$(tr '\n' ' ' <"$WORK/l4_ok.txt")' mis='$(tr '\n' ' ' <"$WORK/l4_mis.txt")'"
    fi
}

run_leg leg0 L0_loader_builds L0_loader_liveness_sentinel L0_corrupt_magic_rejected L0_missing_as_fails
run_leg leg1 L1_sentinel L1_control_no_image L1_control_offset0 L1_control_entry_minus4
run_leg leg2 L2_sentinel L2_control_no_image L2_control_offset0 L2_control_entry_minus4
run_leg leg3 L3_unique_halt_loop L3_exhaustion_halt L3_control_uninit L3_control_crash
run_leg leg4 L4_unaligned_refused_at_compile L4_x86_same_offset_accepted L4_aligned_prints_misaligned_silent

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
