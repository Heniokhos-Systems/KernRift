# bare-console — an interactive shell with no OS

A prompt you can type at, on bare-metal x86_64. VGA text output, PS/2 keyboard
input, serial on both sides. No bootloader, no libc, no assembler, no linker,
and no interrupt handlers — `krc` alone produces the image.

```
make run      # a window to type in, serial log in your terminal
make check    # drives it headless and asserts the output
```

Commands: `help`, `echo <text>`, `ram`, `cpus`, `reboot`.

## `print` works here

The interesting line in `main.kr` is an ordinary one:

```
println("KernRift console ready.")
```

Under `--target=none` the compiler lowers `print`, `println` and f-strings to
`write`, and `std/console.kr` defines `write` with `@builtin_override`. So the
language's normal output works with nothing underneath it — you do not have to
write a `puts` and thread it through your program.

`console_put_u64` / `console_put_hex` exist for the same reason in reverse:
`std/string.kr`'s `int_to_str` **allocates**, and `--target=none` refuses
`alloc`. Formatting a number should not need a heap, so those write into a
caller-owned buffer (see `std/cstr.kr`).

## Polling, not interrupts

`std/ps2.kr` polls the 8042 rather than taking IRQ 1. That means it needs no
IDT and no PIC setup, so it works in a program that has not touched interrupts
at all. The controller buffers a keystroke, so a loop polling faster than a
person types loses nothing.

## What `check` proves

It types on an **emulated PS/2 keyboard** over QMP `sendkey` — deliberately not
over the serial port, which would exercise the UART and leave the scancode
translation untested. Then it asserts the results in two places: the serial log,
and the VGA text buffer read straight out of guest memory at `0xB8000`.

Both halves are load-bearing. Measured, by breaking each on purpose:

| break | what fails |
|---|---|
| one wrong letter in the qwerty scancode row | all four echo assertions, serial and VGA |
| `console_to_vga = 0` | the three VGA assertions only; serial still passes |

## Files

| file | |
|---|---|
| `main.kr` | the shell |
| `check.py` | headless PS/2 driver and assertions |
| `../../std/console.kr` | unified output/input, and the `write` override |
| `../../std/vga_text.kr` | 80x25 text, colours, scrolling, hardware cursor |
| `../../std/ps2.kr` | scancode set 1 → ASCII, modifiers, arrow keys |
| `../../std/serial.kr` | 16550 UART |
| `../../std/cstr.kr` | allocation-free strings and number formatting |
