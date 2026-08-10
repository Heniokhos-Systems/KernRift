# ramfb demo — a framebuffer with no OS

Draws to a real linear framebuffer on bare-metal x86_64. No bootloader, no
assembler, no linker, no driver — `krc` alone produces an image that
`qemu-system-x86_64 -kernel` boots.

```
make run      # opens a window
make check    # boots headless, screendumps over QMP, asserts 13 pixel values
make shot     # same, but keeps the capture as ramfb.ppm
```

## How it works

QEMU's **ramfb** device scans out of ordinary guest RAM. You tell it where via
**fw_cfg**, the same channel QEMU uses to pass a guest its RAM size and SMBIOS
tables before any OS exists.

1. `fw_cfg_present()` — read selector 0 and check it says `QEMU`. On hardware
   without the device the port floats to `0xFF`, and unchecked that garbage
   looks like a very short file directory.
2. `fw_cfg_find_file("etc/ramfb")` — walk the fw_cfg file directory for the
   ramfb selector.
3. Build a 28-byte config (address, `XR24` format, width, height, stride —
   **all big-endian**) and DMA it to that selector. Writes only work over DMA;
   the data port is read-only.
4. From then on, storing a `u32` at `fb + y*stride + x*4` puts a pixel on the
   screen.

The framebuffer lives at 16 MiB; the image loads at 1 MiB and is a few KiB, so
they cannot collide. Nothing is mapped or allocated — on a flat identity-mapped
image a physical address is just a number you store to.

## `-vga none` is required

Without it QEMU adds a default VGA adapter and ramfb becomes the **second**
console. Anything reading console 0 — `screendump`, and the window `make run`
opens — then shows the empty VGA instead, which renders as a black screen with
QEMU's grey *"Guest has not initialized the display"* text.

That failure looks exactly like a broken guest. It is worth recognising,
because the guest can be working perfectly: during development this demo drew
every pixel correctly while the capture showed that message.

## Files

| file | |
|---|---|
| `main.kr` | the demo |
| `check.py` | boots headless and asserts actual scanned-out pixels |
| `../../std/ramfb.kr` | framebuffer setup and drawing |
| `../../std/fw_cfg.kr` | the fw_cfg protocol |
| `../../std/x86.kr` | port I/O and byte-swaps |

## What `check` proves

That the pixels reached the display, not merely that the code compiled or that
stores were issued. `main.kr` reads one pixel back before reporting success, so
a memory-level failure is caught in the guest; `check.py` then compares QEMU's
own screendump against 13 expected values, including a point that is only
correct if `fill_rect` clips in **x** — the one check that fails when clipping
is removed.
