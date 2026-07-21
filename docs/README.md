# KernRift Documentation

The full documentation index. New users should start in **Learn**; the
**Reference** section is the day-to-day lookup; **Internals** is for
contributors and the curious; **Project** tracks direction and process.

## Learn

- [Getting Started](getting-started.md) — install, write and run your
  first program, run the tests.
- [Cheatsheet](CHEATSHEET.md) — every construct on one page, each with a
  runnable example.
- [Tutorial: B-tree](tutorial-btree.md) — building a real data structure.
- [Tutorial: UART driver](tutorial-uart-driver.md) — `device` blocks and
  memory-mapped I/O.

## Embedded & bare metal

- [Embedded targets](../README.md#embedded-targets-riscv32--xtensa--esp32) —
  the riscv32 / xtensa / ESP32 backends: the verified support matrix (no
  floats, no 64-bit integers, no structs when freestanding), the freestanding
  `fn main() -> uint32` programming model, and the ESP32 IRAM/DRAM budget.
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
- [Standard Library](STDLIB.md) — every `std/*.kr` module, function by
  function.
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
- [IR Reference](IR_REFERENCE.md) — the SSA IR: opcodes, the optimizer
  passes, the register allocator.
- [ABI Policy](ABI_POLICY.md) — calling conventions and platform ABI
  decisions.
- [Effect System](EFFECT_SYSTEM.md) — the `@ctx` / `@eff` / `@caps`
  analysis annotations.

## Project

- [Changelog](../CHANGELOG.md) — release-by-release history.
- [Roadmap](roadmap-next.md) — what's planned next.
- [Contributing](../CONTRIBUTING.md) — building, testing, and the CI gate.
- [Living Compiler](LIVING_COMPILER.md) — the `lc` self-evolution vision.
- [Android debug kit](android-debug-kit.md) — platform-specific tooling.
