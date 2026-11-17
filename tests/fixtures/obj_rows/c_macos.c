/* L1 Mach-O object rows (#294 #301 #296 #298 #299): hosted macOS C caller of a
   KernRift -c object. f(5) is called twice; exit ((a*10+b) & 255). */
extern unsigned long f(unsigned long);
unsigned long cadd(unsigned long a) { return a + 1; }
int main(void) { unsigned long a = f(5), b = f(5); return (int)((a * 10 + b) & 255); }
