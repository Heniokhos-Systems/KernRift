# Getting Started with KernRift

**KernRift** is a self-hosted systems programming language and compiler
created by Pantelis Christou. It produces native binaries for Linux,
Windows, macOS, and Android on x86_64 and ARM64, plus bare-metal images for
32-bit RISC-V, Xtensa LX6, and the ESP32.

This guide walks through installing the compiler, writing and running your
first program, and the language features you'll use in day-to-day code.

## Install

### Linux / macOS

```bash
curl -sSf https://raw.githubusercontent.com/Pantelis23/KernRift/main/install.sh | sh
```

Installs `krc` (compiler) and `kr` (runner) to `~/.local/bin/`, and the
standard library to `~/.local/share/kernrift/`. Make sure `~/.local/bin`
is on your `PATH`.

### Windows

```powershell
irm https://raw.githubusercontent.com/Pantelis23/KernRift/main/install.ps1 | iex
```

Installs to `%LOCALAPPDATA%\KernRift\bin\` and adds it to `PATH`.

### Verify

```sh
krc --version
kr --version
```

## Your first program

Save this as `hello.kr`:

```kr
fn main() {
    println("Hello, KernRift!")
    exit(0)
}
```

Compile and run:

```sh
krc hello.kr --arch=x86_64 -o hello
./hello
```

A successful compile reports what it produced and how long it took:

```
15 tokens, 9 nodes, 264 bytes -> hello  (0.61 ms)
```

Or build a cross-platform fat binary and run it through `kr`:

```sh
krc hello.kr -o hello.krbo
kr hello.krbo
```

## Cheatsheet (one page)

Everything a first-time user usually needs, in one place. Full details
live in [LANGUAGE.md](LANGUAGE.md).

**Operators** (tightest → loosest):
`!` `~` `-` (prefix) · `&` `|` `^` · `<<` `>>` · `*` `/` `%` · `+` `-`
· `<` `<=` `>` `>=` (signed when an operand is `i8`..`i64`, unsigned
otherwise; `signed_lt`/`signed_gt`/`signed_le`/`signed_ge` force signed)
· `==` `!=` · `&&` · `||` · `?:` (ternary).
Bitwise ops and shifts bind *tighter* than arithmetic — unlike C.
Compound assigns: `+=` `-=` `*=` `/=` `%=` `&=` `|=` `^=` `<<=` `>>=`.

**Scalar types** are `u8`/`u16`/`u32`/`u64` and their signed siblings
`i8`/`i16`/`i32`/`i64`; `f16`, `f32`, and `f64` cover IEEE 754 floats;
`bool` stores a single byte holding `true` / `false`; `char` stores a
single byte holding a character literal (`'A'`, `'\n'`, …). `u64` is the
integer default — use it when in doubt.

**`bool`** is strictly typed since v2.8.3: you cannot assign an integer
literal to a `bool` variable (`bool b = 1` is rejected; `bool b = true`
is the spelling). `if` and `while` still accept integer conditions where
`0` is false and any non-zero value is true, so stdlib predicates that
return `0` / `1` (like `str_eq`, `is_prime`) read naturally in control
flow: `if is_prime(n) { ... }`.

**Integer division** is truncating: `7 / 2 == 3`, `(-7) / 2` rounds toward
zero. Remainder: `7 % 2 == 1`.

**Ranges in `for` are half-open**: `for i in 0..10` iterates `0, 1, …, 9`
(exactly like Python's `range(10)` or Rust's `0..10`). The inclusive form
`for i in 0..=10` visits `10` too. The `in` keyword is optional
(`for i 0..10` also parses).

**Loops**: `while cond { ... }`, `for i in a..b { ... }`, and
`loop { ... }` (an infinite loop — sugar for `while true`). Use `break`
to exit a loop early and `continue` to skip to the next iteration
(`continue` works in every loop form, including `for`).

**Literals**: decimal `42`, hex `0x2A`, character `'A'` / `'\n'` / `'\t'`
/ `'\\'` / `'\''` / `'\0'` (evaluate to their byte value; use them
directly in comparisons: `if c == 'a' { ... }`).

**Printing**:

```kr
println("hello")           // string literal
println(42)                // integer (decimal)
println(x)                 // variable (decimal)
println(3.14)              // f64 (6-digit fraction)
println(true)              // bool → "true" / "false"
println('A')               // char → one byte
print("no newline")        // same family, no trailing \n

