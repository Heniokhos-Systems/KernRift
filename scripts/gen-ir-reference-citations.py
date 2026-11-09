#!/usr/bin/env python3
"""Regenerate (or --check) tests/ir_reference_citations.txt.

The same file in KernRift and MLRift; it picks the source extension from the
tree (src/main.kr -> .kr, src/main.mlr -> .mlr).

docs/IR_REFERENCE.md cites src/*.<ext> by line number, and line numbers rot: at
one audit 146 of 153 citations pointed at unrelated code while still being in
range, which reads as valid and is the most insidious form of this defect --
and the manifest was then regenerated over them, freezing the wrong lines. So
the manifest records a fingerprint of EVERY line the document cites, not just
the first number of each citation: the end of a range (`src/x.kr:100`–`120`)
and a bare follow-on number (`src/x.kr:100`/`104`, `` `100`, `104` ``) are
citations too, and used to drift unseen. (Those are shapes, not citations.)

Citations INTO MARKDOWN rot the same way, so every `<NAME>.md:<line>` in the
tree's prose -- the *.md files at the top and under docs/, tests/run_tests.sh
and src/ -- is fingerprinted too. A bare `STDLIB.md:<line>` means
docs/STDLIB.md, else ./STDLIB.md.

Citations FROM ONE SOURCE FILE INTO ANOTHER rot the same way, so every
`<file>.<ext>:<line>` (or `src/<file>.<ext>:<line>`) in a comment under src/ is
fingerprinted as well, with its range end and its bare follow-on numbers
(`ir.kr:80/2881`, `main.kr:1095, :3613`), and gets the two checks below. Three
shapes are not src/ citations and are skipped: one inside a backquoted span (an
example diagnostic such as `m.kr:1:1: expected '('`), one followed by `at
<commit>`, which names a line as it was in that commit, and a path with a
directory in front (std/net.kr:153).

A fingerprint only says a line has not changed since it was recorded, not that
it was the right line. Two checks look at what the citation SAYS:
  - "the comment at `src/x:N`" must point at a line that IS a comment (starts
    with //), not code that merely ends in one;
  - when the text between the previous citation and this one names something
    in backquotes that is a function defined in the cited file, the cited
    lines must lie inside one of those functions, or mention one of the
    backquoted names. (`ir_opt_cse` (`src/ir.kr:N`) must be in or call
    ir_opt_cse.)

It also refuses shapes that cannot be right whatever the code says: a range
whose end is before its start, a line number past the end of the file, a
blank line, and a citation of a file that does not exist.

After editing src/, the docs, or the citations, CHECK EACH CITATION AGAINST THE
CODE, then:
    python3 scripts/gen-ir-reference-citations.py
tests/run_tests.sh runs it with --check.
"""
import hashlib, re, sys, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXT = "mlr" if os.path.exists(os.path.join(ROOT, "src", "main.mlr")) else "kr"
doc = os.path.join(ROOT, "docs/IR_REFERENCE.md")
out = os.path.join(ROOT, "tests/ir_reference_citations.txt")

MAIN = re.compile(r'src/([a-z_0-9]+\.' + EXT + r'):(\d+)')
MD = re.compile(r'(?<![\w/.-])((?:docs/)?[A-Za-z][A-Za-z0-9_-]*\.md):(\d+)')
TAIL = re.compile(r'`?\s*(?:-|–|\.\.)\s*`?(\d+)`?')
CONT = re.compile(r'`?\s*(?:/|,|and)\s*`(\d{2,})`')
TICK = re.compile(r'`([A-Za-z_][A-Za-z0-9_]*)(?:\(\))?`')
FN = re.compile(r'^(?:pub\s+)?(?:@\w+(?:\([^)]*\))?\s+)*fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(')
SRC = re.compile(r'(?<![\w/.-])(?:src/)?([a-z_0-9]+\.' + EXT + r'):(\d+)')
SRC_MORE = re.compile(r'\s*(?:/|,)\s*:?(\d{2,})(?![\w.])')
SRC_HIST = re.compile(r'\s+(?:at|in)\s+[0-9a-f]{7,40}\b')
COMMENT_AT = re.compile(r'comment (?:in `[A-Za-z0-9_]+` )?(?:at|in)\s*\(?`?$', re.I)

