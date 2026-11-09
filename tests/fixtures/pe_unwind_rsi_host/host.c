/* #160 known red (#143 A16, re-review finding 10): a C host keeps a value in
   rsi across a call into KernRift. Win64 makes rsi nonvolatile, but KernRift
   code uses it as scratch (here the legacy f-string's `lea rsi` / `rep movsb`;
   in IR code the wide colour file), so a C or OS caller loses it.
   probe() puts a sentinel in rsi, calls the KR object's main(), and returns
   what rsi holds afterwards; start() exits 40 when the sentinel survived and
   41 when it did not. Built with clang --target=x86_64-pc-windows-msvc -O1,
   linked lld-link /nodefaultlib /entry:start against the import library from
   ../pe_unwind_cprobe/k32.def. probe() is asm so that the compiler cannot
   keep the sentinel anywhere else. */
__declspec(dllimport) void __stdcall ExitProcess(unsigned);
unsigned long long probe(void);
__asm__(".text\n.globl probe\nprobe:\n"
        "  push %rsi\n"
        "  sub $32, %rsp\n"
        "  movabs $0x5a5a1234c3c3abcd, %rsi\n"
        "  call main\n"
        "  mov %rsi, %rax\n"
        "  add $32, %rsp\n"
        "  pop %rsi\n"
        "  ret\n");
int main(void);
void start(void) { ExitProcess(probe() == 0x5a5a1234c3c3abcdULL ? 40 : 41); }
