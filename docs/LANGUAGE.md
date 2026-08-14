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

// There are no block comments. `/* ... */` is a parse error; use `//` on
// each line.

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

### Evaluation order

**Evaluation is left to right, and in an assignment the destination
address is evaluated before the value.** Both operands of a binary
operator, every call argument, and both sides of a store run in source
order, on every backend and every target:

```kr
arr[ai()] = fv()          // ai() then fv()
arr[a()]  = fv() + b()    // a(), then fv(), then b()
unsafe { *(fa() as uint32) = fv() }   // fa() then fv()
pts[ai()].x = fv()        // ai() then fv()
f(p(), q(), r())          // p(), q(), r()
```

"Destination address" includes the subscript of an indexed store and the
address expression of an `unsafe` deref store — the *whole* address, before
*any* of the value. `arr[i] OP= v` follows the same rule and evaluates `i`
exactly once. `&&` and `||` still short-circuit, so the right operand of
those may not run at all (§5).

This is a language guarantee, not an artifact: `tests/diff_ir_legacy.sh`
pins the order on all four backend configurations.

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

**Both bounds are evaluated exactly once, before the first iteration**, start
then end. `for i in 0..len(x)` calls `len` once, not once per iteration, and a
bound with a side effect runs that side effect once. The loop iterates over the
range that snapshot describes, so assigning to a variable the end bound was
computed from does not lengthen or shorten the loop:

```kr
uint64 n = 3
for i in 0..n { n = 100 }   // 3 iterations, not 100
```

Use `while` when the condition genuinely has to be re-tested every trip.

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

What is emitted depends on the architecture **and the backend**:

- **x86_64**, both backends: `mfence` (full memory fence) alongside a
  width-correct `mov`.
- **ARM64, IR backend (the default)**: no barrier instruction at all. The
  access itself becomes an acquire/release form — `LDARB`/`LDARH`/`LDAR` and
  `STLRB`/`STLRH`/`STLR`. That gives **ordering, not completion**.
- **ARM64, `--legacy`**: a plain `LDR`/`STR` bracketed by `DSB SY`, which does
  wait for completion.

Measured by compiling `vload32` + `vstore32` and counting in `--emit=asm`:
x86_64 IR 2 × `mfence`, x86_64 legacy 2 × `mfence`, **arm64 IR 0 × `DSB`**
(`LDAR W20,[X19]` / `STLR W21,[X19]`), arm64 legacy 2 × `DSB SY`.

If you are on ARM64 with the default backend and you need the access to have
*completed* — the usual requirement when poking a device register and then
waiting on its effect — add an explicit `dsb()`. Do not assume the volatile
form does it for you.

Note when checking this yourself: the `--emit=asm` disassembler prints the
`LDAR`/`STLR` encodings with a blank mnemonic, so grepping the listing for
`stlr` reports nothing. Decode the raw words (`88dffe74`, `889ffe75`).

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
loads and stores of the right width — that is, to exactly what `vload*` /
`vstore*` emit, with the same per-backend caveat: `mfence` on x86_64, but
`LDAR`/`STLR` acquire/release **ordering** on ARM64's default IR backend,
verified by compiling a `device` block and finding 0 `DSB` in the listing.
See §12 above.

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
(`in al, dx`, `out dx, al`, wide variants), register-to-register `mov`,
`push`/`pop` of a register, and **`call <reg>` / `jmp <reg>`** (indirect,
`FF /2` and `FF /4`).