def citations(text, pat):
    """(path, number, kind, doc line, start, text before) for every cited line."""
    res = []
    for ln, line in enumerate(text.split("\n"), 1):
        prev = 0
        for m in pat.finditer(line):
            f, n = m.group(1), int(m.group(2))
            seg = line[prev:m.start()]
            res.append((f, n, "start", ln, n, seg))
            pos = m.end()
            t = TAIL.match(line, pos)
            if t:
                res.append((f, int(t.group(1)), "end", ln, n, seg))
                pos = t.end()
            while True:
                c = CONT.match(line, pos)
                if not c:
                    break
                res.append((f, int(c.group(1)), "more", ln, int(c.group(1)), ""))
                pos = c.end()
            prev = pos
    return res

cache = {}
def lines_of(rel):
    if rel not in cache:
        p = os.path.join(ROOT, rel)
        cache[rel] = open(p, encoding="utf-8", errors="replace").read().split("\n") if os.path.isfile(p) else None
    return cache[rel]

spans = {}
def fn_spans(rel):
    """{function name: [(first line, last line)]} for a source file."""
    if rel not in spans:
        d, cur = {}, None
        for i, l in enumerate(lines_of(rel), 1):
            m = FN.match(l)
            if m:
                cur = m.group(1)
                d.setdefault(cur, []).append([i, i])
            elif cur is not None and l.startswith("}"):
                d[cur][-1][1] = i
                cur = None
        spans[rel] = d
    return spans[rel]

def md_target(name):
    if name.startswith("docs/"):
        return name
    for cand in ("docs/" + name, name):
        if os.path.isfile(os.path.join(ROOT, cand)):
            return cand
    return "docs/" + name

def prose_files():
    """Every file whose prose may cite a .md line, repo-relative, sorted."""
    res = []
    for name in sorted(os.listdir(ROOT)):
        if name.endswith(".md") and os.path.isfile(os.path.join(ROOT, name)):
            res.append(name)
    for sub in ("docs", "src"):
        top = os.path.join(ROOT, sub)
        for dp, dns, fns in os.walk(top):
            dns.sort()
            for fn in sorted(fns):
                if fn.endswith(".md") or (sub == "src" and fn.endswith("." + EXT)):
                    res.append(os.path.relpath(os.path.join(dp, fn), ROOT))
    if os.path.isfile(os.path.join(ROOT, "tests/run_tests.sh")):
        res.append("tests/run_tests.sh")
    return res

problems, rows = [], {}

def record(where, rel, n, kind, start):
    lines = lines_of(rel)
    if lines is None:
        problems.append(f"{where}: {rel} does not exist")
        return None
    if kind == "end" and n < start:
        problems.append(f"{where}: range {rel}:{start}-{n} runs backwards")
    if n < 1 or n > len(lines):
        problems.append(f"{where}: {rel}:{n} is past the end of the file ({len(lines)} lines)")
        return None
    content = lines[n - 1].strip()
    if not content:
        problems.append(f"{where}: {rel}:{n} is a blank line")
        return None
    rows[(rel, n)] = hashlib.sha1(content.encode()).hexdigest()[:12]
    return lines

def meaning(where, rel, lines, n, end, seg):
    """The two checks of what a citation SAYS (see the docstring)."""
    if end < n or end > len(lines):
        return
    if COMMENT_AT.search(seg.rstrip()) and not lines[n - 1].lstrip().startswith("//"):
        problems.append(f"{where}: {rel}:{n} is cited as a comment but is code: {lines[n - 1].strip()[:60]}")
    named = TICK.findall(seg)
    d = fn_spans(rel)
    fns = [x for x in named if x in d]
    if fns:
        window = "\n".join(lines[n - 1:end])
        ok = any(re.search(r'\b' + re.escape(x) + r'\b', window) for x in named)
        ok = ok or any(a <= end and n <= b for x in fns for a, b in d[x])
        if not ok:
            problems.append(f"{where}: {rel}:{n}" + (f"-{end}" if end != n else "")
                            + f" is cited for {', '.join(fns)} but is not in it and does not mention it")

