#!/bin/bash
# Build .deb packages for KernRift
# Usage: ./build-deb.sh [version]
# Produces: kernrift_VERSION_amd64.deb and kernrift_VERSION_arm64.deb
set -e

REPO="Pantelis23/KernRift"

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
Description: Self-hosted systems language compiler for kernel development
 KernRift is a self-hosting systems language compiler that produces
 native executables for x86_64 and AArch64. It compiles itself to a
 fixed point in 55ms on modern hardware. Features include inline assembly, naked
 functions, packed structs, signed comparisons, bitfield operations,
 volatile memory access, and freestanding mode for bare-metal targets.
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

    # Download stdlib
    for mod in string io math fmt mem vec map color fb fixedpoint font memfast widget time log net; do
        echo "  Downloading std/$mod.kr..."
        curl -sSLf -o "$PKG/usr/share/kernrift/std/$mod.kr" "$RAW/std/$mod.kr"
    done

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
