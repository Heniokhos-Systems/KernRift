/* L1 #303 control: C passes a 24-byte struct to g.kr's g, which writes its
   parameter; C's own r.a must stay 1: exit r.a*100 + 14 = 114. */
struct R { unsigned long long a, b, c; };
extern unsigned long long g(struct R q);
static void sx(long c) { register long x0 asm("x0") = c; register long x8 asm("x8") = 93; __asm__ volatile("svc #0" :: "r"(x0), "r"(x8)); for (;;); }
void _start(void) { struct R r = {1, 2, 3}; unsigned long long v = g(r); sx((long)(r.a * 100 + v)); }
