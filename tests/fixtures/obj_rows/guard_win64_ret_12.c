/* L1 #315: a Win64 KernRift function returning a 12-byte struct (abi_S12.kr's
   k_ret) through the caller's result pointer writes exactly 12 bytes. Exit 0;
   1 = wrong pointer returned, 2 = wrong value, 4 = the guard word after it. */
int _fltused = 0;
unsigned long long c_arg(void) { return 0; } void c_ret(void) { }
extern void *k_ret(void *buf, unsigned long long x);
int start(void) { unsigned int buf[4] = {0, 0, 0, 0x7777};
  void *r = k_ret(buf, 5); int bad = 0;
  if (r != (void *)buf) bad |= 1; if (buf[0] != 5 || buf[2] != 7) bad |= 2; if (buf[3] != 0x7777) bad |= 4; return bad; }
