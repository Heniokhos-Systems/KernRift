# KernRift Documentation

The full documentation index. New users should start in **Learn**; the
**Reference** section is the day-to-day lookup; **Internals** is for
contributors and the curious; **Project** tracks direction and process.

## Learn

- [Getting Started](getting-started.md) — install, write and run your
  first program, run the tests.
- [Cheatsheet](CHEATSHEET.md) — every construct on one page, with examples
  (a few blocks are type/API listings rather than whole programs).
- [Tutorial: B-tree](tutorial-btree.md) — building a real data structure.
- [Tutorial: UART driver](tutorial-uart-driver.md) — `device` blocks and
  memory-mapped I/O.

## Embedded & bare metal

- [Embedded targets](../README.md#embedded-targets-riscv32--xtensa--esp32) —
  the riscv32 / xtensa / ESP32 backends: the verified support matrix (no
  floats, no 64-bit integers, no structs when freestanding, and **none of the
  52 `std/` modules**), the freestanding `fn main() -> uint32` programming
  model, and the ESP32 IRAM/DRAM budget.
- [Freestanding mode](LANGUAGE.md#23-freestanding-mode) — the same ground from
  the language side: what `--freestanding` changes, the embedded-target subset,
  and which constructs survive it.
- [`examples/esp32/`](../examples/esp32/) — the annotated ESP32 boot image that
  was validated on real silicon.

  (Loadable Linux kernel modules are covered by [Kernel Modules](LKM.md) under
  Reference.)

## Reference

- [Language Reference](LANGUAGE.md) — the complete language: types,
  operators, control flow, structs, functions, builtins, annotations.
- [Grammar](GRAMMAR.md) — the EBNF grammar and lexical rules.
- [Standard Library](STDLIB.md) — 19 of the 52 `std/*.kr` modules, function
  by function. The other 33 — the bare-metal drivers, the AMD GPU bring-up
  modules and `apexrift` — are not written up yet; read their source.
- [Undefined Behavior](UNDEFINED_BEHAVIOR.md) — what is defined, what
  traps under `--debug`, and what is genuinely UB. **Read before writing
  `unsafe` code.**
- [Error Handling](ERROR_HANDLING.md) — the sentinel/`opt`/abort
  conventions the standard library follows.
- [Debugging](DEBUGGING.md) — `-g` DWARF, `--debug` traps, the
  miscompile bisection ladder, IR/asm dumps.
- [Kernel Modules](LKM.md) — compiling to a loadable Linux `.ko` with
  `--emit=lkm`.

## Internals

- [Architecture](ARCHITECTURE.md) — the compiler pipeline and source
  layout.
- [IR Reference](IR_REFERENCE.md) — the IR (not SSA): opcodes, the optimizer
  passes, the register allocator.
- [ABI Policy](ABI_POLICY.md) — calling conventions and platform ABI
  decisions.
- [Effect System](EFFECT_SYSTEM.md) — the `@ctx` / `@eff` / `@acquires` /
  `@caps` analysis annotations. **All five passes are implemented and fatal**
  under `krc check`, which exits 1; an ordinary compile does not run them.
  (This entry said "design only" long after that stopped being true.)

## Project

- [Changelog](../CHANGELOG.md) — release-by-release history.
- [Roadmap](roadmap-next.md) — what's planned next.
- [Contributing](../CONTRIBUTING.md) — building, testing, and the CI gate.
- [Living Compiler](LIVING_COMPILER.md) — the `lc` self-evolution vision.
- [Android debug kit](android-debug-kit.md) — platform-specific tooling.
- [GPU driver bring-up handoff](GPU_DRIVER_BRINGUP_HANDOFF.md) — working notes
  for one piece of work rather than reference material, listed because this page
  claims to be the full index.

(`docs/PHASE_B_DESIGN.md` and `docs/MLRIFT_PORT_SCOPE.md` exist in a working
tree but are **gitignored**, so they are deliberately not linked here — a link
to either is a broken link in a fresh clone.)
