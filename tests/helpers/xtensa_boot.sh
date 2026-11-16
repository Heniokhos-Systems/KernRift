# The ONE place the test scripts start qemu-system-xtensa (#228); sourced by
# tests/run_tests.sh. Row xtensa_boot_single_site keeps every other site out.
#
# xt_boot SECS ELF boots ELF on the lx60 board for at most SECS seconds. Its
# stdout is the guest's stdout; its status is qemu's (or timeout's: 124).
#
# WHY NOT PLAIN `-kernel`. QEMU 10.2.0 (commit 18727804c065, "hw/xtensa/xtfpga:
# Have xtfpga_init() only initialize MMU"; still on master when this was
# written, upstream defect #321 in this project's register) writes xtfpga's
# -kernel boot trampoline before the CPU is reset, so it is not written at the
# reset vector 0xfe000000: the CPU starts there on zeros (`ill`) and loops in
# the exception vector until the timeout. QEMU <= 10.1 wrote the trampoline at
# the reset vector and booted the same images. -kernel is kept (it does
# xtfpga's MMU-translated ELF load: the images' 0xd0000000 is physical 0 on
# the DC232B core), and a PC-only generic loader,
# `-device loader,addr=<e_entry>,cpu-num=0`, sets the CPU's PC to the ELF's
# entry point at reset (QEMU >= 2.9). Measured: 10.2.1 and 8.2.2 both start at
# e_entry this way. The only state the old trampoline set and this does not is
# a0 = entry and a2 = the boot-parameter tag pointer; no row image reads either.
#
# The entry point is read with od (coreutils only). The file must be an Elf32,
# little-endian, EM_XTENSA (0x5e) image; anything else is REFUSED: status 99
# (neither qemu, timeout nor a row image exits 99) and one line
# `xt_boot: refused <elf>: <reason>` on STDOUT, because the rows capture stdout
# and discard qemu's stderr. qemu is never started for a refused file.
xt_boot() {
    local secs="$1" elf="$2" h why="" entry
    h=$(od -An -v -tx1 -N 28 -- "$elf" 2> /dev/null | tr -d ' \n')
    if [ ! -r "$elf" ] || [ ! -f "$elf" ]; then why="not a readable file"
    elif [ "${h:0:8}" != 7f454c46 ]; then why="not an ELF file"
    elif [ "${#h}" -lt 56 ]; then why="shorter than an Elf32 header"
    elif [ "${h:8:2}" != 01 ]; then why="EI_CLASS $(printf '0x%x' "0x${h:8:2}") is not ELFCLASS32"
    elif [ "${h:10:2}" != 01 ]; then why="EI_DATA $(printf '0x%x' "0x${h:10:2}") is not ELFDATA2LSB"
    elif [ "${h:38:2}${h:36:2}" != 005e ]; then
        why="e_machine $(printf '0x%x' "0x${h:38:2}${h:36:2}") is not EM_XTENSA (0x5e)"
    else
        entry="0x${h:54:2}${h:52:2}${h:50:2}${h:48:2}"
    fi
    if [ -n "$why" ]; then
        echo "xt_boot: refused $elf: $why"
        return 99
    fi
    timeout "$secs" qemu-system-xtensa -M lx60 -nographic -semihosting -kernel "$elf" -device "loader,addr=$entry,cpu-num=0"
}
