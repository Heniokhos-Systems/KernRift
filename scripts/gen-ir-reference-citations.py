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

ONLY FILES THAT ARE PART OF THE TREE COUNT, on both sides of a citation. When
ROOT is the top of a git work tree, the tree is what
`git ls-files --cached --others --exclude-standard` lists: every tracked file,
plus the untracked ones git's standard ignore rules do not exclude (a new doc a
contributor has not `git add`ed yet is checked, and so is a file a suite row
plants in a scratch repo), and NEVER an ignored one. docs/superpowers/ is
ignored and holds local planning notes that cite long-gone line numbers;
walking it made the check fail on a working checkout while passing on every
fresh clone. An ignored file is also not a valid citation TARGET: it does not
exist in a clone, so a citation of one says "does not exist".

"Ignored" is git's full standard set: the .gitignore files, .git/info/exclude,
and the user's core.excludesFile. Those last two are per-checkout and per-user,
on purpose: they only ever decide about UNTRACKED files, which no clone has, and
a note a user ignores locally is the same case as docs/superpowers/. (Turning
the user's config off would also drop safe.directory, and fail a checkout git
itself accepts.) The variables that say WHICH repo git is in are removed from
its environment (GIT_LOCATION_VARS below), so a hook's GIT_DIR or
GIT_INDEX_FILE, or a push quarantine's GIT_OBJECT_DIRECTORY, cannot point the
listing at another repo or fail it. Configuration from the environment
(GIT_CONFIG_COUNT/KEY_n/VALUE_n, GIT_CONFIG_PARAMETERS, GIT_CONFIG_GLOBAL, ...)
and GIT_EXEC_PATH are kept: they are where safe.directory and core.excludesFile
may come from, and the listing must agree with the git the user runs.

ls-files lists a nested untracked repo, or a submodule, as its directory and
not its files, so files inside one are not part of the tree: they are not
scanned, and a citation into one says "does not exist".

When ROOT has no .git of its own (an exported copy, a scratch copy that may sit
inside some other repo) every file on disk counts, as before. When it HAS one
but git cannot list it (git not installed, "dubious ownership", a corrupt
index), the checker stops with git's message and exit status 2 instead of
silently walking the disk, which would bring the ignored files back.

After editing src/, the docs, or the citations, CHECK EACH CITATION AGAINST THE
CODE, then:
    python3 scripts/gen-ir-reference-citations.py
tests/run_tests.sh runs it with --check.
"""
import hashlib, re, sys, os, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXT = "mlr" if os.path.exists(os.path.join(ROOT, "src", "main.mlr")) else "kr"
doc = os.path.join(ROOT, "docs/IR_REFERENCE.md")
out = os.path.join(ROOT, "tests/ir_reference_citations.txt")

# The repo-location variables: `git rev-parse --local-env-vars` minus its
# configuration entries (GIT_CONFIG, GIT_CONFIG_PARAMETERS, GIT_CONFIG_COUNT),
# plus the two that steer repository discovery (GIT_CEILING_DIRECTORIES,
# GIT_DISCOVERY_ACROSS_FILESYSTEM). A fixed list, so that what is stripped does
# not depend on the git installed, and so that it is the same list
# tests/run_tests.sh unsets (KR_GIT_LOCATION_VARS); git 2.43 and 2.53 print
# the same --local-env-vars. The suite row
# ir_reference_citations_skips_ignored_files fails if the two lists differ, or
# if the git it runs names a location variable missing from them. The
# *_PATHSPECS variables are not stripped: the one ls-files below takes no
# pathspec.
GIT_LOCATION_VARS = (
    "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_OBJECT_DIRECTORY", "GIT_DIR",
    "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE", "GIT_INDEX_FILE",
    "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_PREFIX",
    "GIT_SHALLOW_FILE", "GIT_COMMON_DIR", "GIT_CEILING_DIRECTORIES",
    "GIT_DISCOVERY_ACROSS_FILESYSTEM",
)

def tree_files():
    """The repo-relative paths that are part of the tree (see the docstring),
    or None when ROOT has no .git of its own: then everything on disk counts.
    Exits 2 when ROOT has a .git but git cannot list it."""
    own = os.path.lexists(os.path.join(ROOT, ".git"))
    env = {k: v for k, v in os.environ.items() if k not in GIT_LOCATION_VARS}
    def git(*args):
        try:
            r = subprocess.run(["git", "-C", ROOT] + list(args), env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError as e:
            return None, f"cannot run git: {e}"
        err = r.stderr.decode("utf-8", "replace").strip()
        return (r.stdout.decode("utf-8", "surrogateescape") if r.returncode == 0 else None), err
    def refuse(why):
        print(f"{ROOT} has a .git, but {why}", file=sys.stderr)
        print("not walking the disk instead: that would count the ignored files too", file=sys.stderr)
        sys.exit(2)
    top, err = git("rev-parse", "--show-toplevel")
    if top is None or os.path.realpath(top.strip()) != os.path.realpath(ROOT):
        if own:
            refuse(f"git rev-parse --show-toplevel failed: {err}" if top is None
                   else f"git says the top of its work tree is {top.strip()}")
        return None
    out, err = git("ls-files", "-z", "--cached", "--others", "--exclude-standard")
    if out is None:
        refuse(f"git ls-files failed: {err}")
    return set(p for p in out.split("\0") if p)

TREE = tree_files()

def in_tree(rel):
    """rel exists and is part of the tree."""
    if not os.path.isfile(os.path.join(ROOT, rel)):
        return False
    return TREE is None or os.path.normpath(rel).replace(os.sep, "/") in TREE

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
        cache[rel] = open(p, encoding="utf-8", errors="replace").read().split("\n") if in_tree(rel) else None
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
        if in_tree(cand):
            return cand
    return "docs/" + name

def prose_files():
    """Every file of the tree whose prose may cite a .md line, repo-relative,
    sorted. Only files that are part of the tree (see the docstring)."""
    res = []
    for name in sorted(os.listdir(ROOT)):
        if name.endswith(".md") and in_tree(name):
            res.append(name)
    for sub in ("docs", "src"):
        top = os.path.join(ROOT, sub)
        for dp, dns, fns in os.walk(top):
            dns.sort()
            for fn in sorted(fns):
                rel = os.path.relpath(os.path.join(dp, fn), ROOT)
                if (fn.endswith(".md") or (sub == "src" and fn.endswith("." + EXT))) and in_tree(rel):
                    res.append(rel)
    if in_tree("tests/run_tests.sh"):
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
