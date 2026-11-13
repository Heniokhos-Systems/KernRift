#!/usr/bin/env python3
"""Drive the bare-metal console headlessly and assert what it produced.

Types on an emulated PS/2 keyboard via QMP `sendkey` -- NOT over the serial
port. That distinction is the point: serial input would exercise the UART and
leave std/ps2.kr's scancode translation completely untested.

Checks both sinks, because console.kr claims to write to both:
  * the serial log, captured to a file
  * the VGA text buffer, read straight out of guest memory at 0xB8000

Usage:  check.py <image>
"""
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time


# Scratch files and the qemu child are registered here and removed / killed
# whatever ends the run: a SystemExit, an error, or the SIGTERM the test
# suite's `timeout` sends (the handler below turns it into SystemExit, so this
# runs; #261 -- a TERMed check used to leave its serial log, PPM dumps and
# socket behind). Serial logs and PPM dumps go to tempfile.gettempdir()
# ($TMPDIR; under the suite, its private scratch directory). The QMP socket
# stays in /tmp: AF_UNIX paths are capped at 107 bytes and a socket under a
# deep $TMPDIR makes qemu exit 1 with no attribution.
_SCRATCH = []
_PROCS = []


def _cleanup():
    for p in _PROCS:
        if p.poll() is None:
            p.kill()
            try:
                p.wait(timeout=5)
            except Exception:
                pass
    for f in _SCRATCH:
        try:
            os.remove(f)
        except OSError:
            pass


def _scratch(name):
    path = os.path.join(tempfile.gettempdir(), name)
    _SCRATCH.append(path)
    return path


def _sock(name):
    path = "/tmp/" + name
    _SCRATCH.append(path)
    return path

VGA = 0xB8000

# QMP sendkey names for the characters we type. Only what the script needs.
KEYNAME = {" ": "spc", "\n": "ret"}
for c in "abcdefghijklmnopqrstuvwxyz0123456789":
    KEYNAME[c] = c


class Qemu:
    def __init__(self, image, serial):
        self.sock = _sock("bcon_%d.sock" % os.getpid())
        for f in (serial, self.sock):
            if os.path.exists(f):
                os.remove(f)
        self.p = subprocess.Popen(
            ["qemu-system-x86_64", "-kernel", image, "-m", "256",
             "-display", "none", "-no-reboot", "-serial", "file:" + serial,
             "-qmp", "unix:%s,server,nowait" % self.sock],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        _PROCS.append(self.p)
        for _ in range(200):
            if os.path.exists(self.sock):
                break
            time.sleep(0.05)
        else:
            raise SystemExit("QEMU never created the QMP socket")
        s = socket.socket(socket.AF_UNIX)
        s.connect(self.sock)
        self.f = s.makefile("rw")
        self.f.readline()
        self.cmd({"execute": "qmp_capabilities"})

    def cmd(self, c):
        self.f.write(json.dumps(c) + "\n")
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                return None
            r = json.loads(line)
            if "return" in r or "error" in r:
                return r

    def hmp(self, s):
        r = self.cmd({"execute": "human-monitor-command",
                      "arguments": {"command-line": s}})
        return (r or {}).get("return", "")

    def type(self, text):
        for ch in text:
            name = KEYNAME.get(ch)
            if name is None:
                raise SystemExit("no sendkey name for %r" % ch)
            self.hmp("sendkey " + name)
            time.sleep(0.03)

    def vga_row(self, n, cols=60):
        vals = []
        out = self.hmp("xp /%dxb 0x%x" % (cols * 2, VGA + n * 80 * 2))
        for line in out.splitlines():
            parts = line.split(":", 1)
            if len(parts) < 2:
                continue
            vals += [int(v, 16) for v in parts[1].split()]
        return "".join(chr(vals[i]) if 32 <= vals[i] < 127 else " "
                       for i in range(0, len(vals), 2)).rstrip()

    def close(self):
        self.cmd({"execute": "quit"})
        try:
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()
        if os.path.exists(self.sock):
            os.remove(self.sock)


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    image = sys.argv[1]
    serial = _scratch("bcon_%d.txt" % os.getpid())
    q = Qemu(image, serial)
    failures = []
    try:
        time.sleep(2.0)                      # let it boot and print the banner

        # Banner must be on screen before any input.
        row0 = q.vga_row(0)
        if "KernRift bare-metal console" not in row0:
            failures.append("banner missing from VGA row 0: %r" % row0)

        q.type("echo hello\n")
        time.sleep(0.6)
        q.type("ram\n")
        time.sleep(0.6)
        q.type("nosuch\n")
        time.sleep(0.8)

        screen = "\n".join(q.vga_row(n) for n in range(25))
        log = open(serial, errors="replace").read() if os.path.exists(serial) else ""
    finally:
        q.close()
        if os.path.exists(serial):
            os.remove(serial)

    # Serial: the keystrokes arrived, were echoed, and each command ran.
    for want in ["KernRift console ready.", "> echo hello", "hello",
                 "ram: ", " MiB", "unknown command: nosuch"]:
        if want not in log:
            failures.append("serial missing %r" % want)

    # VGA: the same text reached the screen, not just the serial port.
    for want in ["echo hello", "hello", "unknown command: nosuch"]:
        if want not in screen:
            failures.append("VGA missing %r" % want)

    print("--- serial ---")
    print(log.strip() or "<nothing>")
    print("--- VGA (non-blank rows) ---")
    for line in screen.splitlines():
        if line.strip():
            print("  |%s|" % line)

    if failures:
        for f in failures:
            print("BAD  " + f)
        raise SystemExit("FAIL: %d check(s) failed" % len(failures))
    print("PASS: PS/2 input echoed, commands ran, output on BOTH vga and serial")


signal.signal(signal.SIGTERM, lambda signo, frame: sys.exit(128 + signo))
try:
    main()
finally:
    _cleanup()
