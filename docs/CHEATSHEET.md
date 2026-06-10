# KernRift Cheatsheet

One-page reference. Every snippet here compiles with the current `krc`.

Build & run:

```sh
krc hello.kr -o hello.krbo   # default: fat binary, all 8 targets
kr hello.krbo                # run it (extracts matching slice)

krc --arch=x86_64 hello.kr -o hello   # single native ELF
krc check hello.kr                     # semantic check only
krc lc hello.kr                        # Living Compiler report
```

## Hello world

```kr
fn main() {
    println_str("Hello, World!")
    exit(0)
}
```

## Types

```kr
u8  u16  u32  u64        // unsigned (aliases)
i8  i16  i32  i64        // signed   (aliases)
uint8 .. uint64          // long unsigned forms
int8  .. int64           // long signed forms
f32  f64                 // floats
```

## Variables & functions

```kr
fn add(u64 a, u64 b) -> u64 {
    u64 sum = a + b      // explicit type
    let doubled = sum * 2  // `let` infers the type from the RHS (here u64)
    return doubled
}

fn greet() {             // no return type = returns nothing
    println_str("hi")
}
```

`let name = expr` infers a local's type from its initializer (which is
required). Use it for scalars/calls/arithmetic; keep explicit types for
struct values and for parameters/fields/statics.

## Control flow

```kr
// if / else if / else  — chains of any length return on all paths
fn grade(u64 x) -> u64 {
    if x > 90 { return 4 }
    else if x > 80 { return 3 }
    else if x > 70 { return 2 }
    else { return 1 }
}

// while, break, continue
fn sum_to(u64 n) -> u64 {
    u64 i = 0
    u64 s = 0
    while i < n {
        i = i + 1
        if i == 3 { continue }
        if i > 6  { break }
        s = s + i
    }
    return s
}

// for over a range  (0..5 = 0,1,2,3,4)
fn main() {
    u64 s = 0
    for i in 0..5 { s = s + i }
    exit(s)
}
```

Logical operators: `&&`, `||`, `!`. Comparisons: `==  !=  <  <=  >  >=`.

```kr
// ternary: cond ? then : else  (lowest precedence, right-associative)
fn main() {
    u64 x = 5
    u64 y = x > 9 ? 3 : x > 4 ? 2 : 1   // → 2
    exit(y)
}
```

```kr
// match: top-to-bottom; `_` is the default; comma-lists and ranges allowed.
// Arm bodies are a block or one bare statement; `match` also works as a value.
fn classify(u64 c) -> u64 {
    return match c {
        0          => 0          // exact
        1, 2, 3    => 1          // any of these
        4..=9      => 2          // inclusive range (IR backend)
        _          => 9          // default
    }
}

fn main() {
    match classify(7) {
        2 => exit(2)             // bare statement arm (no braces)
        _ => exit(0)
    }
}
```

## Compound assignment

```kr
fn main() {
    u64 x = 10
    x += 5      // also -= and the other arithmetic compounds
    x -= 2
    exit(x)
}
```

## Structs & methods

```kr
struct Point { u64 x; u64 y }

fn Point.sum(Point self) -> u64 {
    return self.x + self.y
}

fn main() {
    Point p = Point { x: 3, y: 4 }
    exit(p.sum())            // 7
}
```

## Arrays & slices

```kr
static u8[4] buf            // static fixed array

fn total([u8] xs) -> u64 {  // slice parameter; .len is the caller-passed length
    u64 s = 0
    u64 i = 0
    while i < xs.len {
        s = s + xs[i]       // slice indexing is byte-addressed
        i = i + 1
    }
    return s
}
```

Slices are byte-addressed: `xs[i]` reads the byte at `xs + i`. For wider
elements use the load builtins — e.g. `load64(xs + i * 8)` for `[u64]` data.

## Pointers — load / store

```kr
fn main() {
    u64 p = alloc(8)        // heap bytes
    store64(p, 42)          // store8/16/32/64
    exit(load64(p))         // load8/16/32/64
}
```

Volatile variants for MMIO: `vload8/16/32/64`, `vstore8/16/32/64`.

## Device blocks (typed MMIO)

```kr
device UART at 0x10000000 {
    DATA at 0 : u32 rw
    STAT at 4 : u32 rw
}
```

## Atomics

```kr
fn main() {
    u64 p = alloc(8)
    atomic_store(p, 5)
    exit(atomic_load(p))    // also atomic_cas, atomic_add/sub/and/or/xor
}
```

## Bitfields

```kr
fn main() {
    u64 v = 0
    v = bit_set(v, 2)       // bit_get / bit_set / bit_clear / bit_range / bit_insert
    exit(bit_get(v, 2))     // 1
}
```

## Signed comparisons

```kr
fn main() {
    i64 a = 0 - 3
    if a < 0 { exit(1) }    // `<` is signed when an operand is i8..i64;
    exit(0)                 // signed_lt/gt/le/ge force signed on u64 bits
}
```

## Annotations

```kr
@export            fn api() { }          // keep symbol in output
@noreturn          fn panic() { exit(1) }
@naked @section("name")  // also available
```

## Strings & output

```kr
print_str("no newline")
println_str("with newline")
```

## Comments

```kr
// line comment
/* block comment */
```
