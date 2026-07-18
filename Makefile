# KernRift Self-Hosted Compiler
# Usage:
#   make              - build the compiler
#   make test         - run test suite
#   make install      - install to ~/.local/bin
#   make dist         - create distribution binaries for all platforms
#   make clean        - remove build artifacts
#   make bootstrap    - verify bootstrap (krc3 == krc4)

KERNRIFTC ?= kernriftc
INSTALL_DIR ?= $(HOME)/.local/bin
DIST_DIR = dist

SRCS = src/lexer.kr src/ast.kr src/parser.kr src/codegen.kr \
       src/codegen_aarch64.kr src/ir.kr src/ir_aarch64.kr src/ir_riscv.kr src/codegen_riscv.kr src/ir_xtensa.kr src/codegen_xtensa.kr src/format_macho.kr src/format_pe.kr \
       src/format_archive.kr src/format_android.kr src/bcj.kr src/analysis.kr src/type_check.kr src/inliner.kr src/living.kr \
       src/runtime.kr src/formatter.kr src/main.kr

.PHONY: all build kr-runner test install dist clean bootstrap check

all: build kr-runner

# Build from the self-hosted compiler (no Rust needed)
build: build/krc2

# Build the .krbo runner. runner.kr references filter_aarch64_bcj /
# filter_x86_64_bcj from bcj.kr, so the two must be concatenated before
# compile — otherwise the runner builds with unresolved BCJ calls and
# silently corrupts every extracted slice (entry-point bytes get
# clobbered, slice bus-errors at startup).
#
# `kr` is a shell wrapper (packaging/kr.sh) that catches exit 120 from
# kr-bin and re-execs the extracted ./kr-exec — needed on Termux/Android
# where raw execve from app data dirs is SELinux-denied. Other hosts hit
# the wrapper's `exit $status` line as a no-op since the runner exec's
# the slice directly.
kr-runner: build/kr build/kr-bin

build/kr-runner.kr: src/runner.kr src/bcj.kr
	@mkdir -p build
	cat src/runner.kr src/bcj.kr > build/kr-runner.kr

build/kr-bin: build/kr-runner.kr build/krc2
	./build/krc2 --arch=x86_64 build/kr-runner.kr -o build/kr-bin
	chmod +x build/kr-bin
	@echo "Built build/kr-bin (host-native runner binary)"

build/kr: packaging/kr.sh
	@mkdir -p build
	cp packaging/kr.sh build/kr
	chmod +x build/kr
	@echo "Built build/kr (shell wrapper for kr-bin)"

build/krc.kr: $(SRCS)
	@mkdir -p build
	cat $(SRCS) > build/krc.kr

# Use the pre-built self-hosted compiler to self-compile
build/krc2: build/krc.kr
	@if [ -f build/krc2 ]; then \
		./build/krc2 --arch=x86_64 build/krc.kr -o build/krc2.new && \
		mv build/krc2.new build/krc2 && chmod +x build/krc2; \
	elif [ -f $(DIST_DIR)/krc-linux-x86_64 ]; then \
		cp $(DIST_DIR)/krc-linux-x86_64 build/krc2 && chmod +x build/krc2 && \
		./build/krc2 --arch=x86_64 build/krc.kr -o build/krc2.new && \
		mv build/krc2.new build/krc2; \
	else \
		echo "No self-hosted compiler found. Bootstrap from Rust:"; \
		echo "  cargo install --git https://github.com/Pantelis23/KernRift-bootstrap kernriftc"; \
		echo "  $(KERNRIFTC) --emit=hostexe build/krc.kr -o build/krc"; \
		echo "  cp build/krc.kr test_input.kr && ./build/krc && mv a.out build/krc2"; \
		exit 1; \
	fi

# Build using the import system (no cat needed)
build-import: build/krc2
	./build/krc2 --arch=x86_64 src/main.kr -o build/krc-import
	chmod +x build/krc-import

# Run test suite
test: build/krc2
	@echo "=== Running test suite ==="
	@echo '#!/bin/bash' > /tmp/krc-test && echo 'exec ./build/krc2 --arch=x86_64 "$$@"' >> /tmp/krc-test && chmod +x /tmp/krc-test
	@KRC=/tmp/krc-test bash tests/run_tests.sh

