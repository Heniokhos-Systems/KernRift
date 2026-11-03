#!/usr/bin/env python3
"""native_corpus_check.py -- tests/windows/native_corpus.lst against the row
names of tests/run_tests.sh (#143, A15-17 review finding 1). KernRift tree.

  native_corpus_check.py <run_tests.sh> <native_corpus.lst> <native_corpus_nonrows.lst>

The native corpus is every suite row whose name matches
wine|windows|win_|_win|c7_ (the qemu rows, Linux arm64, excluded) and is made of
[A-Za-z0-9_] (the names native_judge.py can read). run_tests.sh is not run here,
so its row names are derived statically, and both directions are checked:
  * TOKENS: every identifier of run_tests.sh that matches the pattern is either
    a corpus row or listed in native_corpus_nonrows.lst (helpers, prefixes,
    fixtures, variables). A row added to the suite therefore fails this check
    until it is added to the corpus (or, if it is not a row, to the non-rows);
  * TEMPLATES: a corpus row that is not a whole token must be produced by a
    `$`-template of run_tests.sh (`emit_accept_$GOOD`,
    `t6_debug_hosted_${OS}_$A`, ...), the `$` parts standing for a word; and a
    template whose literal text matches the pattern must produce at least one
    corpus row (otherwise its rows are missing), unless the non-rows list it;
  * a non-row may not be a corpus row, and must still occur in run_tests.sh
    (no stale entries); the corpus may not list a name twice.
Prints one line per problem, then a summary; exit 0 when there is none.
"""
import re
import sys

PAT = re.compile(r'wine|windows|win_|_win|c7_')


def load(path):
    out = []
    for l in open(path, encoding='utf-8'):
        l = l.split('#', 1)[0].strip()
        if l:
            out.append(l)
    return out


def main(argv):
    if len(argv) != 4:
        print(__doc__)
        return 2
    src = open(argv[1], encoding='utf-8', errors='replace').read()
    corpus, nonrows = load(argv[2]), load(argv[3])
    cset, nset = set(corpus), set(nonrows)
    tokens = set(t for t in re.findall(r'[A-Za-z0-9_]+', src) if PAT.search(t) and 'qemu' not in t)
    # $-templates: word characters around $X / ${X} parts
    tmpl = set()
    for m in re.finditer(r'(?<![A-Za-z0-9_$])((?:[A-Za-z0-9_]|\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*)+)', src):
        t = m.group(1)
        if '$' in t and re.sub(r'\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*', '', t):
            tmpl.add(t)
    def rx(t):
        parts = re.split(r'(\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*)', t)
        return re.compile('^' + ''.join('[A-Za-z0-9_]+' if p.startswith('$') else re.escape(p) for p in parts) + '$')
    trx = {t: rx(t) for t in tmpl}
    bad = []
    dup = sorted(set(n for n in corpus if corpus.count(n) > 1))
    if dup:
        bad.append('native_corpus.lst lists %s more than once' % ', '.join(dup))
    for n in sorted(cset - set(n for n in cset if PAT.search(n) and 'qemu' not in n)):
        bad.append('corpus row %s does not match the Windows pattern (or is a qemu row)' % n)
    for t in sorted(tokens - cset - nset):
        bad.append('%s: a Windows-pattern name in run_tests.sh that is neither in native_corpus.lst nor in '
                   'native_corpus_nonrows.lst (a new row? add it to the corpus)' % t)
    for n in sorted(cset & nset):
        bad.append('%s is listed both as a corpus row and as a non-row' % n)
    for n in sorted(nset):
        if n not in tokens and n not in tmpl:
            bad.append('non-row %s no longer occurs in run_tests.sh (stale entry)' % n)
    ntmpl = 0
    for n in sorted(cset - tokens):
        hits = [t for t in tmpl if trx[t].match(n)]
        if not hits:
            bad.append('corpus row %s is not a name in run_tests.sh, nor made by any $-template there' % n)
        else:
            ntmpl += 1
    for t in sorted(tmpl):
        lit = re.sub(r'\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*', '', t)
        if PAT.search(lit) and 'qemu' not in lit and t not in nset and not any(trx[t].match(n) for n in cset):
            bad.append('template %s makes Windows-pattern names but no corpus row matches it '
                       '(add its rows, or list it in native_corpus_nonrows.lst)' % t)
    for b in bad:
        print('native_corpus_check: ' + b)
    print('native_corpus_check: %d corpus rows (%d whole names, %d from $-templates), %d non-rows, %d problems'
          % (len(cset), len(cset & tokens), ntmpl, len(nset), len(bad)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
