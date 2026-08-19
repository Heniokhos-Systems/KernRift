# IR Reference

Line citations below are pinned by `tests/ir_reference_citations.txt` and
checked on every `make test`; regenerate with
`python3 scripts/gen-ir-reference-citations.py` after moving code.

Everything below was checked against `src/` at commit `2f13efb` (branch
`main`) and, where the check was runnable, against the compiler built from
it. Claims that could not be verified are marked **UNVERIFIED** and say why.
`file:line` citations point at the code that establishes the claim — go read
it before you rely on it, because line numbers drift and this document does
not.

> **Verification convention.** A claim is *verified* only if it was read out
> of source at this commit or observed by compiling and running a probe. This
> file previously carried several confident, wrong statements (the IR is not
> SSA; x86 does not use 5 colours; `IR_FFMA` is not a fused multiply-add;
> bare `<` is type-directed, not always unsigned). A confident wrong IR
> reference is worse than a thin one, because it is trusted by whoever
> changes codegen next.

---

## 1. What the IR is — and what it is not

The IR is a **flat, per-function, virtual-register instruction list with
explicit basic blocks**. It is produced by `ir_lower_function()`
(`src/ir.kr:5654`) from the AST and consumed by four machine-code emitters.

**It is not SSA, despite the name of the `--emit=ir` help text.** Verified
two ways:

1. `IR_PHI` (opcode 60) is **completely dead**. Tree-wide, the only three
   references are the constant definition (`src/ir.kr:73`), its name string
   in `ir_opcode_name` (`src/ir.kr:5419`), and a stale comment
   (`src/ir_aarch64.kr:2226`). No lowering emits it and no emitter handles
   it.
2. A vreg is assigned in more than one block. Probe (`--emit=ir` on an
   if/else plus a `while`):

   ```
   bb0:  v3 = copy v2        ← x = 1
         br_cond v5, bb1
   bb1:  v3 = copy v6        ← x = 2
   bb3:  v3 = copy v7        ← x = 3
   bb2:  v9 = copy v8        ← i = 0
   bb5:  v9 = copy v13       ← i = i + 1
   ```

   `v3` has three definitions and `v9` two.

What actually happens: the lowering keeps a *variable map* from name token to
"the vreg currently holding this variable" (`ir_var_get`, `src/ir.kr:1118`).
At a control-flow merge it snapshots that map and emits reconciling
`IR_COPY`s onto the incoming edges via `ir_emit_copy_to_snapshot()`
(`src/ir.kr:1154`), using a two-phase read-before-write ordering to avoid
parallel-copy hazards. There is no phi insertion, no dominance-frontier
computation, and no SSA destruction pass. Passes that assume single
assignment (const propagation, CSE) must — and do — carry their own
single-def checks; see §10.

### Instruction record

32 bytes, fixed layout (accessors at `src/ir.kr:516`–`545`):

| Offset | Width | Field | Notes |
|---|---|---|---|
| 0 | u32 | `opcode` | |
| 4 | u32 | `dest` | destination vreg; `0` = no destination |
| 8 | u32 | `src1` | `0` = unused |
| 12 | u32 | `src2` | `0` = unused |
| 16 | u64 | `imm` | interpretation is per-opcode |
| 24 | u32 | `bb` | owning basic block |
| 28 | u32 | `next` | **intrusive linked-list link**, `0xFFFFFFFF` = end |

The `next` field is why the arena is *not* walked as a contiguous index
range. LICM appends hoisted instructions at high indices and splices them
into a preheader's list; liveness and colouring walk the linked list, which
is what makes that correct (`src/ir.kr:13609`–`13024`).

Three parallel, index-keyed side tables share `ir_insn_cap` and leave the
32-byte record untouched:

| Table | Width | Purpose | Decl |
|---|---|---|---|
| `ir_insn_src_tok` | u32/insn | source token, for `-g` DWARF line records | `src/ir.kr:223` |
| `ir_insn_origin` | u64/insn | pointer to a static name literal: *which builtin lowered to this instruction* | `src/ir.kr:244` |
| (the arena) | 32 B/insn | the instructions | `src/ir.kr:217` |

Basic blocks are 16-byte records — `first_insn`, `last_insn`, `succ0`,
`succ1`, each u32 with `0xFFFFFFFF` as the empty/none sentinel
(`ir_new_bb`, `src/ir.kr:715`).

Initial capacities (`ir_init`, `src/ir.kr:294`): 65536 instructions, 4096
basic blocks, 65536 vreg float-kind slots. The instruction arena grows
(`src/ir.kr:619`); the block arena does **not** — exceeding 4096 blocks is a
hard `error: IR basic block overflow` and `exit(1)` (`src/ir.kr:717`).

`ir_vreg_next` starts at 1 (`src/ir.kr:323`), so **vreg 0 is reserved** and
means "no value".

**fkind** is a per-vreg byte tag: `0` = integer, `1` = f64, `2` = f32. It
selects the register class at emission. `ir_init` memsets the whole buffer
because it is indexed without a length guard and a stale byte from the
previous function would mislabel a vreg as float (`src/ir.kr:323`–`321`).

---

## 2. Which invocations reach the IR, and which bypass it

This is the single most load-bearing fact for anyone writing a test. It was
verified empirically at HEAD by compiling the same program with and without
`--legacy` and comparing bytes — identical output means `--legacy` changed
nothing, i.e. that mode was already using the legacy backend.

| Invocation | Backend | Evidence |
|---|---|---|
| default (fat `.krbo`) | **IR** | differs from `--legacy` |
| `--emit=elfexe` | **IR** | differs from `--legacy` |
| `--emit=pe`, `--emit=macho`, `--emit=android` | **IR** | differs from `--legacy` |
| `--emit=asm` | **IR** | differs from `--legacy` |
| `--legacy` | legacy | by definition |
| **`--emit=obj` / `-c`** | **legacy** | byte-identical with and without `--legacy` (160 B both) |
| **`--emit=lkm`** | **legacy** | byte-identical with and without `--legacy` |
| `--emit=image`, `--emit=uefi` | **IR** | the gate excludes only modes 3 and 7; the usual "differs from `--legacy`" evidence is *unavailable* here — both require `--target=none`, and `--legacy` is refused under it (`t6_legacy_tnone_*`), so there is no legacy build to diff against |
| `--arch=riscv32`, `--arch=xtensa` (any emit mode) | **IR** | no legacy backend exists for these arches; `--legacy` is a silent no-op |
| `--emit=ir` | neither — lowering only | the `if emit_mode == 6` block in `compile()`, `src/main.kr` — exits before codegen |

This table is per **emit mode** and all ten are now listed. It named six of
them for a while: `--emit=image` (8) and `--emit=uefi` (9) were both missing,
and the second row's "differs from `--legacy`" evidence *cannot* be produced
for either of them, so adding them by pattern-matching the rows above would
have written a claim nobody could check.

The gate is one condition, in two places — `grep -n 'emit_ir_mode != 0 && arch =='
src/main.kr` finds both:

```
if emit_ir_mode != 0 && arch == 0 && emit_mode != 3 && emit_mode != 7 {
} else if emit_ir_mode != 0 && arch == 1 && emit_mode != 3 && emit_mode != 7 {
```

**No line numbers here, deliberately.** The three that used to be in this
section pointed at neither this tree nor its parent: they were off by exactly
+9 from the parent, i.e. measured against an intermediate working state and
never re-checked — by the same commit that deleted line numbers from
`src/main.kr` on the grounds that named variables do not rot. Re-deriving them
would only reset the clock.

`emit_mode == 3` is `--emit=obj`, `emit_mode == 7` is `--emit=lkm`. The
in-source comment says why: *"skip for `--emit=obj` and `--emit=lkm`; both
need legacy codegen for extern relocations"*.

> **The trap.** `--emit=obj` **is the legacy backend**. An `--emit=obj` test
> proves nothing whatsoever about IR lowering, and an IR-side guard leaves
> `--emit=obj` unguarded by construction. This has caught the project twice:
> the `--target=none` `time_ns` silent-constant-zero survived a whole audit
> round for exactly this reason, and the fix was to move the refusal helper
> out of `ir.kr` into `codegen.kr` (`src/codegen.kr:789`–`640`).

Also verified, and frequently assumed backwards: **`--target=` selects the
ABI, not the container.** `--arch=x86_64 --target=windows` emits an **ELF**
(`objdump` reports `elf64-x86-64`). PE and Mach-O only come out of
`--emit=pe` / `--emit=macho`. A byte-identity gate built on `--target=`
rows alone will never exercise the PE or Mach-O header emitters.

### `--emit=ir` is pre-optimization

`ir_dump()` is called directly after `ir_lower_function()` with **no
`ir_optimize()` in between** — the two calls are adjacent inside the
`if emit_mode == 6` block in `compile()`, `src/main.kr`. (The claim is true;
the `:2387`–`2389` that used to be cited here was not, for the same reason as
the three above. Re-checked against the block itself.) So `--emit=ir`
shows you what the lowering produced, never what the optimizer did. Ops the
optimizer creates (`IR_ADD_IMM`, `IR_MUL_IMM`, `IR_LEA_BIS`, `IR_ROR`,
`IR_SHL_IMM`, `IR_LOAD_BIS`, `IR_STORE_BIS`, the riscv `*_IMM` family)
therefore never appear in a dump. To see post-optimization code, read
`--emit=asm` or disassemble.

`ir_opcode_name()` (`src/ir.kr:5419`) is also **incomplete**: it has no entry
for 124, 125, or 135–148, so those print `???`. 124/125 are emitted by
ordinary lowering, so this is observable — verified:

```
$ krc --emit=ir prog.kr     # prog.kr does `println(some_f64)`
    v13 = ??? v12, v9       # this is IR_FMT_F64 (125)
```

---

## 3. The per-OS dispatch shape, and where a new case goes

`target_os` values (parsed at `src/main.kr:9011`, derived from `--emit` at
`9255`–`9257`, reset per slice by `compile_fat` at `5939` and `6942`):

<!-- The previous version of this line read "assigned in 9011-5258, defaults at
     3631/3859/4113/4361/4486/4618". The range ran backwards and every one of
     those six line numbers pointed at unrelated emit code. Only the first
     number in a citation is hashed by tests/ir_reference_citations.txt, so the
     rest drifted for however long without the guard noticing. Numbers above
     were each checked against what is on the line. -->

| Value | OS |
|---|---|
| 0 | Linux |
| 1 | macOS / Darwin |
| 2 | Windows |
| 3 | Android |
| 4 | none (bare metal, `--target=none`) |

**The house pattern is "special-case Windows/macOS, else fall through to
POSIX."** A new `target_os` value therefore inherits the Linux path by
default at roughly sixty branch sites. Measured at HEAD across the eight
backend files (`src/ir.kr src/ir_aarch64.kr src/ir_riscv.kr src/ir_xtensa.kr
src/codegen.kr src/codegen_aarch64.kr src/codegen_riscv.kr
src/codegen_xtensa.kr`), counting occurrences on non-comment lines:

| Pattern | Count |
|---|---|
| `target_os == 2` (Windows) | 113 |
| `target_os == 1` (macOS) | 103 |
| `target_os == 4` (bare metal) | 39 |
| `target_os != 2` | 12 |
| `target_os == 3` (Android) | 11 |
| **`target_os == 0` (Linux)** | **4** |
| `target_os != 1` | 1 |

Reproduce with:

```sh
grep -h "target_os == 0" src/ir.kr src/ir_aarch64.kr src/ir_riscv.kr \
  src/ir_xtensa.kr src/codegen.kr src/codegen_aarch64.kr \
  src/codegen_riscv.kr src/codegen_xtensa.kr \
  | grep -v '^[[:space:]]*//' | grep -o "target_os == 0" | wc -l
```