# Full CI gate: bootstrap fixed point + suite + both IR-vs-legacy differential
# harnesses (x86_64 + arm64 via qemu). Any failure aborts (each step exits
# non-zero on failure). Wire THIS into CI, not just `make test`.
check: build/krc2 bootstrap test
	@echo "=== IR vs legacy differential (exit codes) ==="
	@KRC=./build/krc2 bash tests/diff_ir_legacy.sh
	@echo "=== IR vs legacy differential (stdout) ==="
	@KRC=./build/krc2 bash tests/diff_ir_legacy_stdout.sh
	@echo "=== Token/AST cap headroom (fail >80%) ==="
	@toks=$$(./build/krc2 --arch=x86_64 build/krc.kr -o /dev/null 2>&1 | grep -oE '^[0-9]+ tokens' | grep -oE '^[0-9]+'); \
	 cap=524288; pct=$$(( toks * 100 / cap )); \
	 echo "self-compile: $$toks / $$cap tokens ($$pct%)"; \
	 if [ "$$pct" -ge 80 ]; then echo "FAIL: token cap >80% — raise max_tok"; exit 1; fi
	@echo "=== Self-host warning invariant (no spurious used-before-init) ==="
	@uninit=$$(./build/krc2 --arch=x86_64 build/krc.kr -o /dev/null 2>&1 | grep -c "used before initialization" || true); \
	 echo "used-before-init warnings on self-compile: $$uninit"; \
	 if [ "$$uninit" -ne 0 ]; then echo "FAIL: spurious used-before-init warnings — a working compiler never reads an uninitialized local"; exit 1; fi
	@echo "=== Differential fuzz (deterministic seed, 20 programs + regressions) ==="
	@if command -v python3 >/dev/null 2>&1; then \
		KRC=./build/krc2 FUZZ_COUNT=20 bash tests/fuzz/run.sh; \
	else echo "  (skipped: python3 not found)"; fi
	@echo "=== check: all gates passed ==="

# Verify bootstrap convergence
bootstrap: build/krc2
	@echo "=== Bootstrap verification ==="
	@cp build/krc.kr /tmp/krc_bs_src.kr
	@./build/krc2 --arch=x86_64 /tmp/krc_bs_src.kr -o /tmp/krc3_bs 2>/dev/null
	@chmod +x /tmp/krc3_bs
	@/tmp/krc3_bs --arch=x86_64 /tmp/krc_bs_src.kr -o /tmp/krc4_bs 2>/dev/null
	@if diff /tmp/krc3_bs /tmp/krc4_bs >/dev/null 2>&1; then \
		echo "PASS: fixed point at $$(wc -c < /tmp/krc3_bs) bytes"; \
	else \
		echo "FAIL: krc3 != krc4"; exit 1; \
	fi
	@rm -f /tmp/krc_bs_src.kr /tmp/krc3_bs /tmp/krc4_bs

# Install to INSTALL_DIR
install: build/krc2
	@mkdir -p $(INSTALL_DIR)
	cp build/krc2 $(INSTALL_DIR)/krc
	chmod +x $(INSTALL_DIR)/krc
	@echo "Installed: $(INSTALL_DIR)/krc"
	@echo "Ensure $(INSTALL_DIR) is in your PATH"

# Create distribution binaries
dist: build/krc2
	@mkdir -p $(DIST_DIR)
	@echo "=== Building distribution ==="
	@# x86_64 Linux ELF
	cp build/krc2 $(DIST_DIR)/krc-linux-x86_64
	chmod +x $(DIST_DIR)/krc-linux-x86_64
	@echo "  krc-linux-x86_64"
	@# ARM64 Linux ELF (cross-compiled). R1 fix landed — IR ARM64 now
	@# handles 9+ arg calls correctly so the previous --legacy override
	@# is no longer needed. Validated natively on Redmi Note 8 Pro.
	./build/krc2 --arch=arm64 build/krc.kr -o $(DIST_DIR)/krc-linux-arm64 2>/dev/null
	chmod +x $(DIST_DIR)/krc-linux-arm64
	@echo "  krc-linux-arm64"
	@# Windows PE (cross-compiled)
	./build/krc2 --arch=x86_64 --emit=pe build/krc.kr -o $(DIST_DIR)/krc-windows-x86_64.exe 2>/dev/null
	@echo "  krc-windows-x86_64.exe"
	./build/krc2 --arch=arm64 --emit=pe build/krc.kr -o $(DIST_DIR)/krc-windows-arm64.exe 2>/dev/null
	@echo "  krc-windows-arm64.exe"
	@# Fat binary (default)
	./build/krc2 build/krc.kr -o $(DIST_DIR)/krc.krbo 2>/dev/null
	@echo "  krc.krbo (x86_64 + arm64)"
	@# Source distribution
	cp build/krc.kr $(DIST_DIR)/krc-source.kr
	@echo "  krc-source.kr"
	@# License + attribution (Apache 2.0 §4a/§4d — travel with every copy)
	cp LICENSE NOTICE $(DIST_DIR)/
	@echo "  LICENSE + NOTICE"
	@echo ""
	@ls -la $(DIST_DIR)/
	@echo ""
	@echo "=== Distribution complete ==="

# Clean all build artifacts
clean:
	rm -rf build/krc build/krc2 build/krc.kr
	rm -rf $(DIST_DIR)
	rm -f a.out output.elf test_input.kr
	rm -f krc2 krc3 krc4 krc_arm64
	rm -f *.elf *.out
	@echo "Cleaned."
