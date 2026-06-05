# Changelog

All notable changes to `kernriftc` are documented in this file.

## Unreleased — language ergonomics (2026-06)

### New language features
- **Ternary `cond ? then : else`** — lowest-precedence, right-associative,
  short-circuiting conditional expression. Works on all four backends.
- **`match` ergonomics** — arm bodies may be a single bare statement
  (`1 => exit(1)`, braces optional); the `_ =>` default arm is documented and
  supported; and **`match` works as an expression** (`let r = match x { 1 =>
  10  _ => 0 }`), yielding the matching arm's value.
- **`let` type inference** — `let name = expr` infers a local's type from its
  initializer (required). Covers scalars, calls, arithmetic, comparisons,
  ternaries and match expressions; struct values still need an explicit type.

### Legacy-backend parity / correctness
- Short-circuit `&&` / `||` and f-strings now behave identically on the
  `--legacy` backends and the default IR backend (x86_64 and arm64).
- **Legacy arm64 signed `/ % >>`** and **signed comparison operators**
  (`< <= > >=` on `i64`) are now type-directed — they previously emitted
  unsigned instructions on the legacy arm64 path only.
- Calls to an undefined function are now rejected on arm64 (both backends)
  with a clear error instead of hanging.
- else-if chains of any length now pass return-path exhaustiveness analysis.

All changes preserve the bootstrap fixed point (krc compiles itself bit-
identically) and are validated by the full test suite plus IR-vs-legacy
differential harnesses across x86_64 and arm64 (incl. real Pi 400 hardware).

## Licensing — 2026-05-19

- Relicensed from MIT to Apache 2.0. See `LICENSE` and `NOTICE`.
- Copyright attribution updated: `Copyright (c) 2025–2026 Panteleimon-Panagiotis ("Pantelis") Christou`.
- All commits up to and including the previous one remain available under the MIT license under which they were originally published; everything from this commit forward is Apache 2.0.

## v2.8.25 — 2026-05-07

### Codegen correctness
- **`struct_var_table` reset per function.** The codegen's struct-var
  table is global and was never cleared between functions, so two
  functions in the same compilation unit declaring a variable of the
  same name but different struct types silently mis-resolved field
  offsets — `struct_var_lookup` walked linearly and returned the first
  registered match. Concretely:

  ```
  struct A { u64 a0; u64 a1; u64 a2 }
  struct B { u64 b0; u64 b1; u64 b2; u64 b3; u64 b4; u64 b5 }
  fn touch_a() -> u64 { A w = ...; return w.a2 }   // ok
  fn touch_b() -> u64 { B w = ...; return w.b5 }   // BUG: lookup wins A
  ```

  `touch_b`'s `w.b5` lowered as offset 8 (A's `a1`) — or returned
  `0xFFFFFFFF` for fields A doesn't have, garbage-reading from there.
  A second symptom: two consecutive return-by-value calls of
  *different* struct types from the same caller frame segfaulted on
  the second call because the wrong struct's size flowed into sret-
  slot allocation in the caller frame, scribbling saved registers /
  return address.

  Fix: reset `struct_var_count = 0` at the start of each function's
  codegen, in both backends — `var_reset()` for the legacy x86 path
  and `ir_lower_function()` for the IR backend (both x86 and aarch64).
  Per-function entries now live only for the duration of that
  function's lowering. Regression repro lives at
  `examples/codegen_struct_var_collision.kr` and
  `examples/codegen_consecutive_struct_returns.kr`.

- **IR Assign-alias clobber for bare-Ident RHS.** The Assign lowering
  in `src/ir.kr` aliased the LHS to the RHS's vreg whenever RHS was a
  bare Ident — Ident lowering returns the existing vreg without
  copying. Subsequent mutations to the LHS (e.g. `t = t + 1` inside a
  loop) then physically clobbered the source variable's storage via
  the back-edge IR_COPY emitted by `ir_emit_copy_to_snapshot`:

  ```
  u64 t_lo = 0
  u64 t = 999
  t = t_lo                  // Assign-alias: t and t_lo share vreg
  while t < N {
      t = t + 1             // back-edge IR_COPY clobbers t_lo
  }
  // t_lo is now N, not 0
  ```

  VarDecl already emitted a fresh vreg + IR_COPY on every init path;
  Assign was missing the mirror. Fix: after the existing ITOF /
  F64TOF32 / F32TOF64 cast paths (which already produce fresh vregs),
  check whether `val` still equals the local-vreg of the RHS Ident,
  and if so emit `IR_COPY fresh_val, val` and rebind the LHS. Statics
  on the RHS already produce a fresh vreg via IR_STATIC_LOAD, so the
  equality check naturally fails. Compound-assign / field / index /
  call-result LHS paths are all unaffected. Regression repro lives at
  `examples/codegen_bare_ident_repro.kr`.

Both fixes are also pulled in by the v0.1.1 MLRift port.

## v2.8.24 — 2026-05-04

### Optimizations
- **Briggs/George copy coalescing, on by default.** The graph-colouring
  register allocator now collapses `vN = copy vM` pairs whose live
  ranges don't interfere into a single colour, so the redundant
  `mov rN, rN` is dropped at emit time. The coalescer is conservative
  — Briggs counts neighbours of the merged class with degree ≥ K and
  refuses if ≥ K such neighbours would remain (would force a spill).
  When Briggs rejects, a George fallback (gated to K ≥ 8) tries either
  direction: every neighbour t of one node must already interfere with
  the other or have deg[t] < K. `--no-coalesce` disables.

  krc.kr self-compile vs `--no-coalesce`:
  - x86_64 (K=6, Briggs only): −72 B
  - arm64  (K=10, Briggs+George): −1592 B

  Two correctness items folded in:
  1. Union always points high → low, so the rep is the lower-numbered
     vreg and is coloured first in the sequential walk. Without this,
     a neighbour of a follower would look up `uf_find(follower) = rep`
     where rep ≥ vi and read an as-yet-unassigned colour, silently
     dropping the constraint and allowing collisions at runtime.
  2. Degree lookups consult `deg[ir_uf_find(n)]` since followers' own
     degree slots are zeroed at drop time. Without the redirect, both
     Briggs and George could accept merges that the rep's true degree
     should have rejected.

- **AST-level function inliner.** Pure single-expression callees
  (`fn add(a, b) -> uint64 { return a + b }`) are folded into their
  call sites via in-place `Call` node mutation. DCE then drops the
  unused originals. For `--emit=obj`, `--emit=asm`, and `--emit=ir`
  every top-level function is seeded as live so the original symbols
  still appear in the linker symbol table / asm listing / IR dump.
  Eligibility: param uses ≤ 1, no recursion, no `@section`, expression
  body uses only basic kinds (binop / cmp / call / ident / literals).

### Tooling
- **`--help` rewritten** to cover every flag the parser handles —
  output groups (`--arch` / `--target` / `--targets` / `--emit=…`),
  code-gen toggles (`--ir` / `--legacy` / `--coalesce` / `--no-coalesce`
  / `--O0` / `--freestanding` / `--debug` / `-g`), and the living
  compiler subcommands. Previously `--legacy`, `--coalesce`, `--O0`,
  and the `lc` proposal flags were undocumented.

## v2.8.23 — 2026-04-30

### Performance
- **Self-compile peak RSS drops 96–99 %.** Single-arch went from
  806 MB → 33 MB; fat (8 slices) went from 6.3 GB → 87 MB. Wall-clock
  improves ~30 % alongside (single-arch 1.52 s → 1.06 s, fat 11.9 s →
  8.4 s on a Ryzen 9 7900X), and Pi 400 fat self-compile now actually
  finishes — previously it triggered heavy swap and never completed.
  Three fixes:

  1. **`ir_emit_copy_to_snapshot` was leaking its `pairs` buffer**
     (`ir.kr:898`). The function is called for every if/else, while,
     and match merge — across the self-host's ~700 functions, that
     was thousands of unfreed allocations. Added the missing
     `dealloc(pairs)`.

  2. **`ir_block_offsets` / `ir_br_fixups` / `ir_ret_fixups` were
     re-allocated per emitted function** without freeing the previous
     buffer (both `ir.kr` and `ir_aarch64.kr`). 52 KB × ~700 functions
     × 8 slices = ~290 MB leaked per fat self-compile. Fixed with
     grow-as-needed caps (`ir_block_offsets_cap`, etc.) so the
     buffers are reused and only realloc when a function needs more
     capacity than previously seen.

  3. **`ir_compute_liveness` allocated a per-BB scratch set
     (`tmp = alloc(set_bytes)`)** inside the dataflow loop and never
     freed it. The dataflow loop iterates until convergence (typically
     3–8 passes), each touching every BB, so total leak ≈
     `passes × bb_count × set_bytes` per function. Hoisted the
     allocation to a static `ir_live_tmp` (with a `_cap` companion);
     the scratch is now reused across BBs *and* across iterations,
     which also explains the wall-clock gain (no per-BB malloc/free
     overhead).

  Codegen output buffer's old 512 MB up-front cap was also reduced
  to 4 MB initial with a doubling growth path in `emit_byte`. On
  Linux this was mostly virtual reservation (lazy fault), but the
  growable form removes the surprise on RAM-tight platforms and is
  cleaner to reason about.

