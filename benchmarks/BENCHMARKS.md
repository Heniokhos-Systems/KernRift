# KernRift Benchmarks — v2.8.33

**Run date:** 2026-07-28
**Host:** AMD Ryzen 9 7900X, 64 GB DDR5, Linux 6.17 (x86_64)
**Compilers:** krc 2.8.33 (self-hosted), gcc 13.3.0, rustc 1.93.0

Reproduce with `KRC=build/krc2 bash benchmarks/run_benchmarks.sh`. Each
runtime is the median of three back-to-back runs after a warmup pass.

## Headline summary

Runtime in milliseconds (median of 3); lower is better. KernRift's
column reports the default `--ir` backend, now including the v2.8.33
x86_64 XMM register class and the widened integer colour files.

| Benchmark              | krc  | gcc -O0 | gcc -O2 | rustc -O2 |
|------------------------|-----:|--------:|--------:|----------:|
| fib(40) recursive      |  416 |     391 |      80 |       166 |
| sort 200k ints (qsort) |   59 |     153 |     272 |        45 |
| sieve primes ≤ 10⁶     |    3 |       4 |       2 |         2 |
| matmul 256³ (int)      |    6 |      16 |       4 |         3 |
| mandelbrot 1024² f64   |  539 |    1386 |     484 |       477 |
| sha-256 16 MiB         |  191 |     202 |      40 |        48 |

KernRift now beats `gcc -O0` on five of six, and the picture against
`gcc -O2` is no longer uniform:

- **sort is 4.6x faster than `gcc -O2`** (59 vs 272 ms). This is not an
  artefact of the input distribution -- it holds on a random fill too --
  gcc -O2 simply makes a poor choice for this loop shape.
- **mandelbrot is within 11%** (539 vs 484 ms), down from 3.9x behind in
  v2.8.25. The v2.8.33 XMM register class did that: f64 values now live in
  xmm2-xmm15 instead of round-tripping through general-purpose registers on
  every operation.
- **sieve and matmul are within 1.5x.**
- **sha-256 (4.8x) and fib (5.2x) remain the weak spots.** sha-256 still makes
  real calls to its `k_at` / `load_u32` helpers -- it wants a statement-level
  inliner -- and fib is bound by call structure, not register allocation.
  Neither is a vectorisation problem.

There is still no auto-vectorisation or SIMD intrinsics.

## Compile time + binary size

KernRift's single-pass codegen and direct ELF emission are by far the
fastest end-to-end pipeline of the three. Numbers are from the same run.

| Benchmark | krc compile | gcc -O2 | rustc -O2 | krc size | gcc -O2 size | rustc -O2 size |
|-----------|------------:|--------:|----------:|---------:|-------------:|---------------:|
| fib       |       2 ms |   37 ms |     72 ms |    296 B |     15 800 B |    3 887 792 B |
| sort      |       2 ms |   32 ms |     96 ms |    408 B |     15 960 B |    3 888 048 B |
| sieve     |       2 ms |   31 ms |     93 ms |    464 B |     16 008 B |    3 888 144 B |
| matmul    |       2 ms |   35 ms |     91 ms |    648 B |     15 960 B |    3 888 488 B |
| mandelbrot|       2 ms |   28 ms |     77 ms |    960 B |     15 976 B |    3 893 696 B |
| sha-256   |       3 ms |   45 ms |    111 ms |  4 672 B |     16 176 B |    3 897 872 B |

KernRift produces 830×-13 000× smaller binaries than `rustc -O2` (no
CRT, no debug info, no `panic=abort` strings, no allocator) and 3-53×
smaller than `gcc -O2`, depending on the program. That's not a tuning artifact — KernRift writes
the ELF header and machine bytes directly, with no linker step and no
startup trampoline.

## Detail per benchmark

### fib(40) — recursive

```
fn fib(uint64 n) -> uint64 {
    if n < 2 { return n }
    return fib(n-1) + fib(n-2)
}
```

Tight call-heavy stress test. KernRift's leaf-call overhead is two
push/pop pairs (rbx + r12 from the Briggs coalesced prologue); gcc -O2
tail-merges and unrolls down to a fraction of that. The 80 ms gcc -O2
number is an SSA-CCP / value-range analysis win that no cost-modeled
single-pass codegen will match.

### sort — quicksort, 200 000 ints