`call <reg>` exists for the one thing `call_ptr` cannot do: enter a function
after changing `rsp` yourself. `call_ptr` is framed normally by the compiler,
and a compiler-managed frame does not survive `rsp` moving underneath it, so a
stack-switching trampoline has to make the call from inline asm. Note what is
still absent — there is **no memory operand** (`mov [rcx], rsp`) and no
immediate arithmetic (`and rsp, -16`), so a trampoline must keep its saved
state in registers and let the caller do any alignment.

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
`{expr}` with the same type-directed formatter `print` uses. The literal
segments between the interpolations take **exactly the escape sequences a
plain `"..."` literal takes** — `\n \t \r \0 \\ \" \' \b \f \v \a \e` and
`\xHH` — so `f"a\nb={n}\n"` is two lines, not a backslash and an `n`. A
literal brace is written `{{` or `}}` (`\{` and `\}` also work). f-strings
compose with variadic `println`:

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
| `vload8/16/32/64(addr)` | Volatile load for MMIO — `mfence` on x86_64, `LDAR*` acquire on arm64 IR (§12). |
| `vstore8/16/32/64(addr, val)` | Volatile store for MMIO — `mfence` on x86_64, `STLR*` release on arm64 IR (§12). |

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
| `get_target_os()` | Target OS: `0`=Linux, `1`=macOS, `2`=Windows, `3`=Android, `4`=none (bare metal, `--target=none`). |
| `get_arch_id()` | Compile-time arch ID: `1` Linux x86_64, `2` Linux arm64, `3` Win x86_64, `4` Win arm64, `5` macOS x86_64, `6` macOS arm64, `7` Android arm64, `8` Android x86_64, `9` bare-metal x86_64, `10` bare-metal arm64, `11` bare-metal riscv32, `12` bare-metal xtensa. |
| `exec_process(path)` | Spawn and wait for a process (argv = `{path, NULL}`). Returns exit code. |
| `exec_process_argv(path, argv)` | Like `exec_process` but with an explicit NULL-terminated `argv` pointer array. |
| `set_executable(path)` | `chmod +x` equivalent. |
| `time_ns()` | Monotonic clock reading in nanoseconds (`CLOCK_MONOTONIC`). |
| `get_module_path(buf, size)` | Write the current binary's path into `buf`. Returns the length, or `0` if no path is available — which is the answer on Linux, macOS, Android and `--target=none`; only Windows resolves a real path. |
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
fn _start() { }   // placed in a separate section
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
#   ir                                                  → IR dump per function (to stdout; not SSA -- linear three-address code, see src/ir.kr)
#   image                                               → raw flat binary, no container (bare metal; --image-header prefixes an arm64 boot header; --reset-vector selects the x86_64 QEMU -bios form — emits the stage and boots, see below)
#   uefi                                                → UEFI application (PE32+) that firmware loads and enters directly
krc <file.kr> --emit=pe -o out.exe
krc <file.kr> --emit=macho -o out
krc <file.kr> --emit=android -o out
krc <file.kr> -c -o out.o            # shorthand for --emit=obj
krc <file.kr> --emit=lkm -o mod.ko   # Linux loadable kernel module (x86_64 only)
```

### Bare-metal flat images (`--emit=image`)

```
krc prog.kr --arch=arm64 --target=none --emit=image --load-addr=0x40400000 -o prog.img
```

Emits a raw flat binary: there is no container, and nothing is truncated
(`memsz == filesz`). Byte 0 is the first code byte unless something is
prefixed, and this format has **three** such front-of-file forms, never more
than one at a time:

* **arm64, `--image-header`** (below) — the 64-byte Linux `Image` header.
* **x86_64, `--stack-top=`** (below) — a multiboot header.
* **x86_64, `--reset-vector`** (below) — not a header at all but a whole
  16→32→64-bit stage, several hundred bytes of it, with the compiler's
  payload placed *after* it.

They occupy the same slot and cannot combine: `--image-header` is refused on
x86_64, and `--reset-vector` is refused on arm64 and never emits
`--stack-top=`'s multiboot stub. So at most one thing ever precedes code.
The build prints a report line the boot tooling parses:

```
image: arch=arm64 entry=620 filesz=1048 memsz=1048 load=1077936128
```

`entry` is a **file offset**, because a flat image has no `e_entry` and this
report line is the only place it is recorded. Which offset depends on the
flags: the entry function is a live `_start` if the program has one and
`main` otherwise, and with `--stack-top=` (below) `entry` is instead the
offset of the **emitted entry stub**, which is what a loader or a reset
vector must start at. Two forms override that, both to `0`: under
`--image-header` the header's first word branches to the stub, and under
`--reset-vector` the stage *is* the first byte of the file, so in both cases
the address to start at is file offset 0. All values are decimal.

`--load-addr=` is **required, validated, and reported — never embedded**:
x86_64 images are fully RIP-relative and run at any address; arm64 images
are position-independent modulo 4 KiB, so a non-4096-aligned `--load-addr`
is refused on arm64 only. Requires `--target=none` (a hosted OS would put
its syscalls in the blob), an explicit `--arch=x86_64|arm64` (riscv32/xtensa
already own their raw paths via `--freestanding`). `-g` is refused.
**`--reset-vector` is the one exception to "required":** it *refuses*
`--load-addr=` outright and reports `load=0` — see its own section below.

#### Self-booting images (`--stack-top=`)

```
krc prog.kr --arch=x86_64 --target=none --emit=image \
    --load-addr=0x400000 --stack-top=0x90000 -o prog.img
qemu-system-x86_64 -kernel prog.img          # and nothing else
```

Without `--stack-top=` the image has no startup code at all: SP is whatever
reset left behind, so the entry function faults in its own prologue and
something else has to set up the stack and branch to `load + entry`.

`--stack-top=` opts into an emitted entry stub, and the image becomes
self-sufficient:

* **arm64** — `movz`/`movk` the stack top into `x0`, `mov sp, x0`, `bl` the
  entry function, then `b .`. Boot it by parking the reset PC on
  `load + entry`.
* **x86_64** — a multiboot header followed by a 32-bit trampoline that builds
  an identity map of the first 1 GiB, enables PAE + long mode, loads a 64-bit
  GDT, sets RSP and calls the entry function, then `hlt; jmp .`. The header
  carries the load and entry addresses, so `qemu-system-x86_64 -kernel` is
  the whole command line.

The stub's trailing halt is the entry function's **return** site: when the
entry function returns, the machine parks there rather than running off the
end of the image.

The value is refused if it is zero, and validated per arch. **The x86_64 row
is this section's stub only** — `--reset-vector` reads the same flag and
applies a different, wider set of rules to it, listed in its own section
below:

| | accepted `--stack-top=` | accepted `--load-addr=` |
|---|---|---|
| **arm64** | 16-byte aligned, below 2^32 | 4096-aligned (unchanged by this flag) |
| **x86_64** | **at most `0x40000000`**, and **at most `0x1000` or at least `0x4008`** | **`0x4000` … below `0x40000000`** |

Both arches additionally refuse a stack top that starts **inside the image**
(again, this section's stubs only — `--reset-vector` refuses `--load-addr=`,
so there is no load address for this rule to be computed from and it is not
applied there):
the stack grows down, so the first push writes the eight bytes below it, and
those must not be the program's own. The refused band is everything strictly
above `--load-addr` and below `load + filesz + 8` — so a stack top *at* or
below the load address is fine (its first push lands under the image), and
`load + filesz + 8` is the lowest accepted value above it. How far the stack
grows afterwards is not knowable at compile time and is not checked: a stack
placed just above the image will still collide eventually.

The x86_64 numbers all come from the trampoline it emits. Its identity map is
a single 512-entry page directory of 2 MiB pages, so it maps exactly the first
1 GiB — hence the `0x40000000` ceiling on the stack, on the load address, and
on the image's *end* (a load address that fits but whose image runs past 1 GiB
is refused too). The page tables themselves are built at physical
`0x1000–0x4000` and that range is zeroed, so neither the stack nor the image
may live there. The stack bound is stated on the **first push**, not on the
pointer: the trampoline's `call` writes the eight bytes below the stack top, so
`0x1000` is accepted (its push lands at `0xFF8`, under the tables) and `0x4000`
is refused (its push at `0x3FF8` would overwrite the last page-directory entry,
which maps the top 2 MiB of the mapped GiB). `0x4008` is the lowest accepted
value above the tables. Passing `--stack-top=` is what makes the two
`--load-addr` bounds apply: without it no trampoline is emitted and the image is
a blob for a loader of your own, which is subject to none of this.

**Declare the entry function with no parameters.** No stub on any of the three
paths sets up arguments, and none is refused for taking them: `fn main(uint64
argc, uint64 argv) -> uint64` compiles clean into an image and reads whatever
the stub happened to leave in the argument registers. What it reads is *stable
and plausible-looking*, which is worse than garbage — measured under QEMU by
booting an entry that spins iff its first parameter equals a candidate, and for
the reset-vector row by booting one that **prints** its parameters:

* **arm64** — the first parameter is the **stack top**. The stub materialises
  it in `x0` (`movz`/`movk`), copies it to `sp`, and never clobbers `x0`
  before the `bl`, so `argc` is exactly the `--stack-top=` value.
* **x86_64** — the first parameter is **`0x4000`**, the address one past the
  identity-map page tables: the trampoline leaves `%edi` there after filling
  the page directory and does not touch it again before `call *%rax`.
* **x86_64 under `--reset-vector`** — the first parameter is **`0x7000`**, one
  past *that* stage's six pages of tables, for the same reason and with a
  different number. Measured under `qemu-system-x86_64 -bios`, two payloads of
  different sizes, both printing `28672`.

Second and later parameters are true garbage — under `--reset-vector` `%rsi`
came back as the end of the stage's copy source (`0xFFFF05A8` and `0xFFFF06B0`
for those same two payloads), i.e. a value that moves with the program. `@builtin_override fn _start` is
likewise a no-op here: the stub calls the entry function directly, not through
any trampoline an override could replace.

**Nothing zeroes a BSS tail, by design.** The image is never truncated, so
its statics are carried as real zero bytes and there is nothing left for a
zeroing loop to do. Do not assume RAM outside the image is zero — QEMU
zero-fills it, real silicon does not.

#### arm64 boot header (`--image-header`)

```
krc prog.kr --arch=arm64 --target=none --emit=image \
    --load-addr=0x40400000 --stack-top=0x40800000 --image-header -o prog.img
