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
# The clicked button, and the second button which is never touched and so acts
# as a control. Insets avoid the border.
BTN1_RECT = (74, 114, 226, 150)
BTN2_RECT = (264, 114, 416, 150)

# The click assertion compares the SAME button before and after the press, not
# one button against the other. The two buttons are deliberately different
# colours, so "clicked differs from control" is true whether or not the press
# ever registered -- measured: with button_set_pressed reduced to a no-op, that
# form of the check still passed. A before/after diff on one widget is the
# assertion that actually discriminates.


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
    ppm_before = (keep + ".before") if keep else "/tmp/mgui_%d_b.ppm" % os.getpid()
    serial = "/tmp/mgui_%d.txt" % os.getpid()

    q = Qemu(image, serial)
    fail = []
    try:
        time.sleep(2.5)

        # QMP mouse_move deltas are SCREEN-space: +y is down.
        q.hmp("mouse_move %d %d" % (TARGET_X - START_X, TARGET_Y - START_Y))
        time.sleep(0.6)
        # Capture BEFORE the press, with the cursor already parked on the
        # button, so the only difference between the two frames is the press.
        q.hmp("screendump " + ppm_before)
        time.sleep(0.4)
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

    if not os.path.exists(ppm) or not os.path.exists(ppm_before):
        fail.append("screendump missing (need both before and after)")
    else:
        wb, hb, pb = read_ppm(ppm_before)
        w, h, px = read_ppm(ppm)
        print("resolution: %dx%d" % (w, h))
        if (w, h) != (640, 480) or (wb, hb) != (640, 480):
            fail.append("expected 640x480, got %dx%d / %dx%d" % (w, h, wb, hb))
        else:
            def diff_count(rect):
                x0, y0, x1, y1 = rect
                n = 0
                for y in range(y0, y1):
                    for x in range(x0, x1):
                        o = (y * w + x) * 3
                        if px[o:o + 3] != pb[o:o + 3]:
                            n += 1
                return n
            d1, d2 = diff_count(BTN1_RECT), diff_count(BTN2_RECT)
            total1 = (BTN1_RECT[2] - BTN1_RECT[0]) * (BTN1_RECT[3] - BTN1_RECT[1])
            print("clicked button: %d/%d pixels changed by the press" % (d1, total1))
            print("control button: %d pixels changed (must be 0)" % d2)
            # A press must visibly change the widget it landed on...
            if d1 == 0:
                fail.append("press changed NO pixels on the clicked button -- no visual feedback")
            # ...and must not touch anything else.
            if d2 != 0:
                fail.append("control button changed by %d pixels (nothing touched it)" % d2)

    if not keep:
        for f in (ppm, ppm_before):
            if os.path.exists(f):
                os.remove(f)

    if fail:
        for f in fail:
            print("BAD  " + f)
        raise SystemExit("FAIL: %d check(s) failed" % len(fail))
    print("PASS: cursor moved, click hit the widget and changed pixels, "
          "keyboard alive while mouse streamed")


main()
