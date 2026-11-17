/* L1 #315: the same as guard_win64_ret_12.c for a 20-byte struct (abi_S20.kr). */
int _fltused = 0;
unsigned long long c_arg(void) { return 0; } void c_ret(void) { }
extern void *k_ret(void *buf, unsigned long long x);
int start(void) { unsigned int buf[6] = {0, 0, 0, 0, 0, 0x7777};
  void *r = k_ret(buf, 5); int bad = 0;
  if (r != (void *)buf) bad |= 1; if (buf[0] != 5 || buf[4] != 9) bad |= 2; if (buf[5] != 0x7777) bad |= 4; return bad; }
