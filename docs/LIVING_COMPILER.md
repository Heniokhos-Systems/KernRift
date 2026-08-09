# The Living Compiler

> *Can a programming language remain stable enough for real engineering
> while still evolving its syntax, features, and ergonomics in response
> to actual usage?*

The Living Compiler is a governed, self-evolving compiler system: it
observes how the language is used, identifies friction points, proposes
improvements, and can adopt them under strict control — without
destroying compatibility, determinism, or long-term maintainability.

This document describes the vision and the current implementation. The
blueprint is ambitious; we build toward it in stages.

---

## The two-layer model

The core idea that makes the Living Compiler viable:

**Stable semantic core.** Type rules, IR meaning, safety model, ABI,
concurrency behavior. This layer changes slowly and carefully. Old code
compiled against a pinned core version continues to compile forever.

**Adaptive surface layer.** Syntax sugar, annotations, diagnostics,
common patterns, domain-specific constructs. This layer evolves in
response to observed usage. Multiple surface versions can coexist as
long as they lower into the same canonical IR.

This separation is what lets a language mature without fragmenting.
Beginners get ergonomic shortcuts. Long-lived kernels get a frozen
semantic contract. Migrations are mechanical because the lowered form
is stable.

---

## The pipeline

```
       Source code
           |
           v
    +-------------+
    |  Telemetry  |   Observe usage: call graph, pattern frequency,
    +-------------+   unsafe density, lock depth, extern ratio, etc.
           |
           v
    +-------------+
    |  Proposals  |   Generate candidate improvements. Each proposal
    +-------------+   names a pattern and a replacement form.
           |
           v
    +-------------+
    |   Fitness   |   Score each proposal: readability, safety,
    +-------------+   adoption cost, ambiguity, performance impact.
           |
           v
    +-------------+
    | Governance  |   Approve / reject / rollback / stabilize. Track
    +-------------+   the promotion lifecycle: experimental → stable
           |         → deprecated.
           v
    +-------------+
    |  Migration  |   Rewrite old code into the new form. Mechanical
    +-------------+   when the lowering is identity-preserving.
```

The five components are designed to be independent. You can run just
the telemetry pass and get a report. You can run telemetry + proposals
+ fitness and see suggestions. Governance and migration are the
heavier-weight stages that require human judgment or batch rewrites.

---

## Success criteria

From the original blueprint:

- Old projects continue to compile under pinned versions.
- New syntax or features provide measurable benefit.
- Changes are reversible and versioned.
- Migration can be automated.
- Semantic stability is preserved.
- Compile-time and runtime regressions stay controlled.
- The language becomes more useful over time without becoming fragmented.

---

## Current implementation

`krc lc <file.kr>` runs the telemetry and proposal passes and prints a
two-layer report.

```
=== KernRift Living Compiler Report ===
    stable semantic core + adaptive surface layer

Telemetry
  Functions:    13
  Calls:        21
  Unsafe ops:   22
  Total ops:    205
  Patterns:     2

Fitness: 73/100

--- Semantic Core (1) ---

  [1] unchecked_call  fitness: 43
      title: Unchecked call results
      signal: 95 occurrence(s)
      suggestion: Check return values of calls, especially for file I/O and allocation.

--- Adaptive Surface (1) ---

  [1] legacy_ptr_ops  fitness: 60  (auto-fix available)
      title: Legacy unsafe{} pointer syntax
      signal: 22 occurrence(s)
      suggestion: Migrate `unsafe { *(addr as T) -> dest }` to `dest = loadN(addr)` and `unsafe { *(addr as T) = val }` to `storeN(addr, val)`. Same codegen, much cleaner.
```

Patterns are classified as **semantic core** (correctness or
structural issues) or **adaptive surface** (ergonomic migrations).
Patterns tagged `(auto-fix available)` are candidates for the future
migration engine — the rewrite is identity-preserving at the IR level.

### Patterns currently detected

**Semantic core:**

| Pattern | What it catches |
|---|---|
| `unchecked_call` | Calls whose results are discarded (especially risky for I/O and allocation). |
| `large_unsafe_ratio` | Too many raw unsafe operations vs total operations. |
| `high_call_density` | Very complex call graph &mdash; hard to audit. |

**Adaptive surface:**

| Pattern | Migration | Auto-fix |
|---|---|---|
| `legacy_ptr_ops` | `unsafe { *(addr as T) -> dest }` → `dest = loadN(addr)` | Yes (planned) |
| `many_trivial_fns` | Inline 1-2 statement helper functions at call sites. | No |