## v2.8.22 — 2026-04-29

### Infrastructure
- **Loop-Invariant Code Motion (LICM)** lands in the IR optimiser as
  correctness-first scaffolding for richer loop opts. Pure invariant
  computations (arith, logic, cmp, float ops) get hoisted out of every
  loop's body to its preheader; chains of invariants converge in up
  to 8 fixed-point iterations per function. fib/sort/sieve/matmul are
  all within noise of v2.8.21 (~0% to −3%) — the framework hoists the
  invariants it can prove safe and profitable, but with current
  conservatism the hot loops in these four benchmarks expose nothing
  it can win on without regressing register pressure. Bootstrap binary
  grows +0.5% (1,176,168 → 1,182,536 bytes); 439/439 tests pass; krc2
  == krc3 byte-identical.

  Two correctness/profitability tunings the implementation taught us:

  - **Hoistability is stricter than CSE-purity.** CSE treats
    `static_load` (op 77) as pure because intervening writes
    invalidate its hash table within a BB; LICM cannot, because the
    hoisted op runs *before* the loop ever observes those writes.
    Excluding op 77 from the hoistable set fixed a self-host
    miscompile where `dce_scan`'s inner loop (`while i < dce_count`,
    body calls `dce_add` which mutates `dce_count`) became infinite
    when the load of `dce_count` was hoisted to the preheader. (Found
    by binary-searching a per-function bisect: MAX=65 OK, MAX=66
    hangs → function 66 in LICM order = `dce_scan`.)
  - **`IR_CONST` (op 1) is rematerialize-cheap, so don't hoist it.**
    A `mov reg, imm32` is 5 bytes / 1 cycle inline; hoisting trades
    that for register pressure across the whole loop, and if the
    coloured set runs out (sort had ~6 small constants in a body
    with 6 colours available), every hoisted constant spills to a
    stack slot — strictly worse than rematerialization. (Found by
    A/B benchmark: sort regressed 108 → 152 ms after enabling LICM,
    disasm showed all the hoisted `mov rax, imm; mov [rsp+N], rax`
    stores. Excluding op 1 restored sort to baseline.)

  Implementation notes:
  - Per-vreg "defining BB" map with a `0xFFFFFFFE` multi-def sentinel
    — a vreg assigned in two or more BBs is conservatively treated as
    varying, since one of those BBs may be inside the loop region.
  - Per-loop body walk uses the BB linked-list (not an insn-index
    range), so it stays correct after a previous LICM pass appends
    hoisted insns at high indices.
  - Static `ir_walk_stack` (65 536 × 4 B) replaces per-BB
    alloc/dealloc, keeping LICM at O(insns) per pass.
  - Liveness and the interference-graph builder now walk the BB
    linked list rather than an insn-index range, so they stay correct
    after LICM appends hoisted insns at non-consecutive indices.

  Future profitability work (not in this release): hoist a constant
  only when it feeds a long invariant chain that *also* hoists; proper
  dominance analysis to cover CFG shapes the BB-index range model
  misses; rematerialization on spill so even the hoisted-spilled case
  isn't strictly worse than inline.

## v2.8.21 — 2026-04-29

### Performance
- **Self-host bootstrap shrinks 5.2%** (1,240,432 → 1,176,168 bytes) and
  the `sort` benchmark drops **30%** (153 → 108 ms — krc now beats
  gcc -O2 by 2.5×) from three IR-backend codegen wins:
  1. **6th register colour (rbp).** The graph-colouring regalloc gained
     one more callee-saved register, dropping spill rate across the
     compiler. rbp had been left out historically; the lz4 / fat-archive
     paths surfaced an off-by-one in stack-arg overflow loads (the old
     `+48` hardcoded "5 pushes + ret addr" — replaced with
     `ir_callee_save_bytes + 8`).
  2. **Per-function used-callee-save prologue.** Functions only push
     the colours regalloc actually assigned. fib's prologue dropped
     from 5 pushes to 3, and most leaf-ish helpers drop to 0 or 1.
     Variable alignment math (push_count parity decides whether
     frame_size needs +8) keeps SP 16-aligned at every CALL.
  3. **Cross-register spill-reload peephole.** `store rax,V` followed
     by `load rcx,V` (different register) now emits `mov rcx, rax`
     instead of a memory roundtrip. Catches the matmul-style pattern
     where intermediate vregs flow through different scratch regs.

  Runtime impact (Ryzen 9 7900X, AVX2-disabled bench programs):

  | Bench  | v2.8.20 | v2.8.21 | gcc -O2 | Δ |
  |---|---|---|---|---|
  | fib    | 442 ms  | 427 ms  | 78 ms   | -3% |
  | sort   | 153 ms  | **108 ms** | 270 ms | **-30%, 2.5× ahead of gcc -O2** |
  | sieve  | 3 ms    | 3 ms    | 2 ms    | tied |
  | matmul | 34 ms   | 33 ms   | 4 ms    | -3% |

## v2.8.20 — 2026-04-28

### Fixed
- **`return N` from `main` was silently ignored.** The auto-inserted
  exit syscall at the end of `main` clobbered the return register
  (`rax` on x86_64, `x0` on aarch64) with a hardcoded `0` immediately
  before the syscall — so `fn main() -> int32 { return 42 }` exited
  with status 0, not 42, on every backend (legacy and IR, both
  arches). Found while debugging `while 1 == 1 { ... if cond { return
  42 } }` which exhibited the same symptom for the obvious reason.
  Existing examples like `hello.kr` were unaffected because they call
  `exit(0)` explicitly. Fixed by removing the clobber and instead
  zeroing the return register at the start of `main`'s body (legacy
  backends) / inside `IR_RET_VOID` (IR backends), so the
  implicit-zero default is preserved for `fn main() { ... }` while
  explicit `return N` flows through to the exit status as expected.

## v2.8.19 — 2026-04-28

### Fixed
- **Termux on Android 14+ couldn't run `.krbo` fat binaries.** Three
  bugs stacked. (1) Termux's exec wrapper duplicates `argv[0]` and
  `argv[1]` (both = path-to-self), but the runner's linker-shift
  detection only matched `/system/bin/linker64` and Android's apex
  linker — so `--version` got parsed as a `.krbo` path, the runner
  fell through to file-open + exec of garbage data, and SIGBUS'd on
  the corrupted binary. The detection now also fires when
  `argv[0] == argv[1]` (a pattern no normal shell invocation can
  reproduce). (2) `runner.kr` references `filter_aarch64_bcj` and
  `filter_x86_64_bcj` from `bcj.kr`, but the source files weren't
  concatenated before compile when building the runner standalone, so
  the generated binary had unresolved BCJ calls. The "exec" of the
  undefined function landed somewhere arbitrary and silently corrupted
  every extracted slice (entry-point bytes clobbered → SIGBUS at
  startup). New `kr-runner` Make target concatenates the two
  explicitly. (3) Even with a correctly-extracted slice, raw `execve`
  from the runner's app SELinux context fails with `EACCES`: Termux's
  libc wraps `execve` via `LD_PRELOAD`, but our `svc 0` syscall
  bypasses the wrapper. Tested `execve`, `execveat(AT_FDCWD)`, and
  `execve` of bash — all denied. Solution: `kr` is now a small shell
  wrapper (`packaging/kr.sh`) that catches the runner's exit-120
  ("extract succeeded, exec was denied") and re-execs `./kr-exec`
  from its own shell context where `LD_PRELOAD` is engaged. Verified
  on Z Fold 5 / Android 16 / Termux: `kr program.krbo` now prints the
  program's output and exits 0.
- **Mixed f32/f64 arithmetic in `BinOp` and `Assign` paths.** When the
  two sides of a float op had different `fkind`s, codegen emitted
  `ADDSS/SUBSS/MULSS/DIVSS` against an f64 literal still in 64-bit
  XMM layout — the f32 instruction reads only the low 32 bits, which
  are `0x00000000` for round f64 values like `1.0`/`2.0`/`0.5`, so
  `a + 1.0`, `a - 1.0`, `a * 2.0` quietly produced 0 / a / +Inf for
  f32 vars. Now the narrower side is widened to f64 in float arith,
  matching the existing FCMP fix; the assign path round-trips
  `f32 t = ...; t = a - 1.0` via `F64TOF32` / `F32TOF64`.
- **Signed integer comparisons.** `int64 var < 0` always evaluated
  false (and the dual `>= 0` always true) because compare lowering
  unconditionally emitted `IR_CMP_LT` etc, which codegen rendered as
  unsigned `setb`/`setbe`/`seta`/`setae` on x86 (LO/LS/HI/HS on
  aarch64). Heavy infrastructure was already there — `IR_SCMP_*`
  opcodes wired through both backends, fused-cmp peephole maps,
  `signed_lt`/`le`/`gt`/`ge` builtins as escape hatches — but the
  frontend never reached them. Added a parallel byte-array
  `ir_vreg_signed_buf` (mirroring `ir_vreg_fkind_buf`), tagged from
  `int8`/`16`/`32`/`64` declarations, propagated through Assign and
  the int path of BinOp, and let the f64-truncating `f64_to_int`
  builtin emit it (cvttsd2si is signed). `uint*` stays unsigned, so
  pointer math comparing to `0xFFFFFFFFFFFFF000` is untouched. The
  legacy backend has no per-vreg metadata, so signedness is re-derived
  from the AST via `legacy_node_is_signed` (Ident → declared type;
  BinOp/UnaryNeg/Call recursing).
