# KernRift Examples

Each file in this directory is a standalone runnable KernRift program that
compiles with the current `krc` and exercises a specific language feature.

## Running

```sh
krc hello.kr --arch=x86_64 -o hello
./hello
```

Or build a fat binary and run with the `kr` runner:

```sh
krc hello.kr -o hello.krbo
kr hello.krbo
```

## What's in here

| File | Demonstrates |
|------|--------------|
| `hello.kr` | The minimum program: `println` of a string literal. |
| `fib.kr` | Recursive Fibonacci — recursion, `for..in`, integer arithmetic. |
| `fizzbuzz.kr` | `for` loops, `if/else` chains, `println` with both literals and variables. |
| `pointers.kr` | `load8/16/32/64` and `store8/16/32/64` builtins — the clean way to access memory. |
| `count_chars.kr` | Byte-level string iteration via `load8`. |
| `slices.kr` | `[T] name` slice parameters + `.len` — fat pointer pattern. |
| `struct_arrays.kr` | `Point[10] pts` — fixed arrays of structs. |
| `mmio_driver.kr` | `device` blocks — named typed MMIO registers with volatile semantics. |
| `echo.kr` | `scan_str` / `print_str` for stdin / stdout with variable strings. |
| `extern_libc.kr` | `extern fn` — call libc (`strlen`, `write`) via ELF/Mach-O/COFF relocations. |
| `linked_list.kr` | Canonical heap-struct pattern — `Node n = alloc(16)`, append, traverse. |

## Notes

- All examples use the short type aliases (`u8`, `u16`, `u32`, `u64`) rather
  than the long forms (`uint8` etc.).
- `println(variable)` formats the variable as a decimal integer. For
  variables that hold string pointers, use `print_str` / `println_str`.
- Range loops default to the exclusive form `0..n`; the inclusive form
  `0..=n` (visits `n`) is also supported.
