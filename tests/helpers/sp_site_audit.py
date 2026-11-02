#!/usr/bin/env python3
"""sp_site_audit.py <tree> -- #143 option C (spec 2.5.1, check 1): the
mechanical pairing check between the compiler's SP-writing emitters and the
backstop.

  (a) every SP helper's body calls uw_sp_moves();
  (b) every moving/folded entry of tests/pe_unwind_sp_sites.lst names a
      function that exists and whose body (or the named op block in it) calls
      an SP helper or uw_sp_moves() -- no listed site is left raw;
  (c) a sweep of the four backends for raw SP-writing encodings outside the
      SP helpers finds nothing that is not on the committed list of reviewed
      raw hits (tests/pe_unwind_sp_raw.lst: prologue/epilogue code, non-Windows
      paths and decoder false positives, each with its reason).

Exit 0 = all three hold; 1 = a problem (each printed); 2 = usage/input error.
(a) and (b) are exact; (c) is a tripwire for a new raw site.
"""
import re
import sys

HELPERS = {
    'codegen.kr': ['emit_win_alloc_stack', 'emit_win_free_stack', 'emit_x64_push_r', 'emit_x64_pop_r',
                   'emit_x64_rsp_adj'],
    'codegen_aarch64.kr': ['emit_a64_sub_sp_imm', 'emit_a64_add_sp_imm', 'emit_a64_stp_pre', 'emit_a64_ldp_post',
                           'emit_a64_sp_word'],
}
FILES = ['ir.kr', 'codegen.kr', 'ir_aarch64.kr', 'codegen_aarch64.kr']
ALL_HELPERS = [h for v in HELPERS.values() for h in v]
# x64 IR call-frame wrappers: each must itself call an SP helper (checked in (a))
WRAPPERS = {'ir.kr': ['ir_x86_win64_call_frame', 'ir_x86_win64_call_release', 'ir_x86_emit_call_stack_args',
                      'ir_x86_emit_call_stack_cleanup', 'c7_x86_push', 'c7_x86_pop']}
CALL_RE = re.compile(r'\b(%s|uw_sp_moves)\(' % '|'.join(ALL_HELPERS + [w for v in WRAPPERS.values() for w in v]))
HELPER_RE = re.compile(r'\b(%s|uw_sp_moves)\(' % '|'.join(ALL_HELPERS))


def functions(text):
    """{name: (start line, end line, body text)} for every top-level fn."""
    lines = text.split('\n')
    starts = [(i, m.group(1)) for i, l in enumerate(lines) for m in [re.match(r'^fn (\w+)', l)] if m]
    out = {}
    for k, (i, n) in enumerate(starts):
        j = starts[k + 1][0] if k + 1 < len(starts) else len(lines)
        out[n] = (i + 1, j, '\n'.join(lines[i:j]))
    return out


def code(line):
    return line.split('//')[0]


def op_block(body, op):
    """The text of `if op == N {` ... up to the next top-level op test."""
    m = re.search(r'\n    if op == %d \{' % op, body)
    if not m:
        return None
    n = re.search(r'\n    if op == \d+ \{', body[m.end():])
    return body[m.start(): m.end() + (n.start() if n else len(body))]


# raw SP encodings (spec 2.5.1 check 1 (c))
X64_PAIR = re.compile(r'emit_byte\(0x48\);\s*emit_byte\(0x8[13]\);\s*emit_byte\(0x(EC|C4|E4)\)', re.I)
X64_C7 = re.compile(r'c7_b[34]\(0x48,\s*0x8[13],\s*0x(EC|C4|E4)', re.I)
X64_OP = re.compile(r'emit_byte\(0x(5[0-9A-F]|9C|9D|C8|C9|6A|68)\)', re.I)
X64_CALC = re.compile(r'0x5[08]\s*[|+]')
A64_WORD = re.compile(r'0x([0-9A-F]{8})', re.I)
A64_CALC = re.compile(r'0x(D1|91)[0-9A-F]{6}\s*\|.*\(31 << 5\)\s*\|\s*31\b', re.I)