```

`--image-header` prefixes the artifact with the 64-byte arm64 Linux `Image`
header (magic `0x644d5241`), so that a real arm64 boot chain (U-Boot, UEFI
stub, and similar) can recognize and load it, the same way `--stack-top=`
above adds x86_64's multiboot header. That last part is a **design claim
about the format, not a tested one** — read *What this is verified against*
at the end of this section before relying on it. `file(1)` reports the
result as
*"Linux kernel ARM64 boot executable Image, little-endian, 4K pages"*.

The header's first word is a branch to the entry stub, so **the artifact
boots from its first byte**: a loader jumps to the load address and needs to
know nothing else about the layout. `image_size` carries the whole file size,
header included; `text_offset` is 0 and `flags` is `0xA` (little-endian,
4 KB pages, load anywhere).

The header is emitted *before* code generation, so every page-relative
reference is laid out around it. That is why the artifact grows by exactly 64
bytes and not by 64 plus padding, and why a header cannot be bolted onto an
already-emitted image after the fact — the `adrp` page arithmetic would be
64 bytes stale and the image would boot to silence.

Without the flag no byte of the output changes.

`--image-header` requires all three of:

* `--emit=image` — a flat image is the only thing to prefix.
* `--arch=arm64` — the header is arm64's Linux `Image` format; x86_64
  `--emit=image` already has its own front-of-file forms — the multiboot
  header `--stack-top=` adds, and the stage `--reset-vector` adds — so
  `--image-header` there has nothing to attach to.
* `--stack-top=` — a header on a stub-less image validates under `file(1)`
  and is accepted by a loader, but the image has no entry stub to jump to
  and faults instantly. Requiring `--stack-top=` keeps that combination —
  a header making a false claim about the bytes behind it — unrepresentable.

##### What this is verified against — and what it is not

Two oracles exercise the header and no others: `file(1)`, and a real
`qemu-system-aarch64 -M virt -cpu cortex-a57 -kernel <image>` boot in
`tests/target_none/boot_gate.sh` (leg L6), where QEMU is the thing that
parses the 64 bytes and decides both where to place the image and where to
start it. Everything below is a limit of *that evidence*.

* **No real boot chain has run any of this.** No U-Boot `booti`, no EFI stub,
  no Android `boot.img` tooling was available. Nor has anything run on
  hardware: QEMU 8.2.2 on one developer machine is the whole of the boot
  evidence.
* **The header's own boot legs now DO run in CI** — this bullet said they did
  not, and that stopped being true when sub-project C merged. Re-checked at
  E Task 4: `origin/main` is `07e0422`, that tree's `boot_gate.sh` contains
  `L6_kernel_boots`, and GitHub Actions run **30989294535** on that sha
  concluded *success* with both suite jobs (Linux x86_64 and Linux ARM64)
  green. The gate is a counted test inside `tests/run_tests.sh` and the suite
  exits non-zero on any FAIL, so a green suite job on that sha is L5 and L6
  passing on the runners. (The run's log body was no longer retrievable, so
  the per-leg lines are not quoted here — the job conclusions are.)
* **The load-base result is QEMU's behaviour, not the specification's.** L6
  shows the image landing at an address nothing on the command line named,
  and moving when `text_offset` moves. That is QEMU's `load_aarch64_image`
  reading our header — it proves the header *is read*. It does **not** prove
  the header is conformant to the Linux `Image` specification, and nothing
  in this tree does.
* **QEMU does not reject a bad magic.** A corrupted magic still boots and
  still prints, because this compiler's arm64 output is position-independent:
  QEMU silently abandons the header and falls back to its own default offset.
  So no boot *failure* ever witnesses the magic. Its oracles are `file(1)`
  and that shift in load base.
* **Several fields are checked by nothing.** `code1`, `res2`–`res5` are
  written as zero and read by nothing observable. The emitted **`flags` value
  is uncovered too.** `file(1)` reads only bit 0 (endianness) and bits 1–2
  (page size); nothing reads **bit 3**, the physical-placement bit, and
  measuring it in isolation confirms that twice over — `0xA` vs `0x2` and
  `0x8` vs `0x0` each differ in bit 3 alone and each give an identical
  `file(1)` line *and* an identical parked PC. The compiler-side rows in
  `tests/run_tests.sh` assert what was *written*; they cannot assert that
  anything reads it.
* **Whether `text_offset` is legacy is not settled here.** We write
  `text_offset = 0` and declare 2 MiB-relative placement through `flags`
  bit 3, the form current kernel documentation describes. QEMU honours
  `text_offset` *verbatim* (measured: `0x300000` → base `0x40300000`, with a
  +2 MiB bump only below 4 KiB), so it does not treat the field as legacy —
  but whether a modern loader prefers the flags bit, the field, or neither is
  **unverified**, because exactly one loader has ever been tried.
* **The entry stub discards `x0`.** The arm64 boot protocol requires the
  loader to pass the device tree blob's physical address in `x0`. The stub
  `--stack-top=` emits materialises the stack top *in `x0`* before moving it
  to `sp`, so a real loader's FDT pointer is overwritten before any KernRift
  code runs and cannot be recovered. Measured, not inferred: with the stub's
  first three instructions skipped, a plain `qemu -M virt -kernel` boot parks
  with `x0 = 0x44000000`, whose first guest word is `0xd00dfeed` — the FDT
  magic; the same image unpatched parks with `x0 = 0`. Nothing in a KernRift
  image can read a device tree today.
* **`--load-addr=` does not survive a header-parsing loader.** Under
  `-kernel` QEMU chose `0x40200000` regardless of what `--load-addr=` said.
  The value is still required, still validated, and the stack-vs-image
  refusal above is **still computed from it** — so with `--image-header` you
  can be refused for an overlap the real load makes irrelevant, or accepted
  into one it creates. Set it to where you actually expect the image to land
  and treat that refusal as advisory.

#### The reset-vector form (`--reset-vector`)

```
krc prog.kr --target=none --arch=x86_64 --emit=image --reset-vector \
    --stack-top=0x90000 -o bios.bin
