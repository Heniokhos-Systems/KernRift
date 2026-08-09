# KernRift Effect & Capability System

Design and current implementation of the four annotation-driven analysis
passes in `src/analysis.kr`:

1. **Context** (`@ctx`) — which execution mode a function is legal in
   (task / IRQ / NMI).
2. **Effects** (`@eff`) — what an operation is allowed to do
   (I/O, allocate, acquire a lock).
3. **Locks** (`@acquires` / `@releases`) — deadlock detection via a
   lock-order graph.
4. **Capabilities** (`@caps`) — coarse-grained permission tags.

The passes are run in order by `run_analysis` and each emits its own
diagnostics. They are advisory today — the compiler does not *reject*
programs that violate them; it prints errors and continues. The
ambition is to tighten this at 1.0.

This document supersedes the one-line note in `ARCHITECTURE.md` that
mentioned "ctx, eff, lock, caps, critical" as passes with no further
explanation.

---

## 1. Context hierarchy

### Rationale

A freestanding kernel runs code in three distinct contexts:

- **Task** — ordinary scheduled code, can block, can alloc.
- **IRQ** — servicing a hardware interrupt, must not block, must not
  re-enable IRQs until it returns.
- **NMI** — non-maskable interrupts, even stricter than IRQ: must not
  touch any data that a normal IRQ handler might be holding.

Calling the wrong direction (IRQ code calling into a task-only API,
say `mutex_lock`) is a **classic kernel bug** that is invisible in C
and surfaces only as sporadic deadlocks. The `@ctx` annotation catches
it at analysis time.

### Annotation

```kr
@ctx(nmi)
fn nmi_entry() { /* ... */ }

@ctx(irq)
fn timer_irq() { /* ... */ }

@ctx(task)
fn main() { /* ... */ }

// Unannotated functions default to ctx=any.
```

Valid values: `any` (= 0, the default), `task` (1), `irq` (2), `nmi`
(3). Ordered most-permissive to most-restrictive.

### Rule

A function with context `C` may only call functions with context `C`
or broader. Expressed numerically:

```
caller_ctx >= callee_ctx  → legal
caller_ctx <  callee_ctx  → error: "caller's context is stricter"
```

