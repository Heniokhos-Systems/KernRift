# KernRift Language Support

Editor support for the [KernRift](https://github.com/Heniokhos-Systems/KernRift)
systems programming language — syntax highlighting plus a language server that
drives live diagnostics and IntelliSense from the real compiler.

![KernRift syntax highlighting and file icons in VS Code](https://raw.githubusercontent.com/Heniokhos-Systems/KernRift/main/editors/Images/VScode.png)

## Features

- **Syntax highlighting** for `.kr` files, with a file icon (blue cracked K) in
  the explorer and tabs.
- **Live diagnostics** — errors and warnings from `krc check`, mapped to the
  exact line and column as you type.
- **IntelliSense** — completions, hover docs, and go-to-definition for
  keywords, built-ins, types, functions, structs, and enums.

Highlighting covers:

- Integer types — short aliases `u8`/`u16`/`u32`/`u64`, `i8`/`i16`/`i32`/`i64`
  and long forms `uint8`..`int64`.
- Floating point — `f16`, `f32`, `f64`.
- Built-in functions — pointer ops (`load8..64`, `store8..64`), volatile ops
  (`vload/vstore8..64`), atomics (`atomic_load/store/cas/add/...`), bitfield ops
  (`bit_get/set/clear/range/insert`), signed compares (`signed_lt/gt/le/ge`),
  string output (`print_str`, `println_str`), and platform hooks
  (`get_target_os`, `get_arch_id`, `syscall_raw`, `exec_process`).
- Keywords including `let`, `match`, `loop`, `defer`, `for`, `while`, and the
  declaration set (`fn`, `struct`, `enum`, `static`, `const`, `device`, ...).
- `device` blocks for MMIO: `device NAME at ADDR { FIELD at OFF : TYPE rw }`.
- Static and struct arrays (`static u8[N] name`, `Point[10] pts`), slice
  parameters (`fn foo([u8] data)` with `data.len`), and method syntax
  (`fn Point.sum(Point self) -> u64`).
- Annotations (`@export`, `@noreturn`, `@naked`, `@packed`, `@section("name")`)
  and the `#lang` directive (`#lang stable` / `#lang experimental`).
- String/char literals with escapes, line (`//`) and block (`/* */`) comments,
  auto-closing brackets, indentation, and folding.

## Requirements

Syntax highlighting works on its own. **Diagnostics and hover docs need the
`krc` compiler installed** — the language server shells out to `krc check`. If
`krc` is not found, highlighting and completions still work, but no errors are
reported.

Install the compiler from [kernrift.org](https://kernrift.org) (or via
Homebrew / apt / Scoop / AUR — see the
[repository](https://github.com/Heniokhos-Systems/KernRift)), and make sure
`krc` is on your `PATH` or set `kernrift.compilerPath` below.

## Extension Settings

| Setting | Default | Description |
| --- | --- | --- |
| `kernrift.compilerPath` | `krc` | Path to the `krc` compiler binary used for diagnostics. Set this if `krc` is not on your `PATH`. |

## About KernRift

KernRift is a self-hosted, bare-metal systems language. It compiles itself
ahead-of-time to native machine code — no VM, no interpreter, no runtime, no
libc. One `.krbo` fat binary contains all **8 platform slices**
(Linux / macOS / Windows / Android × x86_64 / ARM64); a small `kr` runner
extracts the matching slice at startup and executes it. Self-host bootstrap
fixed point is verified by CI on every push.

The compiler is written entirely in KernRift and includes an SSA IR backend,
graph-coloring register allocator, constant folding / DCE / CSE, and per-target
ELF / Mach-O / PE emitters — no LLVM, no external assembler, no external linker.

- [GitHub](https://github.com/Heniokhos-Systems/KernRift)
- [Website](https://kernrift.org)
- [Language Reference](https://github.com/Heniokhos-Systems/KernRift/blob/main/docs/LANGUAGE.md)
- [Living Compiler (`krc lc`)](https://kernrift.org/living-compiler.html)
