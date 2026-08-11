#!/usr/bin/env python3
"""Drive the bare-metal GUI headlessly and assert what it actually did.

Three independent claims, because each can fail without the others:

  1. the mouse moves the cursor to a commanded position (serial POS line)
  2. a click on a widget is detected and CHANGES PIXELS (framebuffer)
  3. the keyboard still works while the mouse is streaming

(3) is the one worth the trouble. The keyboard and mouse share one 8042 output
buffer and a byte can be read only once, so two pollers each calling inb(0x60)
steal each other's bytes. Before std/ps2.kr grew a single drain, ps2_poll read
the port and threw away anything with the aux bit set -- a mouse could not work
at all while anything polled the keyboard, and console_poll calls ps2_poll
first. A test that only moves the mouse would pass with that bug fully present.

`-vga none` is required: otherwise QEMU adds a default VGA, ramfb becomes the
second console, and screendump captures the empty VGA instead.

Usage:  check.py <image> [--keep-ppm PATH]
"""
import json
import os
import socket
import subprocess
import sys
import time

# Scene geometry, from main.kr. The cursor starts at (320,240); "Click me"
# spans x 70..230, y 110..154, so (150,132) is comfortably inside it.
START_X, START_Y = 320, 240
TARGET_X, TARGET_Y = 150, 132
# A point inside "Click me", and one inside the second button which is never
# touched and therefore acts as a control.
BTN1_PROBE = (90, 145)
BTN2_PROBE = (300, 145)
BTN2_UNPRESSED = (0x60, 0x40, 0x80)


class Qemu:
    def __init__(self, image, serial):
        self.sock = "/tmp/mgui_%d.sock" % os.getpid()
        for f in (serial, self.sock):
            if os.path.exists(f):
                os.remove(f)
        self.p = subprocess.Popen(
            ["qemu-system-x86_64", "-kernel", image, "-m", "256",
             "-display", "none", "-no-reboot", "-vga", "none",
             "-device", "ramfb", "-serial", "file:" + serial,
             "-qmp", "unix:%s,server,nowait" % self.sock],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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
        return (self.cmd({"execute": "human-monitor-command",
                          "arguments": {"command-line": s}}) or {}).get("return", "")

    def close(self):
        self.cmd({"execute": "quit"})
        try:
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()
        if os.path.exists(self.sock):
            os.remove(self.sock)


def read_ppm(path):
    d = open(path, "rb").read()
    i, fields = 0, []
    while len(fields) < 4:
        while d[i:i + 1].isspace():
            i += 1
        s = i
        while not d[i:i + 1].isspace():
            i += 1
        fields.append(d[s:i])
    i += 1
    return int(fields[1]), int(fields[2]), d[i:]


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    image = sys.argv[1]
    keep = None
    if "--keep-ppm" in sys.argv:
        keep = sys.argv[sys.argv.index("--keep-ppm") + 1]
    ppm = keep or "/tmp/mgui_%d.ppm" % os.getpid()
    serial = "/tmp/mgui_%d.txt" % os.getpid()

    q = Qemu(image, serial)
    fail = []
    try:
        time.sleep(2.5)

        # QMP mouse_move deltas are SCREEN-space: +y is down.
        q.hmp("mouse_move %d %d" % (TARGET_X - START_X, TARGET_Y - START_Y))
        time.sleep(0.6)
        q.hmp("mouse_button 1")
        time.sleep(0.7)
        q.hmp("screendump " + ppm)
        time.sleep(0.5)
        q.hmp("mouse_button 0")
        time.sleep(0.4)
        # Keyboard AFTER the mouse has been streaming for a while.
        for k in ["k", "b"]:
            q.hmp("sendkey " + k)
            time.sleep(0.3)
        time.sleep(0.4)
        log = open(serial, errors="replace").read() if os.path.exists(serial) else ""
    finally:
        q.close()
        if os.path.exists(serial):
            os.remove(serial)

    print("--- serial ---")
    print(log.strip() or "<nothing>")

    if "GUI-READY" not in log:
        fail.append("guest never reported GUI-READY")
    # 1. cursor reached the commanded position
    want_pos = "x=%d y=%d" % (TARGET_X, TARGET_Y)
    if want_pos not in log:
        fail.append("cursor never reached %s" % want_pos)
    # 2. the click was attributed to the right widget
    if "HIT go" not in log:
        fail.append("click on 'Click me' not detected (no 'HIT go')")
    # 3. keyboard still alive while the mouse streams
    for k in ["KEY k", "KEY b"]:
        if k not in log:
            fail.append("keyboard dead while mouse streaming (missing %r)" % k)

    if not os.path.exists(ppm):
        fail.append("no screendump produced")
    else:
        w, h, px = read_ppm(ppm)
        print("resolution: %dx%d" % (w, h))
        if (w, h) != (640, 480):
            fail.append("expected 640x480, got %dx%d" % (w, h))
        else:
            def at(x, y):
                o = (y * w + x) * 3
                return (px[o], px[o + 1], px[o + 2])
            b1, b2 = at(*BTN1_PROBE), at(*BTN2_PROBE)
            print("clicked button %s   control button %s" % (b1, b2))
            # The pressed widget must look different from the untouched one.
            # Asserting "differs from the control" rather than a literal colour
            # keeps this from breaking if the theme changes.
            if b2 != BTN2_UNPRESSED:
                fail.append("control button changed: %s (nothing should have touched it)" % (b2,))
            if b1 == b2:
                fail.append("pressed button looks identical to the control -- no visual feedback")

    if not keep and os.path.exists(ppm):
        os.remove(ppm)

    if fail:
        for f in fail:
            print("BAD  " + f)
        raise SystemExit("FAIL: %d check(s) failed" % len(fail))
    print("PASS: cursor moved, click hit the widget and changed pixels, "
          "keyboard alive while mouse streamed")


main()
