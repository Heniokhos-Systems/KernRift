# KernRift Language Support

Language support for the [KernRift](https://github.com/Rift-Intelligence/KernRift) systems programming language — version-locked to the compiler.

## Features

- **Syntax highlighting** for `.kr` files
- **File icon** (blue cracked K) in the explorer and tabs
- **LSP** powered by `krc check` — diagnostics, completions, hover docs, go-to-definition
- Short type aliases: `u8`/`u16`/`u32`/`u64`, `i8`/`i16`/`i32`/`i64`
- Long type forms: `uint8`..`int64`
- v2.8 builtins highlighted as built-in functions:
  - **Pointer ops**: `load8`/`load16`/`load32`/`load64`, `store8/16/32/64`
  - **Volatile ops**: `vload8/16/32/64`, `vstore8/16/32/64`
  - **String output**: `print_str`, `println_str`
  - **Atomics**: `atomic_load`, `atomic_store`, `atomic_cas`, `atomic_add/sub/and/or/xor`
  - **Bitfield**: `bit_get`, `bit_set`, `bit_clear`, `bit_range`, `bit_insert`
  - **Signed compare**: `signed_lt`, `signed_gt`, `signed_le`, `signed_ge`
  - **Platform**: `get_target_os`, `get_arch_id`, `syscall_raw`, `exec_process`
- **Device blocks** for MMIO: `device NAME at ADDR { FIELD at OFF : TYPE rw }`
- **Static/struct arrays**: `static u8[N] name`, `Point[10] pts`
- **Slice parameters**: `fn foo([u8] data)` with `data.len`
- **`#lang`** directive highlighting for `#lang stable` / `#lang experimental`
- **Method syntax**: `fn Point.sum(Point self) -> u64`
- Annotations: `@export`, `@noreturn`, `@naked`, `@packed`, `@section("name")`
- String/char literals with escape sequences
- Line (`//`) and block (`/* */`) comments
- Auto-closing brackets, indentation, folding

## About KernRift

KernRift is a self-hosted, bare-metal systems language. It compiles itself ahead-of-time to native machine code — no VM, no interpreter, no runtime, no libc. One `.krbo` fat binary contains all **8 platform slices** (Linux / macOS / Windows / Android × x86_64 / ARM64); a small `kr` runner extracts the matching slice at startup and executes it. Self-host bootstrap fixed point is verified by CI on every push.

The compiler is written entirely in KernRift and includes an SSA IR backend, graph-coloring register allocator, constant folding / DCE / CSE, and per-target ELF / Mach-O / PE emitters — no LLVM, no external assembler, no external linker.

- [GitHub](https://github.com/Rift-Intelligence/KernRift)
- [Website](https://kernrift.org)
- [Language Reference](https://github.com/Rift-Intelligence/KernRift/blob/main/docs/LANGUAGE.md)
- [Living Compiler (`krc lc`)](https://kernrift.org/living-compiler.html)