- **Signed `/`, `%`, `>>` for negative two's-complement values.**
  After the compare fix, `int64 a = -10; a / 3` still returned
  `(2^64 - 10) / 3` as unsigned because `IR_DIV` codegen always
  emitted `xor rdx, rdx; div r/m64`, and `>>` always emitted `shr`.
  Added `IR_SDIV = 132` (`mov rax, _; cqo; idiv` on x86; `sdiv` on
  aarch64), `IR_SMOD = 133` (the same plus `msub`), `IR_SAR = 134`
  (ModRM `/7` on x86; `asr` on aarch64). BinOp lowering picks the
  signed variant when either operand carries the signed flag from
  the previous fix. Mirrored in the legacy backend with inline
  `cqo + idiv` for div/mod and ModRM `0xF8` vs `0xE8` for SAR/SHR.

## v2.8.14 — 2026-04-19

### Fixed
- **`compile_fat` x86_64 slice buffer overflow.** The slice's temp
  buffer was a hardcoded 1 MB `alloc()` at the top of `compile_fat`,
  but the ELF x86_64 slice has been ~1.18 MB for months. The copy loop
  wrote ~180 KB past the buffer end every fat compile. Linux's mmap
  heap absorbed it silently; Windows's VirtualAlloc guard pages turned
  it into a SIGSEGV on every `krc *.kr -o *.krbo` on a Windows host.
  Fixed by allocating *after* codegen, sized to the actual slice
  length — the pattern every other slice already uses.
- **Windows x86_64 `file_open` read-then-write hardcoded jump.** After
  the compact-imm MOV optimisation landed in v2.8.13, `mov r64, imm64`
  dropped from 10 bytes to 5 bytes for uint32-fitting constants. A
  `jz +10` in the Windows `file_open` lowering that assumed the old
  size overshot by 5 bytes on every read-after-write. Fixed to patch
  the rel8 displacement after the mov emits.
- **macOS ARM64 `alloc()` SIGSEGV.** The IR ARM64 backend hardcoded
  Linux's `MAP_PRIVATE|MAP_ANON = 0x22` for every non-Windows target;
  macOS's value is `0x1002`. Every `alloc()` on native arm64 macOS
  CI was dereferencing a MAP_FAILED pointer. Legacy codegen already
  did this correctly; IR now matches.
- **Windows ARM64 `ReadFile` / `WriteFile` out-count pointer.** The IR
  ARM64 path passed `&lpNumberOfBytesRead = NULL` to the kernel32 IAT
  entry. ReadFile returned its BOOL success code in `x0`, which we
  then used as the "bytes read" count — so `file_read()` returned `1`
  regardless of how many bytes landed in the buffer. Fixed to allocate
  a DWORD scratch slot, pass its address, and load the real count
  back after the call.
- **Windows ARM64 `file_size()` scratchpad clobber.** The IR path
  computed `&scratch` into `x11`, called `GetFileSizeEx` through the
  IAT, then loaded the size back from `[x11]`. `x11` is caller-saved
  (x0..x18 per AAPCS64), so the IAT call legally trashed it and the
  follow-up LDR dereferenced kernel garbage. Fixed by recomputing
  `x11` from SP after the call. This was blocking every Windows ARM64
  self-compile.

### Changed
- **Fat-binary codegen defaults to IR.** `compile_fat` used to route
  every slice through the legacy direct-walking emitters; now it
  routes through IR by default, matching what direct `--arch=…`
  compiles already did. Legacy is retained behind `--legacy` for an
  explicit opt-out. Net fat-binary size: 4.09 MB → 3.82 MB (-6.7%).
  Per-slice wins are largest on ARM64 / PE / Mach-O (-15 to -18%).
- **Windows PE `time_ns()` implemented.** Previously a stub returning
  `0`, which silently disabled the parenthesised compile-time tail
  (`(X.XX ms)`) on Windows. Wired through the IAT as
  `QueryPerformanceCounter + QueryPerformanceFrequency`, with an
  overflow-safe split-and-recombine so counter × 1e9 doesn't wrap
  after ~29 days of uptime. ARM64 Windows still returns 0 (no WoA
  test hardware available); the print-gate falls back gracefully.
- **Fat-binary compile also prints `(X.XX ms)`.** `compile_fat` now
  tail-reports its total wall time the same way single-file compile
  already did, so you don't need to wrap with external `time` /
  `Measure-Command` to measure fat output.

### Performance (IR x86_64 backend)
- **Compact imm encoding.** `mov r64, imm64` now uses 5-byte
  `B8+r imm32` (zero-extend) or 7-byte `REX.W C7 /0 imm32` (sign-
  extend) when the constant fits — a 10-byte `movabsq` was emitted
  unconditionally before. -9.1% on x86_64 ELF self-compile.
- **CMP + BR_COND fusion.** When a CMP's result is used solely as
  a branch condition (the common `if a == b { … }` pattern), emit
  `cmp; jcc disp32` directly instead of materialising the bool and
  testing it. 14 bytes → 6 bytes per conditional. Guarded by a
  per-vreg use-count so fusion only fires when safe. -6.6%.
- **BR_COND inversion on fallthrough-true.** Emit one inverted jcc
  to the false target and fall through to true when true-target
  is the next BB, instead of `jcc true; jmp false`. -1.5%.

Cumulative x86 self-compile deltas (dist/krc-linux-x86_64 v2.8.13
vs current):
  linux x86_64 ELF      1 422 772 → 1 184 947 B  (-16.7 %)
  macOS x86_64 Mach-O   1 429 504 → 1 191 936 B  (-16.6 %)
  windows x86_64 PE     1 479 168 → 1 244 672 B  (-15.9 %)
  android x86_64 ELF    1 507 328 → 1 310 720 B  (-13.0 %)

### CI
First fully-green cross-platform + ci since 2026-04-17. All 4
pipelines (Linux x86_64/ARM64, macOS x86_64/ARM64, Windows x86_64/
ARM64 native, cross-compile test matrix) pass on this release tag.

## v2.8.13 — 2026-04-18

### Added
- **Modern Greek case folding.** `utf8_lower_codepoint` and
  `utf8_upper_codepoint` now cover the Greek and Coptic block
  (U+0370..U+03FF) in addition to ASCII and Latin-1 Supplement:

  - Α-Ρ ↔ α-ρ and Σ-Ω ↔ σ-ω (+32 pattern, skipping the unassigned
    U+03A2 slot).
  - Accented pairs with tonos / dialytika: Ά↔ά, Έ-Ί↔έ-ί, Ό↔ό,
    Ύ-Ώ↔ύ-ώ, Ϊ-Ϋ↔ϊ-ϋ.
  - Final sigma ς upper-cases to Σ (the "end of word" information
    is lost, same way every Unicode case fold does it).

  `str_lower_utf8("Γειά σου Κόσμε")` → `"γειά σου κόσμε"`.
  `str_upper_utf8("ελληνικός")` → `"ΕΛΛΗΝΙΚΌΣ"`.
  Mixed Latin-1 + Greek text round-trips correctly
  (`"café Ωραία"` → `"CAFÉ ΩΡΑΊΑ"`).

### Out of scope (documented in `std/string.kr`)
- Polytonic Greek (U+1F00..U+1FFF — classical Greek with breathings
  and circumflexes, ~230 codepoints).
- Cyrillic, Armenian, Georgian, and other bicameral scripts.
- One-to-many folds (German ß→SS, Turkish İ→i̇, Dutch IJ).
- Locale-aware transforms.

## v2.8.12 — 2026-04-18

### Added (completion of the v2.8.11 string work)
- **String builder + sprintf-style fill-ins.** `sb_new` / `sb_reserve`
  / `sb_append_byte` / `sb_append_str` / `sb_append_int` /
  `sb_append_hex` / `sb_append_float` / `sb_append_bool` /
  `sb_append_codepoint` / `sb_len` / `sb_finish` / `sb_free`. Doubling
  growth policy, 16-byte header (capacity + length), O(1) amortised
  append. Fills the `sprintf`-shaped gap where f-strings aren't the
  right fit (per-line logger, serialisation, building hundreds of
  strings without allocating each one).
- **UTF-8-aware case folding for ASCII + Latin-1 Supplement.**
  `utf8_lower_codepoint(cp)` / `utf8_upper_codepoint(cp)` /
  `str_lower_utf8(s)` / `str_upper_utf8(s)`. Covers the A-Z / a-z plus
  the À-Þ / à-þ blocks — enough for common Western European text.
  Codepoints outside those ranges pass through unchanged; ASCII-only
  `str_lower` / `str_upper` are still available if you want
  guaranteed locale stability. We deliberately don't ship a full
  Unicode fold table (~1500 entries), one-to-many folds like ß→SS, or
  locale-sensitive transforms — tracked as future work.
