/* L1 C struct ABI rows: freestanding x86_64 Linux entry around abi_<T>.h's
   body(), given with -include abi_<T>.h -DMODE=1|4|8|32. Exit = body()'s mask. */
static void sx(long c) { __asm__ volatile("mov $60, %%eax; syscall" :: "D"(c) : "rax"); for (;;); }
__attribute__((force_align_arg_pointer)) void _start(void) { sx(body()); }
