/* L1 C struct ABI rows: hosted macOS main around abi_<T>.h's body(), given
   with -include abi_<T>.h -DMODE=1|4|8|32. Exit = body()'s mask. */
int main(void) { return body(); }
