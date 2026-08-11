# A linear framebuffer on bare-metal x86_64, via QEMU's ramfb.
#
# No assembler, no linker, no bootloader. `--emit=image` writes a raw multiboot
# image that `qemu-system-x86_64 -kernel` loads directly, and `--stack-top`
# makes the compiler emit its own entry stub.
KRC       ?= ../../build/krc2
LOAD_ADDR ?= 0x100000
STACK_TOP ?= 0x90000

# -vga none is NOT optional. Without it QEMU adds a default VGA adapter and
# ramfb becomes the second console, so anything that captures console 0 -- the
# `screendump` in check.py, and the window `run` opens -- shows the empty VGA
# instead of the framebuffer.
QEMU_FLAGS = -m 256 -no-reboot -vga none -device ramfb

all: kernel.img

kernel.img: main.kr ../../std/ramfb.kr ../../std/fw_cfg.kr ../../std/x86.kr
	$(KRC) --target=none --arch=x86_64 --emit=image \
	       --load-addr=$(LOAD_ADDR) --stack-top=$(STACK_TOP) \
	       main.kr -o kernel.img

# Opens a window with the drawing. Ctrl-A X quits.
run: kernel.img
	qemu-system-x86_64 -kernel kernel.img $(QEMU_FLAGS) -serial stdio

# Headless: boot, screendump over QMP, assert the actual pixel values.
check: kernel.img
	@python3 check.py kernel.img

# Same, but keep the capture so you can look at it.
shot: kernel.img
	@python3 check.py kernel.img --keep-ppm ramfb.ppm
	@echo "wrote ramfb.ppm"

clean:
	rm -f kernel.img ramfb.ppm

.PHONY: all run check shot clean
