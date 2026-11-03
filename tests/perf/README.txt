tests/perf -- #143's binding performance metric (spec 9, plan A15): guest
instruction counts under qemu-user (-one-insn-per-tb -d exec,nochain), base
compiler vs branch, for builtin-free ports of benchmarks/ built as Windows-ABI
freestanding ELFs (--freestanding --target=windows), so they have the Windows
frame shapes and run on Linux x86_64 and arm64, IR and --legacy.

Each port is self-checking: it computes a known result and ends through
pe_exit_ok() or pe_exit_bad() (a wrong result exits 1, so a miscompile cannot
pass as fast). It uses no builtin (alloc, exit, file_*, ...): in a
freestanding Windows-ABI ELF those lower to unresolved import calls. The exits
are raw bytes/words in exit_x86_64.kr / exit_arm64.kr; count_insns.sh appends
the one for the arch to the port before compiling.

  calib.kr        the calibration loop (row perf_insn_count_calibration)
  fib.kr sort.kr matmul.kr sieve.kr sha256.kr   the ports
  count_insns.sh  <compiler> <port.kr> <arch> [compiler flags]  -> "<count> <exit>"
