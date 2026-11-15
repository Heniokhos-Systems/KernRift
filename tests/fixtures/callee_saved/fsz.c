/* #241 (M3): freestanding arm64 Linux C caller of a KernRift -c leaf that
   calls file_size (asm_legacy_obj_file_size_x19_arm64): x19 holds a sentinel
   across the call. Exit 7 = preserved, 119 = destroyed. */
extern unsigned long f(unsigned long);
static void sys_exit(long c) { register long x0 asm("x0") = c; register long x8 asm("x8") = 93; __asm__ volatile("svc #0" :: "r"(x0), "r"(x8)); for(;;); }
void _start(void) {
    register unsigned long k19 asm("x19") = 0x1919;
    __asm__ volatile("" : "+r"(k19));
    unsigned long r = f(0);
    __asm__ volatile("" : "+r"(k19));
    if (k19 != 0x1919) sys_exit(119);
    sys_exit(7);
}
