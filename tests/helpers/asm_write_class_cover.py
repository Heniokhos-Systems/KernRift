#!/usr/bin/env python3
"""asm_write_class_cover.py <codegen.kr> -- row asm_write_class_covers_assembler.

Every mnemonic the arm64 inline assembler accepts (`asm_match(sptr, 0, "<mn>`
inside `fn asm_emit_a64`) must be classified EXPLICITLY by the write
classification of codegen.kr (#251, #252): an entry of exactly one of the
exact lists asm_wc_none / asm_wc_first / asm_wc_both / asm_wc_status, or a
mnemonic starting with an entry of a family list asm_wc_second_fam /
asm_wc_both_fam / asm_wc_none_fam, or a conditional branch `b.<cond>` /
`bc.<cond>`. The x18/x29 checks (#242, #246, #249) and #143's scanner read
those lists, so a mnemonic added to the assembler without a classification
would be judged by the fail-closed default only; this check makes adding one
a deliberate step.

Prints one summary line, then `IN TWO LISTS: ...` and/or `UNCLASSIFIED: ...`
when there is a problem. Exit 0 = covered, 1 = a problem, 2 = the source has
no asm_emit_a64 or no classification list (the check would be vacuous).
"""
import re
import sys


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    src = open(argv[1], encoding='utf-8', errors='replace').read()
    m = re.search(r'^fn asm_emit_a64\(.*?^}', src, re.S | re.M)
    if not m:
        print('asm_write_class_cover: no fn asm_emit_a64 in %s' % argv[1])
        return 2
    asm = sorted(set(re.findall(r'asm_match\(sptr, 0, "([a-z0-9.]+)', m.group(0))))
    if not asm:
        print('asm_write_class_cover: asm_emit_a64 matches no mnemonic (the pattern is stale)')
        return 2
    lists = {}
    for name in ('none', 'first', 'both', 'status', 'second_fam', 'both_fam', 'none_fam'):
        mm = re.search(r'^fn asm_wc_' + name + r'\(\) -> uint64 \{ return "\|(.*)\|" \}', src, re.M)
        lists[name] = set(mm.group(1).split('|')) if mm else set()
    if not any(lists.values()):
        print('UNCLASSIFIED: ' + ' '.join(asm))
        print('asm_write_class_cover: no asm_wc_* classification list in %s' % argv[1])
        return 1
    exact = lists['none'] | lists['first'] | lists['both'] | lists['status']
    fam = lists['second_fam'] | lists['both_fam'] | lists['none_fam']
    bad = [x for x in asm if x not in exact and not any(x.startswith(f) for f in fam)
           and not re.match(r'^bc?\.', x)]
    dup = sorted(x for x in exact if sum(x in lists[k] for k in ('none', 'first', 'both', 'status')) > 1)
    print('asm_write_class_cover: %d assembler mnemonics; lists none %d, first %d, both %d, status %d, families %d'
          % (len(asm), len(lists['none']), len(lists['first']), len(lists['both']), len(lists['status']), len(fam)))
    if dup:
        print('IN TWO LISTS: ' + ' '.join(dup))
    if bad:
        print('UNCLASSIFIED: ' + ' '.join(bad))
    return 1 if (bad or dup) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
