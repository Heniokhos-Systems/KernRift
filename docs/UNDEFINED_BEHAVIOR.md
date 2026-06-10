# KernRift — Defined vs Undefined Behavior

This table lists every operation whose semantics a systems programmer might
reasonably want to rely on, and says whether KernRift gives it a defined
meaning, leaves it unspecified, or treats it as undefined.

- **Defined** — the compiler guarantees this behavior across all supported
  targets. Safe to rely on.
- **Implementation-defined** — the behavior is consistent within a target
  but may differ between x86_64, AArch64, Linux, macOS, Windows, Android.
- **Unspecified** — the compiler picks one of several reasonable behaviors.
  Don't rely on which one.
- **Undefined** — the program is invalid. The compiler makes no promise —
  including that "nothing happens." Do not write code that depends on it.

The tier table is the canonical reference; the notes beneath explain the
reasoning for anything non-obvious.

## Integer arithmetic

| Operation                               | Status   | Notes |
|-----------------------------------------|----------|-------|
| `u64` / `u32` / `u16` / `u8` add / sub / mul overflow | Defined | Two's-complement wrap in all modes. The default IR backend emits no overflow checks even under `--debug`; the `--legacy` backend's `--debug` add/sub guard tests the *signed*-overflow flag (`jno` / `b.vc`), so unsigned carry never traps. |
| `i64` / `i32` / `i16` / `i8`  add / sub / mul overflow | Defined in release; trap under `--legacy --debug` | Two's-complement wrap in release. Signed add/sub overflow traps with `exit(1)` only on the legacy backend under `--debug`; the default IR backend wraps in all modes. |
| Divide / modulo by zero                 | **Undefined** | x86 raises `#DE` (SIGFPE); ARM64 returns 0 for both `udiv` and `sdiv` (ARMv8 division never traps). Under `--debug`, the ARM64 IR backend and the legacy backend (both arches) emit an explicit `exit(1)` guard; the x86_64 IR backend has no check (you get the hardware SIGFPE). |
| Divide `INT_MIN / -1`                   | **Undefined** | x86 traps; ARM64 produces `INT_MIN`. |
| Shift by amount `>= bit-width`          | **Undefined** | x86 masks the count mod 64 / 32; ARM64 masks mod 64 / 32. Results differ. |
| Shift by negative amount                | **Undefined** | The count is treated as u64, so "negative" means a huge positive shift. |
| Signed right-shift of negative          | Defined  | Arithmetic shift (sign-extended). |
| Integer literal larger than its type    | Defined  | Truncated to the destination type at codegen. No diagnostic. |

## Floating-point

| Operation                               | Status   | Notes |
|-----------------------------------------|----------|-------|
| IEEE-754 round-to-nearest-even          | Defined  | Default rounding mode; not switched. |
| NaN / Inf / denormal                    | Defined  | Produced and propagated per IEEE-754. |
| f64 → i64 conversion overflow           | Implementation-defined | x86 produces `0x8000000000000000`; ARM64 saturates. |
| Division by zero (f32/f64)              | Defined  | Produces ±Inf or NaN per IEEE-754. No trap. |

## Memory access

| Operation                               | Status   | Notes |
|-----------------------------------------|----------|-------|
| `load8` / `load16` / `load32` / `load64` with valid address | Defined | Little-endian on all targets. |
| Unaligned load / store (non-atomic)     | Defined  | Both x86 and ARMv8 permit; a few microbenchmarks pay a penalty. |
| Unaligned atomic load / store           | **Undefined** | ARMv8 traps. x86 works but is not portable. |
| Load / store of an invalid pointer      | **Undefined** | No bounds tracking. Typically SIGSEGV. |
| Array indexing out-of-bounds            | **Undefined** in release; trap under `--debug` | Compile with `--debug` to turn every indexed access of a compile-time-sized array (stack or static) into a bounds check that `exit(1)`s on violation. Release builds elide the check. |
| Use-after-free (`dealloc` then access)  | **Undefined** | The backing allocator is `mmap` / `HeapAlloc`; behavior varies. |
| Double `dealloc`                        | **Undefined** | Allocator-dependent. |
| Read of an uninitialized stack slot     | Unspecified | Whatever value happens to be on the stack. Not cleared by prologue. |
| Read of an uninitialized `static`       | Defined  | Zero-initialized by the loader (BSS). |
| `memcpy` with overlapping src/dst       | **Undefined** | Use `memmove` from `std/mem.kr` — it picks the right scan direction. |
| `memcpy` / `memset` with len 0          | Defined  | No-op even if the pointer is invalid. |
| Store of `bool` value other than 0/1    | **Undefined** | Only `true` (1) and `false` (0) are valid bit patterns. |

## Pointers

| Operation                               | Status   | Notes |
|-----------------------------------------|----------|-------|
| Pointer arithmetic (`ptr + offset`)     | Defined  | Byte-offset arithmetic; no type scaling. |
| Comparing pointers from different allocations | Defined | Raw u64 comparison — always well-defined. |
| Null pointer dereference (`load/store` at 0) | **Undefined** | Typically SIGSEGV on hosted targets; may be valid MMIO in freestanding. |
| Dangling pointer comparison             | Defined  | The u64 value remains. Dereferencing it is UB. |
| `unsafe { *(p as TYPE) }` outside an allocation | **Undefined** | Same as a raw deref. |

