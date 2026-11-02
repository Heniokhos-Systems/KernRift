#!/usr/bin/env python3
"""win_file_err_shape.py -- static shape check of the Windows I/O builtin arms.

Checks that the PE image's lowering of read/file_read, file_size, write,
file_write and alloc carries the error handling and std-fd mapping that
#136 #138 #145 #162 #163 #165 #167 #168 #171 require, on a backend with no
Windows runner (arm64) as well as one with Wine (x86_64).

usage:
  win_file_err_shape.py --arch x86_64|arm64 [--legacy] [--rules a,b,...] FILE.exe LISTING.s
  win_file_err_shape.py --selftest

The functions checked are the `sh_*` labels of LISTING.s, the compiler's
--emit=asm listing of the same source. Each is located BY ITS LISTING OFFSET
(listing offsets are .text offsets), never by searching for its bytes: on the
IR backend sh_write/sh_fwrite (and sh_read/sh_rd) compile to identical code.
Each label must occur exactly once, and the image bytes at that offset must
equal the listing's, except the address fields a link resolves (x86_64:
the disp32 after e8/e9 or a rip-relative ModRM; arm64: adrp/bl words and the
ldr/add after an adrp). Only those ranges are inspected, so main, the hosted
prologue and the runtime's fatal-message helpers -- whose WriteFile result is
discarded -- are never looked at.

Rules (each inside every sh_* range, in program order):
  a  every ReadFile call: BOOL test right after it, GetLastError call,
     `cmp eax,109` / `cmp w0,#109` right after that, -5 afterwards, and the
     "data wins" count test (IR: before the GetLastError call; legacy x86_64:
     test rax,rax after it; arm64: a cbnz on the count before it)
  b  every GetFileSizeEx call: preceded by the std-fd guard (cmp ...,2 and an
     unsigned ja/b.hi that jumps over a GetStdHandle call) and followed by a
     BOOL test and -5
  c  (legacy) every ReadFile call is preceded by the std-fd guard
  d  every WriteFile call: BOOL test, count test and -5 after it
  e  (legacy) every WriteFile call is preceded by the std-fd guard
  f  every VirtualAlloc call is preceded by the #171 clamp
     (x86_64: cmp r,8 ; sbb ; or -- arm64: cmp x,#8 ; csinv ...,hs)
Every rule also needs at least one site of its call, so no rule passes vacuously.

Exit 0 = every requested rule holds; 1 = a violation (printed); 2 = usage/input.
"""
import struct
import sys

MINUS5_X86 = bytes([0x48, 0xC7, 0xC0, 0xFB, 0xFF, 0xFF, 0xFF])
MOVN_M5 = 0x92800080          # movn x0, #4  (x0 = -5)
CMP_W0_109 = 0x7101B41F       # cmp w0, #109


class Fail(Exception):
    pass


# ---------------------------------------------------------------------- PE --
def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def parse_pe(data):
    if data[:2] != b"MZ":
        raise Fail("not a PE image")
    lf = u32(data, 0x3C)
    nsec = u16(data, lf + 6)
    optsz = u16(data, lf + 20)
    opt = lf + 24
    imgbase = struct.unpack_from("<Q", data, opt + 24)[0]
    imp_rva = u32(data, opt + 120)
    secs = []
    for i in range(nsec):
        h = opt + optsz + 40 * i
        name = data[h:h + 8].rstrip(b"\0").decode("latin1")
        vsz, va, rsz, rp = struct.unpack_from("<IIII", data, h + 8)
        secs.append((name, va, max(vsz, rsz), rp, rsz))

    def rva2off(rva):
        for _n, va, sz, rp, rsz in secs:
            if va <= rva < va + sz:
                return rp + (rva - va)
        raise Fail("rva 0x%x outside every section" % rva)

    text = [s for s in secs if s[0] == ".text"]
    if not text:
        raise Fail("no .text section")
    _n, tva, _sz, trp, trsz = text[0]
    tbytes = data[trp:trp + trsz]
    iat = {}                                   # IAT slot RVA -> import name
    d = rva2off(imp_rva)
    while True:
        ilt, _t, _f, _nm, ft = struct.unpack_from("<IIIII", data, d)
        if ilt == 0 and ft == 0:
            break
        k = 0
        while True:
            e = struct.unpack_from("<Q", data, rva2off(ilt) + 8 * k)[0]
            if e == 0:
                break
            if not e >> 63:
                o = rva2off(e & 0x7FFFFFFF) + 2
                end = data.index(b"\0", o)
                iat[ft + 8 * k] = data[o:end].decode("latin1")
            k += 1
        d += 20
    return tva, tbytes, iat, imgbase


