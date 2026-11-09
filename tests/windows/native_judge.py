#!/usr/bin/env python3
"""native_judge.py -- the judge of a native suite run (#143 A14b, phase-5
review findings 1 and 2). KernRift tree.

  native_judge.py <out dir> [--c7]
  native_judge.py --selftest      (synthetic runs, one per rule; suite row
                                   native_judge_selftest)

<out dir> holds what native_suite.sh wrote: suite.log (tests/run_tests.sh with
KR_WINE=tests/windows/native_exec.sh), concurrent.txt (native_concurrent.sh)
and hostrows.txt (native_hostrows.sh). The rules, none of which can pass
vacuously:
  * the log must be complete: its last non-empty line must be the suite's
    `=== Results: P/T passed, F failed, S skipped ===` line (the
    `, S skipped` part is optional: logs of suites before it was added);
  * every name in tests/windows/native_corpus.lst (the Windows corpus: every
    row whose name matches wine|windows|win_|_win|c7_, qemu rows excluded)
    must appear in the log EXACTLY once, and no name may be listed twice;
  * EVERY row of the log that FAILed -- in the corpus or not -- is a native
    FAIL, unless tests/windows/native_reclass.lst reclassifies it, and a
    reclassification is accepted only when the row's failure REASON matches
    the class's rule (RULES below), never by name alone;
  * a SKIP of a corpus row is a native FAIL (no tool is absent natively);
  * every row of tests/pe_unwind_known_reds.lst must FAIL exactly once, for
    its known reason (KNOWN_REDS below; require_rows' rule 3, A15-17 review
    finding 2): it is then judged KNOWN-RED, not FAIL. A known red that
    PASSes, SKIPs, is absent, reports twice or fails for another reason is a
    native FAIL, and a known red without a reason here is an input error;
  * the per-row script results replace their rows and must be PASS.
Writes <out dir>/summary.txt (one line per corpus row:
`<row>: PASS | FAIL (why) | SKIP (class: proof; native reason)`) and prints the
counts; exit 0 when nothing FAILed, 1 otherwise, 2 on an input error.
--c7 prints only the C7 corpus rows (c7_native.sh) with the same judgement.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# Reclassification rules, by failure REASON. Each takes the text after
# "<row>: FAIL " (or "FAIL: <row> ") and returns True when the native failure
# is exactly the one the class allows.
FAULT = re.compile(r"^\(rc=(\d+) stdout '([^']*)' want rc=(\d+) '([^']*)'; "
                   r"FAIL: no RtlVirtualUnwind type 1 walk starting in the image; "
                   r"checker C0-C6 \+ C3b \+ C4b PASS\)$")
CP932 = re.compile(r"ANSI code page is not 932")
LINKP = re.compile(r"^\( peu_p: Wine exit 7, want 11; peu_p: chain [^;]*; peu_pn: Wine exit (\d+), want 32;\)$")
OVERRIDE = re.compile(r"^\( base image: rc=5 stdout 'armed\|', want rc=0 'armed\|';\)$")


def fault_ok(why):
    m = FAULT.match(why)
    return bool(m) and m.group(1) == m.group(3) and m.group(2) == m.group(4)


def linkprobe_ok(why):
    m = LINKP.match(why)
    return bool(m) and m.group(1) != '7'


RULES = {
    # the program ran natively, exited and printed exactly what the row wants,
    # the checker passed; only the Wine +unwind trace clause failed (there is
    # no Wine trace natively)
    'fault': fault_ok,
    # the laptop's ANSI code page is not 932 (the reason must say so)
    'cp932': lambda why: bool(CP932.search(why)),
    # the linked COFF probe: natively it exits 7 (the native target, Wine's
    # 11 is 7 + 4 NULLs) and the --test-no-unwind control does not
    'linkprobe': linkprobe_ok,
    # Wine's winedbg override: main's table-less image ends natively with
    # STATUS_ACCESS_VIOLATION (exit 5), as Windows must; Wine's "exits 0" red
    # does not exist natively
    'override': lambda why: bool(OVERRIDE.match(why)),
}
SCRIPTED = {'concurrent': 'concurrent.txt', 'hostrows': 'hostrows.txt'}

# The known reds (tests/pe_unwind_known_reds.lst), each with the failure
# reason it must report. The row text is run_tests.sh's own; natively the
# program runs through native_exec.sh, so the reason may say "native" where
# Wine says "Wine", and nothing else may differ.
KNOWN_REDS = {
    # #160: the C host's rsi is clobbered by KR code (exit 41, want 40)
    'pe_unwind_host_rsi_across_kr': re.compile(
        r"^\(#160: the C host's rsi does not survive a call into KR \((?:Wine|native) exit 41, want 40\)\)$"),
}


def load_list(name):
    rows = []
    for l in open(os.path.join(HERE, name), encoding='utf-8'):
        l = l.split('#', 1)[0].strip()
        if l:
            rows.append(l)
    return rows


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    out, c7only = argv[1], '--c7' in argv[2:]
    try:
        log = open(os.path.join(out, 'suite.log'), encoding='utf-8', errors='replace').read().split('\n')
        corpus = load_list('native_corpus.lst')
        reclass = {}
        for l in load_list('native_reclass.lst'):
            f = [x.strip() for x in l.split('|')]
            if len(f) != 3 or f[1] not in list(RULES) + list(SCRIPTED):
                raise ValueError('native_reclass.lst: bad line %r' % l)
            if f[0] in reclass:
                raise ValueError('native_reclass.lst: %s twice' % f[0])
            reclass[f[0]] = (f[1], f[2])
        reds = load_list(os.path.join('..', 'pe_unwind_known_reds.lst'))
        for r in reds:
            if r not in KNOWN_REDS:
                raise ValueError('known red %s has no reason in native_judge.py KNOWN_REDS' % r)
            if r in reclass:
                raise ValueError('known red %s is also reclassified' % r)
    except (OSError, ValueError) as ex:
        print('native_judge.py: %s' % ex)
        return 2
    bad = []
    dup = sorted(set(n for n in corpus if corpus.count(n) > 1))
    if dup:
        bad.append('native_corpus.lst lists %s more than once' % ', '.join(dup))
    last = next((l for l in reversed(log) if l.strip()), '')
    if not re.match(r'^=== Results: \d+/\d+ passed, \d+ failed(, \d+ skipped)? ===$', last):
        bad.append('suite.log does not end with its "=== Results:" line (empty or truncated run)')
    seen = {}
    for l in log:
        m = re.match(r'^\s+([A-Za-z0-9_]+): (PASS|FAIL|SKIP)\b ?(.*)$', l)
        if m:
            seen.setdefault(m.group(1), []).append((m.group(2), m.group(3)))
            continue
        m = re.match(r'^FAIL: ([A-Za-z0-9_]+) ?(.*)$', l)
        if m:
            seen.setdefault(m.group(1), []).append(('FAIL', m.group(2)))
    scripted = {}
    for k, fn in SCRIPTED.items():
        p = os.path.join(out, fn)
        txt = open(p, encoding='utf-8', errors='replace').read() if os.path.exists(p) else ''
        for m in re.finditer(r'^([A-Za-z0-9_]+): (PASS|FAIL)(.*)$', txt, re.M):
            scripted[m.group(1)] = (m.group(2), m.group(3).strip())
    lines = []
    judged = {}
    for name in sorted(seen):
        res = seen[name]
        if name in reds:
            if len(res) != 1:
                judged[name] = ('FAIL', '(known red) reported %d times' % len(res))
            elif res[0][0] != 'FAIL':
                judged[name] = ('FAIL', '(known red) %s %s -- it must FAIL until its defect is fixed; if it is '
                                'fixed, remove it from tests/pe_unwind_known_reds.lst' % res[0])
            elif not KNOWN_REDS[name].match(res[0][1]):
                judged[name] = ('FAIL', '(known red, not its known failure) ' + res[0][1])
            else:
                judged[name] = ('KNOWN-RED', res[0][1])
            continue
        if name in corpus and len(res) != 1:
            judged[name] = ('FAIL', 'reported %d times' % len(res))
            continue
        st, why = res[-1]
        if name in reclass:
            cls, proof = reclass[name]
            if cls in SCRIPTED:
                if name not in scripted:
                    st, why = 'FAIL', '%s gave no result for it' % SCRIPTED[cls]
                else:
                    st, why = scripted[name][0], '%s: %s' % (proof, scripted[name][1])
            elif st == 'FAIL':
                if RULES[cls](why):
                    st, why = 'SKIP', '(%s: %s) native: %s' % (cls, proof, why)
                else:
                    why = '(not the %s failure the reclassification allows) %s' % (cls, why)
        if st == 'SKIP' and name in corpus and name not in reclass:
            st, why = 'FAIL', '(a corpus row may not SKIP natively) ' + why
        if st == 'SKIP' and name in reclass and reclass[name][0] not in RULES:
            st = 'FAIL'
        judged[name] = (st, why)
    for name in corpus + reds:
        if name not in seen:
            judged[name] = ('FAIL', 'absent from the log')
    nf = 0
    for name in sorted(judged):
        st, why = judged[name]
        if c7only and not name.startswith('c7_'):
            continue
        if st == 'FAIL':
            nf += 1
        elif name not in corpus and name not in reds:
            continue          # a non-corpus row that passed
        lines.append('%s: %s%s' % (name, st, (' ' + why) if why else ''))
    n = {s: sum(1 for l in lines if re.match(r'^\S+: %s( |$)' % s, l)) for s in ('PASS', 'FAIL', 'SKIP', 'KNOWN-RED')}
    for b in bad:
        lines.append('JUDGE: FAIL (%s)' % b)
    if not c7only:
        open(os.path.join(out, 'summary.txt'), 'w').write('\n'.join(lines) + '\n')
        print('native corpus: %d rows expected + %d known reds, %d judged -- PASS %d, FAIL %d, SKIP %d, KNOWN-RED %d%s'
              % (len(corpus), len(reds), len(lines) - len(bad), n['PASS'], n['FAIL'], n['SKIP'], n['KNOWN-RED'],
                 ''.join('; JUDGE FAIL: ' + b for b in bad)))
    else:
        print('\n'.join(lines))
    return 1 if (nf or (bad and not c7only)) else 0


def selftest():
    """Each rule must bite: a complete synthetic run passes; every defect
    below must make the judge fail."""
    import io
    import contextlib
    import shutil
    import tempfile
    corpus = load_list('native_corpus.lst')
    reclass = {}
    for l in load_list('native_reclass.lst'):
        f = [x.strip() for x in l.split('|')]
        reclass[f[0]] = f[1]
    good_fail = {
        'fault': "(rc=5 stdout 'armed|f3|' want rc=5 'armed|f3|'; FAIL: no RtlVirtualUnwind type 1 walk "
                 "starting in the image; checker C0-C6 + C3b + C4b PASS)",
        'cp932': "(rc=0 (the ANSI code page is not 932: single-byte) GetCPInfo(CP_ACP) said 'ok=1 max=01')",
        'linkprobe': "( peu_p: Wine exit 7, want 11; peu_p: chain main,main,kernel32.dll; peu_pn: Wine exit 2, want 32;)",
        'override': "( base image: rc=5 stdout 'armed|', want rc=0 'armed|';)",
    }

    def run(mut):
        d = tempfile.mkdtemp(prefix='njst')
        try:
            rows = []
            for n in corpus:
                cls = reclass.get(n)
                rows.append('  %s: FAIL %s' % (n, good_fail[cls]) if cls in good_fail else '  %s: PASS' % n)
            rows.append('  some_linux_row: PASS')
            for r in reds:
                rows.append('  %s: FAIL %s' % (r, red_why))
            rows.append('=== Results: %d/%d passed, %d failed ===' % (len(rows) - len(reds), len(rows), len(reds)))
            scripted = ['%s: PASS (native)' % n for n, c in reclass.items() if c in SCRIPTED]
            rows, scripted = mut(rows, scripted)
            open(os.path.join(d, 'suite.log'), 'w').write('\n'.join(rows) + '\n')
            open(os.path.join(d, 'concurrent.txt'), 'w').write('\n'.join(scripted) + '\n')
            open(os.path.join(d, 'hostrows.txt'), 'w').write('\n'.join(scripted) + '\n')
            with contextlib.redirect_stdout(io.StringIO()):
                return main(['native_judge.py', d])
        finally:
            shutil.rmtree(d)

    reds = load_list(os.path.join('..', 'pe_unwind_known_reds.lst'))
    red = 'pe_unwind_host_rsi_across_kr'
    assert red in reds, 'the selftest needs the #160 known red'
    red_why = "(#160: the C host's rsi does not survive a call into KR (Wine exit 41, want 40))"
    fault = next(n for n, c in reclass.items() if c == 'fault')
    cp = next(n for n, c in reclass.items() if c == 'cp932')
    plain = next(n for n in corpus if n not in reclass)
    def sub(rows, name, new):
        return [new if (l.startswith('  %s: ' % name)) else l for l in rows]
    # a mutation adds its rows BEFORE the Results line, which must stay last,
    # so that each case fails for its own reason
    cases = [
        ('complete run', 0, lambda r, s: (r, s)),
        ('complete run, Results line with its skipped count', 0, lambda r, s: (r[:-1] + [r[-1].replace(
            ' failed ===', ' failed, 0 skipped ===')], s)),
        ('a Results line with a malformed skipped count', 1, lambda r, s: (r[:-1] + [r[-1].replace(
            ' failed ===', ' failed, skipped ===')], s)),
        ('a skipped-count Results line with trailing text', 1, lambda r, s: (r[:-1] + [r[-1].replace(
            ' failed ===', ' failed, 0 skipped === trailing')], s)),
        ('a negative skipped count', 1, lambda r, s: (r[:-1] + [r[-1].replace(
            ' failed ===', ' failed, -1 skipped ===')], s)),
        ('a skipped count with more after it', 1, lambda r, s: (r[:-1] + [r[-1].replace(
            ' failed ===', ' failed, 0 skipped, 2 more ===')], s)),
        ('rows after the Results line (it is not the last)', 1, lambda r, s: (r[:-1] + [r[-1].replace(
            ' failed ===', ' failed, 0 skipped ==='), '  some_late_row: PASS'], s)),
        ('trailing blank lines after the Results line', 0, lambda r, s: (r + ['', '   '], s)),
        ('empty log', 1, lambda r, s: ([], s)),
        ('truncated log (no Results line)', 1, lambda r, s: (r[:len(r) // 2], s)),
        ('every row present, only the Results line missing', 1, lambda r, s: (r[:-1], s)),
        ('a corpus row missing', 1, lambda r, s: ([l for l in r if not l.startswith('  %s: ' % plain)], s)),
        ('a corpus row twice', 1, lambda r, s: (r[:-1] + ['  %s: PASS' % plain] + r[-1:], s)),
        ('a corpus row SKIPs', 1, lambda r, s: (sub(r, plain, '  %s: SKIP (no wine)' % plain), s)),
        ('a non-corpus row FAILs', 1, lambda r, s: (r[:-1] + ['  some_other_row: FAIL (x)'] + r[-1:], s)),
        ('a non-corpus FAIL in the FAIL: form', 1, lambda r, s: (r[:-1] + ['FAIL: some_other_row (x)'] + r[-1:], s)),
        ('a fault row with the wrong exit code', 1, lambda r, s: (sub(r, fault,
            "  %s: FAIL (rc=0 stdout 'armed|f3|' want rc=5 'armed|f3|'; FAIL: no RtlVirtualUnwind type 1 walk "
            "starting in the image; checker C0-C6 + C3b + C4b PASS)" % fault), s)),
        ('a fault row in the pre-option-C checker wording', 1, lambda r, s: (sub(r, fault,
            "  %s: FAIL (rc=5 stdout 'armed|f3|' want rc=5 'armed|f3|'; FAIL: no RtlVirtualUnwind type 1 walk "
            "starting in the image; checker C0-C6 + C4b PASS)" % fault), s)),
        ('a fault row whose checker failed', 1, lambda r, s: (sub(r, fault,
            "  %s: FAIL (rc=5 stdout 'armed|f3|' want rc=5 'armed|f3|'; FAIL: no RtlVirtualUnwind type 1 walk "
            "starting in the image; checker: C3: FAIL x)" % fault), s)),
        ('a CP932 row failing for another reason', 1, lambda r, s: (sub(r, cp, '  %s: FAIL (rc=3 crashed)' % cp), s)),
        ('a scripted row without its script result', 1, lambda r, s: (r, [])),
        ('a scripted row whose script FAILed', 1, lambda r, s: (r, [x.replace(': PASS', ': FAIL') for x in s])),
        ('a known red failing for its reason in the native wording', 0, lambda r, s: (sub(r, red,
            '  %s: FAIL %s' % (red, red_why.replace('Wine exit', 'native exit'))), s)),
        ('a known red that PASSes', 1, lambda r, s: (sub(r, red, '  %s: PASS (rsi survives)' % red), s)),
        ('a known red that SKIPs', 1, lambda r, s: (sub(r, red, '  %s: SKIP (the control failed)' % red), s)),
        ('a known red absent', 1, lambda r, s: ([l for l in r if not l.startswith('  %s: ' % red)], s)),
        ('a known red twice', 1, lambda r, s: (r[:-1] + ['  %s: FAIL %s' % (red, red_why)] + r[-1:], s)),
        ('a known red failing for another reason', 1, lambda r, s: (sub(r, red,
            '  %s: FAIL (build/link failed)' % red), s)),
        ('a known red with another exit code', 1, lambda r, s: (sub(r, red,
            '  %s: FAIL %s' % (red, red_why.replace('exit 41', 'exit 5'))), s)),
    ]
    bad = 0
    for name, want, mut in cases:
        got = run(mut)
        ok = (got == 0) if want == 0 else (got != 0)
        print('  case %s: judge rc %d%s' % (name, got, '' if ok else '  <-- WRONG'))
        bad += 0 if ok else 1
    print('native_judge selftest: %d cases, %d wrong' % (len(cases), bad))
    return 1 if bad else 0


if __name__ == '__main__':
    if sys.argv[1:2] == ['--selftest']:
        sys.exit(selftest())
    sys.exit(main(sys.argv))
