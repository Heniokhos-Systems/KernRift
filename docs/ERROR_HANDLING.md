# Error Handling Convention

KernRift has no `Result<T, E>` sum type, no exceptions, and no panic.
Every operation that can fail communicates failure through its return
value or an out-parameter. This document picks **one canonical pattern
per shape of failure** so the standard library, example code, and every
future stdlib addition stay consistent.

The three patterns below cover every error-returning function in the
stdlib. They were settled at v2.8.14, when `std/` had 39 modules; it now has
52, and the conventions are unchanged — a new module picks one of these three
rather than inventing a fourth.

---

## Pattern 1 — "absent" sentinel for searches / lookups

A function that looks something up and might not find it returns the
all-ones value `0xFFFFFFFFFFFFFFFF` on miss.

```kr
u64 idx = str_index_of(haystack, "needle")
if idx == 0xFFFFFFFFFFFFFFFF { println("not found"); exit(1) }
// idx is a valid offset here
```

**Why all-ones:** it's `u64(-1)` if you treat the word as signed, and
it's also what `0xFFFF...` returns from the kernel for many negative
syscall errnos, which makes the pattern composable with `syscall_raw`
results. Zero is never the sentinel because zero is a legitimate index
/ offset / pointer value in many contexts.

**Helpers in `std/string.kr`:**

| Helper | Value | Semantics |
|--------|-------|-----------|
| `opt_none() -> u64`        | `0xFFFFFFFFFFFFFFFF` | the sentinel |
| `opt_some(u64 v) -> u64`   | `v` (with assertion `v != sentinel`) | wrap a value |
| `opt_is_some(u64 v) -> u64` | `1` if not the sentinel, else `0` | check |
| `opt_unwrap(u64 v) -> u64` | `v` or `exit(1)` | extract |

**Functions in the stdlib that use it today:**

| Function | Module | On miss |
|----------|--------|---------|
| `str_find_byte(s, b)`   | `std/string.kr` | `0xFFFFFFFFFFFFFFFF` |
| `str_index_of(s, needle)` | `std/string.kr` | `0xFFFFFFFFFFFFFFFF` |
| `static_lookup(tok)` *(compiler internal)* | `src/codegen.kr` | `0xFFFFFFFF` (note: 32-bit here) |

---

## Pattern 2 — kernel-style negative return for syscalls / I/O

Anything that talks to the kernel (file descriptors, `mmap`, `execve`,
etc.) follows the Linux syscall convention: on success the return is
`>= 0`; on failure it's `-errno` in two's complement (visible as a very
large `u64` in the range `0xFFFFFFFFFFFFF000..0xFFFFFFFFFFFFFFFF`).

```kr
u64 fd = file_open(path, 0)
if fd > 0xFFFFFFFFFFFFF000 {
    // fd is actually -errno; useful for diagnostics but mostly "it failed"
    write(2, "open failed\n", 12)
    exit(1)
}
// fd is safe to use
```

The guard threshold `0xFFFFFFFFFFFFF000` is stable on every target we
support because errno values are always < 4096 (the largest legitimate
errno on Linux is EHWPOISON = 133). The fat-binary runner `kr` uses
exactly this check for `execve` failures.

**Helpers in `std/io.kr`** *(added in v2.8.14)*:

| Helper | Semantics |
|--------|-----------|
| `is_errno(u64 r) -> u64` | `1` if `r > 0xFFFFFFFFFFFFF000`, else `0` |
| `get_errno(u64 r) -> u64` | returns `-r` (positive errno) if `is_errno(r)`, else `0` |

---

## Pattern 3 — boolean success flag for operations with no naturally bad value

When a function can't return a sentinel inside its normal value range
(because the value range already covers all `u64`), take an
out-parameter for the result and return `1` for success / `0` for
failure:

```kr
u64[1] out
u64 ok = parse_config_u64(line, out)
if ok == 0 { println("bad line"); exit(1) }
u64 v = load64(out)
```

`load64` is the spelling to use. The older `unsafe { *(out as uint64) -> v }`
still compiles and still means the same thing, but the load/store built-ins are
what `living.kr` migrates that form towards, and they need no `unsafe` block.

This matches how `atomic_cas` already works today: it returns `1` on
swap, `0` on mismatch, and the next-value read is separate.

---

## When to use which pattern

| Your function... | Use |
|------------------|-----|
| returns an index / offset into an array | Pattern 1 (`opt_*`) |
| returns a pointer that might be null | Pattern 1 — zero is the sentinel for pointers |
| wraps a syscall / file descriptor | Pattern 2 (`is_errno`) |
| returns a `u64` where every value is meaningful | Pattern 3 (boolean + out-param) |
| returns a float where NaN is already "no answer" | return NaN (standard IEEE semantics) |
| can't fail at all | no sentinel; just return the value |

## What KernRift does NOT have, and the pragmatic substitute

- **No `Option<T>` sum type** — use Pattern 1 with `opt_*` helpers. The
  discipline is: *by the type of `T`, you know whether a particular
  sentinel is reachable as a real value*. For `u64` offsets, indexes,
  byte-counts, the all-ones pattern is out of range. For arbitrary
  `u64` values use Pattern 3.
- **No `Result<T, E>` sum type** — Pattern 2 with `is_errno` gives you
  the same information. If your function needs richer error context,
  return `1` / `0` and leave the details in a caller-supplied error
  buffer.
- **No exceptions** — `exit(n)` terminates. Fatal paths (out-of-memory,
  broken invariants) call `exit(1)` with a `write(2, …)` diagnostic.
  Never panic silently; never swallow errors.

## Why this matters

Without a pattern, every stdlib addition picks its own convention — some
return 0 on failure (ambiguous because 0 is a legitimate index), some
return -1 (ambiguous because -1 as `u64` is `0xFF..FF` and looks like a
pointer), some set a global `errno` (breaks thread-safety). Locking down
three patterns means:

- `import "std/string.kr"` and `import "std/io.kr"` compose predictably.
- Reading any stdlib function's signature tells you which check to
  write at the call site.
- A new contributor picking up a function knows which pattern to apply
  without reading five existing ones first.

## Historical note

Before v2.8.14 this convention was implicit — `str_find_byte` and
`str_index_of` both used Pattern 1, but there was no written rule and
no helper like `opt_is_some`. Future stdlib additions that introduce a
new failure mode should prefer an existing pattern before inventing a
fourth.
