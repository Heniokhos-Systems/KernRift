/* L1 C struct ABI rows: Windows entry `start` (no CRT) around abi_<T>.h's
   body(), given with -include abi_<T>.h -DMODE=1|4|8|32. Exit = body()'s mask. */
int _fltused = 0;
int start(void) { return body(); }
