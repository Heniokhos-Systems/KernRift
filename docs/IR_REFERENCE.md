# IR Opcode Reference

KernRift's intermediate representation is a flat SSA form produced by
`src/ir.kr` (AST → IR lowering) and consumed by `src/ir.kr` (x86_64 emitter)
and `src/ir_aarch64.kr` (AArch64 emitter). Each instruction is a 32-byte
record with fields `{opcode, dest, src1, src2, imm, bb}`. Virtual
registers (vregs) are numbered from 1; vreg 0 is reserved for "no value"
(void returns, stores). Basic blocks are numbered from 0.

This reference documents the IR opcodes (107 as of v2.8.26; the canonical
list is the `static uint64 IR_*` definitions at the top of `src/ir.kr`),
so that:
- The IR lowering can be validated (does `ast_lower_*` preserve semantics?).
- Optimizer soundness can be reasoned about per pass (what does DCE assume?).
- Backend ports can check for coverage (every opcode must be emittable).

Opcodes are grouped by category; the numeric values in the table below
match the constants defined in `src/ir.kr`.

## Conventions used in this document

- **dest** — destination vreg. `0` means no destination (the instruction
  is purely for its side effect).
- **src1**, **src2** — source vregs. `0` means "not used". Register
  allocator preserves src vregs up to the instruction; the destination is
  live after.
- **imm** — 64-bit immediate. Interpretation depends on opcode.
- **bb** — the basic block this instruction belongs to.
- **fkind** — each vreg has a float-kind tag (`0` = integer, `1` = f64,
  `2` = f32). The emitter uses this to pick integer vs SIMD register
  classes.
- **side effect** — if "yes", DCE must keep this instruction even when
  its dest is dead. See `ir_opt_is_side_effect()` in src/ir.kr.
- **trap** — whether the opcode can trap at runtime.

## Arithmetic (1–13)

