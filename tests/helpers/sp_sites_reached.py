#!/usr/bin/env python3
"""sp_sites_reached.py <compiler> <tests dir> <work dir>

#143 option C (spec 2.5.1 check 2; plan A19g): row pe_unwind_sp_sites_reached.
Builds every line of tests/fixtures/win_sp_sites/manifest.txt for Windows
(--emit=pe, --test-listing, --test-sp-site-log) and requires, per line: the
build succeeds; its log contains the line's id; no log contains `unnamed`;
the line's function has the line's class (win_frame_classes.py: SP-moving
has a frame register, SP-fixed has none); the image passes C0-C6 + C3b +
C4b (pe_unwind_check.py, 9 PASS). Then, per backend, every moving and folded
top-level id of tests/pe_unwind_sp_sites.lst must be reached by some line.
Compiles run under ulimit -v 2000000 and timeout 120. Prints one line per
problem and a summary; exit 0 when there are none.
"""
import os
import re
import resource
import subprocess
import sys

ARCH = {'x64-ir': 'x86_64', 'x64-legacy': 'x86_64', 'arm64-ir': 'arm64', 'arm64-legacy': 'arm64'}


def cap():
    resource.setrlimit(resource.RLIMIT_AS, (2000000 * 1024, 2000000 * 1024))


def main():
    krc, tdir, work = sys.argv[1:4]
    os.makedirs(work, exist_ok=True)
    helpers = os.path.join(tdir, 'helpers')
    sys.path.insert(0, helpers)
    fx = os.path.join(tdir, 'fixtures', 'win_sp_sites')
    bad, reached, n = [], {}, 0
    for line in open(os.path.join(fx, 'manifest.txt')):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        be, sid, f, flags, fn, cls = line.split('|')
        n += 1
        tag = '%s %s %s' % (be, sid, f)
        stem = os.path.join(work, '%s_%s_%s' % (be, sid.replace('-', 'none'), f[:-3]))
        log = stem + '.log'
        if os.path.exists(log):
            os.unlink(log)
        cmd = [krc] + flags.split() + ['--arch=' + ARCH[be], '--target=windows', '--emit=pe',
               '--test-listing=' + stem + '.lst', '--test-sp-site-log=' + log, os.path.join(fx, f), '-o', stem + '.exe']
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=120, preexec_fn=cap)
        except subprocess.TimeoutExpired:
            bad.append('%s: build timed out' % tag); continue
        if r.returncode != 0:
            bad.append('%s: build failed: %s' % (tag, (r.stderr.strip().split('\n') or [''])[0][:120])); continue
        # one "<id> <code offset>" line per report (format_pe_unwind.kr uw_sp_log_site)
        ids = [l.split()[0] for l in open(log) if l.strip()] if os.path.exists(log) else []
        for i in ids:
            reached.setdefault(be, set()).add(i)
        if 'unnamed' in ids:
            bad.append('%s: the log has an unnamed report' % tag)
        if sid != '-' and sid not in ids:
            bad.append('%s: the log does not reach %s (it has %s)' % (tag, sid, sorted(set(ids))))
        c = subprocess.run([sys.executable, '-B', os.path.join(helpers, 'win_frame_classes.py'), ARCH[be], stem + '.lst'],
                           capture_output=True, text=True).stdout
        got = {l.split()[0]: l.split()[1] for l in c.split('\n') if l.strip()}
        if got.get(fn) != cls:
            bad.append('%s: %s is %s, want %s' % (tag, fn, got.get(fn), cls))
        env = dict(os.environ)
        env.pop('PE_UNWIND_CHECK_DISABLE', None)
        k = subprocess.run([sys.executable, '-B', os.path.join(helpers, 'pe_unwind_check.py'), '--arch', ARCH[be],
                            stem + '.exe', '--listing', stem + '.lst'], capture_output=True, text=True, env=env).stdout
        if k.count(': PASS') != 9:
            first = [l for l in k.split('\n') if 'FAIL' in l or 'error' in l][:1]
            bad.append('%s: checker: %s' % (tag, (first or [k[:120]])[0][:140]))
    want = {}
    for l in open(os.path.join(tdir, 'pe_unwind_sp_sites.lst')):
        if l.startswith('#') or '|' not in l:
            continue
        p = l.split('|')
        if re.match(r'^[XLAG]\d+$', p[0]) and p[5] in ('moving', 'folded'):
            want.setdefault(p[1], set()).add(p[0])
    for be in sorted(want):
        miss = sorted(want[be] - reached.get(be, set()), key=lambda s: int(s[1:]))
        if miss:
            bad.append('%s: no fixture reaches %s' % (be, ','.join(miss)))
    for b in bad:
        print(b)
    tot = sum(len(v) for v in want.values())
    print('sp_sites_reached: %d builds, %d moving/folded ids over 4 backends, %d problems' % (n, tot, len(bad)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
