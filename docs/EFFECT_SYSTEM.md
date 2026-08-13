# KernRift Effect & Capability System

> ## ⚠️ Status: DESIGN ONLY — four of the five passes cannot fire
>
> **`@ctx`, `@eff`, `@acquires` / `@releases` and `@caps` do nothing today.**
> The parser accepts the annotation syntax and then discards it: nothing ever
> calls `ann_register` or `lock_add_edge` (`src/analysis.kr:45` and `:288` —
> both have **zero call sites**, a fact `src/main.kr:8753` records in a comment
> of its own). The annotation table and the lock graph are therefore always
> empty, so `check_ctx`, `check_effects`, `check_caps` and `check_lock_cycles`
> run on every `krc check` and can never report anything. There is no program
> you can write that makes them warn.
>
> **One pass is real: critical regions** (§5). It is annotation-independent —
> it matches the *names* `acquire`, `release` and `alloc` on bare call
> statements — and it does warn. See §7 for a reproducer that actually
> produces output.
>
> Sections 1–4 below describe the **intended** design, kept because it is the
> specification the implementation is being written against. Read every
> "Rule" and "Implementation" heading in them as *planned*, not *current*.
> Do not rely on any of it to catch a bug.

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

### Implementation — NOT IMPLEMENTED

`check_ctx` exists and runs, but `@ctx` is never recorded: `ann_register`
has no callers, so `ann_lookup` returns the "unannotated" default for both
caller and callee on every comparison and the pass is a no-op. **No `@ctx`
violation is diagnosable today.** The intended behaviour is that `check_ctx`
walks each function's body, and on every `Call` node looks up the callee's
`@ctx`, compares to the caller's `@ctx`, and emits a diagnostic on violation.

Limitations of that intended design, once it is wired up:
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

### Implementation — NOT IMPLEMENTED

`check_effects` exists and runs, but `@eff` is never recorded, so the declared
mask is always the unannotated default ("any effect allowed") and nothing can
be outside it. **No `eff-check` diagnostic is reachable today** — the message
text quoted above has never been printed by a released compiler. The intended
behaviour is that `check_effects` walks each function, bitwise-ORs the effects
of every expression in the body, and compares against the declared bitmask,
with any bit in actual-but-not-declared an error.

Limitations of that intended design, once it is wired up:
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

### Implementation — NOT IMPLEMENTED

`lock_add_edge` (`src/analysis.kr:288`) would add (from, to) to a static table,
but **it has no callers**, so the graph is empty on every run and
`check_lock_cycles` always returns "no cycle". **No deadlock warning is
reachable today.** When wired up, `check_lock_cycles` does a pairwise check —
for every edge (A, B), look for a reverse edge (B, A). That catches the simple
two-lock deadlock; it does **not** catch longer cycles (A → B → C → A). A
proper DFS-based SCC check is on the roadmap.

Limitations of that intended design, once it is wired up:
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

### Implementation — NOT IMPLEMENTED

`check_caps` exists and runs, but `@caps` is never recorded, so there is no
declared set to compare against and the pass reports nothing. **The
`cap-check` message above has never been printed.** The intended behaviour is
that `check_caps` walks each function looking for known effect-bearing calls
(currently only the I/O family) and warns if the enclosing function's `@caps`
doesn't cover them.

Limitations of that intended design, once it is wired up:
- Module-level `@caps` is not parsed — only per-function.
- No mechanism to declare "this module **grants** a cap to functions
  that import it." Grants and demands don't have separate syntax.
- The cap set is hardcoded in the analyzer; no way to define new caps.

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