### CLI

```sh
krc lc file.kr                     # full report
krc lc --min-fitness=30 file.kr    # filter the REPORT to patterns >= 30
krc lc --ci --min-fitness=1 file.kr   # fail if ANY pattern fires
krc lc --ci file.kr                # fail only on patterns >= 50  (see below)
```

**`--ci` on its own does NOT fail on every pattern — it applies a default
threshold of 50.** `--min-fitness` sets that threshold when `--ci` is present,
and `krc lc --ci --min-fitness=50` is therefore *identical* to bare
`krc lc --ci`, not a stricter form of it. Wiring the bare form into CI in the
belief that it catches everything gives you a gate that silently ignores every
pattern below 50. Demonstrated against this repository's own stdlib:

```
$ krc lc std/alloc.kr | grep fitness:
  [1] unchecked_call  fitness: 44
$ krc lc --ci std/alloc.kr ; echo $?
0                       # a pattern fired, and the gate passed
$ krc lc --ci --min-fitness=1 std/alloc.kr ; echo $?
1                       # what "fail if any pattern fires" actually requires
```

The gate is `fitness >= threshold` over the pattern list, so `--min-fitness=1`
catches everything a pattern detector can report (fitness 0 is not emitted).
Note `--min-fitness` does double duty: with `--ci` it is the gate, without it
it filters the report, and it is also the promotion floor for `--promote`.

### Fitness scoring

The file-level fitness score starts at 100 and deducts for each
detected pattern:

- **Core-layer** pattern: deduct up to `fitness / 4` (bigger penalty).
- **Surface-layer** pattern: deduct up to `fitness / 8` (smaller penalty).

This reflects the blueprint's priority: correctness concerns weigh more
than stylistic ones.

---

## Roadmap

What's built and what's next, aligned with the blueprint:

| Stage | Status |
|---|---|
| Telemetry collection | Implemented |
| Pattern detection | Implemented (5 patterns, 2-layer classification) |
| Fitness scoring | Implemented (layer-weighted) |
| Two-layer report | Implemented |
| CI gating (`--ci`, `--min-fitness`) | Implemented — `--ci` alone gates at fitness **50**, not 0 |
| Auto-fix flag on patterns | Implemented |
| **Migration engine** (actual source rewriting) | Implemented — `krc lc --fix` rewrites `unsafe{}` pointer ops to `load*/store*` builtins in place. `--dry-run` previews without writing. |
| **Proposal engine** (generate candidate syntax forms) | Implemented — `krc lc` prints proposals that fire against telemetry, with before/after snippets and rationale. 7 proposals in the initial registry. |
| **Governance layer** (lifecycle states: experimental / stable / deprecated) | Implemented — `krc lc --list-proposals` prints the full registry with each proposal's current state. Persistent per-project state file is planned for a future release. |
| **Versioned language profiles** (`#lang stable` / `#lang experimental`) | Implemented — the lexer parses an optional `#lang` directive on the first line of a file and records the profile. `get_lang_profile()` exposes it to later passes for feature gating. |

All five stages of the blueprint pipeline are now in place. What remains
are extensions:

- **Persistent governance** — move the proposal state table out of
  compiler source and into a per-project `.kernrift/proposals` file so
  projects can pin their own governance decisions.
- **Richer migrations** — beyond `unsafe{}` ops, migrate long-form
  types to short aliases, detect `(ptr, len)` param pairs that could
  become slice parameters, detect repeated MMIO addresses that could
  become `device` blocks.
- **Profile-gated features** — use `#lang experimental` to gate
  not-yet-stable syntax (`tail_call()`, `extern fn`, etc.) so stable
  code can't accidentally depend on unstable features.

---

## Why it matters

Traditional languages become outdated because real usage patterns
change faster than the language can. Engineers compensate with macros,
boilerplate, conventions, wrappers, and external tooling. The Living
Compiler internalizes that pressure and turns it into structured,
measurable language evolution.

The goal is not a chaotic language that changes unpredictably. The
goal is a compiler that can propose, evaluate, version, and adopt
language changes under strict control. The language becomes an
evolving engineering system: new syntax forms, domain-specific
constructs, and usability improvements can emerge when they are
justified by measurable benefit, while the underlying semantics remain
stable and reproducible.

Language design as an ongoing optimization process, rather than a
one-time decision.
