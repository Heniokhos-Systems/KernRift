/* L1 COFF object rows (#149 #296 #298 #299): Windows C caller (entry `start`,
   no CRT) of a KernRift --emit=obj object. f(5) is called twice; exit
   ((a*10+b) & 255). No floats, so no _fltused (the arm64 rows use it too). */
extern unsigned long long f(unsigned long long);
unsigned long long cadd(unsigned long long a) { return a + 1; }
int start(void) { unsigned long long a = f(5), b = f(5); return (int)((a * 10 + b) & 255); }
