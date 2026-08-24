# KernRift Effect & Capability System

> ## Status: IMPLEMENTED — all five passes run and can fail a build
>
> `@ctx`, `@eff`, `@acquires` / `@releases` and `@caps` are parsed, recorded and
> checked. `krc check` reports violations as errors with `file:line:col` and a
> caret, and exits non-zero.
>
> This replaces a "DESIGN ONLY" banner. Previously the parser accepted the
> annotation syntax and discarded it — nothing called `ann_register` or
> `lock_add_edge`, so the tables were always empty and no program could make
> the passes warn. Three separate things had to change: the parser had to
> capture the arguments (a generic "skip to `)`" arm was swallowing them),
> `analysis_init` had to stop resetting the table *after* parsing had filled
> it, and the ctx/effect traversals had to become recursive — they covered
> statement kinds 16/13/14 only, so a call in `return f()`, `uint64 x = f()`,
> `x = f()`, `f(g())` or `a + f()` was never examined.

Design for four annotation-driven analysis passes in `src/analysis.kr`, plus
one implemented pass:

1. **Context** (`@ctx`) — which execution mode a function is legal in
   (task / IRQ / NMI). *Not implemented.*
2. **Effects** (`@eff`) — what an operation is allowed to do
   (I/O, allocate, acquire a lock). *Not implemented.*
3. **Locks** (`@acquires` / `@releases`) — deadlock detection via a
   lock-order graph. *Not implemented.*
4. **Capabilities** (`@caps`) — coarse-grained permission tags.
   *Not implemented.*
5. **Critical regions** — `alloc` between `acquire` and `release`.
   **Implemented**, with the limits documented in §5.

Even for the implemented pass the diagnostics are advisory: they print to
stderr with no `file:line:` prefix, `krc check` still reports `- OK`, and the
exit status stays 0.

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
fn nmi_entry() { }

@ctx(irq)
fn timer_irq() { }

@ctx(task)
fn main() { }

// Unannotated functions default to ctx=any.
```

Valid values: `any` (= 0, the default), `task` (1), `irq` (2), `nmi`
(3). Ordered most-permissive to most-restrictive.

### Rule

A function with context `C` may only call functions with context `C`
or broader. Expressed numerically:

```
callee_ctx == any        → legal (a callee that declares nothing constrains nothing)
caller_ctx <= callee_ctx → legal
caller_ctx >  callee_ctx → error: the caller's context is stricter than the callee's
```

(An earlier revision of this document stated the comparison the other way
round, which contradicted all three of the worked examples below. The
implementation follows the examples: `caller_ctx > callee_ctx && callee_ctx != 0`.)

Concretely:
- An `@ctx(irq)` function calling an `@ctx(any)` helper: fine.
- An `@ctx(irq)` function calling an `@ctx(task)` helper: **error**
  (the task function may block, and we're in IRQ).
- An `@ctx(task)` function calling an `@ctx(irq)` helper: fine (the
  helper is more restrictive than us, so it doesn't do anything we
  can't).

### Implementation

`check_ctx` walks each function's body via `check_ctx_walk` — one recursive
walk over the whole subtree — and on every `Call` looks up the callee's `@ctx`,
compares it to the caller's, and reports a violation with `file:line:col`.

Limitations of the current design:
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
fn log_to_file(u64 fd, u64 msg) -> u64 { return 0 }

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

`check_effects` walks each function via `compute_effects_walk`, bitwise-ORs the
effects of every expression in the body — including the effects an annotated
callee declares, so the set is transitive — and compares against the declared
bitmask. Any bit in actual-but-not-declared is an error.

Limitations of the current design:
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
fn disk_write(u64 blk, u64 buf) { }
```

Functions can list multiple locks. The compiler builds a directed graph
where an edge `L1 → L2` means "some function holds L1 and acquires L2."

### Rule

**No cycles.** If L1 → L2 and L2 → L1 both exist, deadlock is
possible (even if not reachable in any actual call path, which is
harder to prove).

### Implementation

The parser adds an edge for every ordered pair in an `@acquires` list, and
`check_lock_cycles` runs a three-colour DFS over the resulting graph: white
unvisited, grey on the current stack, black finished. An edge into a grey node
is a back edge, so **cycles of any length are detected**, not just the
two-lock case. (An earlier revision checked only for a reverse edge (B, A) and
missed A → B → C → A.)

