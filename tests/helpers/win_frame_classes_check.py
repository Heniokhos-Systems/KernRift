#!/usr/bin/env python3
"""win_frame_classes_check.py <compiler> <tests dir> <work dir>

#143 option C (spec 2.5.5, finding 21; plan A19g): row
pe_unwind_win_frame_classes. For each (backend, fixture, flags) group of
tests/fixtures/win_abi_frames/classes.txt, builds the fixture for Windows
(--emit=pe --test-listing, under ulimit -v 2000000 and timeout 120), reads
every function's class (and arm64 IR shape) with win_frame_classes.py and
compares the two sets of lines in both directions. Prints each difference and
a summary; exit 0 when there is none.
"""
import os
import resource
import subprocess
import sys

ARCH = {'x64-ir': 'x86_64', 'x64-legacy': 'x86_64', 'arm64-ir': 'arm64', 'arm64-legacy': 'arm64'}


def cap():
    resource.setrlimit(resource.RLIMIT_AS, (2000000 * 1024, 2000000 * 1024))


def main():
    krc, tdir, work = sys.argv[1:4]
    os.makedirs(work, exist_ok=True)
    groups, order = {}, []
    for l in open(os.path.join(tdir, 'fixtures', 'win_abi_frames', 'classes.txt')):
        l = l.strip()
        if not l or l.startswith('#'):
            continue
        be, fx, flags, fn, cls, shape = l.split('|')
        k = (be, fx, flags)
        if k not in groups:
            groups[k] = {}; order.append(k)
        groups[k][fn] = (cls, shape)
    bad, nf = [], 0
    for i, (be, fx, flags) in enumerate(order):
        stem = os.path.join(work, 'c%d' % i)
        cmd = [krc] + flags.split() + ['--arch=' + ARCH[be], '--target=windows', '--emit=pe',
               '--test-listing=' + stem + '.lst', os.path.join(tdir, 'fixtures', fx), '-o', stem + '.exe']
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=120, preexec_fn=cap)
        except subprocess.TimeoutExpired:
            bad.append('%s %s: build timed out' % (be, fx)); continue
        if r.returncode != 0:
            bad.append('%s %s: build failed' % (be, fx)); continue
        args = [sys.executable, '-B', os.path.join(tdir, 'helpers', 'win_frame_classes.py'), ARCH[be], stem + '.lst']
        if be == 'arm64-ir':
            args.append('--ir')
        out = subprocess.run(args, capture_output=True, text=True).stdout
        got = {}
        for l in out.split('\n'):
            p = l.split()
            if len(p) == 3:
                got[p[0]] = (p[1], p[2])
        want = groups[(be, fx, flags)]
        for fn in sorted(set(want) | set(got)):
            nf += 1
            if want.get(fn) != got.get(fn):
                bad.append('%s %s %s: classes.txt says %s, the listing says %s' % (be, fx, fn, want.get(fn), got.get(fn)))
    for b in bad:
        print(b)
    print('win_frame_classes: %d groups, %d functions, %d differences' % (len(order), nf, len(bad)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
