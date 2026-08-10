# An interactive console on bare-metal x86_64: VGA text out, PS/2 keyboard in.
#
# No assembler, no linker, no bootloader. `--emit=image` writes a raw multiboot
# image that `qemu-system-x86_64 -kernel` loads directly.
KRC       ?= ../../build/krc2
LOAD_ADDR ?= 0x100000
STACK_TOP ?= 0x90000

STD = ../../std/console.kr ../../std/vga_text.kr ../../std/serial.kr \
      ../../std/ps2.kr ../../std/cstr.kr ../../std/x86.kr

all: kernel.img

kernel.img: main.kr $(STD)
	$(KRC) --target=none --arch=x86_64 --emit=image \
	       --load-addr=$(LOAD_ADDR) --stack-top=$(STACK_TOP) \
	       main.kr -o kernel.img

# A window to type in, with the serial log mirrored to this terminal.
# Ctrl-A X quits.
run: kernel.img
	qemu-system-x86_64 -kernel kernel.img -m 256 -no-reboot -serial stdio

# Headless: types on an emulated PS/2 keyboard over QMP and asserts the output
# on BOTH the serial log and the VGA text buffer.
check: kernel.img
	@python3 check.py kernel.img

clean:
	rm -f kernel.img

.PHONY: all run check clean
