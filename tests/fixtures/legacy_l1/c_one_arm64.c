/* L1 one-call C caller of a KernRift -c object (loop and #248 object rows): exit f(5). */
extern unsigned long f(unsigned long);
static void sys_exit(long c) { register long x0 asm("x0") = c; register long x8 asm("x8") = 93; __asm__ volatile("svc #0" :: "r"(x0), "r"(x8)); for(;;); }
void _start(void) { sys_exit((long)f(5)); }
