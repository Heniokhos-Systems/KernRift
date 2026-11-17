struct S8 { unsigned long long a; };
unsigned long long f(unsigned long long);
unsigned long long k_arg(struct S8 q);
struct S8 k_ret(unsigned long long x);
unsigned long long c_arg(struct S8 q) { unsigned long long s = (unsigned long long)q.a * 100; q.a = 9; return s; }
struct S8 c_ret(unsigned long long x) { struct S8 r; r.a = x + 0; return r; }
static int body(void) {
  unsigned long long bad = 0;
#if MODE == 1
  bad = f(1);
#endif
#if MODE == 4
  bad = f(4);
#endif
#if MODE == 8
  struct S8 t; t.a = 1;
  if (k_arg(t) != 100) bad |= 8;
  if (t.a != 1) bad |= 16;
#endif
#if MODE == 32
  struct S8 u = k_ret(5);
  if ((unsigned long long)u.a * 100 != 500) bad |= 32;
#endif
  return (int)bad; }
