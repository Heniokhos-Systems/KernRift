#!/usr/bin/env python3
"""M3 for scripts/mutate-arxmod.sh: reinstate the MODINFO pre-fill bug.

A separate file rather than a sed inside the campaign, because the replacement
spans three lines and the escaping has to survive bash, then python, then sed --
which it did not: the campaign wrote a literal backslash-n into the source and
the mutant was recorded as "the compiler no longer builds", a kill that named
the harness rather than the code.
"""
import sys
p = 'src/format_arx.kr'
s = open(p).read()
old = "        emit_u64_le(arx_mod_abi)\n"
new = ("        uint64 mz = 0\n"
       "        while mz < 24 { emit_byte(0)  mz = mz + 1 }\n"
       "        emit_u64_le(arx_mod_abi)\n")
if s.count(old) != 1:
    sys.exit("M3: anchor is not unique (%d)" % s.count(old))
open(p, 'w').write(s.replace(old, new))
