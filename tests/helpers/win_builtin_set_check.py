#!/usr/bin/env python3
"""win_builtin_set_check.py <src dir> -- #143 (A19d review finding 2).

The legacy pre-scan decides "builtin or named call" with cg_win_is_builtin's
name list (src/codegen.kr); the emitters decide it in gen_expr /
gen_expr_a64 by `tok_matches(wct, "<name>", n)`. A builtin missing from the
list is pre-scanned as a named call (fail-safe, but a builtin whose area
exceeds a call area then stops the build); a name on the list that no
emitter handles is dead. The two sets must be equal, on both legacy
backends. Prints the differences; exit 0 when there are none.
"""
import re
import sys


def main():
    d = sys.argv[1]
    cg = open(d + '/codegen.kr', encoding='latin-1').read()
    a64 = open(d + '/codegen_aarch64.kr', encoding='latin-1').read()
    m = re.search(r'fn cg_win_is_builtin\(.*?uint64 names = "\|([^"]*)\|"', cg, re.S)
    if not m:
        print('cg_win_is_builtin: name list not found'); return 1
    lst = set(m.group(1).split('|'))
    bad = 0
    for what, text in (('codegen.kr gen_expr', cg), ('codegen_aarch64.kr gen_expr_a64', a64)):
        g = set(re.findall(r'tok_matches\(wct, "([A-Za-z_0-9]+)"', text))
        for n in sorted(g - lst):
            print('%s handles builtin %s, cg_win_is_builtin does not list it' % (what, n)); bad += 1
        for n in sorted(lst - g):
            print('cg_win_is_builtin lists %s, %s does not handle it' % (n, what)); bad += 1
    print('win_builtin_set_check: %d names, %d differences' % (len(lst), bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
