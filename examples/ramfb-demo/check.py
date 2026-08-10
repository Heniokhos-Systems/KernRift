#!/usr/bin/env python3
"""Boot the ramfb demo headless and assert the pixels QEMU actually scanned out.

This exists because "it compiled" and "it drew" are different claims. The guest
writes to plain RAM; only a screendump proves QEMU was told to display that RAM.

Two QEMU details that cost real debugging time and are pinned here:

  * `-vga none` is REQUIRED. Without it QEMU adds a default VGA adapter, ramfb
    becomes the SECOND console, and `screendump` captures console 0 -- the
    empty VGA. The symptom is a black image with the grey "Guest has not
    initialized the display" text, which reads exactly like a guest bug.

  * The guest needs time to run. Issuing screendump immediately after
    qmp_capabilities captures the display before the guest has drawn anything.

Usage:  check.py <image> [--keep-ppm PATH]
"""
import json
import os
import socket
import subprocess
import sys
import time

# (name, x, y, (r, g, b)) -- chosen to avoid every boundary the demo draws.
CHECKS = [
    ("background",        600,  20, (0x20, 0x20, 0x20)),
    ("red rect",          100, 100, (0xFF, 0x00, 0x00)),
    ("red rect top-left",  64,  64, (0xFF, 0x00, 0x00)),
    ("left of red",        63, 100, (0x20, 0x20, 0x20)),
    ("green rect",        400, 100, (0x00, 0xFF, 0x00)),
    ("blue rect",         100, 300, (0x00, 0x60, 0xFF)),
    ("clipped yellow",    600, 450, (0xFF, 0xFF, 0x00)),
    ("frame top",         320,   0, (0xFF, 0xFF, 0xFF)),
    ("frame bottom",      320, 479, (0xFF, 0xFF, 0xFF)),
    ("frame left",          0, 240, (0xFF, 0xFF, 0xFF)),
    ("frame right",       639, 240, (0xFF, 0xFF, 0xFF)),
    # The yellow rect deliberately overhangs the right edge. If fill_rect fails
    # to clip x, the overhang does not vanish -- it wraps onto the START of the
    # next scanline. This point sits exactly where that spill lands and nothing
    # else writes it. It is load-bearing: with the x-clip deleted from
    # std/ramfb.kr, every OTHER check here still passed (measured), including
    # (0,450) -- the frame is drawn after the rects, so it repaints column 0
    # and hides the spill there.
    ("x-spill guard",      50, 450, (0x20, 0x20, 0x20)),
    ("frame left lower",    0, 450, (0xFF, 0xFF, 0xFF)),
]


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
    if fields[0] != b"P6":
        raise SystemExit("not a P6 PPM: %r" % fields[0])
    return int(fields[1]), int(fields[2]), d[i:]


def boot_and_dump(image, ppm, serial):
    sock = "/tmp/ramfb_qmp_%d.sock" % os.getpid()
    for f in (ppm, serial, sock):
        if os.path.exists(f):
            os.remove(f)
    p = subprocess.Popen(
        ["qemu-system-x86_64", "-kernel", image, "-m", "256",
         "-serial", "file:" + serial, "-display", "none", "-no-reboot",
         "-vga", "none", "-device", "ramfb",
         "-qmp", "unix:%s,server,nowait" % sock],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        for _ in range(200):
            if os.path.exists(sock):
                break
            time.sleep(0.05)
        else:
            raise SystemExit("QEMU never created the QMP socket")
        s = socket.socket(socket.AF_UNIX)
        s.connect(sock)
        f = s.makefile("rw")
        f.readline()

        def cmd(c):
            f.write(json.dumps(c) + "\n")
            f.flush()
            while True:
                line = f.readline()
                if not line:
                    return None
                r = json.loads(line)
                if "return" in r or "error" in r:
                    return r

        cmd({"execute": "qmp_capabilities"})
        time.sleep(3.0)
        r = cmd({"execute": "human-monitor-command",
                 "arguments": {"command-line": "screendump " + ppm}})
        if r is None or "error" in r:
            raise SystemExit("screendump failed: %r" % r)
        cmd({"execute": "quit"})
    finally:
        try:
            p.wait(timeout=5)
        except Exception:
            p.kill()
        if os.path.exists(sock):
            os.remove(sock)


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    image = sys.argv[1]
    keep = None
    if "--keep-ppm" in sys.argv:
        keep = sys.argv[sys.argv.index("--keep-ppm") + 1]
    ppm = keep or "/tmp/ramfb_check_%d.ppm" % os.getpid()
    serial = "/tmp/ramfb_check_%d.txt" % os.getpid()

    boot_and_dump(image, ppm, serial)

    out = ""
    if os.path.exists(serial):
        out = open(serial, errors="replace").read().strip()
    print("serial: %s" % (out or "<nothing>"))
    if not out.startswith("OK:"):
        raise SystemExit("FAIL: guest did not report success")

    w, h, px = read_ppm(ppm)
    print("resolution: %dx%d" % (w, h))
    if (w, h) != (640, 480):
        raise SystemExit("FAIL: expected 640x480, got %dx%d "
                         "(640x480 is also QEMU's default, so a mismatch here "
                         "means ramfb was NOT configured)" % (w, h))

    bad = 0
    for name, x, y, exp in CHECKS:
        o = (y * w + x) * 3
        got = (px[o], px[o + 1], px[o + 2])
        if got != exp:
            bad += 1
            print("  BAD  %-18s (%3d,%3d) got=%s exp=%s" % (name, x, y, got, exp))
        else:
            print("  ok   %-18s (%3d,%3d) %s" % (name, x, y, got))

    if not keep and os.path.exists(ppm):
        os.remove(ppm)
    if os.path.exists(serial):
        os.remove(serial)

    if bad:
        raise SystemExit("FAIL: %d/%d pixel checks failed" % (bad, len(CHECKS)))
    print("PASS: %d/%d pixel checks" % (len(CHECKS), len(CHECKS)))


main()
