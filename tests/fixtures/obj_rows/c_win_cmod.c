/* L1 #303: k.kr (KernRift) calls cmod with a 24-byte struct; cmod writes its
   parameter. The caller's r.a must stay 1: exit r.a*100 + 15 = 115. */
struct R { unsigned long long a, b, c; };
unsigned long long cmod(struct R q) { unsigned long long s = q.a * 10 + q.b + q.c; q.a = 9; return s; }
extern unsigned long long f(unsigned long long);
int start(void) { return (int)f(5); }
