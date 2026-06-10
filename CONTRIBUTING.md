# Contributing to KernRift

## Prerequisites

- **Bootstrap compiler** — needed only once to go from nothing to a
  working `krc`: `cargo install --git https://github.com/Pantelis23/KernRift-bootstrap kernriftc`
- After the first build, `krc` compiles itself — no Rust, C, or LLVM
  needed for any subsequent build.

## Build

```sh
make build       # use the existing self-hosted krc2 to recompile the sources
```

`make build` concatenates the `src/*.kr` files (in the order in the
Makefile's `SRCS`) into `build/krc.kr` and self-compiles it to
`build/krc2`. All sources are one compilation unit, so every function is
globally visible across files.

## The pre-PR gate: `make check`

Run **`make check`** before submitting anything. It is the real CI gate
and runs, aborting on the first failure:

1. **Bootstrap fixed point** — `krc3 == krc4` byte-for-byte (the compiler
   compiles itself to a stable fixed point).
2. **Test suite** — `tests/run_tests.sh` (560+ tests).
3. **IR-vs-legacy differential** — `tests/diff_ir_legacy.sh` and
   `diff_ir_legacy_stdout.sh` compile+run each probe on all four backends
   (IR/legacy × x86_64/arm64, arm64 under `qemu-aarch64-static`) and
   compare exit codes and stdout. Any divergence fails.
4. **Self-host invariants** — the token/AST arena stays under 80% of the
   524288-token cap, and the self-compile emits zero spurious
   used-before-init warnings.
5. **Differential fuzz** — a deterministic-seed run of `tests/fuzz/run.sh`
   plus replay of every recorded regression in `tests/fuzz/regressions/`.

`make test` runs only step 2; `make bootstrap` only step 1.

## Source structure

All compiler source is in `src/` (one compilation unit; see the Makefile
`SRCS` for the canonical order):

| File | Purpose |
|------|---------|
| `lexer.kr` | Tokenizer |
| `ast.kr` | AST node arena + accessors (32-byte nodes) |
| `parser.kr` | Parser (recursive descent + Pratt expressions) |
| `analysis.kr` | Semantic checks + diagnostics (`diag_*`) |
| `type_check.kr` | Type checker (default-on, fatal) + `let` inference |
| `ir.kr` | SSA IR: lowering, optimizer passes, register allocation, x86_64 emit |
| `ir_aarch64.kr` | IR AArch64 emit |
| `codegen.kr` | Legacy direct x86_64 codegen (`--legacy`) |
| `codegen_aarch64.kr` | Legacy direct AArch64 codegen |
| `inliner.kr` | AST-level function inliner |
| `bcj.kr` | BCJ filters for fat-binary slice compression |
| `format_macho.kr` / `format_pe.kr` / `format_archive.kr` / `format_android.kr` | Output container formats (ELF is in the codegen/ir emit) |
| `living.kr` | Living compiler (`lc` mode: patterns, proposals, CI gating) |
| `runtime.kr` | Runtime/startup support |
| `formatter.kr` | `krc fmt` source formatter |
| `runner.kr` | The `kr` `.krbo` fat-binary runner (built separately) |
| `main.kr` | CLI argument parsing + compilation driver |

The default backend is the **IR** path (`ir.kr` + `ir_aarch64.kr`); the
**legacy** direct backend (`codegen*.kr`) is kept as an independent
second implementation and a differential oracle — see the IR vs legacy
harnesses. New language features should land on the IR path.

The standard library is in `std/` (18 modules) — see
[docs/STDLIB.md](docs/STDLIB.md) for the per-function reference.

## Adding a test

Tests live in `tests/run_tests.sh`. The common helpers:

- `run_test "name" 'SOURCE' EXPECTED_EXIT` — compile + run on the default
  (IR) backend, assert the exit code.
- `run_test_legacy "name" 'SOURCE' EXPECTED_EXIT` — same on `--legacy`
  (must appear **after** the `run_test_legacy` definition in the file).
- `run_test_output "name" 'SOURCE' 'EXPECTED_STDOUT' [exit]` — assert
  stdout.
- `diag_span_test "name" 'SOURCE' 'substring'` — assert the program does
  **not** compile and the error contains the substring plus a source
  span and `^` caret.

For a behavior that could differ between backends, also add a case to
`tests/diff_ir_legacy.sh` / `diff_ir_legacy_stdout.sh`.

## Architecture & internals

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the pipeline and
[docs/IR_REFERENCE.md](docs/IR_REFERENCE.md) for the IR, optimizer, and
register allocator (including the "adding an opcode" surface).

## Guidelines

- The compiler must always self-compile to a fixed point — run
  `make check` (or at least `make bootstrap`) before submitting.
- No external dependencies — the compiler stays fully self-contained.
- Keep the IR and legacy backends in agreement (the differential
  harnesses enforce this); prefer adding features to the IR path.
