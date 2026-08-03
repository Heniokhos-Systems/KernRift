#!/bin/bash
# =============================================================================
# The --target=none acceptance gate
# =============================================================================
#
# WHAT A GREEN RUN CLAIMS, EXACTLY:
#
#   1. No trap instruction is present in any artifact --target=none produces.
#   2. print/println/print_str/println_str/write lower to a CALL that lands on
#      an @builtin_override provider, and the provider body is in the artifact
#      IF AND ONLY IF something reaches it.
#   3. Every builtin that has no bare-metal meaning refuses, the refusal names
#      THAT BUILTIN, and it writes no artifact -- on all four architectures.
#   4. Every existing target -- all 8 hosted (arch x OS), hosted riscv32, the
#      fat binary, and every riscv32/xtensa freestanding invocation the suite
#      makes -- emits BYTE-IDENTICAL artifacts before and after this branch.
#
# WHAT A GREEN RUN DOES NOT CLAIM, AND MUST NEVER BE READ AS CLAIMING:
#
#   NOTHING IN THIS SUB-PROJECT HAS EVER PRODUCED OUTPUT ON BARE METAL. Not on
#   silicon, not under an emulator. --target=none hardcodes a 0x400000 load
#   address (src/main.kr:3101, 3719, 3832) and emits no startup code, so the
#   stack pointer is garbage by the time main's prologue runs. A QEMU boot of
#   one of these images produced no output; that is the EXPECTED symptom of a
#   missing entry point, not an unexplained failure. Sub-project B
#   (--emit=image) supplies the entry point, the stack and the load address.
#
#   So: "the compiler emits a call to the UART provider" is proven here.
#   "a character came out of the UART" is not, and this script has no leg that
#   could prove it. Two safety comments in this sub-project's own diff were
#   wrong in review; a disassembly is not an execution.
#
# The BLOCKING serial-output legs live in tests/target_none/boot_gate.sh
# (sub-project B1): both UARTs observed printing computed sentinels from
# RAW --emit=image artifacts, one heap-exhaustion halt discriminated by
# parked PC over QMP, and an arm64 misalignment pair -- every leg with an
# observed negative control. Runtime claims about bare metal cite THAT
# gate; this script's claims remain compile-time only.
#
# -----------------------------------------------------------------------------
# Usage
#   tests/target_none/prove_no_syscalls.sh            # both gates
#   tests/target_none/prove_no_syscalls.sh --gate1    # byte-identity only
#   tests/target_none/prove_no_syscalls.sh --gate2    # the corpus only
#
# Env:
#   KRC=<path>      compiler under test          (default build/krc2)
#   TN_BASE=<sha>   the commit this branch forks from, for gate 1
#
# TWO GATES, BECAUSE NEITHER SEES WHAT THE OTHER CATCHES.
#
# Gate 1 (byte-identity) proves the branch disturbed no existing target. It
# STRUCTURALLY CANNOT detect the failure this sub-project is most likely to
# have: the per-OS dispatch throughout the backends is "special-case Windows /
# macOS, else fall through to POSIX", so a missing --target=none arm makes bare
# metal silently inherit Linux. Every existing target stays byte-identical
# while doing so -- by construction, since none of their arms changed.
#
# Gate 2 (the corpus) is the leg that sees that. It compiles every builtin
# under --target=none on all four architectures and requires each one to either
# reach a provider or refuse BY NAME. A refusal that names the wrong builtin,
# or the generic emitter backstop firing, is a failure: the backstop firing
# means a lowering has no --target=none arm and only the last line of defence
# caught it.
#
# Exit status: 0 iff every check passed. Any failure is a defect in the tasks
# this gate consumes, not in the gate.
# =============================================================================

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
KRC="${KRC:-$REPO/build/krc2}"
# The BASE this branch forks from. Pinned rather than derived from
# `git merge-base`, which silently changes meaning the moment the branch is
# merged or rebased -- and a gate whose baseline moved is a gate comparing the
# tree against itself.
TN_BASE="${TN_BASE:-271e1186e22994e7fc4c4b9f6abf71e7bad0164e}"

MODE="both"
case "${1:-}" in
    --gate1) MODE="gate1" ;;
    --gate2) MODE="gate2" ;;
    "")      MODE="both" ;;
    *) echo "usage: $0 [--gate1|--gate2]" >&2; exit 2 ;;
esac

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  $1: PASS${2:+ ($2)}"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $1${2:+ ($2)}"; }

if [ ! -x "$KRC" ]; then
    echo "FAIL: no compiler at $KRC -- run 'make build' first" >&2
    exit 2
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/krc_tn_gate_XXXXXX")
# Gate 2's programs import "../std/...". Imports resolve against the importing
# FILE's own directory first, then against the INSTALLED stdlib -- so a program
# in /tmp would either fail to resolve or silently pick up whatever
# ~/.local/share/kernrift/std happens to hold, which is not the tree under
# test. This directory therefore has to live in the repo.
INREPO=$(mktemp -d "$REPO/krc_tn_gate_XXXXXX")
cleanup() { rm -rf "$TMP" "$INREPO"; }
trap cleanup EXIT

