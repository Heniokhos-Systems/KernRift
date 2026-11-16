/* L1 #315 (shared copy loop): an x86_64 SysV KernRift function returning a
   20-byte MEMORY-class struct (abi_S20.kr's k_ret, result pointer in rdi)
   writes exactly 20 bytes. Exit 0; 1/2/4 as in guard_win64_ret_12.c. */
extern void *k_ret(void *buf, unsigned long long x);
unsigned long long c_arg(void) { return 0; } void c_ret(void) { }
static void sx(long c) { __asm__ volatile("mov $60, %%eax; syscall" :: "D"(c) : "rax"); for (;;); }
__attribute__((force_align_arg_pointer)) void _start(void) {
  unsigned int buf[6] = {0, 0, 0, 0, 0, 0x7777}; void *r = k_ret(buf, 5); int bad = 0;
  if (r != (void *)buf) bad |= 1; if (buf[0] != 5 || buf[4] != 9) bad |= 2; if (buf[5] != 0x7777) bad |= 4; sx(bad); }