qemu-system-x86_64 -bios bios.bin          # and nothing else
```

**Status: the stage is emitted and the artifact boots.** This is no longer
the flag surface only: `--reset-vector` now emits a self-contained
16-bit → 32-bit → 64-bit stage at file offset 0, places the compiler's own
payload after it, zero-fills to exactly 65536 bytes and plants the 3-byte
reset `jmp` at `0xFFF0`. The artifact has been booted with
`qemu-system-x86_64 -bios` on one machine and printed `RPL` followed by its
payload's own computed output. It does
**not claim** real hardware, real firmware, or any BIOS other than QEMU's
`-bios` mapping behaviour.

The build prints a second report line:

```
image: arch=x86_64 entry=0 filesz=65536 memsz=65536 load=0
reset-vector: payoff=304 paylen=1016 kentoff=676 stack=589824
```

`entry=0` is the stage's own first byte — the CPU resets to `CS=f000:IP=fff0`
and the `jmp` there transfers to `CS:0`, so file offset 0 is where execution
begins. `load=0` because `--load-addr=` is refused for this form (below).
The `reset-vector:` line is the layout contract: `payoff` is the payload's
file offset (and therefore the stage's length), `paylen` the number of bytes
copied to physical `0x100000`, `kentoff` the entry function's offset *within*
the payload — so the guest is entered at `0x100000 + kentoff` — and `stack`
the value loaded into `rsp`.

`--reset-vector` is x86_64-only and is **unrelated to `--stack-top=`'s
entry stub above**: it does not reuse, extend, or modify the multiboot
header + long-mode trampoline `--stack-top=` alone opts into, and building
with both present never emits that trampoline. The two stages share no code
and are deliberately different: this one's GDT selector `0x08` is *32-bit*
code (a 16-bit stage has to enter protected mode before it can enter long
mode), and it identity-maps the full 4 GiB rather than 1 GiB, because the
stage itself runs at `0xFFFF0000`. What the two flags share is only the
underlying value — `--reset-vector` reads the `--stack-top=` number for its
own `rsp` — not the stub that number otherwise gates.

Three characters are written to COM1 as the stage advances: `R` once 16-bit
real mode is running at the reset vector, `P` once 32-bit protected mode is
entered, `L` once long mode is. They are not debug leftovers — without them a
fault anywhere in the sequence is an indistinguishable silent reboot.

This form is for `qemu-system-x86_64 -bios`: QEMU maps the file so its last
byte sits at the top of the 32-bit address space and the CPU resets into it
directly, with no loader, no multiboot header, and no `-kernel` convenience
in between. Because of that, the geometry differs from every other
`--emit=image` form in three ways this flag surface already enforces:

* **`--load-addr=` is refused, not merely unnecessary.** A `-bios` reset
  vector has no loader to hand an address to, and measurement backs this up:
  a plain `--emit=image` x86_64 payload is byte-identical whether
  `--load-addr=` says `0x100000` or `0x20000000`. There is nothing for the
  flag to choose here, so it is refused rather than silently ignored.
* **`--stack-top=` is required, with no default — same rule as
  `--stack-top=` itself states, extended to a form that cannot fall back to
  "no stub, whatever SP reset left behind."** The stage sets `esp` and `rsp` from this value; an unset stack means "no value,"
  never "guess one."
* **`--stack-top=` has its own x86_64 range rule, wider than `--stack-top='s
  existing one.** The existing self-boot trampoline (above) keeps its
  identity-map page tables at physical `0x1000`–`0x4000`. The reset-vector
  form's own page tables need more room — `0x1000`–`0x7000`, six pages:
  PML4, PDPT and four page directories — so a
  stack top whose first push (the stack grows down, so the first push writes
  the eight bytes *below* the stack top — same convention as the existing
  rule) would land in that wider band is refused: at most `0x1000`, or at
  least `0x7008`. This bound is checked today, from the flag value alone.
