# Architecture

The KernRift compiler (`krc`) is a self-hosting compiler written entirely in KernRift. It compiles itself to a bit-identical fixed point. No external assembler, linker, or C toolchain is involved — `krc` writes ELF, Mach-O, PE, and ESP32 esp-image headers plus native machine code directly to disk.

## Source Structure

```
src/
├── lexer.kr           Tokenizer (90+ token kinds)
├── ast.kr             Arena-based flat AST (32-byte nodes, 1-indexed)
├── parser.kr          Recursive descent + Pratt precedence climbing
├── analysis.kr        Semantic checks (missing return, unused/uninit, arg
│                      counts) + diagnostics (spans/carets); effect passes
├── type_check.kr      Type checker (default-on, fatal) + `let` inference
├── inliner.kr         AST-level inliner: pure single-expression callees → call sites
├── ir.kr              SSA IR + x86_64 emitter, liveness, graph-colour RA with
│                      Briggs/George coalescer, LICM, CF/DCE/CSE
├── ir_aarch64.kr      AArch64 emitter from the same IR
├── ir_riscv.kr        RV32IMC emitter from the same IR (+ C-compression peephole)
├── ir_xtensa.kr       Xtensa LX6 emitter from the same IR (literal pools, CALL0
│                      frames, ESP32 IRAM/DRAM layout guards)
├── codegen.kr         Legacy direct x86_64 codegen (SysV ABI)
├── codegen_aarch64.kr Legacy direct AArch64 codegen (AAPCS64)
├── codegen_riscv.kr   RV32IMC disassembler for --emit=asm
├── codegen_xtensa.kr  Xtensa disassembly / encoding helpers
├── format_macho.kr    macOS Mach-O header emission
├── format_pe.kr       Windows PE/COFF headers + import table
├── format_espimage.kr ESP32 esp-image container (byte-identical to esptool)
├── format_android.kr  Android ELF quirks (DT_FLAGS_1, soname)
├── format_archive.kr  AR archives, KRBO objects, KrboFat v2 (BCJ + LZ-Rift)
├── bcj.kr             Branch/call/jump filter for better compression
├── living.kr          Pattern detection + fitness scoring
├── formatter.kr       Source-level auto-formatter
├── runner.kr          `kr` — fat-binary slice extractor / launcher
├── runtime.kr         fmt_uint helper
└── main.kr            CLI, compile(), compile_fat()
```

## Compilation Pipeline