# =============================================================================
# GATE 1 -- byte-identity across every existing target
# =============================================================================
#
# THE COMPARISON IS TWO COMPILERS ON THE SAME FROZEN INPUT. An earlier run of
# this comparison reported 14 differences that were not differences: it built
# the old compiler from old source and the new compiler from new source and
# then compiled DIFFERENT inputs with them, so it was measuring the source
# edits, not the codegen. Here the BEFORE compiler is BASE's source compiled by
# the compiler under test, the AFTER compiler is the compiler under test, and
# both are handed byte-identical input files.
#
# STDERR IS DELIBERATELY NOT COMPARED, and the exclusion is not laziness:
# commit 563b0f3 fixed 30 write(fd,"lit",N) lengths and this branch's first
# commit fixed 3 more, all of which INTENTIONALLY change diagnostic bytes.
# Byte-identity is a claim about emitted artifacts. What is compared per row is
# (exit status, artifact bytes or its absence) -- the absence matters, because
# a row that used to build and now refuses is exactly as much of a regression
# as a row whose bytes moved.
gate1() {
    echo ""
    echo "=== GATE 1: byte-identity across every existing target ==="

    if ! git -C "$REPO" cat-file -e "$TN_BASE^{commit}" 2>/dev/null; then
        bad "gate1_base_present" "$TN_BASE is not a commit in this repo -- gate 1 cannot run"
        return
    fi

    # The BEFORE tree, straight from git so nothing in the working tree can
    # leak into it.
    mkdir -p "$TMP/base"
    if ! git -C "$REPO" archive "$TN_BASE" | tar -x -C "$TMP/base"; then
        bad "gate1_base_checkout" "git archive $TN_BASE failed"
        return
    fi
    # Use BASE's OWN Makefile to concatenate BASE's OWN source list. Spelling
    # the file list here would silently compile the wrong set the moment the
    # list changes on either side.
    if ! make -s -C "$TMP/base" build/krc.kr >/dev/null 2>&1; then
        bad "gate1_base_sources" "could not assemble build/krc.kr at $TN_BASE"
        return
    fi
    G1_FROZEN="$TMP/base/build/krc.kr"
    if ! "$KRC" --arch=x86_64 "$G1_FROZEN" -o "$TMP/krc_before" >/dev/null 2>&1; then
        bad "gate1_base_compiler" "the BASE sources did not compile"
        return
    fi
    chmod +x "$TMP/krc_before"
    ok "gate1_before_compiler_built" "$(wc -c < "$TMP/krc_before") B from $TN_BASE"

    # --- the row list -------------------------------------------------------
    # Each row is:  <name>|<flags>|<input>
    ROWS="$TMP/rows"
    : > "$ROWS"
    g1row() { echo "$1|$2|$3" >> "$ROWS"; }

    # (A) 8 hosted arch x OS pairs, four emit paths each, two programs each.
    #     --legacy and --emit=obj are in here because the legacy backend holds
    #     80 of the tree's 96 raw x86 syscall sites and has its own builtin
    #     dispatch; a change there is invisible to an IR-only matrix.
    #     --emit=asm is in because the first commit on this branch changed the
    #     assembly listing writer.
    for a in x86_64 arm64; do
        for t in linux macos windows android; do
            for m in ir legacy obj asm; do
                case "$m" in
                    ir)     mf="" ;;
                    legacy) mf="--legacy" ;;
                    obj)    mf="--emit=obj" ;;
                    asm)    mf="--emit=asm" ;;
                esac
                g1row "krc_${a}_${t}_${m}"   "--arch=$a --target=$t $mf" "$G1_FROZEN"
                g1row "probe_${a}_${t}_${m}" "--arch=$a --target=$t $mf" "$DIR/corpus/probe_io.kr"
            done
        done
    done

    # (A2) The CONTAINER emitters, which the rows above do not reach. --target=
    #      selects the ABI (syscall numbers, calling convention), NOT the
    #      output format: `--arch=x86_64 --target=windows` emits an ELF whose
    #      magic is 7f454c46, and PE and Mach-O come out only under --emit=.
    #      These rows exist because an injected byte in emit_pe_headers_x64 and
    #      emit_pe_headers_a64 -- both of them -- flagged only the two fat rows
    #      when the matrix had 121 rows, which is what a container emitter
    #      covered by exactly one path looks like. --emit=lkm is absent because
    #      it refuses on both arches for both programs, i.e. there is nothing
    #      to compare.
    for a in x86_64 arm64; do
        for e in pe macho; do
            g1row "krc_${a}_${e}"   "--arch=$a --emit=$e" "$G1_FROZEN"
            g1row "probe_${a}_${e}" "--arch=$a --emit=$e" "$DIR/corpus/probe_io.kr"
        done
    done

    # (B) --debug on every hosted pair. bmarr.kr indexes a stack array with a
    #     runtime value ON PURPOSE: --debug on an array-free program emits no
    #     bounds check at all, so those rows would compare two artifacts that
    #     contain nothing of what --debug does.
    for a in x86_64 arm64; do
        for t in linux macos windows android; do
            g1row "debug_${a}_${t}" "--arch=$a --target=$t --debug" "$DIR/corpus/bmarr.kr"
        done
    done

    # (C) The fat binary: no --arch, no --target. It builds all 8 hosted slices
    #     through a different path from any single-slice build, and Task 1's
    #     Critical was precisely a fat-path regression (freestanding is a
    #     static global that persisted into every slice).
    g1row "fat_krc"   "" "$G1_FROZEN"
    g1row "fat_probe" "" "$DIR/corpus/probe_io.kr"

    # (D) The portable corpus on the 32-bit targets. arith.kr and bmarr.kr are
    #     uint32-only because riscv32 and xtensa reject uint64 in the type
    #     checker -- a uint64 program cannot be the same frozen input on all
    #     four arches, it would compare two identical parse errors.
    for p in arith bmarr; do
        g1row "rv32_hosted_$p"       "--arch=riscv32"                "$DIR/corpus/$p.kr"
        g1row "rv32_freestanding_$p" "--arch=riscv32 --freestanding" "$DIR/corpus/$p.kr"
        g1row "xt_freestanding_$p"   "--arch=xtensa --freestanding"  "$DIR/corpus/$p.kr"
    done

    # (E) Every riscv32/xtensa invocation the suite itself makes, DERIVED from
    #     tests/run_tests.sh rather than copied. A hand-copied list is stale the
    #     first time someone adds an example, and "every existing invocation"
    #     is the requirement. Line continuations are joined first because four
    #     of the esp32 invocations are written across two lines.
    G1_DERIVED="$TMP/derived"
    RUNTESTS="$REPO/tests/run_tests.sh" python3 - > "$G1_DERIVED" <<'DERIVE'