* **`--stack-top=` also has its own, wider ceiling: `0x100000000` (4 GiB),
  not the existing trampoline's `0x40000000` (1 GiB).** The existing
  self-boot trampoline's identity map is a single GiB; the reset-vector
  stage's own map is `PDPT[0..3]`, 2048 x 2 MiB, the full 4 GiB, so a stack
  top at or above that ceiling is refused too — checked from the flag value
  alone, before the stage that ceiling is about is even emitted.

**That 4 GiB ceiling is the *map* bound, and it is not the only bound. The
other one cannot be checked, and exceeding it is a silent reboot loop.**
The page tables say an address is *mapped*; they do not say there is RAM
behind it. The stack has to land in **memory the machine actually has**, and
the compiler has no way to know how much that is — so this is documented
rather than refused. Measured on `qemu-system-x86_64`, same image, same
sentinel payload, varying only `--stack-top` and `-m`:

| `--stack-top` | default RAM (128 MiB) | `-m 4096` |
|---|---|---|
| `0x90000` | `RPL2000000016` | `RPL2000000016` |
| `0x10000000` (256 MiB) | **`RPLRPLRPL…`** | `RPL2000000016` |
| `0x80000000` (2 GiB) | **`RPLRPLRPL…`** | `RPL2000000016` |
| `0xF0000000` | **`RPLRPLRPL…`** | **`RPLRPLRPL…`** (PCI hole) |
| `0x100000` | `RPL`, then dies | `RPL`, then dies (legacy hole) |
| `0xFFFFFFF8` | `RPL`, then hangs | `RPL`, then hangs (inside the image) |

Two things to read off it. First, **the command this section prints —
`qemu-system-x86_64 -bios bios.bin`, and nothing else — is the 128 MiB
column**, so a stack top above about 128 MiB reboots under exactly the
invocation documented here, with no diagnostic from anything. Second, the
symptom is **`RPL` repeating**, not `RP` repeating: `L` *does* print, because
long mode is reached and the map is fine; the fault is the payload's first
push landing on an address with nothing behind it, which triple-faults and
resets the CPU back into the stage. `RPRPRP…` (no `L`) means something else
entirely — a bad map or a bad GDT.

**"Mapped" is not "backed by RAM", and the holes are not all at the top.**
The last three rows are the same hazard in three places: `0xF0000000` is the
PCI hole below 4 GiB, `0xFFFFFFF8` is inside the region `-bios` maps the image
itself into, and `0x100000` is the *low* one — the stack grows down out of
`0x100000` straight into `0xA0000`–`0xFFFFF`, the legacy VGA/option-ROM
window, which is not writable RAM on a PC. `0x100000` is worth calling out
because the payload-overlap refusal below **accepts** it: the first push lands
below the payload, which is all that rule claims, and the address is still
unusable for an unrelated reason. None of the three is refused, for the same
reason the RAM bound is not: which physical addresses are backed by writable
memory is a property of the machine, not of the program. Keep `--stack-top`
inside installed RAM, below `0xA0000`, clear of `0x1000`–`0x7000`, and clear
of the payload at `0x100000`; `0x90000` satisfies all four, which is why it is
the example.

**Refused at flag-parse time, each with its own message:**

| condition | why |
|---|---|
| `--arch` other than `x86_64` | arm64 resets directly into AArch64 state; riscv32/xtensa already have raw paths via `--freestanding` |
| `--target` other than `none` | same rule every `--emit=image` build follows — no hosted OS in a flat image |
| `--emit` other than `image` | the flag selects a form of the flat image and needs one to select |
| `--stack-top=` absent | no default stack, ever |
| `--load-addr=` given | measured meaningless for this form (above) |
| `--stack-top=`'s first push lands in `0x1000`–`0x7000` | this form's own, wider page-table band |
| `--stack-top=` at or above `0x100000000` | this form's own, wider (4 GiB) identity-map ceiling |

**Refused at the end of the build, not at flag-parse time —** two rules, both
needing `paylen`, which does not exist until code generation has run:

* **A payload that will not fit.** The file is exactly 65536 bytes, of which
  the stage takes `payoff` and the reset vector's own window takes the last
  16, so the payload has `65536 - payoff - 16` bytes. The message names
  **both** the payload's actual size and the space available. It never
  truncates: a truncated image boots, prints `RPL`, and then runs half a
  program.
* **`--stack-top=`'s first push landing inside the payload.** The payload is
  copied to physical `0x100000`, so it occupies
  `0x100000 .. 0x100000 + paylen`, and a stack top inside that band means the
  stage's own `call` writes its return address over the program it is about to
  enter. Measured before this was checked: `--stack-top=0x100008` exited 0,
  wrote a valid-looking 65536-byte image, printed `RPL`, and then **wedged
  silently** — no message and no exit code, because `0x100008` is inside the
  4 GiB map, inside installed RAM and clear of the page tables, so no other
  rule saw it.

Both of these, and the `0x1000`–`0x7000` rule in the table above, use the same
convention as `--stack-top=`'s own existing check: they compare the band the
**first push** writes, `[stack_top-8, stack_top)`. How far down the stack
travels afterwards is not knowable at compile time and is not refused — a
stack top eight bytes past the payload's end is accepted and will still
collide once the program's own frames walk down into it (measured:
`--stack-top=0x100400` against a 1016-byte payload boots to `RPL` and dies).

**What a green result claims, and what it does not.** *A reset-vector image
built by `krc` alone reaches 16-bit real mode, 32-bit protected mode and
64-bit long mode, and runs its payload, under QEMU on one machine.* It does
**not claim** real hardware, real firmware, or any BIOS other than QEMU's
`-bios` mapping behaviour — which the whole geometry above depends on. That
bound was written while there was nothing to boot, and it still holds now
that there is.

##### What this is verified against — and what it is not

One oracle exercises this form and no others: a real
`qemu-system-x86_64 -bios <image>` boot in `tests/target_none/boot_gate.sh`
(leg L9) — nine checks, eight boots, every one of them with an observed
negative control. Everything below is a limit of *that evidence*, and each
number names the command that produced it.