- **Combining-mark detection + grapheme count.**
  `utf8_is_combining(cp)` recognises the two combining-diacritical
  blocks (U+0300–U+036F, U+20D0–U+20FF) plus ZWJ/ZWNJ/BOM.
  `str_grapheme_count(s)` counts base codepoints, so both `"café"` and
  `"cafe" + combining-acute` are 4 graphemes. Indic, Arabic joining
  forms, and emoji ZWJ sequences need the full Unicode break-property
  tables and aren't handled here.
- **`str_from_float(v, decimals)`** / **`str_from_bool(b)`** /
  **`str_from_codepoint(cp)`** — symmetric scalar-to-string helpers so
  callers don't have to thread a buffer themselves. Integer form
  already existed as `int_to_str`.

## v2.8.11 — 2026-04-18

### Added
- **`std/string.kr` rounded out** with ten missing functions. Each returns
  a fresh allocation owned by the caller; every one has a test in
  `tests/run_tests.sh` (18 new cases).

  | Function | Description |
  |----------|-------------|
  | `str_index_of(haystack, needle)` | First byte index of substring, or `0xFF..FF` when absent. Empty needle → 0. |
  | `str_compare(a, b) -> u64` | Signed `-1 / 0 / +1` (wrapping to `0xFF..FF` / `0` / `1` in u64). Pair with `signed_lt` / `signed_gt` for sorts. |
  | `str_lower(s)` / `str_upper(s)` | ASCII case conversion; non-ASCII bytes copied verbatim so valid UTF-8 passes through unchanged. |
  | `str_replace(haystack, from, to)` | Replaces every occurrence; empty `from` returns a copy (no infinite loop). |
  | `str_split(s, delim_byte, parts[], max) -> count` | Caller supplies a `u64[]` buffer; trailing delimiter produces an empty segment matching POSIX `strtok_r` semantics. |
  | `str_join(parts[], count, sep)` | Inverse of `str_split`. `count == 0` returns `""`. |
  | `str_to_float(s) -> f64` | Parses `-3.14e2` and friends. Accepts optional leading sign, integer / fractional / exponent parts; non-digit bytes terminate. No hex floats, no "inf" / "nan" literals (yet). |
  | `utf8_decode_at(s, i, out_width) -> codepoint` | Decodes one UTF-8 sequence starting at byte offset `i`; writes the byte width (1..4) through `out_width`. Invalid leading bytes decode as width-1 raw bytes so callers never loop forever on corrupt input. |
  | `utf8_encode(cp, buf) -> width` | Writes `cp` as UTF-8 into `buf`; out-of-range codepoints clamp to U+FFFD. |
  | `str_codepoint_count(s)` | Byte-length ≠ codepoint length once you have multi-byte chars; this returns the latter. |

  Byte-oriented operations (`str_eq`, `str_copy`, `str_cat`, `str_contains`, `str_replace`) are already UTF-8-safe because they work on raw bytes; the new `utf8_*` helpers only matter when you want to *iterate codepoints* (render text, truncate to N characters, uppercase non-ASCII, etc.).

## v2.8.10 — 2026-04-18

### Added
- **Full C-style escape table in string and char literals.** Previously
  only `\n` / `\t` / `\r` / `\0` / `\\` / `\"` / `\'` were translated;
  other backslash sequences silently passed through their *source byte*
  (so `'\b'` evaluated to the byte value of `'b'`, and `"\e[31m"`
  emitted `e[31m` instead of an ESC sequence). Now also handled:

  | Escape | Byte | Description |
  |--------|-----:|-------------|
  | `\b`   |    8 | backspace |
  | `\f`   |   12 | form feed |
  | `\v`   |   11 | vertical tab |
  | `\a`   |    7 | alert / bell |
  | `\e`   |   27 | ESC (handy for ANSI colour codes) |
  | `\xHH` | 0xHH | two-digit hex byte |

  The char lexer now scans up to the closing `'` so `'\xHH'` literals
  fit in a single token. Both the IR lowering and the legacy x86 / ARM64
  emitters share the same two helpers in `codegen.kr`
  (`escape_char_to_byte`, `hex_digit_pair_to_byte`) so the table stays
  in one place.

## v2.8.9 — 2026-04-18

### Added
- **`float` / `double` type aliases** — `float` is a synonym for `f32`,
  `double` for `f64`, matching the C/C++/Java convention. The IR
  backend sees them as identical to `f32` / `f64`; no runtime cost.
  Bootstrap fixed point holds; 335/335 tests pass.

  ```kr
  float pi = 3.14       // same as: f32 pi = 3.14
  double tau = 6.283    // same as: f64 tau = 6.283
  ```

## v2.8.8 — 2026-04-18

IR ARM64 codegen bug bash.

### Fixed
All bugs here are miscompiled ARM64 output from the IR backend — the
shipped krc binaries have been legacy-compiled as a workaround since
v2.8.7, but programs built *by* krc for ARM64 via the IR path
(the default for direct `--arch=arm64`) hit these:

- **`str_eq` returned garbage on equal strings, wrong bool on prefixes.**
  The hand-emitted `CMP w2, w3` had Rd=w2 instead of Rd=wZR, so SUBS
  destroyed the byte in w2 right before the `CBZ w2, equal` check —
  every matching byte looked like "end of string" and made the
  function claim `str_eq("ab","a") == 1`. The surrounding `B.NE`/`CBZ`
  offsets were also encoded with imm19 shifted by 6 bits instead of 5
  (both offsets doubled); those are now `0x540000A1`/`0x340000C2`.
- **`int_to_f32` / `f32_to_int` produced 0 for every value.** SCVTF was
  encoded as `SCVTF Dd, Wn` (double destination, 32-bit int source),
  so 64-bit ints got rounded into a double and the subsequent
  `fmov w, s` pulled garbage low bits. FCVTZS had the mirror bug.
- **`atomic_add` / `atomic_sub` / `atomic_and` / `atomic_or` /
  `atomic_xor` returned the NEW value** (matched neither the doc
  comment "returns old" nor the x86 xadd-based lowering). The retry
  loops now keep the pre-op value in x9 and write the computed result
  from x13 back via STLXR.
- **`atomic_cas` always reported success.** The `B.NE fail` offset
  landed on the `MOVZ d=1` success branch instead of the `MOVZ d=0`
  fail branch, because imm19=3 reached `MOVZ d=1` and skipped all
  three instructions in between. Now `imm19=5`.
- **`memcmp` / `struct ==` returned equal on mismatches.** The CMP
  inside the loop wrote to `w3` (same SUBS-clobber shape as str_eq),
  and the `B.NE not_equal` offset pointed at the `B done` branch
  instead of the `MOVZ d=0` a couple of instructions past it. Both
  fixed together.
- **`println(0.0)` printed `0.0000048`.** The fraction pad-loop
  repurposed x11 as the ASCII `'0'` scratch to feed STRB, but x11
  still held `frac_int` for the subsequent digit-extraction loop. It
  now uses x3 instead, and the per-iteration `x10++` (which
  double-counted the padding bytes) is gone — `add x10, x10, 6`
  after the digit copy handles the full fraction length.
- **`--debug` divide-by-zero didn't trap on ARM64.** ARM64's UDIV
  returns 0 for `x/0` instead of raising like x86 `div`. Added an
  explicit `CBNZ divisor, skip ; exit(1)` guard in debug builds.

### Tests
329/335 pass on an IR-compiled ARM64 krc under qemu-aarch64; the four
x86-only `asm_*` tests are (correctly) skipped on native aarch64 CI.
`device_block_read_write` and `custom_fat_smaller` still fail — the
former maps an absolute VA that qemu's user-mode translator can't
honour, and the latter hits the same compile_fat-on-IR-ARM64 segfault
tracked separately.

## v2.8.7 — 2026-04-18

Android/ARM64 fat-binary segfault fix.

### Fixed
- **`kr krc.krbo` segfaulted on every ARM64 platform (Android, Linux, macOS,
  Windows).** Every recently-released ARM64 krc was IR-compiled, but the IR
  ARM64 backend mis-compiles `compile_fat` itself — the machine code runs
  until it hits LZ4 pair compression, then segfaults inside the compressor.
  The bug survived testing because every prior ARM64 release was manually
  rebuilt with `--legacy` before upload. Now:
  - All four ARM64 slices inside `compile_fat` route through `gen_function_a64`
    (legacy) by default, so `krc.krbo`'s arm64 slice is functional for users.
    `--ir` still forces IR through the fat ARM64 path for backend testing.
  - `make dist` and `.github/workflows/release.yml` pass `--legacy --arch=arm64`
    when building `krc-linux-arm64` / `krc-windows-arm64.exe` /
    `krc-macos-arm64` / `krc-android-arm64` so CI-published binaries also
    boot correctly. The 13% size hit is the cost of correctness; the IR
    ARM64 regression is being isolated separately.
  - Single-architecture builds (`--arch=arm64`) stay on the IR default —
    only the fat-binary path and the shipped krc binaries themselves move
    to legacy.

### Known
- IR ARM64 code generation still mis-handles string compare, atomics,
  struct equality, f32 printing, and several other code patterns when the
  resulting binary is executed natively on ARM64. Tracked for a follow-up.
  Cross-compiled single-arch ARM64 targets that users ship from an x86_64
  host execute fine on ARM64 for the tests they pass locally.

