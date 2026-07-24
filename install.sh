#!/bin/sh
# KernRift Installer — download and install krc + kr from GitHub releases
# Usage: curl -sSf https://raw.githubusercontent.com/Heniokhos-Systems/KernRift/main/install.sh | sh
#
# Alternative installation methods:
#   Homebrew (macOS/Linux):  brew install heniokhos-systems/kernrift/kernrift
#   Scoop (Windows):         scoop bucket add kernrift https://github.com/Heniokhos-Systems/KernRift && scoop install kernrift
#   Winget (Windows):        winget install Pantelis23.KernRift
#   Debian/Ubuntu (.deb):    curl -sSLO https://github.com/.../kernrift_2.5.0_amd64.deb && sudo dpkg -i kernrift_*.deb
#   AUR (Arch Linux):        yay -S kernrift
#   PowerShell (Windows):    irm https://raw.githubusercontent.com/Heniokhos-Systems/KernRift/main/install.ps1 | iex
#
set -e

REPO="Heniokhos-Systems/KernRift"

# Detect platform
ARCH=$(uname -m)
IS_ANDROID=0
IS_TERMUX=0
if [ -f "/system/bin/linker64" ]; then
    IS_ANDROID=1
    if [ -d "/data/data/com.termux/files" ]; then
        IS_TERMUX=1
    fi
fi

case "$ARCH" in
    x86_64|amd64) ARCH_NAME="x86_64" ;;
    aarch64|arm64) ARCH_NAME="arm64" ;;
    *) echo "error: unsupported architecture: $ARCH"; exit 1 ;;
esac

OS=$(uname -s)
case "$OS" in
    Linux)
        if [ "$IS_ANDROID" = "1" ]; then
            OS_NAME="android"
        else
            OS_NAME="linux"
        fi
        ;;
    Darwin) OS_NAME="macos" ;;
    *)      echo "error: unsupported OS: $OS"; exit 1 ;;
esac

# Set install directory based on environment
if [ "$IS_TERMUX" = "1" ]; then
    INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
    STD_DIR="$HOME/.local/share/kernrift/std"
elif [ "$IS_ANDROID" = "1" ]; then
    INSTALL_DIR="${INSTALL_DIR:-/data/local/tmp/kernrift}"
    STD_DIR="/data/local/tmp/kernrift/std"
else
    INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
    STD_DIR="$HOME/.local/share/kernrift/std"
fi

echo "=== KernRift Installer ==="
if [ "$IS_TERMUX" = "1" ]; then
    echo "Platform: Android (Termux) ARM64"
elif [ "$IS_ANDROID" = "1" ]; then
    echo "Platform: Android (adb) ARM64"
else
    echo "Platform: $OS_NAME $ARCH_NAME"
fi
echo "Install to: $INSTALL_DIR"
echo ""

mkdir -p "$INSTALL_DIR"

BASE="https://github.com/$REPO/releases/latest/download"

# Download krc compiler
if [ "$IS_ANDROID" = "1" ]; then
    KRC_ASSET="krc-android-arm64"
    KR_ASSET="kr-android-arm64"
elif [ "$OS_NAME" = "macos" ]; then
    KRC_ASSET="krc-macos-$ARCH_NAME"
    KR_ASSET="kr-macos-$ARCH_NAME"
else
    KRC_ASSET="krc-linux-$ARCH_NAME"
    KR_ASSET="kr-linux-$ARCH_NAME"
fi

echo "Downloading $KRC_ASSET..."
curl -sL -o "$INSTALL_DIR/krc" "$BASE/$KRC_ASSET"
chmod +x "$INSTALL_DIR/krc"

echo "Downloading $KR_ASSET..."
if [ "$IS_TERMUX" = "1" ]; then
    # Termux on Android 14+ denies raw execve of files in
    # /data/data/com.termux/. The runner extracts the slice and exits 120;
    # the canonical packaging/kr.sh shell wrapper catches that and re-execs
    # ./kr-exec from the user's shell context (where Termux's libc
    # LD_PRELOAD makes execve succeed). Install both kr-bin and kr.
    curl -sL -o "$INSTALL_DIR/kr-bin" "$BASE/$KR_ASSET"
    chmod +x "$INSTALL_DIR/kr-bin"
    curl -sL -o "$INSTALL_DIR/kr" \
        "https://raw.githubusercontent.com/$REPO/main/packaging/kr.sh"
    chmod +x "$INSTALL_DIR/kr"
else
    curl -sL -o "$INSTALL_DIR/kr" "$BASE/$KR_ASSET"
    chmod +x "$INSTALL_DIR/kr"
fi

# Download standard library
echo "Installing standard library..."
mkdir -p "$STD_DIR"
for mod in alloc string io math math_float fmt mem memfast vec map color fb fixedpoint font widget time log net sha256; do
    curl -sL -o "$STD_DIR/$mod.kr" \
        "https://raw.githubusercontent.com/Heniokhos-Systems/KernRift/main/std/$mod.kr"
done
echo "Standard library: $STD_DIR"

echo ""

# Verify
if "$INSTALL_DIR/krc" --version 2>/dev/null; then
    echo ""
fi

# Check PATH
case ":$PATH:" in
    *":$INSTALL_DIR:"*)
        echo "krc is in your PATH."
        ;;
    *)
        if [ "$IS_TERMUX" = "1" ]; then
            echo "Add to PATH:"
            echo "  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.bashrc"
            echo "  source ~/.bashrc"
        elif [ "$IS_ANDROID" = "1" ]; then
            echo "Run directly:"
            echo "  $INSTALL_DIR/krc --version"
        else
            echo "Add to PATH:  export PATH=\"$INSTALL_DIR:\$PATH\""
            echo "Or add that line to ~/.bashrc"
        fi
        ;;
esac

echo ""
echo "Usage:"
echo "  krc hello.kr -o hello.krbo    # compile (fat binary)"
echo "  kr hello.krbo                 # run on any platform"
if [ "$IS_ANDROID" = "1" ]; then
    echo "  krc --emit=android hello.kr -o hello   # native Android ARM64"
else
    echo "  krc --arch=$ARCH_NAME hello.kr          # native binary"
fi
echo "  krc check module.kr           # safety analysis"
echo ""
echo "=== Done ==="
