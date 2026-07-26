=== KernRift Benchmark Suite ===
Date: Sun Jul 26 04:04:44 PM UTC 2026
CPU: AMD Ryzen 9 7900X 12-Core Processor

--- fib ---

### fib

**Compile time:**
| Compiler | Time |
|----------|------|
| krc (self-hosted) | 1ms |
| gcc -O0 | 25ms |
| gcc -O2 | 43ms |
| rustc (debug) | 71ms |
| rustc -O2 | 80ms |

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
| krc | 441ms (436, 441, 442) |
| gcc -O0 | 405ms (405, 405, 405) |
| gcc -O2 | 85ms (84, 85, 86) |
| rustc debug | 412ms (410, 416, 412) |
| rustc -O2 | 170ms (170, 172, 169) |

--- sort ---

### sort

**Compile time:**
| Compiler | Time |
|----------|------|
| krc (self-hosted) | 2ms |
| gcc -O0 | 28ms |
| gcc -O2 | 32ms |
| rustc (debug) | 91ms |
| rustc -O2 | 100ms |

**Binary size:**
| Binary | Size |
|--------|------|
| krc | 464 B |
| gcc -O0 | 15960 B |
| gcc -O2 | 15960 B |
| rustc debug | 3905344 B |
| rustc -O2 | 3888048 B |

**Runtime (median of 3):**
| Binary | Time |
|--------|------|
| krc | 81ms (81, 81, 80) |
| gcc -O0 | 158ms (156, 158, 159) |
| gcc -O2 | 279ms (283, 279, 279) |
| rustc debug | 2854ms (2854, 2896, 2820) |
| rustc -O2 | 48ms (48, 49, 48) |

--- sieve ---

### sieve

**Compile time:**
| Compiler | Time |
|----------|------|
| krc (self-hosted) | 2ms |
| gcc -O0 | 28ms |
| gcc -O2 | 34ms |
| rustc (debug) | 94ms |
| rustc -O2 | 107ms |

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
| gcc -O0 | 5ms (5, 5, 4) |
| gcc -O2 | 2ms (2, 2, 2) |
| rustc debug | 23ms (23, 23, 24) |
| rustc -O2 | 2ms (2, 2, 2) |

--- matmul ---

### matmul

**Compile time:**
| Compiler | Time |
|----------|------|
| krc (self-hosted) | 2ms |
| gcc -O0 | 30ms |
| gcc -O2 | 34ms |
| rustc (debug) | 85ms |
| rustc -O2 | 111ms |

**Binary size:**
| Binary | Size |
|--------|------|
| krc | 1104 B |
| gcc -O0 | 15960 B |
| gcc -O2 | 15960 B |
| rustc debug | 3900272 B |
| rustc -O2 | 3888488 B |

**Runtime (median of 3):**
| Binary | Time |
|--------|------|
| krc | 25ms (25, 25, 25) |
| gcc -O0 | 16ms (16, 17, 16) |
| gcc -O2 | 4ms (4, 4, 4) |
| rustc debug | 133ms (132, 133, 135) |
| rustc -O2 | 4ms (4, 4, 4) |

--- mandelbrot ---

### mandelbrot

**Compile time:**
| Compiler | Time |
|----------|------|
| krc (self-hosted) | 2ms |
| gcc -O0 | 31ms |
| gcc -O2 | 32ms |
| rustc (debug) | 85ms |
| rustc -O2 | 93ms |

**Binary size:**
| Binary | Size |
|--------|------|
| krc | 1824 B |
| gcc -O0 | 15968 B |
| gcc -O2 | 15976 B |
| rustc debug | 3896840 B |
| rustc -O2 | 3893696 B |

**Runtime (median of 3):**
| Binary | Time |
|--------|------|
| krc | 1786ms (1792, 1786, 1778) |
| gcc -O0 | 1427ms (1427, 1433, 1422) |
| gcc -O2 | 497ms (496, 497, 500) |
| rustc debug | 1122ms (1125, 1117, 1122) |
| rustc -O2 | 497ms (497, 497, 494) |

--- sha256 ---

### sha256

**Compile time:**
| Compiler | Time |
|----------|------|
| krc (self-hosted) | 3ms |
| gcc -O0 | 33ms |
| gcc -O2 | 53ms |
| rustc (debug) | 97ms |
| rustc -O2 | 110ms |

**Binary size:**
| Binary | Size |
|--------|------|
| krc | 6096 B |
| gcc -O0 | 16240 B |
| gcc -O2 | 16176 B |
| rustc debug | 3916688 B |
| rustc -O2 | 3897872 B |

**Runtime (median of 3):**
| Binary | Time |
|--------|------|
| krc | 416ms (428, 416, 415) |
| gcc -O0 | 206ms (210, 206, 200) |
| gcc -O2 | 41ms (42, 41, 41) |
| rustc debug | 555ms (555, 544, 558) |
| rustc -O2 | 48ms (48, 48, 49) |

=== Done ===