| # | Opcode | Semantics | Side effect | Trap |
|---|--------|-----------|-------------|------|
| 1 | `IR_CONST` | `dest = imm` (64-bit constant) | no | no |
| 2 | `IR_ADD` | `dest = src1 + src2` (wrapping) | no | no |
| 3 | `IR_SUB` | `dest = src1 - src2` (wrapping) | no | no |
| 4 | `IR_MUL` | `dest = src1 * src2` (wrapping) | no | no |
| 5 | `IR_DIV` | `dest = src1 / src2` (unsigned, truncating) | no | yes on x86 if src2==0; silent 0 on ARM64 (unless `--debug`) |
| 6 | `IR_MOD` | `dest = src1 % src2` (unsigned) | no | same as IR_DIV |
| 7 | `IR_AND` | `dest = src1 & src2` | no | no |
| 8 | `IR_OR`  | `dest = src1 \| src2` | no | no |
| 9 | `IR_XOR` | `dest = src1 ^ src2` | no | no |
| 10 | `IR_SHL` | `dest = src1 << (src2 & 63)` | no | no |
| 11 | `IR_SHR` | `dest = src1 >> (src2 & 63)` (logical) | no | no |
| 12 | `IR_NEG` | `dest = -src1` (two's complement) | no | no |
| 13 | `IR_NOT` | `dest = ~src1` | no | no |

Notes:
- Integer arithmetic wraps on overflow (two's-complement wrap-around),
  like C's unsigned integers. There are no signed-overflow-is-UB
  semantics.
- Shift counts are masked to `& 63` by the hardware (both x86 and ARM64).
  This is the defined behaviour, not implementation-defined.

## Unsigned compare (14–19)

All return `1` for true, `0` for false. The result type is `u64`; there
is no separate `bool` at the IR level.

| # | Opcode | Semantics |
|---|--------|-----------|
| 14 | `IR_CMP_EQ` | `dest = (src1 == src2) ? 1 : 0` |
| 15 | `IR_CMP_NE` | `dest = (src1 != src2) ? 1 : 0` |
| 16 | `IR_CMP_LT` | unsigned less-than |
| 17 | `IR_CMP_LE` | unsigned less-or-equal |
| 18 | `IR_CMP_GT` | unsigned greater-than |
| 19 | `IR_CMP_GE` | unsigned greater-or-equal |

## Float arithmetic (20–27, 97–108)

| # | Opcode | Semantics |
|---|--------|-----------|
| 20 | `IR_FADD` | `dest = src1 + src2` (IEEE 754) |
| 21 | `IR_FSUB` | `dest = src1 - src2` |
| 22 | `IR_FMUL` | `dest = src1 * src2` |
| 23 | `IR_FDIV` | `dest = src1 / src2` (returns ±Inf on div by 0.0, NaN on 0/0) |
| 24 | `IR_FCMP_EQ` | ordered equal (returns 0 if either is NaN) |
| 25 | `IR_FCMP_LT` | ordered less-than |
| 26 | `IR_ITOF` | int64 → f64 (signed; truncates for magnitudes > 2^53) |
| 27 | `IR_FTOI` | f64 → int64 (truncating, saturates on overflow) |
| 97 | `IR_FSQRT` | f64 square root (hardware `sqrtsd` / `fsqrt`) |
| 98 | `IR_FFMA` | `dest = src1 * src2 + imm_vreg` fused-multiply-add f64 |
| 99–102 | `IR_FCMP_NE/LE/GT/GE` | ordered float compares |
| 103 | `IR_F32TOF64` | f32 bits → f64 |
| 104 | `IR_F64TOF32` | f64 → f32 (IEEE round-to-nearest-even) |
| 105 | `IR_F32TOF16` | f32 → f16 bit pattern (x86 only) |
| 106 | `IR_F16TOF32` | f16 bit pattern → f32 (x86 only) |
| 107 | `IR_ITOF32` | int64 → f32 |
| 108 | `IR_FTOI32` | f32 → int64 |
| 118 | `IR_FSQRT32` | f32 square root |

The fkind of each vreg determines register class selection:
`fkind=1` → xmm/d on x86/ARM64, `fkind=2` → xmm/s, `fkind=0` → GPR.

## Memory (30–32, 70–78, 84, 88, 94–95)

| # | Opcode | Semantics | Side effect |
|---|--------|-----------|-------------|
| 30 | `IR_LOAD` | `dest = *(src1 as width)` zero-extended to u64. Width in `imm` (1/2/4/8). | no (no address-exposed alias analysis yet) |
| 31 | `IR_STORE` | `*(src1 as width) = src2`. Width in `imm`. | **yes** |
| 32 | `IR_STACK_ADDR` | `dest = sp + imm` (address of stack slot) | no |
| 70 | `IR_ALLOC` | `dest = alloc(src1_or_imm)` — mmap/VirtualAlloc | **yes** |
| 71 | `IR_DEALLOC` | `dealloc(src1)` — munmap/VirtualFree | **yes** |
| 72 | `IR_MEMCPY` | `memcpy(src1=dst, src2=src, imm=len_vreg)` | **yes** |
| 73 | `IR_STRLEN` | `dest = strlen(src1)` | no |
| 74 | `IR_FMT_UINT` | `dest = fmt_uint(src1=buf, src2=val)` → written length | **yes** |
| 75 | `IR_STR_EQ` | `dest = (strcmp(src1, src2) == 0) ? 1 : 0` | no |
| 76 | `IR_MEMSET` | `memset(src1=dst, src2=val, imm=len_vreg)` | **yes** |
| 77 | `IR_STATIC_LOAD` | `dest = static_data[imm]` | no |
| 78 | `IR_STATIC_STORE` | `static_data[imm] = src1` | **yes** |
| 84 | `IR_STATIC_ADDR` | `dest = &static_data[imm]` (LEA-style) | no |
| 88 | `IR_MEMCMP` | `dest = (memcmp(src1, src2, imm) == 0) ? 1 : 0` | no |
| 94 | `IR_VSTORE` | `*(src1 as width) = src2` with memory barrier (volatile) | **yes** |
| 95 | `IR_VLOAD` | `dest = *(src1 as width)` with memory barrier (volatile) | **yes** (can observe external writes) |

Load zero-extension rule: a `load8` of a 0xFF byte yields `u64(0xFF)`,
never `u64(-1)`. Stores truncate.

## Control flow (40–43, 50–52)

| # | Opcode | Semantics |
|---|--------|-----------|
| 40 | `IR_BR` | unconditional jump to basic block `imm` |
| 41 | `IR_BR_COND` | if `src1 != 0` jump to `imm`, else fall through |
| 42 | `IR_RET` | return `src1` (in rax/x0) |
| 43 | `IR_RET_VOID` | return with no value |
| 50 | `IR_CALL` | call function named by `imm` (tok index); dest = rax/x0 |
| 51 | `IR_ARG` | pass `src1` as argument position `imm` before a CALL |
| 52 | `IR_SYSCALL` | perform syscall; `imm` is the internal syscall kind (1=write, 2=open, 3=read, 4=close, 5=mmap, …) |

`IR_BR_COND` treats `src1 != 0` as true (same rule as `if` / `while` in
surface syntax). The branch target uses the basic block number; the
emitter resolves that to a code offset at the end of function lowering.

`IR_CALL` implies side effect. `IR_ARG` lives between the value
computation and the call to pin arguments to parameter registers.

## SSA bookkeeping (60, 61)

| # | Opcode | Semantics |
|---|--------|-----------|
| 60 | `IR_PHI` | phi node (dead after SSA destruction; emitted as COPY) |
| 61 | `IR_COPY` | `dest = src1` (used at merge points to materialise phi operands) |

SSA is destructed before regalloc: every `IR_PHI` is lowered into a set
of `IR_COPY` on incoming edges. The regalloc pass sees only COPY.

## Multi-return tuples (80–83)

| # | Opcode | Semantics |
|---|--------|-----------|
| 80 | `IR_EXTRACT_RDX` | `dest = rdx / x1` after a CALL (second tuple value) |
| 81 | `IR_EXTRACT_R8`  | `dest = r8 / x2` (third tuple value) |
| 82 | `IR_RET2` | return `(src1, src2)` — placed in rax, rdx / x0, x1 |
| 83 | `IR_RET3` | return `(src1, src2, imm_vreg)` |

EXTRACT instructions must immediately follow the CALL they extract from
and are marked side-effectful so DCE doesn't move them.

## Strings (75, 79)

| # | Opcode | Semantics |
|---|--------|-----------|
| 75 | `IR_STR_EQ` | `dest = strcmp(src1, src2) == 0 ? 1 : 0` |
| 79 | `IR_STR_CONST` | `dest = &str_buf[imm]` — LEA the string at the given byte offset |

## Raw primitives (85–87)

| # | Opcode | Semantics |
|---|--------|-----------|
| 85 | `IR_SYSCALL_RAW` | `dest = syscall(src1=nr_vreg, args already staged via IR_ARG)` |
| 86 | `IR_FN_ADDR` | `dest = &fn[imm_tok]` — used by `fn_addr(name)` |
| 87 | `IR_CALL_IND` | `dest = (*src1)()` — indirect call through vreg |

## Atomics (90–93, 109–112)

All atomics on x86_64 use `lock`-prefixed RMW instructions; on ARM64
they use LDAXR/STLXR retry loops. Ordering is sequentially consistent.

| # | Opcode | Semantics | Returns |
|---|--------|-----------|---------|
| 90 | `IR_ATOMIC_STORE` | `*src1 = src2` with release | nothing |
| 91 | `IR_ATOMIC_LOAD` | `dest = *src1` with acquire | loaded value |
| 92 | `IR_ATOMIC_ADD` | `*src1 += src2` | **old** value (matches x86 xadd) |
| 93 | `IR_ATOMIC_CAS` | CAS `*src1: exp=src2 → imm_vreg` | 1 on success, 0 on mismatch |
| 109 | `IR_ATOMIC_SUB` | `*src1 -= src2` | old value |
| 110 | `IR_ATOMIC_AND` | `*src1 &= src2` | old value |
| 111 | `IR_ATOMIC_OR`  | `*src1 \|= src2` | old value |
| 112 | `IR_ATOMIC_XOR` | `*src1 ^= src2` | old value |

v2.8.8 fixed ARM64 bugs where `atomic_cas` always reported success and
`atomic_{add,sub,and,or,xor}` returned the new value instead of old.

## Volatile (94–95)

| # | Opcode | Semantics |
|---|--------|-----------|
| 94 | `IR_VSTORE` | `*(src1 as width) = src2`. Emits `mfence` on x86, `DSB SY` on ARM64 afterwards. |
| 95 | `IR_VLOAD` | `dest = *(src1 as width)`. Emits the fence beforehand. |

Intended for MMIO. Note that `DSB SY` on ARM64 is a data-sync barrier
only — it does NOT flush the instruction cache. If you're writing code
to RAM and then calling it, issue `ISB` explicitly via inline asm or
(post-v2.8.14) the `isb()` builtin.

## Inline assembly (96)

| # | Opcode | Semantics |
|---|--------|-----------|
| 96 | `IR_ASM_BLOCK` | passthrough of raw bytes / assembled instruction strings; `imm` is the AST node index |

`IR_ASM_BLOCK` is opaque to the IR — it cannot be reordered across
other side-effectful ops, and its register inputs / outputs are
declared by the asm `in(…) out(…) clobbers(…)` clauses at parse time.

## Signed compare (120–123)

Results are `0` / `1`. Used whenever the surface syntax calls
`signed_lt`, `signed_gt`, `signed_le`, `signed_ge`.

| # | Opcode | Semantics |
|---|--------|-----------|
| 120 | `IR_SCMP_LT` | signed less-than |
| 121 | `IR_SCMP_LE` | signed less-or-equal |
| 122 | `IR_SCMP_GT` | signed greater-than |
| 123 | `IR_SCMP_GE` | signed greater-or-equal |

Bare `<`, `<=`, `>`, `>=` at the surface are type-directed: they lower
to the **unsigned** compare opcodes (14–19) when the operands are
unsigned, and to the signed variants (120–123) when an operand's vreg
carries the signed flag (declared `i8`..`i64`; see `ir_vreg_signed_buf`
in `src/ir.kr`). The `signed_lt`/`signed_le`/`signed_gt`/`signed_ge`
builtins always lower to the signed opcodes.

## Typed formatting (124, 125)

| # | Opcode | Semantics |
|---|--------|-----------|
| 124 | `IR_FMT_BOOL` | write `"true"` / `"false"` into `src1=buf`; `dest` = length |
| 125 | `IR_FMT_F64`  | write `"[-]INT.FFFFFF"` into `src1=buf` from `src2=f64_vreg`; `dest` = length |

These back the typed `print` / `println` pipeline added in v2.8.3.

## Memory barriers & cache maintenance (126–130)

ARM64-meaningful; on x86 they lower to the nearest equivalent or a no-op.

| # | Opcode | Semantics |
|---|--------|-----------|
| 126 | `IR_ISB` | instruction-sync barrier (ARM64 `ISB`; x86 no-op) |
| 127 | `IR_DCACHE_FLUSH` | D-cache clean+invalidate by VA (ARM64 `DC CIVAC`; x86 `CLFLUSH`) |
| 128 | `IR_ICACHE_INV` | I-cache invalidate by VA (ARM64 `IC IVAU`; x86 no-op) |
| 129 | `IR_DSB` | data-sync barrier (ARM64 `DSB SY`; x86 `MFENCE`) |
| 130 | `IR_DMB` | data-memory barrier (ARM64 `DMB ISH`; x86 `MFENCE`) |

## Bounds check (131)

| # | Opcode | Semantics |
|---|--------|-----------|
| 131 | `IR_ARR_CHECK` | under `--debug`, trap (`exit(1)`) if `src1` (index) `>= imm` (element count); emitted for compile-time-sized array indexing |

## Signed & strength-reduced arithmetic (132–145)

| # | Opcode | Semantics |
|---|--------|-----------|
| 132 | `IR_SDIV` | `dest = src1 / src2` signed (`cqo`+`idiv` on x86, `sdiv` on a64) |
| 133 | `IR_SMOD` | `dest = src1 % src2` signed (`cqo`+`idiv` rdx on x86, `sdiv`+`msub` on a64) |
| 134 | `IR_SAR` | `dest = src1 >> src2` arithmetic (sign-extending) shift |
| 135 | `IR_ADD_IMM` | `dest = src1 + imm` (signed i32 immediate; fused on x86 and riscv32) |
| 136 | `IR_SUB_IMM` | `dest = src1 - imm` (fused on x86 and riscv32) |
| 137 | `IR_ROR` | rotate-right `src1` by `src2` |
| 138 | `IR_MUL_IMM` | `dest = src1 * imm` |
| 139 | `IR_LEA_BIS` | `dest = src1 + src2 * imm`, `imm ∈ {1,2,4,8}` (x86 `lea` base+index*scale) |
| 140 | `IR_AND_IMM` | `dest = src1 & imm` (riscv32-only fusion; imm fits sign-extended imm12) |
| 141 | `IR_OR_IMM` | `dest = src1 \| imm` (riscv32-only, imm12) |
| 142 | `IR_XOR_IMM` | `dest = src1 ^ imm` (riscv32-only, imm12) |
| 143 | `IR_SHL_IMM` | `dest = src1 << imm` (riscv32-only, shamt 0–31) |
| 144 | `IR_SHR_IMM` | `dest = src1 >> imm` logical (riscv32-only, shamt 0–31) |
| 145 | `IR_SAR_IMM` | `dest = src1 >> imm` arithmetic (riscv32-only, shamt 0–31) |

The signed compare opcodes are 120–123 (see above); bare `IR_DIV`/`IR_MOD`/
`IR_SHR` (5/6/11) are the unsigned forms. Like 135/136/138, opcodes 140–145
leave `src2` unused (0) and carry the constant in `imm`; they are produced
only by the const-fold fusion pass (arch-gated) and lower to RV32I I-type
`andi/ori/xori/slli/srli/srai` in `src/ir_riscv.kr`.

## Process / system (113–115, 119)

| # | Opcode | Semantics |
|---|--------|-----------|
| 113 | `IR_EXEC` | `execve(src1=path, argv={path, NULL}, envp=cli_envp)` |
| 114 | `IR_EXEC_ARGV` | `execve(src1=path, src2=argv, envp=cli_envp)` |
| 115 | `IR_SET_EXEC` | `chmod(src1=path, 0755)` |
| 119 | `IR_TIME_NS` | `dest = clock_gettime(CLOCK_MONOTONIC)` in nanoseconds |

## Side-effect set (who survives DCE)

DCE removes instructions whose `dest` is dead UNLESS the opcode is in
the side-effect set, defined in `ir_opt_is_side_effect()` (`src/ir.kr`):

```
STORE, BR, BR_COND, RET, RET_VOID, CALL, ARG, SYSCALL, ALLOC, DEALLOC,
MEMCPY, MEMSET, STATIC_STORE, EXTRACT_RDX, EXTRACT_R8, RET2, RET3,
SYSCALL_RAW, CALL_IND, atomics (90–96), exec/set_exec (109–115),
TIME_NS (119), VSTORE
```

## Optimizer passes

Each pass runs over the per-function IR arena in `ir_opt_run()` after
SSA construction and before register allocation. Order matters because
later passes benefit from earlier constant propagation.

| Pass | Function in `src/ir.kr` | What it does |
|------|------------------------|--------------|
| Constant fold | `ir_opt_const_fold()` | Rewrites pure-arithmetic ops with constant operands into `IR_CONST`. Triggered only on IR_ADD/SUB/MUL/DIV/MOD/AND/OR/XOR/SHL/SHR with both sources `IR_CONST`. |
| Common subexpression elim | `ir_opt_cse()` | Hashes each pure op by `{opcode, src1, src2, imm}` and collapses duplicates within a basic block. Skips side-effectful ops. |
| Dead code elim | `ir_opt_dce()` | Forward liveness: an op's dest is live if its uses are live. Two-phase mark (iteration-to-fixed-point). Side-effectful ops are always live. |
| Branch fold | inline in `ir_opt_run` | Converts `IR_BR_COND src=const` to `IR_BR` to the taken block. Subsequent DCE removes the untaken block. |
| Loop-invariant code motion | `ir_opt_licm` / `ir_licm_is_hoistable` | Hoists pure ops whose operands are all defined outside the loop into a pre-header (`src/ir.kr` ~3622). |

`--O0` disables `ir_opt_run()` entirely; IR goes straight from lowering
to regalloc.

## Register allocator

Graph-coloring (Chaitin-style). Steps in `ir_graph_color()`:

1. Build interference graph from per-op live-out sets.
2. Spill-candidate selection: degree > available-colors → push on
   stack with lowest spill-cost first.
3. Pop stack; assign the first available color not used by any
   already-colored neighbour.
4. Uncolorable vregs go to spill slots on the stack frame.

Color-to-physical-register map:
- **x86_64**: 5 colors → `rbx, r12, r13, r14, r15` (callee-saved only).
- **AArch64**: 10 colors → `x19..x28` (callee-saved).

Callee-saved registers are saved/restored in the prologue/epilogue;
caller-saved registers (rax, rcx, rdx, rsi, rdi, r8–r11 / x0–x18) are
used as scratch during ops like CALL, SYSCALL, atomic RMW.

**Copy coalescing** (on by default; `--no-coalesce` disables). Before
coloring, `vN = copy vM` pairs whose live ranges don't interfere are
merged so the redundant `mov` is never emitted. The Briggs test is the
conservative gate (refuse if ≥ K neighbours of the merged class would
have degree ≥ K); George is a less-conservative fallback at K ≥ 8. See
`ir_coalesce_enabled` / the coalescing loop in `src/ir.kr`.

Spill slot access uses `SP + slot*8` with a fallback to `MOV xN, imm ;
ADD xN, sp, xN ; LDR` when the offset exceeds the imm12-scaled limit
(32760 bytes on ARM64).

## Known miscompiles

- **R1** (resolved in 2026-04-19): the IR ARM64 `compile_fat`
  miscompile. All shipped `krc-*-arm64` binaries now use the IR
  backend by default.
- **R2** (resolved through v2.8.21–v2.8.24): the IR-vs-legacy size
  regression. Partial used-callee-save prologue + cross-register
  spill-reload peephole (v2.8.21), the AST-level inliner (v2.8.24),
  and Briggs/George copy coalescing (v2.8.24) closed the gap; the
  IR path is now strictly smaller than legacy on both architectures.

## Adding a new opcode — checklist

When introducing a new `IR_FOO`:

1. Pick an unused number, add `static uint64 IR_FOO = N` to `src/ir.kr`
   in the appropriate category range (arithmetic: 1–29, control: 40–43,
   memory: 30–32/70–78, atomics: 90–93/109–112, …).
2. Add the opcode-name string to `ir_opcode_name()` (used by
   `--emit=ir`).
3. Add the lowering path in `ir_lower_expr()` or `ir_lower_stmt()` —
   emit the new IR op from the AST node.
4. Add the emission branch in **both** `src/ir.kr` (x86_64) AND
   `src/ir_aarch64.kr` (AArch64). A missing backend will surface as an
   "unreachable opcode" assertion.
5. If the op has a side effect, add its number to
   `ir_opt_is_side_effect()` so DCE keeps it.
6. Add a test in `tests/run_tests.sh`.
7. Update this reference with the new row.
