# KernRift → MLRift Port Scope (working doc — DO NOT COMMIT)

> **Status:** working / context-preservation doc. Not committed by design (per user).
> **Created:** 2026-07-19. **Provenance:** consolidated from three parallel scoping
> agents (backends / IR-frontend / correctness-tooling) run against KernRift
> `src/*.kr` (source of truth) and MLRift `src/*.mlr` (port target) at
> `/home/pantelis/Desktop/Projects/Work/{KernRift,MLRift}`.
> The two are sibling self-hosting compilers with shared fork lineage but
> **independent git histories** — everything below was diffed at the source/feature
> level, using KernRift's `git log` as a candidate menu and checking each item
> against MLRift's current source. Line numbers are anchors valid as of the scan.
>
> **Why this doc exists:** the user wants the full porting context to survive across
> sessions and sidetracks. The original per-agent reports lived in a session
> scratchpad (ephemeral); their full detail is folded in here so nothing is lost.
> The user has separately discovered **gaps/holes in the Xtensa backend** that need
> filling first — see §10, reserved for those, to be filled in next.

---

## 0. TL;DR / current decision state

- **Goal driving the idea:** run ML workloads (facial recognition, etc.) on
  ESP32/Xtensa-class MCUs by porting KernRift's new scalar backends into MLRift,
  and while at it, port any other KernRift improvements that benefit MLRift.
- **Key finding that reframes the goal:** the backend graft is **necessary but not
  sufficient** for ML-on-MCU. MLRift's ML kernels are hand-written AMDGPU
  machine-code blobs, **not** lowered from the shared SSA IR, so a scalar
  riscv/xtensa backend has nothing to lower ML through. See §1 and Track B (§4).
