# ONE boot image, three boot paths, from one `krc --emit=fatimage`.
#
#   make            build fat.img and fat-mixed.img
#   make run-x86    boot fat.img under qemu-system-x86_64 (multiboot)
#   make run-arm64  boot fat.img under qemu-system-aarch64 (raw Image)
#   make check      boot BOTH images on BOTH architectures and assert output
#
# There is no assembler, no linker and no image-building script here. The
# compiler composes the artefact itself: `--emit=fatimage` compiles hello_fat.kr
# once per architecture and writes one file whose first 64 bytes are
# simultaneously a PE DOS stub and an arm64 `Image` header.
KRC ?= ../../build/krc2

# The arm64 slice's own load address. It only has to be 4096-aligned -- arm64
# code is position-independent modulo a page, and the fat image places every
# slice on a page boundary, so where this was built for does not have to match
# where it ends up. (The x86_64 half does not even need that: it is fully
# RIP-relative.)
SLICE_LOAD  ?= 0x40010000
SLICE_STACK ?= 0x40800000

# Where the x86_64 half leaves its plain-ASCII banner for the harness to read
# back. See the WHY PMEMSAVE note on the check target.
WITNESS ?= 0x600000

OVMF_CODE ?= /usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS ?= /usr/share/OVMF/OVMF_VARS_4M.fd

all: fat.img fat-mixed.img

# The pure multi-pass form: one source, both architectures, no extra flags.
# Every load address and stack top is a per-architecture default -- x86_64
# loads at 0x400000 with its stack at 0x3f0000, arm64 loads at 0x40000000 with
# its stack at 0x40800000 -- and `krc --help` documents all four.
fat.img: hello_fat.kr
	$(KRC) --target=none --arch=x86_64,arm64 --emit=fatimage \
	       hello_fat.kr -o fat.img

# A standalone arm64 image, built the ordinary way, to be adopted below.
# --image-header is REQUIRED of a --slice= file on arm64: the fat image reads
# the entry point out of the header's code0 branch, because a headerless raw
# arm64 image records it nowhere.
arm64_slice.img: arm64_slice.kr
	$(KRC) --target=none --arch=arm64 --emit=image --image-header \
	       --load-addr=$(SLICE_LOAD) --stack-top=$(SLICE_STACK) \
	       arm64_slice.kr -o arm64_slice.img

# The mixed form, which is the one the feature was actually written for:
# x86_64 compiled from hello_fat.kr, arm64 adopted from a DIFFERENT program.
# arm64_slice.kr prints a different banner precisely so `make check` can prove
# the substitution happened rather than assuming it.
fat-mixed.img: hello_fat.kr arm64_slice.img
	$(KRC) --target=none --arch=x86_64,arm64 --emit=fatimage \
	       --slice=arm64:arm64_slice.img \
	       hello_fat.kr -o fat-mixed.img

# A window with the VGA banner in it. Ctrl-A X quits.
run-x86: fat.img
	qemu-system-x86_64 -kernel fat.img -m 256

# The same file, entered through its arm64 Image header instead. Ctrl-A X quits.
run-arm64: fat.img
	qemu-system-aarch64 -M virt -cpu cortex-a72 -m 512 -nographic -kernel fat.img

# The same file again, as a UEFI application under OVMF.
run-uefi: fat.img
	@rm -rf esp && mkdir -p esp/EFI/BOOT && cp fat.img esp/EFI/BOOT/BOOTX64.EFI
	@cp $(OVMF_VARS) esp/vars.fd
	qemu-system-x86_64 -M q35 -m 512 -net none \
	    -drive if=pflash,format=raw,unit=0,readonly=on,file=$(OVMF_CODE) \
	    -drive if=pflash,format=raw,unit=1,file=esp/vars.fd \
	    -drive format=raw,file=fat:rw:esp