// Variadic println (v2.8.3) — space-separated args, typed correctly:
println("x =", x, "y =", y)       // prints "x = 42 y = 100"
print("loading ", percent, "%\n")

// f-strings (v2.8.3) — `{expr}` interpolates, `{{` / `}}` escape braces:
println(f"pi ≈ {3.14159}, answer = {answer}")

// For a string that lives in a variable (e.g. a heap-allocated
// buffer or the result of fmt_hex/fmt_dec), use print_str / println_str:
import "std/fmt.kr"
u64 s = fmt_dec(x)
print_str("x = ")
println_str(s)
```

**`fn main()` is always required**, even with `--freestanding`. Exit the
program with `exit(code)`; every example in this guide ends with `exit(0)`.

---

## Language basics

```kr
// Comments — line and /* block */

// Variables: type precedes the name
u64 x = 42
u32 count = 0
u8  byte  = 0xFF

// Short type aliases: u8/u16/u32/u64, i8/i16/i32/i64, byte, addr
// (The long forms uint8..int64 also work.)

// Control flow
if x > 10 {
    println("big")
} else {
    println("small")
}

while count < 10 {
    count = count + 1
}

for i in 0..10 {
    println(i)
}

match opcode {
    1 => { println("one") }
    2 => { println("two") }
}

// Functions — recursion works
fn fib(u64 n) -> u64 {
    if n <= 1 { return n }
    return fib(n - 1) + fib(n - 2)
}

// Structs with methods
struct Point {
    u64 x
    u64 y
}

fn Point.sum(Point self) -> u64 {
    return self.x + self.y
}

// Enums
enum Color {
    Red = 0
    Green = 1
    Blue = 2
}
```

### Printing output

```kr
println("a literal string")   // works
println(42)                   // formats as decimal
println(variable)             // formats as decimal

// Printing the contents of a string pointer variable:
u64 s = int_to_str(42)
print_str("answer is ")
println_str(s)                 // prints "answer is 42"
```

Rule of thumb: `print` / `println` with a string **literal** or with an
**integer** does what you expect. If you want to print the contents of a
string that lives in a variable (e.g. the result of `int_to_str`), use
`print_str` / `println_str`.

### Pointers made easy

KernRift has no dedicated pointer type — addresses are just `u64` values.
Use the built-in load/store functions:

```kr
u64 buf = alloc(32)

store64(buf + 0, 0x1122334455667788)
store32(buf + 8, 0xAABBCCDD)
store16(buf + 12, 0x1234)
store8(buf + 14, 0xAA)

u64 v  = load64(buf)
u32 w  = load32(buf + 8)
u16 h  = load16(buf + 12)
u8  b  = load8(buf + 14)
```

For MMIO, use the volatile variants: `vload8/16/32/64` and
`vstore8/16/32/64`. These emit the same load/store instructions but add a
memory barrier (`mfence` on x86_64, `DSB SY` on ARM64).

### Arrays

```kr
// Local byte buffer
u8[256] buf
buf[0] = 0xAA
u64 b = buf[0]

// Static array at module level
static u8[4096] page

fn main() {
    page[0] = 72
    page[1] = 0
    print_str(page)
    exit(0)
}
```

Fixed arrays of structs work the same way:

```kr
struct Point { u64 x; u64 y }

fn main() {
    Point[10] pts
    pts[0].x = 1
    pts[0].y = 2
    println(pts[0].x)
    exit(0)
}
```

### Slice parameters

For functions that take a buffer, use the slice syntax. Inside the
function, `data.len` reads the length and `data` is a plain pointer:

```kr
fn sum_bytes([u8] data) -> u64 {
    u64 total = 0
    u64 i = 0
    u64 n = data.len
    while i < n {
        total = total + load8(data + i)
        i = i + 1
    }
    return total
}