Four explicit Linux tests against 113 Windows tests is the whole story:
Linux is not a case, it is the fall-through. The comment at
`src/codegen.kr:595` makes the same point but quotes `116` for
`target_os == 2` — that count is now stale by three; the *ratio* is what
matters and it has not changed.

### Consequences you must design around

- **Adding a `target_os` value silently inherits Linux everywhere.** That is
  how a Linux `syscall` instruction ends up inside a bare-metal kernel image.
  The countermeasure adopted for `--target=none` was *not* to audit the
  ~60 sites but to funnel every trap instruction through one emitter per
  architecture and refuse there (§12).
- **The dangerous sub-class is a terminal `else` that produces a *value*.**
  `if os == A {…} else if os == B {…} else { mov rax, 0 }` compiles clean,
  exits 0, and ships an artifact containing a wrong constant. A trap-scanning
  guard cannot see it, because no trap instruction is emitted. Three such
  sites shipped in this compiler; see §9.
- **A new arch × OS pair is validated by an allow-list**, not a blacklist:
  `arch_os_pair_supported()` (`src/main.kr:7471`) is per-row
  `if os == n { return 1 }` with a `return 0` fall-through, checked on the
  resolved pair before every compile entry. Adding an arch without adding its
  row is a hard error at the first build. Before it existed,
  `--arch=riscv32 --target=windows` exited 0 and wrote a 296-byte RISC-V
  *ELF*.

### Where a new case goes

1. If it is a **trap instruction**, it does not go in a new case at all —
   route it through the existing per-arch choke point (§12).
2. If it is a **builtin refusal or a per-OS behaviour change**, it must go in
   **both** the IR lowering (`src/ir.kr`) **and** the legacy backend
   (`src/codegen.kr` / `src/codegen_aarch64.kr`), because `--legacy`,
   `--emit=obj` and `--emit=lkm` never call `ir_lower_expr`.
3. If it is an **emitter-level divergence**, remember that `ir_lower_stmt`
   (`src/ir.kr:4269`–`5147`) contains **no `target_os` branch at all** —
   statement-level constructs (local array decls, struct decls) are per-OS
   blind by construction. That is why the `IR_ALLOC` sites in §11 have no
   bare-metal arm.

---

## 4. Reading an IR dump

```
$ krc --arch=x86_64 --emit=ir prog.kr
function add4:
  bb0:
    v1 = copy param[0]
    v2 = const 8
    v3 = mul v1, v2
    v4 = copy v3
    v5 = const 24
    v6 = add v4, v5
    v7 = copy v6
    v0 = ret v7

function main:
  bb0:
    v1 = const 3
    arg v1 [0]
    v2 = call @32
    v0 = ret v2
```

- `call @32` — the `32` is a **token index**, not a symbol. See §7.
- `v0 = ret v7` — `v0` is the reserved "no destination" vreg.
- `arg v1 [0]` — argument position in `imm`.
- Blocks print in index order, which is *also* the emission order
  (`src/ir.kr:14625`), but not the order the lowering created edges in: an
  `if`'s join block can have a lower index than its `else` arm.

---

## 5. Opcode reference

Numbers are the `static uint64 IR_* = N` constants at `src/ir.kr:30`–`207`.
Gaps (28–29, 33–39, 44–49, 53–59, 62–69, 89, 116–117) are unassigned.

Legend for the *Effect* column: **SE** = in the side-effect set (survives
DCE with a dead `dest`, §9); **pure** = not in it.

### 5.1 Constants and integer arithmetic (1–13, 132–139)

| # | Name | Semantics | Effect |
|---|---|---|---|
| 1 | `IR_CONST` | `dest = imm` | pure |
| 2 | `IR_ADD` | `dest = src1 + src2`, wrapping | pure |
| 3 | `IR_SUB` | `dest = src1 - src2`, wrapping | pure |
| 4 | `IR_MUL` | `dest = src1 * src2`, wrapping | pure |
| 5 | `IR_DIV` | unsigned `src1 / src2` | pure |
| 6 | `IR_MOD` | unsigned `src1 % src2` | pure |
| 7 | `IR_AND` | `dest = src1 & src2` | pure |
| 8 | `IR_OR` | `dest = src1 \| src2` | pure |
| 9 | `IR_XOR` | `dest = src1 ^ src2` | pure |
| 10 | `IR_SHL` | `dest = src1 << src2` | pure |
| 11 | `IR_SHR` | logical `src1 >> src2` | pure |
| 12 | `IR_NEG` | `dest = -src1` | pure |
| 13 | `IR_NOT` | `dest = ~src1` | pure |
| 132 | `IR_SDIV` | signed `src1 / src2` | pure |
| 133 | `IR_SMOD` | signed `src1 % src2` | pure |
| 134 | `IR_SAR` | arithmetic `src1 >> src2` | pure |
| 135 | `IR_ADD_IMM` | `dest = src1 + imm` (signed i32); `src2` unused | pure |
| 136 | `IR_SUB_IMM` | `dest = src1 - imm` (signed i32); `src2` unused | pure |
| 137 | `IR_ROR` | rotate-right; `imm` = width (32 or 64) | pure |
| 138 | `IR_MUL_IMM` | `dest = src1 * imm` (signed i32); `src2` unused | pure |
| 139 | `IR_LEA_BIS` | `dest = src1 + src2 * imm`, `imm ∈ {1,2,4,8}` | pure |

Notes, all verified:

- **Wrapping.** Two's-complement wrap-around; there is no
  signed-overflow-is-UB rule.
- **Shift masking.** Both x86 and AArch64 mask the count to `& 63`, and the
  compiler relies on it. Verified at runtime on both: `1 << 64` → `1`,
  `1 << 65` → `2`.
- **Divide by zero.** `IR_DIV`/`IR_MOD`/`IR_SDIV`/`IR_SMOD`, verified by
  running a `10 / 0`:

  | Backend | x86_64 | arm64 |
  |---|---|---|
  | IR, no `--debug` | **SIGFPE**, exit 136 | **silently returns 0**, exit 0 |
  | IR, `--debug` | SIGFPE | traps, exit 1 |
  | legacy, no `--debug` | SIGFPE, exit 136 | silently returns 0, exit 0 |
  | legacy, `--debug` | SIGFPE | traps, exit 1 |

  This is a hardware difference (`div` faults, `udiv` returns 0), not a
  compiler choice, and `--debug` is the only thing that makes the two agree.
- **135/136/138/139 are optimizer products only.** No lowering emits them;
  `ir_opt_const_fold` rewrites `IR_ADD`/`IR_SUB`/`IR_MUL` into them when one
  source is a known constant. 138 fires only for `target_arch == 0`
  (`src/ir.kr:12663`); 139's producer is gated to arch 0 and 1
  (`src/ir.kr:13697`).

### 5.2 Compares (14–19 unsigned, 120–123 signed)

All produce `1` or `0` in a full-width integer vreg. There is no `bool` type
at the IR level.

| # | Name | | # | Name |
|---|---|---|---|---|
| 14 | `IR_CMP_EQ` | | 120 | `IR_SCMP_LT` |
| 15 | `IR_CMP_NE` | | 121 | `IR_SCMP_LE` |
| 16 | `IR_CMP_LT` (unsigned) | | 122 | `IR_SCMP_GT` |
| 17 | `IR_CMP_LE` | | 123 | `IR_SCMP_GE` |
| 18 | `IR_CMP_GT` | | | |
| 19 | `IR_CMP_GE` | | | |

