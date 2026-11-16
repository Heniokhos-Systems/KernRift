struct F16 { double a; double b; };
unsigned long long f(unsigned long long);
unsigned long long k_arg(struct F16 q);
struct F16 k_ret(unsigned long long x);
unsigned long long c_arg(struct F16 q) { unsigned long long s = (unsigned long long)q.a * 100 + (unsigned long long)q.b * 10; q.a = 9; return s; }
struct F16 c_ret(unsigned long long x) { struct F16 r; r.a = x + 0; r.b = x + 1; return r; }
static int body(void) {
  unsigned long long bad = 0;
#if MODE == 1
  bad = f(1);
#endif
#if MODE == 4
  bad = f(4);
#endif
#if MODE == 8
  struct F16 t; t.a = 1; t.b = 2;
  if (k_arg(t) != 120) bad |= 8;
  if (t.a != 1) bad |= 16;
#endif
#if MODE == 32
  struct F16 u = k_ret(5);
  if ((unsigned long long)u.a * 100 + (unsigned long long)u.b * 10 != 560) bad |= 32;
#endif
  return (int)bad; }
