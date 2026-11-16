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

The extraction can only see what asm_match(sptr, 0, "<mn>...") names, so
(A1, #286) inside asm_emit_a64 a keyword-shaped string literal passed to any
other function, or an asm_match(sptr, 0, ...) whose keyword is not a string
literal, is exit 2 (a mnemonic would drop out of the set silently); message
literals -- quotes, parentheses or three words -- are not keyword-shaped.
And asm_a64_accepted(), the list the assembler words its "not supported"
refusals with, must equal the extracted set (exit 1 `ACCEPTED LIST DRIFT`).

Prints one summary line, then `IN TWO LISTS: ...`, `UNCLASSIFIED: ...` and/or
`ACCEPTED LIST DRIFT: ...` when there is a problem. Exit 0 = covered, 1 = a
problem, 2 = the source has no asm_emit_a64, no classification list or no
asm_a64_accepted(), or hides a mnemonic from the extraction (the check would
be vacuous).
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
    # A1 (#286): a mnemonic matched through any other function would leave
    # the set silently. A keyword-shaped literal (one lower-case word, an
    # optional second word, an optional ', ' / ' ' / ',') passed to anything
    # but asm_match is refused; message literals do not match.
    kw = re.compile(r'"[a-z][a-z0-9.]*(?: [a-z0-9_.]+)?(?:, | |,)?"')
    for call in re.finditer(r'\b(\w+)\(([^()]*)\)', m.group(0)):
        if call.group(1) != 'asm_match' and kw.search(call.group(2)):
            print('asm_write_class_cover: %s(%s) matches a keyword in asm_emit_a64; use asm_match(sptr, 0, ...) so the mnemonic is seen'
                  % (call.group(1), call.group(2)[:60]))
            return 2
    # ... and the keyword of every asm_match(sptr, 0, ...) is a string literal:
    # a variable (`uint64 kw = "yield"`) would hide the mnemonic.
    for call in re.finditer(r'\basm_match\(sptr, 0, ([^,()]+),', m.group(0)):
        if not call.group(1).strip().startswith('"'):
            print('asm_write_class_cover: asm_match(sptr, 0, %s, ...) in asm_emit_a64 -- the keyword must be a string literal'
                  % call.group(1).strip())
            return 2
    acc = re.search(r'^fn asm_a64_accepted\(\) -> uint64 \{ return "\|(.*)\|" \}', src, re.M)
    if not acc:
        print('asm_write_class_cover: no fn asm_a64_accepted() in %s' % argv[1])
        return 2
    drift = sorted(set(acc.group(1).split('|')) ^ set(asm))
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
    if drift:
        print('ACCEPTED LIST DRIFT: ' + ' '.join(drift))
    return 1 if (bad or dup or drift) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