# ----------------------------------------------------------------- listing --
def parse_listing(text, arch):
    """-> {label: (start, bytes)} with the listing's own bytes per function."""
    funcs, order, cur = {}, [], None
    for line in text.splitlines():
        s = line.rstrip()
        if not s or s.startswith(";"):
            continue
        if not s.startswith(" ") and s.endswith(":"):
            cur = s[:-1]
            order.append(cur)
            funcs.setdefault(cur, [])
            continue
        if cur is None:
            continue
        t = s.strip()
        if ":" not in t:
            continue
        off_s, rest = t.split(":", 1)
        try:
            off = int(off_s, 16)
        except ValueError:
            continue
        toks = rest.split()
        bs = bytearray()
        if arch == "arm64":
            if toks and len(toks[0]) == 8:
                bs += struct.pack("<I", int(toks[0], 16))
        else:
            for tk in toks:
                if len(tk) == 2:
                    try:
                        bs.append(int(tk, 16))
                        continue
                    except ValueError:
                        pass
                break
        funcs[cur].append((off, bytes(bs)))
    out = {}
    for name in order:
        if order.count(name) != 1:
            raise Fail("label %s occurs %d times in the listing" % (name, order.count(name)))
        chunks = funcs[name]
        if not chunks:
            continue
        start = chunks[0][0]
        blob = bytearray()
        for off, bs in chunks:
            if off != start + len(blob):
                raise Fail("listing of %s is not contiguous at 0x%x" % (name, off))
            blob += bs
        out[name] = (start, bytes(blob))
    return out


def verify_x86(lst, img):
    """Image bytes must equal the listing's except link-resolved disp32 fields."""
    i, n = 0, len(lst)
    while i < n:
        if lst[i] == img[i]:
            i += 1
            continue
        # a mismatch must sit inside a 4-byte field that follows e8/e9 or a
        # rip-relative ModRM (mod=00, rm=101)
        ok = False
        for s in range(max(1, i - 3), i + 1):
            p = lst[s - 1]
            if p in (0xE8, 0xE9) or (p & 0xC7) == 0x05:
                if s <= i < s + 4:
                    ok = True
                    break
        if not ok:
            return i
        i += 1
    return None


def verify_a64(lst, img):
    for k in range(0, len(lst), 4):
        a = u32(lst, k)
        b = u32(img, k)
        if a == b:
            continue
        if (a & 0x9F000000) == 0x90000000:          # adrp
            continue
        if (a & 0xFC000000) == 0x94000000:          # bl
            continue
        if k >= 4 and (u32(lst, k - 4) & 0x9F000000) == 0x90000000:
            continue                                # ldr/add after adrp
        return k
    return None


# ------------------------------------------------------------- call decode --
def x86_calls(code, base_va, iat):
    """[(pos, name, length)] of `ff 15 disp32` IAT calls in code."""
    out = []
    for i in range(len(code) - 5):
        if code[i] == 0xFF and code[i + 1] == 0x15:
            disp = struct.unpack_from("<i", code, i + 2)[0]
            tgt = base_va + i + 6 + disp
            if tgt in iat:
                out.append((i, iat[tgt], 6))
    return out


