# Changelog

## 2.8.27

- Syntax highlighting for all 18 annotations, up from 5. Adds the kernel-module
  and PCI-driver set (`@module_init`, `@module_exit`, `@module_license`,
  `@module_register_misc_device`, `@module_register_pci_driver`,
  `@lkm_ioctl_handler`, `@lkm_mmap_handler`, `@pci_probe_handler`,
  `@pci_remove_handler`, ...) plus `@builtin_override`.
- Highlights 22 more built-ins (82 of 82): the float conversions and math
  (`sqrt`, `sqrt_f32`, `sqrt_f64`, `fma_f64`, `f32_to_f64`, `int_to_f64`, ...),
  barriers and cache maintenance (`dmb`, `dsb`, `isb`, `dcache_flush`,
  `icache_invalidate`), `time_ns`, `read`, `bit_toggle`, `call_ptr_f64` and
  `exec_process_argv`.
- Version realigned with the compiler (was 2.7.0 against a 2.8.27 toolchain).

## 2.7.0

- Security: bump `esbuild` to `^0.25.0` to fix GHSA-67mh-4wv8-2f99 (dev-server CORS issue). No runtime impact for end users; the dev server is never exercised by the published extension, but the alert is cleared.
- Bump `engines.vscode` from `^1.80.0` to `^1.90.0` (May 2024 baseline; broad coverage with modern API).
- Bump `@types/node` to `^22.0.0` (current LTS).
- Bump `typescript` to `^5.6.3`.
- Update repository URL to `Rift-Intelligence/KernRift` (org migration).
- Add `.vscodeignore` and `engines.node` declaration.

## 2.6.2 and earlier

See git history.