## Concurrency

| Operation                               | Status   | Notes |
|-----------------------------------------|----------|-------|
| `atomic_load` / `atomic_store` (aligned, same size) | Defined | Sequential consistency on both x86 and ARM64 (DMB ISH on ARM, `lock` / `mfence` on x86). |
| `atomic_cas` success path               | Defined  | Returns 1 on success, 0 on failure. Out-param always written with the current value. |
| `atomic_add` / `sub` / `and` / `or` / `xor` | Defined | Return the previous value. Sequentially consistent. |
| Data race (non-atomic concurrent access) | **Undefined** | Torn reads / writes observable. |
| `dmb()` / `dsb()` / `isb()`              | Defined  | Emit the corresponding ARMv8 barrier; no-op on x86. |
| `volatile` load / store                 | Defined  | Not hoisted, not fused, not reordered across other volatiles. No implicit fence — pair with `dmb/dsb/isb` for cross-CPU visibility. |

## Control flow

| Operation                               | Status   | Notes |
|-----------------------------------------|----------|-------|
| Calling a function pointer of wrong signature | **Undefined** | ABI mismatch — stack / regs trashed. |
| Missing `return` from a non-void function | Unspecified | The caller reads whatever register the ABI uses for the return value (usually garbage). |
| Calling a `@noreturn` function that returns | **Undefined** | Caller's frame is not restored. |
| Reaching `exit(code)`                   | Defined  | `code` is masked to 8 bits by the OS. |
| Infinite loop with no I/O               | Defined  | Not optimized away — KernRift has no "infinite loop without side-effects" UB rule. |

## Types

| Operation                               | Status   | Notes |
|-----------------------------------------|----------|-------|
| `bool` holding a value other than 0 / 1 | **Undefined** | The parser / sema accept only `true` / `false` / comparisons. `unsafe` can break this. |
| `char` holding a value outside 0..=255  | **Undefined** | Codegen narrows on store; `unsafe` can violate the invariant. |
| Enum value not in the declared set      | Defined  | Enums are plain `u64`. No tag-exhaustiveness check. |
| Struct field access via wrong struct type | **Undefined** | The compiler trusts the declared type. Reinterpretation via `unsafe` is permitted. |

## Program lifetime

| Operation                               | Status   | Notes |
|-----------------------------------------|----------|-------|
| Recursion                               | Defined  | Limited only by stack size. No tail-call elimination. |
| Stack overflow                          | Unspecified | Platform-dependent — usually SIGSEGV on the guard page. |
| Allocator exhaustion                    | Defined  | `alloc` returns 0. Callers must check. |
| `static` array initializer              | Defined  | Zero-initialized. Non-literal initializers are silently ignored (tracked as issue #53). |

## Optimizer guarantees

The IR optimizer (`--O1`, default) performs:

- **Constant folding** — pure arithmetic on compile-time constants.
- **DCE** — dead store and dead value elimination, but only for ops in the
  pure set (see `docs/IR_REFERENCE.md`).
- **CSE** — common subexpression elimination for pure ops within a block.
- **Copy propagation / value numbering** within a basic block.

The optimizer is **conservative about side-effects**: any op whose
side-effect flag is set (loads, stores, calls, atomics, volatile, asm,
barriers) is never moved, merged, or deleted. Reordering of two side-effect
ops relative to each other is not performed.

What the optimizer does **not** do:

- No inlining across function boundaries.
- No loop unrolling or vectorization.
- No alias analysis — two loads from different pointers are not assumed
  to be independent.
- No "infinite-loop assumes progress" rule (see above).

## Strictness summary

- Strong: `bool` / `char` / `i*` / `u*` / `f*` are distinct at sema level;
  implicit conversions are limited and explicit casts are required between
  signed and unsigned.
- Weak: all pointer operations, everything behind `unsafe` / `asm`,
  everything that touches memory at a raw address.

The boundary between the two is the `unsafe` / `asm` / `volatile` keyword.
Any file that never uses those three can only invoke UB through:
- divide-by-zero,
- out-of-range shift count,
- array indexing out of bounds,
- memory-exhausting recursion,
- missing return from a non-void function.

Every other source of UB in this document requires at least one `unsafe`
block.

## Roadmap

Items tracked against the UB surface:

- #53 — `static T x = expr` silently drops non-literal initializers.
- Bounds-checked slice indexing (opt-in `--safe` mode): not started; on
  the roadmap. Compile-time-sized array indexing already traps under
  `--debug` (both stack `T[N] name` and `static T[N] name`).
- Dedicated `--check=signed-overflow` flag: not started. Today overflow
  trapping exists only on the legacy backend under `--debug`, and its
  add/sub guard (`jno`/`b.vc`) catches signed overflow only — unsigned
  carry wraps silently. The default IR backend emits no overflow checks.
