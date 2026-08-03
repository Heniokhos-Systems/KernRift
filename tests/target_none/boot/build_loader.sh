#!/bin/bash
# Build the multiboot long-mode loader with the KernRift image's entry VA
# baked in (--defsym; movabs resolves it via R_X86_64_64 at link).
#
# REQUIRED toolchain: an x86-capable GNU assembler + linker. FUNCTIONALLY
# PROBED, not `command -v`-checked: on an aarch64 host (the Linux ARM64 CI
# job runs this suite) bare `as` EXISTS and is the aarch64 assembler —
# `command -v as` answers "yes" and means "no", and the build would die
# with an unrelated assembler error (review round 1 C4). Each candidate
# must actually assemble x86 / link elf_i386 to be selected. Absence of
# every candidate is a FAILURE naming the probe list, never a skip — the
# suite's qemu-skip pattern (tests/run_tests.sh:5240) is exactly how a
# previous gate went vacuous. GNU-specific: the boot gate is
# Linux-host-only by decision (see the plan's Global Constraints).
#
# Usage: build_loader.sh <entry_va> <out.elf>
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
ENTRY="$1"; OUT="$2"
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT INT TERM
AS=""
for cand in as x86_64-linux-gnu-as i686-linux-gnu-as; do
    command -v "$cand" >/dev/null 2>&1 || continue
    if printf '.long 0\n' | "$cand" --32 -o "$TMPD/probe.o" - >/dev/null 2>&1; then
        AS="$cand"; break
    fi
done
if [ -z "$AS" ]; then
    echo "FAIL: no x86-capable GNU assembler found (probed: as, x86_64-linux-gnu-as, i686-linux-gnu-as) -- the x86_64 boot leg REQUIRES one; absence is a failure, not a skip" >&2
    exit 1
fi
LD=""
for cand in ld x86_64-linux-gnu-ld i686-linux-gnu-ld; do
    command -v "$cand" >/dev/null 2>&1 || continue
    if "$cand" -m elf_i386 --version >/dev/null 2>&1; then
        LD="$cand"; break
    fi
done
if [ -z "$LD" ]; then
    echo "FAIL: no GNU ld with elf_i386 emulation found (probed: ld, x86_64-linux-gnu-ld, i686-linux-gnu-ld) -- the x86_64 boot leg REQUIRES one; absence is a failure, not a skip" >&2
    exit 1
fi
"$AS" --32 --defsym KR_ENTRY_VA="$ENTRY" -o "$TMPD/boot.o" "$DIR/boot.S" || exit 1
"$LD" -m elf_i386 -T "$DIR/boot.ld" -o "$OUT" "$TMPD/boot.o" || exit 1
# Self-test: the multiboot magic (0x1BADB002 little-endian) must sit in the
# first 8 KiB, the window the multiboot loader scans. Derived from the file,
# not asserted from the source — "length asserted not derived" produced four
# defects in one day elsewhere in this tree.
if ! head -c 8192 "$OUT" | od -An -tx1 | tr -d ' \n' | grep -q "02b0ad1b"; then
    echo "FAIL: multiboot magic not within the first 8 KiB of $OUT" >&2
    exit 1
fi
exit 0
