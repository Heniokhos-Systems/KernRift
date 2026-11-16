struct S20 { unsigned int a; unsigned int b; unsigned int c; unsigned int d; unsigned int e; };
unsigned long long f(unsigned long long);
unsigned long long k_arg(struct S20 q);
struct S20 k_ret(unsigned long long x);
unsigned long long c_arg(struct S20 q) { unsigned long long s = (unsigned long long)q.a * 10000 + (unsigned long long)q.b * 1000 + (unsigned long long)q.c * 100 + (unsigned long long)q.d * 10 + (unsigned long long)q.e * 1; q.a = 9; return s; }
struct S20 c_ret(unsigned long long x) { struct S20 r; r.a = x + 0; r.b = x + 1; r.c = x + 2; r.d = x + 3; r.e = x + 4; return r; }
static int body(void) {
  unsigned long long bad = 0;
#if MODE == 1
  bad = f(1);
#endif
#if MODE == 4
  bad = f(4);
#endif
#if MODE == 8
  struct S20 t; t.a = 1; t.b = 2; t.c = 3; t.d = 4; t.e = 5;
  if (k_arg(t) != 12345) bad |= 8;
  if (t.a != 1) bad |= 16;
#endif
#if MODE == 32
  struct S20 u = k_ret(5);
  if ((unsigned long long)u.a * 10000 + (unsigned long long)u.b * 1000 + (unsigned long long)u.c * 100 + (unsigned long long)u.d * 10 + (unsigned long long)u.e * 1 != 56789) bad |= 32;
#endif
  return (int)bad; }
