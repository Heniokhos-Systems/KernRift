# Bare-metal PL011 echo for the QEMU `virt` machine.
#
# There is no assembler and no linker in this build. `--stack-top` makes the
# compiler emit its own entry stub, and `--emit=image` writes a raw flat
# binary -- `--freestanding` alone would still produce an ELF container.
KRC       ?= ../../build/krc2
LOAD_ADDR ?= 0x40080000
STACK_TOP ?= 0x40200000

all: kernel.img

kernel.img: main.kr uart.kr
	$(KRC) --target=none --arch=arm64 --emit=image --image-header \
	       --load-addr=$(LOAD_ADDR) --stack-top=$(STACK_TOP) \
	       main.kr -o kernel.img

# Type into the terminal; characters echo back. Ctrl-A X quits QEMU.
run: kernel.img
	qemu-system-aarch64 -M virt -cpu cortex-a72 -nographic \
	    -kernel kernel.img

# Non-interactive smoke test: expect the banner AND the echoed input back.
# Both greps are load-bearing: a single grep for the echoed 'Hello' kept
# reporting "banner printed" with the banner deleted (measured), because the
# two strings share no text. The banner proves uart_puts/init ran; the echo
# proves the RX->ring->TX path did.
#
# Two details this depends on. `-serial stdio -monitor none` rather than
# `-nographic`: -nographic muxes the QEMU monitor onto stdio and eats piped
# input. And the leading sleep -- bytes that arrive while uart_init() is
# holding CR at 0 are discarded by the hardware, so sending immediately loses
# the first character.
check: kernel.img
	@out=$$({ sleep 1.5; printf 'Hello'; sleep 1.5; } | \
	    timeout 8 qemu-system-aarch64 -M virt -cpu cortex-a72 \
	    -display none -serial stdio -monitor none -kernel kernel.img \
	    2>/dev/null | head -c 200); \
	  printf '%s' "$$out" | grep -q 'kr-uart echo ready' \
	  && printf '%s' "$$out" | grep -q 'Hello' \
	  && echo "check: OK (banner printed, input echoed)" \
	  || { echo "check: FAILED"; exit 1; }

clean:
	rm -f kernel.img

.PHONY: all run check clean
