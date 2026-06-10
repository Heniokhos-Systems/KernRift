# KernRift Standard Library Reference

The standard library lives in `std/*.kr` — **18 modules, 289 functions**
(274 public + 15 underscore-prefixed internal helpers, listed for
completeness). Import a module with its `std/` path:

```kr
import "std/string.kr"
```

The compiler resolves `std/` against its installed library directory
(e.g. `~/.local/share/kernrift/std/`); inside the stdlib, modules import
each other with bare relative paths (`import "fmt.kr"`). All imported
sources concatenate into one compilation unit, so every `fn` in an
imported module (and its transitive imports) becomes callable — there is
no namespacing.

**Memory convention.** The primitive allocator is the compiler built-in
pair `alloc(size)` / `dealloc(ptr)` (mmap-backed, 8-byte size header
before the returned pointer — see `docs/LANGUAGE.md` §16). Every stdlib
function that *returns a string or buffer* allocates a fresh block with
`alloc()`; the caller owns it and may `dealloc()` it. `std/alloc.kr`
adds three managed allocators on top (arena / pool / heap).

**Failure conventions** (canonical forms in `docs/ERROR_HANDLING.md`):

| Pattern | Used by | Sentinel |
|---|---|---|
| 1 — "absent" | searches/lookups (`str_index_of`, `str_find_byte`, `hex_digit_val`) | `0xFFFFFFFFFFFFFFFF` (all-ones; helpers `opt_none`/`opt_is_some`/`opt_unwrap`) |
| 2 — kernel errno | raw syscall wrappers (`net_*`, `syscall_raw` results) | value `> 0xFFFFFFFFFFFFF000` is `-errno`; test with `is_errno`/`get_errno` from `std/io.kr` |
| 3 — abort | allocators (`arena_alloc`, `pool_alloc`, `heap_alloc`, `alloc_aligned`), `opt_unwrap` | message to stderr + `exit(1)` — they never return failure |

Functions like `map_get`, `vec_pop`, `vec_last` return `0` when there is
nothing to return; `0` is *not* distinguishable from a stored zero.

## Module index