import os, re
src = open(os.environ["RUNTESTS"]).read().replace("\\\n", " ")
pat = re.compile(r'--arch=(riscv32|xtensa)((?:\s+--[A-Za-z0-9=_.-]+)*)\s+"?\$DIR/\.\./(examples/[A-Za-z0-9_/.-]+\.kr)')
rows = set()
for m in pat.finditer(src):
    rows.add(("--arch=" + m.group(1) + " " + " ".join(m.group(2).split())).strip() + "|" + m.group(3))
for r in sorted(rows):
    print(r)
DERIVE
    G1_NDERIVED=$(wc -l < "$G1_DERIVED")
    # Pinned, not floored. A DROP means the suite stopped exercising a
    # freestanding invocation and this gate quietly stopped covering it. A RISE
    # means someone added one and should bump this number having looked at it.
    if [ "$G1_NDERIVED" = "41" ]; then
        ok "gate1_derived_invocations" "41 riscv32/xtensa invocations derived from the suite"
    else
        bad "gate1_derived_invocations" "derived $G1_NDERIVED, expected 41 -- bump this if you added one, investigate if it dropped"
    fi
    while IFS='|' read -r flags input; do
        [ -n "$flags" ] || continue
        nm=$(echo "${flags#--arch=} $input" | tr -c 'A-Za-z0-9' '_' | sed 's/__*/_/g;s/_$//')
        g1row "suite_$nm" "$flags" "$REPO/$input"
    done < "$G1_DERIVED"

    # --- NOTE: the --emit=asm normalisation carve-out is GONE ---------------
    #
    # It existed because the listing writer had three wrong write() lengths
    # (header declared 27 for a 28-byte string, so "...listing" lost its \n;
    # mfence over-read by 1 and emitted a trailing NUL; lock truncated by 1 and
    # lost its third "."). Those were fixed BEFORE the current TN_BASE, so the
    # BEFORE compiler now emits correct listings too and there is nothing left
    # to normalise: the carve-out's own guard fired (`sys.exit(3)`) on all 18
    # asm rows, reporting 18 failures for an artifact difference that no longer
    # exists. Byte-identity passed 129/129 on the RAW, un-normalised bytes in
    # that same run -- which is the proof that removing this is safe rather
    # than a loosening. Asm rows are now compared exactly, like every other row.
    # If a future branch legitimately moves listing bytes again, add the
    # normalisation back WITH its guard, do not exclude the rows.

    # --- run the matrix -----------------------------------------------------
    G1_ROWS=0; G1_SAME=0; G1_DIFF=0; G1_ARTIFACTS=0; G1_DIFFLIST=""; G1_NOBUILD=""
    while IFS='|' read -r name flags input; do
        [ -n "$name" ] || continue
        G1_ROWS=$((G1_ROWS + 1))
        # ${A}_${T} spelled with braces on purpose: an earlier draft wrote
        # /tmp/bi_$A_$T, which the shell parses as ${A_}$T, so arm64 overwrote
        # x86_64 and half the matrix was never compared.
        b="$TMP/before_${name}"; a="$TMP/after_${name}"
        rm -f "$b" "$a"
        # shellcheck disable=SC2086
        "$TMP/krc_before" $flags "$input" -o "$b" >/dev/null 2>&1; bst=$?
        # shellcheck disable=SC2086
        "$KRC"            $flags "$input" -o "$a" >/dev/null 2>&1; ast=$?
        bh="absent"; ah="absent"
        [ -f "$b" ] && bh=$(sha256sum < "$b" | cut -d' ' -f1)
        [ -f "$a" ] && ah=$(sha256sum < "$a" | cut -d' ' -f1)
        if [ "$ah" != "absent" ]; then
            G1_ARTIFACTS=$((G1_ARTIFACTS + 1))
        else
            G1_NOBUILD="$G1_NOBUILD$flags ${input#$REPO/}
"
        fi
        if [ "$bst" = "$ast" ] && [ "$bh" = "$ah" ]; then
            G1_SAME=$((G1_SAME + 1))
        else
            G1_DIFF=$((G1_DIFF + 1))
            G1_DIFFLIST="$G1_DIFFLIST
    $name: exit $bst->$ast, ${bh:0:12}->${ah:0:12}  [$flags $(basename "$input")]"
        fi
        rm -f "$b" "$a"
    done < "$ROWS"

    # Non-vacuity, asserted rather than assumed. A matrix that compiled nothing
    # compares equal on every row, and three of these rows are the suite's own
    # NEGATIVE tests -- invocations it expects to be refused. Those three are
    # named, so a row that starts refusing is a failure and a row that stops
    # refusing is one too.
    if [ "$G1_ROWS" = "129" ]; then
        ok "gate1_row_count" "129 rows"
    else
        bad "gate1_row_count" "built $G1_ROWS rows, expected 129"
    fi
    G1_NOBUILD_WANT="--arch=riscv32 --freestanding examples/riscv-hosted/hello.kr