1. **Lex** — source text → flat token array (16 bytes per token)
2. **Parse** — tokens → arena AST (32 bytes per node, child/sibling links)
3. **Check** — semantic validation (missing return, arg counts, unused/uninitialized) + the type checker (`type_check.kr`); `let` type inference resolves each inferred local. Errors here are fatal. The effect/capability/lock passes also run (advisory).
4. **Inline** — AST-level pass folds pure single-expression callees into call sites; DCE drops the unused originals (translation-unit `--emit=obj/asm/ir` keep them)
5. **Lower to IR** — AST → SSA IR instructions with virtual registers
6. **Optimize IR** — constant folding → DCE → CSE → LICM → DCE
7. **Liveness** — per-opcode live-in/live-out sets for all virtual registers
8. **Register allocation** — Chaitin-style graph coloring with Briggs/George copy coalescing onto physical registers
9. **Emit** — a per-target emitter writes raw machine bytes; see [Emitter fan-out](#emitter-fan-out) below
10. **Fixup** — patch call displacements, RIP-relative / ADRP offsets, string addresses
11. **Write** — ELF / Mach-O / PE headers + code + data + strings straight to the output file

The `--legacy` flag bypasses steps 5–8 and uses the direct AST-walking codegen path instead. Legacy codegen remains available as a correctness oracle; IR is the default and the supported path forward, and now produces strictly smaller binaries on both x86_64 and arm64. `--no-coalesce` disables step 8's coalescer if you need to bisect a related issue.

## Emitter fan-out

Steps 1–8 are entirely target-independent: one lexer, one parser, one checker,
one optimizer, one register allocator. Step 9 is where the single IR fans out
to **five** machine-code emitters, and step 11 to the container writers.

```
                        AST → SSA IR → opt → liveness → regalloc
                                          │
        ┌─────────────┬───────────────────┼───────────────┬─────────────┐
        ▼             ▼                   ▼               ▼             ▼
    ir.kr         ir_aarch64.kr      ir_riscv.kr    ir_xtensa.kr   (--legacy)
    x86_64          AArch64            RV32IMC       Xtensa LX6    codegen*.kr
        │             │                   │               │
        ▼             ▼                   ▼               ▼
   ELF/Mach-O/PE  ELF/Mach-O/PE     ELF32 / raw blob   raw blob / esp-image
```

The register allocator is parameterized per target rather than duplicated:
`IR_NUM_REGS` and the colour map differ (x86_64 GPRs, AArch64 x0–x28, RISC-V
s0–s11, Xtensa a0–a15), but the graph-colouring algorithm, liveness, and
coalescer are shared code.

Two properties are *not* uniform across emitters, and the compiler enforces the
difference with hard errors rather than silent fallbacks:

- **Word size** is 4 bytes on riscv32/xtensa and 8 bytes elsewhere. 64-bit
  integer types are rejected at their declaration site on the 32-bit targets.
- **Opcode coverage** is a subset on the embedded emitters. An IR opcode a
  backend has not implemented aborts the compile
  (`error: <arch>: IR op <N> not yet implemented`) — for example `IR_ALLOC`
  (op 70) is implemented only on the hosted RISC-V path, which is why structs
  and `alloc()` are unavailable on freestanding riscv32 and on xtensa.

The full matrix of what each embedded backend supports is in the
[README](../README.md#embedded-targets-riscv32--xtensa--esp32).

## IR vs legacy in the shipped binaries

All 8 targets ship with the IR backend by default. The IR ARM64 `compile_fat` miscompile that previously forced `--legacy` on arm64 binaries is fixed (R1), so every shipped `krc-*` and `kr-*` builds with IR. `--legacy` remains as an explicit opt-out.

## Android fat-binary runner

`src/runner.kr` (the `kr` tool) on Android prefers a filesystem-free exec path:

1. `memfd_create("kr", MFD_CLOEXEC)` — anonymous in-kernel fd
2. `write(fd, slice, slice_size)` — copy the BCJ-decoded slice into it
3. `execveat(fd, "", argv, envp, AT_EMPTY_PATH)` — kernel ignores the pathname and execs the fd directly

This bypasses the SELinux file-label transition Termux uses to block execve of user-owned binaries, avoids touching any noexec mount, and leaves nothing behind in the user's cwd. On kernels older than Linux 3.17 (no `memfd_create`) it falls back to the file-based path (chmod + execve + exit-120 shell-wrapper trampoline) that earlier releases used.

## Key Design Decisions

- **Flat AST**: 32-byte nodes (8 fixed 4-byte slots: kind, data1–data4, tok, child, next) in a contiguous arena, 1-indexed. No pointers, just indices. Tokens are 16-byte records in a parallel arena.
- **Arenas, some fixed and some growable**: the token buffer is sized for 524288 tokens and the AST arena similarly; the self-compile sits near 48%, and `make check` fails if it crosses 80% (raise `max_tok` in `main.kr` before that). Several tables that used to have hard caps now grow on demand through the shared `grow_buf` helper (`codegen.kr`) — a fresh mmap, a copy, then release of the old mapping. That covers the IR instruction arena and its parallel source-token table, the IR basic-block lists, the struct table and each struct's field list, and the import machinery (seen-set, search paths, path buffer). Because `grow_buf` moves the base pointer, any code holding a raw offset into one of these tables must re-derive it after a growth. Tables that still have fixed caps fail loud on overflow rather than truncating.
- **SSA IR**: target-independent opcodes (114 as of v2.8.28; see [IR_REFERENCE.md](IR_REFERENCE.md)), virtual registers, liveness, graph-coloring register allocator with Briggs/George copy coalescing, an AST-level inliner, LICM, constant folding, DCE, and CSE. Added in v2.8.2, replacing the "no IR" stance of earlier versions.
- **Per-target emitters, shared IR**: Linux/macOS/Windows/Android syscall conventions, Mach-O argc/argv in x0/x1, Windows IAT calls — all handled at emission time from the same abstract opcodes.
- **No external tools**: the compiler writes binaries directly; there is no assembler, linker, or libc in the build graph.
- **Variable dedup**: same-named variables in different if-branches share a slot.
- **Static access**: RIP-relative on x86_64, ADRP+ADD / LDR on AArch64.
- **Fat binary default**: `compile_fat()` runs the IR backend once per target, BCJ-filters the code, LZ-Rift-compresses each slice, and packs all eight into a KrboFat v2 `.krbo`.

## Bootstrap

```
released krc binary → krc (stage 1, from source)
krc → krc2 (stage 2, self-compiled)
krc2 → krc3 (stage 3)
krc3 → krc4 (stage 4)
krc3 == krc4 (bit-identical fixed point)
```

There is no Rust, no C, and no LLVM in the build. A released `krc` binary compiles the current source tree into the next `krc`. CI verifies the fixed point on every push across all eight platform targets.