def a64_calls(code, base_va, iat, imgbase):
    out = []
    for k in range(0, len(code) - 11, 4):
        w = u32(code, k)
        if (w & 0x9F00001F) == 0x90000010 and (u32(code, k + 4) & 0xFFC003FF) == 0xF9400210 \
                and u32(code, k + 8) == 0xD63F0200:
            imm = (((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3)
            if imm & 0x100000:
                imm -= 0x200000
            pc = imgbase + base_va + k
            page = (pc & ~0xFFF) + (imm << 12)
            tgt = page + ((u32(code, k + 4) >> 10) & 0xFFF) * 8 - imgbase
            if tgt in iat:
                out.append((k, iat[tgt], 12))
    return out


def find(code, pat, start, end):
    j = code.find(pat, start, end)
    return j if j >= 0 else None


# ------------------------------------------------------------------- rules --
def x86_guard_before(code, calls, ci, lo):
    """std-fd guard before calls[ci]: cmp r,2 ; ja over a GetStdHandle call."""
    pos = calls[ci][0]
    for i in range(lo, pos):
        if code[i] == 0x48 and code[i + 1] == 0x83 and code[i + 2] in (0xF8, 0xF9, 0xFA) \
                and code[i + 3] == 0x02 and code[i + 4] == 0x77:
            tgt = i + 6 + code[i + 5]
            for p, name, _l in calls:
                if name == "GetStdHandle" and i + 6 <= p < tgt <= pos:
                    return True
    return False


def a64_guard_before(code, calls, ci, lo):
    pos = calls[ci][0]
    for k in range(lo, pos - 4, 4):
        if (u32(code, k) & 0xFFFFFC1F) == 0xF100081F:          # cmp xN, #2
            w = u32(code, k + 4)
            if (w & 0xFF00001F) == 0x54000008:                 # b.hi
                tgt = k + 4 + ((w >> 5) & 0x7FFFF) * 4
                for p, name, _l in calls:
                    if name == "GetStdHandle" and k + 8 <= p < tgt <= pos:
                        return True
    return False


def check_range(arch, legacy, code, calls, rules, fname):
    errs = []

    def prev_end(ci):
        return calls[ci - 1][0] + calls[ci - 1][2] if ci > 0 else 0

    for ci, (pos, name, ln) in enumerate(calls):
        after = pos + ln
        nxt = calls[ci + 1][0] if ci + 1 < len(calls) else len(code)
        where = "%s+0x%x %s" % (fname, pos, name)
        if arch == "x86_64":
            if name == "ReadFile" and "a" in rules:
                if code[after:after + 2] != b"\x85\xC0" or 0x75 not in code[after + 2:after + 10]:
                    errs.append(where + ": no BOOL test (test eax,eax ; jnz) right after the call")
                gle = [c for c in calls[ci + 1:] if c[1] == "GetLastError"]
                if not gle or gle[0][0] - after > 64:
                    errs.append(where + ": no GetLastError call after it")
                else:
                    g = gle[0][0] + 6
                    if code[g:g + 3] != b"\x83\xF8\x6D":
                        errs.append(where + ": GetLastError not followed by cmp eax,109")
                    m5 = find(code, MINUS5_X86, g, g + 64)
                    if m5 is None:
                        errs.append(where + ": no mov rax,-5")
                    if legacy:
                        if m5 is None or find(code, b"\x48\x85\xC0", g, m5) is None:
                            errs.append(where + ": no data-wins test (test rax,rax) before -5")
                    else:
                        if code[after:gle[0][0]].count(b"\x85\xC0") < 2:
                            errs.append(where + ": no data-wins test (second test eax,eax) before GetLastError")
            if name == "ReadFile" and "c" in rules and legacy:
                if not x86_guard_before(code, calls, ci, 0):
                    errs.append(where + ": no std-fd guard before it")
            if name == "GetFileSizeEx" and "b" in rules:
                if not x86_guard_before(code, calls, ci, 0):
                    errs.append(where + ": no std-fd guard before it")
                win = code[after:after + 40]
                if (b"\x85\xC0\x48\x8B\x44\x24\x20\x75" not in win and b"\x85\xC9\x75" not in win) or MINUS5_X86 not in win:
                    errs.append(where + ": no BOOL test and -5 after it")
            if name == "WriteFile" and "d" in rules:
                win = code[after:after + 40]
                if win[:2] != b"\x85\xC0" or win.count(b"\x85\xC0") < 2 or MINUS5_X86 not in win:
                    errs.append(where + ": no BOOL test, count test and -5 after it")
            if name == "WriteFile" and "e" in rules and legacy:
                if not x86_guard_before(code, calls, ci, 0):
                    errs.append(where + ": no std-fd guard before it")
            if name == "VirtualAlloc" and "f" in rules:
                lo = prev_end(ci)
                seg = code[lo:pos]
                ok = False
                for i in range(len(seg) - 9):
                    if seg[i] == 0x48 and seg[i + 1] == 0x83 and seg[i + 3] == 0x08 \
                            and seg[i + 4] == 0x48 and seg[i + 5] == 0x19 \
                            and seg[i + 7] == 0x48 and seg[i + 8] == 0x09:
                        ok = True
                if not ok:
                    errs.append(where + ": no #171 clamp (cmp r,8 ; sbb ; or) before it")
        else:
            w = lambda k: u32(code, k) if k + 4 <= len(code) else 0
            if name == "ReadFile" and "a" in rules:
                if (w(after) & 0xFF00001F) != 0x35000000:
                    errs.append(where + ": no cbnz w0 right after the call")
                gle = [c for c in calls[ci + 1:] if c[1] == "GetLastError"]
                if not gle or gle[0][0] - after > 64:
                    errs.append(where + ": no GetLastError call after it")
                else:
                    g = gle[0][0] + 12
                    if w(g) != CMP_W0_109:
                        errs.append(where + ": GetLastError not followed by cmp w0,#109")
                    if not any(w(k) == MOVN_M5 for k in range(g, g + 24, 4)):
                        errs.append(where + ": no movn x0,#4 after it")
                    data = [k for k in range(after + 4, gle[0][0], 4)
                            if (w(k) & 0x7F00001F) in (0x35000009, 0x35000000) and k != after]
                    if not data:
                        errs.append(where + ": no data-wins cbnz on the count before GetLastError")
            if name == "ReadFile" and "c" in rules and legacy:
                if not a64_guard_before(code, calls, ci, 0):
                    errs.append(where + ": no std-fd guard before it")
            if name == "GetFileSizeEx" and "b" in rules:
                if not a64_guard_before(code, calls, ci, 0):
                    errs.append(where + ": no std-fd guard before it")
                if (w(after) & 0xFF00001F) != 0x35000000 or not any(w(k) == MOVN_M5 for k in range(after, after + 16, 4)):
                    errs.append(where + ": no cbnz w0 and -5 after it")
            if name == "WriteFile" and "d" in rules:
                win = [w(k) for k in range(after, after + 32, 4)]
                if not any((x & 0xFF00001F) == 0x35000000 for x in win) or MOVN_M5 not in win and 0x92800089 not in win:
                    errs.append(where + ": no BOOL test and -5 after it")
            if name == "WriteFile" and "e" in rules and legacy:
                if not a64_guard_before(code, calls, ci, 0):
                    errs.append(where + ": no std-fd guard before it")
            if name == "VirtualAlloc" and "f" in rules:
                lo = prev_end(ci)
                ok = False
                for k in range(lo, pos - 4, 4):
                    if (w(k) & 0xFFFFFC1F) == 0xF100201F and (w(k + 4) & 0xFFFFFC00) == 0xDA9F2000:
                        ok = True
                if not ok:
                    errs.append(where + ": no #171 clamp (cmp x,#8 ; csinv ...,hs) before it")
    # unguarded GetStdHandle (rule e, legacy): every GetStdHandle in the range
    # must be jumped over by a guard
    if "e" in rules and legacy:
        for ci, (pos, name, ln) in enumerate(calls):
            if name != "GetStdHandle":
                continue
            guarded = False
            if arch == "x86_64":
                for i in range(0, pos):
                    if code[i] == 0x48 and code[i + 1] == 0x83 and code[i + 3] == 0x02 and code[i + 4] == 0x77 \
                            and i + 6 <= pos < i + 6 + code[i + 5]:
                        guarded = True
            else:
                for k in range(0, pos - 4, 4):
                    if (u32(code, k) & 0xFFFFFC1F) == 0xF100081F and (u32(code, k + 4) & 0xFF00001F) == 0x54000008:
                        if k + 8 <= pos < k + 4 + ((u32(code, k + 4) >> 5) & 0x7FFFF) * 4:
                            guarded = True
            if not guarded:
                errs.append("%s+0x%x GetStdHandle: called with no fd<=2 guard (#168)" % (fname, pos))
    return errs


NEED = {"a": "ReadFile", "b": "GetFileSizeEx", "c": "ReadFile", "d": "WriteFile",
        "e": "WriteFile", "f": "VirtualAlloc"}


def run(arch, legacy, rules, pe_bytes, listing_text):
    tva, tbytes, iat, imgbase = parse_pe(pe_bytes)
    funcs = parse_listing(listing_text, arch)
    sh = {k: v for k, v in funcs.items() if k.startswith("sh_")}
    if not sh:
        raise Fail("no sh_* function in the listing")
    errs, seen = [], {}
    for fname, (start, lst) in sorted(sh.items()):
        img = tbytes[start:start + len(lst)]
        if len(img) != len(lst):
            errs.append("%s: listing range 0x%x+%d runs past .text" % (fname, start, len(lst)))
            continue
        bad = verify_x86(lst, img) if arch == "x86_64" else verify_a64(lst, img)
        if bad is not None:
            errs.append("%s: image bytes differ from the listing at +0x%x (wrong offset?)" % (fname, bad))
            continue
        calls = x86_calls(img, tva + start, iat) if arch == "x86_64" else a64_calls(img, tva + start, iat, imgbase)
        for _p, nm, _l in calls:
            seen[nm] = seen.get(nm, 0) + 1
        errs += check_range(arch, legacy, img, calls, rules, fname)
    for r in rules:
        if (r in "ce") and not legacy:
            continue
        if not seen.get(NEED[r]):
            errs.append("rule %s: no %s call in any sh_* function (vacuous)" % (r, NEED[r]))
    return errs, seen


# ---------------------------------------------------------------- selftest --
def selftest():
    """Synthetic x86_64 images: offset-located identical functions, rule a."""
    fails = 0
    IAT_RF, IAT_GLE = 0x3000, 0x3008

    def call(at, slot):          # ff 15 disp32 at code offset `at` (text VA 0x1000)
        return b"\xFF\x15" + struct.pack("<i", slot - (0x1000 + at + 6))

    def body(at, good):
        c = bytearray(call(at, IAT_RF))
        c += b"\x85\xC0\x8B\x44\x24\x28\x75\x10\x85\xC0\x75\x0C"
        c += call(at + len(c), IAT_GLE)
        c += (b"\x83\xF8\x6D" if good else b"\x83\xF8\x6C") + b"\xB8\x00\x00\x00\x00\x74\x07" + MINUS5_X86 + b"\xC3"
        return bytes(c)

    def listing(fs):
        out = ["; KernRift assembly listing", ""]
        for name, off, b in fs:
            out.append(name + ":")
            out.append("  %08x: %s  x" % (off, " ".join("%02x" % x for x in b)))
        return "\n".join(out) + "\n"

    def image(code):
        return code

    def check(code, lst_text):
        errs = []
        funcs = parse_listing(lst_text, "x86_64")
        iat = {IAT_RF: "ReadFile", IAT_GLE: "GetLastError"}
        for fname, (start, lst) in funcs.items():
            img = code[start:start + len(lst)]
            if verify_x86(lst, img) is not None:
                errs.append(fname + ": mismatch")
                continue
            errs += check_range("x86_64", False, img, x86_calls(img, 0x1000 + start, iat), "a", fname)
        return errs

    # two byte-identical functions at different offsets: each found at its own
    a = body(0, True)
    b = body(len(a), True)
    code = a + b
    e = check(code, listing([("sh_one", 0, a), ("sh_two", len(a), b)]))
    if e:
        print("selftest FAIL: identical functions at two offsets: %s" % e)
        fails += 1
    # the second copy is bad: only it fails
    b2 = body(len(a), False)
    e = check(a + b2, listing([("sh_one", 0, a), ("sh_two", len(a), b2)]))
    if len(e) != 1 or not e[0].startswith("sh_two"):
        print("selftest FAIL: bad second copy not isolated: %s" % e)
        fails += 1
    # a wrong offset in the listing is a mismatch, not a silent pass
    e = check(a + b, listing([("sh_one", 0, a), ("sh_two", 3, b)]))
    if not any("mismatch" in x for x in e):
        print("selftest FAIL: wrong listing offset not detected: %s" % e)
        fails += 1
    # a duplicated label is refused
    try:
        parse_listing(listing([("sh_one", 0, a), ("sh_one", len(a), b)]), "x86_64")
        print("selftest FAIL: duplicate label accepted")
        fails += 1
    except Fail:
        pass
    # missing BOOL test
    nb = bytearray(a)
    nb[6:8] = b"\x90\x90"
    e = check(bytes(nb), listing([("sh_one", 0, bytes(nb))]))
    if not any("BOOL" in x for x in e):
        print("selftest FAIL: missing BOOL test not detected: %s" % e)
        fails += 1
    print("selftest: %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
    return 1 if fails else 0


def main(argv):
    if argv[1:] == ["--selftest"]:
        return selftest()
    arch, legacy, rules, files = None, False, "abcdef", []
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--arch":
            arch = argv[i + 1]; i += 2; continue
        if a == "--legacy":
            legacy = True; i += 1; continue
        if a == "--rules":
            rules = argv[i + 1].replace(",", ""); i += 2; continue
        files.append(a); i += 1
    if arch not in ("x86_64", "arm64") or len(files) != 2:
        print(__doc__.split("\n\n")[1])
        return 2
    try:
        pe = open(files[0], "rb").read()
        lst = open(files[1], encoding="latin1").read()
        errs, seen = run(arch, legacy, rules, pe, lst)
    except (Fail, OSError, struct.error, ValueError) as e:
        print("win_file_err_shape: error: %s" % e)
        return 2
    if errs:
        for e in errs[:12]:
            print("FAIL " + e)
        return 1
    print("win_file_err_shape: PASS (%s; rules %s)" % (
        ", ".join("%s x%d" % kv for kv in sorted(seen.items())), rules))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
