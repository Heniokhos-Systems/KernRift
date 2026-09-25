# KernRift — Android ARM64 debug-kit for R3 (R1 archived)

You are Claude, running on Pantelis's laptop with ADB access to an
unlocked Android phone (no root). This file is the complete recipe for
reproducing and diagnosing bugs that the upstream (cloud) Claude
could not chase on qemu-aarch64:

- **R1** — *Resolved 2026-04-19.* The IR ARM64 `compile_fat`
  miscompile is fixed; ARM64 `krc-*` binaries now ship with the IR
  backend by default. The R1 reproduction section below is kept as
  historical documentation in case a similar regression appears.

- **R3** — *Answered 2026-09-26, and the premise was wrong.* The claim was
  that qemu-user cannot honor `MAP_FIXED` at an absolute VA, so
  `device_block_read_write` had to be skipped for arm64. It is not skipped and
  it does not need to be: built `--arch=arm64` and run under
  `qemu-aarch64-static`, the test exits **49** — the expected value — and the
  `mmap` returns **exactly** `0x66666000`, not a relocated address. So
  qemu-user honors it, and the row covers arm64 as it stands. A handset run
  would still be worth having for a different reason (the guest kernel's own
  VA policy, not the emulator's), but nothing is blocked on it.

You have network-free USB access to the phone via adb. Do not flash,
reboot, or modify the system partition. Work entirely from
`/data/local/tmp`.

---

## 0. Pre-flight — what the upstream Claude already verified

```
host$  file krc_a64
krc_a64: ELF 64-bit LSB executable, ARM aarch64, statically linked
host$  sha256sum krc_a64 krc_a64_ir
6b30aacec681b8c29068a9cab21c7cfad8f05f8ea313f3179bb82af862d364aa  krc_a64
18a693f0935a92bd707e9d401fe510b10490ff9a9b9880fad7fe321a82c7d8ea  krc_a64_ir
```

- `krc_a64`     — legacy-backend ARM64 build. This one is **known good**.
- `krc_a64_ir`  — IR-backend ARM64 build. This is the **suspect**.

Both live at the repo root (`/home/pantelis/Desktop/Projects/Work/KernRift/`).

The repo is at `main` branch, head `d5553b1`. If you need to rebuild
either, `make bootstrap` produces the legacy one; see §R1-BUILD for the
IR variant.

---

## 1. Environment probe (do this first)

Confirm basic adb state and the device's ARM64 ABI:

```bash
adb devices -l
adb shell getprop ro.product.model
adb shell getprop ro.build.version.release
adb shell getprop ro.product.cpu.abi         # expect "arm64-v8a"
adb shell uname -a
adb shell id                                   # usually uid=2000(shell)
adb shell ls -la /data/local/tmp/
adb shell getenforce                           # "Enforcing" is fine
adb shell selinux -v 2>/dev/null               # optional
```

**Stop if:**
- Device not listed (missing USB permissions → user must tap "Allow USB
  debugging" prompt).
- CPU ABI is not `arm64-v8a`.
- `/data/local/tmp/` is not writable or `-x` is stripped (extremely rare
  on production Android; SELinux usually permits `shell` exec here).

Save `adb shell getprop ro.build.fingerprint` into
`docs/android-debug-kit-fingerprint.txt` so subsequent runs know which
device produced each trace.

---

## 2. Push artifacts

```bash
cd /home/pantelis/Desktop/Projects/Work/KernRift

# Core compilers
adb push krc_a64      /data/local/tmp/krc_a64_legacy
adb push krc_a64_ir   /data/local/tmp/krc_a64_ir

# Source tree — for self-compile reproduction
adb push build/krc.kr /data/local/tmp/krc_src.kr

adb shell chmod 0755 /data/local/tmp/krc_a64_legacy /data/local/tmp/krc_a64_ir
adb shell sha256sum /data/local/tmp/krc_a64_legacy /data/local/tmp/krc_a64_ir
```

The sha256sums must match the host values above. If they differ, adb's
binary transfer is broken (rare, worth flagging).

---

## 3. Sanity test

Run a trivial program through each build to confirm both binaries *at
least start* on real ARM64:

```bash
cat > /tmp/hello.kr <<'KR'
fn main() { exit(42) }
KR
adb push /tmp/hello.kr /data/local/tmp/hello.kr

adb shell /data/local/tmp/krc_a64_legacy --arch=arm64 /data/local/tmp/hello.kr -o /data/local/tmp/hello_leg
adb shell /data/local/tmp/hello_leg; echo "legacy exit=$?"

adb shell /data/local/tmp/krc_a64_ir     --arch=arm64 /data/local/tmp/hello.kr -o /data/local/tmp/hello_ir
adb shell /data/local/tmp/hello_ir; echo "ir exit=$?"
```

Both must print `exit=42`. If the IR path already segfaults here, the
bug is much wider than `compile_fat` — log that and switch to §R1-MIN.

---

## 4. R1 — reproduce the `compile_fat` miscompile

The failing operation is: **native ARM64 krc compiles the whole krc
source into a fat binary**. Run it:

```bash
adb shell /data/local/tmp/krc_a64_ir \
    --arch=arm64 \
    /data/local/tmp/krc_src.kr \
    -o /data/local/tmp/fat_out \
  ; echo "exit=$?"
```

Expected:
- On the legacy build, exit=0 and `fat_out` is ~4 MB (all slices).
- On the IR build, a segfault — either SIGSEGV mid-run, or a truncated
  `fat_out` with a non-zero exit.

Record:
- Exit code
- `adb logcat -d -b crash | tail -200` (if Android wrote a tombstone).
- Any stderr output captured on the phone.
- Output file size if one was produced:
  `adb shell stat -c '%s' /data/local/tmp/fat_out`

If exit code is 0 but the binary is malformed, try running one of its
slices directly (see §4b below).

### 4b. Narrow to a single slice

`compile_fat` emits 8 slices. If any one of them triggers the crash we
can bisect. Override via `--targets`:

```bash
for t in linux-x64 linux-arm64 windows-x64 windows-arm64 \
         macos-x64 macos-arm64 android-arm64 android-x64; do
    echo "=== $t ==="
    adb shell /data/local/tmp/krc_a64_ir \
        --arch=arm64 \
        --targets=$t \
        /data/local/tmp/krc_src.kr \
        -o /data/local/tmp/slice_$t \
      ; echo "  exit=$?"
    adb shell stat -c '  size=%s' /data/local/tmp/slice_$t 2>/dev/null
done
```

The **first target** that produces a non-zero exit or a zero-byte
output is the minimal reproduction. Save the command line.

### 4c. Attach a debugger

Android provides `lldb-server` in the platform tools but it's not on
the device by default. Push a static one. The simplest is:

```bash
# If the NDK is installed on the host:
cp $ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/*/lib/linux/aarch64/lldb-server \
   /tmp/lldb-server-aarch64

# Otherwise, the AOSP prebuilt works:
# https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/
# (download lldb-server for arm64; verify with sha256)
```

If neither is available, fall back to **gdbserver**:

```bash
adb push $(which gdbserver) /data/local/tmp/gdbserver     # x86 won't work
# You need an aarch64 gdbserver. The Termux package is the easiest:
#   on the phone, if Termux is installed: pkg install gdb
#   then: cp $(termux which gdbserver) /data/local/tmp/
```

Run the crashing command under the debugger:

```bash
# Terminal 1 — on the phone, via adb shell
adb shell
$ cd /data/local/tmp
$ ./lldb-server-aarch64 platform --listen '*:5555' --server
# (leave running)
```

```bash
# Terminal 2 — host
adb forward tcp:5555 tcp:5555
lldb
(lldb) platform select remote-linux
(lldb) platform connect connect://localhost:5555
(lldb) file /home/pantelis/Desktop/Projects/Work/KernRift/krc_a64_ir
(lldb) process launch -- --arch=arm64 --targets=<failing-target> \
             /data/local/tmp/krc_src.kr -o /data/local/tmp/out
# When it crashes:
(lldb) bt
(lldb) register read
(lldb) disassemble -a $pc -c 16
(lldb) memory read --size 8 --count 8 $sp
```

Save to `docs/android-debug-kit-r1-trace.txt`:
- the `bt` output
- the crashing instruction and 15 around it (from `disassemble`)
- the `register read` dump
- the first 64 bytes at `$sp`

That is the single most useful artifact for upstream debugging.

### 4d. Smaller repro via strace

If lldb is unreachable, `strace` on the phone is the backup:

```bash
# Most Android builds ship strace in PATH for the shell user.
adb shell which strace
# If not, push one — the busybox-android build on GitHub has it.
adb shell strace -f -o /data/local/tmp/r1.strace \
    /data/local/tmp/krc_a64_ir --arch=arm64 \
    --targets=<failing-target> /data/local/tmp/krc_src.kr \
    -o /data/local/tmp/out
adb pull /data/local/tmp/r1.strace docs/android-debug-kit-r1.strace
```

The last few syscalls before `SIGSEGV` usually show which region was
mmap'd and which address triggered the fault.

---

## 5. R3 — verify `device_block_read_write` on real hardware

Write the minimal repro from `tests/run_tests.sh` line 1601 to a file
and run it through **both** backends. On real ARM64 Linux (including
Android, which is Linux), `MAP_FIXED` at `0x66666000` should succeed as
long as that VA isn't already mapped.

```bash
cat > /tmp/r3.kr <<'KR'
device Fake at 0x66666000 {
    Data   at 0x00 : u32
    Status at 0x04 : u8
}
fn main() {
    u64 nr = 9
    if get_arch_id() == 2 { nr = 222 }
    syscall_raw(nr, 0x66666000, 4096, 3, 0x32, 0xFFFFFFFFFFFFFFFF, 0)
    Fake.Data = 42
    Fake.Status = 7
    u32 v = Fake.Data
    u8  s = Fake.Status
    exit(v + s)
}
KR
adb push /tmp/r3.kr /data/local/tmp/r3.kr

# Legacy — must exit 49
adb shell /data/local/tmp/krc_a64_legacy --arch=arm64 \
     /data/local/tmp/r3.kr -o /data/local/tmp/r3_leg
adb shell /data/local/tmp/r3_leg; echo "r3 legacy exit=$?"

# IR — expected exit 49 if regalloc is clean
adb shell /data/local/tmp/krc_a64_ir --arch=arm64 \
     /data/local/tmp/r3.kr -o /data/local/tmp/r3_ir
adb shell /data/local/tmp/r3_ir; echo "r3 ir exit=$?"
```

Record the exit codes. Three outcomes:

| legacy | ir   | interpretation                                          |
|--------|------|---------------------------------------------------------|
| 49     | 49   | R3 fully resolved — we can re-enable the test on CI.    |
| 49     | ≠ 49 | IR-specific codegen bug at the device-field path.       |
| ≠ 49   | anything | mmap can't do MAP_FIXED at that VA on this device — pick a different address and re-run. |

If the third case hits, try `0x40000000`, `0x50000000`,
`0x70000000` in that order. The value is informational only — we want
one that works so we can make the test VA selectable per platform.

---

## 6. Reporting

Write findings into `docs/android-debug-kit-results.md` with these
sections:

```markdown
# Android debug-kit run — <YYYY-MM-DD>

## Device
- fingerprint:
- model:
- Android version:
- ABI:
- kernel:

## R1 — compile_fat miscompile
- full-run exit code:
- first failing --targets= slice:
- repro command line:
- lldb backtrace: (or attached r1-trace.txt)
- register state at crash:
- tentative diagnosis: (leave blank if unclear)

## R3 — fixed-VA mmap
- legacy exit code:
- ir exit code:
- conclusion:
- alternative VA that worked (if applicable):

## Artifacts pushed back to host
- docs/android-debug-kit-r1-trace.txt
- docs/android-debug-kit-r1.strace (if used)
- docs/android-debug-kit-fingerprint.txt
```

Add-but-do-not-commit these docs (they are device-specific). The
upstream Claude will read them on next sync.

---

## §R1-BUILD — rebuilding `krc_a64_ir` from source

If the existing `krc_a64_ir` is stale, rebuild:

```bash
cd /home/pantelis/Desktop/Projects/Work/KernRift
make bootstrap            # ensures build/krc3 works
# Cross-emit an IR-backend ARM64 build, bypassing the --legacy override:
./build/krc3 --arch=arm64 build/krc.kr -o krc_a64_ir
file krc_a64_ir           # must be aarch64 ELF
```

Note: the Makefile's `dist` target bakes in `--legacy --arch=arm64` on
purpose. Using `build/krc3` directly skips that.

---

## §R1-MIN — minimum reproduction if full `compile_fat` is too big

Strip the source down to the smallest program that triggers the crash:

1. Start with `build/krc.kr` (the whole concatenated compiler).
2. Binary-chop: delete the second half, rebuild the compiler, retry.
3. When the chop causes the IR ARM64 build itself to miscompile its own
   smaller input, you have the minimum repro.
4. Save it as `docs/android-debug-kit-r1-min.kr`.

This may take several iterations — prioritise §4c's debugger approach
first.

---

## Safety

- Do **not** `adb shell su`, `magisk`, or flash anything.
- Do **not** write outside `/data/local/tmp/`.
- Do **not** install APKs.
- The kit writes strictly to `/data/local/tmp/` on the phone and to
  `docs/android-debug-kit-*` on the host. Nothing else.

If the device ever reboots unexpectedly, stop and report — that's
kernel territory and outside this kit's scope.
