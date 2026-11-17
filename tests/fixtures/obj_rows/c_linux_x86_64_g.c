/* L1 #306: C passes a 24-byte struct by value to g.kr's g, which writes its
   parameter; C's own r.a must stay 1: exit r.a*100 + 14 = 114. */
struct R { unsigned long long a, b, c; };
extern unsigned long long g(struct R q);
static void sx(long c) { __asm__ volatile("mov $60, %%eax; syscall" :: "D"(c) : "rax"); for (;;); }
__attribute__((force_align_arg_pointer)) void _start(void) { struct R r = {1, 2, 3}; unsigned long long v = g(r); sx((long)(r.a * 100 + v)); }
