/* L1 object rows (#294 #298 #299 #296): freestanding arm64 Linux C caller of a
   KernRift -c object. f(5) is called twice; exit ((a*10+b) & 255). */
extern unsigned long f(unsigned long);
unsigned long cadd(unsigned long a) { return a + 1; }
static void sx(long c) { register long x0 asm("x0") = c; register long x8 asm("x8") = 93; __asm__ volatile("svc #0" :: "r"(x0), "r"(x8)); for (;;); }
void _start(void) { unsigned long a = f(5), b = f(5); sx((long)((a * 10 + b) & 255)); }