- **What's actually cheap & high-value right now:** the correctness ports (§5),
  especially the `IR_STACK_ADDR` stack-array leak fix (MLRift task #102). These
  are independent of the backend/ML question and benefit MLRift today.
- **Order not yet decided.** Porting is deferred; the immediate next step (per user)
  is to fill the Xtensa gaps (§10) before any porting begins.

### Backlog at a glance

| Track | Item | Class | Effort | Value | Independent? |
|---|---|---|---|---|---|
| **C** | Stack-local arrays → `IR_STACK_ADDR` (task #102) | clean graft, multi-site | **M** | HIGH (leak + perf) | yes |
| **C** | Struct field/size overflow guards | clean graft | **LOW** | MED (stops silent corruption) | yes |
| **C** | arm64 signed/NaN compare batch | VERIFY then maybe port | S to check | HIGH-if-exposed (silent miscompile) | yes |
| **C** | std/io read_file errno + std/map 64-key cap | VERIFY then maybe graft | LOW | crash/hang | yes |
| **D** | Structural type checker (13 rules → analysis.mlr) | dialect relocation | **M–H** | robustness | yes |
| **A** | riscv32 backend graft | port + dialect xlate | **L** | foundational | prereq for B |
| **A** | xtensa backend graft | port + dialect xlate | **L** | foundational (ML target) | prereq for B |
| **B** | Portable scalar/int8 ML lowering + float story | net-new | **XL** | the actual ESP32 ML deliverable | needs A |

---

## 1. STRATEGIC REFRAME — backend graft ≠ ML on ESP32

Investigated how MLRift actually produces ML/tensor work:

1. **MLRift's ML kernels are hand-written AMDGPU machine-code blobs, not IR.** The
   real inference kernels — GEMV, GEMM, attention-decode, RoPE, KV-broadcast,
   AdamW-fused, quantized q4_0/bf16/f32 — are emitted by ~40+ `emit_amdgpu_*`
   functions (driver sites `main.mlr:4650–4951`; bodies in `format_amdgpu.mlr`
   ~1.06 MB + `format_amdgpu_megakernel.mlr` ~0.6 MB). These are **assembled GPU
   binaries**, not lowered from the shared SSA IR. A scalar riscv/xtensa backend
   emits **none** of them.
2. **No portable scalar/CPU tensor lowering exists.** No `IR_TENSOR`/`IR_MATMUL`/
   `IR_CONV` opcodes; no scalar `cpu_gemm`/`cpu_matmul`/soft-float reference path.
   ML in MLRift == the GPU mega-kernel path, or nothing.
3. **The scalar backends refuse floats outright.** riscv32 `rv_float_trap()`
   (`ir_riscv.kr:150`): traps on all float opcodes (20–27, 97–108, FMT_F64) and any
   float-kinded vreg (`ir_riscv.kr:1119`); RV32IMC also rejects all 64-bit types
   (word size 4). Xtensa rejects floats via sema (`ir_xtensa.kr:429,1101`). Neural
   inference is float-dominated, so today's backends would reject the arithmetic
   even if it reached IR.

**Verdict:** the backend port delivers an **integer-only** freestanding emitter that
boots under qemu and prints over a `device`-declared 16550 UART. It does **not**
deliver facial recognition on ESP32. Reaching the ML goal additionally requires a
**separate, larger** effort (Track B): (a) a portable scalar / integer-quantized ML
lowering path in MLRift's shared IR, and (b) soft-float / fixed-point / int8-quantized
arithmetic in the scalar backends (or targeting the Xtensa LX6 FPU with float codegen
the current backend explicitly refuses). Int8/fixed-point quantized inference is the
realistic MCU route.

---

## 2. Track A — Backend graft (riscv32 + xtensa)

### 2.1 Files to CREATE (transcribe .kr → .mlr)

| New MLRift file | From KernRift | Size | fns | Contents |
|---|---|---|---|---|
| `src/ir_riscv.mlr` | `src/ir_riscv.kr` | 2873 L | 52 | IR→RV32IMC lowering, regalloc (s0–s11), spill slots, C-compression peephole; top entry `ir_riscv_gen(fn_node)` @2255 |
| `src/codegen_riscv.mlr` | `src/codegen_riscv.kr` | 1018 L | 13 | Elf32 Ehdr/Phdr (`emit_elf_header`/`_program_header`), Elf32 relocatable `.o` writer, raw-flat helpers, hex/dec fmt |
| `src/ir_xtensa.mlr` | `src/ir_xtensa.kr` | 1915 L | 93 | IR→Xtensa LX6 lowering, SP-init preamble; top entry `ir_xtensa_gen(fn_node)` @1480 |
| `src/codegen_xtensa.mlr` | `src/codegen_xtensa.kr` | 54 L | 2 | `emit_elf_header_xtensa` @15, `emit_program_header_xtensa` @44 (Elf32 boot image only) |

Bulk of the work is the two `ir_*.kr` files; the `codegen_*` files are small.

### 2.2 Files to MODIFY

- **`src/main.mlr`**
  - `--arch=` parser (~4571): add `riscv`→arch 2, `xtensa`→arch 3. Mirror KR
    `main.kr:4691–4701` (`str_starts_with(arch_str,"riscv",5)`→2, `"xtensa",6`→3).
  - **Per-function codegen dispatch**, anchor `main.mlr:2448–2456`:
    ```
    if arch == 0 { gen_function(wchild) }          // x86
    else if arch == 1 { gen_function_a64(wchild) } // arm64
    ```
    add `else if arch == 2 { ir_riscv_gen(wchild) }` / `arch == 3 { ir_xtensa_gen(wchild) }`.
    Duplicate at the other walk sites: `main.mlr:3336 / 3447 / 3544 / 3652`.
  - **compile() image-emission arms** (mirror KR `main.kr`): raw-flat gate
    `arch==2 && emit_mode==0 && freestanding!=0` (KR @2280); xtensa raw-blob gate
    `arch==3 && …` (KR @2290); Elf32 container for riscv hosted / xtensa boot
    (KR @2360–2420: `emit_elf_header_xtensa()`+`emit_program_header_xtensa()`);
    fixup resolver `resolve_fnaddr_fixups_riscv()` (KR @2657).
  - **NYI guards:** port `riscv32_nyi()` (KR @813) and `xtensa_nyi()` (KR @825).
    KR routes arch 2/3 explicitly to these at every dispatch site it hasn't wired
    (Mach-O/PE/Android emission etc.), so arch 2/3 never falls through to an
    x86/arm arm. ~60 `arch == N` sites in `main.kr`; the port adds arch 2/3 arms
    (real or `_nyi`) at the analogous MLRift sites.
- **`src/analysis.mlr`** (MLRift has **no** `type_check.mlr` — sema lives here):
  port KernRift `type_check.kr`'s arch restrictions:
  - `tc_riscv32_reject_kind()` (KR `type_check.kr:266`): reject 64-bit int kinds
    83/87 and float kinds 94–96 under `target_arch==2/3`.
  - call sites: type annotations (@232–233); 32-bit literal overflow for arch 2/3
    (@410 `diag_fatal "integer literal does not fit in 32 bits"`); return types
    (@958); `let`-inferred float kinds (@1065). MLRift already has the
    diag/report_error_at + token-kind machinery; `analysis.mlr:1569–1597`
    (float-scrutinee reject) is a working model to copy.
- **`Makefile`** SRCS (~lines 13–14): append the 4 files, mirroring KR Makefile
  line 15 order: `ir_riscv codegen_riscv ir_xtensa codegen_xtensa`.
- **tests**: add qemu boot tests — riscv `-machine virt` (raw blob via `-bios`),
  xtensa `-M lx60` (Elf32); assert 16550 UART output. (Model on KernRift's
  `riscv_hello_boot` and the new `xtensa_stress_boot` full-output-equality test.)

### 2.3 Prerequisites in MLRift

| Prereq | Status | Note |
|---|---|---|
| `--freestanding` flag | **PRESENT** | `main.mlr:5919` parse, `:4516` global |
| `device`-block / MMIO lowering | **PRESENT** | parser `device NAME at ADDR {…}` (`parser.mlr:2348`); IR read (`ir.mlr:3087` device_lookup/field_offset/base) + write (`ir.mlr:4299`); `IR_VLOAD=95`/`IR_VSTORE=94` exist. Shared frontend/IR — arch-agnostic, comes free. |
| raw flat-binary emission | **ABSENT** | Travels inside compile() gate; part of the port. |
| Elf32 image emission | **ABSENT** | No ELFCLASS32 writer in MLRift (has ELF64/Mach-O/PE/android/archive). Elf32 Ehdr/Phdr+reloc writer travels **inside** codegen_riscv/xtensa.mlr — arrives with the ported files. |
| per-arch register count `IR_NUM_REGS` | **PRESENT** | `ir.mlr:5232 static uint64 IR_NUM_REGS = 6` — mutable global, identical to KR. KR riscv does save/set(12)/restore around regalloc (`ir_riscv.kr:2300`…`2610`). Works out of the box. |
| arch enum / `target_arch` dispatch | **PARTIAL** | `set_target_arch()` exists; only arch 0/1 wired. Add 2/3 at ~60 sites. **NB:** `amdgpu_target_arch_set(0..5)` (`main.mlr:5858`) is a **separate gfx-target selector**, NOT CPU arch — do not conflate. |

### 2.4 IR op-numbering compatibility — EXCELLENT, ONE collision

Method: value-joined every `static uint64 IR_* = N` from `ir.kr` (113) and `ir.mlr`
(107) by name.

- **Zero value mismatches** across the shared range. Everything the new backends
  consume lines up: arith/mul/div/mod, loads/stores, compares (incl. `IR_SCMP_*`),
  calls/args, copy, const, `IR_VLOAD=95`/`IR_VSTORE=94`, and the 132–139 block
  (`IR_SDIV=132, IR_SMOD=133, IR_SAR=134, IR_ADD_IMM=135, IR_SUB_IMM=136,
  IR_ROR=137, IR_MUL_IMM=138, IR_LEA_BIS=139`) all match.
- MLRift did **not** pollute the shared IR opcode space with HIP ops (those live in
  `ir_hip.mlr`).

**⚠️ THE COLLISION — opcodes 140–147 (single biggest graft risk):**
- KernRift `ir.kr` 140–145 = immediate bitwise/shift ops:
  `IR_AND_IMM=140, IR_OR_IMM=141, IR_XOR_IMM=142, IR_SHL_IMM=143, IR_SHR_IMM=144, IR_SAR_IMM=145`.
- MLRift `ir_hip.mlr` 140–147 = GPU ops:
  `IR_GPU_ALLOC=140, IR_GPU_FREE=141, IR_GPU_H2D=142, IR_GPU_D2H=143, IR_GPU_D2D=144,
  IR_KERNEL_LAUNCH=145, IR_GPU_SYNC=146, IR_GPU_BARRIER=147`.
- **Direct numeric double-booking at 140–145.** Both new backends consume these
  (`ir_riscv.kr:1245/1267`, `ir_xtensa.kr:1193/1211/1553`).
- **Mitigating fact:** MLRift's shared IR **never emits** the imm ops today (they're
  an IR-optimizer/const-fold feature MLRift lacks — the 6 `IR_*_IMM` names are the
  only KR opcodes with no MLRift twin). So ported 140–145 handlers would be
  **dormant**.
- **Action:** do NOT reuse literals 140–145 for imm ops in MLRift. Either (a) omit
  the imm-op handlers from the ported backends, or (b) if the IR-optimizer port ever
  lands the imm-rewrite, assign imm ops fresh opcodes **≥148** (first free above
  `IR_GPU_BARRIER=147`) and update backend constants. **Coordinate across efforts.**
  Getting it wrong = a scalar backend mis-decoding a GPU opcode or vice-versa, and
  can move the GPU golden md5.

### 2.5 Dialect translation gotchas (.kr → .mlr)

The 4 files are mostly in the portable subset — low friction:
- `let`: **2 total** (1 in ir_riscv.kr, 1 in ir_xtensa.kr) → rewrite to typed decls.
- ternary `?`: ~7 (upper bound; some may be in comments) → expand to if/else.
- `match`: **3** (all in ir_riscv.kr) → expand to if/else chains.
- **Stack arrays** `uint8[N]` in fn bodies — 6 sites (`codegen_riscv.kr:542,566,581,589`
  `[4]/[24]/[16]`; `ir_xtensa.kr:47`; `ir_riscv.kr:140`) — small hex/dec scratch
  buffers. These lower to `IR_ALLOC` (mmap leak) in MLRift → convert to
  `alloc(N)`/`dealloc`. (Or, if Track C's `IR_STACK_ADDR` fix lands first, they can
  stay as-is — another reason to do §5(a) before Track A.)
- **One global namespace**: ~160 fns across the 4 files, arch-prefixed
  (`rv_*`, `xt_*`, `ir_riscv_*`, `ir_xtensa_*`) so collisions unlikely; any shared
  helper needs a single canonical home (codegen.mlr). Dup `fn` = build error; dup
  `static` tolerated.
- Standard MLRift quirk checklist during transcription: return-type fns need
  `return 0` after `exit()`; struct-through-param writes don't persist; structs
  ≤16 u64 fields; `type` is reserved.

### 2.6 Codegen-level opts that travel with the backends
- **Immediate-operand folding** consumed by both backends (132–139 present in MLRift
  IR; 140–145 absent — see collision). Production is the optimizer's job; the
  *consumption* handlers come with the port.
- **RV32IMC "C" compressed peephole** (KR `1583fb5`; `@naked` opt-out `8b67c85`).
  Net-new; no MLRift equivalent.
- **Branch relaxation / short-branch selection** for both encoders.
- **`@naked`** handling integrated with compression.
All riscv/xtensa-local; MLRift x86/arm64 untouched (byte-identity preserved).

### 2.7 Sequencing + effort

**riscv-first**, mirroring KernRift's build order even though xtensa is the ML
target — riscv is the simpler, standard, better-documented ISA and proves out all
the *shared* scaffolding (arch dispatch, Elf32+raw emit, `IR_NUM_REGS` save/restore,
`_nyi` guards, the 140–145 renumber decision) on the easier target. Xtensa reuses it.

| Phase | Work | Effort |
|---|---|---|
| 0 De-risk dispatch | main.mlr `--arch` + arch 2/3 enum, `*_nyi` stubs, analysis.mlr restrictions, Makefile SRCS | **S** |
| 1 riscv32 | `ir_riscv.mlr` (**L**, dialect xlate + 140–145 renumber) + `codegen_riscv.mlr` (**M**); qemu `-machine virt` boot test | **L** |
| 2 xtensa | `ir_xtensa.mlr` (**L**, 93 fns) + `codegen_xtensa.mlr` (**S**); qemu `-M lx60` Elf32 boot test | **L** |
| 3 ML on scalar (SEPARATE — Track B) | portable scalar/int8 ML lowering + soft-float/fixed-point (or Xtensa FPU) | **XL** |

---

## 3. (reserved — merged into Track A above)

---

## 4. Track B — Portable scalar / int8 ML lowering (the real ESP32 deliverable)

Net-new project, gated on Track A. What's missing (from §1):
- A portable scalar/int8-quantized ML lowering path in MLRift's shared IR — today ML
  is GPU-blob-only (`format_amdgpu*.mlr`), so there is nothing for a scalar backend
  to consume.
- A float story for the MCU targets: soft-float / fixed-point / int8-quantized
  arithmetic in the riscv/xtensa backends, or Xtensa LX6 FPU float codegen the
  current backend explicitly refuses. **Int8/fixed-point quantized inference is the
  realistic MCU route** (facial recon on ESP32 is a quantized-CNN problem, not f32).

**Recommendation:** before committing to Track B, run a **feasibility spike** — e.g.
one quantized conv / GEMV kernel lowered through shared IR to Xtensa and validated
under `qemu-system-xtensa -M lx60`. Effort **XL**; do not start without the spike.

---

## 5. Track C — Correctness ports (high value, independent, mostly cheap)

### (a) Stack-local arrays → `IR_STACK_ADDR` — HIGH — PORT (MLRift task #102)
- **Bug:** `uint64[N] x` in a fn body lowers to `IR_ALLOC` (mmap/VirtualAlloc) every
  call — leaks ~4 KB/call, ~2 µs/call syscall cost.
- **KR fix:** `65507fb` "v2.8.17: stack-local arrays" + `179bdfd` (aarch64
  base-offset). Uses `IR_STACK_ADDR` (opcode 32):
  - `ir.kr` `ir_lower_stmt` (~2865): array decl with `arr_size>0 && total_bytes<=4096`
    emits `IR_STACK_ADDR` at a relative offset, bumping static `ir_stack_array_bytes`;
    else falls back to `IR_ALLOC`.
  - `ir_lower_function` resets `ir_stack_array_bytes = 0`; new static.
  - x86 emit for `op==32`: `lea dst, [rsp + ir_spill_count*8 + imm]`; x86 prologue
    `frame_size = ir_spill_count*8 + ir_stack_array_bytes`.
  - aarch64 emit: `base_off = IR_A64_OVERFLOW_RESERVE + ir_spill_count*8 + imm`;
    aarch64 prologue: `total_frame` and `ir_a64_scratch_off` both add
    `ir_stack_array_bytes` (the 179bdfd correction — without it callee-save base
    under-counts and clobbers).
- **MLR exposure:** `ir.mlr:3389–3391` unconditionally emits `IR_ALLOC`.
  `IR_STACK_ADDR = 32` is *defined* (`ir.mlr:56`) but **never emitted, no emit
  handler** — dead constant.
- **Port class:** dialect effectively identical; near copy-paste but **multi-site**
  (IR lowering + reset + static + x86 emit + x86 prologue + aarch64 emit + aarch64
  prologue = 7 sites, 2 backends). Confirm MLR's aarch64 frame symbols
  (`IR_A64_OVERFLOW_RESERVE`, scratch offset) match KR names before grafting.
- **Effort:** MEDIUM. **Byte-neutral for array-free code** (frame delta term is 0;
  GPU emit path uses no in-fn arrays) — but **re-verify golden md5 + bootstrap fixed
  point after porting** since it's the one graft that emits new machine bytes.

### (c) Struct field/size overflow guards — MEDIUM — PORT (diagnostic only)
- **Bug:** struct registry stride `struct_idx*272` = 16-byte header + 16 fields×16B.
  A 17th field writes at `base+272` → into the next struct's entry. Silent
  corruption. A `>65535`-byte struct wraps the uint16 size field.
- **KR:** `struct_add_field` (`codegen.kr:1056/1062`) has a fail-loud `wfc>=16` guard
  **and** a `total_size>65535` guard.
- **MLR:** `struct_add_field` (`codegen.mlr`) has **neither** — silent corruption.
- **Port class:** CLEAN GRAFT — identical body/dialect; add two
  `if … { write(2,…); exit(1) }` blocks. Does NOT raise the cap (a true raise =
  widen the 272 stride everywhere; out of scope). **Effort:** LOW (~6 lines,
  canonical home codegen.mlr).

### arm64 signed/NaN compare batch — HIGH-if-exposed — VERIFY then maybe port
- KR `c2a5ee9` / `3d3c92f`: arm64 signed comparison had been emitting unsigned
  condition codes (+ NaN-unordered + imm12 fixes). arm64 is a **byte-identical
  shared backend**, so any divergence is a **real silent miscompile**, not cosmetic.
- **Action:** targeted diff of `codegen_aarch64.kr` vs `codegen_aarch64.mlr` for
  these specific patches (separate pass). Effort: S to check; unquantified to fix.

### std/io read_file errno + std/map 64-key cap — VERIFY — (KR `20821bf`)
- `io.kr read_file`: negative errno used as fd → segfault. Check `std/io.mlr`.
- `map.kr`: fixed 64-slot table hangs on 65th key; added `map_grow`. Check
  `std/map.mlr` (may still be capped). If unported: LOW clean graft.

### Already resolved (NO action)
- **(d) `exp_f64` negative** — KR `20821bf`; **already in MLR** (`math_float.mlr:176–186`).
- **(e) f32 store width** — KR `220d9c1`; **already in both** (`parser.mlr:1399–1401,
  1456–1458` set type_size for KwFloat16=94→2/32=95→4/64=96→8).
- **memset-liveness / "0xFF fat binary"** (KR `8edcab3`) — **already in MLR**
  (`ir.mlr:4765`; op 76 now defines a value).
- **(b) struct-param write** — no fix exists in KR either (intended by-value
  memcpy-copy semantics, `ir.kr:2753` ≡ `ir.mlr:2834`). Workaround stays (byte-offset
  writes, or write in `main()`).

---

## 6. Track D — Structural type checker (only substantial optimizer/frontend gap)

MLRift is **very well synced** in the IR-opt/parser/sema area — its batch-port
commits (`4fa3437` batch1, `cd71351` batch2, `04e3a33` batch3, `2382c80` parser,
`7f47ac4` sema, `20758a0` check-mode, + `75d6f09/23d0df7/32beeb6/f0a122b`) pulled
KernRift's critique-fix era (≈ up to v2.8.25). Roadmap status:

| Roadmap item | Landed in KR? | Present in MLR? |
|---|---|---|
| IR optimization passes | YES (const-fold, CSE gen-stamp, IR-DCE, LICM `fb7ed8b`, Briggs/George coalescer `feb4312/10300a8`, 8 peepholes `9025dfe`, strength-reduce pow2 `3d46064`) | **YES** (ported + own 5.5x) |
| **Real type checker** | YES (`type_check.kr`, `bc175e3+9bc5b88+353152e`, 13 rules, fatal, wired into `krc check` `16e95eb`) | **NO** ← the port |
| DWARF debug info | YES (`a450a76/7c1d0d4/156bf7b`) | **YES** (`line_table_*`, `-g`→debug_info_mode, `IR_ARR_CHECK`) |
| JIT mode | **NO** (grep-clean in KR) | NO — nothing to port |

**The type checker** — `type_check.kr` (1192 L), 13 rules across 3 phases:
- P1: A3 unknown-field, A4 field-of-non-struct, A6 return-type-mismatch, B5
  binop-on-struct, B7 bool-required-in-condition.
- P2: A5 void-fn-as-value, B1 assign-struct-vs-non, B2 assign-struct-kind,
  B6 compare-on-struct.
- P3: B3 return-struct-mismatch, C7 return-float-kind (f32 vs f64),
  C6 call-arg-struct-mismatch, C10 match-arm-type-mismatch.

Entry points `tc_init` / `tc_collect_signatures` / `tc_check_module(root)`, wired at
3 `main.kr` sites. Uses **zero** let/ternary/match-expr, so rule bodies graft
mechanically. Port work:
1. **Relocate** into `analysis.mlr` (no `type_check.mlr` in MLRift by convention).
2. **One-global-namespace:** `tc_*` helpers are self-prefixed; it reuses
   `static_kind_of`/struct-table helpers — resolve those to MLRift's existing single
   definitions (canonical home codegen.mlr); do NOT redefine.
3. **Rewire** the 3 call sites into MLRift's compile + `check` paths.
4. C10 applies (MLRift has match-statements). Ternary/let/match-EXPR AST cases in
   `tc_expr_kind` are dead in MLRift — drop them.
- **Effort:** Medium-High. Real cost is **re-triaging false positives** against
  MLRift's larger source (`format_amdgpu*.mlr` idioms KernRift never sees), not the
  transcription. **Roll out advisory (warnings) first, triage to zero, THEN make
  fatal** — exactly KernRift's `bc175e3→353152e` sequence.
- **Risk:** analysis-only (no IR/codegen mutation) → **cannot** move the GPU golden
  md5 or byte-identical output; only failure mode is a spurious abort breaking the
  stage3==stage4 bootstrap. Advisory-first mitigates.

Other minor candidates: **did-you-mean for undeclared variable names**
(analysis-side) — CLEAN GRAFT, LOW (MLRift has it for functions only,
`codegen.mlr:775`); **audit `05923c0` fatal-on-overflow buffer guards** — verify
coverage, LOW. Nothing else in this area is worth porting.

---

## 7. HARD invariants (every track must hold)

- **GPU emit golden md5 `1fabbed0c1f342a8d00fe9981e4759d7`** (`--emit-amdgpu-nop`) —
  unchanged. The 140–147 renumber MUST keep GPU ops at 140–147 (move imm ops ≥148).
- **Bootstrap stage3 == stage4** fixed point.
- **x86_64 / arm64 byte-identical** output — add arch 2/3 arms as pure `else if`
  additions; never restructure the arch 0/1 arms.
- **Bootstrap concurrency footgun:** `make bootstrap` uses fixed `/tmp/mlrc_bs_*`
  paths → **run it SOLO**. `make build` + `make test` are concurrency-safe (use those
  when fanning out parallel worktree agents; run the single authoritative
  `make bootstrap` afterwards on main).
- **Do NOT re-port MLRift's own perf work** (`d09991d` mem-arena-free, `489ae9b`
  5.5x) — MLRift already has it.