def a64_word_writes_sp(w):
    rd, rn = w & 31, (w >> 5) & 31
    top = w & 0x7F000000
    if top in (0x51000000, 0x11000000) and rd == 31:          # add/sub (imm) with Rd = SP
        return True
    if (w & 0x7FE00000) in (0x4B200000, 0x0B200000) and rd == 31:   # add/sub (extended reg)
        return True
    if (w & 0x3A000000) == 0x28000000 and ((w >> 23) & 3) in (1, 3) and rn == 31:   # pair pre/post
        return True
    if (w & 0x3B200C00) in (0x38000400, 0x38000C00) and rn == 31:   # single pre/post
        return True
    return False


# An emit_byte(0x5X / 0x9C / 0xC8 ...) is an opcode only at the start of an
# instruction: it is the first emit_byte of its statement line (or follows only
# a REX.B 0x41), and the previous code line does not end in a byte that still
# needs operands (REX, 0F escape, an opcode taking ModRM, a ModRM/SIB that
# takes a displacement). Bytes after another emit_byte on the same line are
# operands. This is a tripwire, not a decoder: the exact checks are (a) and (b).
NEEDS_MORE = {0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F,
              0x0F, 0x66, 0xF2, 0xF3, 0x89, 0x8B, 0x8D, 0x01, 0x03, 0x09, 0x21, 0x29, 0x31, 0x39, 0x85, 0x87,
              0x83, 0x81, 0xC7, 0xC6, 0xF7, 0xFF, 0x69, 0x6B, 0xD1, 0xD3, 0xC1, 0x63, 0x88, 0x8A, 0x24, 0x44,
              0x4C, 0x54, 0x5C, 0x64, 0x6C, 0x74, 0x7C, 0x84, 0x94, 0x9C, 0xA4, 0xAC, 0xB4, 0xBC, 0x80}
EMIT = re.compile(r'emit_byte\((0x[0-9A-Fa-f]+|\d+)\)')


def x64_opcode_position(lines, i, c, m):
    before = c[:m.start()]
    prior = EMIT.findall(before)
    if prior and not (len(prior) == 1 and int(prior[0], 0) == 0x41):
        return False
    if re.search(r'\bemit_\w+\(', before.replace('emit_byte(0x41)', '')):
        return False
    j = i - 1
    while j >= 0 and not code(lines[j]).strip():
        j -= 1
    if j >= 0:
        pv = EMIT.findall(code(lines[j]))
        if pv and code(lines[j]).rstrip().endswith(')') and int(pv[-1], 0) in NEEDS_MORE \
           and code(lines[j]).rstrip().endswith('emit_byte(%s)' % pv[-1]):
            return False
    return True


def sweep(fname, text, funcs):
    hits = []
    helper_lines = set()
    for h in HELPERS.get(fname, []):
        if h in funcs:
            s, e, _ = funcs[h]
            helper_lines.update(range(s, e + 1))
    lines = text.split('\n')
    fn_of = {}
    for n, (s, e, _) in funcs.items():
        for k in range(s, e + 1):
            fn_of[k] = n
    for i, l in enumerate(lines):
        ln = i + 1
        if ln in helper_lines:
            continue
        c = code(l)
        why = []
        if fname in ('ir.kr', 'codegen.kr'):
            if X64_PAIR.search(c) or X64_C7.search(c):
                why.append('rsp sub/add/and')
            m = X64_OP.search(c)
            if m and x64_opcode_position(lines, i, c, m):
                why.append('push/pop/pushf/enter/leave/push-imm byte')
            if X64_CALC.search(c):
                why.append('computed push/pop')
        else:
            for m in A64_WORD.finditer(c):
                if a64_word_writes_sp(int(m.group(1), 16)):
                    why.append('SP-writing word %s' % m.group(1))
            if A64_CALC.search(c):
                why.append('computed add/sub with Rd = SP')
        if why:
            hits.append((fname, fn_of.get(ln, '-'), ' '.join(c.split()), '; '.join(why), ln))
    return hits


