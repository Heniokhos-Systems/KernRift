#!/bin/bash
# Build .deb packages for KernRift
# Usage: ./build-deb.sh [version]
# Produces: kernrift_VERSION_amd64.deb and kernrift_VERSION_arm64.deb
set -e

REPO="Heniokhos-Systems/KernRift"

if [ -z "${1:-}" ]; then
    echo "Fetching latest version from GitHub..."
    VERSION=$(curl -sSL "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
    BASE="https://github.com/$REPO/releases/latest/download"
    echo "Latest version is $VERSION"
else
    VERSION="$1"
    BASE="https://github.com/$REPO/releases/download/v$VERSION"
fi

RAW="https://raw.githubusercontent.com/$REPO/main"

build_deb() {
    local arch="$1"      # amd64 or arm64
    local bin_name="$2"  # krc-linux-x86_64 or krc-linux-arm64
    local kr_name="$3"   # kr-linux-x86_64 or kr-linux-arm64

    local PKG="kernrift_${VERSION}_${arch}"
    rm -rf "$PKG"

    # Create directory structure
    mkdir -p "$PKG/DEBIAN"
    mkdir -p "$PKG/usr/bin"
    mkdir -p "$PKG/usr/share/kernrift/std"
    mkdir -p "$PKG/usr/share/doc/kernrift"

    # Control file
    cat > "$PKG/DEBIAN/control" <<EOF
Package: kernrift
Version: $VERSION
Section: devel
Priority: optional
Architecture: $arch
Maintainer: Pantelis Christou <contact@heniokhos.com>
Homepage: https://kernrift.org
Description: Self-hosted systems language compiler for kernel and bare-metal development
 KernRift is a self-hosting systems language compiler with an optimising IR
 backend (not SSA) that emits native machine code directly -- no LLVM, no C,
 no external assembler. It produces native executables for x86_64 and AArch64 and
 cross-compiles bare-metal for RISC-V 32 and Xtensa LX6, including direct-boot
 ESP32 images and Linux kernel modules. It self-compiles in about half a second
 on modern hardware, reaching a bit-identical bootstrap fixed point. Kernel-first
 features include device blocks for typed MMIO, inline assembly, atomic and
 bitfield operations, signed comparisons, slice parameters, and a freestanding
 mode for targets with no operating system.
 .
 The compiler is a single static binary with zero dependencies.
EOF

    # Download krc binary
    echo "  Downloading $bin_name..."
    curl -sSLf -o "$PKG/usr/bin/krc" "$BASE/$bin_name"
    chmod 755 "$PKG/usr/bin/krc"

    # Download kr runner
    echo "  Downloading $kr_name..."
    curl -sSLf -o "$PKG/usr/bin/kr" "$BASE/$kr_name"
    chmod 755 "$PKG/usr/bin/kr"

    # Download stdlib.
    #
    # The list is READ FROM THE REPO, not hardcoded. It used to be a literal
    # list of 19 modules and it silently went stale: v2.10.0 ships 35, so a
    # .deb built from the old list was missing all 16 bare-metal ones --
    # vga_text, ps2, serial, idt, pci, x86, cstr and the rest -- which are the
    # headline of that release. An apt user would have installed a compiler
    # whose advertised stdlib did not exist.
    echo "  Listing std/ from the repo..."
    STD_MODS=$(curl -sSLf "https://api.github.com/repos/$REPO/contents/std?ref=v$VERSION" \
               | grep -oE '"name": *"[a-zA-Z0-9_]+\.kr"' | sed -E 's/.*"([^"]+\.kr)"/\1/' | sort -u)
    if [ -z "$STD_MODS" ]; then
        echo "ERROR: could not list std/ from the repo -- refusing to build a .deb" >&2
        echo "  a silently short stdlib is worse than no package" >&2
        exit 1
    fi
    STD_N=0
    for modf in $STD_MODS; do
        echo "  Downloading std/$modf..."
        curl -sSLf -o "$PKG/usr/share/kernrift/std/$modf" "$RAW/std/$modf"
        STD_N=$((STD_N + 1))
    done
    echo "  stdlib: $STD_N modules"
    if [ "$STD_N" -lt 30 ]; then
        echo "ERROR: only $STD_N stdlib modules -- expected 35+; refusing to ship" >&2
        exit 1
    fi

    # Copyright files
    echo "  Downloading LICENSE and NOTICE..."
    curl -sSLf -o "$PKG/usr/share/doc/kernrift/LICENSE" "$BASE/LICENSE"
    curl -sSLf -o "$PKG/usr/share/doc/kernrift/NOTICE" "$BASE/NOTICE"

    # Build .deb
    dpkg-deb --build --root-owner-group "$PKG"
    echo "  Built: ${PKG}.deb"
    rm -rf "$PKG"
}

echo "=== Building KernRift $VERSION .deb packages ==="
build_deb "amd64" "krc-linux-x86_64" "kr-linux-x86_64"
build_deb "arm64" "krc-linux-arm64" "kr-linux-arm64"
echo "=== Done ==="
