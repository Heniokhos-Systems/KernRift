=== KernRift Benchmark Suite ===
Date: Tue Jul 28 03:17:57 AM UTC 2026
CPU: AMD Ryzen 9 7900X 12-Core Processor (x86_64, krc --arch=x86_64)

--- fib ---

### fib

**Compile time:**
| Compiler | Time |
|----------|------|
| krc (self-hosted) | 2ms |
| gcc -O0 | 26ms |
| gcc -O2 | 37ms |
| rustc (debug) | 68ms |
| rustc -O2 | 72ms |

**Binary size:**
| Binary | Size |
|--------|------|
| krc | 296 B |
| gcc -O0 | 15800 B |
| gcc -O2 | 15800 B |
| rustc debug | 3889248 B |
| rustc -O2 | 3887792 B |

**Runtime (median of 3):**
| Binary | Time |
|--------|------|
| krc | 416ms (416, 413, 418) |
| gcc -O0 | 391ms (391, 388, 392) |
| gcc -O2 | 80ms (82, 80, 80) |
| rustc debug | 396ms (396, 396, 395) |
| rustc -O2 | 166ms (166, 166, 163) |

--- sort ---

### sort

**Compile time:**
| Compiler | Time |
|----------|------|
| krc (self-hosted) | 2ms |
| gcc -O0 | 27ms |
| gcc -O2 | 32ms |
| rustc (debug) | 81ms |
| rustc -O2 | 96ms |

**Binary size:**
| Binary | Size |
|--------|------|
| krc | 408 B |
| gcc -O0 | 15960 B |
| gcc -O2 | 15960 B |
| rustc debug | 3905344 B |
| rustc -O2 | 3888048 B |

**Runtime (median of 3):**
| Binary | Time |
|--------|------|
| krc | 59ms (59, 59, 59) |
| gcc -O0 | 153ms (153, 152, 153) |
| gcc -O2 | 272ms (272, 271, 273) |
| rustc debug | 2707ms (2730, 2689, 2707) |
| rustc -O2 | 45ms (46, 44, 45) |

--- sieve ---

### sieve

**Compile time:**
| Compiler | Time |
|----------|------|
| krc (self-hosted) | 2ms |
| gcc -O0 | 26ms |
| gcc -O2 | 31ms |
| rustc (debug) | 82ms |
| rustc -O2 | 93ms |

**Binary size:**
| Binary | Size |
|--------|------|
| krc | 464 B |
| gcc -O0 | 16008 B |
| gcc -O2 | 16008 B |
| rustc debug | 3901200 B |
| rustc -O2 | 3888144 B |

**Runtime (median of 3):**
| Binary | Time |
|--------|------|
| krc | 3ms (3, 3, 3) |
| gcc -O0 | 4ms (4, 4, 4) |
| gcc -O2 | 2ms (2, 2, 2) |
| rustc debug | 22ms (23, 22, 22) |
| rustc -O2 | 2ms (3, 2, 2) |

--- matmul ---

### matmul

**Compile time:**
| Compiler | Time |
|----------|------|
| krc (self-hosted) | 2ms |
| gcc -O0 | 26ms |
| gcc -O2 | 35ms |
| rustc (debug) | 76ms |
| rustc -O2 | 91ms |

**Binary size:**
| Binary | Size |
|--------|------|
| krc | 648 B |
| gcc -O0 | 15960 B |
| gcc -O2 | 15960 B |
| rustc debug | 3900272 B |
| rustc -O2 | 3888488 B |

**Runtime (median of 3):**
| Binary | Time |
|--------|------|
| krc | 6ms (6, 6, 6) |
| gcc -O0 | 16ms (16, 16, 16) |
| gcc -O2 | 4ms (4, 4, 4) |
| rustc debug | 128ms (128, 129, 127) |
| rustc -O2 | 3ms (3, 3, 3) |

--- mandelbrot ---

### mandelbrot

**Compile time:**
| Compiler | Time |
|----------|------|
| krc (self-hosted) | 2ms |
| gcc -O0 | 22ms |
| gcc -O2 | 28ms |
| rustc (debug) | 68ms |
| rustc -O2 | 77ms |

**Binary size:**
| Binary | Size |
|--------|------|
| krc | 960 B |
| gcc -O0 | 15968 B |
| gcc -O2 | 15976 B |
| rustc debug | 3896840 B |
| rustc -O2 | 3893696 B |

**Runtime (median of 3):**
| Binary | Time |
|--------|------|
| krc | 539ms (542, 539, 539) |
| gcc -O0 | 1386ms (1386, 1380, 1390) |
| gcc -O2 | 484ms (484, 490, 481) |
| rustc debug | 1097ms (1091, 1103, 1097) |
| rustc -O2 | 477ms (478, 477, 476) |

--- sha256 ---

### sha256

**Compile time:**
| Compiler | Time |
|----------|------|
| krc (self-hosted) | 3ms |
| gcc -O0 | 29ms |
| gcc -O2 | 45ms |
| rustc (debug) | 83ms |
| rustc -O2 | 111ms |

**Binary size:**
| Binary | Size |
|--------|------|
| krc | 4672 B |
| gcc -O0 | 16240 B |
| gcc -O2 | 16176 B |
| rustc debug | 3916688 B |
| rustc -O2 | 3897872 B |

**Runtime (median of 3):**
| Binary | Time |
|--------|------|
| krc | 191ms (199, 187, 191) |
| gcc -O0 | 202ms (202, 205, 202) |
| gcc -O2 | 40ms (40, 40, 40) |
| rustc debug | 547ms (544, 551, 547) |
| rustc -O2 | 48ms (47, 48, 48) |

=== Done ===