| Module | Purpose |
|---|---|
| [`std/alloc.kr`](#stdallockr--allocators) | Arena, pool, and heap allocators with leak/double-free detection |
| [`std/color.kr`](#stdcolorkr--colors) | 32-bit ARGB color packing, blending, named constants |
| [`std/fb.kr`](#stdfbkr--framebuffer) | Framebuffer descriptor + pixel/rect/line drawing primitives |
| [`std/fixedpoint.kr`](#stdfixedpointkr--1616-fixed-point) | 16.16 fixed-point arithmetic |
| [`std/fmt.kr`](#stdfmtkr--formatting) | Integer→string formatting (dec/hex/bin) and padding |
| [`std/font.kr`](#stdfontkr--bitmap-font) | 8×16 bitmap font (ASCII 32–126) and framebuffer text rendering |
| [`std/io.kr`](#stdiokr--file-and-console-io) | Whole-file read/write, stdin line/int scanning, errno helpers |
| [`std/log.kr`](#stdlogkr--structured-logging) | Leveled logging to stderr with `key=value` variants |
| [`std/map.kr`](#stdmapkr--hash-map) | Open-addressing hash map, string keys → u64 values |
| [`std/math.kr`](#stdmathkr--integer-math) | Integer min/max/abs/clamp/pow/sqrt/gcd/is_prime |
| [`std/math_float.kr`](#stdmath_floatkr--floating-point-math) | f64 trig/exp/log/pow approximations + float formatting |
| [`std/mem.kr`](#stdmemkr--memory-operations) | realloc, aligned alloc, memcmp, memzero, memmove |
| [`std/memfast.kr`](#stdmemfastkr--block-memory-operations) | Word-sized block copy/fill (32/64-bit units) |
| [`std/net.kr`](#stdnetkr--networking) | TCP/UDP socket syscall wrappers (Linux) |
| [`std/string.kr`](#stdstringkr--strings) | The big one: search, slicing, case, split/join, UTF-8, string builder, char predicates |
| [`std/time.kr`](#stdtimekr--time) | Monotonic clock and sleep (Linux) |
| [`std/vec.kr`](#stdveckr--dynamic-array) | Growable array of u64 |
| [`std/widget.kr`](#stdwidgetkr--ui-widgets) | Framebuffer widget toolkit: panel, label, button, progress, textfield |

---

## `std/alloc.kr` — Allocators

Three managed allocators over the `alloc`/`dealloc` built-ins. All place
a `PROT_NONE` guard page after the slab (via `syscall_raw(10, …)` —
mprotect; Linux x86_64 only in V1, a no-op elsewhere). All abort with a
stderr message + `exit(1)` on exhaustion (Pattern 3) and print leak
warnings at destroy time. `*_stats` functions use KernRift tuple
returns: `(u64 a, u64 b) = arena_stats(h)`.

### Arena — bump allocator, free-everything-at-once

| Signature | Description |
|---|---|
| `fn arena_new(u64 capacity) -> u64` | Create arena with `capacity` bytes. Allocates the slab. |
| `fn arena_alloc(u64 arena, u64 size) -> u64` | Bump-allocate `size` bytes (8-byte aligned). Aborts on OOM. |
| `fn arena_reset(u64 arena)` | Rewind used offset to 0 (stats stay cumulative). |
| `fn arena_destroy(u64 arena)` | Free the slab; warns to stderr if bytes still live. |
| `fn arena_stats(u64 arena) -> u64` | Tuple `(total, live)`: cumulative bytes requested, bytes currently used. |

### Pool — fixed-size slots, free list, double-free detection

| Signature | Description |
|---|---|
| `fn pool_new(u64 obj_size, u64 count) -> u64` | Create pool of `count` slots (size rounded to ≥16, 8-aligned). |
| `fn pool_alloc(u64 pool) -> u64` | Pop a zeroed slot. Aborts when out of slots. |
| `fn pool_free(u64 pool, u64 ptr)` | Return slot; poisons with `0xEF` and aborts on double-free (canary `0xDEADBEEFDEADBEEF`). |
| `fn pool_destroy(u64 pool)` | Free pool; warns if slots leaked. |
| `fn pool_stats(u64 pool) -> u64` | Tuple `(capacity, used)`. |

### Heap — variable-size, first-fit, forward coalescing

| Signature | Description |
|---|---|
| `fn heap_new(u64 capacity) -> u64` | Create heap slab. |
| `fn heap_alloc(u64 heap, u64 size) -> u64` | First-fit allocate (8-aligned, blocks split when large). Aborts on OOM. |
| `fn heap_free(u64 heap, u64 ptr)` | Free a block; coalesces with the next free block; detects double-free. |
| `fn heap_destroy(u64 heap)` | Free slab; walks all blocks and warns about leaks. |
| `fn heap_stats(u64 heap) -> u64` | Tuple `(alloc_total, free_total, live)`. |

Verified example:

```kr
import "std/alloc.kr"

fn main() {
    u64 a = arena_new(4096)
    u64 p = arena_alloc(a, 100)
    store64(p, 1)
    (u64 total, u64 live) = arena_stats(a)   // (100, 104) — live is aligned
    arena_destroy(a)
    exit(0)
}
```

---

## `std/color.kr` — Colors

Colors are packed `0xAARRGGBB` (32-bit ARGB) in a `u64`. Pure functions,
no allocation. Named constants are zero-arg functions (call them:
`COLOR_RED()`).

| Signature | Description |
|---|---|
| `fn rgb(u64 r, u64 g, u64 b) -> u64` | Pack opaque color (alpha = 0xFF). |
| `fn rgba(u64 r, u64 g, u64 b, u64 a) -> u64` | Pack color with explicit alpha. |
| `fn color_r(u64 c) -> u64` / `color_g` / `color_b` / `color_a` | Extract one channel (0–255). |
| `fn alpha_blend(u64 fg, u64 bg) -> u64` | Blend `fg` over `bg` using `fg`'s alpha. |
| `fn color_lerp(u64 c1, u64 c2, u64 t) -> u64` | Linear interpolate, `t` in 0–255. |
| `fn color_darken(u64 c, u64 amount) -> u64` | Subtract `amount` from each channel (clamped at 0). |
| `fn color_lighten(u64 c, u64 amount) -> u64` | Add `amount` to each channel (clamped at 255). |
| `fn COLOR_BLACK() -> u64` … `fn COLOR_LIGHT_GRAY() -> u64` | 11 constants: BLACK, WHITE, RED, GREEN, BLUE, YELLOW, CYAN, MAGENTA, GRAY, DARK_GRAY, LIGHT_GRAY. |

---

## `std/fb.kr` — Framebuffer

A framebuffer descriptor is 5 × u64 = `[addr, width, height, stride,
bpp]`, heap-allocated by `fb_init`. `addr` can be real video memory or
any buffer you `alloc`'d. Supports 32/24/16/8 bpp in `fb_pixel`;
`fb_rect` has a fast path for 32 bpp; `fb_blit` assumes 32 bpp.

| Signature | Description |
|---|---|
| `fn fb_init(u64 addr, u64 w, u64 h, u64 stride, u64 bpp) -> u64` | Allocate and fill a 40-byte descriptor. Allocates. |
| `fn fb_addr(u64 fb) -> u64` / `fb_width` / `fb_height` / `fb_stride` / `fb_bpp` | Field accessors. |
| `fn fb_pixel(u64 fb, u64 x, u64 y, u64 color)` | Set one pixel (no bounds check). |
| `fn fb_rect(u64 fb, u64 x, u64 y, u64 w, u64 h, u64 color)` | Filled rectangle. |
| `fn fb_fill(u64 fb, u64 color)` | Fill the whole framebuffer. |
| `fn fb_clear(u64 fb)` | Fill with 0 (black/transparent). |
| `fn fb_hline(u64 fb, u64 x, u64 y, u64 w, u64 color)` | Horizontal line. |
| `fn fb_vline(u64 fb, u64 x, u64 y, u64 h, u64 color)` | Vertical line. |
| `fn fb_line(u64 fb, u64 x0, u64 y0, u64 x1, u64 y1, u64 color)` | Bresenham line (signed-safe). |
| `fn fb_rect_outline(u64 fb, u64 x, u64 y, u64 w, u64 h, u64 color)` | 1-px rectangle outline. |
| `fn fb_blit(u64 fb, u64 x, u64 y, u64 src, u64 src_w, u64 src_h)` | Copy a 32-bpp pixel buffer onto the framebuffer. |

Verified example (off-screen buffer):

```kr
import "std/fb.kr"
import "std/color.kr"

fn main() {
    u64 buf = alloc(100 * 100 * 4)
    u64 fb = fb_init(buf, 100, 100, 400, 32)   // stride = width * 4
    fb_fill(fb, rgb(20, 20, 20))
    fb_rect_outline(fb, 10, 10, 80, 80, COLOR_WHITE())
    exit(0)
}
```

---

## `std/fixedpoint.kr` — 16.16 fixed-point

Format: upper 48 bits integer, lower 16 bits fraction; 1.0 = `0x10000`.
Signed values work via two's complement (`fp_abs`/`fp_min`/`fp_max`/
`fp_clamp` use the `signed_*` compare built-ins). Pure functions, no
allocation.

| Signature | Description |
|---|---|
| `fn FP_ONE() -> u64` / `fn FP_HALF() -> u64` | Constants 65536 / 32768. |
| `fn fp_from_int(u64 n) -> u64` | `n << 16`. |
| `fn fp_to_int(u64 fp) -> u64` | Truncate to integer (`fp >> 16`). |
| `fn fp_from_frac(u64 num, u64 den) -> u64` | Build from a ratio: `fp_from_frac(1, 2)` = 0.5. |
| `fn fp_frac(u64 fp) -> u64` | Fractional bits only. |
| `fn fp_floor(u64 fp) -> u64` / `fp_ceil` / `fp_round` | Round to integer-valued fixed-point. |
| `fn fp_add(u64 a, u64 b) -> u64` / `fp_sub` | Plain add/sub (provided for symmetry). |
| `fn fp_mul(u64 a, u64 b) -> u64` | `(a*b) >> 16`. |
| `fn fp_div(u64 a, u64 b) -> u64` | `(a << 16) / b`. |
| `fn fp_abs(u64 fp) -> u64` / `fp_min(u64 a, u64 b)` / `fp_max(u64 a, u64 b)` / `fp_clamp(u64 val, u64 lo, u64 hi)` | Signed-aware helpers. |
| `fn fp_lerp(u64 a, u64 b, u64 t) -> u64` | Interpolate with fixed-point `t`. |
| `fn fp_sqrt(u64 x) -> u64` | Newton iteration (≤32 steps). |

---

## `std/fmt.kr` — Formatting

Integer→string conversions. **Every function returns a freshly
`alloc`'d null-terminated string the caller owns.** Print results with
the `print_str`/`println_str` built-ins.

| Signature | Description |
|---|---|
| `fn fmt_dec(u64 val) -> u64` | Decimal: `fmt_dec(42)` → `"42"`. Unsigned only. Allocates. |
| `fn fmt_hex(u64 val) -> u64` | Lowercase hex with prefix: `fmt_hex(255)` → `"0xff"`. Allocates. |
| `fn fmt_bin(u64 val) -> u64` | Binary with prefix: `fmt_bin(10)` → `"0b1010"`. Allocates. |
| `fn pad_left(u64 s, u64 width, u64 pad_char) -> u64` | Left-pad to `width`: `pad_left("42", 5, ' ')` → `"   42"`. Allocates (copies even when no padding needed). |
| `fn pad_right(u64 s, u64 width, u64 pad_char) -> u64` | Right-pad to `width`. Allocates. |

---

## `std/font.kr` — Bitmap font

8×16 bitmap font covering printable ASCII 32–126 (16 bytes per glyph).
Glyph data is built lazily on first use and cached in a `static`;
characters outside 32–126 are skipped. Glyphs are 8 px wide, 16 px
tall; `fb_text` treats `\n` (byte 10) as a line break (+16 px).

| Signature | Description |
|---|---|
| `fn font_init() -> u64` | Build (once) and return the 1536-byte glyph table pointer. Allocates on first call only. |
| `fn font_set_glyph(u64 p, u64 b0, …, u64 b15)` | Internal: write 16 row bytes of one glyph at `p`. (16 byte params `b0`–`b15`.) |
| `fn fb_char(u64 fb, u64 x, u64 y, u64 ch, u64 color)` | Draw one character on a `std/fb.kr` framebuffer. |
| `fn fb_text(u64 fb, u64 x, u64 y, u64 str, u64 color)` | Draw a null-terminated string; handles `\n`. |

---

## `std/io.kr` — File and console I/O

Convenience wrappers over the `file_open`/`file_read`/`file_write`/
`file_close`/`file_size` built-ins, plus the errno-test helpers from
Error-Handling Pattern 2.

### Files

| Signature | Description |
|---|---|
| `fn read_file(u64 path) -> u64` | Read entire file into a fresh null-terminated buffer. Returns `0` for an empty file. Allocates. **Caveat (verified): a nonexistent path currently segfaults** — `file_open`'s `-errno` result is used as an fd unchecked. Guard with `file_open` + `is_errno` yourself if the file may be missing. |
| `fn write_file(u64 path, u64 content)` | Create/overwrite file with a null-terminated string. |
| `fn append_file(u64 path, u64 content)` | Read-concat-rewrite append (allocates intermediates). |

### Console

| Signature | Description |
|---|---|
| `fn read_line(u64 max_len) -> u64` | Read one line from stdin (strips `\n`). Returns fresh string. Allocates. |
| `fn scan_str() -> u64` | `read_line(1024)`. Allocates. |
| `fn scan_int() -> u64` | Read a line and parse as integer (optional leading whitespace and `-`). Returns 0 if no digits. |
| `fn print_int(u64 val)` | `println(val)`. |
| `fn print_line(u64 s)` | `println_str(s)`. |
| `fn print_kv(u64 key, u64 val)` | Print `key = val\n` (key is a string, val an integer). |
| `fn print_indent(u64 n)` | Print `n` spaces. |

### Errno helpers (Pattern 2)

| Signature | Description |
|---|---|
| `fn is_errno(u64 r) -> u64` | 1 if `r` is a kernel error return (`> 0xFFFFFFFFFFFFF000`), else 0. |
| `fn get_errno(u64 r) -> u64` | Positive errno value if `r` is an error, else 0. |

---

## `std/log.kr` — Structured logging

Leveled logging to stderr. Levels: 0=debug, 1=info, 2=warn, 3=error;
default minimum is **info** (set lazily). Output: `[LEVEL] message\n` or
`[LEVEL] message key=value\n`. The `_int` variants format the integer
into a stack buffer — no heap allocation.

| Signature | Description |
|---|---|
| `fn log_set_level(u64 level)` | Set minimum level (messages below it are dropped). |
| `fn log_debug(u64 msg)` / `log_info` / `log_warn` / `log_error` | Plain message at each level. |
| `fn log_debug_kv(u64 msg, u64 key, u64 val)` / `log_info_kv` / `log_warn_kv` / `log_error_kv` | Message + `key=value` where `val` is a **string**. |
| `fn log_info_int(u64 msg, u64 key, u64 val)` / `log_error_int(u64 msg, u64 key, u64 val)` | Message + `key=value` where `val` is an **integer**. (Only info/error variants exist.) |

Internal helpers (don't call directly): `_log_ensure_level()`,
`_log_write(u64 s)`, `_log_prefix(u64 level)`,
`_log_itoa(u64 val, u64 buf, u64 buf_size) -> u64`,
`_log_kv(u64 level, u64 msg, u64 key, u64 val)`,
`_log_int(u64 level, u64 msg, u64 key, u64 val)`.

---

## `std/map.kr` — Hash map

Open-addressing hash map (FNV-1a + linear probing), string keys → u64
values. **Fixed capacity of 64 slots** (`static u64 MAP_CAP = 64`) — it
does not grow; inserting more than 64 distinct keys will loop forever
looking for a free slot. Keys are stored as raw pointers (not copied) —
keep them alive. No deletion operation.

| Signature | Description |
|---|---|
| `fn map_new() -> u64` | Create an empty map. Allocates (header + key/value arrays). |
| `fn map_set(u64 m, u64 key, u64 val)` | Insert or update. Stores the key *pointer*. |
| `fn map_get(u64 m, u64 key) -> u64` | Value for `key`, or `0` when absent (indistinguishable from a stored 0 — use `map_has`). |
| `fn map_has(u64 m, u64 key) -> u64` | 1 if present, 0 if not. |
| `fn map_len(u64 m) -> u64` | Number of entries. |
| `fn map_cap(u64 m) -> u64` | Capacity (64). |
| `fn map_keys(u64 m) -> u64` / `fn map_vals(u64 m) -> u64` | Raw key/value array pointers (`cap` × u64; key slot 0 = empty). |
| `fn map_free(u64 m)` | Free the arrays and the map. |
| `fn str_hash(u64 s) -> u64` | FNV-1a hash of a null-terminated string (usable standalone). |

---

## `std/math.kr` — Integer math

Unsigned u64 helpers; `abs` interprets its argument as signed two's
complement. Pure, no allocation.

| Signature | Description |
|---|---|
| `fn min(u64 a, u64 b) -> u64` / `fn max(u64 a, u64 b) -> u64` | Unsigned min/max. |
| `fn abs(u64 val) -> u64` | Two's-complement absolute value (checks bit 63). |
| `fn clamp(u64 val, u64 lo, u64 hi) -> u64` | Unsigned clamp. |
| `fn pow(u64 base, u64 exp) -> u64` | Integer power by repeated multiply (wraps on overflow). |
| `fn sqrt_int(u64 n) -> u64` | Integer square root (Newton). |
| `fn gcd(u64 a, u64 b) -> u64` | Greatest common divisor (Euclid). |
| `fn is_prime(u64 n) -> u64` | 1 if prime, 0 otherwise (trial division). |

---

## `std/math_float.kr` — Floating-point math

Software polynomial approximations for f64 trig/exp/log, plus float
formatting. Written around two V1 codegen limitations (documented in
the source): f64 locals can't be reassigned (hence fresh-variable
chains and recursive helpers) and float literals only keep the integer
part (constants are built as integer ratios via `int_to_f64`). Several
functions have short aliases (`sin` = `sin_f64`, etc.).

### Constants

| Signature | Description |
|---|---|
| `fn f64_pi() -> f64` / `f64_two_pi()` / `f64_half_pi()` | π, 2π, π/2. |
| `fn f64_ln2() -> f64` / `fn f64_e() -> f64` | ln 2, e. |

### Basic ops

| Signature | Description |
|---|---|
| `fn abs_f64(f64 x) -> f64` (alias `abs_f`) | Absolute value. |
| `fn neg_f64(f64 x) -> f64` (alias `neg_f`) | Negate. |
| `fn floor_f64(f64 x) -> f64` (alias `floor`) | Round toward −∞. |
| `fn ceil_f64(f64 x) -> f64` (alias `ceil`) | Round toward +∞. |
| `fn fmod_f64(f64 x, f64 y) -> f64` | `x - floor(x/y)*y`. |

### Transcendentals

| Signature | Description |
|---|---|
| `fn sin_f64(f64 x) -> f64` (alias `sin`) | 7-term Taylor, range-reduced to [−π, π]. Verified: `sin(1)` ≈ 0.8414. |
| `fn cos_f64(f64 x) -> f64` (alias `cos`) | `sin(x + π/2)`. |
| `fn tan_f64(f64 x) -> f64` (alias `tan`) | `sin/cos`. |
| `fn exp_f64(f64 x) -> f64` (alias `exp`) | 10-term Taylor + doubling. **Correct for x ≥ 0 only** — for negative `x` the `2^-k` scaling is skipped (verified: `exp(-1)` returns 1.4715, not 0.3679). |
| `fn log_f64(f64 x) -> f64` (alias `log`) | Natural log via Newton on `exp` (10 iterations). Valid for x > 0; the initial guess table targets x up to a few hundred. |
| `fn pow_f64(f64 x, f64 y) -> f64` (alias `pow_f`) | `exp(y * log(x))` — inherits both functions' domains (x > 0). |

Internal helpers: `f64_double_n(f64 x, u64 n) -> f64`,
`f64_scale10(f64 x, u64 n) -> f64`, `log_step(f64 x, f64 y) -> f64`,
`log_iter(f64 x, f64 y, u64 n) -> f64`, `log_guess(u64 xi) -> f64`.

### Float formatting

| Signature | Description |
|---|---|
| `fn fmt_f64(f64 val, u64 decimals) -> u64` | Format as `[-]INT.FRAC` with `decimals` fractional digits (capped at 15). NaN/±Inf return `"NaN"`, `"inf"`, `"-inf"`. Returns fresh null-terminated string. Allocates. |
| `fn fmt_f32(f32 val, u64 decimals) -> u64` | f32 variant (decimals capped at 7); delegates to `fmt_f64`. Allocates. |
| `fn fmt_classify_f64(f64 v) -> u64` / `fn fmt_classify_f32(f32 v) -> u64` | IEEE-754 class via bit inspection: 0=finite, 1=NaN, 2=+Inf, 3=−Inf. (Needed because float `!=` doesn't flag NaN in V1.) |
| `fn fmt_float_literal(u64 b0, u64 b1, u64 b2, u64 b3) -> u64` | Internal: alloc a ≤4-byte literal ("NaN"/"inf"). Allocates. |
| `fn fmt_f64_pos(f64 aval, u64 decimals, u64 negative) -> u64` | Internal worker for `fmt_f64`. Allocates. |

Verified example:

```kr
import "std/math_float.kr"

fn main() {
    f64 x = int_to_f64(2)
    println_str(fmt_f64(sqrt_f64(x), 6))   // 1.414213 (sqrt_f64 is a compiler builtin)
    exit(0)
}
```

---

## `std/mem.kr` — Memory operations

Extensions to the `memcpy`/`memset` built-ins.

| Signature | Description |
|---|---|
| `fn realloc(u64 ptr, u64 old_size, u64 new_size) -> u64` | Allocate `new_size`, copy `min(old, new)` bytes. Does **not** free `ptr`. Allocates. |
| `fn alloc_aligned(u64 size, u64 align) -> u64` | Buffer whose address is a multiple of `align` (power of two — asserted, aborts otherwise). For DMA / cache-line / page alignment. **Must be freed with `alloc_aligned_free`, not `dealloc`.** Allocates. |
| `fn alloc_aligned_free(u64 ptr)` | Free an `alloc_aligned` buffer (reads the stashed base pointer 8 bytes before `ptr`). |
| `fn memcmp(u64 a, u64 b, u64 len) -> u64` | 0 if regions equal, 1 otherwise (**no ordering** — not C memcmp). |
| `fn memzero(u64 ptr, u64 len)` | `memset(ptr, 0, len)`. |
| `fn memmove(u64 dst, u64 src, u64 len)` | Overlap-safe copy (backward scan when `dst > src`). Use instead of `memcpy` when regions may overlap. |

---

## `std/memfast.kr` — Block memory operations

Word-at-a-time copy/fill. `count` is in **elements**, not bytes.
Addresses should be suitably aligned.

| Signature | Description |
|---|---|
| `fn memcpy32(u64 dst, u64 src, u64 count)` | Copy `count` 32-bit words. |
| `fn memcpy64(u64 dst, u64 src, u64 count)` | Copy `count` 64-bit words. |
| `fn memset32(u64 dst, u64 val, u64 count)` | Fill `count` 32-bit words with `val`. |
| `fn memset64(u64 dst, u64 val, u64 count)` | Fill `count` 64-bit words with `val`. |

---

## `std/net.kr` — Networking

> **Note:** an earlier revision had `net_addr_free` calling
> `dealloc(addr, 16)` (a 2-argument call to the 1-argument `dealloc`
> builtin), which made `import "std/net.kr"` fail to compile. Fixed in
> the repo source. If your *installed* copy still has the old line,
> re-run `make install` (or the std install step) to sync it.

Raw socket syscall wrappers, Linux only (selects x86_64 vs ARM64/Android
syscall numbers via `get_arch_id()`). All wrappers return the raw
syscall result — check failures with `is_errno`/`get_errno` from
`std/io.kr` (Pattern 2).

| Signature | Description |
|---|---|
| `fn net_socket(u64 domain, u64 sock_type, u64 protocol) -> u64` | `socket()`. domain 2=AF_INET; type 1=SOCK_STREAM, 2=SOCK_DGRAM. Returns fd or −errno. |
| `fn net_bind(u64 fd, u64 addr, u64 addr_len) -> u64` | `bind()`. |
| `fn net_listen(u64 fd, u64 backlog) -> u64` | `listen()`. |
| `fn net_accept(u64 fd) -> u64` | `accept()` — returns new connection fd. |
| `fn net_connect(u64 fd, u64 addr, u64 addr_len) -> u64` | `connect()`. |
| `fn net_send(u64 fd, u64 buf, u64 len) -> u64` | `sendto()` without address — bytes sent. |
| `fn net_recv(u64 fd, u64 buf, u64 len) -> u64` | `recvfrom()` without address — bytes received. |
| `fn net_close(u64 fd)` | `close()`. |
| `fn net_setsockopt(u64 fd, u64 level, u64 optname, u64 optval, u64 optlen) -> u64` | `setsockopt()`. |
| `fn net_htons(u64 port) -> u64` | Byte-swap a 16-bit port to network order. |
| `fn net_addr_ipv4(u64 ip, u64 port) -> u64` | Build a 16-byte `sockaddr_in` (`ip` packed host-order, e.g. `0x7F000001`). Allocates; caller frees. |
| `fn net_addr_free(u64 addr)` | Free a `net_addr_ipv4` buffer (`dealloc(addr)`). |

Internal helpers: `_net_nr_socket()`, `_net_nr_bind()`,
`_net_nr_listen()`, `_net_nr_accept()`, `_net_nr_connect()`,
`_net_nr_sendto()`, `_net_nr_recvfrom()`, `_net_nr_close()`,
`_net_nr_setsockopt()` — each `() -> u64`, returning the per-arch
syscall number.

---

## `std/string.kr` — Strings

Strings are null-terminated byte sequences; a "string" is a `u64`
pointer to the first byte. **Every function below that returns a string
allocates fresh memory** — the caller owns and may `dealloc` it.
(`str_len` and `str_eq` are compiler built-ins, not defined here.)

### Construction / conversion

| Signature | Description |
|---|---|
| `fn str_cat(u64 a, u64 b) -> u64` | Concatenate. Allocates. |
| `fn str_copy(u64 s) -> u64` | Duplicate. Allocates. |
| `fn str_repeat(u64 s, u64 count) -> u64` | `str_repeat("ab", 3)` → `"ababab"`. Allocates. |
| `fn int_to_str(u64 val) -> u64` | Unsigned decimal string. Allocates. |
| `fn str_to_int(u64 s) -> u64` | Parse decimal int (optional leading `-`; stops at first non-digit; 0 if none). |
| `fn str_to_float(u64 s) -> f64` | Parse `[±]INT[.FRAC][e±EXP]`. Returns 0.0 when no digits. No hex/inf/nan forms. |
| `fn str_from_float(f64 v, u64 decimals) -> u64` | `fmt_f64` wrapper (needs `std/math_float.kr` imported). Allocates. |
| `fn str_from_bool(u64 b) -> u64` | `"true"` / `"false"` as a fresh allocation. |
| `fn str_from_codepoint(u64 cp) -> u64` | One UTF-8 codepoint as a string. Allocates. |

### Search / comparison

| Signature | Description |
|---|---|
| `fn str_starts(u64 s, u64 prefix) -> u64` | 1/0 prefix test. |
| `fn str_ends(u64 s, u64 suffix) -> u64` | 1/0 suffix test. |
| `fn str_contains(u64 haystack, u64 needle) -> u64` | 1/0 substring test (empty needle → 1). |
| `fn str_find_byte(u64 s, u64 byte_val) -> u64` | Index of first byte, or `0xFFFFFFFFFFFFFFFF`. |
| `fn str_index_of(u64 haystack, u64 needle) -> u64` | Index of first substring match, or `0xFFFFFFFFFFFFFFFF`; empty needle → 0. |
| `fn str_compare(u64 a, u64 b) -> u64` | Lexicographic: `0xFFFFFFFFFFFFFFFF` (−1), 0, or 1. Compare with the `signed_*` helpers. |

### Slicing / transformation

| Signature | Description |
|---|---|
| `fn str_sub(u64 s, u64 start, u64 len) -> u64` | Substring (no bounds checks). Allocates. |
| `fn str_at(u64 s, u64 idx) -> u64` | Byte at `idx`. |
| `fn str_trim(u64 s) -> u64` | Strip leading/trailing space/tab/CR/LF. Allocates. |
| `fn str_lower(u64 s) -> u64` / `fn str_upper(u64 s) -> u64` | ASCII-only case fold. Allocates. |
| `fn str_replace(u64 haystack, u64 from, u64 to) -> u64` | Replace all occurrences (empty `from` → copy). Allocates. |
| `fn str_split(u64 s, u64 delim_byte, u64 out_parts, u64 max_parts) -> u64` | Split on a single byte into caller-supplied `u64[]`; each part freshly allocated. Returns part count. Empty input → 1 empty part. |
| `fn str_join(u64 parts, u64 count, u64 sep) -> u64` | Join a `u64[]` of string pointers with `sep`. Allocates. |

### Option sentinel helpers (Pattern 1)

| Signature | Description |
|---|---|
| `fn opt_none() -> u64` | The sentinel `0xFFFFFFFFFFFFFFFF`. |
| `fn opt_some(u64 v) -> u64` | Pass through `v`; aborts if `v` equals the sentinel. |
| `fn opt_is_some(u64 v) -> u64` | 1 if real value, 0 if sentinel. |
| `fn opt_unwrap(u64 v) -> u64` | `v`, or stderr message + `exit(1)` if sentinel. |

### UTF-8

| Signature | Description |
|---|---|
| `fn utf8_decode_at(u64 s, u64 i, u64 out_width) -> u64` | Decode codepoint at byte offset `i`; writes sequence width (1–4) to `*out_width`. Invalid bytes → raw byte, width 1. |
| `fn utf8_encode(u64 cp, u64 buf) -> u64` | Encode codepoint into `buf`; returns bytes written (1–4); ≥ 0x110000 clamps to U+FFFD. Not null-terminated. |
| `fn str_codepoint_count(u64 s) -> u64` | Codepoints (≠ bytes). |
| `fn str_grapheme_count(u64 s) -> u64` | Grapheme clusters (conservative: combining-mark ranges + ZWJ/ZWNJ). |
| `fn utf8_is_combining(u64 cp) -> u64` | 1 if `cp` is a combining mark / joiner (U+0300–036F, U+20D0–20FF, ZWNJ/ZWJ/BOM). |
| `fn utf8_lower_codepoint(u64 cp) -> u64` / `fn utf8_upper_codepoint(u64 cp) -> u64` | 1:1 case fold for ASCII, Latin-1 Supplement, modern Greek; others pass through (no ß→SS, no locale rules). |
| `fn str_lower_utf8(u64 s) -> u64` / `fn str_upper_utf8(u64 s) -> u64` | UTF-8-aware case fold of a whole string. Allocates. |

### String builder

Builder = alloc'd block: `[capacity u64][length u64][bytes…]`. All
`sb_append_*` / `sb_reserve` may reallocate and **return the (possibly
new) handle — always reassign**: `sb = sb_append_str(sb, …)`.

| Signature | Description |
|---|---|
| `fn sb_new(u64 cap) -> u64` | New builder (min capacity 16; 64 is a good default). Allocates. |
| `fn sb_reserve(u64 sb, u64 extra) -> u64` | Ensure room for `extra` bytes (doubling growth). Returns new handle. |
| `fn sb_append_byte(u64 sb, u64 b) -> u64` | Append one byte. |
| `fn sb_append_str(u64 sb, u64 s) -> u64` | Append a null-terminated string. |
| `fn sb_append_int(u64 sb, u64 n) -> u64` | Append decimal digits. |
| `fn sb_append_hex(u64 sb, u64 n) -> u64` | Append `0x…` lowercase hex. |
| `fn sb_append_float(u64 sb, f64 v, u64 decimals) -> u64` | Append a float (needs `std/math_float.kr` imported). |
| `fn sb_append_bool(u64 sb, u64 b) -> u64` | Append `true`/`false`. |
| `fn sb_append_codepoint(u64 sb, u64 cp) -> u64` | Append a UTF-8-encoded codepoint. |
| `fn sb_len(u64 sb) -> u64` | Current length in bytes. |
| `fn sb_finish(u64 sb) -> u64` | Copy contents into a fresh null-terminated string (builder stays alive). Allocates. |
| `fn sb_free(u64 sb)` | Free the builder. |

Verified example:

```kr
import "std/string.kr"

fn main() {
    u64 sb = sb_new(64)
    sb = sb_append_str(sb, "x = ")
    sb = sb_append_int(sb, 42)
    sb = sb_append_str(sb, ", y = ")
    sb = sb_append_hex(sb, 255)
    u64 s = sb_finish(sb)      // "x = 42, y = 0xff"
    println_str(s)
    sb_free(sb)
    exit(0)
}
```

### Character predicates (ASCII)

Each takes a byte value (0–255) and returns 0/1; non-ASCII input → 0.

| Signature | Description |
|---|---|
| `fn is_digit(u64 c) -> u64` | `'0'..'9'`. |
| `fn is_lower(u64 c) -> u64` / `fn is_upper(u64 c) -> u64` | `'a'..'z'` / `'A'..'Z'`. |
| `fn is_alpha(u64 c) -> u64` / `fn is_alnum(u64 c) -> u64` | Letter / letter-or-digit. |
| `fn is_space(u64 c) -> u64` | Space, `\t\n\v\f\r` (C `isspace` set). |
| `fn is_hex_digit(u64 c) -> u64` | `0-9 a-f A-F`. |
| `fn is_print(u64 c) -> u64` | Printable ASCII 32–126. |
| `fn to_upper_ch(u64 c) -> u64` / `fn to_lower_ch(u64 c) -> u64` | Case-convert one ASCII letter; others pass through. |
| `fn hex_digit_val(u64 c) -> u64` | Numeric value of a hex digit, or `0xFFFFFFFFFFFFFFFF` if invalid. |

---

## `std/time.kr` — Time

Monotonic clock and sleep via raw syscalls (Linux x86_64 / ARM64 /
Android, selected by `get_arch_id()`).

| Signature | Description |
|---|---|
| `fn time_now() -> u64` | Monotonic time in nanoseconds (`clock_gettime(CLOCK_MONOTONIC)`). |
| `fn time_sleep_ns(u64 ns)` | Sleep for `ns` nanoseconds (`nanosleep`). |
| `fn time_sleep_ms(u64 ms)` | Sleep for `ms` milliseconds. |
| `fn time_elapsed(u64 start) -> u64` | Nanoseconds since a `time_now()` value. |

---

## `std/vec.kr` — Dynamic array

Growable array of u64: handle points at `[data_ptr, length, capacity]`
(3 × u64). Starts at capacity 8, doubles on growth. No bounds checks on
`vec_get`/`vec_set`; `vec_remove` shifts elements left.

| Signature | Description |
|---|---|
| `fn vec_new() -> u64` | New empty vec (capacity 8). Allocates. |
| `fn vec_push(u64 v, u64 val)` | Append (grows ×2 when full; old data block is **not** freed on growth). |
| `fn vec_get(u64 v, u64 idx) -> u64` | Element at `idx` (unchecked). |
| `fn vec_set(u64 v, u64 idx, u64 val)` | Overwrite element (unchecked). |
| `fn vec_pop(u64 v) -> u64` | Remove and return last element; `0` if empty. |
| `fn vec_last(u64 v) -> u64` | Last element without removing; `0` if empty. |
| `fn vec_len(u64 v) -> u64` / `fn vec_cap(u64 v) -> u64` | Length / capacity. |
| `fn vec_data(u64 v) -> u64` | Raw element-array pointer. |
| `fn vec_contains(u64 v, u64 val) -> u64` | 1 if any element equals `val`. |
| `fn vec_remove(u64 v, u64 idx)` | Remove element, shifting the tail left. |
| `fn vec_clear(u64 v)` | Set length to 0 (keeps storage). |
| `fn vec_free(u64 v)` | Free data block and handle. |

Verified example:

```kr
import "std/vec.kr"

fn main() {
    u64 v = vec_new()
    vec_push(v, 42)
    println(vec_get(v, 0))   // 42
    vec_free(v)
    exit(0)
}
```

---

## `std/widget.kr` — UI widgets

Minimal widget toolkit for bare-metal framebuffer UIs. Depends on
`fb.kr`, `font.kr`, `color.kr`, `string.kr` (import those too). Each
widget is a heap-allocated descriptor of u64 fields at fixed 8-byte
offsets; `*_new` allocates, there are no `*_free` functions (use
`dealloc` on the handle). Text metrics assume the 8×16 `std/font.kr`
font.

### Panel — rectangle with background + optional border

| Signature | Description |
|---|---|
| `fn panel_new(u64 fb, u64 x, u64 y, u64 w, u64 h, u64 bg_color, u64 border_color) -> u64` | Create (border_color 0 = no border). Allocates. |
| `fn panel_draw(u64 panel)` | Draw fill + outline. |

### Label — single-line text

| Signature | Description |
|---|---|
| `fn label_new(u64 fb, u64 x, u64 y, u64 text, u64 color, u64 bg_color) -> u64` | Create (bg 0 = transparent). Stores the text *pointer*. Allocates. |
| `fn label_draw(u64 label)` | Draw optional background strip + text. |
| `fn label_set_text(u64 label, u64 text)` | Swap the text pointer. |

### Button — clickable rectangle, centered text

| Signature | Description |
|---|---|
| `fn button_new(u64 fb, u64 x, u64 y, u64 w, u64 h, u64 text, u64 fg, u64 bg) -> u64` | Create (starts unpressed). Allocates. |
| `fn button_draw(u64 button)` | Draw; fg/bg swap when pressed. |
| `fn button_contains(u64 button, u64 mx, u64 my) -> u64` | 1 if point inside the button (hit test). |
| `fn button_set_pressed(u64 button, u64 state)` | Set pressed flag (1/0). |

### Progress bar — 0–100 %

| Signature | Description |
|---|---|
| `fn progress_new(u64 fb, u64 x, u64 y, u64 w, u64 h, u64 fg, u64 bg) -> u64` | Create at value 0. Allocates. |
| `fn progress_draw(u64 progress)` | Draw bar (value clamped to 100) + outline. |
| `fn progress_set(u64 progress, u64 value)` | Set value (0–100). |

### Text field — editable single-line buffer (max 254 chars)

| Signature | Description |
|---|---|
| `fn textfield_new(u64 fb, u64 x, u64 y, u64 w, u64 text_color, u64 bg_color) -> u64` | Create with its own 256-byte buffer. Allocates. |
| `fn textfield_draw(u64 field)` | Draw box (24 px tall), text, and cursor. |
| `fn textfield_append_char(u64 field, u64 ch)` | Append a character (silently ignored at 254). |
| `fn textfield_backspace(u64 field)` | Delete last character. |
| `fn textfield_clear(u64 field)` | Empty the buffer. |
| `fn textfield_get_text(u64 field) -> u64` | Pointer to the internal null-terminated buffer (not a copy — do not free). |
| `fn textfield_get_len(u64 field) -> u64` | Current character count. |

---

*`std/*.kr` is the source of truth — regenerate this document whenever
signatures change.*