## v2.8.6 — 2026-04-18

compile_fat memory regression fix.

### Fixed
- **`compile_fat` leaked ~4.5 million `alloc(8)` calls per self-compile**,
  pushing peak RSS to 18 GB and OOM-killing GitHub's 16 GB CI runners.
  The offender was `uint64[1]` slot arrays declared inside LZ4's
  match-search hot loop in `format_archive.kr` — KernRift compiles
  `uint64[N]` to a heap `alloc` with no scope-end free, so each of the
  ~1 M compress-loop iterations leaked a slot. Hoisting the two slots out
  of the loop drops the fat-binary build from 17 s / 18 GB to 2 s / 1 GB,
  so CI/release jobs finish well inside the runner budget.
- **IR control-flow snapshot buffers are now freed at their scope end**
  (`if` / `while` / `match` in `ir_lower_stmt` alloc'd per-statement
  bookkeeping and never called `dealloc` on it).

## v2.8.5 — 2026-04-18

Android runner robustness.

### Fixed
- **IR `main()` startup never populated `cli_envp`** — only `cli_argc` and
  `cli_argv` were wired up (legacy codegen set all three). As a result the
  `kr` runner forwarded `envp=NULL` to every child process it spawned; fine
  on plain Linux, but on Android bionic the loader expects a real envp
  vector. Both IR backends (x86_64 and ARM64) now compute envp the same
  way legacy codegen does.

### Added
- **`kr` runner prefers `memfd_create` + `execveat(AT_EMPTY_PATH)` on
  Android.** The extracted slice lives only in an anonymous kernel fd and
  `execveat` ignores the pathname arg, so nothing touches the filesystem —
  no chmod, no SELinux file-label transition, no noexec mount check, no
  leftover `kr-exec` file in the user's cwd. Falls back to the file-based
  path on kernels older than Linux 3.17.

## v2.8.4 — 2026-04-17

User-reported correctness fixes on top of v2.8.3.

### Fixed
- **`kr <prog>.krbo` SIGBUS on Android** — compile_fat's android-arm64 slice
  was missing the 8-byte static-data alignment that direct `--emit=android`
  applies. The resulting slice was 4 bytes shorter and every string/static
  reference shifted; bionic's loader SIGBUSed before main ran. Fat slice
  is now byte-identical to the direct emit output.
- **`println(f32_var)` printed garbage / `-0.000000`** — `f32 x = 6.9`
  took an f64 literal and relabeled the vreg as f32 without narrowing the
  bits; cvtss2sd then read the low 32 bits of the f64 pattern, producing
  a tiny negative number. VarDecl now emits `IR_F64TOF32` on f64→f32
  assignment (and symmetric `IR_F32TOF64` for `f64 x = 1.5f`).
- **Programs without explicit `exit()` segfaulted on return from main** —
  the IR path was missing the auto-insert `exit(0)` syscall that the
  legacy codegen has. Fixed for both x86_64 and ARM64 IR backends.
- **`--emit=linux-x86_64` / `--emit=linux` / `--emit=elf` / `--emit=windows` /
  `--emit=macos`** rejected as unknown formats. Added as aliases for
  `elfexe` / `pe` / `macho`.

## v2.8.3 — 2026-04-17

Language-level polish and Android correctness.

### Added
- **Strict `bool` type** — new keyword, typed `true`/`false`, stored as 1 byte.
  Sema rejects `uint64 x = true` / `bool b = some_int_literal` when the literal
  is tagged with a conflicting type (partial strictness; full strictness gated
  on a future `as` value-cast operator).
- **Strict `char` type + `'x'` literal** — character literal syntax with
  `\n` / `\t` / `\r` / `\0` / `\\` / `\'` / `\"` escapes.
- **Typed `print` / `println`** — routes to a new runtime pipeline:
  `fmt_uint` for integers, `fmt_f64` for floats, `fmt_bool` for bools,
  single-byte write for chars. No more IEEE-bit-pattern dumps when printing f64.
- **Variadic `print(a, b, c)` / `println(a, b, c)`** — strings and typed
  expressions, space-separated, optional trailing `\n` for `println`.
- **f-string interpolation** — `f"x = {expr}"`, with `{{` / `}}` escapes.
  Each `{expr}` routes through the type-directed formatter.
- **IR arena reuse** — `ir_init`, `ir_liveness_init`, `ir_graph_color`, and
  the regalloc inits lazy-allocate shared arenas instead of freshly `alloc`ing
  per function.

### Fixed
- **Android SIGBUS on programs with no static data** — PT_LOAD RW segment was
  being emitted with `p_memsz=0`, which Bionic's dynamic linker rejects by
  SIGBUSing the process before `main()` runs. Fix patches `p_memsz` with the
  page-aligned size (min 64 KB) while keeping `p_filesz=0` for the empty case.
  Applies to `--emit=android` in `compile()` and both android slices in
  `compile_fat()`.
- **Unary minus on floats** — `-3.14` was using integer two's-complement on
  the IEEE 754 bit pattern, yielding garbage. Now lowered as `IR_FSUB(0.0, x)`
  when the operand's fkind is float.
- **Token capacity bump** (196608 → 262144) — current `krc.kr` exceeds the old
  196608-token cap. Pre-2.8.3 bootstrap compilers SIGSEGV on this source.

### Verified
- 335/335 tests pass on Linux x86_64 with IR default.
- Bootstrap fixed point on x86_64 (1,491,135 B) and ARM64 under qemu.

## v2.8.2 — 2026-04-17

Multi-target IR backend complete. Self-compile works on all 8 platforms.

### Added
- **ARM64 IR emitter** (`src/ir_aarch64.kr`) — AArch64 machine-code backend fed by
  the same SSA IR as x86_64. Covers regalloc, arithmetic, comparisons, memory,
  control flow, calls, syscalls, floats, atomics, `asm{}`, and exec.
- **Cross-OS syscall abstraction** — the IR emits Linux-, macOS-, and
  Android-specific syscall conventions from one set of opcodes. `fchmodat`
  (ARM64 syscall 53), `openat` arg shifts, and the macOS entry ABI all resolve at
  emission time.
- **x86_64 and ARM64 Windows PE support in IR** — IR calls into the PE Import
  Address Table for Win32 APIs (`CreateProcessA`, `ReadFile`, `WaitForSingleObject`,
  `VirtualAlloc`, etc.); no syscalls on Windows.
- **macOS self-compile CI job** — validates stage-2 self-compile on
  macos-14 ARM64 with an explicit `.krbo` path.

### Fixed
- **macOS ARM64 `main()` entry ABI** — Mach-O passes `argc`/`argv` in `x0`/`x1`
  (function-call convention), not on the stack like Linux ELF. Both IR and legacy
  codegen now branch on `target_os == 1` to read registers instead of `[SP]`.
- **IR memset liveness** — `memset` was not recorded as defining its destination
  vreg, so the allocator could overwrite the pointer mid-fill.
- **ARM64 spill safety** — large-offset-safe `LDR`/`STR` sequences for spills and
  prologues; removed mid-function `SP` shifts that clashed with spill slots;
  disambiguated `SP` vs `XZR` in `ADD` register encoding.
- **`VarDecl` initializer aliasing** — variable declarations now COPY the init
  value into a fresh vreg so subsequent writes don't poison the source.
- **Liveness off-by-one** — reverse-walk interference construction corrected.
- Windows PE IR bugfixes — `ReadFile` lpOverlapped offset, valid `&bytesRead`
  pointer, `CreateProcessA`/`WaitForSingleObject`/`GetExitCodeProcess`/`ExitProcess`
  wiring for `IR_EXEC` / `IR_EXEC_ARGV`.

### Verified
- 311/311 tests pass on Linux x86_64 with IR as the default backend.
- Bootstrap fixed point (`krc3 == krc4`) holds on all 8 platform targets:
  Linux, macOS, Windows, Android × x86_64, ARM64.

## v2.8.0–v2.8.1 — 2026-04-15

IR backend promoted to default.

### Added
- **`--ir` default** — IR codegen replaces the direct AST walker for all new
  compiles. `--legacy` still falls back to the old path for parity checks.
- **IR coverage completed** — atomics, volatile, inline assembly with I/O
  constraints, 7+ argument calls, struct arrays, slices, device registers,
  static data, tuples, struct-by-value, signed comparisons, float arithmetic.
- Graph-coloring register allocator with interference graph and clobber
  handling on binary ops.

### Fixed
- 310 tests green on IR. Stage-2 self-compile verified.
- Multiple regalloc and liveness fixes discovered by self-compile.

## v2.7.0–v2.7.1 — 2026-04-14

IR scaffolding and float support.

### Added
- **SSA IR foundation** (`src/ir.kr`) — 90+ opcodes, basic block arena,
  AST→IR lowering, iterative liveness analysis, first x86_64 emission pipeline.
- **`--emit=ir`** dumps IR in human-readable form for debugging.
- **Float types `f16`/`f32`/`f64`** with arithmetic, comparisons, conversions,
  `sqrt`/`fma` intrinsics, and a `std/math_float.kr` math library. Full SSE /
  NEON ABI passing. FMA builtin and `f16`↔`f32` conversions on both targets.