Limitations of the current design:
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
fn driver_init() { }
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

`check_caps` was a shell: its body was a comment, `cap_errors` never left 0,
and the `cap-check` message above had never been printed. It now has logic.

**The implemented rule is narrower than the "use site must declare" above, and
deliberately so.** Applied unconditionally that rule fires on every program
that prints, because `println` reaches `write`. So capability checking is
**opt-in per module**: if no function in the file declares `@caps`, nothing is
checked. Once any function declares one, the module has opted into capability
partitioning and every function performing a capability-bearing operation
(the `io` and `file` families) must declare `@caps` too.

Limitations of the current design:
- Capability *tags* are counted, not compared — declaring `@caps(mmio)` and
  then using a `file` operation is accepted. Subset checking per tag needs the
  tag tokens stored, not just their count.
- The capability-bearing set is the I/O family only, inherited from the effect
  lattice; `mmio`, `dma` and the rest are not yet tied to any operation.

---

## 5. Critical regions — the one pass that is implemented

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

### Implementation — IMPLEMENTED

This pass needs no annotations, which is exactly why it is the one that works.
`check_critical_regions` (`src/analysis.kr:372`) walks each function's
top-level statement list carrying a `depth` counter. A call to a function
*named* `acquire` increments it, one named `release` decrements it. Inside a
`depth > 0` region a call named `alloc` prints:

```
critical-region: alloc inside critical section
```

Current limitations — these are narrow, and you will hit them immediately:

- **Only bare call statements are matched.** `check_critical_stmt` looks for a
  statement whose child is a call node. `alloc(8)` on a line by itself is
  matched; **`u64 b = alloc(8)` is a declaration and is NOT matched**, so the
  ordinary way of writing an allocation is invisible to this pass.
- **Only the top level of a function body is walked.** `check_critical_block`
  is called once per function body; it does not descend into `if` / `while` /
  `loop` bodies, so an `acquire` or an `alloc` nested in any block is not seen.
- **Matching is by name, not by identity.** Any function you happen to call
  `acquire` opens a region, whether or not it takes a lock.
- **`alloc` is the only forbidden call.** Blocking syscalls and stricter-`@ctx`
  callees, both listed under "Rationale" above, are not checked.
- **The diagnostic has no `file:line:` prefix** and does not affect the exit
  status — `krc check` still prints `- OK` and exits 0 (see §7).
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

There is no program that exercises "every pass", because four of the five
cannot produce output at all (see the status box at the top). This reproducer
exercises the **one** pass that works. Save it as `demo_eff.kr`:

```kr
// The critical-region pass matches `acquire` / `release` / `alloc` by name,
// as bare call STATEMENTS at the top level of a function body.
fn acquire(u64 lock_id) { }
fn release(u64 lock_id) { }

fn main() {
    acquire(1)
    alloc(8)            // reported
    release(1)
    alloc(8)            // not reported: outside the region
    exit(0)
}
```

Measured with krc 2.9.0:

```
$ krc check demo_eff.kr
critical-region: alloc inside critical section
krc check: demo_eff.kr - OK
$ echo $?
0
```

Exactly one line, on stderr, with no `file:line:` prefix — and note that
`check` still says `- OK` and exits 0, so this diagnostic will not fail a
build or a CI step.

Two edits that make even that one warning disappear, both worth knowing
because they are how normal code is written:

```kr
    acquire(1)
    u64 b = alloc(8)    // SILENT: a declaration, not a bare call statement
    release(1)
```

```kr
    acquire(1)
    if 1 == 1 {
        alloc(8)        // SILENT: the pass does not descend into nested blocks
    }
    release(1)
```

Both were run against krc 2.9.0 and produced `krc check: … - OK` with no
`critical-region` line.

### What the old version of this section claimed

Until this revision, this section carried a longer program using `@eff`,
`@ctx` and `@acquires`, and asserted that `krc check` "should emit" an
`eff-check` warning and a `critical-region` warning. It emitted neither. It
also did not compile: it used `/* stub */` block comments, which KernRift does
not have, so `krc check` stopped with four parse errors before any analysis
ran.

---

Filing issues for things this document says are limitations: please
open them with the `analysis` label.
