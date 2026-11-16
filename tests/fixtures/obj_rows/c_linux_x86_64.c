/* L1 object rows (#294 #298 #299 #296): freestanding x86_64 Linux C caller of a
   KernRift -c object. f(5) is called twice, so a static's state carries over;
   exit ((a*10+b) & 255). cadd serves ext.kr. */
extern unsigned long f(unsigned long);
unsigned long cadd(unsigned long a) { return a + 1; }
static void sx(long c) { __asm__ volatile("mov $60, %%eax; syscall" :: "D"(c) : "rax"); for (;;); }
__attribute__((force_align_arg_pointer)) void _start(void) { unsigned long a = f(5), b = f(5); sx((long)((a * 10 + b) & 255)); }
