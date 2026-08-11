# mouse-gui — a pointer, widgets and no OS

A clickable GUI on bare-metal x86_64. No bootloader, no libc, no driver stack,
no interrupt handlers. `krc` alone produces an image `qemu-system-x86_64
-kernel` boots.

```
make run      # a window you can move the pointer in and click
make check    # drives mouse + keyboard headless and asserts the result
make shot     # same, but keeps the capture as gui.ppm
```

## Nothing here is new UI code

`std/widget.kr`, `std/fb.kr`, `std/font.kr` and `std/color.kr` already existed
and already worked — panel, label, button, the 8x16 font, `button_contains`,
`button_set_pressed`. What was missing was **the mouse**, and the reason it
could not have worked before is in `std/ps2.kr`.

The widget toolkit allocates its descriptors, and `--target=none` refuses
`alloc` unless the program supplies one. `std/heap_bump.kr` does, over a
caller-given region — the right shape here, since everything is allocated
during setup and nothing is ever freed.

## One drain owns port 0x60

The keyboard and mouse share a single 8042 output buffer, and a byte can be
read only once. Two pollers each calling `inb(0x60)` steal each other's bytes.
Before this, `ps2_poll` read the port and *discarded* anything with the aux
bit set — so a mouse could not work at all while anything polled the keyboard,
and `console_poll` calls `ps2_poll` first.

Now `ps2_drain` reads every pending byte, classifies it by the status aux bit,
and appends it to a keyboard ring or a mouse ring. `ps2_poll` and `mouse_poll`
each read only their own ring. Neither touches the port.

Measured with a second reader put back: the cursor never moved, the click was
never seen, and a keystroke went missing — all three assertions red.

## Bit 3 is a detector, not a resync point

The mouse's flags byte always has bit 3 set, which invites resyncing by
scanning for a byte with bit 3 set. That does not work: bit 3 is also set in
the **movement** bytes whenever |dx| or |dy| lands in 8..15, 24..31, and so on.
Measured, three of four real packets contained such a false candidate — a scan
would lock onto a data byte and stay wrong.

So desync is *detected* via bit 3 and *recovered* by telling the device to
restart its own packet index (`0xF5`, drain, `0xF4`).

## `-vga none` is required

Otherwise QEMU adds a default VGA, ramfb becomes the second console, and the
window and `screendump` show the empty VGA instead of the framebuffer.

## Files

| file | |
|---|---|
| `main.kr` | the demo |
| `check.py` | headless mouse/keyboard driver and assertions |
| `../../std/mouse.kr` | PS/2 mouse protocol (no port access) |
| `../../std/ps2.kr` | owns 0x60: the drain, the rings, controller commands |
| `../../std/widget.kr` | panel, label, button — pre-existing |
| `../../std/heap_bump.kr` | the `alloc` provider bare metal needs |