## v2.6.2–v2.6.3 — 2026-04-12

Compression and 8th platform slice.

### Added
- **LZ-Rift compression** replaces LZ4 for `.krbo` payloads.
- **BCJ (branch/call/jump) filter** before compression improves ratio on
  machine-code slices.
- **8th target slice**: Android x86_64 joins Android ARM64, so `.krbo` fat
  binaries now cover all 8 OS × arch combinations.

## v2.6.1 - 2026-04-11

Living compiler fully realized + cross-platform verification.

### Added

**Living compiler — all five blueprint stages now implemented:**

- **Migration engine** (`krc lc --fix`, `krc lc --fix --dry-run`):
  source-to-source rewriter that applies auto-fixes in place. Currently
  handles `legacy_ptr_ops` — converts `unsafe { *(addr as T) -> v }` to
  `v = loadN(addr)` and `unsafe { *(addr as T) = val }` to
  `storeN(addr, val)`. `--dry-run` previews without writing.
- **Proposal engine**: 7-proposal registry covering both implemented
  features (slice params, device blocks, load/store builtins, short
  aliases) and planned ones (versioned profiles, tail_call, extern fn).
  Proposals with satisfied triggers fire in the normal lc report with
  before/after snippets and rationale.
- **Governance layer**: each proposal has a lifecycle state
  (`experimental` / `stable` / `deprecated`). `krc lc --list-proposals`
  prints the full registry with current states.
- **Versioned language profiles**: `#lang stable` and
  `#lang experimental` directives parsed at the start of a file. The
  lexer records the profile for downstream feature gating.

### Fixed

- **compile_fat re-parse corruption**: the for-loop parser destructively
  mutates source bytes and tokens to synthesize the `1` literal for its
  desugared while-loop. `compile_fat` re-parses the source up to 7 times
  (once per platform slice), so on the second parse everything was
  corrupted. Files with for loops failed fat binary builds with
  `expected token, got integer '1'`. Fix: snapshot source and tokens at
  the top of `compile_fat` and restore before each subsequent parse.
- **`byte` and `addr` keywords removed**: they were documented as short
  aliases but making them reserved words broke any program using them
  as variable names (very common). `u8/u16/u32/u64/i8/i16/i32/i64`
  remain as aliases.

### Verified

- **64/64 platform cross-compile matrix** — every example compiles and
  runs correctly for every target: Linux x86_64, Linux ARM64, Windows
  x86_64, Windows ARM64, macOS x86_64, macOS ARM64, Android ARM64, plus
  fat binaries (7-slice `.krbo`).
- Bootstrap fixed point holds, 131/131 tests pass.

## v2.6.0 - 2026-04-11

Major language expansion — pointers, arrays, and MMIO made first-class.

### Added
- **Short type aliases**: `u8/u16/u32/u64`, `i8/i16/i32/i64`, `byte`, `addr`.
  All map to the same storage as the long forms (`uint8`..`int64`).
- **Pointer load/store builtins**: `load8/16/32/64(addr)` and
  `store8/16/32/64(addr, val)` — the clean way to read/write memory.
  Much shorter than `unsafe { *(addr as u32) = val }`.
- **Volatile pointer builtins**: `vload8/16/32/64` and `vstore8/16/32/64`
  emit the load/store plus a memory barrier (`mfence` on x86_64, `DSB SY`
  on ARM64) — for MMIO.
- **`print_str(s)` / `println_str(s)`**: print the contents of a
  null-terminated string from a variable pointer. Fixes the long-standing
  issue where `println(int_to_str(42))` printed the pointer address.
- **Static arrays**: `static u8[N] name` at module level — allocates N
  bytes in the data section.
- **Struct arrays**: `Point[10] pts` with `pts[i].field` read/write syntax.
- **Slice parameters**: `fn foo([u8] data)` takes a (ptr, len) fat pointer.
  Inside the function, `data.len` reads the length. Callers pass two
  arguments (pointer and length).
- **Device blocks for MMIO**: `device UART0 at 0x3F201000 { Data at 0x00 : u32 ... }`.
  Reads and writes to device fields compile to volatile load/store with
  the appropriate barrier.
- **`examples/` directory**: runnable programs for every feature.

### Fixed
- **Method calls**: `p.method()` now parses correctly (was a parser error).
- **Struct-by-value parameters**: `fn foo(Point p)` now registers `p` as
  a struct variable, so `p.field` inside the function works.
- **`std/io.kr` `print_line` and `print_kv`**: previously called
  `println(s)` which printed pointer addresses. Now use `print_str`.

### Docs
- **LANGUAGE.md**: rewritten to match what the compiler actually does.
  Removed the kernel-safety sections (`@ctx`, `@eff`, `lock`, `percpu`,
  `tail_call`, `critical`, etc.) that were documented but not implemented.
- **README.md** and **getting-started.md**: updated with the new pointer
  syntax, corrected built-in list, and real examples.

### Deferred
- `extern fn` declarations with ELF relocation emission — planned, not
  implemented yet. Requires adding `.rela.text` relocations for
  `R_X86_64_PLT32` and `R_AARCH64_CALL26`.

## v2.5.2 - 2026-04-10

### Added
- **`scan_int()` in std/io.kr**: reads a line from stdin and parses it as an integer (handles whitespace and negative sign).
- **`scan_str()` in std/io.kr**: reads a line from stdin (up to 1024 bytes).

### Fixed
- **ARM64 volatile barriers**: changed `DMB ISH` to `DSB SY` for MMIO correctness (ensures write completion, not just ordering).
- **x86_64 LEA optimization**: `pinned_param ± imm` emits `lea rax, [rbx ± imm]` (4 bytes vs 18).
- **Buffer size increases**: `fn_table`, `static_table`, `fnaddr_fixup_table` increased to 1024; `ret_fixups` to 256.

## v2.5.0 - 2026-04-09

### Added
- **`syscall_raw` builtin**: raw syscalls on all platforms.
- **ARM64 >8 parameter support**: AAPCS64 stack overflow for functions with more than 8 arguments.
- **`krc fmt` auto-formatter**: `krc fmt <file.kr>` auto-formats KernRift source.
- **`--emit=asm` improved decoders**: x86_64 and ARM64 disassembly now includes full operands.
- **std/time.kr**: `clock_gettime`, `nanosleep` for time operations.
- **std/log.kr**: structured logging with levels.
- **std/net.kr**: raw socket operations.

### Tested
- for-loop, enum, string escape tests (125 total).

### Fixed
- **`str_fixups` buffer overflow**: increased from 1024 to 4096; fixes Windows PE generation for large programs.
- **for-loop parser and Block node codegen**: correct parsing and code generation for `for` loops.

## v2.4.1 - 2026-04-08

### Added
- **Atomic builtins**: `atomic_sub`, `atomic_and`, `atomic_or`, `atomic_xor` — arithmetic and bitwise atomic operations on x86_64 (`LOCK` prefix) and ARM64 (`LDXR`/`STXR`).
- **Signed pointer cast types**: `int16`, `int32`, `int64` now work in `unsafe`/`volatile` pointer operations (was uint-only).
- **`--emit=asm` disassembly**: `--emit=asm` now produces a disassembled listing with function labels.
- **`krc --help` / `krc -h`**: compiler prints usage information instead of crashing.
- **`kr --version` / `kr --help` / `kr` (no args)**: runner prints proper output instead of crashing.

### Fixed
- **Android `kr` runner**: tries `/data/local/tmp` first for adb push, falls back to cwd for Termux.
- **Termux SELinux**: `kr` uses a shell wrapper to bypass SELinux `execve` restriction on Termux.
- **Android linker argv shift**: detects and skips injected exe path from the Android linker.
- **`exec_process` robustness**: restores SP on failure and saves `errno`.
- **`exec_process` environment**: passes environment to `execve`.
- **Functions with >6 parameters**: overflow args now correctly passed on the stack (SysV x86_64 ABI). Fixes `panel_new`, `button_new`, `progress_new`.
- **`--emit=asm` MRS/MSR decoder**: fixed bitmask `0xFFE00000` to `0xFFF00000`.

## v2.4.0 - 2026-04-08

### Added
- **uint16 pointer operations**: read/write through `u16` pointers in `unsafe`/`volatile` blocks (both x86_64 and ARM64).
- **ARM64 MSR/MRS system register access**: inline `asm` blocks can now read/write 20+ kernel-mode system registers via MRS/MSR instructions.
- **Volatile memory barriers**: `volatile { ... }` blocks now emit hardware memory barriers (`mfence` on x86_64, `DMB ISH` on ARM64).
- **Atomic builtins**: `atomic_load`, `atomic_store`, `atomic_cas`, `atomic_add` — emits `LOCK` prefix on x86_64 and `LDXR`/`STXR` sequences on ARM64.
- **Builtin argument count validation**: semantic analyzer now checks argument counts for all builtin functions at compile time.
- **std/color.kr**: `rgb`, `rgba`, `alpha_blend`, `color_lerp`, `darken`/`lighten`, 11 named color constants.
- **std/fixedpoint.kr**: 16.16 fixed-point math — `mul`, `div`, `sqrt`, `lerp`, `clamp`.
- **std/memfast.kr**: `memcpy32`/`memcpy64`, `memset32`/`memset64`.
- **std/fb.kr**: framebuffer primitives — `pixel`, `rect`, `line`, `blit`, `clear`, `rect_outline`.
- **std/font.kr**: complete 8x16 bitmap font covering ASCII 32–126 (95 characters).
- **std/widget.kr**: UI widgets — `panel`, `label`, `button`, `progress_bar`, `text_input`.

