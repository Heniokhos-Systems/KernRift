/* #143 A13 (spec 8.4/8.5): the clang host of the KR COFF probe.
   Derived from the reviewer's scratch ~/.cache/pe_unwind_review/t/cprobe/host.c
   (sha256 d81a20aab22246f39301ea5106682f31a16bbc7ec9802332ddc12f62d5b7f750): the same start()/walk()
   pair, with walk() also printing each captured frame -- its address and the
   module that holds it (GetModuleHandleExA FROM_ADDRESS|UNCHANGED_REFCOUNT +
   GetModuleFileNameA), "-" when it is in none -- so the suite row can name the
   chain through lld-link's /map (phase-4 ruling (a)). Since T1 (#327) each
   line also carries that module's load base (the HMODULE GetModuleHandleExA
   returns IS the base): `<pc> <module base | -> <module path | ->`, so an
   image frame is named by its offset from the base the image was really
   loaded at (tests/helpers/probe_chain.py). Before, the row looked the
   absolute pc up in the map, which only holds at the preferred base (Wine);
   natively ASLR moved the image and every frame came out as `main`. The exit
   code is still RtlCaptureStackBackTrace's count. Built with clang
   --target=x86_64-pc-windows-msvc -O1 and linked lld-link /nodefaultlib
   /entry:start against the import library from k32.def. */
typedef unsigned short USHORT; typedef unsigned long ULONG;
__declspec(dllimport) USHORT __stdcall RtlCaptureStackBackTrace(ULONG, ULONG, void**, ULONG*);
__declspec(dllimport) void __stdcall ExitProcess(unsigned);
__declspec(dllimport) void* __stdcall GetStdHandle(ULONG);
__declspec(dllimport) int __stdcall WriteFile(void*, const void*, ULONG, ULONG*, void*);
__declspec(dllimport) int __stdcall GetModuleHandleExA(ULONG, const char*, void**);
__declspec(dllimport) ULONG __stdcall GetModuleFileNameA(void*, char*, ULONG);
static void out(const char* p, ULONG n) { ULONG w; WriteFile(GetStdHandle((ULONG)-11), p, n, &w, 0); }
static void hex16(char* b, unsigned long long v) {
    int i;
    for (i = 0; i < 16; i++) { int d = (v >> (60 - 4 * i)) & 15; b[i] = d < 10 ? '0' + d : 'a' + d - 10; }
}
static void frame(void* pc) {
    char b[300]; int k; void* m = 0; ULONG n = 0;
    hex16(b, (unsigned long long)pc);
    b[16] = ' ';
    if (pc && GetModuleHandleExA(6, (const char*)pc, &m) && m) { hex16(b + 17, (unsigned long long)m); k = 33; }
    else { b[17] = '-'; m = 0; k = 18; }
    b[k++] = ' ';
    if (m) n = GetModuleFileNameA(m, b + k, 260);
    if (n == 0) { b[k] = '-'; n = 1; }
    b[k + n] = '\n';
    out(b, k + n + 1);
}
unsigned long long walk(void) {
    void* f[32]; USHORT i, n = RtlCaptureStackBackTrace(0, 32, f, 0);
    for (i = 0; i < n; i++) frame(f[i]);
    return n;
}
int main(void);
void start(void) { ExitProcess(main()); }
