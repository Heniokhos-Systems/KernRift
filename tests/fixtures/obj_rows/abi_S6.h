struct S6 { unsigned short a; unsigned short b; unsigned short c; };
unsigned long long f(unsigned long long);
unsigned long long k_arg(struct S6 q);
struct S6 k_ret(unsigned long long x);
unsigned long long c_arg(struct S6 q) { unsigned long long s = (unsigned long long)q.a * 100 + (unsigned long long)q.b * 10 + (unsigned long long)q.c * 1; q.a = 9; return s; }
struct S6 c_ret(unsigned long long x) { struct S6 r; r.a = x + 0; r.b = x + 1; r.c = x + 2; return r; }
static int body(void) {
  unsigned long long bad = 0;
#if MODE == 1
  bad = f(1);
#endif
#if MODE == 4
  bad = f(4);
#endif
#if MODE == 8
  struct S6 t; t.a = 1; t.b = 2; t.c = 3;
  if (k_arg(t) != 123) bad |= 8;
  if (t.a != 1) bad |= 16;
#endif
#if MODE == 32
  struct S6 u = k_ret(5);
  if ((unsigned long long)u.a * 100 + (unsigned long long)u.b * 10 + (unsigned long long)u.c * 1 != 567) bad |= 32;
#endif
  return (int)bad; }
