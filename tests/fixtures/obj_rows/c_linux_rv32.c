/* L1 object rows (#294): freestanding riscv32 Linux C caller of a KernRift -c
   object (multir.kr). f(5) is called twice; exit ((a*10+b) & 255). */
extern unsigned int f(unsigned int);
static void sx(long c) { register long a0 asm("a0") = c; register long a7 asm("a7") = 93; __asm__ volatile("ecall" :: "r"(a0), "r"(a7)); for (;;); }
void _start(void) { unsigned int a = f(5), b = f(5); sx((long)((a * 10 + b) & 255)); }
