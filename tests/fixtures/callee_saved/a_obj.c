/* #235 / #226 (M3): freestanding arm64 Linux C caller of a KernRift -c
   object f(5) (asm_legacy_obj_callee_saved_arm64, asm_legacy_obj_lr_arm64):
   x19, x21 and x28 hold sentinels across the call. Exit 7 = preserved;
   119/121/128 = that register destroyed; 110 = wrong result. */
extern unsigned long f(unsigned long);
static void sys_exit(long c) { register long x0 asm("x0") = c; register long x8 asm("x8") = 93; __asm__ volatile("svc #0" :: "r"(x0), "r"(x8)); for(;;); }
void _start(void) {
    register unsigned long k19 asm("x19") = 0x1919;
    register unsigned long k21 asm("x21") = 0x2121;
    register unsigned long k28 asm("x28") = 0x2828;
    __asm__ volatile("" : "+r"(k19), "+r"(k21), "+r"(k28));
    unsigned long r = f(5);
    __asm__ volatile("" : "+r"(k19), "+r"(k21), "+r"(k28));
    if (r != 5) sys_exit(110);
    if (k19 != 0x1919) sys_exit(119);
    if (k21 != 0x2121) sys_exit(121);
    if (k28 != 0x2828) sys_exit(128);
    sys_exit(7);
}