fn main() {
    u8[6] buf
    buf[0] = 10
    buf[1] = 20
    buf[2] = 30
    // Callers pass (pointer, length) — two arguments
    u64 t = sum_bytes(buf, 3)
    println(t)
    exit(0)
}
```

### Imports

```kr
import "std/io.kr"
import "std/string.kr"
import "utils.kr"
```

Paths are resolved relative to the importing file, then under
`~/.local/share/kernrift/`. Circular imports are detected.

### Language profiles

A file can pin its required language profile on the first line:

```kr
#lang stable

fn main() { exit(0) }
```

Two profiles exist today: `stable` (default — production-safe features
only) and `experimental` (also enables features under active
development). Pinning a file to `stable` means new experimental syntax
won't sneak in behind your back, even as the language evolves. See the
[Living Compiler doc](LIVING_COMPILER.md) for the blueprint.

## Toolchain

| Tool | What it does |
|------|--------------|
| `krc <file.kr>` | Compile a source file (to a fat binary by default). |
| `krc --arch=x86_64 <file.kr>` | Compile for a single architecture — native ELF. |
| `krc --arch=riscv32 <file.kr>` | Compile for 32-bit RISC-V (hosted Linux ELF32). |
| `krc --arch=riscv32 --freestanding <file.kr>` | Bare-metal RV32IMC flat blob, entry at offset 0. |
| `krc --arch=xtensa --freestanding <file.kr>` | Bare-metal Xtensa LX6 blob (xtensa is freestanding-only). |
| `krc --arch=xtensa --freestanding --target=esp32 <file.kr>` | Bootable ESP32 flash image (write to flash `0x1000`). |
| `krc --emit=lkm <file.kr>` | Loadable Linux kernel module (`.ko`). |
| `krc --emit=asm <file.kr>` | Emit a disassembled listing with function labels. |
| `krc check <file.kr>` | Run semantic analysis only. |
| `krc fmt <file.kr>` | Auto-format the file in place. |
| `krc lc <file.kr>` | Living compiler report: fitness score, pattern detection, proposal triggers. |
| `krc lc --fix <file.kr>` | Apply auto-fixes in place (e.g. `unsafe{}` pointer ops → `load/store` builtins). |
| `krc lc --fix --dry-run <file.kr>` | Preview auto-fixes without writing. |
| `krc lc --list-proposals` | Print the proposal registry with lifecycle states. |
| `kr <file.krbo>` | Run a fat binary on the current platform. |

## Platforms

| Platform      | Compile | Run     | Self-host |
|---------------|---------|---------|-----------|
| Linux x86_64  | Yes     | Yes     | Yes       |
| Linux ARM64   | Yes     | Yes     | Yes       |
| Windows x86_64| Yes     | Yes     | Yes       |
| Windows ARM64 | Yes     | Yes     | Yes       |
| Android ARM64 | Yes     | Yes     | Yes       |
| Android x86_64| Yes     | Yes     | —         |
| macOS x86_64  | Yes     | Yes     | Yes       |
| macOS ARM64   | Yes     | Partial | —         |

### Embedded targets

These run the same compiler front end but a reduced language — **no floats, no
64-bit integers**, and no structs or `alloc()` when freestanding. The full
matrix and the freestanding `fn main() -> uint32` model are in the
[README](../README.md#embedded-targets-riscv32--xtensa--esp32).

| Target | Mode | Output |
|--------|------|--------|
| riscv32 (RV32IMC) | hosted | Linux ELF32 executable |
| riscv32 (RV32IMC) | `--freestanding` | flat blob, entry at offset 0 |
| Xtensa LX6 | `--freestanding` only | flat blob |
| ESP32 | `--target=esp32` | esp-image, flashed at `0x1000` |

```sh
# Build and run a hosted riscv32 program under qemu
krc --arch=riscv32 examples/riscv-hosted/hello.kr -o hello-rv32
qemu-riscv32-static ./hello-rv32          # prints "hello riscv"

# Build the ESP32 image that was validated on real silicon
krc --arch=xtensa --freestanding --target=esp32 examples/esp32/hello.kr -o hello.bin
```

## Standard library

KernRift ships with a standard library in `std/`. Import any module with
`import "std/module.kr"`. Highlights:

```kr
import "std/string.kr"
import "std/io.kr"
import "std/math.kr"
import "std/vec.kr"

