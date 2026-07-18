#!/bin/bash
# Assemble an .s with the LX106 base-ISA assembler (no relaxation/narrowing)
# and print "offset: bytes  mnemonic operands" — the canonical encoding to
# match krc's --arch=xtensa output against. Usage: xt-golden.sh file.s
set -e
AS=xtensa-lx106-elf-as; OD=xtensa-lx106-elf-objdump
tmp=$(mktemp -d)
$AS --no-transform -o "$tmp/a.o" "$1"
$OD -d --show-raw-insn "$tmp/a.o" | sed -n '/<.*>:/,$p'
rm -rf "$tmp"