* **One emulator, one version, one machine.** QEMU 8.2.2
  (`1:8.2.2+ds-0ubuntu1.17`) on one developer machine is the whole of the
  boot evidence for this flag. Nothing here has run on silicon, and nothing
  here has been loaded by firmware that anyone else wrote.
* **This is the leg where "QEMU only" matters most, not least.** `-bios`
  maps the file so its last byte lands at the top of the 32-bit address
  space — exactly the window a real chipset write-protects, shadow-copies
  into RAM, and hands to a descriptor-driven SPI controller. Getting these
  bytes onto a board is not "the same thing with a different loader": it is
  flashing SPI, which is a separate problem this sub-project does not touch.
  So no real hardware has run this, and no plan for it is implied.
* **The geometry itself is QEMU's behaviour, not a specification.** That the
  file is mapped ending at `0xFFFFFFFF`, that the reset vector therefore sits
  at `filesz - 16`, and that `CS=f000:IP=fff0` reaches it — those are things
  this QEMU does. The stage is *designed around them*. They are not read out
  of a chipset datasheet anywhere in this tree.
* **The 64 KiB size is fixed, and the rule behind it is an inference.**
  Measured on this QEMU, same image padded at the front so the reset vector
  stays last: 32768 B, 65535 B, 66000 B and 98304 B are all **refused**
  (`qemu: could not load PC BIOS`), while 65536 B, 131072 B, 196608 B and
  262144 B all **boot**. Those eight points are the measurement. *"`-bios`
  requires a multiple of 64 KiB"* is the **inference** that fits them — it is
  not quoted from QEMU's source or documentation, and it is not what the
  compiler enforces. The compiler emits exactly 65536, always.
* **`--stack-top`'s real bound is installed guest RAM, and it is unchecked
  and undiagnosable.** The 4 GiB refusal above is the *map* bound. The RAM
  bound is measured in the table earlier in this section, the compiler cannot
  know it, and exceeding it is a **silent reboot loop with no diagnostic from
  anything** — no message, no exit code, just `RPL` repeating. The two
  failure modes are told apart by one letter: a bad map or a bad GDT never
  prints `L`; RAM exhaustion prints `L` and then dies on the payload's first
  push. The same is true of every other *mapped but not backed by writable
  RAM* address — the PCI hole, the legacy `0xA0000`–`0xFFFFF` window, and the
  region `-bios` maps the image into. All are measured in the table earlier in
  this section and none is refused, because the physical memory map belongs to
  the machine and not to the program.
* **The payload-overlap and page-table refusals bound the FIRST push only.**
  Both compare `[stack_top-8, stack_top)`. A stack top clear of both bands
  still collides with the payload once the program's own frames walk down far
  enough, and nothing refuses or diagnoses that — measured,
  `--stack-top=0x100400` against a 1016-byte payload. What the refusals rule
  out is the configuration that is corrupt before a single instruction of the
  program runs, which is the same bound `--stack-top=`'s own
  stack-inside-the-image check has always carried.
* **L9 has run in CI — on x86_64 only.** Until `4390d48` this bullet read "L9
  has never run in CI", which was true while the branch was unpushed. Run
  **31024409854** on `4390d48` concluded *success* with `boot gate: 59 pass,
  0 FAIL, 0 SKIP` on the **Linux x86_64** job, whose test step is **not**
  `continue-on-error` — so all nine L9 legs, including the eight TCG boots,
  are now re-run on every push by a machine that is not the developer's.
  `L9_reset_vector_boots` logged `RPL2000000016` there.
  **What that still does not cover:** every L9 result is QEMU/TCG on a
  GitHub-hosted x86_64 runner. There is no second emulator, no arm64 host for
  this leg (it is x86_64-only by construction), and **no hardware** — see the
  first bullet of this block, which the CI result does not weaken.
* **What is deliberately absent.** No `include_bytes`, no assembly symbol
  references, no settable BIOS size, no arm64 form (arm64 resets straight into
  AArch64 state and needs none of this), no riscv32/xtensa form, and no change
  of any kind to the multiboot path `--stack-top=` alone emits.

#### UEFI applications (`--emit=uefi`)

```
krc app.kr --arch=x86_64 --target=none --emit=uefi -o BOOTX64.EFI
```

A UEFI application is a PE32+ image that the firmware loads, places at an
address of its own choosing, and enters directly. *Places*, not *relocates*:
there is no `.reloc` section and no fixup is ever applied to the image — see
`ImageBase` below.
Unlike `--emit=image` it needs no loader of yours and no
entry stub: firmware enters in long mode with paging on and a stack already
set up, so there is nothing for a trampoline to do. Consequently
`--load-addr=`, `--stack-top=` and `--image-header` are all **refused** with
this mode — they describe a flat image somebody else has to place, and
firmware places this one itself. The build prints a report line:

```
uefi: arch=x86_64 entry=4096 filesz=8192 memsz=8192 hdr=4096
```

`entry` and `hdr` are **file offsets**, decimal, like the `--emit=image`
report's. `hdr` is the size of the header region at the front of the file;
`entry` is the entry function — a live `_start` if the program has one and
`main` otherwise, the same bare-metal rule `--emit=image` uses. Because the
geometry below makes file offset equal RVA, `entry` is also the header's
`AddressOfEntryPoint`, and `filesz` is its `SizeOfImage`.

`filesz` includes **file-alignment padding**: `FileAlignment` is 0x1000, and
a PE section's `SizeOfRawData` is spec-required to be a multiple of it.
Padding to that boundary is a choice, not something firmware forces: an
unaligned `SizeOfRawData`, with the file ending exactly there and nothing
past EOF, is out-of-spec but was **measured to run under both OVMF and
AAVMF**. Padding is kept anyway, for PE-spec conformance and because it lets
`FileAlignment` and `SectionAlignment` share one value instead of two. So a
56-byte program still produces an 8192-byte application. The padding is zero
and is not BSS: the payload carries its zero statics as real bytes, because
firmware zero-fills nothing.

