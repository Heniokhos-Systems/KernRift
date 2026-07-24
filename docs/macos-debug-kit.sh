#!/bin/bash
# macOS ARM64 Debug Kit — Run this on a Mac with Apple Silicon
# Usage: bash macos-debug-kit.sh
set -x

echo "=== System Info ==="
sw_vers
uname -a

echo "=== Download test binary ==="
curl -sL -o /tmp/krc-macos-arm-exit42 \
  "https://github.com/Heniokhos-Systems/KernRift/releases/latest/download/krc-linux-x86_64" 2>/dev/null
# Actually we need the cross-compiled macOS ARM64 binary. Build it locally instead.
# For now, compile a minimal test:

echo "=== Build minimal test binary ==="
cat > /tmp/test_exit42.s << 'ASM'
.global _main
.align 4
_main:
    mov x0, #42
    mov x16, #1
    svc #0x80
ASM

# Try assembling a reference binary
as -o /tmp/ref.o /tmp/test_exit42.s 2>&1
ld -o /tmp/ref_exit42 /tmp/ref.o -lSystem -syslibroot $(xcrun --show-sdk-path) -e _main -arch arm64 2>&1
echo "--- reference binary ---"
./tmp/ref_exit42; echo "ref exit: $?"

echo "=== Test KernRift binary ==="
# The KernRift binary should be copied here as /tmp/macos-arm-exit42
if [ ! -f /tmp/macos-arm-exit42 ]; then
    echo "Copy the macOS ARM64 binary to /tmp/macos-arm-exit42 first!"
    echo "On your Linux machine: scp /path/to/macos-arm-exit42 friend@macbook:/tmp/"
    exit 1
fi

chmod +x /tmp/macos-arm-exit42
echo "--- file info ---"
file /tmp/macos-arm-exit42
echo "--- otool headers ---"
otool -l /tmp/macos-arm-exit42
echo "--- codesign ---"
codesign -f -s - /tmp/macos-arm-exit42 2>&1
codesign -vvv /tmp/macos-arm-exit42 2>&1
echo "--- run under lldb ---"
echo "Running: lldb /tmp/macos-arm-exit42"
echo "In lldb, type: run"
echo "If it crashes, type: bt (backtrace)"
echo "Also check: register read pc"
lldb -o "run" -o "bt" -o "register read" -o "quit" /tmp/macos-arm-exit42 2>&1
echo "--- kernel log ---"
log show --predicate 'eventMessage CONTAINS "macos-arm-exit42" OR (process == "kernel" AND eventMessage CONTAINS "AMFI")' --last 30s --style compact 2>&1 | tail -20
echo "=== Done ==="