---

## 8. Cross-cutting notes

- **Independent histories → semantic sync, never commit graft.** KernRift's `18f517e`
  (3.3x) and MLRift's `489ae9b` (5.5x) are **independent rewrites of the same shared
  hot paths** (liveness, CSE, IR-DCE, regalloc coloring, AST-DCE). Line layouts have
  diverged; textual cherry-picks will not apply cleanly and may silently drop a fix.
  Any future sync in `ir.{kr,mlr}` / `codegen.{kr,mlr}` regalloc/liveness/CSE must be
  diffed at the **semantic** level. (For today's scope, `18f517e` carried no
  correctness fixes — bit-identical output guaranteed — so nothing is owed now.)
- **One global namespace** (repeat, load-bearing): dup `fn` across files = build
  error; dup `static` tolerated. Shared helpers get one canonical home — codegen.mlr,
  early in SRCS.
- **`amdgpu_target_arch_set` ≠ CPU arch.** It's a gfx-target selector; don't conflate
  with `set_target_arch()`.

---

## 9. Corrections to prior memory (stale entries found during scoping)

- `feedback_mlrift_quirks` quirk **#6 (`exp_f64` negative)** and the historical
  **f32-store** note: both fixes are **already in MLRift**. The 86-day-old memory is
  stale on these. (Kept for KernRift-side history, but MLRift needs no action.)
