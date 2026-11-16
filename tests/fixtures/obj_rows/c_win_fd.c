/* L1 #297: C passes an f64 in xmm0 to fd.kr's fd(f64 x, u64 k): exit 2.5*4 + 2 = 12. */
int _fltused = 0;
extern unsigned long long fd(double x, unsigned long long k);
int start(void) { return (int)fd(2.5, 2); }
