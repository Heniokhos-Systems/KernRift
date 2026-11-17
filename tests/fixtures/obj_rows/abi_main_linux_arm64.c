/* L1 C struct ABI rows: freestanding arm64 Linux entry around abi_<T>.h's
   body(), given with -include abi_<T>.h -DMODE=1|4|8|32. Exit = body()'s mask. */
static void sx(long c) { register long x0 asm("x0") = c; register long x8 asm("x8") = 93; __asm__ volatile("svc #0" :: "r"(x0), "r"(x8)); for (;;); }
void _start(void) { sx(body()); }