def main(argv):
    if len(argv) != 1:
        print('usage: sp_site_audit.py <tree>', file=sys.stderr)
        return 2
    root = argv[0].rstrip('/')
    src = {f: open('%s/src/%s' % (root, f), encoding='latin-1').read() for f in FILES}
    funcs = {f: functions(t) for f, t in src.items()}
    probs = []
    # (a)
    for f, hs in HELPERS.items():
        for h in hs:
            if h not in funcs[f]:
                probs.append('(a) SP helper %s missing from %s' % (h, f))
            elif 'uw_sp_moves()' not in funcs[f][h][2]:
                probs.append('(a) SP helper %s (%s) does not call uw_sp_moves()' % (h, f))
    for f, ws in WRAPPERS.items():
        for w in ws:
            if w not in funcs[f]:
                probs.append('(a) wrapper %s missing from %s' % (w, f))
            elif not HELPER_RE.search(funcs[f][w][2]):
                probs.append('(a) wrapper %s (%s) calls no SP helper' % (w, f))
    # (b)
    sites = []
    for l in open('%s/tests/pe_unwind_sp_sites.lst' % root):
        l = l.rstrip('\n')
        if not l or l.startswith('#'):
            continue
        p = l.split('|')
        if len(p) != 7:
            probs.append('(b) malformed site entry: %s' % l)
            continue
        sites.append(p)
    nb = 0
    for sid, backend, f, fn, op, cls, note in sites:
        if cls not in ('moving', 'folded'):     # excluded, neutral, classified (no SP write)
            continue
        nb += 1
        if f not in funcs:
            probs.append('(b) %s: file %s is not a backend file' % (sid, f))
            continue
        if fn not in funcs[f]:
            probs.append('(b) %s: function %s not in %s' % (sid, fn, f))
            continue
        body = funcs[f][fn][2]
        if op != '-':
            blk = op_block(body, int(op))
            if blk is None:
                probs.append('(b) %s: no `if op == %s` block in %s' % (sid, op, fn))
                continue
            body = blk
        if not CALL_RE.search(body):
            probs.append('(b) %s: %s%s calls no SP helper and no uw_sp_moves()' % (sid, fn, '' if op == '-' else ' op %s' % op))
    # (c)
    allowed = {}
    for l in open('%s/tests/pe_unwind_sp_raw.lst' % root):
        l = l.rstrip('\n')
        if not l or l.startswith('#'):
            continue
        p = l.split('|', 2)
        q = p[2].rsplit('|', 2) if len(p) == 3 else []
        if len(q) != 3 or not q[1].isdigit():
            probs.append('(c) malformed raw entry: %s' % l)
            continue
        f, fn = p[0], p[1]
        text, cnt, reason = q
        allowed[(f, fn, text)] = (int(cnt), reason)
    seen = {}
    for f in FILES:
        for h in sweep(f, src[f], funcs[f]):
            k = (h[0], h[1], h[2])
            seen.setdefault(k, []).append(h)
    for k, hs in sorted(seen.items()):
        if k not in allowed:
            for h in hs:
                probs.append('(c) raw SP encoding outside the SP helpers: %s:%d %s: %s [%s]' % (h[0], h[4], h[1], h[2], h[3]))
        elif allowed[k][0] != len(hs):
            probs.append('(c) %s %s: %d raw hits of `%s`, the list says %d' % (k[0], k[1], len(hs), k[2], allowed[k][0]))
    for k in allowed:
        if k not in seen:
            probs.append('(c) stale raw entry (no longer in the tree): %s %s `%s`' % k)
    for p in probs:
        print('FAIL ' + p)
    if probs:
        print('sp_site_audit: %d problems' % len(probs))
        return 1
    print('sp_site_audit: PASS (%d helpers report; %d moving/folded sites call a helper; %d reviewed raw hits, no other)'
          % (len(ALL_HELPERS), nb, sum(c for c, _ in allowed.values())))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