--arch=riscv32 --freestanding --target=esp32 examples/esp32/minimal.kr
--arch=xtensa --target=esp32 examples/esp32/minimal.kr"
    G1_NOBUILD_GOT=$(printf '%s' "$G1_NOBUILD" | sed '/^$/d' | sort)
    if [ "$G1_ARTIFACTS" != "126" ]; then
        bad "gate1_build_outcomes" "$G1_ARTIFACTS of $G1_ROWS rows produced an artifact, expected 126"
    elif [ "$G1_NOBUILD_GOT" != "$(printf '%s' "$G1_NOBUILD_WANT" | sort)" ]; then
        bad "gate1_build_outcomes" "the rows that produced no artifact are not the three expected refusals: $(echo "$G1_NOBUILD_GOT" | tr '\n' ';')"
    else
        ok "gate1_build_outcomes" "126 rows built, 3 refused (the suite's own esp32-guard and riscv32 IR-op-52 negatives)"
    fi
    if [ "$G1_DIFF" = "0" ]; then
        ok "gate1_byte_identity" "$G1_SAME/$G1_ROWS rows identical"
    else
        bad "gate1_byte_identity" "$G1_DIFF of $G1_ROWS rows differ:$G1_DIFFLIST"
    fi
}

# =============================================================================
# GATE 2 -- the corpus: every builtin, all four architectures
# =============================================================================
#
# Gate 1 cannot see any of this. Three separate claims:
#   (a) every builtin with no bare-metal meaning refuses, BY NAME, writing no
#       artifact, on all four arches;
#   (b) with a provider, the output family and the allocator compile, the
#       lowering becomes a CALL, and the provider body is in the artifact iff
#       something reaches it;
#   (c) no artifact --target=none produces contains a trap instruction for ANY
#       of the four architectures.
gate2() {
    echo ""
    echo "=== GATE 2: every builtin under --target=none, all four arches ==="

    # --- (a) refusals are builtin-specific ----------------------------------
    #
    # Every program stores its result into a static so the call is
    # unambiguously live. The PASS condition is deliberately four-legged: a
    # test that only asserts "the generic message is absent" is also satisfied
    # by a syntax error, a missing file or an unrecognised flag.
    #
    # uint32 statics throughout: riscv32 and xtensa reject uint64 in the type
    # checker, and a program that dies there never reaches the lowering under
    # test -- the row would assert nothing and look green.
    A_D="$TMP/audit"; mkdir -p "$A_D"
    au() { printf 'static uint32 sink = 0\nfn main() {\n    %s\n    loop { }\n}\n' "$2" > "$A_D/$1.kr"; }
    au exit              'exit(0)'
    au write             'sink = write(1, "x", 1)'
    au read              'sink = read(0, sink, 1)'
    au print             'print(1)'
    au println           'println(1)'
    au print_str         'print_str("x")'
    au println_str       'println_str("x")'
    au alloc             'sink = alloc(64)'
    au dealloc           'dealloc(sink)'
    au time_ns           'sink = time_ns()'
    au file_open         'sink = file_open("x", 0)'
    au file_close        'sink = file_close(3)'
    au file_read         'sink = file_read(3, sink, 1)'
    au file_write        'sink = file_write(3, "x", 1)'
    au file_size         'sink = file_size(3)'
    au set_executable    'sink = set_executable("x")'
    au exec_process      'sink = exec_process("x")'
    au exec_process_argv 'sink = exec_process_argv("x", sink)'
    au syscall_raw       'sink = syscall_raw(60, 0, 0, 0, 0, 0, 0)'

    G2_BUILTINS=$(ls "$A_D" | sed 's/\.kr$//' | sort)
    G2_NB=$(echo "$G2_BUILTINS" | wc -l)
    # 19 builtin names across 18 lowering sites (print and println share one).
    if [ "$G2_NB" = "19" ]; then
        ok "gate2_builtin_count" "19 builtins in the corpus"
    else
        bad "gate2_builtin_count" "$G2_NB programs, expected 19"
    fi

    for A in x86_64 arm64 riscv32 xtensa; do
        for B in $G2_BUILTINS; do
            OUT="$TMP/au_out"; rm -f "$OUT"
            ERR=$("$KRC" --arch=$A --target=none "$A_D/$B.kr" -o "$OUT" 2>&1); ST=$?
            # exit() on riscv32 and xtensa is a DELIBERATE carve-out, not a
            # miss. ir_xtensa.kr lowers it to a SIMCALL (qemu lx60 semihosting)
            # and ir_riscv.kr to a store to the qemu-virt sifive_test MMIO
            # register, neither of which is a syscall. Both mechanisms are
            # EMULATOR-ONLY and carry an open pre-release decision (see the
            # ledger): SIMCALL is an illegal instruction on real ESP32 silicon
            # and a silent no-op under qemu without -semihosting. Pinned here
            # so that decision cannot be changed silently in either direction.
            if [ "$B" = "exit" ] && { [ "$A" = "riscv32" ] || [ "$A" = "xtensa" ]; }; then
                if [ "$ST" = "0" ] && [ -f "$OUT" ]; then
                    ok "g2_carveout_exit_$A" "compiles: the documented emulator-exit carve-out"
                else
                    bad "g2_carveout_exit_$A" "exit(0) no longer compiles (exit $ST): '$ERR'"
                fi
                rm -f "$OUT"
                continue
            fi
            if [ "$ST" = "0" ]; then
                bad "g2_refuse_${B}_$A" "compiled CLEAN under --target=none -- a fall-through site was missed"
            elif [ -f "$OUT" ]; then
                bad "g2_refuse_${B}_$A" "refused but still wrote an artifact"
            elif echo "$ERR" | grep -q "reached the emitter"; then
                bad "g2_refuse_${B}_$A" "GENERIC emitter backstop fired -- this lowering has no --target=none arm"
            elif ! echo "$ERR" | grep -q "error: --target=none: '$B' is not available on bare metal"; then
                bad "g2_refuse_${B}_$A" "refusal does not name '$B': '$ERR'"
            else
                ok "g2_refuse_${B}_$A"
            fi
            rm -f "$OUT"
        done
    done

    # --- (b) with a provider, the output family and the allocator compile ----
    #
    # The claim under test is that the lowering became a CALL, not that the
    # compiler exited 0: "krc exited 0" is also satisfied by a compiler that
    # emitted nothing at all. Three legs per program -- IR shape, artifact
    # bytes, and DCE in both directions.
    g2mod() { if [ "$1" = "x86_64" ]; then echo "../std/uart_16550.kr"; else echo "../std/uart_pl011.kr"; fi; }

    for A in x86_64 arm64; do
        M=$(g2mod "$A")
        i=0
        for CALL in 'println("hi", 7)' 'print("hi", 7)' 'println_str("hi")' 'print_str("hi")' 'write(1, "hi", 2)'; do
            i=$((i + 1))
            printf 'import "%s"\nfn main() {\n    %s\n    loop { }\n}\n' "$M" "$CALL" > "$INREPO/r.kr"
            rm -f "$INREPO/r.out"
            ERR=$("$KRC" --arch=$A --target=none "$INREPO/r.kr" -o "$INREPO/r.out" 2>&1); ST=$?
            IR=$("$KRC" --arch=$A --target=none --emit=ir "$INREPO/r.kr" 2>&1)
            if [ "$ST" != "0" ] || [ ! -f "$INREPO/r.out" ]; then
                bad "g2_provider_route_${i}_$A" "exit $ST, no artifact: '$ERR'"
            elif echo "$IR" | grep -q "syscall"; then
                bad "g2_provider_route_${i}_$A" "IR still contains a syscall -- the lowering was not rerouted"
            elif echo "$IR" | grep -q "= alloc"; then
                bad "g2_provider_route_${i}_$A" "IR still contains IR_ALLOC -- the format buffer is still a heap call"
            elif ! echo "$IR" | grep -q "call @"; then
                bad "g2_provider_route_${i}_$A" "IR contains no call -- nothing reaches the provider"
            else
                ok "g2_provider_route_${i}_$A"
            fi
            rm -f "$INREPO/r.out"
        done

        # alloc/dealloc and the f-string buffer, through std/heap_bump.kr.
        printf 'import "%s"\nimport "../std/heap_bump.kr"\nfn main() {\n    heap_bump_init(0x200000, 0x100000)\n    uint64 y = 5\n    println(f"x {y}")\n    uint64 p = alloc(32)\n    dealloc(p)\n    loop { }\n}\n' "$M" > "$INREPO/h.kr"
        rm -f "$INREPO/h.out"
        ERR=$("$KRC" --arch=$A --target=none "$INREPO/h.kr" -o "$INREPO/h.out" 2>&1); ST=$?
        IR=$("$KRC" --arch=$A --target=none --emit=ir "$INREPO/h.kr" 2>&1)
        if [ "$ST" != "0" ] || [ ! -f "$INREPO/h.out" ]; then
            bad "g2_provider_heap_$A" "exit $ST, no artifact: '$ERR'"
        elif echo "$IR" | grep -qE "= alloc|dealloc |syscall"; then
            bad "g2_provider_heap_$A" "IR still contains IR_ALLOC/IR_DEALLOC/syscall"
        else
            ok "g2_provider_heap_$A"
        fi

        # DCE, BOTH directions. The provider is reached only through override
        # resolution during IR lowering; dce_scan walks the AST and cannot see
        # that edge. Asserting only "the body is present" would be satisfied by
        # a seed that keeps every override alive unconditionally -- which would
        # put a UART driver in every bare-metal image that never prints.
        printf 'import "%s"\nfn main() {\n    loop { }\n}\n' "$M" > "$INREPO/n.kr"
        printf 'import "%s"\nfn main() {\n    println("hi")\n    loop { }\n}\n' "$M" > "$INREPO/y.kr"
        rm -f "$INREPO/n.out" "$INREPO/y.out"
        "$KRC" --arch=$A --target=none "$INREPO/n.kr" -o "$INREPO/n.out" >/dev/null 2>&1
        "$KRC" --arch=$A --target=none "$INREPO/y.kr" -o "$INREPO/y.out" >/dev/null 2>&1
        if [ ! -f "$INREPO/n.out" ] || [ ! -f "$INREPO/y.out" ]; then
            bad "g2_provider_dce_$A" "one of the two builds produced no artifact"
        else
            NS=$(wc -c < "$INREPO/n.out"); YS=$(wc -c < "$INREPO/y.out")
            if [ "$YS" -gt "$NS" ]; then
                ok "g2_provider_dce_$A" "import-only $NS B, with println $YS B"
            else
                bad "g2_provider_dce_$A" "println pulled in no provider body: $NS B vs $YS B"
            fi
        fi
        # Keep this architecture's three artifacts for the trap scan below.
        # Without the per-arch copies the scan would only ever see whichever
        # arch the loop happened to finish on -- half the coverage, looking
        # exactly as green as the whole of it.
        cp "$INREPO/y.out" "$INREPO/${A}_y.out" 2>/dev/null
        cp "$INREPO/n.out" "$INREPO/${A}_n.out" 2>/dev/null
        cp "$INREPO/h.out" "$INREPO/${A}_h.out" 2>/dev/null
    done

    # The provider body in the BYTES, not merely "some call". This is the leg
    # that proves the artifact contains the actual UART store. Asserted in both
    # directions so a disassembler printing nothing cannot pass it. No capable
    # objdump is a FAILURE, not a skip -- it is the artifact proof.
    # x86_64's OWN pair, named explicitly: the loop above finishes on arm64, so
    # disassembling whatever y.out/n.out happen to be finds a PL011 store with
    # an x86 disassembler and reports 0-and-0, which reads as "the UART store
    # is missing" when it is present. That is a false FAIL today and would be a
    # false PASS the moment the both-directions condition were relaxed.
    #
    # `command -v objdump` proves one is INSTALLED, not that it can decode x86.
    # Ubuntu builds binutils with one target set per host arch: on an arm64 host
    # /usr/bin/objdump knows aarch64 and nothing else, so `-m i386:x86-64` writes
    # "can't use supplied machine i386:x86-64" to stderr (swallowed by
    # 2>/dev/null), prints no instructions, and BOTH counts come back 0 -- read
    # here, correctly, as "the UART store is missing". That was the Linux ARM64
    # CI failure. So probe by DOING the disassembly on a lone 0xee byte and
    # requiring the very pattern grepped for below; a tool that decodes x86 but
    # spells the operand differently is rejected here rather than silently
    # scoring 0 there. CI installs binutils-x86-64-linux-gnu on the arm64 runner
    # so a capable one is always found.
    PAT='out[[:space:]]+%al,\(%dx\)'
    printf '\356' > "$INREPO/probe.bin"   # 0xee, the one-byte `out %al,(%dx)`
    OD=""
    for C in objdump x86_64-linux-gnu-objdump gobjdump x86_64-elf-objdump; do
        command -v "$C" >/dev/null 2>&1 || continue
        if [ "$("$C" -D -b binary -m i386:x86-64 "$INREPO/probe.bin" 2>/dev/null \
                | grep -cE "$PAT")" -ge 1 ]; then
            OD="$C"; break
        fi
    done
    if [ -n "$OD" ]; then
        HAS=$("$OD" -D -b binary -m i386:x86-64 "$INREPO/x86_64_y.out" 2>/dev/null | grep -cE "$PAT")
        NOT=$("$OD" -D -b binary -m i386:x86-64 "$INREPO/x86_64_n.out" 2>/dev/null | grep -cE "$PAT")
        if [ "$HAS" -ge 1 ] && [ "$NOT" = "0" ]; then
            ok "g2_uart_store_in_bytes" "$HAS out instructions with the println via $OD, 0 without"
        else
            bad "g2_uart_store_in_bytes" "with println: $HAS, without: $NOT, via $OD"
        fi
    else
        bad "g2_uart_store_in_bytes" "no objdump on PATH can disassemble x86-64 -- install binutils-x86-64-linux-gnu; this is the artifact proof, not an optional extra"
    fi

    # riscv32/xtensa have NO provider path, and the reason is a language limit
    # rather than a --target=none decision: the override's required signature
    # is `fn write(uint64, uint64, uint64) -> uint64` and both arches reject
    # uint64 in the type checker. Pinned with the exact diagnostic so that when
    # riscv32 grows 64-bit integers, this fails and somebody revisits it
    # instead of finding the providers quietly still unavailable.
    for A in riscv32 xtensa; do
        printf 'import "../std/uart_pl011.kr"\nfn main() {\n    println("hi")\n    loop { }\n}\n' > "$INREPO/p32.kr"
        rm -f "$INREPO/p32.out"
        ERR=$("$KRC" --arch=$A --target=none "$INREPO/p32.kr" -o "$INREPO/p32.out" 2>&1); ST=$?
        if [ "$ST" != "0" ] && [ ! -f "$INREPO/p32.out" ] \
           && echo "$ERR" | grep -q "64-bit integers not supported on $A"; then
            ok "g2_no_provider_$A" "provider modules need uint64, which $A rejects"
        else
            bad "g2_no_provider_$A" "expected the uint64 refusal, got exit $ST: '$ERR'"
        fi
        rm -f "$INREPO/p32.out"
    done

    # --- (b2) IR_ALLOC sites with NO --target=none arm ----------------------
    #
    # READ THE POLARITY BEFORE READING THE ASSERTIONS. Everywhere else in this
    # gate, the generic emitter backstop firing is a FAILURE. Here it is what
    # is asserted, because it is what happens today and pretending otherwise
    # would leave the behaviour unrecorded.
    #
    # src/ir.kr emits IR_ALLOC from six sites that have no --target=none arm
    # and no provider routing:
    #   :3413  struct copy on assignment
    #   :3461  struct returned by value
    #   :3894  struct literal
    #   :4164  local array over the stack-array threshold
    #   :4192  struct declaration with an initialiser
    #   :4209  local array OF structs
    # Only the print/f-string IR_ALLOC was rerouted (Task 5). So on bare metal
    # a struct literal, or a `uint32[2048]`, refuses with the GENERIC message
    # naming 'alloc' -- a builtin the programmer never wrote -- and it does so
    # EVEN WITH std/heap_bump.kr imported, which is the whole remedy the
    # diagnostic would otherwise be pointing at.
    #
    # It FAILS CLOSED: exit 1, no artifact, no syscall in anything shipped. So
    # this is not a safety hole, it is an incomplete feature with a misleading
    # diagnostic -- structs are effectively unusable on bare metal. By this
    # branch's own standard it is a missing arm.
    #
    # PINNED, NOT ENDORSED. Provider routing for these six sites is a FOLLOW-UP
    # and is explicitly not done in this round. What this pin buys is that the
    # day someone routes them, these checks fail and force the pin to be
    # rewritten as the real assertion -- rather than the behaviour changing with
    # nothing recording that it ever looked like this.
    for A in x86_64 arm64; do
        M=$(g2mod "$A")
        printf 'import "%s"\nimport "../std/heap_bump.kr"\nstruct P { uint64 x  uint64 y }\nfn main() {\n    heap_bump_init(0x200000, 0x100000)\n    P p = P { x: 1, y: 2 }\n    println("v=", p.x)\n    loop { }\n}\n' "$M" > "$INREPO/st.kr"
        printf 'import "%s"\nimport "../std/heap_bump.kr"\nfn main() {\n    heap_bump_init(0x200000, 0x100000)\n    uint32[2048] big\n    big[3] = 7\n    println("v=", big[3])\n    loop { }\n}\n' "$M" > "$INREPO/bigarr.kr"
        for W in st bigarr; do
            rm -f "$INREPO/$W.out"
            ERR=$("$KRC" --arch=$A --target=none "$INREPO/$W.kr" -o "$INREPO/$W.out" 2>&1); ST=$?
            if [ "$ST" = "0" ] || [ -f "$INREPO/$W.out" ]; then
                bad "g2_ir_alloc_unrouted_${W}_$A" "this now COMPILES -- if the six IR_ALLOC sites were routed to the provider, rewrite this pin as a real provider assertion"
            elif ! echo "$ERR" | grep -q "reached the emitter from 'alloc'"; then
                bad "g2_ir_alloc_unrouted_${W}_$A" "expected the generic backstop naming 'alloc', got: '$ERR'"
            else
                ok "g2_ir_alloc_unrouted_${W}_$A" "refuses via the generic backstop naming 'alloc', heap_bump imported and unused"
            fi
            rm -f "$INREPO/$W.out"
        done
    done
    # The CONTROL, without which the two checks above are vacuous: "refuses
    # naming 'alloc'" is satisfied by a build where nothing at all works. A
    # local array UNDER the stack-array threshold takes IR_STACK_ADDR instead
    # of IR_ALLOC and must COMPILE with the same imports, so what the pin
    # records is those specific constructs and not bare metal in general.
    for A in x86_64 arm64; do
        M=$(g2mod "$A")
        printf 'import "%s"\nimport "../std/heap_bump.kr"\nfn main() {\n    heap_bump_init(0x200000, 0x100000)\n    uint32[16] small\n    small[3] = 7\n    println("v=", small[3])\n    loop { }\n}\n' "$M" > "$INREPO/smallarr.kr"
        rm -f "$INREPO/smallarr.out"
        ERR=$("$KRC" --arch=$A --target=none "$INREPO/smallarr.kr" -o "$INREPO/smallarr.out" 2>&1); ST=$?
        if [ "$ST" = "0" ] && [ -f "$INREPO/smallarr.out" ]; then
            ok "g2_ir_alloc_control_small_array_$A" "under the threshold: IR_STACK_ADDR, compiles"
        else
            bad "g2_ir_alloc_control_small_array_$A" "a stack-sized local array does not compile either, so the two pins above assert nothing specific: '$ERR'"
        fi
        rm -f "$INREPO/smallarr.out"
    done

    # riscv32/xtensa never reach the backstop: IR_ALLOC (op 70) is unimplemented
    # in those backends at all, hosted included. Different message, same
    # fail-closed outcome, pinned separately so the two are not conflated.
    printf 'struct P { uint32 x  uint32 y }\nfn main() {\n    P p = P { x: 1, y: 2 }\n    loop { }\n}\n' > "$INREPO/st32.kr"
    for A in riscv32 xtensa; do
        rm -f "$INREPO/st32.out"
        ERR=$("$KRC" --arch=$A --target=none "$INREPO/st32.kr" -o "$INREPO/st32.out" 2>&1); ST=$?
        if [ "$ST" = "0" ] || [ -f "$INREPO/st32.out" ]; then
            bad "g2_ir_alloc_unrouted_struct_$A" "this now compiles -- IR op 70 must have been implemented; rewrite this pin"
        elif ! echo "$ERR" | grep -q "error: $A: IR op 70 not yet implemented"; then
            bad "g2_ir_alloc_unrouted_struct_$A" "expected the IR op 70 NYI refusal, got: '$ERR'"
        else
            ok "g2_ir_alloc_unrouted_struct_$A" "IR op 70 NYI -- fails closed, by a different route"
        fi
        rm -f "$INREPO/st32.out"
    done

    # --- (b3) -g under --target=none: an ACCEPTED flag, recorded ------------
    #
    # Task 6 refused --debug and --legacy under --target=none and recorded why.
    # -g was never ruled on. It is ACCEPTED, and the decision is recorded here
    # as an assertion rather than a sentence: DWARF is inert data that no code
    # reads at runtime and it emits no instructions, so unlike --debug (which
    # emits bounds-check traps) there is nothing about it that needs an OS.
    # Pinned in three directions -- it compiles, it is byte-identical to the
    # --freestanding -g artifact (so --target=none adds nothing of its own to
    # the debug path), and it is NOT a no-op (it differs from the same build
    # without -g, so a future change that silently dropped DWARF fails here).
    printf 'fn main() { loop { } }\n' > "$INREPO/g.kr"
    rm -f "$INREPO/g_tn" "$INREPO/g_fs" "$INREPO/g_plain"
    "$KRC" --arch=x86_64 --target=none    -g "$INREPO/g.kr" -o "$INREPO/g_tn"    >/dev/null 2>&1
    "$KRC" --arch=x86_64 --freestanding   -g "$INREPO/g.kr" -o "$INREPO/g_fs"    >/dev/null 2>&1
    "$KRC" --arch=x86_64 --target=none       "$INREPO/g.kr" -o "$INREPO/g_plain" >/dev/null 2>&1
    if [ ! -f "$INREPO/g_tn" ]; then
        bad "g2_dash_g_accepted" "-g under --target=none no longer compiles; if it is now refused, this pin records the old decision and must be rewritten"
    elif ! cmp -s "$INREPO/g_tn" "$INREPO/g_fs"; then
        bad "g2_dash_g_accepted" "--target=none -g and --freestanding -g no longer agree"
    elif cmp -s "$INREPO/g_tn" "$INREPO/g_plain"; then
        bad "g2_dash_g_accepted" "-g is a no-op under --target=none -- the DWARF is not being emitted"
    else
        ok "g2_dash_g_accepted" "$(wc -c < "$INREPO/g_tn") B with -g vs $(wc -c < "$INREPO/g_plain") B without, identical to --freestanding -g"
    fi

    # --- (c) no trap instruction in any artifact ----------------------------
    #
    # Every artifact --target=none produced above is scanned for ALL FOUR trap
    # encodings, not just its own arch's: a cross-wired backend emitting the
    # wrong architecture's trap is exactly the kind of thing a per-arch scan
    # would miss.
    #
    # The scan searches raw BYTES at every offset. It is deliberately not
    # instruction-aligned -- these are flat images with no section table to
    # align against, and an unaligned hit is worth reporting anyway. What it
    # avoids is the NIBBLE-boundary false positive: `xxd -p | grep 0f05`
    # matches half-way through a byte pair, so bytes A0 F0 5B read as a
    # SYSCALL that is not there. Scanning bytes rather than a hex string
    # cannot make that mistake. The trade is the opposite direction --
    # constant data that happens to spell a trap encoding would be reported,
    # which is a false FAIL and would be investigated, not a false pass.
    #
    #   x86_64  SYSCALL  0F 05
    #   arm64   SVC #0   0xD4000001 little-endian -> 01 00 00 D4
    #   riscv32 ECALL    0x00000073 little-endian -> 73 00 00 00
    #   xtensa  SIMCALL  xt_rrr(0,0,1,5,0,0) = word 0x005100, 24-bit
    #                    little-endian -> 00 51 00
    #
    # The xtensa exit() artifact is the ONE place a SIMCALL is expected, and it
    # is asserted PRESENT rather than excluded, so the carve-out cannot vanish
    # unnoticed. Everything else must be clean.
    rm -f "$INREPO/e_rv" "$INREPO/e_xt"
    printf 'fn main() { exit(0) }\n' > "$INREPO/e.kr"
    "$KRC" --arch=riscv32 --target=none "$INREPO/e.kr" -o "$INREPO/e_rv" >/dev/null 2>&1
    "$KRC" --arch=xtensa  --target=none "$INREPO/e.kr" -o "$INREPO/e_xt" >/dev/null 2>&1

    G2_TRAP=$(TN_FILES="$INREPO/x86_64_y.out $INREPO/x86_64_n.out $INREPO/x86_64_h.out $INREPO/arm64_y.out $INREPO/arm64_n.out $INREPO/arm64_h.out $INREPO/e_rv $INREPO/e_xt $INREPO/g_tn" python3 - <<'TRAPPY'
import os, sys
TRAPS = {"x86_SYSCALL": b"\x0f\x05", "arm64_SVC": b"\x01\x00\x00\xd4",
         "riscv32_ECALL": b"\x73\x00\x00\x00", "xtensa_SIMCALL": b"\x00\x51\x00"}
found, simcall_in_xt = [], 0
for path in os.environ["TN_FILES"].split():
    if not os.path.exists(path):
        found.append("%s: MISSING -- nothing was scanned" % os.path.basename(path))
        continue
    data = open(path, "rb").read()
    for name, enc in TRAPS.items():
        n = data.count(enc)
        if n == 0:
            continue
        if path.endswith("e_xt") and name == "xtensa_SIMCALL":
            simcall_in_xt = n
            continue
        found.append("%s: %d x %s" % (os.path.basename(path), n, name))
if simcall_in_xt != 1:
    found.append("xtensa exit() artifact holds %d SIMCALL words, expected exactly 1 "
                 "(the documented semihosting carve-out)" % simcall_in_xt)
print("; ".join(found))
TRAPPY
)
    if [ -z "$G2_TRAP" ]; then
        ok "g2_no_trap_instructions" "9 bare-metal artifacts (incl. the -g build), 0 traps outside the xtensa exit carve-out"
    else
        bad "g2_no_trap_instructions" "$G2_TRAP"
    fi
}

case "$MODE" in
    gate1) gate1 ;;
    gate2) gate2 ;;
    both)  gate1; gate2 ;;
esac

echo ""
echo "=== prove_no_syscalls: $PASS passed, $FAIL failed ==="
echo "    A green run says the compiler emits the right calls and refuses the"
echo "    right builtins. It does NOT say anything has run on bare metal --"
echo "    see the TODO(sub-project B) serial-output leg at the top of this file."
[ "$FAIL" = "0" ] || exit 1
exit 0
