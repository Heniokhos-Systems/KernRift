#!/usr/bin/env python3
"""a64_win_shape_codes.py <image.exe> <listing> --fixed=A,B --moving=C,D

#143 option C (spec 2.5.3; plan A19e): the unwind codes of Windows arm64
functions, read back with llvm-readobj --unwind and matched to the listing's
labels by address (.text at image base + 0x1000). For every --fixed function:
save_fplr (`stp x29, x30`) present, no add_fp/set_fp (`add fp` / `mov fp`), and
exactly one epilog scope with EpilogueStartIndex 0. For every --moving
function: add_fp or set_fp present. Prints one line per function and a
summary; exit 0 when all conform.
"""
import re
import subprocess
import sys

LINE = re.compile(r'^\s+([0-9a-f]{8}):')
LABEL = re.compile(r'^([A-Za-z_.$][\w.$@]*):\s*$')


def labels(lst):
    out, pending = {}, []
    for l in open(lst, encoding='latin-1'):
        m = LABEL.match(l.rstrip('\n'))
        if m:
            pending.append(m.group(1)); continue
        m = LINE.match(l)
        if m and pending:
            for n in pending:
                out[n] = int(m.group(1), 16)
            pending = []
    return out


def records(exe):
    t = subprocess.run(['llvm-readobj', '--unwind', exe], capture_output=True, text=True).stdout
    recs, cur, where = {}, None, None
    for l in t.split('\n'):
        s = l.strip()
        m = re.match(r'Function: 0x([0-9a-fA-F]+)', s)
        if m:
            cur = {'prolog': [], 'scopes': []}; recs[int(m.group(1), 16)] = cur; where = None; continue
        if cur is None: continue
        if s.startswith('Prologue ['): where = 'p'; continue
        if s.startswith('EpilogueScopes ['): where = 'e'; continue
        m = re.match(r'EpilogueStartIndex: (\d+)', s)
        if m: cur['scopes'].append(int(m.group(1))); continue
        m = re.match(r'0x[0-9a-fA-F]+\s+; (.*)', s)
        if m and where == 'p': cur['prolog'].append(m.group(1))
    return recs


def main():
    exe, lst = sys.argv[1:3]
    fixed, moving = [], []
    for a in sys.argv[3:]:
        if a.startswith('--fixed='): fixed = [x for x in a.split('=', 1)[1].split(',') if x]
        elif a.startswith('--moving='): moving = [x for x in a.split('=', 1)[1].split(',') if x]
    lab, recs = labels(lst), records(exe)
    bad = 0
    for n in fixed + moving:
        if n not in lab or 0x140001000 + lab[n] not in recs:
            print('%s: no record' % n); bad += 1; continue
        r = recs[0x140001000 + lab[n]]
        p = r['prolog']
        fp = any(c.startswith('add fp') or c.startswith('mov fp') for c in p)
        fplr = any(c.startswith('stp x29, x30') for c in p)
        if n in fixed:
            why = []
            if fp: why.append('has add_fp/set_fp')
            if not fplr: why.append('no save_fplr')
            if r['scopes'] != [0]: why.append('epilog scopes %s, want [0]' % r['scopes'])
            print('%s: %s' % (n, 'SP-fixed codes OK' if not why else 'want SP-fixed: ' + '; '.join(why)))
            bad += 1 if why else 0
        else:
            print('%s: %s' % (n, 'frame pointer OK' if fp else 'want add_fp/set_fp, none'))
            bad += 0 if fp else 1
    print('%d functions, %d do not conform' % (len(fixed) + len(moving), bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
