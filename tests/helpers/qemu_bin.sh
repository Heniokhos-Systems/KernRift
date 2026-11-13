# The ONE qemu-user resolver of the test scripts (#227); sourced by
# tests/run_tests.sh, tests/diff_ir_legacy.sh, tests/diff_ir_legacy_stdout.sh
# and tests/diff/run.sh.
#
# qemu_bin NAME (aarch64, x86_64, riscv32, ...) prints the path of the
# "-static" build of qemu-NAME when one is on PATH, else of plain qemu-NAME,
# else nothing (status 1). Debian's qemu-user-static ships the suffixed names;
# Ubuntu 26.04's qemu-user ships only the plain ones (static-pie binaries, so
# the plain name serves the same purpose, including inside a container).
# Sites used to probe the suffixed name alone and then skipped -- or ran
# nothing -- on a host that had qemu under its plain name. The row
# qemu_resolver_single_site keeps every other site from naming a suffixed
# binary literally.
qemu_bin() {
    command -v "qemu-$1-static" 2> /dev/null || command -v "qemu-$1" 2> /dev/null
}