- The **memset-liveness / compile_fat 0xFF** class is **already resolved in MLRift**.
- The **only** genuinely unported documented quirk is **#5 stack-local arrays**
  (MLRift task #102) — see §5(a).
- `project_mlrift_porting` memory remains accurate on the dialect diffs, dup-symbol
  rule, and bootstrap concurrency footgun.

---

## 10. ⚠️ XTENSA GAPS TO FILL FIRST (reserved — user to report)

> The user discovered holes/gaps in the **KernRift** Xtensa backend that must be
> addressed before (or alongside) any MLRift port — porting a backend with known
> holes just propagates them. **This section is a placeholder to be filled in when
> the user reports the specific gaps.** Capture each gap with: symptom, suspected
> root cause, repro, affected file:line, and fix approach — same rigor as the
> alignment bug (`5f97006`, CALL0 word-alignment) found during complex-program
> testing.

Known context that may bound the gaps (from the Xtensa build + testing so far):
- Float support is deferred (post-Layer-3); backend rejects floats at sema
  (`ir_xtensa.kr:429,1101`).
- Large-frame SP arithmetic loud-fails (>2047B frame / >1020 offset) —
  spills/overflow-param/frame.
- `_IMM` handlers are dead until the ir.kr fusion gate includes arch3.
- `callx0` / `IR_FN_ADDR` paths are unexercised by tests so far.
- Unconditional 64B overflow reserve.
- Recently fixed: CALL0 targets require 4-byte-aligned function `code_start`
  (pool-less functions were inheriting an unaligned offset) — `5f97006`, guarded by
  the `xtensa_stress_boot` full-output qemu test.

### Verified gap inventory (2026-07-19)

All verified empirically (compile a minimal program per op) AND by dispatch audit
(`ir_xtensa.kr` handles ops up to the compare/branch block at 1455–1463; everything
below falls to the catch-all `xt_nyi_op(op)` @1473 → `write(2,…"not yet
implemented"); exit(1)`). **Every gap is a LOUD compile-time fail — zero silent
miscompiles.** RISC-V already implemented all of them (its G1/2/3 feature-gap phase),
so `ir_riscv.kr` is a direct same-repo template for each.

| Op | Name | Source trigger | Fix template (riscv) / xtensa-specific note |
|----|------|----------------|---------------------------------------------|
| 79 | STR_CONST | string literal | riscv = auipc+addi PC-rel pair; **xtensa = intern absolute addr in literal pool + L32R** (easier — fixed load base, pool already exists). Needs a data/rodata blob in the image + address assignment. |
| 77/78/84 | STATIC_LOAD/STORE/ADDR | static globals | same address-materialization machinery as STR_CONST; load/store then use base+offset |
| 32 | STACK_ADDR | stack arrays `T[N]` in fn | frame-relative `addi dst, sp, off`; reserve array bytes in frame layout (mirror the x86/arm64 `ir_stack_array_bytes` fix) |
| 72/76/73/75/88 | MEMCPY/MEMSET/STRLEN/STR_EQ/MEMCMP | intrinsics | riscv lowers as inline machine-code loops — direct template |
| 74 | FMT_UINT | `fmt_uint()` decimal | inline divide-by-10 loop (xtensa has hw QUOU/REMU already wired) |
| 86 | FN_ADDR | `fn_addr("name")` | absolute fn addr via literal pool + a fnaddr fixup (extend `resolve_fixups_xtensa`); CALL_IND(87) already works so calling through it is done |
| 96 | ASM_BLOCK | `asm { }` | raw asm passthrough — niche, last non-float item |

**Deferred:** frames >2047B (large-frame SP arith — user: probably fine to skip);
floats (needed for ML on ESP32/RISC-V — scheduled LAST, before/with Track B).

**The one genuinely xtensa-specific design point:** static/string/fn-addr all need a
**data section in the freestanding image + absolute-address materialization**. The
current boot image is code + per-function literal pools only — no data blob yet. The
clean xtensa approach is a rodata/data segment at a known load offset, with each
static/string/fn address interned as an absolute 32-bit constant in the literal pool
and loaded via L32R (simpler than riscv's PC-relative auipc+addi, because the load
base is fixed). This is the piece that warrants a short spec; the rest mirrors riscv.

### Suggested grouping (mirrors riscv's G-phase, dependency-ordered)
1. **Data section + address materialization** — STR_CONST, STATIC_ADDR/LOAD/STORE.
   Foundational (unlocks globals + strings). Contains the one real design decision.
2. **Stack arrays** — STACK_ADDR + frame-layout reservation. Independent.
3. **Inline intrinsics** — MEMSET, MEMCPY, STRLEN, STR_EQ, MEMCMP, FMT_UINT. Mostly
   independent inline loops.
4. **Function pointers** — FN_ADDR (reuses Group 1 address machinery + a fixup).
5. **Inline asm** — ASM_BLOCK. Niche, last of the non-float work.
6. **Deferred** — large frames; then floats (last).

Each group ends with a qemu `-M lx60` boot-and-check-output test (per the lesson that
disasm/golden-diff tests are blind to layout/linking bugs — see `5f97006`).

---

## 11. Open decisions (pending)

1. **Do the Xtensa gaps (§10) first**, then decide port scope — current user
   direction. Porting deferred.
2. Track ordering when porting begins: recommended **C (cheap correctness) →
   A (riscv → xtensa) → B (ML path, gated on spike)**. Not yet confirmed.
3. Whether Track B (scalar ML lowering) is in scope at all, or whether the MCU story
   stays integer/UART-only for now.
4. 140–145 imm-op opcode decision (omit handlers vs renumber ≥148) — only forced if
   the imm-rewrite optimizer ever lands in MLRift.

---

*Source reports (session-ephemeral scratchpad, folded into this doc):
`scope-backends.md`, `scope-ir-frontend.md`, `scope-fixes-tooling.md`.*
