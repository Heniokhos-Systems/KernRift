# KernRift — ABI Stability Policy

This document defines what "ABI compatibility" means in KernRift, which
versions are compatible with which, and what we promise not to break
between releases.

The current release is **v2.8.24**. KernRift is pre-1.0. The policy below
describes what we do today; it will tighten at 1.0.

## Scope of the ABI

"ABI" in KernRift covers five distinct interfaces. Each has its own
stability story.

### 1. Calling convention (between KernRift functions)

This is the contract between a caller and a callee compiled by the same
`kernriftc` build. It includes register assignments, argument passing,
return values, stack layout, and struct packing.

| Target                | Convention                                   | Stable? |
|-----------------------|----------------------------------------------|---------|
| Linux x86_64          | System V AMD64                               | Yes     |
| Linux AArch64         | AAPCS64                                      | Yes     |
| macOS x86_64          | System V AMD64                               | Yes     |
| macOS AArch64 (ARM64) | AAPCS64 (Apple variant — arg spill rules)    | Yes     |
| Windows x86_64        | Microsoft x64                                | Yes     |
| Android AArch64       | AAPCS64                                      | Yes     |

**Promise.** The calling convention for each target follows the platform
ABI exactly. A KernRift `fn foo(u64 a, u64 b) -> u64` can be called from
C, and vice versa, as long as the C signature matches.

**Not covered.** Types that the platform ABI treats specially (`_Complex`,
`long double`, C++-style non-trivial structs) are not representable in
KernRift. If you need them, use `extern "C"` wrappers on the C side.

### 2. Struct layout

| Rule                                                         | Status |
|--------------------------------------------------------------|--------|
| Fields laid out in declaration order.                        | Stable |
| No padding between fields.                                   | Stable — KernRift structs are packed by default. |
| `@packed` annotation is accepted but currently a no-op (packing is already the default). | Stable |
| Struct size = sum of field sizes.                            | Stable |
| Cross-language struct interop with C: add explicit padding fields to match C's natural alignment. | Documented in `docs/LANGUAGE.md`. |

### 3. IR bytecode

IR is the in-memory representation consumed by the IR backend. **IR is
not a stable interface.** We add, remove, and renumber opcodes between
minor releases. The current opcode catalog is documented in
`docs/IR_REFERENCE.md` for the release it ships with.

If you need a stable target-independent format, compile to object files
(`--emit=obj`) instead.

### 4. stdlib (`std/*.kr`)

Functions exported by `std/io.kr`, `std/mem.kr`, `std/string.kr`, etc.

**Additive changes** (new functions) — any release.

**Breaking changes** (signature or semantic change to an existing
function) — bump minor version (2.x.y → 2.(x+1).0). Deprecation notice
in one release before removal, when feasible.

Currently frozen: all helpers documented in `docs/ERROR_HANDLING.md`
(`opt_some`, `opt_none`, `opt_is_some`, `opt_unwrap`, `is_errno`,
`get_errno`).

### 5. Compiler flags and command-line interface

| Flag                     | Stability |
|--------------------------|-----------|
| `--emit=exe/obj/asm/ir`  | Stable    |
| `--target=<name>`        | Stable    |
| `--legacy`               | Stable during the IR migration; may become a no-op later. |
| `--coalesce` / `--no-coalesce` | Stable surface — the heuristic may change. |
| `--O0` / `--O1`          | Stable surface — the underlying optimizations may change. |
| `--check=<list>`         | Experimental — not yet present; reserved. |

`--target=` takes a **name**, not an LLVM-style triple. The accepted values
are exactly:

| Value | Meaning |
|-------|---------|
| `linux` | Linux (the default) |
| `macos`, `darwin` | macOS |
| `windows`, `win` | Windows |
| `android` | Android |
| `esp32` | ESP32 (Xtensa LX6) esp-image; requires `--arch=xtensa --freestanding` |

Anything else is a hard error. A triple such as `aarch64-linux-android` has
never been accepted — before v2.8 it matched nothing, fell through the
dispatch chain and was silently ignored, producing a default-target binary.
It is now rejected outright. Note that `--target=` selects the **OS** (or, for
`esp32`, the machine target); the instruction set is selected separately with
`--arch=`.

Removing or renaming a flag requires a minor-version bump. Changing the
*default* value of a flag (e.g., `--O1` becoming `--O2`) also requires a
minor-version bump.

## Versioning scheme

KernRift uses MAJOR.MINOR.PATCH.

- **PATCH** (2.8.14 → 2.8.15) — bugfixes, new stdlib symbols, new IR opcodes
  (IR is not stable), doc fixes. No removals. Existing programs keep
  compiling and running unchanged.
- **MINOR** (2.8.x → 2.9.0) — intentional breaking changes: removed stdlib
  functions, changed defaults, changed struct layout rules, syntax tweaks,
  anything that could break an existing source file. Announced in the
  `CHANGELOG.md` "Breaking changes" section.
- **MAJOR** (2.x.y → 3.0.0) — reserved for the 1.0-equivalent stabilization
  milestone. At 1.0, the scope of "ABI" in this document becomes a hard
  contract.

## What is explicitly **not** stable

- **IR opcode numbers.** Don't hand-write IR.
- **Name mangling.** KernRift has none today; if we add it, it will not be
  retroactively stable.
- **Symbol visibility rules.** Currently, everything is global and
  externally visible. The `@export` annotation is accepted but does not
  change behavior. This will change.
- **Debug info format.** No DWARF / CodeView yet; the roadmap calls for
  DWARF 4 eventually. Format will stabilize separately from source.
- **Allocator behavior.** `alloc` / `dealloc` call through to
  `mmap` + a slab today. Programs must not rely on consecutive allocations
  returning nearby pointers, nor on freed memory being immediately
  reusable.
- **Error messages.** Both text and exit codes can change in any release.

## Cross-compilation compatibility

A KernRift program compiled for target A and a KernRift program compiled
for target B are fully ABI-compatible *only* when:

1. `A == B`, OR
2. Both targets share the same platform ABI (e.g., Linux x86_64 and
   Alpine x86_64), AND
3. Both were built by the same `kernriftc` version, OR versions that share
   the same MINOR (2.8.x ↔ 2.8.y).

Fat binaries (KrboFat v2) work across targets by shipping one slice per
target; they do not attempt to unify the ABI.

## Breaking-change process

Breaking changes require, in order:

1. A discussion issue on GitHub with a "breaking" label.
2. A deprecation period of at least one MINOR release, when feasible.
3. A `CHANGELOG.md` entry under "Breaking changes" with migration notes.
4. A migration guide in `docs/migrations/` for non-trivial changes.

Emergency breakage (security, correctness) may skip step 2 with a
rationale in the changelog entry.

## Reporting ABI bugs

If a KernRift program calls into C (or vice versa) and the ABI appears
violated, that is a bug. Reproduce with:

```
$ kernriftc --emit=asm file.kr -o file.s
$ # compare the generated prologue / epilogue against the ABI spec
```

File at https://github.com/Pantelis23/KernRift with both the `.kr` source,
the `.s` output, and the target triple.