KernRift wins against `gcc -O2` here (59 ms vs 272 ms) — a 4.6× margin. gcc's optimizer
appears to misorder the partition's branch hint vs the input
distribution, producing more taken-branch mispredictions than the
straight unoptimised KernRift output. `rustc -O2` is fastest at 45 ms
because it inlines the comparator and vectorises the partition
swap. (`rustc debug` at 2 657 ms is unsurprising — debug builds wrap
every integer op in overflow checks and do no inlining.)

### sieve — primes up to 1 000 000

Memory-bandwidth bound on a small working set. Modern x86 caches and
prefetchers smooth out everyone's differences here; the three top
contenders all clock in at 2-3 ms.

### matmul — 256³ integer multiply-accumulate

A loop the SIMD-aware optimisers eat alive. gcc -O2 emits AVX2 chains;
rustc -O2 uses LLVM's loop vectoriser to similar effect. KernRift issues
straight scalar `mul + add + mov` per iteration. **1.5× slower than gcc
-O2** — the widened colour files closed most of what used to be an 8×
gap, but the remaining margin is the honest cost of no auto-vectorisation.

### mandelbrot — 1024 × 1024, max 1000 iter, f64

```
// for each pixel: iterate z := z² + c until |z|² > 4 or iter == 1000
```

gcc -O2 / rustc -O2 vectorise two pixels per loop with AVX double;
KernRift still does one scalar f64 op at a time — but as of v2.8.33 those
ops run xmm-to-xmm instead of bouncing through general-purpose registers,
which took this benchmark from 1771 ms to 551 ms. **1.11× slower than
gcc -O2**, down from 3.9×. Output value is `270513949` across all three
implementations.

### sha-256 — hash a 16 MiB zero buffer

Bit-twiddling intensive: 64 iterations of ROTR / XOR / ADD per
64-byte block × 256 K blocks ≈ 16 M rounds. KernRift's overhead has
three identifiable sources:

1. **No native u32:** every operation is `uint64` with explicit
   `& 0xFFFFFFFF` masks. That doubles register pressure and adds an
   extra AND per arithmetic op.
2. **`rotr32` is a function call:** gcc emits a single `ror`
   instruction; KernRift emits `shr + shl + or + and` plus call/return
   overhead. The AST-level inliner doesn't trigger here because the
   body is more than one expression.
3. **No SHA-NI / AVX intrinsics:** gcc compiled with `-O2` doesn't
   auto-emit SHA-NI either, but it does interleave 32-bit integer ops
   well enough that the compress function fits in roughly 200
   instructions.

Result: KernRift at 191 ms vs gcc -O2 at 40 ms (4.8× slower). Output
matches the system `sha256sum`:
`080acf35a507ac9849cfcba47dc2ad83e01b75663a516279c8b9d243b719643e`.

Two of the three causes (native u32, multi-expression inlining) are
addressable in future releases without inventing an autovectoriser.

## Methodology notes

- Each benchmark is a single source file in each language; no external
  dependencies. Source: `benchmarks/{name}.{kr,c,rs}`.
- Compile-time and binary-size figures come from the same wall-clock
  measurement as runtime.
- Benchmarks that produce output verify equivalence: the printed line
  must be byte-identical across all three implementations.
- Runtime measurements are wall-clock elapsed time from `date +%s%N`
  bracketing the binary execution. No CPU pinning, no isolcpus — these
  are everyday-machine numbers, not microbenchmark-rig numbers.

## What the gap looks like, where it shows up

| Cause                                  | mandelbrot | matmul | sha-256 | fib | sort | sieve |
|----------------------------------------|:----------:|:------:|:-------:|:---:|:----:|:-----:|
| No auto-vectorisation                  |     ○      |   ○    |    -    |  -  |  -   |   -   |
| No native 32-bit ops                   |     -      |   -    |    ●    |  -  |  -   |   -   |
| No interprocedural inlining (>1 expr)  |     -      |   -    |    ●    |  -  |  -   |   -   |
| No global value numbering / CCP        |     -      |   -    |    -    |  ●  |  -   |   -   |
| Prologue/epilogue size on small fns    |     -      |   -    |    -    |  ●  |  -   |   -   |

`-` = not the dominant cost on that benchmark; `●` = clear primary cost;
`○` = still the main remaining cost, but no longer dominant — the v2.8.33
XMM class and widened colour files cut mandelbrot to 1.11× and matmul to
1.5× of `gcc -O2`.

These match the roadmap items already on the table (autovectorisation
pass, deeper inliner, native u32 in IR). The gaps are well-known; this
table just localises which bench surfaces which.
