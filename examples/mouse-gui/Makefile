# A mouse-driven GUI on bare-metal x86_64.
#
# No assembler, no linker, no bootloader. `--emit=image` writes a raw multiboot
# image that `qemu-system-x86_64 -kernel` loads directly.
KRC       ?= ../../build/krc2
LOAD_ADDR ?= 0x100000
STACK_TOP ?= 0x90000

STD = ../../std/mouse.kr ../../std/ps2.kr ../../std/ramfb.kr ../../std/fw_cfg.kr \
      ../../std/widget.kr ../../std/fb.kr ../../std/font.kr ../../std/color.kr \
      ../../std/heap_bump.kr ../../std/serial.kr ../../std/cstr.kr ../../std/x86.kr

# -vga none is NOT optional. Without it QEMU adds a default VGA adapter, ramfb
# becomes the second console, and anything reading console 0 -- the window and
# check.py's screendump -- shows the empty VGA instead of the framebuffer.
QEMU_FLAGS = -m 256 -no-reboot -vga none -device ramfb

all: kernel.img

kernel.img: main.kr $(STD)
	$(KRC) --target=none --arch=x86_64 --emit=image \
	       --load-addr=$(LOAD_ADDR) --stack-top=$(STACK_TOP) \
	       main.kr -o kernel.img

# A window you can move the pointer in and click. Ctrl-A X quits.
run: kernel.img
	qemu-system-x86_64 -kernel kernel.img $(QEMU_FLAGS) -serial stdio

# Headless: drives the mouse and keyboard over QMP, asserts the serial log and
# the framebuffer pixels.
check: kernel.img
	@python3 check.py kernel.img

shot: kernel.img
	@python3 check.py kernel.img --keep-ppm gui.ppm
	@echo "wrote gui.ppm"

clean:
	rm -f kernel.img gui.ppm

.PHONY: all run check shot clean
