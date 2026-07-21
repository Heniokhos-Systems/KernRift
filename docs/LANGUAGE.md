# KernRift Language Reference

**KernRift** is a bare-metal systems programming language and compiler created
by Pantelis Christou. It compiles itself. It runs on Linux, Windows, macOS,
and Android across x86_64 and ARM64 without any C toolchain, runtime, or libc.

This document describes what the language actually is. Every feature listed
here is implemented in the compiler you just installed — if you hit
something that doesn't work, it's a bug, not a typo in the docs.

---

## Table of Contents

1. [File structure and comments](#1-file-structure-and-comments)
2. [Types](#2-types)
3. [Variables and assignment](#3-variables-and-assignment)
4. [Operators](#4-operators)
5. [Control flow](#5-control-flow)
6. [Functions](#6-functions)
7. [Structs, methods, and enums](#7-structs-methods-and-enums)
8. [Arrays](#8-arrays)
9. [Slice parameters](#9-slice-parameters)
10. [Static variables and constants](#10-static-variables-and-constants)
11. [Pointer operations](#11-pointer-operations)
12. [Volatile and atomic](#12-volatile-and-atomic)
13. [Device blocks (MMIO)](#13-device-blocks-mmio)
14. [Inline assembly](#14-inline-assembly)
15. [Floating-point types](#15-floating-point-types)
16. [Allocators and memory management](#16-allocators-and-memory-management)
17. [Imports](#17-imports)
18. [Built-in functions](#18-built-in-functions)
19. [Annotations](#19-annotations)
20. [Compiler CLI](#20-compiler-cli)
21. [Living compiler](#21-living-compiler)
22. [Language profiles (#lang)](#22-language-profiles-lang)
23. [Freestanding mode](#23-freestanding-mode)
24. [Extern functions](#24-extern-functions)
25. [Binary formats](#25-binary-formats)

---

## 1. File structure and comments

KernRift source files use the `.kr` extension. One file is one module. A
program starts execution at `fn main()` (unless you pass `--freestanding`).

```kr
// Line comment

/* Block comment.
   Can span multiple lines. */

fn main() {
    println("Hello, KernRift!")
    exit(0)
}
```

Statements do not require trailing semicolons. Semicolons are accepted and
ignored — useful when you want to write multiple statements on one line.

---

## 2. Types

### Scalar types

| Type      | Width | Alias | Notes                         |
|-----------|-------|-------|-------------------------------|
| `uint8`   | 1 B   | `u8`, `byte` | Unsigned byte          |
| `uint16`  | 2 B   | `u16` | Unsigned 16-bit               |
| `uint32`  | 4 B   | `u32` | Unsigned 32-bit               |
| `uint64`  | 8 B   | `u64`, `addr` | Unsigned 64-bit, pointer-sized |
| `int8`    | 1 B   | `i8`  | Signed byte                   |
| `int16`   | 2 B   | `i16` | Signed 16-bit                 |
| `int32`   | 4 B   | `i32` | Signed 32-bit                 |
| `int64`   | 8 B   | `i64` | Signed 64-bit                 |
| `f16`     | 2 B   |              | IEEE 754 half-precision (storage only on ARM64) |
| `f32`     | 4 B   | `float`      | IEEE 754 single-precision — full arithmetic, literals `1.5f` |
| `f64`     | 8 B   | `double`     | IEEE 754 double-precision — full arithmetic, default for float literals (`1.5`, `2e10`, `3.14`) |
| `bool`    | 1 B   |       | `true` / `false` (strict, since v2.8.3) |
| `char`    | 1 B   |       | Single byte holding a character literal (`'A'`, `'\n'`, …); strict since v2.8.3 |

All integer values are stored as 64-bit words in variable slots. The specific
width matters for pointer load/store and for struct field layout. The short
aliases (`u8`, `u64`, `i32`, …) are exact synonyms for the long form.
Floating-point types keep their declared width (f32 in 32-bit slots, f64 in
64-bit slots) and are tracked through the IR with a per-vreg "fkind" tag so
the emitter picks the right load/store/convert instructions.

Full floating-point details (operators, conversions, the `std/math_float.kr`
library) live in §15.

### `bool` (strict since v2.8.3)

```kr
bool ok = true            // ok
bool done = false         // ok
bool b = 1                // compile error — int literal not assignable to bool
```

Inside `if`/`while`, the compiler still accepts any integer (`0` false,
non-zero true), so `if str_eq(a, b) { ... }` works even though `str_eq`
returns `u64`. The type strictness only bites on variable declarations and
struct fields — it stops `uint64 flag = true` being silently coerced.

### `char` (strict since v2.8.3)

```kr
char c = 'A'               // stored as byte 65
char nl = '\n'             // stored as byte 10
if c == 'A' { ... }        // mixing char with its int value works
char bad = 97              // compile error — int literal not assignable
```

### Literals

- Decimal: `42`, `1000000`
- Hex: `0x1000`, `0xDEADBEEF`
- Float: `1.5`, `-3.14`, `2e10`, `1.5f` (f32 suffix)
- Bool: `true`, `false` (strict `bool` type)
- String: `"hello"` with `\n`, `\t`, `\\`, `\"`, `\0` escapes
- Character: `'A'`, `'\n'`, `'\t'`, `'\r'`, `'\0'`, `'\\'`, `'\''` — evaluates
  to the byte value of the character (e.g. `'A'` is 65, `'\n'` is 10).
  Use them directly in comparisons and arithmetic: `if c == 'a' { ... }`.
- f-string: `f"pi = {3.14}, answer = {x}"` — `{expr}` interpolates with type-directed
  formatting (integers, floats, bools, chars, `@string` slots), `{{`/`}}` escape.

---

## 3. Variables and assignment

```kr
TYPE name = initializer
TYPE name                    // uninitialized — garbage contents
name = new_value
```

The type precedes the name (C-style, not Rust-style).

```kr
u32 status = 0
u64 base   = 0x3F000000
u8  byte   = 0xFF
```

### `let` (type inference)

`let name = expr` declares a local whose type is inferred from the
initializer, so you don't repeat the type:

```kr
let count = 0              // u64
let total = a + b          // type of a
let ok    = x < limit      // bool
let value = lookup(key)    // the function's return type
let pi    = 3.14159        // f64
```

An initializer is required — there is nothing to infer from otherwise, so
`let x` is a compile error. Inference covers integer/float/bool literals,
identifiers, calls, arithmetic, comparisons, ternaries and match
expressions. For a struct value, declare it with an explicit type (`Point p
= ...`) rather than `let` for now. `let` is a local-only convenience;
parameters, fields and statics still spell out their types.

### Compound assignment

| Op | Meaning        |
|----|----------------|
| `+=` | add            |
| `-=` | subtract       |
| `*=` | multiply       |
| `/=` | divide         |
| `%=` | remainder      |
| `&=` | bitwise AND    |
| `\|=` | bitwise OR     |
| `^=` | bitwise XOR    |
| `<<=` | left shift     |
| `>>=` | right shift    |

---

## 4. Operators

Expressions are parsed with a Pratt parser. Precedence from tightest to
loosest (matching `binop_precedence` in `src/parser.kr` and the table in
`docs/GRAMMAR.md`):

| Precedence | Operators                        | Notes                    |
|------------|----------------------------------|--------------------------|
| (prefix)   | `!`, `~`, `-`                    | Logical not, bitwise not, negation |
| 8          | `&`, `\|`, `^`                   | Bitwise AND / OR / XOR   |
| 7          | `<<`, `>>`                       | Shift                    |
| 6          | `*`, `/`, `%`                    | Multiply, divide, remainder |
| 5          | `+`, `-`                         | Add, subtract            |
| 4          | `<`, `<=`, `>`, `>=`             | Comparison (signedness follows operand types) |
| 3          | `==`, `!=`                       | Equality                 |
| 2          | `&&`                             | Logical AND              |
| 1          | `\|\|`                           | Logical OR               |
| 0          | `?:`                             | Ternary (right-assoc, see §5) |

> **This differs from C.** Bitwise operators and shifts bind *tighter*
> than arithmetic and comparisons: `1 << 2 * 3` is `(1 << 2) * 3` = 12,
> `6 & 1 == 0` is `(6 & 1) == 0` (true), and `2 + 3 & 4` is `2 + (3 & 4)`
> = 2. Parenthesize when porting C code.

`<`, `<=`, `>`, `>=` are **type-directed**: when either operand has a
signed type (`i8`..`i64`) the comparison is signed; otherwise it is
unsigned. The `signed_lt` / `signed_gt` / `signed_le` / `signed_ge`
built-ins force a signed comparison regardless of operand types (useful
on raw `u64` bit patterns).

---

## 5. Control flow

### if / else

```kr
if x > 10 {
    println("big")
} else {
    println("small")
}
```

Parentheses around the condition are optional. `else if` works as a chain:

```kr
if n < 0 {
    println("negative")
} else if n == 0 {
    println("zero")
} else if n < 10 {
    println("small")
} else {
    println("big")
}
```

### ternary (`? :`)

`cond ? then_value : else_value` is an expression that picks one of two
values. It has the lowest precedence (below `||`) and is right-associative,
so it nests cleanly in either arm:

```kr
let max = a > b ? a : b
let sign = n < 0 ? 0 - 1 : n > 0 ? 1 : 0
exit(ok ? 0 : 1)
```

Only the chosen arm is evaluated — the other is short-circuited, so calls in
the unused arm don't run.

### while

```kr
u64 i = 0
while i < 10 {
    println(i)
    i = i + 1
}
```

### for (range)

```kr
for i in 0..n {
    println(i)
}
```

`0..n` is an **exclusive** range — `i` takes values `0, 1, ..., n-1`. The
inclusive form `0..=n` visits `n` as well. The `in` keyword is optional:
`for i 0..10` also parses.

### break and continue

```kr
while true {
    if done { break }
    if skip { continue }
    // ...
}
```

### loop

`loop { ... }` is an infinite loop — sugar for `while true`. Exit with
`break` or `return`:

```kr
u64 n = 0
loop {
    n = n + 1
    if n == 3 { break }
}
```

### defer

`defer { ... }` schedules a block to run at every function exit — each
`return` (including tuple returns) and the implicit fall-through — in
LIFO order when there are several. `exit(n)` bypasses defers. Requires
the IR backend (the default); `--legacy` rejects it.

```kr
fn demo() {
    defer { println_str("done") }   // runs at every exit point
    println_str("working")          // prints "working" then "done"
}
```

### match

```kr
match opcode {
    1 => { println("one") }
    2 => { println("two") }
    3 => { println("three") }
    _ => { println("other") }      // default arm: matches anything
}
```

Arms are tested top-to-bottom. A pattern is an integer literal, a named
integer constant, a comma-separated list (`1, 2, 3 => ...`), a range
(`0..=31 => ...`, IR backend only), or `_` for a catch-all default arm. If
no arm matches and there is no `_`, the match is a no-op.

An arm body can be a brace block or a single bare statement — the braces are
optional for one statement:

```kr
match code {
    0 => return ok()
    1 => exit(1)
    _ => log("unknown")
}
```

**`match` as an expression.** When used in value position, each arm is a
single expression and the whole `match` yields the matching arm's value (or
`0` if nothing matches and there is no `_`):

```kr
let name = match day {
    0 => "Sun"
    6 => "Sat"
    _ => "weekday"
}
exit(match status { 0 => 0  _ => 1 })
```

### return

```kr
fn get_value() -> u64 {
    return 42
}

fn do_thing() {
    return    // void return — also fine to just fall off the end
}
```

---

## 6. Functions

```kr
fn name(TYPE param1, TYPE param2) -> RETURN_TYPE {
    // body
    return value
}
```

The return type after `->` is optional; omitting it means the function
returns void. Parameters are `TYPE name` — type first.

```kr
fn add(u64 a, u64 b) -> u64 {
    return a + b
}

fn greet(u64 name) {
    print("Hello, ")
    print_str(name)
    println("!")
}
```

Recursion and mutual recursion work — function order within a file doesn't
matter.

### Calling functions

```kr
u64 r = add(2, 3)
greet("world")
```

Up to 6 arguments are passed in registers on x86_64 (`rdi rsi rdx rcx r8
r9`, on every OS) and up to 8 on arm64 (`x0..x7`). Functions with more
arguments pass the overflow on the stack.

### Type parameters (generics)

A function may declare type parameters with `<T>` or `<T, U>`:

```kr
fn max_t<T>(T a, T b) -> T {
    if a > b { return a }
    return b
}

fn main() {
    exit(max_t(3, 42))   // 42
}
```

Type parameters are **syntactic only** in the current implementation:
every scalar is a 64-bit slot, so `T` is effectively `u64` at codegen
time. There is no monomorphization and no type checking across
instantiations — `max_t(3, 42)` and `max_t(struct_ptr_a, struct_ptr_b)`
compile to the same machine code. Use the syntax when it makes the
caller clearer; don't rely on it for type safety.

### Tuple return and destructure (2 or 3 elements)

A function can return two or three values and the caller can destructure
them in one statement — `return (a, b)` / `return (a, b, c)` paired with
`(u64 x, u64 y) = call()` / `(u64 x, u64 y, u64 z) = call()`. Tuples are
limited to exactly two or three elements — four or more requires a struct
(or an out-pointer parameter).

```kr
fn divmod(u64 x, u64 y) -> u64 {
    return (x / y, x % y)
}

fn main() {
    (u64 q, u64 r) = divmod(17, 5)
    println(q)    // 3
    println(r)    // 2
    exit(0)
}
```

Runtime convention:
- **x86_64** — first value in `rax`, second in `rdx`, third in `r8`.
  All three are caller-saved on the SysV ABI, so the extra values flow
  through the epilogue untouched.
- **arm64** — first in `x0`, second in `x1`, third in `x2`. Same
  AAPCS64 reasoning.

The function's declared return type stays scalar (`-> u64` above) —
the tuple shape lives entirely in the `return (a, b)` expression and
the `(T1 a, T2 b) = call(…)` destructure. If you `return (a, b)` from
a function but only call it as a scalar expression, you get the first
value and the second is silently discarded. Calling a scalar-returning
function as a destructure picks up whatever the callee happened to
leave in `rdx` / `x1` (likely garbage). There is no arity check yet —
match the two sides yourself.

Destructuring is only recognised at statement position, and both
element types must be type keywords (`u8`..`u64`, `i8`..`i64`). You
can't destructure a struct field or an element of a literal tuple;
the RHS must be an expression whose tail evaluates into the two
return registers — in practice, a call to a tuple-returning function.

---

## 7. Structs, methods, and enums

### Structs

```kr
struct Point {
    u64 x
    u64 y
}
```

Field layout is packed — no alignment padding. Fields are stored in
declaration order at increasing offsets. Field sizes are determined by
their type (`u8` = 1 byte, `u32` = 4 bytes, `u64` = 8 bytes, etc.).

```kr
Point p            // stack-allocated struct value
p.x = 10
p.y = 20
println(p.x)
```

### Heap-allocated structs

A struct variable can also be initialized with an expression that
returns a pointer — typically `alloc(size)`. When written this way,
the variable holds the pointer and field access dereferences it:

```kr
struct Node {
    u64 value
    u64 next
}

fn main() {
    Node a = alloc(16)        // a holds the heap pointer
    Node b = alloc(16)
    a.value = 10
    a.next  = b               // field store on a pointer-backed struct
    b.value = 20
    b.next  = 0

    Node cur = a
    while cur != 0 {
        println(cur.value)
        cur = cur.next        // reassign pointer variable
    }
    exit(0)
}
```

This is the idiomatic form for linked lists, BSTs, graph nodes, and
any tree-shaped data. Field size is inferred from the struct
declaration just like stack structs; the only difference is that the
variable's slot holds a pointer to heap memory instead of stack
memory. Reassigning the pointer variable is allowed, so traversal
patterns like `cur = cur.next` work as expected.

### Methods

Attach a function to a struct with `fn StructName.method_name(StructName self, ...)`:

```kr
struct Point {
    u64 x
    u64 y
}

fn Point.sum(Point self) -> u64 {
    return self.x + self.y
}

fn main() {
    Point p
    p.x = 10
    p.y = 20
    u64 total = p.sum()   // 30
    println(total)
    exit(0)
}
```

The method receives `self` as a reference to the struct on the caller's
stack — `self.field` reads and writes work normally, and writes through
`self` are visible to the caller after the method returns. This also
holds when the receiver is a nested struct field (`w.p.set(…)`) or a
struct array element (`arr[i].set(…)`).

### Struct parameters are passed by value

A *plain* struct parameter (any parameter other than a method's `self`)
receives a **copy** of the argument — C-style value semantics:

```kr
fn poke(Point p) {
    p.x = 99          // writes the callee's local copy
}

fn main() {
    Point a
    a.x = 1
    poke(a)
    println(a.x)      // 1 — the caller's struct is unchanged
    exit(0)
}
```

Writes to the parameter work normally *inside* the callee, but are
never visible to the caller. This holds uniformly for every argument
form — a struct variable, a nested struct field (`o.inner`), a struct
array element (`arr[i]`), and heap-backed struct variables (the
*contents* are copied, so the callee cannot mutate the heap object
through a plain parameter either).

To let a function mutate a struct, make it a method — `self` is the
language's by-reference struct parameter.

### Enums

```kr
enum Color {
    Red = 0
    Green = 1
    Blue = 2
}
```

`Color.Red`, `Color.Green`, `Color.Blue` are named integer constants usable
in any integer context (assignments, comparisons, match arms, switch bases,
etc.). Enums are a compile-time convenience; no runtime object is created.

> **Reminder**: `<`, `<=`, `>`, `>=` follow the operand types (see §4):
> signed when an operand is `i8`..`i64`, unsigned otherwise. Values that
> can go negative — an AVL balance factor, a graph distance — should be
> declared with a signed type (`i64`), or compared with the
> `signed_lt`/`signed_le`/`signed_gt`/`signed_ge` builtins when they
> live in unsigned slots. This trips people up in tree and heap code
> surprisingly often.

---

## 8. Arrays

### Local arrays

```kr
u8[256]  buffer         // byte buffer
u16[16]  samples        // 16 × 2-byte values
u32[10]  pixels         // 10 × 4-byte values
u64[10]  numbers        // 10 × 8-byte values

buffer[0]  = 0xAA
numbers[2] = 300
u64 first  = numbers[0]
```

Local arrays are allocated on the stack. The element size follows the
declared type — `u64[10]` reserves 80 bytes, `u32[10]` reserves 40, etc.
Indexing is scaled automatically (`numbers[2]` loads 8 bytes from offset
`2*8`). The variable holds a pointer to the first element, so `buffer`
alone evaluates to the base address. Indexing is unchecked.

### Static arrays

At module level, a static array gets storage in the data section:

```kr
static u8[1024]  message_buf      // 1024 bytes
static u16[16]   sensor_samples   // 32 bytes
static u32[10]   pixel_row        // 40 bytes
static u64[10]   counters         // 80 bytes

fn main() {
    message_buf[0] = 72   // 'H'
    message_buf[1] = 105  // 'i'
    message_buf[2] = 0
    counters[0] = 1000000
    counters[9] = 2000000
    print_str(message_buf)
    exit(0)
}
```

All integer element widths (`u8`/`u16`/`u32`/`u64`, `i8`/`i16`/`i32`/`i64`)
are supported and indexing is scaled automatically — `counters[5]` reads
8 bytes from offset `5*8`. (In compilers older than 2.6.3, wider element
types silently miscompiled; upgrade if you see garbage reads.)

Static arrays are zero-initialized by the loader.

### Struct arrays

Fixed-size arrays of struct instances work both locally and statically:

```kr
struct Point { u64 x; u64 y }

fn main() {
    Point[10] pts
    pts[0].x = 1
    pts[0].y = 2
    pts[5].x = 50
    println(pts[5].x)
    exit(0)
}
```

Element indexing uses the struct's full size as stride. `pts[i].field` is
a first-class syntax that reads and writes the `field` at the correct
offset within element `i`.

---

## 9. Slice parameters

A slice parameter `[TYPE] name` is sugar for a fat pointer: a `(ptr, len)`
pair passed as two separate arguments. Inside the function, `data.len`
reads the length, and `data` is a plain pointer for indexing.

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
    // Caller passes (pointer, length) — two arguments
    u64 t = sum_bytes(buf, 3)
    println(t)
    exit(0)
}
```

The caller side explicitly passes the length as a normal second argument.
This is the classic C `(ptr, len)` pattern with a nicer symbolic name for
the length inside the callee.

---

## 10. Static variables and constants

### static

```kr
static u64 counter = 0
static u64 gpio_base = 0x3F200000

fn tick() {
    counter = counter + 1
}
```

Static variables live in the data section for the lifetime of the program.
A literal initializer — `= 42`, `= 0x3F200000`, `= 'A'`, `= true`, with an
optional leading `-` or `~` — is honoured and emitted into the binary.
Without an initializer the slot is zero (BSS). Non-literal initializers
(calls, named constants, arithmetic such as `= 5 + 3`) are **not**
evaluated: only a leading literal, if any, is kept and the rest is
silently dropped (`= 5 + 3` stores 5; tracked as issue #53). Set those
values at startup instead.

### const

```kr
const u64 BAUD = 115200
const u64 UART_BASE = 0x3F201000
```

`const` creates a compile-time integer constant. At use sites the value is
inlined — there is no runtime storage.

---

## 11. Pointer operations

KernRift has no dedicated pointer type. Addresses are just `u64` values. To
read or write memory at an address, use the pointer built-ins:

### The easy way

```kr
u64 v = load64(addr)          // read a 64-bit value
u32 x = load32(addr)          // read a 32-bit value
u16 h = load16(addr)          // read a 16-bit value
u8  b = load8(addr)           // read a single byte

store64(addr, 0xDEADBEEF)     // write 64 bits
store32(addr, 0x1234)         // write 32 bits
store16(addr, 0x5678)         // write 16 bits
store8(addr, 0xAA)            // write 1 byte
```

The load builtins zero-extend the read into a full `u64`. The store
builtins write exactly the specified width.

### The verbose way (unsafe blocks)

You can also write the raw pointer syntax:

```kr
u64 val = 0
unsafe { *(addr as u32) -> val }     // load
unsafe { *(addr as u8)  = some_byte } // store
```

The cast type determines access width. Supported cast types:
`u8`, `u16`, `u32`, `u64`, `i8`, `i16`, `i32`, `i64` (plus the long
forms `uint8`..`int64`, and `f16`/`f32`/`f64` for float-typed access).
`unsafe { ... }` is just a marker block — it accepts exactly **one**
pointer statement (one load or one store). Use a separate `unsafe` block
for each additional access.

The `load*` / `store*` builtins are equivalent and much easier to read —
prefer them unless you have a reason to use `unsafe` blocks.

---

## 12. Volatile and atomic

### Volatile: MMIO-safe loads and stores

For memory-mapped I/O, the compiler must not reorder, elide, or cache the
access, and the memory operation must complete before anything after it.

```kr
u32 v = vload32(mmio_addr)     // volatile load, barrier after
vstore32(mmio_addr, 0x01)      // volatile store, barrier before
```

All widths are available:
`vload8`, `vload16`, `vload32`, `vload64`, `vstore8`..`vstore64`.

The barrier emitted is:
- **x86_64**: `mfence` (full memory fence)
- **ARM64**: `DSB SY` (data synchronization barrier — waits for completion,
  not just ordering)

`volatile { *(addr as u32) = val }` is the equivalent block form and does
the same thing.

### Atomic operations

Lock-free atomic primitives are available as builtins:

```kr
u64 v = atomic_load(addr)
atomic_store(addr, v)
u64 old = atomic_cas(addr, expected, desired)   // compare-and-swap
u64 old = atomic_add(addr, delta)               // returns old value
u64 old = atomic_sub(addr, delta)
u64 old = atomic_and(addr, mask)
u64 old = atomic_or(addr, mask)
u64 old = atomic_xor(addr, mask)
```

These compile to `LOCK`-prefixed instructions on x86_64 and `LDXR`/`STXR`
exclusive pairs on ARM64. `atomic_cas` returns `1` on success, `0` on
failure.

---

## 13. Device blocks (MMIO)

For driver code, a `device` block describes a hardware register set at a
fixed base address. Field reads and writes compile directly to volatile
loads and stores of the right width — with the proper memory barriers.

```kr
device UART0 at 0x3F201000 {
    Data   at 0x00 : u32
    Flag   at 0x18 : u32
    IBRD   at 0x24 : u32
    FBRD   at 0x28 : u32
    LCRH   at 0x2C : u32
    Ctrl   at 0x30 : u32 rw
}

fn putc(u8 c) {
    // Spin until TX FIFO has room
    while (UART0.Flag & 0x20) != 0 { }
    UART0.Data = c
}
```

Syntax:

- `device NAME at ADDR { ... }` declares a device rooted at `ADDR`.
- `FIELD at OFFSET : TYPE [rw|ro|wo]` declares a register. The access
  specifier (`rw`, `ro`, `wo`) is currently optional and parsed-but-ignored
  — future versions will enforce it.
- Supported field types: `u8`, `u16`, `u32`, `u64` (and signed variants).

A read like `UART0.Data` emits a `vloadN` of the right width at
`0x3F201000 + 0x00`. A write like `UART0.Ctrl = 1` emits a `vstoreN` with
the appropriate barrier.

Device blocks sit on top of the volatile builtins — there is no hidden
mechanism, just a convenient named-register syntax.

---

## 14. Inline assembly

The `asm` keyword emits raw machine instructions at the call site.

### Single instruction

```kr
asm("nop")
asm("cli")
asm("sti")
```

### Multi-instruction block

```kr
asm {
    "cli";
    "mov rax, cr0";
    "sti"
}
```

### Raw hex bytes

When the assembler doesn't recognize a mnemonic, drop to hex:

```kr
asm("0x0F 0x01 0xD9")    // vmmcall (x86_64)
asm("0xD503201F")        // nop (ARM64)
```

### Supported instructions

**x86_64**: `nop`, `ret`, `hlt`, `int3`, `iretq`, `cli`, `sti`, `cpuid`,
`rdmsr`, `wrmsr`, `lgdt [rax]`, `lidt [rax]`, `invlpg [rax]`, `ltr ax`,
`swapgs`, control-register moves (`mov cr0, rax`, etc.), port I/O
(`in al, dx`, `out dx, al`, wide variants).

**ARM64**: `nop`, `ret`, `eret`, `wfi`, `wfe`, `sev`, barriers (`isb`,
`dsb sy/ish`, `dmb sy/ish`), `svc #N`, and `mrs` / `msr` for 20+ system
registers including `SCTLR_EL1`, `VBAR_EL1`, `TCR_EL1`, `MAIR_EL1`,
`MPIDR_EL1`, `CurrentEL`.

For anything not in the built-in table, use the raw hex form.

### I/O constraints

Any `asm(...)` or `asm { ... }` may be followed by `in(...)`, `out(...)`,
and/or `clobbers(...)` clauses that describe how registers flow between
the block and KernRift's local variables.

```kr
import "std/fmt.kr"

fn rdtsc_ns() -> u64 {
    u64 lo = 0
    u64 hi = 0
    asm { "rdtsc" } out(rax -> lo, rdx -> hi)
    return (hi << 32) | lo
}

fn main() {
    println_str(fmt_dec(rdtsc_ns()))
    exit(0)
}
```

A `cpuid` helper with both inputs and outputs:

```kr
fn cpuid_signature() -> u64 {
    u64 leaf = 0
    u64 zero = 0
    u64 a = 0
    u64 b = 0
    u64 c = 0
    u64 d = 0
    asm { "cpuid" }
        in(leaf -> rax, zero -> rcx)
        out(rax -> a, rbx -> b, rcx -> c, rdx -> d)
    return (b << 32) | c
}
```

**Clause semantics**:
- `in(<var> -> <reg>, ...)` — before the block runs, KernRift emits a
  `mov <reg>, <local_slot>` for each pair. Inputs are load-only; the
  named variable is not updated after the block.
- `out(<reg> -> <var>, ...)` — after the block runs, KernRift emits a
  `mov <local_slot>, <reg>` for each pair. Outputs are store-only.
- `clobbers(<reg>, ...)` — accepted syntactically but currently
  **advisory**. You still must list every register your block writes
  under `out(...)` if you need its value, and every register whose
  prior contents you don't care about should not be relied on after
  the block. The compiler does not yet save/restore clobbered
  callee-saved registers.

**Register names**:
- **x86_64**: `rax` `rcx` `rdx` `rbx` `rsp` `rbp` `rsi` `rdi` `r8` …
  `r15`. No 32-bit or 8-bit aliases yet — use the 64-bit form even if
  the instruction operates on a sub-register.
- **ARM64**: `x0` … `x30`. No `w` (32-bit) aliases.

**Limitations** (V1):
- Clauses must come immediately after the closing `)` or `}` of the
  asm form, before any other statement.
- Clobbers list is parsed but emits no save/restore code — list an
  output or pick non-conflicting registers.
- Only integer GPRs are accepted; no SSE/NEON register constraints.
- No memory-operand constraints (Rust's `in("rax") [ptr]` — not yet).
- Pinned-parameter inputs (rbx/r12 on x86_64, picked by the compiler
  for parameter slots 0 and 1) are handled correctly — KernRift
  emits a reg-reg move instead of a stack reload so pinning stays
  transparent.

---

## 15. Floating-point types

KernRift supports IEEE 754 floating-point types: `f32` (single, 32-bit),
`f64` (double, 64-bit), and `f16` (half, 16-bit, storage-only — no
arithmetic, use `f16_to_f32` / `f32_to_f16` for conversion).

### Literals

```kr
f64 x = 3.14          // f64 (default)
f64 y = 0.001
f32 w = 3.14f         // f32 (suffix)
```

### Arithmetic

```kr
f64 a = int_to_f64(6)
f64 b = int_to_f64(7)
f64 c = a * b         // 42.0
f64 d = a + b - c / a
```

Operators `+`, `-`, `*`, `/` work on matching float types. Mixing
float and integer in one expression is a compile error — use the
explicit conversion builtins.

### Comparisons

```kr
if a < b { ... }
if a == b { ... }
```

All comparison operators (`<`, `>`, `<=`, `>=`, `==`, `!=`) work.
NaN follows IEEE 754: `NaN == NaN` is false. Test for NaN with
`x != x` (true only for NaN).

### Conversions (explicit, no implicit coercion)

| Builtin | Description |
|---|---|
| `int_to_f64(u64) -> f64` | Integer to double |
| `int_to_f32(u64) -> f32` | Integer to single |
| `f64_to_int(f64) -> u64` | Double to integer (truncates toward zero) |
| `f32_to_int(f32) -> u64` | Single to integer |
| `f32_to_f64(f32) -> f64` | Widen single to double |
| `f64_to_f32(f64) -> f32` | Narrow double to single |
| `f32_to_f16(f32) -> f16` | Single to half (storage) |
| `f16_to_f32(f16) -> f32` | Half to single |

### Math library (`std/math_float.kr`)

```kr
import "std/math_float.kr"

f64 r = sqrt(int_to_f64(49))   // 7.0 (hardware)
f64 s = sin(f64_pi())           // ~0.0
f64 e = exp(int_to_f64(1))     // ~2.718
println_str(fmt_f64(e, 6))     // "2.718281"
```

| Function | Description |
|---|---|
| `sqrt(f64) -> f64` | Square root (hardware) |
| `abs_f(f64) -> f64` | Absolute value |
| `neg_f(f64) -> f64` | Negation |
| `sin(f64) -> f64` | Sine |
| `cos(f64) -> f64` | Cosine |
| `tan(f64) -> f64` | Tangent |
| `exp(f64) -> f64` | Exponential (e^x) |
| `log(f64) -> f64` | Natural logarithm |
| `pow(f64, f64) -> f64` | Power (x^y) |
| `floor(f64) -> f64` | Floor |
| `ceil(f64) -> f64` | Ceiling |
| `fmt_f64(f64, u64) -> u64` | Format as decimal string |
| `fmt_f32(f32, u64) -> u64` | Format f32 as decimal string |

### Function ABI

Float arguments use the float register file independently from
integer arguments:

- **x86_64 SysV**: `xmm0`–`xmm7` for float args, return in `xmm0`
- **ARM64 AAPCS**: `d0`–`d7` for float args, return in `d0`

```kr
fn lerp(f64 a, f64 b, f64 t) -> f64 {
    return a + (b - a) * t
}
```

### Precision

| Type | Reliable decimal digits | Range |
|---|---|---|
| `f16` | ~3 | ±65504 |
| `f32` | ~7 | ±3.4 × 10³⁸ |
| `f64` | ~15 | ±1.8 × 10³⁰⁸ |

---

## 16. Allocators and memory management

```kr
import "std/alloc.kr"
```

KernRift ships three allocators in the standard library. All are backed
by `mmap`/`VirtualAlloc` with no libc dependency.

### Low-level: `alloc` / `dealloc`

`alloc(size)` maps a new region and stores an 8-byte size header before
the returned pointer. `dealloc(ptr)` reads that header and calls
`munmap` (Linux/macOS) or `VirtualFree` (Windows) to release the pages.
Previous releases left `dealloc` as a no-op; it now frees for real.

### Arena allocator

Bump-pointer allocator. Fast, no per-object free. Good for
request-scoped or phase-scoped work where you free everything at once.

```kr
u64 a = arena_new(65536)          // 64 KiB slab
u64 p1 = arena_alloc(a, 128)     // bump 128 bytes
u64 p2 = arena_alloc(a, 256)     // bump 256 bytes
arena_reset(a)                    // rewind to start (no munmap)
(u64 total, u64 live) = arena_stats(a)
arena_destroy(a)                  // munmap; warns if bytes still live
```

### Pool allocator

Fixed-size slot allocator with an embedded free list. Constant-time
alloc and free. Ideal for many same-sized objects (nodes, handles).

```kr
u64 pool = pool_new(64, 1024)     // 1024 slots of 64 bytes each
u64 obj = pool_alloc(pool)
pool_free(pool, obj)
(u64 capacity, u64 used) = pool_stats(pool)
pool_destroy(pool)                // warns if slots still in use
```

### Heap allocator

General-purpose variable-size allocator. First-fit with forward
coalescing on free. Use when allocation sizes vary.

```kr
u64 h = heap_new(1048576)         // 1 MiB slab
u64 buf = heap_alloc(h, 4096)
heap_free(h, buf)
(u64 total, u64 freed, u64 live) = heap_stats(h)
heap_destroy(h)                   // warns if blocks still allocated
```

### API summary

| Function | Returns | Description |
|---|---|---|
| `arena_new(capacity)` | arena handle | Create arena with `capacity` bytes |
| `arena_alloc(arena, size)` | pointer | Bump-allocate `size` bytes (8-byte aligned) |
| `arena_reset(arena)` | — | Rewind used offset to 0 |
| `arena_destroy(arena)` | — | Release slab; leak warning if bytes live |
| `arena_stats(arena)` | `(total, live)` | Cumulative allocated bytes, currently live bytes |
| `pool_new(obj_size, count)` | pool handle | Create pool of `count` fixed-size slots |
| `pool_alloc(pool)` | pointer | Pop a slot from the free list |
| `pool_free(pool, ptr)` | — | Return slot; poisons + sets canary |
| `pool_destroy(pool)` | — | Release slab; leak warning if slots in use |
| `pool_stats(pool)` | `(capacity, used)` | Total slots, currently used slots |
| `heap_new(capacity)` | heap handle | Create heap with `capacity` bytes |
| `heap_alloc(heap, size)` | pointer | First-fit allocate (8-byte aligned) |
| `heap_free(heap, ptr)` | — | Free + forward coalesce; poisons + canary |
| `heap_destroy(heap)` | — | Release slab; leak warning if blocks allocated |
| `heap_stats(heap)` | `(total, freed, live)` | Bytes allocated, bytes freed, bytes live |

### Safety features

All three allocators share the same hardening:

- **Guard pages** — A `PROT_NONE` page is mapped at the end of every
  slab. Buffer overruns hit an immediate `SIGSEGV` instead of silently
  corrupting adjacent memory.
- **Double-free detection** — Pool and heap write a `0xDEADBEEFDEADBEEF`
  canary into freed slots/blocks. A second free of the same pointer
  prints a diagnostic and calls `exit(1)`.
- **Use-after-free poison** — Freed memory is filled with `0xEF` bytes
  (pool) or the canary pattern (heap). Reads of freed data return
  obviously wrong values instead of stale data.
- **Leak warnings** — `arena_destroy`, `pool_destroy`, and
  `heap_destroy` walk their metadata and print to stderr if any
  allocations were not freed (or not reset, for arenas).

---

## 17. Imports

Bring functions and declarations from another file into the current
compilation unit:

```kr
import "std/io.kr"
import "std/string.kr"
import "utils.kr"
```

Import paths are resolved:

1. Relative to the importing file's directory
2. Then in the standard library location: `~/.local/share/kernrift/`
   (or `%LOCALAPPDATA%\KernRift\share\` on Windows)

Circular imports are detected and rejected. Each file is compiled at most
once regardless of how many files import it.

---

## 18. Built-in functions

All of these are compiler intrinsics — no runtime library, no imports
needed.

### I/O

| Function | Description |
|---|---|
| `print(a, b, ...)` | Typed, variadic (v2.8.3). Each arg is formatted according to its type: string literals emitted as-is, integers as decimal, floats via `fmt_f64`/`fmt_f32`, bools as `true`/`false`, chars as a single byte. Args are space-separated; no trailing newline. |
| `println(a, b, ...)` | Same, plus a newline. |
| `print_str(s)` | Print a null-terminated string from a pointer variable (for results of `int_to_str`, `fmt_hex`, etc.). |
| `println_str(s)` | Same, plus a newline. |
| `write(fd, buf, len)` | Write `len` bytes from `buf` to file descriptor `fd`. |
| `file_open(path, flags)` | Open a file. Returns a descriptor. |
| `file_read(fd, buf, len)` | Read up to `len` bytes. Returns bytes read. |
| `file_write(fd, buf, len)` | Write `len` bytes. Returns bytes written. |
| `file_close(fd)` | Close a descriptor. |
| `file_size(fd)` | Return the size of an open file. |

**f-strings** (v2.8.3): `f"x = {x}, pi ≈ {3.14}"` interpolates each
`{expr}` with the same type-directed formatter `print` uses. `{{` and
`}}` escape braces. The surrounding string segments are emitted
verbatim, so f-strings compose with variadic `println`:

```kr
println(f"result = {answer} ({percent}%)")
```

**When to prefer `*_str`:** `print(variable)` formats the variable as a
decimal integer (or float/bool/char, based on its static type). If your
variable holds a string *pointer* — e.g. the return of `int_to_str` or a
manually-built buffer — reach for `print_str` / `println_str`.

### Memory

| Function | Description |
|---|---|
| `alloc(size)` | Heap-allocate `size` bytes. Returns a pointer. |
| `dealloc(ptr)` | Free a previously allocated block. |
| `memcpy(dst, src, len)` | Copy `len` bytes. |
| `memset(dst, val, len)` | Fill `len` bytes with `val`. |
| `str_len(s)` | Length of a null-terminated string. |
| `str_eq(a, b)` | 1 if two null-terminated strings are equal, 0 otherwise. |
| `sizeof(T)` | Compile-time byte size of a scalar type or struct. `sizeof(u64)` is 8; `sizeof(SomeStruct)` is its packed size (fields are laid out with no padding — see §7). Folds to a constant at compile time. |

### Pointer load/store

| Function | Description |
|---|---|
| `load8/16/32/64(addr)` | Read a value of the given width, zero-extended to `u64`. |
| `store8/16/32/64(addr, val)` | Write a value of the given width. |
| `vload8/16/32/64(addr)` | Volatile load with barrier — for MMIO. |
| `vstore8/16/32/64(addr, val)` | Volatile store with barrier — for MMIO. |

### Atomic

| Function | Description |
|---|---|
| `atomic_load(ptr)` | Sequentially-consistent load. |
| `atomic_store(ptr, val)` | Sequentially-consistent store. |
| `atomic_cas(ptr, exp, new)` | Compare-and-swap. Returns 1 on success. |
| `atomic_add/sub/and/or/xor(ptr, val)` | RMW, returns old value. |

### Bit manipulation

| Function | Description |
|---|---|
| `bit_get(v, n)` | Bit `n` of `v` (0 or 1). |
| `bit_set(v, n)` | Return `v` with bit `n` set. |
| `bit_clear(v, n)` | Return `v` with bit `n` cleared. |
| `bit_range(v, start, width)` | Extract `width` bits starting at `start`. |
| `bit_insert(v, start, width, bits)` | Insert `bits` into `v` at position `start`. |

### Signed comparison

The normal `<`, `<=`, `>`, `>=` operators are type-directed — signed when
an operand is `i8`..`i64`, unsigned otherwise (see §4). To force a signed
comparison on unsigned operands (raw `u64` bit patterns):

```kr
signed_lt(a, b)    signed_gt(a, b)
signed_le(a, b)    signed_ge(a, b)
```

### Platform and process

| Function | Description |
|---|---|
| `exit(code)` | Terminate the process with an exit code. |
| `get_target_os()` | Host OS: `0`=Linux, `1`=macOS, `2`=Windows, `3`=Android. |
| `get_arch_id()` | Compile-time arch ID: `1` Linux x86_64, `2` Linux arm64, `3` Win x86_64, `4` Win arm64, `5` macOS x86_64, `6` macOS arm64, `7` Android arm64, `8` Android x86_64. |
| `exec_process(path)` | Spawn and wait for a process (argv = `{path, NULL}`). Returns exit code. |
| `exec_process_argv(path, argv)` | Like `exec_process` but with an explicit NULL-terminated `argv` pointer array. |
| `set_executable(path)` | `chmod +x` equivalent. |
| `time_ns()` | Monotonic clock reading in nanoseconds (`CLOCK_MONOTONIC`). |
| `get_module_path(buf, size)` | Write the current binary's path into `buf`. |
| `fmt_uint(buf, val)` | Format `val` as decimal into `buf`. Returns length. |
| `syscall_raw(nr, a1, a2, a3, a4, a5, a6)` | Raw syscall with up to 6 args. |

### Function pointers

| Function | Description |
|---|---|
| `fn_addr(name)` | Get the address of a named function. The name is a string literal, resolved at link time. |
| `call_ptr(addr, ...)` | Call a function by address with any number of arguments. The caller's signature must match the target's or the result is undefined. |

Example — passing a comparator to a generic sort-ish loop:

```kr
fn asc(u64 a, u64 b) -> u64 { return a < b }
fn desc(u64 a, u64 b) -> u64 { return a > b }

fn sorted(u64 a, u64 b, u64 cmp) -> u64 {
    if call_ptr(cmp, a, b) != 0 { return a }
    return b
}

fn main() {
    u64 c = fn_addr("asc")
    exit(sorted(3, 7, c))        // → 3
}
```

### Cache and memory-ordering builtins (ARM64 / x86)

| Function | ARM64 | x86_64 | Description |
|---|---|---|---|
| `isb()` | `ISB` | nop | Instruction-sync barrier. |
| `dsb()` | `DSB SY` | `MFENCE` | Full data-sync barrier — waits for completion. |
| `dmb()` | `DMB ISH` | `MFENCE` | Data-memory barrier (inner-shareable). |
| `dcache_flush(addr)` | `DC CIVAC + DSB ISH + ISB` | `CLFLUSH + MFENCE` | Writeback + invalidate one cache line. |
| `icache_invalidate(addr)` | `IC IVAU + DSB ISH + ISB` | nop (coherent) | Invalidate one I-cache line. |

---

## 19. Annotations

Annotations appear immediately before a function or struct declaration.

### `@export`

Marks a function for inclusion in the output binary's symbol table (for
linking or ELF object introspection).

```kr
@export
fn my_entry() { }
```

### `@section("name")`

Places the function in a named section for kernel / bare-metal
layouts. Under `--emit=asm` the listing emits a gas-style directive
(`.section .text.init,"ax",@progbits`) before the function's label,
so the output round-trips through GNU as + ld with a user-supplied
linker script.

```kr
@section(".text.init")
fn _start() { /* placed in a separate section */ }
```

Under `--emit=obj` the name is captured but the ELF relocatable still
groups all code into `.text` — full multi-section object emit is on
the roadmap.

### `@naked`

Emits a function with no prologue/epilogue. Useful for interrupt handlers
and low-level entry points that manage their own stack.

```kr
@naked fn isr() {
    asm { "cli"; "nop"; "iretq" }
}
```

### `@noreturn`

Marks a function that never returns (e.g. `panic`, infinite loops).
The compiler omits the epilogue.

```kr
@noreturn fn panic() {
    write(2, "panic\n", 6)
    while true { asm("hlt") }
}
```

### `@builtin_override`

Defining a function whose name matches a recognized built-in (`str_len`,
`time_ns`, `memcpy`, ...) is a **compile error**: the user body would win
at every call site, and silent shadowing has produced invisible bugs.
Annotating the definition with `@builtin_override` declares the shadowing
deliberate — calls then resolve to the user body on every backend.

```kr
@builtin_override
fn str_len(uint64 s) -> uint64 {
    // custom implementation; calls to str_len() use this body,
    // not the built-in
    ...
}
```

`extern fn` declarations are exempt and keep their documented behavior:
`extern fn write(...)` shadows the built-in without any annotation
(see section 24). Struct methods (`fn Type.name`) never collide with
built-ins — they dispatch via dot syntax — so they need no annotation.

### `@packed`

Accepted on struct declarations. KernRift structs are *already* packed
(no alignment padding), so this annotation is currently a no-op that
documents intent.

```kr
@packed struct Header {
    u8  kind
    u32 length
    u8  flags
}
```

### Analysis annotations: `@ctx`, `@eff`, `@caps`, `@acquires` / `@releases`

A separate family of annotations feeds the optional effect / capability /
lock analysis passes (`krc check`): `@ctx(...)` declares an execution
context, `@eff(...)` the effects a function may perform, `@caps(...)` the
capabilities it requires, and `@acquires(...)` / `@releases(...)` track
lock ownership for the deadlock-cycle check. They are advisory pre-1.0
and do not affect codegen. See [EFFECT_SYSTEM.md](EFFECT_SYSTEM.md) for
the full model.

---

## 20. Compiler CLI

```sh
krc <file.kr>                        # compile to <stem>.krbo (fat binary, all 8 slices)
krc <file.kr> -o out                 # specify output name
krc <file.kr> --arch=x86_64 -o out   # single-arch native ELF
krc <file.kr> --arch=arm64 -o out    # single-arch ARM64 ELF
krc <file.kr> --targets=linux-x64,macos-arm64 -o out.krbo   # custom fat subset (v2.8.x)

# Single target (one platform, host or cross) instead of a fat binary:
krc <file.kr> --target=linux -o out
krc <file.kr> --target=macos -o out
krc <file.kr> --target=windows -o out.exe
krc <file.kr> --target=android -o out

# Emit format (aliased since v2.8.4):
#   elfexe / elf                                        → Linux ELF
#   pe                                                  → Windows PE
#   macho                                               → macOS Mach-O
#   android                                             → Android PIE ELF
#   obj   (or -c)                                       → ELF relocatable (.o / .obj)
#   lkm                                                 → Linux kernel module (.ko) — see docs/LKM.md
#   asm                                                 → annotated assembly listing (to -o path)
#   ir                                                  → SSA IR dump per function (to stdout)
krc <file.kr> --emit=pe -o out.exe
krc <file.kr> --emit=macho -o out
krc <file.kr> --emit=android -o out
krc <file.kr> -c -o out.o            # shorthand for --emit=obj
krc <file.kr> --emit=lkm -o mod.ko   # Linux loadable kernel module (x86_64 only)

# Codegen backend & optimization
krc <file.kr> --arch=arm64           # default: IR (SSA + optimizer + regalloc)
krc --legacy --arch=arm64 <file.kr>  # legacy direct-walking codegen
krc --ir <file.kr>                   # force IR even where a recipe falls back to legacy
krc --no-coalesce <file.kr>          # disable Briggs/George copy coalescing (default on)
krc --no-check-types <file.kr>       # disable the type checker (default on)
krc --O0 <file.kr>                   # disable the IR optimizer (CF/DCE/CSE/LICM)
krc --debug <file.kr>                # runtime safety checks (bounds, null, some div-by-zero)
krc -g <file.kr> -o out              # emit DWARF debug info (.debug_line/info/abbrev/str)

# Non-compile modes
krc --freestanding <file.kr> -o out  # no main trampoline, no auto-exit
krc check <file.kr>                  # static checks only (semantic + type checker)
krc fmt   <file.kr>                  # auto-format: prints formatted source to stdout
krc lc <file.kr>                     # living compiler report (section 21)
krc lc --fix <file.kr>               # apply auto-fixes in place
krc lc --fix --dry-run <file.kr>     # preview auto-fixes without writing
krc lc --ci <file.kr>                # CI gate: exit non-zero if patterns fire
krc lc --min-fitness=N <file.kr>     # filter: only patterns with fitness >= N
krc lc --list-proposals              # print the proposal registry
krc lc --promote <name>              # promote a proposal to stable
krc lc --deprecate <name>            # mark a proposal as deprecated
krc lc --reject <name>               # revert a proposal to experimental
krc --emit=ir <file.kr>              # dump the SSA IR for a single function
krc --version                        # print the compiler version
krc --help                           # usage info
```

For debugging — `-g` DWARF in gdb, the `--debug` trap table, and the
`--O0` → `--no-coalesce` → `--legacy` miscompile bisection ladder — see
[docs/DEBUGGING.md](DEBUGGING.md).

### Static checks: the type checker

A static type checker runs by default on every compile (and under
`krc check`). Its errors are **fatal** — they abort the build with a
`file:line:col` message, source line, and caret. Pass `--no-check-types`
to disable it (e.g. to compile a file it rejects while you investigate).

It is a focused checker centred on struct/float/void misuse, not a full
Hindley–Milner system — integer-width mismatches, for instance, are not
flagged. What it catches:

| Category | Example that is rejected |
|----------|--------------------------|
| Field access on a non-struct | `u64 n = 5` then `n.x` |
| Unknown field on a struct | `p.nope` where `nope` isn't a field of `p`'s type |
| Two different struct types mixed | `Q q = some_P` (init, assignment, argument, return, or match pattern) |
| Arithmetic on a struct value | `p + q` |
| Ordering comparison on a struct | `p < q` (`==`/`!=` are allowed — field-by-field equality) |
| Void function used as a value | `u64 x = print_str(s)` |
| Return value/void mismatch | `return x` in a void fn, or bare `return` in a value fn |
| Float-kind mismatch on return | returning an `f32` from an `-> f64` function |
| `match` on a float scrutinee | `match some_f64 { ... }` |
| Ternary / `match`-expr arms mixing float and int | `c ? 1.5 : 2` |

Because KernRift treats a struct-typed variable as a typed pointer, a
struct and a raw pointer/`u64` mix freely (`P p = alloc(16)` is fine);
only two *different* struct types clash.

### `kr` runner

```sh
kr program.krbo                      # run a fat binary on any platform
kr program.krbo arg1 arg2            # forward args to the child
kr --version
kr --help
```

The `kr` runner auto-detects the host architecture (x86_64 / arm64 / Linux
/ Windows / macOS / Android), extracts the matching slice from `.krbo`,
BCJ-unfilters the decompressed code, and execves it. On Android (Linux
≥ 3.17) it uses `memfd_create` + `execveat(AT_EMPTY_PATH)` to bypass
SELinux file-exec restrictions without writing to cwd; older kernels
fall back to a `/data/local/tmp/kr-exec` / cwd temp file plus a
`exit(120)` shell-wrapper trampoline.

---

## 21. Living compiler

`krc lc` analyses KernRift source and produces a two-layer report. The
living compiler separates concerns into a **stable semantic core**
(correctness and structural issues) and an **adaptive surface layer**
(ergonomic migrations that lower to the same IR). This lets the language
evolve without destroying compatibility.

### Basic report

```sh
krc lc file.kr
```

Output has three sections: a telemetry summary, a fitness score
(layer-weighted, 0–100), and the patterns detected in each layer.
Patterns tagged `(auto-fix available)` can be rewritten mechanically.

### CI gating

```sh
krc lc --min-fitness=60 file.kr     # filter: only patterns with fitness >= 60
krc lc --ci file.kr                 # exit non-zero if any pattern fires
krc lc --ci --min-fitness=50 file.kr  # gate only on patterns >= 50
```

### Migration engine (auto-fix)

```sh
krc lc --fix file.kr                # rewrite in place
krc lc --fix --dry-run file.kr      # preview the rewritten source
```

The migration engine currently handles the `legacy_ptr_ops` pattern:

- `unsafe { *(addr as T) -> dest }`  →  `dest = loadN(addr)`
- `unsafe { *(addr as T) = val }`    →  `storeN(addr, val)`

Both forms lower to identical code at the codegen level, so the rewrite
is safe by construction.

### Proposal registry

The living compiler ships with a registry of candidate syntax evolutions,
each tagged with a lifecycle state (`experimental`, `stable`, or
`deprecated`):

```sh
krc lc --list-proposals
```

Proposals with triggers that match the current file fire inline in the
report. Under `#lang stable` (the default), only stable proposals fire.
Under `#lang experimental`, experimental proposals also fire as
"coming-soon" hints.

### Governance: persistent per-project state

Each project can override the compiler's baseline proposal states and
store them in a `.kernrift/proposals` file at the project root:

```sh
krc lc --promote <name>     # move a proposal to `stable`
krc lc --deprecate <name>   # move a proposal to `deprecated`
krc lc --reject <name>      # revert to `experimental`
```

The first invocation creates `.kernrift/proposals`. Subsequent runs of
`krc lc` in that directory automatically load the overrides. The format
is one line per proposal:

```
slice_for_buffer_params stable
tail_call_intrinsic experimental
extern_fn_decls deprecated
```

This is how the governance layer actually works — the compiler has a
baseline, each project can pin its own decisions, and everything is
version-controlled alongside the source.

See [`docs/LIVING_COMPILER.md`](LIVING_COMPILER.md) for the full
blueprint and the pipeline design.

---

## 22. Language profiles (`#lang`)

A source file may pin its required language profile on the first line:

```kr
#lang stable

fn main() {
    // only features promoted to the stable surface are allowed
    println("hello")
    exit(0)
}
```

```kr
#lang experimental

fn main() {
    // experimental features are also allowed
    exit(0)
}
```

Recognized profiles:

| Profile | Meaning |
|---|---|
| `stable` | Default. All stable features. Safe for production code. |
| `experimental` | Also allows features under active development. |

The directive must be the first non-empty line of the file. If absent,
the profile defaults to `stable`.

Profiles are part of the Living Compiler's two-layer model: the stable
semantic core doesn't change, but the adaptive surface layer may gate
certain features (like `tail_call()` or `extern fn` when those are added)
behind `#lang experimental`. This lets the language evolve without
breaking existing files — pin a file to `stable` and it keeps compiling
forever, even as new experimental features enter the language.

---

## 23. Freestanding mode

`krc --freestanding` produces a binary suitable for bare-metal:

- No automatic `exit(0)` at the end of `main`.
- No OS-specific syscall wrappers injected.
- The ELF entry point (`e_entry`) still points at `main` — you must
  provide `fn main()`. If you want a different name (e.g. `_start`),
  keep `fn main()` as the trampoline and have it call into your
  entry function.

```sh
krc --freestanding --arch=arm64 kernel.kr -o kernel.elf
```

Use this for kernel entry points, bootloaders, and embedded firmware.
The programmer is responsible for setting up the stack and handling
any return from `main`. Mark functions that never return with
`@noreturn` so the compiler skips the return-path check; annotate
interrupt handlers with `@naked` to suppress the prologue/epilogue.

Freestanding example:

```kr
@noreturn
fn main() {
    // kernel entry — set up your own state, never returns
    u64 vga = 0xB8000
    store16(vga + 0, 0x0F48)  // 'H' bright white
    store16(vga + 2, 0x0F69)  // 'i'
    while true { }
}
```

### Stack size warnings

The legacy backend (`--legacy`) prints a warning to stderr when a
function's stack frame exceeds 49152 bytes (the default IR backend does
not currently implement this warning):

```
warning: large stack frame (60032 bytes) in function 'parse_module'
```

This catches accidental large local arrays that could overflow a kernel
stack. Big dispatch functions with many mutually exclusive branches
legitimately allocate slots across branches; the threshold is set high
enough to let those pass.

### Embedded targets: riscv32 and xtensa

On x86_64 and arm64, `--freestanding` only removes the startup glue — the whole
language is still available. On the 32-bit embedded backends
(`--arch=riscv32`, `--arch=xtensa`) the *language itself* is a subset, and the
restrictions are hard compile errors rather than silent miscompiles:

| Construct | riscv32 hosted | riscv32 `--freestanding` | xtensa |
|---|---|---|---|
| Arithmetic, control flow, calls, `device` blocks | Yes | Yes | Yes |
| String literals, `str_len` / `str_eq` | Yes | Yes | Yes |
| `static` globals, fixed arrays | Yes | Yes | Yes |
| Structs, `alloc()` | Yes | **No** | **No** |
| `f16` / `f32` / `f64` | **No** | **No** | **No** |
| `u64` / `i64` | **No** | **No** | **No** |
| `exit()`, `syscall_raw` | Yes | **No** | **No** |

```
error: 64-bit integers not supported on riscv32; use uint32
error: float (f16/f32/f64) not supported on riscv32 (no hardware FPU)
error: riscv32: IR op 70 not yet implemented        // IR_ALLOC: struct or alloc()
```

The 64-bit restriction is the one that bites first when porting existing code,
because `u64` is the language's integer default (§3). On these targets the word
is 4 bytes; write `u32` (or `uint32`) everywhere.

### The `fn main() -> uint32` shape

Because a freestanding program has no OS beneath it, there is nothing for
`exit()` to talk to, and the embedded backends refuse to emit it. A freestanding
program instead **returns** its result, or never returns at all:

```kr
// Return a value. The harness or debugger reads it from the return register.
fn main() -> uint32 {
    return 42
}
```

```kr
// Or never return — on real silicon there is nothing to return to.
fn main() {
    loop { }
}
```

Hosted riscv32 uses the same shape, but there the returned value becomes the
process exit status:

```sh
krc --arch=riscv32 examples/riscv-hosted/exit_code.kr -o exit_code
qemu-riscv32-static ./exit_code ; echo $?    # 42
```

Note that `@noreturn fn main()` (the x86/arm64 kernel idiom shown above) still
applies to the embedded targets — it is the `loop { }` form.

### Talking to hardware

MMIO is the same on every target: declare a `device` block (§13) and read/write
its fields, which lower to volatile accesses with the appropriate barriers
(§12). Nothing about `device` blocks is target-specific, and they are fully
supported on riscv32 and xtensa:

```kr
device UART0 at 0x3FF40000 {
    status at 0x1C : u32
}

fn wait_tx_ready() {
    while (UART0.status & 0xFF0000) == 0 { }
}
```

For the ESP32 machine target (`--target=esp32`), its flash-image layout, and its
IRAM/DRAM budget, see the
[README](../README.md#embedded-targets-riscv32--xtensa--esp32) and the annotated
[`examples/esp32/hello.kr`](../examples/esp32/hello.kr).

---

## 24. Extern functions

`extern fn` declares a function that is resolved by the platform linker at
link time. It has no body — the signature names an external symbol (typically
from libc or another static library):

```kr
extern fn strlen(u64 s) -> u64
extern fn write(u64 fd, u64 buf, u64 len) -> u64

fn main() {
    u64 msg = "hello from KernRift via libc!\n"
    write(1, msg, strlen(msg))
    exit(0)
}
```

Compile to a relocatable object and link with the platform toolchain:

```sh
# Linux
krc --emit=obj extern_libc.kr -o extern_libc.o
gcc extern_libc.o -o extern_libc -no-pie

# macOS
krc --target=macos --emit=obj extern_libc.kr -o extern_libc.o
clang extern_libc.o -o extern_libc

# Windows
krc --target=windows --emit=obj extern_libc.kr -o extern_libc.obj
link extern_libc.obj msvcrt.lib /ENTRY:main /SUBSYSTEM:console
```

The compiler emits relocations in the native format of each target:

| Target        | Format  | Relocation                |
|---------------|---------|---------------------------|
| Linux x86_64  | ELF     | `R_X86_64_PLT32`          |
| Linux ARM64   | ELF     | `R_AARCH64_CALL26`        |
| macOS x86_64  | Mach-O  | `X86_64_RELOC_BRANCH`     |
| macOS ARM64   | Mach-O  | `ARM64_RELOC_BRANCH26`    |
| Windows x64   | COFF    | `IMAGE_REL_AMD64_REL32`   |
| Windows ARM64 | COFF    | `IMAGE_REL_ARM64_BRANCH26`|

`extern fn` names shadow built-ins: if you declare `extern fn write(...)`,
calls to `write` resolve to the libc symbol instead of the `write` syscall
built-in. This lets you opt into the platform runtime on demand.

Note that programs that call buffered libc functions (like `printf` or
`puts`) from `main()` should exit via a libc `exit()` rather than the
built-in `exit()` — the built-in uses a raw syscall that bypasses libc's
stdio flush on exit. The safest pattern is to declare `extern fn exit`
and use that:

```kr
extern fn exit(u64 code)
extern fn puts(u64 s) -> u64

fn main() {
    puts("flushed through stdio")
    exit(0)
}
```

---

## 25. Binary formats

| Format | Produced by | Use |
|---|---|---|
| `.krbo` fat binary | default (no `--arch`) | Cross-platform distribution — `kr` picks the right slice |
| ELF executable | `--arch=x86_64` / `--arch=arm64` on Linux | Native Linux binary |
| ELF relocatable | `--emit=obj` | Link into an external object (`.o`) |
| Mach-O | `--emit=macho` | macOS executable (x86_64 or arm64) |
| PE | `--emit=pe` | Windows `.exe` |
| Android PIE ELF | `--emit=android` | Android ARM64 (default) or x86_64 (`--arch=x86_64`) |
| Assembly listing | `--emit=asm` | Human-readable disassembly with labels |

A `.krbo` fat binary packs up to 8 platform slices (Linux x86_64, Linux
ARM64, Windows x86_64, Windows ARM64, macOS x86_64, macOS ARM64, Android
ARM64, Android x86_64), each BCJ+LZ4 compressed. The `kr` runner
extracts and executes the slice matching the current host at startup.

---

## Appendix A. ABI reference

This is a quick reference for anyone reading the code `krc` generates or
linking it against other toolchains. It's the minimum you need to
reason about register allocation, interoperate with C, or write
`@naked` functions.

### x86_64

| Target  | Arg regs (1..6/8)                   | Return | Callee-saved                    | Stack align at CALL |
|---------|-------------------------------------|--------|---------------------------------|---------------------|
| Linux   | `rdi rsi rdx rcx r8 r9` (then stack) | `rax`  | `rbx rbp r12 r13 r14 r15 rsp`   | 16                  |
| macOS   | same (System V)                     | `rax`  | same                            | 16                  |
| Windows | `rcx rdx r8 r9` (then stack, +32 shadow) | `rax` | `rbx rbp rdi rsi rsp r12..r15 xmm6..xmm15` | 16 |

- KernRift currently allocates only GPRs — no XMM usage in generated
  code, so the caller-saved XMM registers are irrelevant to user code
  but matter when you link against C.
- On Windows, the first 32 bytes of the stack below `rsp` at call time
  are a **shadow** area owned by the callee. `krc` allocates it for you.
- `@naked` functions get no prologue/epilogue — you're responsible for
  stack alignment if you call into user code.

### arm64 (AArch64)

| Target       | Arg regs  | Return | Callee-saved       | Syscall nr in |
|--------------|-----------|--------|--------------------|---------------|
| Linux        | `x0..x7`  | `x0`   | `x19..x28 sp fp lr` | `x8`          |
| macOS        | `x0..x7`  | `x0`   | same               | `x16`         |
| Android      | `x0..x7`  | `x0`   | same               | `x8`          |
| Windows arm64| `x0..x7`  | `x0`   | same               | (no syscalls; uses kernel32 IAT) |

## Appendix B. Syscall numbers

`krc`'s builtins lower to real kernel syscalls. The table below is the
number used by each builtin on each supported (OS × arch) target.
Useful when reading `--emit=asm` output, stepping through with a
debugger, or writing portable code that uses `syscall_raw`.

### Linux x86_64

| Builtin    | nr  | C name          |
|------------|-----|-----------------|
| `write`    | 1   | `write`         |
| `read`     | 0   | `read`          |
| `exit`     | 231 | `exit_group`    |
| `alloc`    | 9   | `mmap`          |
| `dealloc`  | 11  | `munmap`        |
| `file_open`| 2   | `open`          |
| `file_read`| 0   | `read`          |
| `file_write`|1   | `write`         |
| `file_close`|3   | `close`         |
| `time_ns`  | 228 | `clock_gettime` |
| `set_executable` | 90 | `chmod` |

`syscall_raw(nr, a1, a2, a3, a4, a5, a6)` passes `nr` in `rax` and the
arguments in `rdi rsi rdx r10 r8 r9` (standard Linux x86_64 ABI). The
table above covers every `krc` builtin that lowers to a syscall — for
anything else you're calling directly, get the number from the kernel's
own table at
[`arch/x86/entry/syscalls/syscall_64.tbl`](https://github.com/torvalds/linux/blob/master/arch/x86/entry/syscalls/syscall_64.tbl).
Example: `getpid` is syscall 39 — `uint64 pid = syscall_raw(39, 0, 0, 0, 0, 0, 0)`.

### Linux arm64

| Builtin    | nr  |
|------------|-----|
| `write`    | 64  |
| `read`     | 63  |
| `exit`     | 93  |
| `alloc`    | 222 (`mmap`)  |
| `dealloc`  | 215 (`munmap`) |
| `file_open`| 56  (`openat`) |
| `time_ns`  | 113 (`clock_gettime`) |
| `set_executable` | 53 (`fchmodat`) |

`syscall_raw` passes nr in `x8` and args in `x0..x5`. Complete numbering
list: Linux kernel
[`include/uapi/asm-generic/unistd.h`](https://github.com/torvalds/linux/blob/master/include/uapi/asm-generic/unistd.h)
(arm64 uses the generic table).

### macOS x86_64

macOS syscall numbers use the high nibble to encode the syscall class
(2 = Unix class). The numbers below are the full 32-bit values passed
in `rax`; arguments go in `rdi rsi rdx rcx r8 r9` like Linux.

| Builtin    | nr          | C name   |
|------------|-------------|----------|
| `exit`     | `0x2000001` | `exit`   |
| `write`    | `0x2000004` | `write`  |
| `read`     | `0x2000003` | `read`   |
| `alloc`    | `0x20000C5` | `mmap`   |

### macOS arm64

On arm64 macOS, the syscall number goes in **`x16`** (not `x8` as on
Linux). Numbers are the plain Darwin numbers, not the class-tagged form.

| Builtin    | nr  |
|------------|-----|
| `exit`     | 1   |
| `write`    | 4   |
| `read`     | 3   |
| `alloc`    | 197 |

Darwin syscall table (both arches): xnu
[`bsd/kern/syscalls.master`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/syscalls.master).
On x86_64 macOS, OR the base number with `0x2000000` to form the `rax`
value (e.g. `exit` = `1 | 0x2000000 = 0x2000001`).

### Windows

Windows x86_64 and arm64 do not use direct syscalls — every I/O and
process-control builtin lowers to a call through the binary's Import
Address Table (IAT) against `kernel32.dll`:

| Builtin            | kernel32 import            |
|--------------------|----------------------------|
| `exit`             | `ExitProcess`              |
| `write`            | `GetStdHandle` + `WriteFile` |
| `read`             | `GetStdHandle` + `ReadFile` |
| `alloc`            | `VirtualAlloc`             |
| `dealloc`          | `VirtualFree`              |
| `file_open`        | `CreateFileA`              |
| `file_read`        | `ReadFile`                 |
| `file_write`       | `WriteFile`                |
| `file_close`       | `CloseHandle`              |
| `exec_process`     | `CreateProcessA` + `WaitForSingleObject` + `GetExitCodeProcess` + `ExitProcess` |
| `set_executable`   | no-op (Windows has no executable bit) |

`syscall_raw` is **not supported** on Windows — the platform has no
stable syscall numbering. The `--target=windows` PE output uses IAT
imports exclusively.

## Appendix C. `--emit=obj` section layout

A relocatable object file (`.o` on Linux/macOS, `.obj` on Windows) produced
by `--emit=obj` contains the minimum set of sections the platform linker
needs. No `.rodata`, no `.bss`, no `.data` — string literals and static
scalars are placed at the end of `.text` and referenced with RIP-relative
addressing.

### Linux x86_64 / arm64 (ELF)

| Index | Name              | Type      | Purpose |
|-------|-------------------|-----------|---------|
| 0     | (null)            | NULL      | required by ELF |
| 1     | `.text`           | PROGBITS  | code + string literals + static scalars |
| 2     | `.data`           | PROGBITS  | (emitted empty — static data lives inside `.text`) |
| 3     | `.symtab`         | SYMTAB    | every `fn` is a symbol; `main` is `GLOBAL`, others `LOCAL` |
| 4     | `.strtab`         | STRTAB    | symbol name strings |
| 5     | `.shstrtab`       | STRTAB    | section header names |
| 6     | `.note.GNU-stack` | PROGBITS (flags=0) | marks the binary as non-exec-stack so `ld` doesn't warn |
| 7     | `.rela.text`      | RELA      | only present if the program uses `extern fn` |

Relocation types for `extern fn` call sites:
- **x86_64**: `R_X86_64_PLT32` (disp32 = -4 addend)
- **arm64**: `R_AARCH64_CALL26` (addend 0)

### macOS x86_64 / arm64 (Mach-O)

One `__TEXT,__text` section containing code + string literals. Symbol
names are prefixed with an underscore (`_main`, `_write`) as required
by the Darwin C ABI. `extern fn` call sites use relocations
`X86_64_RELOC_BRANCH` (x86_64) and `ARM64_RELOC_BRANCH26` (arm64).

### Windows x86_64 / arm64 (COFF `.obj`)

One `.text` section, one COFF symbol table. No underscore prefix on
x86_64. `extern fn` call sites use relocations
`IMAGE_REL_AMD64_REL32` (x86_64) and `IMAGE_REL_ARM64_BRANCH26` (arm64).

### Linking with gcc or clang

```sh
# Linux
krc --emit=obj prog.kr -o prog.o
gcc prog.o -o prog -no-pie

# No more "missing .note.GNU-stack" warning as of v2.6.3 — the compiler
# emits the section by default so linked binaries get a non-executable
# stack.
```

## Appendix D. `.krbo` fat-binary format (v2)

The runtime format for `.krbo` files — directly parseable without any
KernRift toolchain.

**Layout**:
```
offset  size  field
0x00    8     magic:        "KRBOFAT\0"
0x08    4     version:      u32 = 2
0x0C    4     arch_count:   u32 (currently emitted as 8)
0x10    (arch_count × 48)   arch descriptor table
...     compressed slice blobs (per arch)
```

> **Note**: the descriptor reserves `runtime_offset` / `runtime_len`
> for per-arch kr-runner blobs, but the current emitter writes them
> as `0` and the runner ignores them. Decoders should treat those
> fields as informational only.

**Arch descriptor** (48 bytes each, one per slice):
```
offset  size  field
+0x00   4     arch_id:           u32 (see table below)
+0x04   4     compression:       u32 (1 = LZ4 frame, preceded by BCJ filter)
+0x08   8     slice_offset:      u64 (from start of file)
+0x10   8     slice_comp_size:   u64
+0x18   8     slice_uncomp_size: u64
+0x20   8     runtime_offset:    u64 (reserved, emitted as 0)
+0x28   8     runtime_len:       u64 (reserved, emitted as 0)
```

**Arch IDs**:

| id | OS       | arch   |
|----|----------|--------|
| 1  | Linux    | x86_64 |
| 2  | Linux    | arm64  |
| 3  | Windows  | x86_64 |
| 4  | Windows  | arm64  |
| 5  | macOS    | x86_64 |
| 6  | macOS    | arm64  |
| 7  | Android  | arm64  |
| 8  | Android  | x86_64 |

**Decompression**: each slice is LZ4-compressed with a BCJ filter
applied *before* compression. On extraction the runner first LZ4-
decompresses, then runs the matching BCJ filter in reverse to restore
the original call/jmp offsets. BCJ filter selection:
- x86-family arch_ids (1, 3, 5, 8): x86_64 BCJ filter (rewrites `E8`/`E9`
  disp32 offsets to absolute, for better compression).
- arm-family arch_ids (2, 4, 6, 7): AArch64 BCJ filter (rewrites `BL`
  imm26 fields).

Edge case: the x86_64 BCJ filter is a no-op when the slice is shorter
than 5 bytes (the minimum length of an `E8`/`E9` disp32 instruction),
and the arm64 filter is a no-op on slices shorter than 4 bytes. Both
conditions happen only for pathologically tiny test programs and are
safe — there is nothing to rewrite in either direction, so
encode+decode remains a perfect round-trip.

**Minimal Python decoder**:
```python
import struct, lz4.frame

def parse_krbo(path):
    d = open(path, 'rb').read()
    assert d[:8] == b'KRBOFAT\0'
    ver, n = struct.unpack_from('<II', d, 8)
    assert ver == 2
    slices = []
    for i in range(n):
        off = 16 + i * 48
        (arch_id, compression,
         slice_off, comp_sz, uncomp_sz,
         rt_off, rt_len) = struct.unpack_from('<IIQQQQQ', d, off)
        raw_lz4 = d[slice_off:slice_off + comp_sz]
        # NOTE: you still need to reverse the BCJ filter after lz4 decode
        decompressed = lz4.frame.decompress(raw_lz4)
        slices.append((arch_id, decompressed))
    return slices
```

`arch_count` is currently 8 (Linux x86_64, Linux arm64, Windows x86_64,
Windows arm64, macOS x86_64, macOS arm64, Android arm64, Android x86_64).
The descriptor table is fixed-stride so decoders can skip ahead by
`16 + arch_count × 48` to locate the first compressed blob. Future
targets (e.g. FreeBSD) can be added by bumping `arch_count` without
format-version changes.

---

*See the `examples/` directory for runnable programs demonstrating every
feature in this reference.*
