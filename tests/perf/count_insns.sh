#!/bin/bash
# count_insns.sh <compiler> <port.kr> <x86_64|arm64> [compiler flags...]
# (#143 A15, spec 9): builds <port.kr> + exit_<arch>.kr as a Windows-ABI
# freestanding ELF (--freestanding --target=windows --arch=<arch> [flags]) and
# runs it under qemu-user (qemu_bin, tests/helpers/qemu_bin.sh: qemu-aarch64 for
# arm64) with one guest instruction per translation
# block and chaining off, logging every executed TB through a FIFO into
# `wc -l`: the line count is the number of guest instructions executed.
# PEU_N=<n> replaces the token PEU_N in the source (calib.kr).
# Prints "<count> <exit status>"; exits 0 when it ran, 2 on a build or tool
# error (message on stderr).
set -u
KRC="${1:?usage: count_insns.sh <compiler> <port.kr> <x86_64|arm64> [flags]}"; SRC="${2:?port}"; ARCH="${3:?arch}"; shift 3
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../helpers/qemu_bin.sh"
QN=$ARCH; [ "$ARCH" = arm64 ] && QN=aarch64
QEMU="$(qemu_bin $QN)"
[ -n "$QEMU" ] || { echo "count_insns.sh: no qemu-$QN (qemu_bin tries the -static name, then the plain one)" >&2; exit 2; }
mkdir -p "${PEU_PERF_TMP:-$HOME/.cache/pe_unwind}" || { echo "count_insns.sh: cannot create the scratch root" >&2; exit 2; }
W=$(mktemp -d "${PEU_PERF_TMP:-$HOME/.cache/pe_unwind}/cnt.XXXXXX") || { echo "count_insns.sh: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$W"' EXIT
{ sed "s/PEU_N/${PEU_N:-0}/g" "$SRC"; cat "$HERE/exit_$ARCH.kr"; } > "$W/p.kr"
if ! ( ulimit -v 2000000; timeout 120 "$KRC" --freestanding --target=windows --arch=$ARCH "$@" "$W/p.kr" -o "$W/p.elf" ) > "$W/b.log" 2>&1; then
    echo "count_insns.sh: build failed: $(grep -m1 error "$W/b.log")" >&2; exit 2
fi
chmod +x "$W/p.elf"
mkfifo "$W/f"
wc -l < "$W/f" > "$W/n" &
WC=$!
timeout 1800 "$QEMU" -one-insn-per-tb -d exec,nochain -D "$W/f" "$W/p.elf" > /dev/null 2>&1; RC=$?
wait "$WC"
echo "$(tr -d ' ' < "$W/n") $RC"
