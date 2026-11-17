/* L1 one-call C caller of a KernRift -c object (loop and #248 object rows): exit f(5). */
extern unsigned long f(unsigned long);
static void sys_exit(long c) { __asm__ volatile("mov $60, %%eax; syscall" :: "D"(c) : "rax"); for(;;); }
__attribute__((force_align_arg_pointer)) void _start(void) { sys_exit((long)f(5)); }
