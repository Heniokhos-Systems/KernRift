/* L1 #303: k.kr (KernRift, -c) passes a 24-byte struct to cmod, which writes
   its parameter; the caller's r.a must stay 1: exit 115. */
struct R { unsigned long a, b, c; };
unsigned long cmod(struct R q) { unsigned long s = q.a * 10 + q.b + q.c; q.a = 9; return s; }
extern unsigned long f(unsigned long);
static void sx(long c) { register long x0 asm("x0") = c; register long x8 asm("x8") = 93; __asm__ volatile("svc #0" :: "r"(x0), "r"(x8)); for (;;); }
void _start(void) { sx((long)f(5)); }
