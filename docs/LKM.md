# Linux Kernel Modules (`--emit=lkm`)

KernRift can compile a `.kr` source file directly into a Linux loadable
kernel module — a `.ko` you `insmod` into a running kernel. No C toolchain,
no kernel headers, no Kbuild: the compiler emits the relocatable ELF, the
`.modinfo` strings, the `struct module` section, and the
`init_module` / `cleanup_module` symbols itself.

This is **experimental, pre-1.0 functionality**. What works today, verified
on real hardware:

- Hello-world modules that print to `dmesg` on insmod/rmmod.
- Misc character devices (`/dev/<name>`) with `ioctl` and `mmap` handlers
  written in KernRift.
- Real PCI drivers: probe/remove handlers, BAR mapping into userland via
  `remap_pfn_range`, user-page pinning, IOMMU map/unmap, MSI-X interrupts.
- `alloc()` / `dealloc()` inside kernel code (lowered to the kernel slab
  allocator automatically).

What doesn't: anything not x86_64, kernels far from 6.x, module parameters,
reading kernel data symbols. See [Limitations](#limitations--caveats) for the
honest list. Kernel code runs in ring 0 — a bug can panic or wedge the
machine, so develop in a VM you can afford to lose.

If you just want a hello module loading in `dmesg`, the walkthrough below is
all you need.

---

## Quick walkthrough

The canonical example is
[`examples/hello_lkm.kr`](../examples/hello_lkm.kr):

```kr
@module_license("GPL")
@module_author("KernRift Phase A.1")
@module_description("Hello-world LKM emitted by the KernRift compiler")
@module_name("hello_kr")

// Modern kernels (4.20+) export `_printk`; the unprefixed `printk` is a
// C macro. Declaring `printk` gets you "Unknown symbol" at load time.
extern fn _printk(uint64 fmt) -> int32

@module_init
fn hello_init() -> int32 {
    _printk("Hello from KernRift\n")
    return 0
}

@module_exit
fn hello_exit() {
    _printk("Bye from KernRift\n")
}
```

Build it:

```bash
krc --emit=lkm --arch=x86_64 --target=linux examples/hello_lkm.kr -o hello.ko
```

(`--arch`/`--target` are optional on an x86_64 Linux host; `--emit=lkm`
alone works. The flag is rejected with an error on any other architecture.)

Load, observe, unload:

```bash
sudo insmod hello.ko
dmesg | tail -5          # → "Hello from KernRift"
sudo rmmod hello_kr      # rmmod takes the @module_name, not the file name
dmesg | tail -5          # → "Bye from KernRift"
```

Use plain `insmod` — **not** `insmod -f`. Force-loading disables the
modversions path and, on kernels built with `CONFIG_MODULE_FORCE_LOAD=n`
(Ubuntu, Debian), fails with a silent `-ENOEXEC`. With plain `insmod` you
may see one harmless warning in `dmesg`:

```
hello_kr: no extended symbol version for module_layout
```

That is expected — the module carries empty extended-version sections, the
kernel iterates zero entries and proceeds.

You can inspect the result with the usual binutils:

```bash
modinfo hello.ko          # license, author, description, vermagic, ...
readelf -p .modinfo hello.ko
readelf -r hello.ko       # relocations against kernel symbols
```

---

## Annotation reference

All annotations go immediately before the declaration they apply to.
Module-wide annotations take a string argument and may appear anywhere at
the top level (conventionally at the top of the file); per-function
annotations take no arguments and tag the `fn` that follows.

### Module metadata

| Annotation | What it does | Arguments | Example |
|---|---|---|---|
| `@module_license("...")` | Sets `license=` in `.modinfo`. Use `"GPL"` to resolve GPL-only exports (`_printk`, `misc_register`, the `iommu_*` family are all GPL-only). | string | `@module_license("GPL")` |
| `@module_author("...")` | Sets `author=` in `.modinfo`; shows up in `modinfo`. Optional. | string | `@module_author("Jane Doe")` |
| `@module_description("...")` | Sets `description=` in `.modinfo`. Optional. | string | `@module_description("My driver")` |
| `@module_name("...")` | The module's name: written into `struct module.name`, `.modinfo`'s `name=`, and what you pass to `rmmod`. Defaults to `kernrift_module` if omitted. | string | `@module_name("hello_kr")` |

### Lifecycle (classic mode)

| Annotation | What it does | Arguments | Example |
|---|---|---|---|
| `@module_init` | Tags the function the kernel calls at `insmod`. It becomes the module's `init_module`. Signature: `fn() -> int32`; return `0` for success, a negative errno to refuse loading. | none (per-function) | `@module_init fn my_init() -> int32 { ... }` |
| `@module_exit` | Tags the function the kernel calls at `rmmod` (`cleanup_module`). Signature: `fn()`. In misc-device mode (below) it instead becomes an optional teardown hook. | none (per-function) | `@module_exit fn my_exit() { ... }` |

In classic mode both `@module_init` and `@module_exit` are required; the
compiler errors out if either is missing.

### Misc device / ioctl / mmap

`@module_register_misc_device` switches the module into **misc-device
mode**: the compiler auto-generates `init_module` / `cleanup_module` bodies
that call `misc_register` / `misc_deregister` on a statically emitted
`struct miscdevice` + `struct file_operations`, so loading the module makes
`/dev/<name>` appear (dynamic minor, major 10) and unloading removes it.

| Annotation | What it does | Arguments | Example |
|---|---|---|---|
| `@module_register_misc_device("name")` | Module-wide. Registers `/dev/<name>` on load. Auto-generates init/exit; `@module_init` is **forbidden** in this mode, `@module_exit` becomes an optional teardown hook run before `misc_deregister`. Requires an `@lkm_ioctl_handler` and the two externs below. | string (device name) | `@module_register_misc_device("mydev")` |
| `@lkm_ioctl_handler` | Tags the function wired into `file_operations.unlocked_ioctl`. Userland `ioctl()` on the device dispatches here. Signature: `fn(uint64 file, uint64 cmd, uint64 arg) -> int64`. Required in misc-device mode. | none (per-function) | see below |
| `@lkm_mmap_handler` | Tags the function wired into `file_operations.mmap`. Userland `mmap()` of the device dispatches here. Signature: `fn(uint64 file, uint64 vma) -> int64`. Optional. | none (per-function) | see below |

Misc-device mode requires these extern declarations in the source (the
auto-generated init/exit call them):

```kr
extern fn misc_register(uint64 dev) -> int32
extern fn misc_deregister(uint64 dev) -> int32
```

A minimal device with an ioctl
([`examples/lkm_kmalloc_test.kr`](../examples/lkm_kmalloc_test.kr) is the
full version):

```kr
@module_license("GPL")
@module_name("mydev")
@module_register_misc_device("mydev")

extern fn _printk(uint64 fmt) -> int32
extern fn misc_register(uint64 dev) -> int32
extern fn misc_deregister(uint64 dev) -> int32

@lkm_ioctl_handler
fn driver_ioctl(uint64 file, uint64 cmd, uint64 arg) -> int64 {
    if cmd == 0x4B01 {
        _printk("mydev: ping\n")
        return 0
    }
    return 0xFFFFFFFFFFFFFFE7   // -ENOTTY = -25
}
```

Errno returns are plain negative numbers in two's complement — write them
as 64-bit hex constants (`-25` = `0xFFFFFFFFFFFFFFE7`, `-22 (EINVAL)` =
`0xFFFFFFFFFFFFFFEA`, `-12 (ENOMEM)` = `0xFFFFFFFFFFFFFFF4`).

An mmap handler ([`examples/lkm_mmap_test.kr`](../examples/lkm_mmap_test.kr)):

```kr
@lkm_mmap_handler
fn drv_mmap(uint64 file, uint64 vma) -> int64 {
    // Real drivers call remap_pfn_range(vma, vm_start, pfn, size, prot)
    // here; see examples/mlrift_pci.kr for a full BAR-mapping handler.
    return 0xFFFFFFFFFFFFFFEA   // -EINVAL
}
```

### PCI driver

`@module_register_pci_driver` layers **PCI-driver mode** on top of
misc-device mode (use both together — the auto-generated init/exit bodies
host the registration calls). The compiler emits a `struct pci_driver` into
`.data`, wires your probe/remove handlers into it, calls
`__pci_register_driver` during init and `pci_unregister_driver` during
cleanup.

| Annotation | What it does | Arguments | Example |
|---|---|---|---|
| `@module_register_pci_driver("name")` | Module-wide. Registers a `struct pci_driver` named `name` on load, unregisters on unload. Requires `@pci_probe_handler`, `@pci_remove_handler`, and the two externs below. Conflicts with a `@module_exit` teardown hook (compiler error). | string (driver name) | `@module_register_pci_driver("mydrv")` |
| `@pci_probe_handler` | Tags the `.probe` callback — called when a matching PCI device is bound to the driver. Signature: `fn(uint64 pdev, uint64 id) -> int64`; return `0` to claim the device. | none (per-function) | see below |
| `@pci_remove_handler` | Tags the `.remove` callback — called on unbind / `rmmod`. Signature: `fn(uint64 pdev)`. | none (per-function) | see below |

Required externs:

```kr
extern fn __pci_register_driver(uint64 drv, uint64 owner, uint64 name) -> int32
extern fn pci_unregister_driver(uint64 drv)
```

The smallest complete PCI driver is
[`examples/pci_driver_smoke.kr`](../examples/pci_driver_smoke.kr):

```kr
@module_license("GPL")
@module_name("pci_drv_smoke")
@module_register_misc_device("pci_drv_smoke")
@module_register_pci_driver("pci_drv_smoke")

extern fn _printk(uint64 fmt) -> int32
extern fn misc_register(uint64 dev) -> int32
extern fn misc_deregister(uint64 dev) -> int32
extern fn __pci_register_driver(uint64 drv, uint64 owner, uint64 name) -> int32
extern fn pci_unregister_driver(uint64 drv)

@pci_probe_handler
fn driver_probe(uint64 pdev, uint64 id) -> int64 {
    _printk("pci_drv_smoke: probe\n")
    return 0
}

@pci_remove_handler
fn driver_remove(uint64 pdev) {
    _printk("pci_drv_smoke: remove\n")
}

@lkm_ioctl_handler
fn driver_ioctl(uint64 file, uint64 cmd, uint64 arg) -> int64 {
    return 0xFFFFFFFFFFFFFFE7
}
```

---

## Calling into the kernel

### Extern kernel symbols

Inside an LKM, `extern fn` declarations resolve against the running
kernel's exported symbols instead of libc. The compiler emits standard
`R_X86_64_PLT32` relocations; the kernel's module loader resolves them at
`insmod` time. Rules of thumb:

- **Use the real exported name.** `printk` is a C macro — the export is
  `_printk`. Same for `_copy_from_user` / `_copy_to_user` on recent
  kernels. Check with `grep <name> /proc/kallsyms` or
  `nm /usr/lib/debug/boot/vmlinux-$(uname -r)` if in doubt.
- **GPL-only exports need `@module_license("GPL")`** — otherwise the
  loader rejects the symbol reference.
- **The ABI is x86_64 System V**, same as the kernel's: args in
  `rdi, rsi, rdx, rcx, r8, r9`, the 7th and beyond on the stack
  (verified working — e.g. the 7-argument
  `sg_alloc_table_from_pages_segment`).
- **Kernel `int` returns occupy `eax` only**; the upper 32 bits of the
  64-bit value KernRift sees are undefined. Mask with `& 0xFFFFFFFF` (and
  sign-check) at the call site when a kernel function returns `int`.
- Only extern **calls** are supported — you cannot read kernel data
  symbols (e.g. `page_offset_base`, `vmemmap_base`). Prefer kernel APIs
  that do the address math for you (`iommu_map_sg` over `iommu_map`,
  reading `pci_dev` resources directly, etc.).

[`examples/mlrift_pci.kr`](../examples/mlrift_pci.kr) is the kitchen-sink
reference: `copy_from_user`/`copy_to_user`, `remap_pfn_range`,
`pin_user_pages_fast`, the scatter-gather and `iommu_*` families, and MSI-X
setup, all via `extern fn`.

### Heap allocation in kernel context

`alloc()` and `dealloc()` work inside LKM functions. Under `--emit=lkm`
they lower to the kernel slab allocator — `__kmalloc_noprof(size,
GFP_KERNEL)` and `kfree(ptr)` — instead of the userland `mmap`/`munmap`
syscalls (a `syscall` instruction from ring 0 panics the kernel). No extern
declarations are needed; the compiler adds the two symbols to the `.ko`
automatically when used. You can verify a module is syscall-free with:

```bash
objdump -d -M intel my.ko | grep -c syscall   # must print 0
```

Note `GFP_KERNEL` allocations may sleep — don't `alloc()` in atomic
context (e.g. interrupt handlers).

### vermagic and modinfo

The kernel refuses modules whose `vermagic` string doesn't match its own.
KernRift builds it **at compile time** by reading
`/proc/sys/kernel/osrelease` on the build host and appending the fixed
Ubuntu/Debian suffix:

```
vermagic=<host kernel release> SMP preempt mod_unload modversions
```

Consequences:

- A `.ko` is built for **the kernel of the machine you compile on**. Move
  it to a box running a different kernel release and `insmod` will reject
  it (`disagrees about version of symbol module_layout` / invalid format).
  Recompile on (or for) the target.
- The suffix assumes a typical distro config (`SMP`, `preempt`,
  `mod_unload`, `modversions`). Kernels built differently won't match.

The emitted `.modinfo` carries `license`, `author`, `description`, `name`,
`depends=` (always empty — no inter-module dependencies), `retpoline=Y`
(KernRift emits direct calls only, which are retpoline-safe by
construction), a placeholder `srcversion`, and the `vermagic`. All of it is
visible via `modinfo my.ko`.

### What's inside the .ko

For the curious: the output is a relocatable ELF (`ET_REL`) containing
`.text` (your code plus any auto-generated init/cleanup bodies), `.data`
(statics plus the auto-emitted `miscdevice` / `file_operations` /
`pci_driver` structs), `.modinfo`, `.gnu.linkonce.this_module` (a
`struct module` image — 1280 bytes on 6.x x86_64, with the name at offset
24 and init/exit pointers fixed up via relocations), a symbol table
exposing `init_module`, `cleanup_module` and `__this_module`, and the
`.rela` sections tying it all together. It is a normal object file:
`readelf`, `objdump` and `modinfo` all work on it.

---

## Limitations & caveats

This is experimental. Known constraints, in rough order of how likely they
are to bite:

- **x86_64 only.** `--emit=lkm` errors out for arm64
  (`krc: --emit=lkm currently supports x86_64 only`).
- **Kernel 6.x assumed.** Internal struct layouts are baked in for 6.x
  x86_64 (verified against 6.17): `struct module` size/offsets,
  `file_operations.unlocked_ioctl` @ 0x50 and `.mmap` @ 0x60,
  `struct miscdevice`, `struct pci_driver`. Older kernels (5.x and below)
  have different layouts — loading there is untested and may misbehave in
  ways worse than a clean load failure.
- **vermagic targets the build host's kernel** (see above). No flag yet to
  override the target kernel release.
- **No modversions CRCs.** The extended-version sections are present but
  empty; the one-time `no extended symbol version for module_layout`
  warning in `dmesg` is expected. `srcversion` is a fixed placeholder
  (only an issue on kernels built with `CONFIG_MODULE_SRCVERSION_ALL=y`).
- **Plain `insmod` only** — `-f`/force-load silently fails on distro
  kernels (`CONFIG_MODULE_FORCE_LOAD=n`).
- **No module parameters** (`module_param`), no sysfs attributes, no
  devicetree.
- **Extern calls only, no extern data** — kernel variables can't be read,
  which rules out the `virt_to_phys` / `page_to_phys` macro family.
- **One handler each**: a single `@lkm_ioctl_handler`, optionally one
  `@lkm_mmap_handler`, one probe, one remove. Other `file_operations`
  callbacks (read/write/poll/open/release) are not wireable yet.
- **Annotation conflicts are compile errors**: `@module_init` with
  `@module_register_misc_device`; a `@module_exit` teardown hook with
  `@module_register_pci_driver`.
- **PCI-driver mode has no device-ID table** — the emitted driver matches
  nothing automatically; bind devices explicitly via
  `/sys/bus/pci/drivers/<name>/bind` (see
  `examples/mlrift_pci_driver_test.sh`).
- **It's ring 0.** Logic errors don't segfault, they oops or panic. Use a
  VM, keep `dmesg -w` open, and treat every new ioctl path as hostile
  until proven otherwise.

---

## See also

- [`examples/hello_lkm.kr`](../examples/hello_lkm.kr) — minimal
  init/exit module (start here).
- [`examples/lkm_kmalloc_test.kr`](../examples/lkm_kmalloc_test.kr) —
  misc device + ioctl + kernel-heap `alloc()`/`dealloc()`.
- [`examples/lkm_mmap_test.kr`](../examples/lkm_mmap_test.kr) —
  `@lkm_mmap_handler` wiring proof.
- [`examples/pci_driver_smoke.kr`](../examples/pci_driver_smoke.kr) —
  smallest complete PCI driver.
- [`examples/mlrift_pci.kr`](../examples/mlrift_pci.kr) — full
  production-shaped driver: ioctls, BAR mmap, page pinning, IOMMU
  map/unmap, MSI-X. With a C userland test
  ([`examples/mlrift_pci_test.c`](../examples/mlrift_pci_test.c)) and a
  driver-binding script
  ([`examples/mlrift_pci_driver_test.sh`](../examples/mlrift_pci_driver_test.sh)).
- [`docs/LANGUAGE.md`](LANGUAGE.md) — §19 Annotations, §24 Extern
  functions, §25 Binary formats.
- [`CHANGELOG.md`](../CHANGELOG.md) — release notes; LKM support landed
  in May 2026 and is not yet part of a tagged release.