Concretely:
- An `@ctx(irq)` function calling an `@ctx(any)` helper: fine.
- An `@ctx(irq)` function calling an `@ctx(task)` helper: **error**
  (the task function may block, and we're in IRQ).
- An `@ctx(task)` function calling an `@ctx(irq)` helper: fine (the
  helper is more restrictive than us, so it doesn't do anything we
  can't).

### Implementation

`check_ctx` walks each function's body. On every `Call` node it looks
up the callee's `@ctx`, compares to the caller's `@ctx`, and emits a
diagnostic on violation.

Current limitations:
- Indirect calls (`call_ptr`) are not tracked — the callee's context
  is unknown at analysis time.
- No transitive inference. If `foo()` calls `bar()` which calls an
  `@ctx(task)` function, `bar`'s effective context is task but the
  annotation isn't inferred — you must declare it.

---

## 2. Effect lattice

### Rationale

Being explicit about side effects is the core discipline of systems
programming. An effect system lets the signature of a function carry
what it might do, so callers can reason about cost (allocation,
syscall, blocking) without reading the body.

### Annotation

```kr
@eff(alloc, io)
fn log_to_file(u64 fd, u64 msg) -> u64 { /* ... */ }

@eff(none)
fn pure_helper(u64 x) -> u64 { return x * 2 }
```

Effects are a bitmask. Current lattice (see
`compute_effects_expr` in `analysis.kr`):

| Bit | Name      | Triggered by                                     |
|-----|-----------|--------------------------------------------------|
| 0   | `io`      | `write`                                          |
| 1   | `alloc`   | `alloc`                                          |
| 4   | `file`    | `file_open`, `file_read`, `file_write`           |
| *   | (custom)  | Whatever annotated callees declare, transitive.  |

Absence of annotation is treated as "any effect allowed" (0xFFFF).
`@eff(none)` declares zero — useful for leaf helpers.

### Rule

```
actual(body) ⊆ declared(fn)
```

If the body computes effects the annotation doesn't cover, error:

```
eff-check: undeclared effect in parse_line
```

### Implementation

`check_effects` walks each function, bitwise-ORs the effects of every
expression in the body, and compares against the declared bitmask. Any
bit in actual-but-not-declared is an error.

Current limitations:
- No arithmetic on effect sets — the `~declared & actual != 0` check is
  clear for bits but awkward for richer lattices.
- Control-flow insensitive (an effect inside `if false { ... }` still
  counts).
- No module-level `pure` / `total` sub-lattices. Purity (does not
  depend on or mutate external state) is orthogonal to "no I/O" but
  not encoded.

---

## 3. Locks and lock-order graph

### Rationale

If thread A holds lock X and waits for lock Y, while thread B holds
Y and waits for X, you deadlock. The fix is a global lock order: pick
one; always acquire in that order. `@acquires` / `@releases` lets the
compiler build the acquisition-order graph and look for cycles.

### Annotation

```kr
@acquires(disk_lock)
@releases(disk_lock)
fn disk_write(u64 blk, u64 buf) { /* ... */ }
```

Functions can list multiple locks. The compiler builds a directed graph
where an edge `L1 → L2` means "some function holds L1 and acquires L2."

### Rule

**No cycles.** If L1 → L2 and L2 → L1 both exist, deadlock is
possible (even if not reachable in any actual call path, which is
harder to prove).

### Implementation

`lock_add_edge` adds (from, to) to a static table. `check_lock_cycles`
currently does a pairwise check — for every edge (A, B), look for a
reverse edge (B, A). That catches the simple two-lock deadlock; it
does **not** catch longer cycles (A → B → C → A). A proper DFS-based
SCC check is on the roadmap.

Current limitations:
- No `try_acquire` modeling — non-blocking acquires don't deadlock.
- No RAII-style guards — the `acquire` / `release` helpers are plain
  function calls, and the pass counts them textually. Forgetting a
  `release` on an early return path is invisible.
- The edge extraction is driven by annotations, not by the actual
  pattern of calls inside the body. Scoping still up to the programmer.

---

## 4. Capabilities

### Rationale

A capability is a coarse right that module M has and module N doesn't.
Example: "this module can issue raw syscalls" vs "this module can only
call higher-level stdlib." Helps partition a codebase into trust
boundaries.

### Annotation

```kr
@caps(mmio, irq_mask)
fn driver_init() { /* ... */ }
```

Capabilities are free-form tags. The compiler records them and, for
now, reports on functions that **use** a capability without **declaring**
one in the surrounding module.

### Rule

At present: "use site must declare." Without a module-level `@caps`
manifesto, the error is:

```
cap-check: undeclared capability 'mmio' in driver_init
```

### Implementation

`check_caps` walks each function and looks for known effect-bearing
calls (currently only the I/O family). If the enclosing function's
`@caps` doesn't cover them, it's a warning.

Current limitations:
- Module-level `@caps` is not parsed — only per-function.
- No mechanism to declare "this module **grants** a cap to functions
  that import it." Grants and demands don't have separate syntax.
- The cap set is hardcoded in the analyzer; no way to define new caps.

---

## 5. Critical regions

### Rationale

Between an `acquire()` and the matching `release()`, a thread is
*in a critical section* — it holds a lock, has IRQs disabled, or
similar. Inside, some operations are forbidden:

- `alloc` — can block waiting for the heap mutex → deadlock with self.
- Blocking syscalls — same.
- Calling functions with stricter `@ctx` — reintroduces the same class.

### Rule

If depth > 0 (we are inside a critical section), emit a warning on
any occurrence of a forbidden call.

### Implementation

`check_critical_regions` walks the AST carrying a `depth` counter. Each
`acquire()` increments it, each `release()` decrements it. Inside a
`depth > 0` region, certain callees (currently `alloc`) raise a
diagnostic.

Current limitations:
- Static structural walk — loops and branches are not modeled, so
  `if cond { acquire() } ...; release()` looks balanced even if `cond`
  is always false.
- No awareness of unreachable paths.
- No support for "releasing *from* the current scope *on return*"
  (i.e., no RAII / defer).

---

## 6. Roadmap

The current passes are a useful first draft — they catch obvious bugs
and give annotations a home. The next steps are to promote them from
advisory to authoritative:

1. **Diagnostics go through `diag_emit`.** Today each pass prints
   directly to stderr. Routing through the diagnostic table would give
   us consistent `file:line: error:` prefixes and an error count.
2. **Transitive effect/ctx inference.** Let the compiler compute
   `caller's minimum ctx` = `min over all callees` and warn only
   on user-declared mismatches, not on the inferred transitivity.
3. **Deadlock DFS.** Replace the pairwise cycle check with Tarjan's
   SCC so longer cycles are caught.
4. **Control-flow sensitive critical regions.** Track the acquire /
   release pattern per basic block, not lexically.
5. **Module-level capability manifesto.** `@caps(mmio, irq_mask)` at
   the top of a file.
6. **`defer { release(lock) }`.** A scope-exit action that runs on
   every exit path, including early returns. Halves the chance of
   leaked locks.
7. **Reject violations, don't just warn.** Once (1)–(6) are solid,
   promote to hard errors. Until then, tooling-only.

---

## 7. Minimal reproducer

To exercise every pass, save this as `demo_eff.kr` and compile:

```kr
fn acquire(u64 lock_id) { /* stub */ }
fn release(u64 lock_id) { /* stub */ }

@eff(io)
fn io_write_one(u64 fd, u64 b) {
    store8(b, 0x41)
    write(fd, b, 1)
}

@ctx(irq)
@eff(none)
fn timer_irq() {
    u64 b = alloc(1)              // critical-region + eff warn
    io_write_one(1, b)            // ctx violation: irq → any, but eff fail
}

@acquires(lockA)
fn takeA() { /* ... */ }

@acquires(lockB)
fn takeB() { /* ... */ }

fn main() {
    timer_irq()
    acquire(1)
    u64 buf = alloc(8)            // critical-region warn
    release(1)
    exit(0)
}
```

Running `krc check demo_eff.kr` should emit:

- An `eff-check` warning for `timer_irq` (declared `none`, uses
  `io` / `alloc`).
- A `critical-region` warning for `alloc` between `acquire` /
  `release`.
- No deadlock warning in this example (no A → B and B → A edges).

---

Filing issues for things this document says are limitations: please
open them with the `analysis` label.
