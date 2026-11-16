/* L1 #303/#306: k.kr (KernRift, -c) passes a 24-byte struct to cmod, which
   writes its parameter; the caller's r.a must stay 1: exit 115. */
struct R { unsigned long a, b, c; };
unsigned long cmod(struct R q) { unsigned long s = q.a * 10 + q.b + q.c; q.a = 9; return s; }
extern unsigned long f(unsigned long);
static void sx(long c) { __asm__ volatile("mov $60, %%eax; syscall" :: "D"(c) : "rax"); for (;;); }
__attribute__((force_align_arg_pointer)) void _start(void) { sx((long)f(5)); }
