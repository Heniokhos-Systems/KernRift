/* L1 #309 #315: Win64 struct returns between C and ret.kr (= the note's p309/k.kr): 1/2/4/8-byte
   structs in rax, others through the result pointer in rcx. Exit 0; a set bit names the failing check. */
int _fltused = 0;
typedef unsigned long long u64;
struct R4 { unsigned a; }; struct D8 { double d; }; struct T12 { unsigned a, b, c; };
struct R4 c_r4(u64 x) { struct R4 r = { (unsigned)x + 7 }; return r; }
struct D8 c_d8(u64 x) { struct D8 r = { (double)x + 0.5 }; return r; }
struct T12 c_t12(u64 a, u64 b, u64 c, u64 d, u64 e) { struct T12 r = { (unsigned)(a + b), (unsigned)(c + d), (unsigned)e }; return r; }
struct R4 k_r4(u64); struct D8 k_d8(u64); struct T12 k_t12(u64, u64, u64, u64, u64); u64 f(u64);
int start(void) {
  int bad = (int)f(0);
  if (k_r4(5).a != 12) bad |= 32;
  if (k_d8(5).d != 5.5) bad |= 64;
  struct T12 t = k_t12(1, 2, 3, 4, 5);
  if (t.a != 3 || t.b != 7 || t.c != 5) bad |= 128;
  return bad;
}
