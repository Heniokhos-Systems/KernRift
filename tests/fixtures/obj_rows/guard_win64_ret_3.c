/* L1 #315: the same as guard_win64_ret_12.c for a 3-byte struct (abi_U3.kr). */
int _fltused = 0;
unsigned long long c_arg(void) { return 0; } void c_ret(void) { }
extern void *k_ret(void *buf, unsigned long long x);
int start(void) { unsigned char buf[4] = {0, 0, 0, 0x77};
  void *r = k_ret(buf, 5); int bad = 0;
  if (r != (void *)buf) bad |= 1; if (buf[0] != 5 || buf[2] != 7) bad |= 2; if (buf[3] != 0x77) bad |= 4; return bad; }