### Tested
- 13 new tests for uint16, atomics, volatile, and MSR/MRS (119 total).

## v2.3.0 - 2026-04-05

### Fixed
- **kr runner execution**: `kr` runner now executes extracted binaries via `set_executable` + `exec_process`.
- **exec_process Windows crash**: `exec_process` uses `lpApplicationName` to avoid read-only string crash.
- **kr runner Windows args**: `kr` runner correctly parses Windows command line via `win_init_args_r`.
- **Android kr temp path**: Android `kr` uses `/data/local/tmp/.kr-exec` (no `/tmp` on Android).
- **exec_process argv**: `exec_process` passes proper `argv` array to `execve`.

### Changed
- **Release workflow**: add macOS and Android binaries to release workflow (17 total assets).

## v2.2.0 - 2026-04-03

### Added
- **Android ARM64 support**: PIE ELF format for Android `aarch64` targets.
- **Semantic analysis pass**: argument count checking, missing return detection, duplicate function detection.

### Fixed
- **ARM64 codegen fixes**: SP encoding, large stack frames, and bit operation correctness.
- **Windows PE fixes**: stack alignment and digit buffer overflow.

## v2.1.1 - 2026-04-02

### Added
- **Universal fat binary**: `.krbo` now contains 7 slices — Linux ELF (x86_64 + arm64), Windows PE (x86_64 + arm64), macOS Mach-O (x86_64 + arm64). One binary runs everywhere.
- **BCJ compression filters**: x86_64 and AArch64 Branch/Call/Jump filters normalize instruction offsets before LZ4 compression, yielding ~9% better compression on real binaries.
- **Loader-resolved IAT**: Windows PE binaries have all 13 API imports (ExitProcess, GetStdHandle, WriteFile, CreateFileA, ReadFile, CloseHandle, VirtualAlloc, GetCommandLineA, GetFileSizeEx, CreateProcessA, WaitForSingleObject, GetExitCodeProcess, GetModuleFileNameA) resolved directly by the Windows PE loader at startup — no runtime GetProcAddress resolver needed.
- **Windows `kr` runner**: `kr.exe` extracts and executes Windows PE slices from `.krbo` fat binaries using CreateProcessA.
- **Windows stdlib support**: `install.ps1` downloads the standard library to `%LOCALAPPDATA%\KernRift\std\`. The compiler discovers stdlib via `GetModuleFileNameA` relative to its own path.
- **New built-in functions**: `get_target_os()`, `get_arch_id()`, `exec_process(path)`, `get_module_path(buf, size)` — compile-time platform detection and cross-platform process execution.
- **VS Code file icon**: `.kr` files show a minimal blue cracked K icon (auto-enabled via `languages[].icon`, no theme selection needed).
- **macOS Mach-O in fat binary**: Cross-compiled from Linux using existing `--emit=macho` support, tested via GitHub Actions macOS runners.

### Fixed
- **Undeclared identifier detection**: Using an undeclared variable (e.g., `cli_argv` without `static` declaration) now produces `error: use of undeclared identifier 'cli_argv'` at compile time instead of silently compiling to a null pointer dereference (SIGSEGV at runtime).
- **Fat binary buffer overflow**: Output buffer was 1MB but 6-slice compressed data exceeded it, causing silent truncation. Increased to 4MB.
- **Cross-platform CI tests**: `|| true` in test harness was swallowing exit codes, making all non-zero exit tests appear to fail on macOS.
- **Windows install script**: `install.ps1` now downloads from GitHub releases (was looking for local `dist/` binary that doesn't exist).
- **Release CI**: Bootstraps from previous release binary instead of outdated Rust `kernriftc`.

## Unreleased

### Added
- **Kernel-first features**: 10 features for bare-metal and kernel development:
  - **Inline assembly**: `asm("nop")` and `asm { "cli"; "sti" }` with x86_64 privileged instructions (cr0/cr3/cr4, lgdt, lidt, invlpg, cpuid, wrmsr, rdmsr, in/out, swapgs, iretq) and ARM64 system instructions (wfi, wfe, sev, isb, dsb, dmb, svc, eret). Raw hex byte emission for arbitrary encodings.
  - **@naked functions**: No prologue/epilogue — pure assembly bodies for ISR entry points.
  - **@noreturn functions**: Marks diverging functions (epilogue omitted).
  - **@packed structs**: No alignment padding between fields.
  - **@section attribute**: Place functions in specific linker sections (stored for future linker script support).
  - **Signed comparisons**: `signed_lt()`, `signed_gt()`, `signed_le()`, `signed_ge()` builtins using x86 setl/setg and ARM64 CSET LT/GT.
  - **Bitfield operations**: `bit_get()`, `bit_set()`, `bit_clear()`, `bit_range()`, `bit_insert()` builtins for hardware register manipulation.
  - **Volatile blocks**: `volatile { ... }` as explicit MMIO intent (same codegen as unsafe, forward-compatible with future optimizer).
  - **Stack size warnings**: Compile-time warning when a function's stack frame exceeds 4096 bytes.
  - **Freestanding mode**: `--freestanding` flag disables _start trampoline, auto-exit, and OS-specific syscall wrappers.
- **Self-contained toolchain**: `kernriftc` now produces native executables for all major platforms without any external tools.
  - Native ELF executable writer (`--emit=elfexe`) — no longer needs `ld`.
  - Native `.a` archive writer (`--emit=staticlib`) — no longer needs `ar`.
  - PE32+ executable writer for Windows x86_64 and AArch64 (with import directories).
  - Mach-O executable writer for macOS x86_64 and AArch64 (with dyld/libSystem linkage).
  - Native host executable emitter (`--emit=hostexe`) — no longer needs `cc`/`gcc`/`clang` on any platform.
- **6 platform runtime blobs**: hand-assembled machine code for Linux/macOS/Windows x86_64 and AArch64. Implements `_start`, `__kr_exit`, `__kr_write`, `__kr_mmap_alloc`, `__kr_alloc`, `__kr_dealloc`, `__kr_getenv`, `__kr_exec`, `__kr_str_copy`, `__kr_str_cat`, `__kr_str_len`.
- **Port I/O intrinsics**: `inb(port)`, `outb(port, val)`, `inw`, `outw`, `ind`, `outd` — x86_64 built-in intrinsics that emit native `IN`/`OUT` instructions. AArch64 produces a clear compile-time error (ARM has no port-mapped I/O).
- **`@syscall(nr, args...)` intrinsic**: generic syscall for Linux/macOS on both x86_64 and AArch64.
- **9 built-in host functions**: `write`, `alloc`, `dealloc`, `getenv`, `exec`, `exit`, `str_copy`, `str_cat`, `str_len` — available in `@ctx(host)` code without `extern fn` declarations, mapped to `__kr_*` runtime symbols.
- **Slice indexing**: `buf[i]` read and `buf[i] = val` write syntax for array element access.
- **KrboFat v2**: format version bumped with `runtime_offset`/`runtime_len` fields per entry.

### Changed
- **ApexRift drivers migrated**: all 7 driver `.kr` files now use built-in `inb`/`outb` intrinsics instead of `extern fn aos_inb/outb`.
- **`build.kr` migrated**: build script uses built-in host functions (`write`, `getenv`, `exec`, `str_len`, `exit`) instead of libc externs (`puts`, `system`, `getenv`, `exit`).
- Relaxed canonical-exec validation: general-purpose code with multiple variables and computed returns now compiles without rejection.

## v1.0.0 - 2026-03-24

### Added
- AArch64 (ARM64) backend: `aarch64-sysv` (Linux), `aarch64-macho` (macOS), `aarch64-win` (Windows).
- `KRBOFAT` fat binary container: 8-byte magic `KRBOFAT\0`, LZ4-compressed per-arch slices, fat-first detection (checked before single-arch `KRBO` magic).
- Default `kernriftc <file.kr>` output is now a fat binary (`.krbo`) containing x86_64 and ARM64 slices.
- `--arch x86_64|arm64|aarch64` flag: routes compilation to the specified target; output is still a fat binary. `aarch64` is an accepted alias for `arm64`.
- `--emit=krbofat` explicit fat binary emit mode (equivalent to default compile).
- `--emit=krboexe` for single-arch x86_64 KRBO (unchanged from prior behavior when requesting single-arch output explicitly).
- Dual-file output for `--emit=elfobj`, `--emit=asm`, `--emit=staticlib` without `--arch`.
- `kernrift` runner: fat-first detection reads 8-byte magic before the 4-byte single-arch check; extracts host-arch slice and executes it.
- ARM64 I-cache flush: `kernrift` flushes the instruction cache after writing ARM64 code to executable memory (required for AArch64 coherence on all Linux/macOS ARM64 hosts).
- New `krir` crate constants and APIs: `KRBO_ARCH_AARCH64` (`0x02`), `KRBO_FAT_MAGIC`, `KRBO_FAT_VERSION`, `KRBO_FAT_ARCH_X86_64`, `KRBO_FAT_ARCH_AARCH64`, `KRBO_FAT_COMPRESSION_NONE`, `KRBO_FAT_COMPRESSION_LZ4`, `emit_aarch64_executable_bytes()`, `emit_aarch64_elf_object_bytes()`, `emit_aarch64_macho_object_bytes()`, `emit_aarch64_coff_object_bytes()`, `emit_krbofat_bytes()`, `parse_krbofat_slice()`.
- New `krir` types: `TargetArch::AArch64`, `TargetAbi::Aapcs64`/`Aapcs64Win`, `BackendTargetId::Aarch64Sysv`/`Aarch64MachO`/`Aarch64Win`, `AArch64IntegerRegister` (X0–X15, X19–X30, Sp, Xzr; X16/X17/X18 excluded), `lower_executable_krir_to_aarch64_asm()`.
- New `kernriftc` CLI: `BackendArtifactKind::KrboFat` ("krbofat").
- New spec docs in `docs/spec/`: `aarch64-asm-linear-subset-v0.1.md`, `aarch64-object-linear-subset-v0.1.md`, `backend-target-model-aarch64-sysv-v0.1.md`, `backend-target-model-aarch64-macho-v0.1.md`, `backend-target-model-aarch64-win-v0.1.md`, `krbofat-container-v0.1.md`.

### Fixed
- `kernrift` runner: `map_uart_buffer` falls back to a kernel-chosen address when `mmap(MAP_FIXED)` at `0x10000000` is rejected (macOS CI ARM64 and Windows CI return `ENOMEM`/`null` for fixed mappings); programs with no MMIO (e.g. `examples/smoke_noop.kr`) are unaffected.
- `kernrift` runner (Unix): `map_executable` now maps `PROT_READ|PROT_WRITE` first, copies code, then `mprotect`s to `PROT_READ|PROT_EXEC`; avoids rejection of `PROT_WRITE|PROT_EXEC` on macOS CI (W^X enforcement).
- `kernrift` runner (Windows): `map_executable` calls `FlushInstructionCache` after writing JIT code; fixes SIGILL (exit 132) on Windows ARM64 where the I-cache and D-cache are incoherent.
- `krir` tests: 9 ELF-link tests now compile-gated with `#[cfg(all(unix, target_arch = "x86_64"))]`; `ld` on Windows emits PE (MZ magic), not ELF — those tests no longer run on Windows.

