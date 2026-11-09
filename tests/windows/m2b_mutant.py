#!/usr/bin/env python3
"""m2b_mutant.py <src dir> -- mutant 2b of #143 A19h (spec 2.5.6, plan Task D
step 3c). KernRift tree. From ~/.cache/pe_unwind_impl/mut19h/
m2b_legacy_nofp_nofold.py, committed so that Task D does not depend on an
untracked file (A15-17 review finding 3).

The mutant: legacy x86_64 Windows functions are all described SP-fixed (no
`push rbp; mov rbp,rsp`, no UWOP_SET_FPREG) while the outgoing-area folding is
off, so the per-call `sub rsp` areas stay in the body; the backstop is not
armed (uw_fn_sp_fixed stays 0). Wine recovers from this error class, so the
only dynamic evidence is native: Task D 3c builds
tests/fixtures/pe_unwind_mixed_fault.kr --legacy with the mutant compiler and
cdb_chain.sh must FAIL on it while it passes on the real compiler's image.

Edits <src dir>/codegen.kr in place by exact text match; exits 1 (and edits
nothing) unless the text occurs exactly once. Row m2b_mutant_applies applies
it to a copy of src/ and checks the edit lands and bites.
"""
import os
import sys

OLD = '''    if cg_win_ps_fixed != 0 {
        cg_win_folded = 1
        cg_win_out_bias = cg_win_out
        uw_fn_sp_fixed = 1
    }
    uint64 win_fp = 0
    if target_os == 2 && cg_win_folded == 0 { win_fp = 1 }'''
NEW = '''    uint64 win_fp = 0'''


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    p = os.path.join(argv[1], 'codegen.kr')
    t = open(p, encoding='utf-8').read()
    n = t.count(OLD)
    if n != 1:
        print('m2b_mutant: the target text occurs %d times in %s (want 1): codegen.kr changed; '
              're-derive the mutant' % (n, p))
        return 1
    open(p, 'w', encoding='utf-8').write(t.replace(OLD, NEW))
    print('m2b_mutant: applied to %s' % p)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