# 1. docs/IR_REFERENCE.md -> src/*.<ext>, with the two meaning checks.
cites = citations(open(doc, encoding="utf-8").read(), MAIN)
for i, (f, n, kind, ln, start, seg) in enumerate(cites):
    rel = "src/" + f
    where = f"IR_REFERENCE.md:{ln}"
    lines = record(where, rel, n, kind, start)
    if lines is None or kind != "start":
        continue
    end = n
    if i + 1 < len(cites) and cites[i + 1][2] == "end" and cites[i + 1][3] == ln and cites[i + 1][4] == n:
        end = cites[i + 1][1]
    meaning(where, rel, lines, n, end, seg)

# 2. <NAME>.md:<line> anywhere in the tree's prose.
for src in prose_files():
    text = "\n".join(lines_of(src))
    for f, n, kind, ln, start, seg in citations(text, MD):
        record(f"{src}:{ln}", md_target(f), n, kind, start)

# 3. src/*.<ext> -> src/*.<ext>: a comment in one source file citing another
# (or itself), with the same two meaning checks.
for src in prose_files():
    if not (src.startswith("src/") and src.endswith("." + EXT)):
        continue
    for ln, line in enumerate(lines_of(src), 1):
        prev = 0
        for m in SRC.finditer(line):
            if line.count("`", 0, m.start()) % 2 == 1 or SRC_HIST.match(line, m.end()):
                continue
            f, n = m.group(1), int(m.group(2))
            rel, where, seg = "src/" + f, f"{src}:{ln}", line[prev:m.start()]
            end, pos = n, m.end()
            t = re.match(r'\s*(?:-|–)\s*(\d+)', line[pos:])
            if t:
                end = int(t.group(1))
                pos += t.end()
            lines = record(where, rel, n, "start", n)
            if end != n:
                record(where, rel, end, "end", n)
            while True:
                c = SRC_MORE.match(line, pos)
                if not c:
                    break
                record(where, rel, int(c.group(1)), "more", int(c.group(1)))
                pos = c.end()
            prev = pos
            if lines is not None:
                meaning(where, rel, lines, n, end, seg)

body = "\n".join(f"{rel}:{n} {h}" for (rel, n), h in sorted(rows.items(), key=lambda t: (t[0][0], t[0][1])))
header = ("# Generated by scripts/gen-ir-reference-citations.py -- do not hand-edit.\n"
          "# <citation> <sha1-12 of the stripped line it points at>\n")

if "--check" in sys.argv:
    # The citations' shape and meaning, then the manifest against the CURRENT
    # documents and files: a citation the manifest lacks, a manifest entry no
    # longer cited, and a line whose fingerprint changed are all reported.
    try:
        have = {}
        for raw in open(out):
            raw = raw.strip()
            if raw and not raw.startswith("#"):
                cite, h = raw.split()
                have[cite] = h
    except FileNotFoundError:
        problems.append("tests/ir_reference_citations.txt is missing")
        have = {}
    want = {f"{rel}:{n}": h for (rel, n), h in rows.items()}
    for cite in sorted(set(want) | set(have)):
        if cite not in have:
            problems.append(f"{cite} is cited but not in the manifest")
        elif cite not in want:
            problems.append(f"{cite} is in the manifest but no longer cited (or now invalid)")
        elif have[cite] != want[cite]:
            problems.append(f"{cite} moved: the line it was recorded against changed")
    for p in problems:
        print(p)
    sys.exit(1 if problems else 0)

if problems:
    for p in problems:
        print(p, file=sys.stderr)
    print("not writing the manifest: fix the citations above first", file=sys.stderr)
    sys.exit(1)
with open(out, "w") as fh:
    fh.write(header + body + "\n")
print(f"wrote {len(rows)} cited lines to {out}")