### Platform notes
- **macOS x86_64**: CI builds and ships the binary but execution on Intel Mac hardware has not been independently verified. Use with caution and report any issues.

### Tested
- `examples/smoke_noop.kr` compiled on Pi 400 (aarch64 Linux), fat binary pulled and run on x86_64 — exit 0.
- `examples/smoke_noop.kr` compiled on x86_64, fat binary run on Pi 400 — exit 0.

## v0.3.1 - 2026-03-23

### Added
- `kernrift` split into its own crate so `cargo install` tracks both binaries independently.
- `elfexe` emit target: `kernriftc --emit=elfexe` links an ELF ET_EXEC binary using `ld.lld`/`ld`.
- Dead function elimination pass: strips functions unreachable from `@export`/`@ctx(boot)`.
- Link-time lock graph merge: `kernriftc link` detects cross-module lock-order cycles.
- `kernriftc lc` alias: short form for `kernriftc living-compiler` (alias kept).
- Three new living-compiler patterns: `irq_raw_mmio`, `high_lock_depth`, `mmio_without_lock`.
- `lc --ci`: exit 1 if any suggestion fitness ≥ 50 (override with `--min-fitness N`).
- `lc --diff <file>`: show only new/worsened suggestions vs git HEAD.
- `lc --diff <before> <after>`: two-file local diff, no git dependency.
- `lc --fix --dry-run`: preview tail-call fixes as a unified diff.
- `lc --fix --write`: apply tail-call fixes in place, atomically.

### Improved
- **Syntax error messages** — all TokParser diagnostics now show human-readable token names
  instead of Rust debug format (e.g. `got '{'` instead of `got LBrace`).
  Specific improvements:
  - Missing return type after `->`: suggests valid types and `-> u64` example.
  - `if` without a condition: points at the `{` and suggests a boolean expression.
  - `let` keyword: directs to typed declaration syntax (`u64 x = ...`).
  - Undeclared variable assignment: names the variable and suggests declaration syntax.
  - Duplicate symbol: includes source location in the error.
  - Missing comma between call arguments: flags the unexpected token.
  - `mmio`/`mmio_reg` inside a function body: reports module-scope restriction.
  - `expect_kind` and all inner parser helpers use readable token names.
- `token_kind_to_str` is now exhaustive — every `TokenKind` variant maps to a display string.

## v0.2.10 - 2026-02-27

### Changed
- KRIR v0.1 acceptance script added: `tools/acceptance/krir_v0_1.sh`.
- Verify-report schema documentation tightened and strictness negative tests added for unknown keys/invalid enum values.
- KRIR spec updated with explicit verify-report ABI strictness table.

### Notes
- Product-only release.
- No infra/release workflow changes.
- `v0.2.9` remains frozen.

## v0.2.9 - 2026-02-27

### Changed
- KRIR v0.1: added schema-validated verify report ABI v1 (`docs/schemas/kernrift_verify_report_v1.schema.json`).
- `verify --report` now validates emitted report JSON against embedded schema with deterministic canonicalization.
- Expanded golden matrix for verify/report edge cases:
  - invalid UTF-8 contracts
  - schema-invalid contracts
  - signature mismatch
  - invalid signature/public key parsing
  - report overwrite refusal
- Aligned verify report output writing to guarded safe-write behavior (no overwrite + staged write flow).

### Notes
- User-visible product update: verify report format and coverage are now regression-locked in golden tests.

## v0.2.8 - 2026-02-23

### Changed
- Infra-only: release pipeline now signs/verifies archives only (`.tar.gz`, `.zip`).
- `.sha256` files remain unsigned convenience artifacts.

### Notes
- No compiler behavior changes vs v0.2.7.

## v0.2.7 - 2026-02-23

### Changed
- Fixed Windows cosign self-verification identity regex in release workflow.

### Notes
- `v0.2.6` introduced portable Linux checksums + signature self-verify, but release failed on Windows identity regex mismatch; use `v0.2.7`.

## v0.2.6 - 2026-02-23

### Changed
- Linux release checksum files now use archive basenames (portable `sha256sum -c` outside CI workspace layout).
- Release pipeline now self-verifies cosign signatures/certificates before uploading artifacts.

### Notes
- Infra-only release: no compiler behavior changes vs v0.2.5.

## v0.2.5 - 2026-02-23

### Changed
- Added `kernriftc --version` / `kernriftc -V` output (`kernriftc <semver>`) for release automation checks.

### Notes
- `v0.2.4` introduced release gating/signing workflow changes but failed release execution due missing CLI `--version`; use `v0.2.5`.

## v0.2.4 - 2026-02-23

### Changed
- Release pipeline now runs `fmt`/`clippy`/`test` gates before packaging artifacts.
- Release pipeline now signs artifacts with cosign keyless and publishes `.sig` + `.cert` files.
- Release build uses `--locked` and enforces tag/version match (`vX.Y.Z` == `kernriftc --version`).

### Notes
- This release is product-aligned and supersedes infra-only release tags (`v0.2.1`, `v0.2.2`).

## v0.2.3 - 2026-02-23

### Changed
- Infra: CI guards + release automation; no compiler behavior changes since v0.2.0.
- Versioning policy: tags/releases now track `kernriftc --version` (product-aligned).

### Notes
- v0.2.1 and v0.2.2 were infra-only tags; v0.2.3 is the aligned product tag.

## v0.2.0 - 2026-02-22

### Added
- Integrated policy gate in `check`:
  - `kernriftc check --policy <policy.toml> <file.kr>`
  - `kernriftc check --policy <policy.toml> --contracts-out <contracts.json> <file.kr>`
- Policy evaluator command:
  - `kernriftc policy --policy <policy.toml> --contracts <contracts.json>`
- Canonical contracts artifact outputs from `check`:
  - `--contracts-out`, `--hash-out`, `--sign-ed25519`, `--sig-out`
- Artifact verification command:
  - `kernriftc verify --contracts <contracts.json> --hash <contracts.sha256> [--sig <contracts.sig> --pubkey <pubkey.hex>]`

### Changed
- Policy diagnostics are now deterministic and code-prefixed:
  - `policy: <CODE>: <message>`
- Policy `max_lock_depth` is evaluated from `report.max_lock_depth`.
- Exit code split is enforced:
  - `0` success
  - `1` policy/verification deny
  - `2` invalid input/config/schema/decode/tooling errors

### Safety Hardening
- Embedded contracts schema is used for validation (distro-safe, no repo path dependency).
- `check` refuses overwriting existing output files.
- Output writes use staged temp files before commit.
- `verify` now requires UTF-8 contracts content and schema/version-valid contracts payload (not only hash/signature match).