Bare `<`, `<=`, `>`, `>=` at the surface are **type-directed**: they lower to
14–19 when the operands are unsigned and to 120–123 when an operand's vreg
carries the signed flag (see `ir_vreg_signed_buf` in `src/ir.kr`). The
`signed_lt`/`signed_le`/`signed_gt`/`signed_ge` builtins always take the
signed path. *(The pre-2026 claim that bare comparisons are always unsigned
is false; it is still present in MLRift's copy of this document.)*

### 5.3 Floating point (20–27, 97–108, 118, 125)

| # | Name | Semantics |
|---|---|---|
| 20–23 | `IR_FADD`/`FSUB`/`FMUL`/`FDIV` | IEEE-754 binary64 |
| 24 | `IR_FCMP_EQ` | ordered equal (false if either is NaN) |
| 25 | `IR_FCMP_LT` | ordered less-than |
| 26 | `IR_ITOF` | int64 → f64 |
| 27 | `IR_FTOI` | f64 → int64, truncating |
| 97 | `IR_FSQRT` | `sqrtsd` / `fsqrt d` |
| 98 | `IR_FFMA` | `dest = src1 * src2 + imm_vreg` — **not fused**, see below |
| 99–102 | `IR_FCMP_NE`/`LE`/`GT`/`GE` | ordered compares |
| 103 | `IR_F32TOF64` | `cvtss2sd` |
| 104 | `IR_F64TOF32` | `cvtsd2ss`, round-to-nearest-even |
| 105 | `IR_F32TOF16` | f32 → f16 bit pattern |
| 106 | `IR_F16TOF32` | f16 bit pattern → f32 |
| 107 | `IR_ITOF32` | int64 → f32 |
| 108 | `IR_FTOI32` | f32 → int64 |
| 118 | `IR_FSQRT32` | f32 square root |

- **`IR_FFMA` is a misnomer.** It emits `mulsd` + `addsd` on x86_64
  (verified by disassembly: no `vfmadd`) and `FMUL d0` + `FADD` on arm64
  (`src/ir_aarch64.kr:2973`/`2871`). Two roundings, not one — results differ
  from a true FMA. The source says so at `src/ir.kr:13513`: *"The current
  FFMA emit isn't actually a hardware FMA instruction — it just inlines
  mulsd+addsd back-to-back."* Its value is skipping the GPR round-trip
  between the FMUL and the FADD, not accuracy.
- **`IR_FTOI` saturates.** Verified on both arches: `1e21 → 9223372036854775807`,
  `NaN → 0`. The two arches agree.
- **105/106 are not x86-only** (a claim the old text made). arm64 implements
  both as software bit manipulation, `src/ir_aarch64.kr:3002` and `2938`.
- **Float literals are materialised at runtime.** `1.5` lowers to
  `itof(1) + itof(5)/itof(10)`, and `ir_opt_const_fold` does not fold float
  ops, so the `cvtsi2sd`/`divsd` survive to codegen. Verified by disassembly:
  a function containing `f64 x = 1.5` emits three `cvtsi2sd` and one `divsd`.

`fkind` picks the register class: `1` → `xmm`/`d`, `2` → `xmm`/`s`, `0` → GPR.

### 5.4 Memory (30–32, 70–78, 84, 88, 94–95, 147–148)

| # | Name | Semantics | Effect |
|---|---|---|---|
| 30 | `IR_LOAD` | `dest = *(src1)` at width `imm` ∈ {1,2,4,8}, zero-extended | pure |
| 31 | `IR_STORE` | `*(src1) = src2` at width `imm`; truncates | **SE** |
| 32 | `IR_STACK_ADDR` | `dest = sp + imm` | pure |
| 70 | `IR_ALLOC` | `dest = alloc(size)`; per-OS, see §8 | **SE** |
| 71 | `IR_DEALLOC` | free `src1` | **SE** |
| 72 | `IR_MEMCPY` | `memcpy(src1, src2, imm_vreg)` | **SE** |
| 73 | `IR_STRLEN` | `dest = strlen(src1)` | pure |
| 74 | `IR_FMT_UINT` | writes decimal digits into `src1`; `dest` = length | **SE** |
| 75 | `IR_STR_EQ` | `dest = (strcmp(src1,src2) == 0)` | pure |
| 76 | `IR_MEMSET` | `memset(src1, src2, imm_vreg)` | **SE** |
| 77 | `IR_STATIC_LOAD` | `dest = static_data[imm]` | pure |
| 78 | `IR_STATIC_STORE` | `static_data[imm] = src1` | **SE** |
| 84 | `IR_STATIC_ADDR` | `dest = &static_data[imm]` | pure |
| 88 | `IR_MEMCMP` | `dest = (memcmp(src1,src2,imm) == 0)` | pure |
| 94 | `IR_VSTORE` | volatile store, fence after | **SE** |
| 95 | `IR_VLOAD` | volatile load, fence before | **SE** |
| 147 | `IR_LOAD_BIS` | `dest = *(src1 + src2 << log2(imm))`; `imm` = width 4\|8 | pure |
| 148 | `IR_STORE_BIS` | `*(src1 + imm << log2(dest)) = src2`; `imm` is the **index vreg**, `dest` is the **width** | **SE** |

- `IR_LOAD` zero-extends: `load8` of `0xFF` yields `0x00000000000000FF`,
  never `-1`.
- **`IR_STORE_BIS` has an unusual operand shape** — `dest` holds a *width*,
  not a vreg, and `imm` holds a *vreg*, not a constant. It therefore has to
  be listed alongside `IR_STORE` in every "no def" list and alongside
  `IR_FFMA` in every "imm is a vreg" list for liveness, use-counting, DCE and
  interference. Get this wrong and you get a use-after-free of a register.
  See the constant's comment, `src/ir.kr:203`–`205`.
- **147/148 are arm64-only.** Produced solely by `ir_opt_fuse_lea_mem`, which
  is called under `if target_arch == 1` (`src/ir.kr:13609`). Handlers exist
  only at `src/ir_aarch64.kr:1429` and `1412`.

### 5.5 Control flow (40–43, 50–52, 61, 85–87)

| # | Name | Semantics | Effect |
|---|---|---|---|
| 40 | `IR_BR` | jump to block `imm` | **SE** |
| 41 | `IR_BR_COND` | if `src1 != 0` → block `imm`; **else → block `succ0` of the current block** | **SE** |
| 42 | `IR_RET` | return `src1` | **SE** |
| 43 | `IR_RET_VOID` | return, no value | **SE** |
| 50 | `IR_CALL` | call the fn named by token `imm`; `src1` = arg count | **SE** |
| 51 | `IR_ARG` | stage `src1` as argument `imm` | **SE** |
| 52 | `IR_SYSCALL` | syscall; `imm` = the **Linux syscall number** | **SE** |
| 61 | `IR_COPY` | `dest = src1` | pure |
| 85 | `IR_SYSCALL_RAW` | `dest = syscall(src1 = nr vreg)`, args staged by `IR_ARG` | **SE** |
| 86 | `IR_FN_ADDR` | `dest = &fn[imm_tok]` | pure |
| 87 | `IR_CALL_IND` | `dest = (*src1)()` | **SE** |

- **`IR_BR_COND` does not "fall through".** The false target is the block's
  `succ0` field, read separately (`src/ir.kr:14684`). The emitter then picks
  one of four layout cases against the *next* block index — both-next (emit
  nothing), true-next (invert the condition, one `jcc`), false-next (`jcc`,
  no trailing `jmp`), neither (`jcc` + `jmp`). If you write a pass that
  reorders or renumbers blocks, you must maintain `succ0`/`succ1`, not just
  the terminator's `imm`.
- Terminators are **not** emitted from the per-instruction dispatch on any
  backend. x86 has explicit no-op cases at `src/ir.kr:12260`/`11713` and
  skips them in the block loop (`src/ir.kr:14645`); arm64/riscv32/xtensa have
  no case at all and emit terminators in their function-level loop.

### 5.6 Multi-value returns (80–83)

| # | Name | Semantics | Effect |
|---|---|---|---|
| 80 | `IR_EXTRACT_RDX` | `dest = rdx` / `x1` after a call | **SE** |
| 81 | `IR_EXTRACT_R8` | `dest = r8` / `x2` after a call | **SE** |
| 82 | `IR_RET2` | return `(src1, src2)` | **SE** |
| 83 | `IR_RET3` | return `(src1, src2, imm_vreg)` | **SE** |

80/81 read a physical register that only holds the right value immediately
after the call. They are in the side-effect set specifically so DCE cannot
delete them and nothing can be scheduled between them and their call.

### 5.7 Strings, atomics, barriers, formatting, process

| # | Name | Semantics | Effect |
|---|---|---|---|
| 79 | `IR_STR_CONST` | `dest = &str_buf[imm]` | pure |
| 90 | `IR_ATOMIC_STORE` | `*src1 = src2` | **SE** |
| 91 | `IR_ATOMIC_LOAD` | `dest = *src1` | **SE** |
| 92 | `IR_ATOMIC_ADD` | `*src1 += src2`, returns **old** | **SE** |
| 93 | `IR_ATOMIC_CAS` | CAS `*src1`: expect `src2`, store `imm_vreg`; returns 1/0 | **SE** |
| 96 | `IR_ASM_BLOCK` | inline-asm passthrough; `imm` = AST node index | **SE** |
| 109–112 | `IR_ATOMIC_SUB`/`AND`/`OR`/`XOR` | RMW, return **old** | **SE** |
| 113 | `IR_EXEC` | `exec_process(path)` | **SE** |
| 114 | `IR_EXEC_ARGV` | `exec_process_argv(path, argv)` | **SE** |
| 115 | `IR_SET_EXEC` | `set_executable(path)` — chmod +x | **SE** |
| 119 | `IR_TIME_NS` | monotonic nanosecond counter | **SE** |
| 124 | `IR_FMT_BOOL` | write `"true"`/`"false"` into `src1`; `dest` = length | **SE** |
| 125 | `IR_FMT_F64` | write a decimal into `src1` from `src2`; `dest` = length | **SE** |
| 126 | `IR_ISB` | instruction-sync barrier | **SE** |
| 127 | `IR_DCACHE_FLUSH` | D-cache clean+invalidate by VA | **SE** |
| 128 | `IR_ICACHE_INV` | I-cache invalidate by VA | **SE** |
| 129 | `IR_DSB` | data-sync barrier | **SE** |
| 130 | `IR_DMB` | data-memory barrier | **SE** |
| 131 | `IR_ARR_CHECK` | under `--debug`, trap if `src1 >= imm` | **SE** |
| 146 | `IR_MODULE_PATH` | `GetModuleFileNameA(NULL, src1, src2)` — **Windows only** | **pure** |

Verified at runtime on both x86_64 and arm64: `atomic_add` returns the old
value (10, then the load reads 15); `atomic_cas` returns 1 on match and 0 on
mismatch. The two arches agree.

**`IR_MODULE_PATH` (146) writes through the `src1` buffer pointer but is
*not* in the side-effect set** (`ir_opt_is_side_effect`, `src/ir.kr:12920`,
has no `op == 146` case), unlike `IR_FMT_UINT`/`IR_FMT_BOOL`/`IR_FMT_F64`
which have the same buffer-writing shape and *are* listed. If a program calls
`get_module_path(buf, n)` and ignores the returned length, DCE is free to
delete the call. Reported, not fixed — see §13.

### 5.8 Immediate-fused forms (140–145)

| # | Name | Semantics |
|---|---|---|
| 140 | `IR_AND_IMM` | `dest = src1 & imm` |
| 141 | `IR_OR_IMM` | `dest = src1 \| imm` |
| 142 | `IR_XOR_IMM` | `dest = src1 ^ imm` |
| 143 | `IR_SHL_IMM` | `dest = src1 << imm` |
| 144 | `IR_SHR_IMM` | logical `dest = src1 >> imm` |
| 145 | `IR_SAR_IMM` | arithmetic `dest = src1 >> imm` |

All leave `src2` unused (0) and carry the constant in `imm`. All are
optimizer products.

The old text called all six "riscv32-only". **That is wrong for 143**, which
is created by the pow2-`MUL`→`SHL` strength reduction for *every* arch
(`src/ir.kr:12642`) and has handlers on all four backends. 140–142 and
144–145 are created only under `target_arch == 2` (`src/ir.kr:12848`), even
though xtensa carries handlers for them (`src/ir_xtensa.kr:1954`, `1975`) —
those xtensa arms are dead code today.

Shift-amount width is enforced in the *producer*, not the consumer:
`src/ir.kr:12642` refuses to fold a shamt ≥ 32 when
`target_arch == 2 || target_arch == 3`, because RV32 `slli`/`srli`/`srai` and
the Xtensa equivalents take a 5-bit shamt while x86/arm64 take 6.

---

## 6. Backend coverage matrix

Four emitters, one dispatch function each:

| Arch | Dispatch fn | File:line | NYI helper |
|---|---|---|---|
| x86_64 | `ir_emit_x86_insn` | `src/ir.kr:8728` | `x86_nyi_op`, `src/ir.kr:8574` |
| AArch64 | `ir_emit_arm64_insn` | `src/ir_aarch64.kr:940` | `a64_nyi_op`, `src/ir_aarch64.kr:738` |
| RV32IMC | `ir_emit_riscv_insn` | `src/ir_riscv.kr:1113` | `rv_nyi_op`, `src/ir_riscv.kr:133` |
| Xtensa LX6 | `ir_emit_xtensa_insn` | `src/ir_xtensa.kr:1713` | `xt_nyi_op`, `src/ir_xtensa.kr:157` |

All four NYI helpers write `error: <arch>: IR op <N> not yet implemented\n`
to fd 2 and `exit(1)`. **There is never a silent fallback.** RISC-V has a
second, earlier rejection: `rv_op_is_float` (`src/ir_riscv.kr:151`) covers
20–27, 97–108, 118 and 125, and `rv_float_trap` (`src/ir_riscv.kr:144`)
prints `error: float not supported on riscv32 (no hardware FPU)`.

**No emitter implements the whole set.** The old text's claim that "x86_64
and AArch64 implement the whole set" is false in both directions.

`✓` = handled, `—` = falls to NYI, `F` = rejected by the riscv float
backstop, `H` = handled only when `freestanding == 0`, `fn` = handled in the
function-level loop rather than the instruction dispatch.

| Op | Name | x86 | a64 | rv32 | xtensa |
|---|---|:--:|:--:|:--:|:--:|
| 1–11 | const, add…shr | ✓ | ✓ | ✓ | ✓ |
| 12–13 | neg, not | ✓ | ✓ | — | — |
| 14–19 | unsigned compares | ✓ | ✓ | ✓ | ✓ |
| 20–27 | f64 arith / cmp / conv | ✓ | ✓ | F | — |
| 30–32 | load, store, stack_addr | ✓ | ✓ | ✓ | ✓ |
| 40–41 | br, br_cond | fn | fn | fn | fn |
| 42–43 | ret, ret_void | ✓ | ✓ | ✓ | ✓ |
| 50–52 | call, arg, syscall | ✓ | ✓ | ✓ | ✓ |
| 60 | **phi** | — | — | — | — |
| 61 | copy | ✓ | ✓ | ✓ | ✓ |
| 70–71 | alloc, dealloc | ✓ | ✓ | H | — |
| 72–79 | memcpy…str_const | ✓ | ✓ | ✓ | ✓ |
| 80–83 | extract/ret2/ret3 | ✓ | ✓ | — | — |
| 84 | static_addr | ✓ | ✓ | ✓ | ✓ |
| 85 | syscall_raw | ✓ | ✓ | H | — |
| 86–88 | fn_addr, call_ind, memcmp | ✓ | ✓ | ✓ | ✓ |
| 90–92 | atomic store/load/add | ✓ | ✓ | — | — |
| 93 | atomic_cas | ✓ | ✓ | — | **✓** |
| 94–96 | vstore, vload, asm_block | ✓ | ✓ | ✓ | ✓ |
| 97–108, 118 | float builtins | ✓ | ✓ | F | — |
| 109–112 | atomic sub/and/or/xor | ✓ | ✓ | — | — |
| 113–115 | exec, exec_argv, set_exec | ✓ | ✓ | — | — |
| 119 | time_ns | ✓ | ✓ | — | — |
| 120–123 | signed compares | ✓ | ✓ | ✓ | ✓ |
| 124 | fmt_bool | ✓ | ✓ | — | — |
| 125 | fmt_f64 | ✓ | ✓ | F | — |
| 126–131 | barriers, cache, arr_check | ✓ | ✓ | — | — |
| 132–136 | sdiv…sub_imm | ✓ | ✓ | ✓ | ✓ |
| 137 | ror | ✓ | ✓ | ✓ | — |
| 138 | mul_imm | ✓ | — | — | — |
| 139 | lea_bis | ✓ | ✓ | — | — |
| 140–142 | and/or/xor_imm | — | — | ✓ | ✓ (dead) |
| 143 | shl_imm | ✓ | ✓ | ✓ | ✓ |
| 144–145 | shr_imm, sar_imm | — | — | ✓ | ✓ (dead) |
| 146 | module_path | ✓ | ✓ | — | — |
| 147–148 | load_bis, store_bis | — | ✓ | — | — |

Consequences worth stating plainly:

- **`IR_NEG` (12) and `IR_NOT` (13) are unimplemented on riscv32 and
  xtensa**, and both *are* emitted by ordinary lowering, so `-x` and `~x` on
  a non-constant operand are hard build failures on those targets.
- **`IR_ALLOC` (70) is hosted-only on riscv32** (`src/ir_riscv.kr:2066`
  opens `if freestanding != 0 { rv_nyi_op(op); return }`) **and absent on
  xtensa entirely.** Since structs and local arrays over the stack threshold
  lower to `IR_ALLOC`, they are unavailable on freestanding riscv32 and on
  xtensa. Same shape for 71 and 85.
- **Xtensa has `IR_ATOMIC_CAS` but none of the other atomics** — it has
  `S32C1I` and nothing else. No other backend has that asymmetry.
- riscv32 and xtensa additionally lack the whole process-control block
  (113–115), the barrier/cache block (126–131), `IR_TIME_NS`, `IR_FMT_BOOL`,
  and the 2/3-tuple return block.

See also the
[embedded support matrix](../README.md#embedded-targets-riscv32--xtensa--esp32).

---

## 7. Opcodes that are many-to-one with the surface language

### `IR_CALL` (50) carries a token index, resolved by text

`imm` on an `IR_CALL` is the index of a token in the *source text*. At
fixup time, `fn_lookup()` (`src/codegen.kr:3221`) walks the function table
comparing with `tok_text_eq()` (`src/codegen.kr:1255`), which compares byte
by byte through `cg_source`.

**Consequence: a compiler-synthesised call to a name that has no token in the
program's source is impossible.** There is no "make me a symbol" path. Any
lowering that wants to call something must find a real token for it. This is
why `builtin_override_tok_of()` (`src/codegen.kr:3299`) exists and returns
the *definition's* token: the `--target=none` print rerouting needs a token
to put in an `IR_CALL`, and the only one available is the one on the
`@builtin_override fn write` declaration. Designs that assume otherwise have
been derailed twice.

### The IR backend has no extern relocation on x86_64 or arm64

`grep extern src/ir_aarch64.kr src/ir_xtensa.kr` returns nothing. The x86
`IR_CALL` handler (`src/ir.kr:10327`–`9821`) records only an entry in the
internal `fixup_table`; it never calls `extern_fn_lookup`. Extern symbols are
the reason `--emit=obj` and `--emit=lkm` are routed to the legacy backend
(§2).

**One exception, and it is real:** `src/ir_riscv.kr:1579`–`1600` *does* emit
`R_RISCV_CALL_PLT` for an extern callee when `cg_emit_mode == 3`. riscv32 has
no legacy backend, so `--emit=obj` there necessarily goes through the IR, and
the relocation had to be implemented in it. Verified:

```
$ krc --arch=riscv32 --emit=obj extr.kr -o extr.o
$ readelf -r extr.o
00000010  00000213 R_RISCV_CALL_PLT  00000000   xstrlen + 0
```

A blanket "the IR backend cannot do extern relocations" is therefore wrong at
HEAD; the accurate statement is *"x86_64 and arm64 IR paths cannot; riscv32's
can, under `--emit=obj` only."*

### `IR_SYSCALL` (52) carries a syscall number, not a builtin

`imm` is the **canonical Linux syscall number**, not an internal kind. Each
emitter feeds it through an arch/OS remapper (`ir_x86_syscall_nr`
`src/ir.kr:8131`; `ir_a64_syscall_nr` `src/ir_aarch64.kr:755`;
`ir_rv32_syscall_nr`), and branches on specific Linux values — `imm == 2`
triggers the `open`→`openat` argument shift on arm64 and riscv32.

The mapping from builtins to numbers is **many-to-one**:

| nr | Builtins that produce it | `ir_emit_syscall` call sites in `src/ir.kr` |
|---|---|---|
| 1 (`write`) | `write`, `print`, `println`, `print_str`, `println_str`, `file_write` | 2078, 2594, 2630, 2643, 2813, 3001 |
| 0 (`read`) | `read`, `file_read` | 2665, 2831 |
| 8 (`lseek`) | `file_size` (twice: END then SET) | 2852, 2858 |

So the emitter **cannot** recover which builtin it is serving from `imm`
alone. That is why `ir_insn_origin` (`src/ir.kr:244`) exists: a parallel
u64-per-instruction table holding a pointer to a static name literal naming
the surface builtin.

**`ir_emit_syscall()` (`src/ir.kr:691`) is the only constructor of
`IR_SYSCALL`.** Verified: the only `ir_emit` call with `IR_SYSCALL` in the
tree is `src/ir.kr:692`, inside that function, and there is no `ir_emit(52,`
anywhere. It has 13 call sites, all in `src/ir.kr`. A future lowering
therefore cannot add an anonymous `IR_SYSCALL` by accident.

Readers: `ir_insn_origin_at()` (`src/ir.kr:508`), called from the op-52
handler on all three IR backends that have one (`src/ir.kr:10310`,
`src/ir_aarch64.kr:1709`, `src/ir_riscv.kr:2348`). Each falls back to
`"an unnamed syscall lowering"` when the slot is 0 — never a guessed name.

Note that `IR_SYSCALL_RAW` (85) is a *different* opcode, emitted through plain
`ir_emit`, and carries no origin; its emitters hard-code `"syscall_raw"`.

---

## 8. Per-target divergence, opcode by opcode

### 8.1 Per-OS

| Op | x86 branch | arm64 branch | What differs |
|---|---|---|---|
| 52 `IR_SYSCALL` | `src/ir.kr:10299` | `src/ir_aarch64.kr:1691` | Windows → IAT thunks; macOS numbers get `0x2000000` OR'd; arm64 `open`→`openat` shift on Linux/Android but not macOS |
| 70 `IR_ALLOC` | `src/ir.kr:9628`, `9072` | `src/ir_aarch64.kr:1734`, `1690` | Windows → `VirtualAlloc(NULL, size+8, 0x3000, 4)` through the IAT; elsewhere inline `mmap` with flags `0x22` (Linux/Android) vs `0x1002` (macOS) |
| 71 `IR_DEALLOC` | `src/ir.kr:9628` | `1717` | `VirtualFree(ptr-8,0,MEM_RELEASE)` vs `munmap` |
| 85 `IR_SYSCALL_RAW` | — | `2047` | syscall-number register is **x16 on macOS, x8 elsewhere** |
| 113/114 `IR_EXEC*` | `10380`/`10487` | `2353`/`2446` | `CreateProcessA` + `WaitForSingleObject` + `ExitProcess` vs `execve` |
| 115 `IR_SET_EXEC` | `10595` | `2546` | **emits nothing on Windows**; `fchmodat` on Linux/Android, `chmod` nr 15 on macOS |
| 119 `IR_TIME_NS` | `10672`/`10705` | `2603`/`2620`/`2643` | QPC/QPF on Windows, `gettimeofday` on macOS, `clock_gettime(CLOCK_MONOTONIC)` on Linux/Android |
| 131 `IR_ARR_CHECK` | `10816` | `2744` | trap sequence differs per OS; **on arm64 + Windows the check is skipped entirely** (`if target_os == 2 { return }`, `src/ir_aarch64.kr:2849`) |
| 146 `IR_MODULE_PATH` | `10615` | `2581` | `GetModuleFileNameA` on Windows; otherwise the emitter loads 0 |

Verified concretely — `alloc(64)` on Linux x86_64 emits an inline `mmap` and
stores the size in an 8-byte header below the returned pointer:

```
mov  $0x40,%ebx           ; size
push %rbx
mov  %rbx,%rsi ; add $0x8,%rsi   ; length = size + 8
xor  %rdi,%rdi                   ; addr = NULL
mov  $0x3,%edx                   ; PROT_READ|PROT_WRITE
mov  $0x22,%r10d                 ; MAP_PRIVATE|MAP_ANONYMOUS
mov  $-1,%r8 ; xor %r9,%r9       ; fd = -1, offset = 0
mov  $0x9,%eax ; syscall         ; mmap
pop  %rcx ; mov %rcx,(%rax)      ; header = size
lea  0x8(%rax),%rax              ; return base + 8
```

Under `--emit=pe` the same program's binary contains `VirtualAlloc` and
`kernel32.dll` in its import table instead — verified with `strings`.

**Per-OS lowering** (as opposed to emission) is much rarer.
`ir_lower_stmt()` has **no `target_os` branch at all**. In `ir_lower_expr()`:

- `file_open` bakes `0x241` (Linux/Android) vs `0x601` (macOS) into an
  `IR_CONST` (`src/ir.kr:2886`).
- `get_target_os` folds `target_os` verbatim into an `IR_CONST`
  (`src/ir.kr:3459`).
- `get_arch_id` folds an OS × arch crosstable into an `IR_CONST`
  (`src/ir.kr:3498`). Bare-metal ids are 9–12, deliberately outside the 1–8
  KrboFat slice space. **ABI trap**: `if get_arch_id() == 2` meaning arm64
  sees **10** under `--target=none`.
- `get_module_path` emits `IR_MODULE_PATH` **only** when `target_os == 2`
  (`src/ir.kr:2461`); otherwise `IR_CONST 0`.
- `print`/`println`/`print_str`/`println_str` take a completely different
  lowering under `target_os == 4` (`ir_lower_print_bare_metal`,
  `src/ir.kr:1543`) — stack scratch plus a provider `IR_CALL`, no `IR_ALLOC`
  and no `IR_SYSCALL`.

### 8.2 Per-arch, beyond instruction encoding

| Op | Divergence |
|---|---|
| 126 `IR_ISB` | real `ISB` on arm64 (`src/ir_aarch64.kr:2804`); **complete no-op on x86_64**, zero bytes emitted (`src/ir.kr:11301`) |
| 128 `IR_ICACHE_INV` | `IC IVAU; DSB ISH; ISB` on arm64; **no-op on x86_64** (`src/ir.kr:11328`) |
| 129 / 130 `IR_DSB` / `IR_DMB` | distinct instructions on arm64 (`DSB SY` / `DMB ISH`); **both collapse to the same `MFENCE`** on x86 — two IR ops, one instruction |
| 127 `IR_DCACHE_FLUSH` | `CLFLUSH; MFENCE` on x86 vs `DC CIVAC; DSB ISH; ISB` to Point of Coherency on arm64 — different reach; the arm64 form needs EL1+ on real hardware |
| 131 `IR_ARR_CHECK` | absent on arm64 + Windows (above) |
| 5/6 `IR_DIV`/`IR_MOD` | x86 faults on divide-by-zero, arm64 returns 0 (§5.1) |

`IR_VSTORE`/`IR_VLOAD` are intended for MMIO. `DSB SY` on arm64 is a
data-sync barrier only — it does **not** flush the instruction cache. If you
write code to RAM and then call it, issue `ISB` explicitly (inline asm, or
the `isb()` builtin).

---

## 9. Side effects, purity, and what survives DCE

There are **two different predicates** and conflating them is a trap.

**`ir_opt_is_side_effect(op)`** — `src/ir.kr:12920`. Used by DCE: an
instruction whose `dest` is dead is **NOP'd out** (its opcode set to 0)
*unless* this returns 1. Nothing is ever removed from the arena or the block
lists, and no block is ever deleted. The complete set at HEAD, read out of
the function:

```
31 STORE            148 STORE_BIS       40 BR            41 BR_COND
42 RET              43 RET_VOID         50 CALL          51 ARG
52 SYSCALL          70 ALLOC            71 DEALLOC       72 MEMCPY
74 FMT_UINT         76 MEMSET          124 FMT_BOOL     125 FMT_F64
78 STATIC_STORE     80 EXTRACT_RDX      81 EXTRACT_R8    82 RET2
83 RET3             85 SYSCALL_RAW      87 CALL_IND
90..96              (atomics, vstore, vload, asm_block)
109..115            (atomic RMW, exec, exec_argv, set_exec)
119 TIME_NS        126 ISB             127 DCACHE_FLUSH 128 ICACHE_INV
129 DSB            130 DMB             131 ARR_CHECK
```

The old text's version of this list omitted `FMT_UINT`, `FMT_BOOL`,
`FMT_F64`, `STORE_BIS`, and the whole barrier/cache/`ARR_CHECK` group.

**`ir_opt_cse_is_pure(op)`** — `src/ir.kr:13131`. Used by CSE to decide what
may be hashed and collapsed. This is a *whitelist of arithmetic*, not the
complement of the side-effect set; see §10 for the full three-way split and
why the gap between the two predicates matters. `IR_LOAD` (30) is in neither
set: it is DCE-able when dead, but it is not CSE-pure, because there is no
alias analysis and a load cannot be assumed to return the same value twice.

### What DCE does not do, and what needs a seed

- Unused-result `alloc()` / `file_open()` are **not** deleted, and under
  `--target=none` they still refuse — verified at `563b0f3` by rebuilding
  four commits. (An earlier report claimed the opposite; the cause was a
  scratch harness piping the compiler through `head -4`, which cut off a
  diagnostic that lands on line 6. Print the *whole* output before concluding
  the compiler did not diagnose something.)
- **AST-level DCE seeds only `main` and `@export`** (`dce_scan`,
  `src/codegen.kr:13700`). `_start` is not a seed, so freestanding riscv32 and
  xtensa entry points had to be added explicitly (`src/main.kr:2628`–`2374`).
- **A provider reached only through override resolution gets pruned.** Under
  `--target=none`, `println` reroutes to the `@builtin_override fn write`
  provider, and an f-string's buffer reroutes to the `alloc` provider — but
  neither reroute is a `Call` node in the AST, so the provider is dead to
  `dce_scan` and is pruned. Both needed explicit seeds
  (`src/codegen.kr:13535`–`12035`). The seeds are deliberately *narrow* —
  gated on `target_os == 4`, on the callee really being one of the four print
  builtins, and on that name not itself being overridden — so that the test
  proving the seed is load-bearing cannot pass vacuously.

---

## 10. Optimizer

The driver is `ir_optimize()` (`src/ir.kr:13555`). **There is no
`ir_opt_run()`** — that name appears only in older revisions of this
document. It runs once per function, after lowering and before liveness.

`--O0` sets `ir_opt_level = 0` (`src/ir.kr:12318`, written only at
`src/main.kr:9168`) and each backend skips the whole call
(`src/ir.kr:14396`, `src/ir_aarch64.kr:3356`, `src/ir_riscv.kr:2414`,
`src/ir_xtensa.kr:2816`). Note the spelling: **`--O0`**, two dashes. There is
no `-O0`, `-O1`, `--O2` — no other write to `ir_opt_level` exists.

**What `--O0` does *not* disable**, because these live outside
`ir_optimize()`: liveness, use counts, wide-colour-file selection, colour
ceilings, **copy coalescing**, the XMM/FPR allocators, and the emit-time
spill peepholes. `--O0` is not "straight from lowering to regalloc".

Exact order at HEAD. Every cleanup DCE is conditional on the preceding pass
having bumped `ir_opt_rewrites` (a global monotone counter, `src/ir.kr:28`;
the pipeline only compares deltas, so never resetting it is sound):

| # | Pass | Line | Gate |
|---|---|---|---|
| 0 | memset the constant/w32 lattices over `min(ir_vreg_next, 65536)` | 13001 | always |
| 1 | `ir_opt_const_fold()` (fn 11799) | 13008 | always |
| 2 | `ir_opt_dce()` (fn 12422) | 13009 | always |
| 3 | `ir_opt_cse()` (fn 12594) | 13011 | always |
| 4 | `ir_opt_dce()` | 13016 | if CSE rewrote |
| 5 | `ir_opt_licm()` (fn 12988) — **loops up to 8×** over `ir_opt_licm_one_pass()` (fn 12893), stopping at fixpoint | 13026 | `ir_licm_enabled != 0` **and** `ir_loop_count != 0` |
| 6 | `ir_opt_dce()` | 13027 | if LICM rewrote |
| 7 | `ir_opt_recognize_rotate()` (fn 13489) | 13035 | always |
| 8 | `ir_opt_const_fold()` then `ir_opt_dce()` | 13040 | if rotate fired |
| 9 | `ir_opt_recognize_lea_bis()` (fn 13135) | 13048 | always |
| 10 | `ir_opt_dce()` | 13049 | if it fired |
| 11 | `ir_compute_use_count()` → `ir_opt_fuse_lea_mem()` (fn 13260) → conditional DCE | 13056 | **`target_arch == 1` only** |
| 12 | `ir_compute_use_count()` → `ir_opt_recognize_ffma()` (fn 13085) → conditional DCE | 13067 | always |

So const-fold runs once or twice, DCE up to six times, LICM up to eight inner
iterations, everything else exactly once. **There is no outer fixpoint loop
over the whole pipeline.**

`ir_licm_enabled` (`src/ir.kr:13541`) gates step 5 but is **never assigned
anywhere** — a dead knob with no CLI flag.

Ordering rationale recorded in source, worth preserving:

- CSE runs **before** LICM so LICM sees one canonical instance per invariant
  expression.
- The second const-fold after rotate recognition exists to elide a consumer's
  `& 0xFFFFFFFF` over the new (w32-clean) `IR_ROR`.
- `ir_compute_use_count()` is recomputed immediately before both
  use-count-sensitive passes, because the DCE in between changes counts.
- LICM appends hoisted instructions at **high arena indices but low block
  positions**. Anything that assumes instruction index order matches
  execution order breaks. Liveness and `ir_graph_color` are safe only because
  they walk `ir_build_bb_lists` order (`src/ir.kr:13311`), not index ranges.

### Per-pass contracts

**`ir_opt_const_fold` (11799)** — linear walk, but **flow-insensitive**: the
constant map is wiped at every block boundary (11830), so it is effectively
intra-block. It does far more than fold two `IR_CONST`s: binary fold for
2–11 and 14–19, unary `NEG`/`NOT`, identity and zero rules → `COPY`/`CONST`,
`AND(x, 0xFFFFFFFF)` → `COPY` when `x` is w32-clean, pow2 `MUL` → `SHL_IMM`,
and all five immediate-fusion families. It **propagates through `IR_COPY`**
(11887), so operands need not be literal `IR_CONST`s.
*Breaking invariant:* the w32-clean lattice is sound only for single-def
vregs, and `ir_w32_single_def` (11789) gates every set — because merges
redefine snapshot vregs via `COPY` (§1). Remove that gate and live
`& 0xFFFFFFFF` masks get silently elided.

**Branch folding is inline here** (11956): an `IR_BR_COND` with a
constant condition becomes an `IR_BR`. **CFG successors are deliberately
left as lowered** (comment 11953) — liveness over-approximates, and
**nothing ever removes the untaken block.**

**`ir_opt_dce` (12422)** — a **backward** sweep over the flat array iterated
to fixpoint, then a forward **NOP-out** sweep that sets `opcode = 0`
(12482). It never deletes an instruction and never touches the block linked
lists; terminators survive via `ir_opt_is_side_effect`. It crosses blocks.
*Breaking invariant:* the operand-shape exclusion list in `ir_opt_dce` (which
opcodes really read `src2`, and the imm-as-vreg set `{72, 76, 83, 93, 98,
148}`) is **duplicated verbatim in six other places — seven copies in total**.
See §14 for the full list; any divergence between them miscompiles.

**`ir_opt_cse` (12594)** — strictly **intra-block**. Hashes
`{op, canon(src1), canon(src2), canon(imm)}` into a 4096-entry
direct-mapped table; a hit rewrites the instruction to `IR_COPY <earlier>`.
Any op in `ir_opt_cse_invalidates` (12562) bumps a generation stamp, wiping
the table in O(1).

**`ir_opt_licm` (12988) / `ir_opt_licm_one_pass` (12893)** — crosses blocks.
Loop metadata comes **only from the `while` lowering** (`src/ir.kr:4762`,
records `[preheader, header, body_first, body_last]`, cap 256). A hoist
requires the dest to be **single-def** (12948; multi-def sentinel
`0xFFFFFFFE`). `ir_licm_is_hoistable` (12807) is *stricter* than CSE purity:
it excludes `IR_CONST` (rematerialising is cheaper — hoisting them cost 30%
on sort) and `IR_STATIC_LOAD`.

**`ir_opt_recognize_ffma` (13085)** — matches `FADD` whose `src1` or `src2`
is defined by an `FMUL` with **exactly one use**. *Breaking invariant:*
gated to `imm == 1` (f64) on both. `IR_FFMA`'s emitter is f64-only and has no
float-kind slot; firing on f32 would run `mulsd`/`addsd` over f32 bit
patterns and silently produce garbage.

**`ir_opt_recognize_lea_bis` (13135)** — `ADD(base, MUL_IMM(idx, K))` or
`ADD(base, SHL_IMM(idx, k))` → `IR_LEA_BIS`. **Does not check use counts**;
the feeding op stays live if it has other users.

**`ir_opt_fuse_lea_mem` (13260)** — arm64 only, **intra-block**. Commits only
if `matched == ir_use_count_get(dest)` with a non-saturated count. It
maintains `ir_lea_mem_dirty` and refuses to trust a use count its own
commits invalidated — which is why step 11 recomputes counts first.

**`ir_opt_recognize_rotate` (13489)** — matches the canonical 32-bit rotation
idiom through `ir_def_skip_copy` (so it sees past CSE's copy chains) and
rewrites the `OR` in place to `IR_ROR`. The dead `AND`/`SHL`/`SHR`/`CONST`
chain is left for the DCE at step 8.

### `ir_opt_cse_is_pure` vs `ir_opt_is_side_effect` — the trap, precisely

They are **not complements**, and there is a large gap between them.

- **CSE-pure** (`src/ir.kr:13131`): 1–19, 20–27, 77, 79, 84, 86, 97–108,
  120–123, **and 143 only** of the immediate family.
- **Side-effecting** (`src/ir.kr:12920`): the list in §9.
- **Neither** — DCE-able when dead, but *never* CSE'd or hoisted:
  `IR_LOAD` 30, `IR_STACK_ADDR` 32, `IR_COPY` 61, `IR_STRLEN` 73,
  `IR_STR_EQ` 75, `IR_MEMCMP` 88, 105, 106, 118, `IR_SDIV` 132,
  `IR_SMOD` 133, `IR_SAR` 134, `IR_ADD_IMM` 135, `IR_SUB_IMM` 136,
  `IR_ROR` 137, `IR_MUL_IMM` 138, `IR_LEA_BIS` 139, 140–142, 144, 145,
  `IR_MODULE_PATH` 146, `IR_LOAD_BIS` 147.

Two consequences worth writing down:

1. **`IR_STATIC_LOAD` (77) is CSE-pure but is a memory read.** That is sound
   only because a `STORE`/`CALL` bumps the CSE generation. LICM has no such
   protection and excludes 77 explicitly (12793) — the comment records the
   `dce_scan` infinite-loop miscompile this caused.
2. **Strength reduction destroys CSE and LICM opportunities.** const-fold
   runs *before* CSE and rewrites `ADD`→`ADD_IMM`, `MUL`→`MUL_IMM`. Those
   products are mathematically pure but not on the CSE whitelist, so
   expressions that would have been collapsed or hoisted as `ADD`/`MUL` no
   longer are. The comment at 12578 acknowledges the hazard, but it was only
   fixed for 143.

Also latent: `IR_STORE_BIS` (148) is in `ir_opt_is_side_effect` but **not**
in `ir_opt_cse_invalidates`. Not exploitable today — 148 is created at step
11, strictly after the only `ir_opt_cse()` call — but it becomes a live bug
the moment CSE is moved or re-run.

---

## 11. Register allocator

`ir_graph_color()` (`src/ir.kr:6731`) is shared by all four backends through
a single colour→physical-register table (`ir_phys_regs`, sized once for the
largest file any arch uses, `src/ir.kr:6144`).

**It is not Chaitin-style.** There is no simplify/select stack and no
spill-and-rebuild loop. One pass:

1. every vreg pre-set to `0xFFFFFFFF` = spilled (6852);
2. representatives ordered by **saturating use count, descending**, via a
   counting sort (6872); `ir_use_count_get` saturates at 255. Any order would
   be *correct*; this one is a spill-cost priority;
3. for each rep, take the lowest colour not used by an interfering neighbour
   and below the rep's colour ceiling (6960). **If none is free the vreg
   simply stays `0xFFFFFFFF` and spills** — there is no retry;
4. rep colours propagate to coalescing followers (6975).

`ir_used_color_mask` (6405) then tells the prologue which callee-saved
colours were actually used, so only those get pushed. *(Its own comment at
`src/ir.kr:6714` still says "5-bit set" — stale; it is 6 bits and includes
rbp. That comment is the likely origin of the wrong claim in earlier
revisions of this document.)*

### Colour files, verified from the init functions

The old text's "x86_64: 5 colors → rbx, r12, r13, r14, r15" is wrong on the
count, the set, **and** on which file is the default.

| Arch | Narrow | Registers | Wide (**the default**) | Extra registers |
|---|---|---|---|---|
| x86_64 | 6 (`src/ir.kr:6153`) | rbx, r12, r13, r14, r15, **rbp** | **12** (`src/ir.kr:6190`) | + rsi, rdi, r8–r11 (all caller-saved) |
| arm64 | 10 (`src/ir_aarch64.kr:196`) | x19–x28 | **23** (`src/ir_aarch64.kr:240`) | colours 10–18 → x0–x8; 19–22 → x12–x15 |
| riscv32 | 12 (`src/ir_riscv.kr:108`) | — | (none) | |
| xtensa | 4 (`src/ir_xtensa.kr:477`) | — | 9 (`src/ir_xtensa.kr:522`) | |

**Wide is what runs.** Narrow is the fallback. The narrow file is
callee-saved only, so a colour survives a call for free. The wide file
appends caller-saved registers **after** the callee-saved prefix, so the
prologue/epilogue (which look only at colours below the prefix length) need
no change and "must survive a call" becomes simply "ceiling = prefix length".

Registers deliberately excluded from the x86 wide file, and why
(`src/ir.kr:6177`–`5937`): **rax/rcx** are the universal spill-reload
scratch pair used by `ir_resolve_src`, **rcx** is also the variable-shift
count (CL), and **rdx** is `div`/`mod`'s implicit high half and `IR_FFMA`'s
third-operand scratch. On arm64 the exclusions are x9/x10 (scratch pair),
x11 (`IR_MOD` quotient temp and large-frame address scratch), x16/x17
(linker veneer scratch; x16 is also the ADRP target of the static/str-const
fixup sequences and macOS's syscall-number register) and x18
(platform-reserved).

**Wide-mode gate — exactly two disqualifiers.** The function contains an
`IR_ASM_BLOCK` (op 96) anywhere in its body, or it is `@naked`.
`ir_x86_fn_wide_ok` (`src/ir.kr:6323`) / `ir_a64_fn_wide_ok`
(`src/ir_aarch64.kr:289`) test only the former; the call sites
(`src/ir.kr:14419`, `src/ir_aarch64.kr:3376`) add `&& is_naked == 0`. The asm
check must stay a **whole-body scan, not a constraint-list scan** — the
comment at `src/ir.kr:6299` records a real case where a CPUID block wrote r13
with no constraint naming it. `@naked` is excluded because it gets
`frame_size = 0`, so a ceiling-forced spill would store outside any frame.

### Colour ceilings

This is the mechanism that makes the wide file correct without auditing every
op handler, and it is the part of the allocator most likely to be
misunderstood.

The wide file hands out **caller-saved** registers. A value that must survive
a `CALL`, a syscall, a helper loop or a Windows IAT thunk cannot live in one.
Rather than teach the colourer about physical registers, each vreg gets a
per-vreg cap: *you may only take colours below N*. Setting N to the
callee-saved prefix length (6 on x86, 10 on arm64) confines the value to
registers the ABI preserves.

`ir_seed_wide_ceilings_generic` (`src/ir.kr:6378`) seeds these at
**instruction** granularity, not block granularity. The comment at
`src/ir.kr:6329` records why: sha256's whole 64-round compression body is one
block containing two small calls, so block-level capping surrendered every
register in exactly the code the feature exists for. It walks each block
backward and, at every "dirty" (non-whitelisted) instruction, caps everything
live after it, its own dest, and everything live before it. Temporaries whose
entire life sits between two dirty points keep the full file.

Whitelists: `ir_x86_op_widesafe` (`src/ir.kr:6274`) and `ir_a64_op_widesafe`
(`src/ir_aarch64.kr:269`) — "safe" means the handler touches no physical
register outside the scratch set beyond its allocator-assigned operands. The
arm64 list additionally excludes 77/78/79/84/86, because arm64's
static-data / str-const / fn-addr sequences materialise through **X16 *and*
X0**. A missing whitelist entry is a lost optimisation, never a miscompile.

`ir_color_ceil_to_reps` (`src/ir.kr:6586`) exists because coalescing colours
*representatives* and propagates to followers: without pushing the tightest
ceiling onto the rep, a capped vreg coalesced with an uncapped one would
inherit a colour its own ceiling forbids — a value a call is about to destroy
quietly landing in a caller-saved register. Called at `src/ir.kr:7170`, after
coalescing is final and before the greedy loop.

**Parameter ceilings** solve a different, sharper problem.
`ir_a64_seed_param_ceilings` (`src/ir_aarch64.kr:318`) and
`ir_x86_seed_param_ceilings` (`src/ir.kr:6503`) cap every register-passed
parameter to the callee-saved prefix. The leading param copies read x0–x7 /
rdi,rsi,rdx,rcx,r8,r9 **one at a time in ascending param order**; if param 0's
home were x3, the copy for param 3 would read a register param 0 already
clobbered. Capping the params is enough and needs no parallel-move
sequencing.

### Copy coalescing

Lives **inside** `ir_graph_color` (`src/ir.kr:6914`–`6843`), after the
interference graph is built and before the greedy loop. On by default;
`ir_coalesce_enabled` (`src/ir.kr:6646`) is read only in the loop condition
at 6640, and `--no-coalesce` clears it. **`--O0` does not disable it.**

Candidates are every `IR_COPY` with non-zero dest and src1 whose
representatives differ and do not already interfere. The **lower vreg is
always kept** as the representative (6662) — a correctness requirement, not a
preference: otherwise an intermediate vreg colours against a rep that is
still uncoloured and can collide.

- **Briggs** (6666): count neighbours of the merged class whose rep's cached
  degree is `>= IR_NUM_REGS`; accept if that count is below `keff`.
- **`keff` is per-merge**, not global: `min(ceil(keep), ceil(drop))` (6684).
  Note the asymmetry — the *significant-degree* test uses the global
  `IR_NUM_REGS`, the *accept threshold* uses the tightest ceiling.
- **George** (6715) is tried only when Briggs fails, and is **skipped
  entirely when `keff < 8`** (6730). The measurement is in the comment at
  6724: arm64 (K=10) gains ~800 B, x86 (K=6) loses ~900 B. So George never
  runs for a ceiling-capped vreg, even in the wide file.

Interference-freedom is necessary but **not sufficient** — Briggs/George gate
it as well.

### Spilling

**Slots are vreg-indexed, one per vreg**, not a compacted set of spilled
values: `ir_spill_count = ir_vreg_next - 1` (`src/ir.kr:14447`,
`src/ir_aarch64.kr:3398`). The comments at `src/ir.kr:7993` and
`src/ir_aarch64.kr:353` explain why the older `vreg - IR_NUM_REGS - 1`
mapping was removed: it assumed a low-numbered vreg could never spill, but a
colour ceiling can spill **any** vreg, and the subtraction underflowed. Found
first on xtensa.

- **x86:** `[rsp + (vreg-1)*8]` (`ir_spill_offset`, `src/ir.kr:7992`);
  `ir_emit_load_spill`/`ir_emit_store_spill` pick disp8 below 128 else
  disp32. **No offset limit, no fallback needed.**
- **arm64:** `IR_A64_OVERFLOW_RESERVE + (vreg-1)*8`
  (`src/ir_aarch64.kr:353`). The reserve is **not** a constant 128 — it is
  sized per function to the actual outgoing overflow-arg need
  (`src/ir_aarch64.kr:3457`), with 128 kept only as a floor for asm-block and
  Windows functions.
- **The 32760-byte limit is real.** `ir_a64_ldr_sp` / `ir_a64_str_sp`
  (`src/ir_aarch64.kr:694`/`649`) emit the imm12-scaled form when
  `off <= 32760` (= 4095 × 8) and otherwise
  `MOV x11, imm; ADD x11, sp, x11; LDR/STR [x11]`. The scratch is
  specifically **x11**. Same structure in the d-register variants (478/488).
- **Emit-time peepholes**, which are *not* part of `ir_optimize()` and are
  *not* disabled by `--O0`: a `store_spill r,v` immediately followed by
  `load_spill r,v` with no bytes emitted between is elided entirely
  (`src/ir.kr:7961`); the same vreg into a *different* register becomes a
  reg-reg `mov` (7721). arm64 has the load-side equivalent at
  `src/ir_aarch64.kr:665`.

### Floating point — two allocators, two different designs

**Both** arches have a dedicated float allocator; the old text's claim that
x86 handles floats "inside the integer allocation" is wrong.

**arm64** — `ir_a64_fpr_alloc` (`src/ir_aarch64.kr:433`), run after
`ir_graph_color`. It **reuses the same interference graph and union-find**
but colours an independent 8-entry file `d8..d15` over representatives whose
fkind is 1 (f64). Order is **highest vreg first**, so loop-carried values
born deep in the function beat early constants to the homes. Because
`d8..d15` are AAPCS **callee-saved**, no call-liveness restriction is needed
at all. `ir_a64_fpr_used_mask` (464) lets the prologue save only the
d-registers actually handed out, paired via `stp`/`ldp`.

**x86** — `ir_x86_xmm_alloc` (`src/ir.kr:7856`), homes `xmm2..xmm15`
(`xmm0`/`xmm1` are the float scratch pair and xmm0 is the SysV float return
register). It is called **unconditionally** (`src/ir.kr:7944`) with an
`enable` argument, so a stale map from the previous function can never leak.

The decisive difference: **SysV x86-64 has no callee-saved XMM registers at
all** — a call may destroy the entire XMM file. So x86 needs a bar arm64 does
not: `ir_x86_xmm_mark_unsafe()` (`src/ir.kr:7729`) disqualifies, at
instruction granularity, every vreg live across a non-widesafe op. A second
bar is coalition purity: a rep whose coalition contains any non-f64 member is
barred, because a mixed coalition shares one storage location.

Enforcement on x86 is **funnel-based, not per-handler**: a homed vreg's GPR
colour is forcibly cleared to "spilled", so all ~70 op handlers read it
through `ir_resolve_src`/`ir_emit_load_spill` and write through
`ir_emit_store_spill`, and those funnels redirect to a `movq` against the xmm
home instead of a stack slot (`src/ir.kr:8023`/`7756`). The one emitter that
reads slots directly — the >6-argument overflow path in `IR_CALL` — carries
an explicit home check at the site (`src/ir.kr:7547`). If you add an emitter
that touches a spill slot without going through the funnels, you must add the
same check.

---

## 12. Bare metal (`--target=none`)

`target_os == 4`. Because Linux is the fall-through (§3), the guard strategy
is **choke points, not audits**: every trap instruction on every architecture
goes through exactly one emitter, and that emitter refuses.

| Arch | Trap | Choke point | File:line |
|---|---|---|---|
| x86_64 | `SYSCALL` (`0F 05`) | `emit_x86_syscall_insn` | `src/codegen.kr:650` |
| arm64 | `SVC` (`0xD4000001` / `0xD4001001`) | `emit_a64_svc_word` | `src/codegen_aarch64.kr:407` |
| riscv32 | `ECALL` (`0x00000073`) | `rv_ecall` | `src/ir_riscv.kr:262` |
| xtensa | `SIMCALL` | `xt_simcall` | `src/ir_xtensa.kr:286` |

Verified by byte-level enumeration at HEAD: exactly one adjacent
`emit_byte(0x0F); emit_byte(0x05)` pair in the tree; exactly one
`0x00000073` emission; exactly one SIMCALL encoding. All arm64
`0xD4000001` sites route through `emit_a64_svc_word`.

Two deliberate carve-outs, both documented in source:

- **Inline `asm("syscall")` / `svc` / `ecall` bypasses the guard on all four
  arches.** This is an intentional escape hatch, noted in
  `emit_x86_syscall_insn` with cross-references from the other three.
- **`exit()` still emits emulator-only mechanisms.** xtensa emits `SIMCALL`
  (QEMU `lx60` semihosting — an illegal instruction on real ESP32 silicon
  and a *silent no-op* if QEMU runs without `-semihosting`); riscv32 writes
  the QEMU-`virt`-only `sifive_test` MMIO address `0x00100000`. This is
  inherited from `--freestanding` and the release decision is **still open**;
  `--target=none` is the flag most likely to mean real silicon.

Builtin refusals live in `bare_metal_builtin_refused`
(`src/codegen.kr:808`), beside `bare_metal_trap_refused`
(`src/codegen.kr:616`) — **in `codegen.kr`, not `ir.kr`**, precisely because
`--legacy` / `--emit=obj` / `--emit=lkm` have their own builtin dispatch and
never call `ir_lower_expr`. Refusals are placed *after*
`builtin_override_lookup`, so `@builtin_override` still wins.

Verified messages:

```
$ krc --arch=x86_64 --target=none prints.kr
error: --target=none: 'println' is not available on bare metal: there is no
operating system to provide it. supply `@builtin_override fn write(uint64 fd,
uint64 buf, uint64 len) -> uint64` -- import "std/uart_16550.kr" (x86_64 COM1)
or "std/uart_pl011.kr" (arm64 PL011), or drop the call
```

Refused under `--target=none`: `--debug`, `--legacy`, `--emit=macho`,
`--emit=pe`, `--emit=android`, `--emit=lkm`. Allowed and pinned:
`--emit=obj`, `--emit=asm`, `--emit=ir`, `--emit=elfexe`, `-g`.
**Require** `--target=none` rather than merely tolerating it:
`--emit=image` and `--emit=uefi` — a third outcome this sentence had no
category for, and the reason it read as complete while omitting two modes.
`-g`'s entry is a per-mode fact, not a blanket one: it is accepted alongside
the default ELF on bare metal and **refused** by both of those two, because
the DWARF footer is laid out from an ELF geometry neither container has.
The per-mode roster the suite actually derives is
`t6_emit_table_covers_every_mode` in `tests/run_tests.sh`; prose here cannot
notice a mode nobody added to it, which is exactly how this paragraph went
stale.

### Known gap: six `IR_ALLOC` sites with no bare-metal arm

`src/ir.kr:3562`, `3461`, `3894`, `4164`, `4192`, `4209` emit `IR_ALLOC` with
no `target_os == 4` arm and no provider routing:

| Line | Construct |
|---|---|
| 3413 | struct passed **by value** as a call argument (alloc + memcpy) |
| 3461 | struct **returned** from a call |
| 3894 | struct **literal** expression (`P { 10, 20 }`) |
| 4164 | local array declaration **over the 4096-byte stack threshold** |
| 4192 | struct variable declaration **with** an initializer |
| 4209 | struct variable declaration **without** one, including arrays of structs |

Three are in `ir_lower_stmt`, which has no `target_os` reference anywhere in
its body — per-OS blindness by construction, not oversight.

They **fail closed**: the emitter's Linux `mmap` arm is reached and the trap
choke point refuses. But the diagnostic names `'alloc'`, a builtin the user
never wrote, even with `heap_bump` imported. On xtensa there is no op-70 case
at all, so they hit `xt_nyi_op(70)` instead. Structs are effectively unusable
on bare metal. Provider routing for these six is a known follow-up, pinned by
tests in both directions plus a control (`uint32[16]` still compiles, so the
pin cannot be satisfied by "nothing works").

---

## 13. Known traps and defects

Current at HEAD unless stated. Historical items that are closed have been
removed; do not re-add them without re-verifying.

**Documented behaviour that surprises people**

1. **`--emit=obj` is the legacy backend.** §2. An `--emit=obj` test proves
   nothing about IR lowering.
2. **`--emit=ir` is pre-optimization**, and `ir_opcode_name` prints `???`
   for opcodes 124, 125 and 135–148.
3. **`--target=` picks the ABI, not the container.** §2.
4. **The IR is not SSA.** §1.
5. **`IR_FFMA` is not fused.** §5.3.
6. **arm64 division by zero silently returns 0** without `--debug`. §5.1.

**Live defects found while writing this document — reported, not fixed**

7. **`IR_MODULE_PATH` (146) is missing from the side-effect set.**
   `ir_opt_is_side_effect` (`src/ir.kr:12920`) has no `op == 146` case even
   though the op writes through the `src1` buffer pointer, exactly like
   `IR_FMT_UINT`/`FMT_BOOL`/`FMT_F64` which *are* listed. A
   `get_module_path(buf, n)` whose returned length is unused is DCE-eligible.
   Windows-only, so the blast radius is small.
8. **`extern fn` in an executable emit mode compiles clean and calls the
   wrong thing.** Verified on x86_64 and arm64. `extern fn strlen(...)` plus
   `strlen("abc")`:
   - `--emit=obj`: correct — `R_X86_64_PLT32` / `R_AARCH64_CALL26` recorded.
   - default `--emit=elfexe`, IR backend: exit 0, **binds the call to a
     locally-synthesised zero-returning body** (`xor %rax,%rax; ret`).
   - `--legacy --emit=elfexe`: exit 193, **`call rel32 = 0`** — a call to the
     next instruction.

   Neither path warns. `docs/LANGUAGE.md` §24 "Extern functions" documents
   `--emit=obj` as the
   intended use, so this is a missing diagnostic rather than a broken
   feature, but the failure is silent and differs by backend.
9. **`--legacy --arch=arm64 --debug` emits no array bounds check.** Verified:
   the `--debug` artifact is byte-identical to the non-debug one, and an OOB
   store compiles clean and runs. Legacy x86_64 does emit the check;
   IR arm64 does (`src/ir.kr:3718`/`4551` + trap at
   `src/ir_aarch64.kr:2865`). `arr_count_lookup` is simply absent from
   `src/codegen_aarch64.kr`. Pre-existing, all targets.
10. **`IR_ARR_CHECK` is skipped entirely on arm64 + Windows**
    (`src/ir_aarch64.kr:2849`, `if target_os == 2 { return }`). Deliberate —
    the comment says the `ExitProcess`-via-IAT sequence does not fit the
    short-jump pattern — but it means `--debug` bounds checking does not
    exist on that pair.
11. **arm64 inline-asm register names are resolved with the x86 table.**
    `src/ir.kr:5211`/`5012` select `rv_reg_code` for riscv32 and
    `x86_reg_code` for everything else, arm64 included. Flagged in a source
    comment as pre-existing and deliberately unchanged.
12. **Dead handler arms.** Xtensa's `IR_AND_IMM`/`OR_IMM`/`XOR_IMM`/
    `SHR_IMM`/`SAR_IMM` cases (`src/ir_xtensa.kr:1954`, `1975`) are
    unreachable — their only producer (`src/ir.kr:12848`) is gated to
    `target_arch == 2` and xtensa is arch 3. Harmless, but do not mistake
    their presence for coverage. Relatedly, 140–145 are absent from **both**
    wide-safe whitelists, so any block containing one caps to the
    callee-saved prefix — the family is wide-allocator-hostile by
    construction.
13. **`IR_STORE_BIS` (148) is in `ir_opt_is_side_effect` but not in
    `ir_opt_cse_invalidates`.** Not exploitable today because 148 is created
    strictly after the only `ir_opt_cse()` call, but it becomes a live bug
    the moment CSE moves or is re-run. §10.
14. **Duplicated operand-shape tables.** The "which opcodes really read
    `src2`" exclusion list and the imm-is-a-vreg set `{72, 76, 83, 93, 98,
    148}` are written out **EIGHT separate times**, all in `src/ir.kr`. Adding
    an opcode with an unusual operand shape means editing **all eight**; any
    divergence miscompiles.

    | enclosing function |
    |---|
    | `ir_compute_liveness` |
    | `ir_compute_use_count` |
    | `ir_seed_wide_ceilings_generic` |
    | `ir_naked_diagnose_generic` |
    | `ir_graph_color` |
    | `ir_x86_xmm_mark_unsafe` |
    | `ir_opt_dce` |
    | `ir_lea_mem_reads` |

    Find them all with:

    ```
    grep -n 'op == 72 || op == 76 || op == 83 || op == 93 || op == 98 || op == 148' src/ir.kr
    ```

    **This entry said "five" until 2026-08-09, and the two it omitted were
    `ir_compute_liveness` and `ir_x86_xmm_mark_unsafe` — both in the
    liveness/interference path, i.e. exactly the class §5.4 warns produces a
    use-after-free of a register.** An implementer following the old text
    would have edited five sites and shipped a miscompile. Two further
    near-copies in `ir_opt_cse` and `ir_opt_licm_one_pass` drop `148`
    deliberately; do not "fix" those to match without reading §10 first.
    The eighth copy, `ir_naked_diagnose_generic`, arrived with the `@naked`
    callee-saved fix: it walks liveness backwards per instruction to find
    values a naked body keeps across a call, and under-approximating that
    walk turns a warning the implementer needs into silence.

**Stale comments that have already misled this document**

15. `src/ir.kr:6714` — `ir_used_color_mask` says it "returns a 5-bit set …
    rbx/r12/r13/r14/r15". It is 6 bits and includes rbp. This is the likely
    origin of the wrong colour count in earlier revisions of this file.
    MLRift's copy of the same comment was corrected; KernRift's was not.
16. `src/ir.kr:6921` — the coalescing section header says "aggressive … we
    only check for direct interference, no Briggs degree heuristic … switch
    to conservative coalescing here", sitting directly above the Briggs and
    George implementations.
17. `src/ir.kr:6535` — says the colour-ceiling buffer is "only ever populated
    by the xtensa driver; every other arch leaves the buffer null". x86 and
    arm64 both populate it now.

**Process lessons, earned expensively**

18. **Guard the choke point, not N sites — and verify N.** A brief once
    asserted "`emit_a64_svc` is a single function behind 49 call sites"; seven
    sites emitted `emit_a64(0xD4000001)` directly. Guarding the named function
    would have shipped seven live `SVC`s.
19. **A terminal `else` that returns a value is invisible to a trap scan.**
    Three shipped in this compiler: IR arm64 `set_executable` emitted *zero
    instructions* (chmod never happened, returned 0 = success); IR arm64
    `time_ns` returned constant 0; legacy `time_ns` on both arches returned
    constant 0 while exiting 0 and writing an artifact. Only a
    byte-identity/behaviour gate catches this class.
20. **A dropped assertion is a finding you decided not to have.** The legacy
    `time_ns` zero was seen as "a naming quirk" and the assertion was removed
    instead of chased. The symptom was the bug.
21. **Print the whole output before concluding the compiler did not
    diagnose something.** A scratch harness piping through `head -4` cut off
    a refusal that lands on line 6 and produced a false DCE claim that was
    then propagated into a permanent test comment.
22. **Reverting an injected byte-identity regression poisons the next
    bootstrap generation** — the injected compiler emits the bad lowering
    into its successor's own code. And `touch build/krc.kr` defeats the
    `cat $(SRCS)` regeneration, so the build silently compiles stale source.
    Recovery: restore `build/krc2` from a pristine seed and
    `rm -f build/krc.kr`.

---

## 14. Adding a new opcode

1. **Pick a number that is free in *both* KernRift and MLRift**, or accept
   that the two dialects will disagree about what it means. See §15 — this
   has already happened for 143, 147 and 148. Add
   `static uint64 IR_FOO = N` to `src/ir.kr` in the appropriate range.
2. Add the name to `ir_opcode_name()` (`src/ir.kr:5419`). It is currently
   incomplete; do not add to the gap.
3. Add the lowering in `ir_lower_expr()` or `ir_lower_stmt()`, **or** the
   optimizer pass that synthesises it. If the op is created by the optimizer
   only, it will never appear in `--emit=ir`.
4. Add the emission branch to every backend that must support it, and check
   the others fail *loudly* — the NYI helpers do, but only if the opcode
   really falls through to them.
5. If it has a side effect, add it to `ir_opt_is_side_effect()`
   (`src/ir.kr:12920`). If it is safe to CSE, add it to
   `ir_opt_cse_is_pure()` (`src/ir.kr:13131`). These are two different
   decisions.
6. If any operand slot is used unconventionally — `imm` holding a vreg,
   `dest` holding a width — audit **every** liveness, use-count, DCE and
   interference list for it. `IR_STORE_BIS` and `IR_FFMA` are the existing
   examples to copy.
7. If the op needs per-OS behaviour, remember that the legacy backend has its
   own dispatch and never sees your lowering (§2, §3).
8. Add a test in `tests/run_tests.sh` that exercises a mode which actually
   uses the IR backend.
9. Update this reference, and re-verify the counts in §3 and §6 rather than
   editing them by hand.

---

## 15. Divergence from MLRift

MLRift (`../MLRift`, HEAD `24796d5`) is a fork of KernRift; `src/ir.mlr`
corresponds to `src/ir.kr`. Its copy of this document covers its own side.
**113 opcode names are shared and 110 of them have identical numbers**; ops
0–139 are identical everywhere, and both backends' dispatches agree on
opcodes 1–123. All divergence is at 124 and above.

### Opcode numbers 140–150 mean different things

MLRift reserves **140–147 for GPU host ops** (`src/ir_hip.mlr`), so its
later opcodes are shifted. The same number therefore denotes different
opcodes in the two dialects:

| Number | KernRift | MLRift |
|---|---|---|
| 140 | `IR_AND_IMM` | `IR_GPU_ALLOC` |
| 141 | `IR_OR_IMM` | `IR_GPU_FREE` |
| 142 | `IR_XOR_IMM` | `IR_GPU_H2D` |
| **143** | **`IR_SHL_IMM`** | **`IR_GPU_D2H`** |
| 144 | `IR_SHR_IMM` | `IR_GPU_D2D` |
| 145 | `IR_SAR_IMM` | `IR_KERNEL_LAUNCH` |
| 146 | `IR_MODULE_PATH` | `IR_GPU_SYNC` |
| 147 | `IR_LOAD_BIS` | `IR_GPU_BARRIER` |
| **148** | **`IR_STORE_BIS`** | **`IR_SHL_IMM`** |
| 149 | — | `IR_LOAD_BIS` |
| 150 | — | `IR_STORE_BIS` |

**A numeric opcode literal copied between the two repos is a miscompile.**
`ir_opt_is_side_effect` is the clearest illustration: KernRift lists
`op == 148` (`STORE_BIS`), MLRift lists `op == 150` — same intent, different
number, and swapping them would mark `IR_SHL_IMM` side-effectful in one and
leave a store DCE-eligible in the other.

The GPU opcodes cost more than they earned: **nothing in MLRift produces or
consumes them.** `src/ir_hip.mlr` declares eight constants and contains no
`fn` at all; the three real GPU emitters (`format_hip.mlr`,
`format_amdgpu.mlr`, `format_amdgpu_megakernel.mlr`) walk the **AST**, not
the IR. So the entire numbering divergence exists to reserve space for
opcodes that were never emitted.

### Opcodes present in only one dialect

- **KernRift only**: `IR_AND_IMM`/`IR_OR_IMM`/`IR_XOR_IMM`/`IR_SHR_IMM`/
  `IR_SAR_IMM` (the riscv32 immediate-fused logicals — a riscv32-specific
  family MLRift never needed, since its const-folder has no riscv fusion at
  all) and `IR_MODULE_PATH`.
- **MLRift only**: the eight GPU host ops in `src/ir_hip.mlr`.

### Real capability differences, in both directions

| | KernRift | MLRift |
|---|---|---|
| `--target=none` / bare metal | **yes** — 39 `target_os == 4` sites, four trap choke points, the `ir_bm_*` lowering layer (`src/ir.kr:1451`–`1538`) | **no** — zero `target_os == 4` sites anywhere. §12 does not apply |
| Dynamic linking from the IR | **no** — no PLT/GOT/`DT_NEEDED` path | **yes** — `dyn_sym_registry.mlr` + `format_elf_dyn.mlr`, called from inside the x86 IR emitter: `dyn_sym_lookup` decides whether an `IR_CALL` becomes a PLT call (`ir.mlr:9410`), `dyn_call_record` registers the relocation (`:9425`), `dyn_sym_count_get() > 0` switches the whole output to dynamic ELF (`:13115`) |
| arm64 `IR_ADD_IMM`/`IR_SUB_IMM` (135/136) | handled (`src/ir_aarch64.kr:1312`) and produced (const-fold gate includes arch 1, `src/ir.kr:12697`) | **neither** — the const-folder excludes arm64 (`ir.mlr:11683`), so the emitter has no handler. Internally consistent, but a genuine gap |
| cmp-with-immediate fusion | arch 0 **and** 1 (`src/ir.kr:12593`, arm64 capped at imm12 4095) | arch 0 only (`ir.mlr:11590`) |
| pow2 `MUL` → `SHL_IMM` | ungated, with a shamt guard for arch 2/3 | present, gated to arch 0/1 — *not* absent, contrary to an older project note |
| `--emit=lkm` | yes; the IR gate is `emit_mode != 3 && emit_mode != 7` | no; the gate is `emit_mode != 3` alone |
| `arch_os_pair_supported()` | yes (`src/main.kr:7471`) | **absent** — no arch × OS allow-list |
| `--target=amdgpu-native` | no | yes |
| var map | FNV-1a open-addressed 4096-slot hash (`src/ir.kr:978`) | linear scan (`ir.mlr:1013`) |
| per-BB instruction lists for colouring | flat lists via `ir_build_bb_lists` (`src/ir.kr:13311`) | a 65536-entry walk stack |
| CTZ | open-codes `ir_popcount64(iso - 1)` at each site | has `ir_ctz64` (`ir.mlr:5495`) — MLRift is ahead here |
| builtin-name dispatch | linear | (first char × name length) 128×32 prefilter (`ir_bi_filter_init`, `ir.mlr:916`) — MLRift is ahead |
| conditional cleanup DCE | yes — `ir_opt_rewrites` deltas gate all six (19 uses in `ir.kr`) | no — all six cleanup DCEs run unconditionally (0 uses). Compile-time only, no codegen difference |

The optimizer **pass list and order are identical** in both. The register
allocator is identical in both, including the wide colour files, the colour
ceilings, and Briggs + George. Both use **`--O0`** (two dashes). MLRift's
copy of this document says `-O0`; that is wrong and is corrected there.

The living compiler (`living.kr` / `living.mlr`) **does not touch the IR in
either repo** — zero `ir_*` calls in both; it works on tokens and the AST.
KernRift is in fact slightly *ahead* there: MLRift's copy has not been
touched since the `.kr → .mlr` rename.

### Build seed

MLRift's `build/mlrc` is a **tracked** git seed. KernRift's `build/krc2` is
gitignored (`git ls-files build` returns nothing). Do not "fix" either to
match the other.

### GPU and SIMD

**Neither repo has IR-level SIMD.** There is no `IR_VEC_*`/`IR_SIMD_*`
opcode and no VEX/AVX2 encoder in either. CPU-side vector work in both goes
through inline asm (op 96) — which is exactly why `ir_x86_fn_wide_ok` /
`ir_a64_fn_wide_ok` must disqualify any function containing op 96 (§11).

MLRift's GPU work lives in `docs/GPU_BACKEND.md` (self-labelled a historical
kickoff document; its proposed IR-op table describes a pipeline that was
never built) and its planned vector codegen in `docs/SIMD_CODEGEN.md`
(self-labelled design-approved, implementation not started). Neither has a
KernRift counterpart, and this document does not duplicate them.