**Required flags, and why each is refused rather than defaulted:**

* `--target=none` — a new emit mode does *not* get a bare-metal target for
  free. Without this flag the resolved OS is the default, `linux`, and the
  application would carry Linux syscalls that firmware does not provide.
* `--arch=x86_64` or `--arch=arm64`, **explicitly** — a PE names the CPU in
  its `Machine` field, so a silently defaulted arch produces an application
  declaring a processor you did not ask for. riscv32 and xtensa are refused
  outright: neither has a `Machine` value here, and both already own a raw
  boot path through `--freestanding`.
* `-g` is refused, as it is for `--emit=image`: the DWARF footer is laid out
  from an ELF geometry this container does not have.

`--target=android` is refused too, and for a reason worth knowing: that flag
does not only choose an OS, it *also* forces `--emit=android`, so combining
the two would otherwise have silently emitted an Android ELF.

**The header region is 4096 bytes and that is a correctness constraint, not
a formatting choice.** arm64 `adrp` page arithmetic is baked during code
generation from the *file* offset of each datum, while a PE loader places the
payload at `SectionRVA + (file offset − PointerToRawData)`. The two agree on
page boundaries only when that difference is a multiple of 4096. This
compiler takes the strongest form: `PointerToRawData == SectionRVA == 0x1000`,
so file offset equals RVA for every byte in the artifact. A conventional
0x200 file alignment with the section at RVA 0x1000 gives a difference of
0xE00 instead — and the resulting image loads, is accepted by `file(1)`, and
faults with no diagnostic. x86_64 output is RIP-relative and immune to this,
and is held to the same geometry anyway.

**The header, and the fields that are load-bearing.** One section, `.text`,
carrying code and statics together, with characteristics `0xE0000020` —
`CODE|EXECUTE|READ|`**`WRITE`**. The write bit is arm64's: measured under
AAVMF, a read-only code section loads and starts, then takes a *Synchronous
Exception* on the first store to a static. x86_64 does not enforce it.

* `Subsystem` is **10**, `EFI_APPLICATION`. Subsystems 0, 3, 11, 12 and 13 are
  all refused by the boot manager — including 11 and 12, which are perfectly
  valid EFI subsystems. It is also the field `file(1)` keys its
  *"(EFI application)"* phrase on.
* `ImageBase` is 0 and `IMAGE_FILE_RELOCS_STRIPPED` is **never** set, so
  firmware places the image where it likes. There is no `.reloc` section and
  none is needed: the payload is position-independent.
* There is **no import directory**. That is the whole difference between this
  and `--emit=pe`, whose entry instruction calls through a `kernel32` import
  slot only the Windows loader fills.
* `SizeOfOptionalHeader` is 240 with 16 data directories. What firmware
  actually validates is the *consistency* `SizeOfOptionalHeader − 112 ==
  NumberOfRvaAndSizes × 8`, not the count.

**Status: this has booted.** Sub-project D Task 2 emits the header, and the
resulting applications were run under **QEMU's OVMF 2024.02 firmware on q35
and AAVMF 2024.02 on `virt`** — emulated, not real hardware or vendor
firmware, and with no Secure Boot — where each printed its sentinel and
returned control to the boot manager. An application that returns hands
control back and the
firmware then runs its setup UI; that is a normal return, not a failure.

**`make test` re-runs those boots.** Task 3 put them in
`tests/target_none/boot_gate.sh` as legs **L7** (x86_64/OVMF, ten checks) and
**L8** (arm64/AAVMF, four), so the evidence is a counted test rather than prose
in a report. Both legs boot the pristine application off a FAT ESP as
`EFI/BOOT/BOOTX64.EFI` / `BOOTAA64.EFI` and then boot deliberately corrupted
copies of it.