fn main() {
    // String operations
    u64 s = int_to_str(42)
    print_str(s)
    println("")

    // Dynamic array
    u64 v = vec_new()
    vec_push(v, 10)
    vec_push(v, 20)
    vec_push(v, 30)
    println(vec_get(v, 1))  // 20

    // Math
    println(max(10, 20))     // 20
    println(gcd(48, 18))     // 6

    // Read a number from stdin
    print("Enter a number: ")
    u64 n = scan_int()
    println(n)

    exit(0)
}
```

Available modules:

| Module | Highlights |
|--------|-----------|
| `std/string.kr` | `str_cat(a,b)`, `str_copy(s)`, `str_sub(s,start,len)`, `str_to_int(s)`, `int_to_str(v)`, `str_trim(s)` — all return newly allocated strings |
| `std/io.kr` | `read_file`, `write_file`, `read_line`, `scan_int`, `scan_str`, `print_kv`, `print_indent` |
| `std/math.kr` | `min`, `max`, `abs`, `clamp`, `pow`, `sqrt_int`, `gcd`, `is_prime` |
| `std/fmt.kr` | `fmt_hex`, `fmt_bin`, `pad_left`, `pad_right` |
| `std/mem.kr` | `realloc`, `memcmp`, `memzero`, `arena_init`, `arena_alloc`, `arena_reset` |
| `std/vec.kr` | `vec_new`, `vec_push`, `vec_get`, `vec_set`, `vec_pop`, `vec_len` |
| `std/map.kr` | `map_new`, `map_set`, `map_get`, `map_has`, `map_len` |
| `std/time.kr` | `time_now`, `time_sleep_ns`, `time_sleep_ms`, `time_elapsed` |
| `std/log.kr` | `log_set_level`, `log_debug`, `log_info`, `log_warn`, `log_error` |
| `std/net.kr` | `net_socket`, `net_bind`, `net_listen`, `net_accept`, `net_connect`, `net_send`, `net_recv` |
| `std/fb.kr` | Framebuffer: `fb_init(addr,w,h,stride,bpp)`, `fb_pixel`, `fb_rect`, `fb_line`, `fb_blit` |
| `std/font.kr` | 8x16 bitmap font: `font_init`, `fb_char`, `fb_text` |
| `std/widget.kr` | UI widgets: `panel_new`, `label_new`, `button_new`, `progress_new`, `textfield_new` |
| `std/color.kr` | `rgb`, `rgba`, `color_r/g/b/a`, `alpha_blend`, `color_lerp`, `color_darken`, `color_lighten` |
| `std/fixedpoint.kr` | 16.16 fixed-point math: `fp_from_int`, `fp_mul`, `fp_div`, `fp_sqrt`, `fp_lerp` |

## Examples

Every runnable example lives in the top-level [`examples/`](../examples/)
directory. Start with:

- **`hello.kr`** — smallest possible program
- **`fib.kr`** — recursive Fibonacci
- **`fizzbuzz.kr`** — control flow
- **`count_chars.kr`** — byte-level string iteration
- **`linked_list.kr`** — heap-allocated structs (canonical data-structures pattern)
- **`pointers.kr`** — pointer builtins
- **`slices.kr`** — slice parameters
- **`struct_arrays.kr`** — fixed arrays of structs
- **`mmio_driver.kr`** — device blocks (embedded-style MMIO)
- **`echo.kr`** — stdin / stdout
- **`extern_libc.kr`** — linking against libc via `extern fn`

## Editor setup

### VS Code

Install the **KernRift** extension from the VS Code Marketplace. It
provides:

- Syntax highlighting
- LSP diagnostics (via `krc check`)
- Completions, hover docs, and go-to-definition

The extension activates automatically for `.kr` files.

## Next steps

- Read the [Language Reference](LANGUAGE.md) for the full syntax and all
  built-ins.
- Browse [`examples/`](../examples/) for runnable code.
- See [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) for compiler internals.
