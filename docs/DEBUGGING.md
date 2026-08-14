# Debugging KernRift Programs

This is a practical guide for debugging KernRift programs — and for debugging
the compiler itself when you think it has wronged you. It is organized by
task: find the section that matches what's going wrong and follow the steps.
Every flag and behavior described here has been verified against the shipped
compiler (`krc 2.8.26`).

Quick map:

- **Program crashes or prints garbage** → [§1](#1-my-program-crashes-or-misbehaves)
- **Compiler output looks wrong (miscompile suspicion)** → [§2](#2-i-think-the-compiler-miscompiled-my-code)
- **Want to see what the compiler generated** → [§3](#3-inspecting-compiler-output)
- **Want to catch bugs before running** → [§4](#4-static-checks-before-running)
- **Android / macOS specific issues** → [§5](#5-platform-debug-kits)

---

## 1. My program crashes or misbehaves

### Step 1: rebuild with `--debug`

`--debug` turns on runtime safety checks. A program that silently corrupts
memory in release mode will often die immediately — with `exit(1)` — at the
exact bad operation:

```sh
krc --arch=x86_64 --debug program.kr -o program
./program ; echo "exit=$?"
```

A minimal program that traps under `--debug`:

```kr
fn main() {
    u64[4] buf
    let i = 5
    buf[i] = 42        // out of bounds — traps here
    println(buf[0])
    exit(0)
}
```

Release build: runs to completion, prints `0`, exits 0 — the out-of-bounds
store silently lands somewhere on the stack. With `--debug`: the process
exits with code **1** before the store, on **all four** backend/arch
configurations — the IR backend on x86_64 and arm64, and the legacy backend
on x86_64 and arm64. The trap is silent (no message); a non-zero exit at an
unexpected point is the signal.

Until this landed, the legacy arm64 backend had no bounds-check codegen at
all, and rather than ship a build that silently had no checks, `--debug`
was **refused outright** on every command line reaching it. That refusal is
gone. `codegen_aarch64.kr` now emits the check at the same two subscript
sites the legacy x86_64 backend uses — the rvalue read and the indexed
assignment — from the same `arr_count_lookup`, with the same unsigned
comparison and the same silent `exit(1)`.

Because the check lives in the codegen rather than in a front-end
predicate, every route into that backend carries it: `--legacy`,
`--emit=obj` and `--emit=lkm` (which select legacy codegen on arm64 even
with no `--legacy` on the line, for extern relocations), `--emit=android`,
and a fat build carrying an arm64 slice — including plain `krc prog.kr
--legacy --debug` with no `--arch` at all. That last one was the likeliest
way a real user met the old refusal without ever typing `arm64`.

What the check does and does not cover, on every backend:

- Both the read (`v = a[i]`) and the store (`a[i] = v`) are checked; they
  are separate sites in each backend.
- The index is compared **unsigned**, so a negative-looking index produced
  by signed math becomes a huge positive and fails the check.
- A **constant** out-of-range index is caught at **runtime** by this same
  check, not at compile time — nothing folds it away first.
- Arrays whose element count is not known at compile time (a raw pointer,
  or a `T[N]` the front end could not resolve) are **not** checked, on any
  backend. Bounds checking here means compile-time-sized arrays only.
- Arrays **of structs** are not checked either, on any of the four
  configurations — measured: `P[4] arr; arr[99].x` runs to completion on
  all four. A struct element is reached through a separate multiply-by-
  stride path in each backend, and no backend instruments it. This is a
  pre-existing uniform gap, not an arm64 one, and it is why the arm64
  legacy check was added at exactly the two sites the x86_64 legacy one
  occupies and no others: adding it to a third site on one backend only
  would have created a divergence where there is currently parity.

### What `--debug` checks, per backend

The two backends instrument different things. This table is derived from
`docs/UNDEFINED_BEHAVIOR.md` and verified by running trap programs on each
backend:

| Check | IR backend (default) | `--legacy` backend, x86_64 | `--legacy` backend, arm64 |
|---|---|---|---|
| Array bounds (compile-time-sized stack/static arrays) | **Traps**, `exit(1)` — x86_64 and arm64 | **Traps**, `exit(1)` | **Traps**, `exit(1)` |
| Integer divide / modulo by zero | arm64: **traps**, `exit(1)`. x86_64: **no check** — hardware SIGFPE (shell reports exit 136) | **Traps**, `exit(1)` | **Traps**, `exit(1)` |
| Signed `i64`/`i32`… add/sub overflow | No check — wraps | **Traps**, `exit(1)` | **Traps**, `exit(1)` |
| Null pointer in `loadN`/`storeN` builtins | No check — SIGSEGV (exit 139) | **Traps**, `exit(1)` | **Traps**, `exit(1)` |
| Unsigned overflow | No check (defined behavior — wraps) | No check (wraps; the guard tests the *signed* overflow flag only) | No check (wraps; same signed-only guard) |

#### What the arm64 legacy check compiles to

Five instructions, of which three are on the in-range path. For
`uint64[4] a` indexed by a value in `x0`:

```
mov  x11, #4          // the declared element count
cmp  x0, x11          // SUBS XZR, X0, X11 — unsigned
b.lo <after>          // in range (0..3): skip the trap
mov  x0, #1           // exit code 1
mov  x8, #93          // Linux __NR_exit; x16 / #1 on macOS
svc  #0               // Windows: BLR through the IAT to ExitProcess
<after>:
```

`B.LO` (carry clear) is the exact counterpart of x86's `jb`: it admits
`0..count-1` and nothing else. `B.LS` would admit `count` itself, which is
why the suite tests `index == count` separately from `index = 99` — the
two failures look identical from a program that only ever indexes far out
of range.

The count goes through a full 64-bit `MOV` rather than a compare-immediate.
arm64's `CMP` immediate form is 12 bits, and x86's `cmp rax, imm32`
sign-extends, so neither can express a count at or above 2³¹ — the two
backends agree over the whole range `arr_count_lookup` can actually return
(it reserves `0xFFFFFFFF` for "not known at compile time", which suppresses
the check entirely).

#### History: this was once a refusal

`codegen_aarch64.kr` never had bounds-check codegen, so `--debug` on legacy
arm64 compiled clean and read past the array — measured, `uint64[4] a;
a[99]` exited 0 there while the other three configurations exited 1.
Rather than ship a safety promise unmet with no diagnostic, the compiler
**refused** `--debug` on every command line that reached that backend.

That refusal had to be **derived from the codegen dispatch**, not
enumerated from flag spellings, and getting that wrong once is instructive.
Its first version refused the combination `--legacy --arch=arm64 --debug`
and missed `--arch=arm64 --emit=obj --debug`, which reaches the identical
codegen with `--legacy` nowhere on the line, because a relocatable object
always uses legacy codegen so extern relocations resolve. The fat-build
path — whose four arm64 slices choose legacy on `--legacy` alone, with no
`--arch` anywhere — was a third family again.

It also cost something real. `codegen_aarch64.kr`'s overflow,
divide-by-zero and null-pointer guards always worked; the checks are
all-or-nothing per backend build, so refusing the command line disabled
those three as well. A `--debug` build that used only the working checks
lost them.

Both of those problems are gone rather than solved. The check now lives in
the codegen next to the guards it sits beside in the table above, so every
route into that backend — present or added later — carries it by
construction, and nothing turns the other guards off.

Practical consequence: if `--debug` on the default backend doesn't catch
anything, try `--legacy --debug` — it guards more operations, and now does
so on both arches:

```sh
krc --arch=x86_64 --legacy --debug program.kr -o program
krc --arch=arm64  --legacy --debug program.kr -o program
```

All traps exit with code 1. Distinguish them from hardware faults by exit
code: **1** = a `--debug` guard fired, **139** = SIGSEGV, **136** = SIGFPE.

### Step 2: debug with gdb and `-g`

`-g` emits DWARF v5 debug info into the binary:

```sh
krc --arch=x86_64 -g program.kr -o program
readelf -S program | grep debug
```

```
  [ 2] .debug_line       PROGBITS  ...
  [ 3] .debug_abbrev     PROGBITS  ...
  [ 4] .debug_str        PROGBITS  ...
  [ 5] .debug_info       PROGBITS  ...
```

Four sections are emitted: `.debug_line`, `.debug_abbrev`, `.debug_str`, and
`.debug_info`. The `.debug_info` CU contains base-type DIEs for all the
primitive types, a `DW_TAG_subprogram` per function (with `decl_file` /
`decl_line` / `low_pc` / `high_pc`), and `DW_TAG_variable` /
`DW_TAG_formal_parameter` entries for locals and params.

A real session:

```
$ gdb ./program
(gdb) break main
Breakpoint 1 at 0x40008a
(gdb) run
Breakpoint 1, 0x000000000040008a in main ()
(gdb) info locals
x = 6
y = 6
(gdb) stepi          # instruction-level stepping
(gdb) x/8i $pc       # disassemble around the current point
(gdb) continue
```

**What works:** breakpoints by function name (`break main`,
`break square`), `info locals` and `print x` for named locals and
parameters, `info functions`, and instruction-level stepping
(`stepi` / `nexti`).

**Known limitations (verified against gdb 15.1):**

- **Source-line operations do not work yet.** The `.debug_line` table is
  emitted and `readelf --debug-dump=rawline` decodes it, but gdb reports
  "no line number information" — so `break file.kr:12`, `next`, `step`,
  and `list` fall back to function/instruction granularity. Use `stepi`
  and `x/i $pc` instead, and map addresses back to source with
  `--emit=asm` ([§3](#3-inspecting-compiler-output)).
- **Backtraces stop after the innermost frame.** No `.eh_frame` /
  `.debug_frame` CFI is emitted, so `bt` reliably names the faulting
  function but the caller chain beyond it shows `?? ()`.
- Locals are visible but a value read before its assignment executes is
  whatever was in the slot (frame slots are not cleared).

### Reading a segfault

```
$ ./program
Segmentation fault (core dumped)    # shell exit code 139
```

Run it under gdb to find the faulting function:

```
$ gdb --batch -ex run -ex bt ./program
Program received signal SIGSEGV, Segmentation fault.
0x000000000040008b in poke ()
#0  0x000000000040008b in poke ()
```

The usual suspects, in order of likelihood:

1. **Null or garbage pointer** in a `loadN`/`storeN` — rebuild with
   `--legacy --debug` (either arch — see §1's `--debug` table) to turn null
   dereferences into a clean `exit(1)` at the exact call.
2. **Out-of-bounds array index** that walked off the stack — `--debug`
   bounds checks catch this on all four backend/arch configurations.
3. **Use-after-`dealloc`** or stack overflow from deep recursion — see
   `docs/UNDEFINED_BEHAVIOR.md` for what is and isn't defined.

Exit 136 (SIGFPE) on x86_64 almost always means divide/modulo by zero —
ARM64 hardware never traps on division (it yields 0), which is itself a
portability hazard; see the UB table.

---

## 2. I think the compiler miscompiled my code

Suspected miscompiles are real — KernRift is self-hosted and its optimizer
and register allocator have had bugs before. The good news: the compiler has
**two independent backends** and several switchable passes, so you can
bisect the failure to a component in minutes.

### The bisection ladder

Run your program after each step. The first flag that changes the behavior
points at the guilty component:

```sh
# 0. baseline (IR backend, optimizations + coalescing on)
krc --arch=x86_64 program.kr -o p0 && ./p0

# 1. disable IR optimizations (constant folding, DCE, CSE, LICM)
krc --arch=x86_64 --O0 program.kr -o p1 && ./p1

# 2. disable register copy coalescing (Briggs/George)
krc --arch=x86_64 --no-coalesce program.kr -o p2 && ./p2

# 3. switch to the legacy backend entirely
krc --arch=x86_64 --legacy program.kr -o p3 && ./p3
```

Note the spelling: it is `--O0` (two dashes), not `-O0`.

| Behavior changes at… | Suspect |
|---|---|
| `--O0` | An IR optimizer pass (CF/DCE/CSE/LICM) deleted or folded something it shouldn't have |
| `--no-coalesce` | The copy coalescer merged two vregs that interfere |
| `--legacy` | IR lowering or the IR emitter for your arch (`src/ir.kr` / `src/ir_aarch64.kr`) |
| none of the above | Probably not a miscompile — recheck your program against `docs/UNDEFINED_BEHAVIOR.md` (uninitialized stack reads and shift-by-≥-width are the classic false accusations) |

### `--legacy` as a correctness oracle

The IR backend (default) and the legacy direct-codegen backend
(`--legacy`) are two independent implementations of the same language. They
share the parser and nothing else that matters. **If the same program
behaves differently under the two backends, one of them has a bug** — that
is always reportable, even if you can't tell which side is wrong.

```sh
krc --arch=x86_64 program.kr -o p_ir   && ./p_ir   > ir.out;  echo "ir=$?"
krc --arch=x86_64 --legacy program.kr -o p_leg && ./p_leg > leg.out; echo "leg=$?"
diff ir.out leg.out
```

(Caveat: under `--debug` the backends intentionally differ — see the trap
table in §1. Compare release builds.)

### Minimizing a repro

Before filing, shrink the program:

1. Replace I/O and imports with constants; keep `exit(N)` as the observable
   (exit codes survive minimization better than stdout).
2. Delete functions/branches one at a time, re-checking that the
   IR-vs-legacy (or `--O0`-vs-default) divergence persists.
3. Aim for a single `fn main()` of under ~15 lines — most historical
   codegen bugs reduce to that size (see `examples/codegen_*.kr` for past
   repros kept as regression tests).

### The differential harnesses

Two scripts in `tests/` do this comparison systematically, and are the
template for turning your repro into a permanent test:

- **`tests/diff_ir_legacy.sh`** — compiles and runs ~60 small programs
  through all four backends (IR and legacy × x86_64 and arm64; arm64 runs
  under `qemu-aarch64-static` when installed, otherwise those columns are
  skipped) and compares **exit codes** against the IR-x86_64 baseline. Any
  disagreement prints a `DIVERGE` line with all four results; the run ends
  with `PARITY OK` or `PARITY GAPS FOUND`.
- **`tests/diff_ir_legacy_stdout.sh`** — same four-backend matrix, but
  compares **full stdout**. It targets the paths most likely to diverge
  subtly: integer/float printing, `fmt_f64`, signed-negative div/mod,
  struct return-by-value, nested structs, f-strings, `match` expressions.

Both honor `KRC=path/to/krc` from the environment:

```sh
KRC=./build/krc2 bash tests/diff_ir_legacy.sh
KRC=./build/krc2 bash tests/diff_ir_legacy_stdout.sh
```

If you found a divergence, add a `diff_case`/`dc` line with your minimized
program — that's the preferred form for a parity bug report.

---

## 3. Inspecting compiler output

### `--emit=ir` — dump the IR (not SSA)

Prints the IR for every function to **stdout** (any `-o` is ignored):

```sh
krc --arch=x86_64 --emit=ir program.kr
```

```
function square:
  bb0:
    v1 = copy param[0]
    v2 = mul v1, v1
    v0 = ret v2

function main:
  bb0:
    v1 = const 6
    v2 = copy v1
    arg v2 [0]
    v3 = call @26
    ...
```

How to read it: `vN` are virtual registers (`v0` means "no value"; the IR
is not SSA — named variables reuse one vreg across assignments, so no phi
is ever needed and none is built);
`bbN` are basic blocks; `arg vX [i]` loads vX into argument slot *i* for the
next `call`/`syscall`. Every opcode — all 93 of them — is documented in
[`docs/IR_REFERENCE.md`](IR_REFERENCE.md), including which ops the
optimizer considers pure (eligible for DCE/CSE) and which carry
side-effects. When chasing an optimizer bug, dump the IR with and without
`--O0` and diff the two.

### `--emit=asm` — annotated assembly listing

Writes a listing to the `-o` path (default backend's machine code, with
raw bytes and decoded mnemonics):

```sh
krc --arch=x86_64 --emit=asm program.kr -o program.s
```

```
square:
  00000000: 53                 push rbx
  00000001: 48 89 fb  mov rbx, rdi
  00000004: 48 0f af db  imul rbx, rbx
  00000008: 48 89 d8  mov rax, rbx
  ...
```

This is what `gdb`'s `stepi` is walking through, so it doubles as the
source map while line-level DWARF is still limited (§1). What to look for:

- A function that's suspiciously short — a pass may have deleted a
  side-effecting op (compare against `--O0`).
- Two values living in the same register where you expected both alive —
  compare against `--no-coalesce`.
- Unsigned condition codes (`jb`/`jae`, `cc lo/hs`) where the operands are
  signed types (`jl`/`jge`, `cc lt/ge` expected) — a known historical bug
  class on the legacy arm64 path.

---

## 4. Static checks before running

### The type checker (on by default)

Every compile runs the type checker. It catches struct/float/void misuse —
unknown fields, arithmetic or comparison on struct values, struct-kind
mismatches in assignment/calls/returns, f32-vs-f64 return mixups, void
results used as values, non-bool conditions:

```
program.kr:5:17: error: arithmetic operator on struct value
     5 |     u64 bad = p + 1
       |                 ^
```

It is intentionally not a full Hindley-Milner system — plain integer-width
mismatches and int↔float argument coercions pass silently. `--no-check-types`
bypasses it entirely (the program compiles anyway); use that only when the
checker itself is the thing you're debugging, and re-enable with
`--check-types` (the default).

### `krc check` — safety analysis pre-flight

```sh
krc check program.kr
krc check: program.kr - OK
```

**A clean `krc check` is a much weaker statement than it looks.** The
context (`@ctx`), effect (`@eff`), capability (`@caps`) and lock-cycle passes
all run, but the annotations that drive them are parsed and then discarded —
nothing populates the annotation table or the lock graph — so **none of those
four can report anything, on any input**. The only analysis in `check` that
can produce a finding is the critical-region pass (`alloc` between a bare
`acquire()` and `release()`), and that one misses `u64 b = alloc(8)` and
anything nested inside an `if` or a loop. See
[EFFECT_SYSTEM.md](EFFECT_SYSTEM.md) for the measured details.

So: a clean `check` does **not** mean "the context/effect/capability contracts
hold" — it mostly means the file parsed. It is a complement to the type
checker, not a superset, and certainly not a safety guarantee.

`--ci` (gate on a fitness threshold, exit 1 below it) and `--fix` (run the
migration engine) are **`krc lc` flags, not `krc check` flags**. Both are
accepted on a `krc check` command line and then ignored — `krc check --ci`
and `krc check --fix` behave exactly like a bare `krc check`, and both exit 0.
Use `krc lc --ci program.kr` if you want the gating behaviour.

A sensible pre-flight before a long debug session:

```sh
krc check program.kr && krc --arch=x86_64 --debug program.kr -o program && ./program
```

---

## 5. Platform debug kits

- **Android (ARM64, via adb):**
  [`docs/android-debug-kit.md`](android-debug-kit.md) — a complete recipe
  for reproducing on-device what qemu-aarch64 can't (fixed-VA `MAP_FIXED`
  mappings, real-silicon behavior), working entirely from
  `/data/local/tmp` with no root.
- **macOS (Apple Silicon):** `docs/macos-debug-kit.sh` — a script to run on
  an ARM64 Mac that collects system info and builds minimal test binaries.
  Note: as of this writing the script is **untracked** in the repository
  (it sits in `docs/` but isn't committed), so treat its contents as
  unstable and consider committing it alongside this guide.

For arm64 work on an x86_64 host, install `qemu-aarch64-static` — the
differential harnesses (§2) and any `krc --arch=arm64` output run under it
directly.

---

## Quick reference: the debug flag set

| Flag | Effect |
|---|---|
| `-g` | DWARF v5 debug info (`.debug_line/.debug_abbrev/.debug_str/.debug_info`) |
| `--debug` | Runtime traps — bounds on both backends; div-zero/overflow/null on legacy (see §1 table) |
| `--O0` | Disable IR optimizations (CF/DCE/CSE/LICM) |
| `--coalesce` / `--no-coalesce` | Enable (default) / disable copy coalescing |
| `--ir` / `--legacy` | IR backend (default) / legacy backend — the correctness oracle |
| `--emit=ir` | Dump IR per function to stdout (not SSA) |
| `--emit=asm` | Annotated assembly listing to `-o` |
| `--check-types` / `--no-check-types` | Type checker on (default) / off |
| `krc check FILE.kr [--ci] [--fix]` | Static safety analysis |