# ---------------------------------------------------------------------------
# check: BOOT the artefacts, do not merely build them.
# ---------------------------------------------------------------------------
#
# THREE TRAPS ARE ENCODED HERE, each measured rather than anticipated.
#
# 1. NEVER READ A NEVER-EXITING GUEST'S STDOUT THROUGH A PIPE. QEMU block-
#    buffers piped stdout, and these guests halt in a `loop {}` and never exit,
#    so `timeout` SIGTERMs them and the buffered banner is lost -- the test
#    then fails on a boot that worked perfectly. `-serial file:PATH` writes
#    through, so the arm64 legs capture to a file and grep the file.
#
# 2. WHY PMEMSAVE AT ALL, on the x86_64 legs. A PC's serial port is behind the
#    `out` instruction, and hello_fat.kr cannot contain one -- it is compiled
#    for arm64 as well, where the x86 `asm` block is refused at emission time
#    even inside a branch that is never taken. So the x86_64 half writes its
#    banner to the VGA text buffer (a plain store, which both backends lower)
#    and leaves a flat-ASCII copy at $(WITNESS) for the monitor to dump. Nothing
#    is being faked: the bytes only appear there if the guest ran.
#
# 3. QEMU's HMP `pmemsave` NEEDS THE FILENAME QUOTED. Unquoted, a path with a
#    letter after a `/` is parsed as an expression and the command dies with
#    `invalid char 't' in expression`, having written nothing -- and since the
#    monitor's own output is discarded, the only symptom is a missing file.
#    Also note `-display none -monitor stdio` rather than `-nographic`:
#    -nographic muxes the monitor onto the same stdio the serial port wants.
check: fat.img fat-mixed.img
	@fail=0; \
	x86_witness() { \
	    rm -f "$$2"; \
	    { sleep 3; echo "pmemsave $(WITNESS) 64 \"$$2\""; sleep 1; echo quit; } \
	      | timeout 40 qemu-system-x86_64 -display none -monitor stdio \
	          -kernel "$$1" -m 256 >/dev/null 2>&1; \
	    tr -d '\000' < "$$2" 2>/dev/null; }; \
	arm_serial() { \
	    rm -f "$$2"; \
	    timeout 40 qemu-system-aarch64 -M virt -cpu cortex-a72 -m 512 \
	        -display none -monitor none -serial "file:$$2" \
	        -kernel "$$1" >/dev/null 2>&1; \
	    cat "$$2" 2>/dev/null; }; \
	expect() { \
	    if printf '%s' "$$2" | grep -q "$$3"; then echo "  PASS: $$1"; \
	    else echo "  FAIL: $$1 (wanted '$$3', got '$$2')"; fail=1; fi; }; \
	if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then \
	    echo "  SKIP: x86_64 legs (qemu-system-x86_64 not installed)"; fail=1; \
	else \
	    expect "fat.img boots the x86_64 multiboot path" \
	           "$$(x86_witness fat.img fat_x86.bin)" 'KRFAT x86_64 boot path OK'; \
	    expect "fat-mixed.img boots the x86_64 multiboot path" \
	           "$$(x86_witness fat-mixed.img mixed_x86.bin)" 'KRFAT x86_64 boot path OK'; \
	fi; \
	if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then \
	    echo "  SKIP: arm64 legs (qemu-system-aarch64 not installed)"; fail=1; \
	else \
	    expect "fat.img boots the arm64 Image path" \
	           "$$(arm_serial fat.img fat_arm64.log)" 'KRFAT arm64 boot path OK'; \
	    expect "fat-mixed.img boots the PREBUILT arm64 slice" \
	           "$$(arm_serial fat-mixed.img mixed_arm64.log)" 'KRFAT arm64 PREBUILT SLICE OK'; \
	fi; \
	if [ ! -r "$(OVMF_CODE)" ] || [ ! -r "$(OVMF_VARS)" ]; then \
	    echo "  SKIP: UEFI leg (no OVMF at $(OVMF_CODE)) -- the PE boot path of"; \
	    echo "        this image is then UNCHECKED, not known good"; \
	else \
	    rm -rf esp && mkdir -p esp/EFI/BOOT && cp fat.img esp/EFI/BOOT/BOOTX64.EFI; \
	    cp $(OVMF_VARS) esp/vars.fd; rm -f fat_uefi.bin; \
	    { sleep 14; echo "pmemsave $(WITNESS) 64 \"$$PWD/fat_uefi.bin\""; sleep 1; echo quit; } \
	      | timeout 90 qemu-system-x86_64 -M q35 -m 512 -net none \
	          -drive if=pflash,format=raw,unit=0,readonly=on,file=$(OVMF_CODE) \
	          -drive if=pflash,format=raw,unit=1,file=esp/vars.fd \
	          -drive format=raw,file=fat:rw:esp \
	          -display none -monitor stdio >/dev/null 2>&1; \
	    expect "the SAME fat.img boots as a UEFI application" \
	           "$$(tr -d '\000' < fat_uefi.bin 2>/dev/null)" 'KRFAT x86_64 boot path OK'; \
	    rm -rf esp; \
	fi; \
	if [ $$fail -eq 0 ]; then echo "check: OK"; else echo "check: FAILED"; exit 1; fi

clean:
	rm -f fat.img fat-mixed.img arm64_slice.img \
	      fat_x86.bin mixed_x86.bin fat_uefi.bin \
	      fat_arm64.log mixed_arm64.log
	rm -rf esp

.PHONY: all run-x86 run-arm64 run-uefi check clean
