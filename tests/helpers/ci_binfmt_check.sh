#!/bin/bash
# ci_binfmt_check.sh -- fail when a qemu binfmt_misc handler for an arch other
# than this host's own is enabled (#272; run by .github/workflows/ci.yml after
# each qemu install on both Linux jobs, never by the suite: a developer host
# may legitimately have qemu-user-binfmt, and run_tests.sh only prints the
# state in its header).
#
# With such a handler the kernel runs that arch's binaries through qemu by
# itself, so a row meant to run a foreign binary only through
# tests/helpers/qemu_bin.sh, or to SKIP or refuse because the host cannot run
# it, would exec it directly and could pass without testing what it claims.
# Ubuntu 24.04's qemu-user-static and the qemu-user-binfmt package (which
# qemu-user recommends) register one for every arch; CI installs only
# `qemu-user --no-install-recommends`.
# Prints every qemu-* handler with its state; exit 0 when none is foreign and
# enabled (or binfmt_misc is not mounted), 1 otherwise, naming the handler and
# the package that registered it.
case "$(uname -m)" in
    x86_64) own=qemu-x86_64 ;;
    aarch64|arm64) own=qemu-aarch64 ;;
    *) own="" ;;
esac
d=/proc/sys/fs/binfmt_misc
if [ ! -r "$d/status" ]; then
    echo "binfmt: binfmt_misc not mounted"
    exit 0
fi
echo "binfmt: $(cat "$d/status") ($(uname -m) host; its own handler would be ${own:-none})"
bad=""
for f in "$d"/qemu-*; do
    [ -e "$f" ] || continue
    n=${f##*/}
    st=$(head -1 "$f")
    echo "  $n: $st"
    if [ "$st" = enabled ] && [ "$n" != "$own" ]; then
        pkg=""
        for c in "/usr/lib/binfmt.d/$n.conf" "/lib/binfmt.d/$n.conf" "/usr/share/binfmts/$n" "/var/lib/binfmts/$n"; do
            [ -e "$c" ] || continue
            pkg=$(dpkg -S "$c" 2> /dev/null | head -1 | cut -d: -f1)
            [ -n "$pkg" ] && break
        done
        bad="$bad $n (${pkg:-unknown package})"
    fi
done
if [ -n "$bad" ]; then
    echo "FAIL: foreign-arch qemu binfmt handler(s) enabled, registered by:$bad -- the suite must reach foreign binaries only through qemu_bin: install qemu-user with --no-install-recommends and nothing that ships binfmt.d files"
    exit 1
fi
echo "binfmt: no foreign-arch qemu handler enabled"
exit 0