**L7** carries the header-rejection set: `Subsystem 3`, `Magic 0x10b`, a wrong
`Machine`, an inconsistent `NumberOfRvaAndSizes` and an undersized `SizeOfImage`
are all **refused**; an undersized `VirtualSize` and a zero `SizeOfRawData`
**load and then fault**; and an `AddressOfEntryPoint` moved to the section start
**loads, runs and says nothing**. **L8** carries three of those — `Subsystem 3`
and `VirtualSize`, plus the case that exists only on arm64: a read-only code
section, which prints both markers and *then* aborts on its first store (x86_64
runs the same artifact unharmed, which is L7's tenth check).

The firmware images (Debian/Ubuntu `ovmf` and `qemu-efi-aarch64`, or the
equivalent paths on other distributions) are a hard dependency of those two
legs. Absence is a **counted failure** naming every path tried — never a silent
pass — though the checks downstream of it in the same leg are then reported as
SKIP rather than run: a missing OVMF gives 1 FAIL and 9 SKIP on L7, a missing
AAVMF 1 FAIL and 3 SKIP on L8.

##### Limits, as measured

Everything in this section was measured on **one machine**, with **edk2
2024.02** (Ubuntu `ovmf` / `qemu-efi-aarch64` 2024.02-2ubuntu0.8) under **QEMU
8.2.2**, Secure Boot off unless stated. No real hardware and no vendor firmware
has run any of it. Where a field is described as not being checked, that is a
statement about *this* build: **"not guaranteed to be caught" is what was
observed, and it never means "safe to get wrong."**

**Secure Boot rejects this output. That is a property of the artifact, not a
gap in the tooling.** The applications are unsigned and nothing here signs
them. Measured with the *identical* file — one variable changed, the firmware
pair:

| what booted | firmware | result |
|---|---|---|
| the x86_64 sentinel | `OVMF_CODE_4M.fd` + `OVMF_VARS_4M.fd` | **ran** — both sentinel markers on COM1 |
| the same bytes | `OVMF_CODE_4M.ms.fd` + `OVMF_VARS_4M.ms.fd` (Microsoft keys) | `BdsDxe: failed to load Boot0001 …: **Access Denied**` — nothing of ours ran |
| Microsoft-signed `shimx64.efi.dualsigned` | that same MS-key firmware | `loading` → **`starting`** — so the firmware does boot an image it trusts |
| the arm64 sentinel | `AAVMF_CODE.no-secboot.fd` | **ran** — both markers on the PL011 |
| the same bytes | `AAVMF_CODE.ms.fd` + `AAVMF_VARS.ms.fd` | `failed to load Boot0001 …: **Access Denied**` |

The third row is the control that makes the second mean something: without it,
`Access Denied` could have been the ESP rather than the signature. Note also
that `Access Denied` is a *different* status from the `Not Found` an empty or
misnamed ESP produces, so this rejection is a positive observation and not an
absence. Signing is out of scope for this mode; a signed application would need
a key, an `sbsign`-equivalent, and a `.reloc`-free image the signer accepts —
none of which exist here.

**Boot services are out of scope, and a codegen limit blocks them.** These
applications never touch the `EFI_SYSTEM_TABLE`: they take the firmware's
entry, drive a UART directly and return. `efi_main(ImageHandle, SystemTable)`
is not implemented, and calling a boot service would go through `call_ptr`,
which **silently drops every argument past the sixth** — `src/ir.kr:3151`
declares `uint64[6] cp_arg_vregs` and `:3155` stops the lowering loop at
`cp_count < 6`, with no diagnostic and exit 0. Measured on this tree: a
seven-parameter callee reached through
`call_ptr(p, 1, 2, 4, 8, 16, 32, 7)` returns **63** on x86_64 (the seventh
argument was never passed) and **127** on arm64 (never passed either — the
callee read an uninitialised `x6`, which held `64` from an earlier probe). The
legacy backend does the same thing: 63. That cap has to be fixed before boot
services are possible, it is **codegen work rather than container work**, and
it is not claimed to be the only thing in the way.

**Also deliberately absent:** `--emit=uefi` for riscv32 or xtensa (neither has
a PE `Machine` value here, and both already own a raw boot path through
`--freestanding`), and any new `--target=` value — a UEFI application is
`--target=none` like every other bare-metal artifact.

```

# Codegen backend & optimization
krc <file.kr> --arch=arm64           # default: IR (not SSA -- optimizer + regalloc)
krc --legacy --arch=arm64 <file.kr>  # legacy direct-walking codegen
krc --ir <file.kr>                   # force IR even where a recipe falls back to legacy
krc --no-coalesce <file.kr>          # disable Briggs/George copy coalescing (default on)
krc --coalesce <file.kr>             # ...and its explicit positive form (the default)
krc --no-check-types <file.kr>       # disable the type checker (default on)
krc --check-types <file.kr>          # ...and its explicit positive form (the default)
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
krc --emit=ir <file.kr>              # dump the IR per function, not SSA
krc --version                        # print the compiler version
krc --help                           # usage info
```

For debugging — `-g` DWARF in gdb, the `--debug` trap table, and the
`--O0` → `--no-coalesce` → `--legacy` miscompile bisection ladder — see
[docs/DEBUGGING.md](DEBUGGING.md).

`--debug` emits array bounds checks on **all four** backend/arch
configurations — the IR backend on x86_64 and arm64, and the legacy backend
on x86_64 and arm64. Earlier versions **refused** `--debug` on every command
line that would reach legacy arm64 codegen, because that backend had no
bounds-check codegen and would otherwise have compiled clean while silently
shipping `--debug` unmet. `codegen_aarch64.kr` now emits the check at the
same two subscript sites the legacy x86_64 backend uses, so the refusal is
gone: `--legacy --arch=arm64 --debug`, `--arch=arm64 --emit=obj --debug`,
`--emit=android --legacy --debug`, and a fat (`.krbo`) build carrying an
arm64 slice (including plain `krc prog.kr --legacy --debug` with no
`--arch`) all build again, and all check. Legacy arm64's
overflow/null-pointer/divide-by-zero `--debug` checks, which that refusal
also made unreachable, work on those command lines again too. See
[docs/DEBUGGING.md](DEBUGGING.md) for the per-backend table.

`--debug` is still refused with `--target=none`, for an unrelated reason: a
failed check has no kernel to exit to on bare metal.

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

All ten `--emit=` modes, and the two formats that are reached by other flags:

| Format | Produced by | Use |
|---|---|---|
| ARX container | `--emit=arx` | A program ApexRift loads from its own filesystem (hosted; the OS supplies the stack) |
| `.krbo` fat binary | default (no `--arch`) | Cross-platform distribution — `kr` picks the right slice |
| ELF executable | `--emit=elfexe` (the default), `--arch=x86_64` / `--arch=arm64` on Linux | Native Linux binary |
| ELF relocatable | `--emit=obj` (or `-c`) | Link into an external object (`.o`) |
| Mach-O | `--emit=macho` | macOS executable (x86_64 or arm64) |
| PE | `--emit=pe` | Windows `.exe` |
| Android PIE ELF | `--emit=android` | Android ARM64 (default) or x86_64 (`--arch=x86_64`) |
| Loadable kernel module | `--emit=lkm` | Linux `.ko`, x86_64 only — see [LKM.md](LKM.md) |
| Assembly listing | `--emit=asm` | Human-readable disassembly with labels |
| IR dump | `--emit=ir` | Text on **stdout**; no file is written |
| Raw flat image | `--emit=image` | Bare metal, no container — needs `--target=none` |
| UEFI application | `--emit=uefi` | PE32+ image firmware loads and enters — needs `--target=none` |
| ESP32 flash image | `--arch=xtensa --freestanding --target=esp32` | Not an `--emit=` mode: the machine target selects it |

The last **three** have no place on a hosted OS, and the two bare-metal
`--emit=` modes **require** `--target=none` rather than merely accepting it.
`--emit=ir` is not one of them: it is a text dump and runs perfectly well
hosted (`krc --arch=x86_64 --target=linux --emit=ir prog.kr` exits 0 and
prints the IR).

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
