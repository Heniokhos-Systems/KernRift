/* L1 #303 control: C passes a 24-byte struct to g.kr's g, which writes its
   parameter; C's own r.a must stay 1: exit r.a*100 + 14 = 114. */
struct R { unsigned long long a, b, c; };
extern unsigned long long g(struct R q);
int start(void) { struct R r = {1, 2, 3}; unsigned long long v = g(r); return (int)(r.a * 100 + v); }
