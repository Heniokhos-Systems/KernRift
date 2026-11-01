#!/bin/bash
# pe_unwind_selftest.sh <workdir> [core|rules] -- self-test of
# tests/helpers/pe_unwind_check.py
# (#143, spec section 8.1; byte-identical in the KernRift and MLRift trees).
#
# A checker that accepts everything is worse than none, so every rule is shown
# to bite before it is trusted:
#   positives  llvm-mc assembles `.seh_*` snippets for x86_64 and arm64 Windows;
#              llvm's own unwind tables must decode exactly as llvm-readobj
#              decodes them, and every rule must PASS on them;
#   negatives  byte mutations of those objects (and of committed PE oracles),
#              each of which must FAIL with the rule id that owns the defect.
#
# Part `core` (default) covers C0-C2, part `rules` C3-C6 and C4b; each is its
# own suite row. Prints one line per case, then a summary line. Exit 0 = every case behaved;
# 1 = a case did not (the line says which); 77 = a required tool is absent
# (the last line says which -- the suite turns that into a counted SKIP).
set -u
W="${1:?usage: pe_unwind_selftest.sh <workdir> [core|rules]}"
PART="${2:-core}"
case "$PART" in core|rules) ;; *) echo "FAIL usage: part '$PART' is not core or rules"; exit 1 ;; esac
H="$(cd "$(dirname "$0")" && pwd)"
CHK="$H/pe_unwind_check.py"
OR="$H/../fixtures/pe_unwind_oracle"
for t in python3 llvm-mc llvm-readobj llvm-objdump; do
    command -v "$t" > /dev/null 2>&1 || { echo "SKIP-REASON: no $t"; exit 77; }
done
rm -rf "$W"; mkdir -p "$W"
N=0
fail() { echo "FAIL $1: $2"; exit 1; }
# expect <case> <rule> PASS|FAIL <checker args...>: the checker's line for
# <rule> must start with "<rule>: PASS" / "<rule>: FAIL".
expect() {
    local c="$1" r="$2" want="$3" out line; shift 3
    out=$(python3 "$CHK" --rules "$r" "$@" 2>&1)
    line=$(grep -m1 "^$r: " <<< "$out")
    case "$line" in
        "$r: $want"*) N=$((N + 1)); echo "  case $c: $r $want as required${line#"$r: $want"}" ;;
        *) fail "$c" "want $r $want, got: $(tr '\n' '|' <<< "$out" | head -c 300)" ;;
    esac
}

if [ "$PART" = core ]; then
# ---------------------------------------------------------------- positives
cat > "$W/x.s" <<'EOF'
        .text
        .def f1; .scl 2; .type 32; .endef
        .globl f1
        .seh_proc f1
f1:
        pushq %rbx
        .seh_pushreg %rbx
        pushq %rbp
        .seh_pushreg %rbp
        subq $0x98, %rsp
        .seh_stackalloc 0x98
        movq %rsp, %rbp
        .seh_setframe %rbp, 0
        .seh_endprologue
        leaq f3(%rip), %rax
        callq f2
        addq $0x98, %rsp
        popq %rbp
        popq %rbx
        retq
        .seh_endproc
        .def f2; .scl 2; .type 32; .endef
        .globl f2
        .seh_proc f2
f2:
        pushq %rbp
        .seh_pushreg %rbp
        subq $0x20, %rsp
        .seh_stackalloc 0x20
        movq %rsp, %rbp
        .seh_setframe %rbp, 0
        .seh_endprologue
        callq f3
        addq $0x20, %rsp
        popq %rbp
        retq
        .seh_endproc
        .def f3; .scl 2; .type 32; .endef
        .globl f3
        .seh_proc f3
f3:
        pushq %rbp
        .seh_pushreg %rbp
        movq %rsp, %rbp
        .seh_setframe %rbp, 0
        .seh_endprologue
        popq %rbp
        retq
        .seh_endproc
EOF
# arm64: no function may be packable (only full .xdata records are accepted),
# so each prologue carries a `.seh_nop`; g1 has one epilog (E bit, shared
# codes), g2 two epilogs (explicit scopes).
cat > "$W/a.s" <<'EOF'
        .text
        .def g1; .scl 2; .type 32; .endef
        .globl g1
        .seh_proc g1
g1:
        sub sp, sp, #32
        .seh_stackalloc 32
        stp x19, x20, [sp, #0]
        .seh_save_regp x19, 0
        stp x29, x30, [sp, #16]
        .seh_save_fplr 16
        add x29, sp, #16
        .seh_add_fp 16
        mov x9, x9
        .seh_nop
        .seh_endprologue
        bl g2
        .seh_startepilogue
        sub sp, x29, #16
        .seh_add_fp 16
        ldp x29, x30, [sp, #16]
        .seh_save_fplr 16
        ldp x19, x20, [sp, #0]
        .seh_save_regp x19, 0
        add sp, sp, #32
        .seh_stackalloc 32
        .seh_endepilogue
        ret
        .seh_endproc
        .def g2; .scl 2; .type 32; .endef
        .globl g2
        .seh_proc g2
g2:
        stp x29, x30, [sp, #-16]!
        .seh_save_fplr_x 16
        mov x29, sp
        .seh_set_fp
        mov x9, x9
        .seh_nop
        .seh_endprologue
        cbz x0, 1f
        .seh_startepilogue
        ldp x29, x30, [sp], #16
        .seh_save_fplr_x 16
        .seh_endepilogue
        ret
1:
        mov x0, #1
        .seh_startepilogue
        ldp x29, x30, [sp], #16
        .seh_save_fplr_x 16
        .seh_endepilogue
        ret
        .seh_endproc
EOF
llvm-mc -triple=x86_64-pc-windows-msvc -filetype=obj "$W/x.s" -o "$W/x.obj" 2> "$W/mc.err" || fail mc_x64 "$(head -c 200 "$W/mc.err")"
llvm-mc -triple=aarch64-pc-windows-msvc -filetype=obj "$W/a.s" -o "$W/a.obj" 2> "$W/mc.err" || fail mc_a64 "$(head -c 200 "$W/mc.err")"
for r in C1 C2; do
    expect "llvm_x64_$r" "$r" PASS --arch x86_64 "$W/x.obj"
    expect "llvm_a64_$r" "$r" PASS --arch arm64 "$W/a.obj"
done
# a committed PE whose tables a real loader accepted (the frame-pointer
# prototype): C0 and C1 (decode == llvm-readobj) must pass on an IMAGE too.
expect proto_image_C0 C0 PASS --arch x86_64 "$OR/nest8_fp.exe" --listing "$OR/nest8_fp.asm"
# The prototype keeps its UNWIND_INFO inside .pdata (the layout before the
# phase-2 review's M1): accepted only as an --oracle input ...
expect proto_image_C1 C1 PASS --arch x86_64 "$OR/nest8_fp.exe" --oracle
expect neg_combined_layout C1 FAIL --arch x86_64 "$OR/nest8_fp.exe"
# ... and its split-layout derivation (spec 6.1 as amended): .pdata exactly
# the RUNTIME_FUNCTION array, the records in an appended read-only .xdata.
# llvm-readobj must then decode exactly the real records. Two negatives from
# the same derivation: .pdata trimmed to the array but the UnwindInfo RVAs
# left at the old records (no longer in any section); a writable .xdata.
python3 - "$OR/nest8_fp.exe" "$W" <<'PYEOF' || fail split_derivation "could not derive the split images"
import struct, sys
src, w = sys.argv[1], sys.argv[2]
b0 = bytearray(open(src, 'rb').read())
pe = struct.unpack_from('<I', b0, 0x3C)[0]
nsec = struct.unpack_from('<H', b0, pe + 6)[0]
opt = struct.unpack_from('<H', b0, pe + 20)[0]
tab = pe + 24 + opt
dd3 = pe + 24 + 112 + 3 * 8
prva, psize = struct.unpack_from('<II', b0, dd3)
hdrs = [tab + 40 * i for i in range(nsec)]
ph = [h for h in hdrs if b0[h:h + 8].rstrip(b'\0') == b'.pdata'][0]
pvs, pva, praw, pptr = struct.unpack_from('<IIII', b0, ph + 8)
def make(name, xflags, move, trim=True):
    b = bytearray(b0)
    recs = bytes(b[pptr + psize:pptr + pvs])           # the records after the array
    while len(b) % 0x200:
        b.append(0)
    xoff = len(b)
    top = max(struct.unpack_from('<I', b, h + 12)[0] + struct.unpack_from('<I', b, h + 8)[0] for h in hdrs)
    xrva = (top + 0xFFF) & ~0xFFF
    b += recs + bytes((-len(recs)) % 0x200)
    if move:
        for k in range(psize // 12):
            u = struct.unpack_from('<I', b, pptr + 12 * k + 8)[0]
            struct.pack_into('<I', b, pptr + 12 * k + 8, xrva + (u - (pva + psize)))
    if trim:
        struct.pack_into('<I', b, ph + 8, psize)          # .pdata VirtualSize = the array
    xh = tab + 40 * nsec
    b[xh:xh + 8] = b'.xdata\0\0'
    struct.pack_into('<IIII', b, xh + 8, len(recs), xrva, len(recs) + (-len(recs)) % 0x200, xoff)
    struct.pack_into('<I', b, xh + 36, xflags)
    struct.pack_into('<H', b, pe + 6, nsec + 1)
    struct.pack_into('<I', b, pe + 24 + 56, (xrva + len(recs) + 0xFFF) & ~0xFFF)
    open('%s/%s.exe' % (w, name), 'wb').write(b)
make('split', 0x40000040, True)
make('split_records_in_pdata', 0x40000040, False)   # .pdata trimmed, RVAs still at the old records
make('split_writable_xdata', 0xC0000040, True)
PYEOF
expect proto_split_image_C1 C1 PASS --arch x86_64 "$W/split.exe"
python3 "$CHK" --rules C1 --arch x86_64 "$W/split.exe" 2>&1 | grep -q '^C1: PASS (4 records, llvm-readobj agrees)' \
    || fail proto_split_image_count "llvm-readobj must decode exactly the 4 real records: $(python3 "$CHK" --rules C1 --arch x86_64 "$W/split.exe" 2>&1)"
N=$((N + 1)); echo "  case proto_split_image_count: llvm-readobj decodes exactly the 4 real records"
expect neg_split_records_in_pdata C1 FAIL --arch x86_64 "$W/split_records_in_pdata.exe"
expect neg_split_writable_xdata C1 FAIL --arch x86_64 "$W/split_writable_xdata.exe"

# ---------------------------------------------------------------- negatives
# mutate <in> <out> <what>: one byte-level defect in a copy.
mutate() {
    python3 - "$1" "$2" "$3" <<'PYEOF' || fail "mutate_$3" "mutation could not be applied"
import struct, sys
src, dst, what = sys.argv[1:4]
b = bytearray(open(src, 'rb').read())
def sec(name):
    if b[:2] == b'MZ':
        pe = struct.unpack_from('<I', b, 0x3C)[0]; coff = pe + 4
    else:
        coff = 0
    n = struct.unpack_from('<H', b, coff + 2)[0]; opt = struct.unpack_from('<H', b, coff + 16)[0]
    for i in range(n):
        o = coff + 20 + opt + 40 * i
        if b[o:o + 8].rstrip(b'\0').decode() == name:
            return struct.unpack_from('<I', b, o + 20)[0], struct.unpack_from('<I', b, o + 16)[0]
    raise SystemExit('no section ' + name)
def add32(off, d):
    struct.pack_into('<I', b, off, (struct.unpack_from('<I', b, off)[0] + d) & 0xFFFFFFFF)
if what in ('unsorted', 'overlap', 'gap', 'misaligned'):
    p, _ = sec('.pdata')
    if what == 'unsorted':      # swap entries 0 and 1 (section-relative addends)
        b[p:p + 24] = b[p + 12:p + 24] + b[p:p + 12]
    elif what == 'overlap':     # entry 0 ends 4 bytes into entry 1
        add32(p + 4, 4)
    elif what == 'gap':         # entry 0 ends 1 byte early: a byte nobody covers
        add32(p + 4, -1)
    else:                       # entry 1's UNWIND_INFO address off by 2
        add32(p + 20, 2)
elif what == 'a64_unsorted':
    p, _ = sec('.pdata')
    b[p:p + 16] = b[p + 8:p + 16] + b[p:p + 8]
elif what == 'a64_flen':        # g1's .xdata FunctionLength one word too long
    x, _ = sec('.xdata')
    add32(x, 1)
elif what == 'a64_misaligned':  # g2's BeginAddress off by 2: not on an instruction
    p, _ = sec('.pdata')
    add32(p + 8, 2)
elif what == 'no_dd3':          # an image without DataDirectory[3]
    pe = struct.unpack_from('<I', b, 0x3C)[0]
    struct.pack_into('<II', b, pe + 24 + 112 + 8 * 3, 0, 0)
else:
    raise SystemExit('unknown mutation ' + what)
open(dst, 'wb').write(b)
PYEOF
}
mutate "$W/x.obj" "$W/x_unsorted.obj" unsorted
expect neg_x64_unsorted C1 FAIL --arch x86_64 "$W/x_unsorted.obj"
mutate "$W/x.obj" "$W/x_overlap.obj" overlap
expect neg_x64_overlap C1 FAIL --arch x86_64 "$W/x_overlap.obj"
mutate "$W/x.obj" "$W/x_gap.obj" gap
expect neg_x64_gap_C1_still_ok C1 PASS --arch x86_64 "$W/x_gap.obj"
expect neg_x64_gap C2 FAIL --arch x86_64 "$W/x_gap.obj"
mutate "$W/x.obj" "$W/x_mis.obj" misaligned
expect neg_x64_misaligned C1 FAIL --arch x86_64 "$W/x_mis.obj"
mutate "$W/a.obj" "$W/a_unsorted.obj" a64_unsorted
expect neg_a64_unsorted C1 FAIL --arch arm64 "$W/a_unsorted.obj"
# the swap only reorders the entries; the ORDER check itself must report it
python3 "$CHK" --rules C1 --arch arm64 "$W/a_unsorted.obj" 2>&1 | grep -q '^C1: FAIL entries 0/1 not strictly ascending' \
    || fail neg_a64_unsorted_by_order "the order-only swap was not reported as unsorted: $(python3 "$CHK" --rules C1 --arch arm64 "$W/a_unsorted.obj" 2>&1)"
N=$((N + 1)); echo "  case neg_a64_unsorted_by_order: C1 reports 'not strictly ascending' for the order-only swap"
mutate "$W/a.obj" "$W/a_flen.obj" a64_flen
expect neg_a64_function_length C1 FAIL --arch arm64 "$W/a_flen.obj"
mutate "$W/a.obj" "$W/a_mis.obj" a64_misaligned
expect neg_a64_misaligned C1 FAIL --arch arm64 "$W/a_mis.obj"
mutate "$OR/nest8_fp.exe" "$W/no_dd3.exe" no_dd3
expect neg_synthetic_pe_without_dd3 C1 FAIL --arch x86_64 "$W/no_dd3.exe"
# the base compiler's own image (d8f2a56): no tables at all
expect neg_base_image_nest C1 FAIL --arch x86_64 "$OR/nest.exe"
# C0 bites: one flipped code byte in the listing's image
python3 - "$OR/nest.exe" "$W/nest_flip.exe" <<'PYEOF'
import struct, sys
b = bytearray(open(sys.argv[1], 'rb').read())
pe = struct.unpack_from('<I', b, 0x3C)[0]; o = pe + 24 + 240
rawptr = struct.unpack_from('<I', b, o + 20)[0]
b[rawptr + 0x11] ^= 0x01
open(sys.argv[2], 'wb').write(b)
PYEOF
expect neg_c0_flipped_byte C0 FAIL --arch x86_64 "$W/nest_flip.exe" --listing "$OR/nest.asm"
expect pos_c0_base_image C0 PASS --arch x86_64 "$OR/nest.exe" --listing "$OR/nest.asm"
echo "selftest: $N cases behaved"
exit 0
fi

# ======================================================= C3..C6 and C4b (A2)
# mk <name> <x64|a64>: assemble $W/<name>.s (heredoc on stdin) into $W/<name>.obj
mk() {
    cat > "$W/$1.s"
    local tr=x86_64-pc-windows-msvc
    [ "$2" = a64 ] && tr=aarch64-pc-windows-msvc
    llvm-mc -triple=$tr -filetype=obj "$W/$1.s" -o "$W/$1.obj" 2> "$W/mc.err" || fail "mc_$1" "$(head -c 300 "$W/mc.err")"
}
# ann <name>: an annotation-only listing for $W/<name>.obj from the template on
# stdin, where {sym} is replaced by that symbol's .text offset in hex
ann() {
    local tpl; tpl=$(cat)
    python3 - "$W/$1.obj" "$W/$1.lst" "$tpl" <<'EOF2'
import re, subprocess, sys
syms = {}
for l in subprocess.run(['llvm-nm', sys.argv[1]], capture_output=True, text=True).stdout.split('\n'):
    f = l.split()
    if len(f) == 3:
        syms[f[2]] = int(f[0], 16)
t = sys.argv[3] + '\n'
open(sys.argv[2], 'w').write(re.sub(r'\{(\w+)\}', lambda m: '%x' % syms[m.group(1)], t))
EOF2
}
command -v llvm-nm > /dev/null 2>&1 || { echo "SKIP-REASON: no llvm-nm"; exit 77; }
ALLR=C1,C2,C3,C4,C4b,C5,C6
# expect_all <case> <checker args...>: every rule C1..C6 PASSes
expect_all() {
    local c="$1" out; shift
    out=$(python3 "$CHK" --rules $ALLR "$@" 2>&1)
    if grep -q ': FAIL' <<< "$out" || [ "$(grep -c ': PASS' <<< "$out")" != 7 ]; then
        fail "$c" "want C1..C6 PASS, got: $(grep -v ': PASS' <<< "$out" | tr '\n' '|' | head -c 400)"
    fi
    N=$((N + 1)); echo "  case $c: C1..C6 PASS as required"
}
# expect_only <case> <rule> <grep> <checker args...>: <rule> FAILs with a
# message matching <grep>, every other rule PASSes
expect_only() {
    local c="$1" r="$2" g="$3" out; shift 3
    out=$(python3 "$CHK" --rules $ALLR --verbose "$@" 2>&1)
    if ! grep -q "^$r: FAIL" <<< "$out" || ! grep -qE "$g" <<< "$out"; then
        fail "$c" "want $r FAIL matching '$g', got: $(tr '\n' '|' <<< "$out" | head -c 400)"
    fi
    local others; others=$(grep ': FAIL' <<< "$out" | grep -v "^$r: FAIL")
    [ -z "$others" ] || fail "$c" "only $r may fail, also: $(tr '\n' '|' <<< "$others" | head -c 300)"
    N=$((N + 1)); echo "  case $c: $r FAIL as required, every other rule PASS"
}

# ---- llvm-mc positives: FP frames, SAVE-free shapes, every ALLOC form ------
mk fp_frames x64 <<'EOF'
        .text
        .def h1; .scl 2; .type 32; .endef
        .globl h1
        .seh_proc h1
h1:
        pushq %rbx
        .seh_pushreg %rbx
        pushq %r12
        .seh_pushreg %r12
        pushq %rbp
        .seh_pushreg %rbp
        subq $0x90, %rsp
        .seh_stackalloc 0x90
        movq %rsp, %rbp
        .seh_setframe %rbp, 0
        .seh_endprologue
        movq %rax, %rbx
        callq h2
        addq $0x90, %rsp
        popq %rbp
        popq %r12
        popq %rbx
        retq
        .seh_endproc
        .def h2; .scl 2; .type 32; .endef
        .globl h2
        .seh_proc h2
h2:
        pushq %rbp
        .seh_pushreg %rbp
        subq $0x100000, %rsp
        .seh_stackalloc 0x100000
        movq %rsp, %rbp
        .seh_setframe %rbp, 0
        .seh_endprologue
        testq %rax, %rax
        je 1f
        callq h3
1:
        addq $0x100000, %rsp
        popq %rbp
        retq
        .seh_endproc
        .def h3; .scl 2; .type 32; .endef
        .globl h3
        .seh_proc h3
h3:
        pushq %rbp
        .seh_pushreg %rbp
        subq $0x20, %rsp
        .seh_stackalloc 0x20
        movq %rsp, %rbp
        .seh_setframe %rbp, 0
        .seh_endprologue
        addq $0x20, %rsp
        popq %rbp
        retq
        .seh_endproc
EOF
expect_all llvm_x64_fp_frames_alloc_small_large0_large1 --arch x86_64 "$W/fp_frames.obj"

# arm64: save_regp, save_fplr, save_fregp, add_fp, alloc_m after it, a shared
# epilog (E bit) and two explicit epilog scopes
mk a64_frames a64 <<'EOF'
        .text
        .def k1; .scl 2; .type 32; .endef
        .globl k1
        .seh_proc k1
k1:
        sub sp, sp, #48
        .seh_stackalloc 48
        stp x19, x20, [sp, #0]
        .seh_save_regp x19, 0
        stp x29, x30, [sp, #16]
        .seh_save_fplr 16
        stp d8, d9, [sp, #32]
        .seh_save_fregp d8, 32
        add x29, sp, #16
        .seh_add_fp 16
        sub sp, sp, #1024
        .seh_stackalloc 1024
        .seh_endprologue
        bl k2
        .seh_startepilogue
        sub sp, x29, #16
        .seh_add_fp 16
        ldp d8, d9, [sp, #32]
        .seh_save_fregp d8, 32
        ldp x29, x30, [sp, #16]
        .seh_save_fplr 16
        ldp x19, x20, [sp, #0]
        .seh_save_regp x19, 0
        add sp, sp, #48
        .seh_stackalloc 48
        .seh_endepilogue
        ret
        .seh_endproc
        .def k2; .scl 2; .type 32; .endef
        .globl k2
        .seh_proc k2
k2:
        mov x9, x9
        .seh_nop
        stp x29, x30, [sp, #-16]!
        .seh_save_fplr_x 16
        mov x29, sp
        .seh_set_fp
        .seh_endprologue
        cbz x0, 1f
        .seh_startepilogue
        mov sp, x29
        .seh_set_fp
        ldp x29, x30, [sp], #16
        .seh_save_fplr_x 16
        mov x9, x9
        .seh_nop
        .seh_endepilogue
        ret
1:
        mov x0, #1
        .seh_startepilogue
        mov sp, x29
        .seh_set_fp
        ldp x29, x30, [sp], #16
        .seh_save_fplr_x 16
        mov x9, x9
        .seh_nop
        .seh_endepilogue
        ret
        .seh_endproc
EOF
expect_all llvm_a64_save_regp_fplr_fregp_add_fp_alloc_m_scopes --arch arm64 "$W/a64_frames.obj"

# C3 bites: a code that no longer matches its instruction
python3 - "$W/fp_frames.obj" "$W/c3_x64.obj" "$W/a64_frames.obj" "$W/c3_a64.obj" <<'EOF'
import struct, sys
def sec(b, name):
    n = struct.unpack_from('<H', b, 2)[0]; opt = struct.unpack_from('<H', b, 16)[0]
    for i in range(n):
        o = 20 + opt + 40 * i
        if b[o:o + 8].rstrip(b'\0').decode() == name:
            return struct.unpack_from('<I', b, o + 20)[0]
b = bytearray(open(sys.argv[1], 'rb').read())
x = sec(b, '.xdata')
b[x + 4] -= 1                      # h1's first code (SET_FPREG) one byte early
open(sys.argv[2], 'wb').write(b)
b = bytearray(open(sys.argv[3], 'rb').read())
x = sec(b, '.xdata')
i = b.index(b'\xe2\x02', x)        # k1's add_fp #16 -> add_fp #24
b[i + 1] = 3
open(sys.argv[4], 'wb').write(b)
EOF
expect neg_c3_x64_code_offset C3 FAIL --arch x86_64 "$W/c3_x64.obj"
expect neg_c3_a64_add_fp C3 FAIL --arch arm64 "$W/c3_a64.obj"

# ---- body cases (x86_64) ---------------------------------------------------
# each frame: push rbp; mov rbp,rsp (SET_FPREG last), canonical epilogue
FR_PRO='        pushq %rbp
        .seh_pushreg %rbp
        movq %rsp, %rbp
        .seh_setframe %rbp, 0
        .seh_endprologue'
fn_wrap() {   # <name> <body file>: one function around a body
    printf '        .text\n        .def %s; .scl 2; .type 32; .endef\n        .globl %s\n        .seh_proc %s\n%s:\n%s\n' "$1" "$1" "$1" "$1" "$FR_PRO"
    cat "$2"
    printf '        popq %%rbp\n        retq\n        .seh_endproc\n'
}
body() { cat > "$W/body.s"; fn_wrap b "$W/body.s" | mk "$1" x64; }

# an IAT call with its 32-byte shadow space moves RSP inside the body: pass
body iat_shadow <<'EOF'
        subq $0x20, %rsp
        callq *__imp_GetStdHandle(%rip)
        addq $0x20, %rsp
EOF
expect_all body_iat_shadow --arch x86_64 "$W/iat_shadow.obj"

# one path leaves a push on the stack: C4b
body unbalanced <<'EOF'
        testq %rax, %rax
        je 1f
        pushq %rax
1:
EOF
expect_only body_unbalanced_path C4b 'inconsistent stack depth' --arch x86_64 "$W/unbalanced.obj"

# the fmt_uint digit loops, byte for byte as KR's IR backend emits them
# (ir.kr:10201-10271, measured from a --target=windows image)
cat > "$W/loopbody.s" <<'EOF'
        .byte 0x48,0x31,0xc9
        .byte 0x41,0xba,0x0a,0x00,0x00,0x00
lp_b:
        .byte 0x48,0x31,0xd2, 0x49,0xf7,0xf2, 0x80,0xc2,0x30, 0x52, 0x48,0xff,0xc1, 0x48,0x85,0xc0, 0x75,0xee
lp_e:
        .byte 0x48,0x89,0xc8
lq_b:
        .byte 0x5a, 0x88,0x17, 0x48,0xff,0xc7, 0x48,0xff,0xc9, 0x75,0xf5
lq_e:
EOF
fn_wrap b "$W/loopbody.s" | mk digit_loop x64
echo '; uw-loops {lp_b}-{lp_e} {lq_b}-{lq_e} rcx' | ann digit_loop
expect_all body_digit_loop_annotated --arch x86_64 "$W/digit_loop.obj" --listing "$W/digit_loop.lst"
printf '; (no annotation)\n' > "$W/none.lst"
expect_only body_digit_loop_unannotated C4b 'inconsistent stack depth' --arch x86_64 "$W/digit_loop.obj" --listing "$W/none.lst"
# the same pair TOP-tested (test; jz out at the top, jmp back at the bottom)
cat > "$W/loopbody.s" <<'EOF'
        xorq %rcx, %rcx
        movl $10, %r10d
lp_b:
        testq %rax, %rax
        je lp_e
        xorq %rdx, %rdx
        divq %r10
        addb $0x30, %dl
        pushq %rdx
        incq %rcx
        jmp lp_b
lp_e:
        movq %rcx, %rax
lq_b:
        testq %rcx, %rcx
        je lq_e
        popq %rdx
        movb %dl, (%rdi)
        incq %rdi
        decq %rcx
        jmp lq_b
lq_e:
EOF
fn_wrap b "$W/loopbody.s" | mk digit_loop_top x64
echo '; uw-loops {lp_b}-{lp_e} {lq_b}-{lq_e} rcx' | ann digit_loop_top
# guarded top-tested (ruling (c)): the pop header tests the counter, so the
# pair is safe at a zero count -- it passes since the C4b widening
expect_all body_digit_loop_top_tested --arch x86_64 "$W/digit_loop_top.obj" --listing "$W/digit_loop_top.lst"

# KR's LEGACY fmt_uint digit loops, byte for byte as codegen.kr emits them
# (`xor r10,r10`; push loop `test rax,rax; jz near out ... push rdx; inc r10;
# jmp near top`; pop loop `test r10,r10; jz near out; pop rcx ... dec r10;
# jmp near top`): guarded top-tested, counter r10 -- must PASS
legacy_loops() {   # <name> <push-loop body after the exit test> <between> <pop header> <pop body>
    cat > "$W/loopbody.s" <<EOF
        .byte 0x49,0x89,0xfb
        .byte 0x4d,0x31,0xd2
lp_b:
        .byte 0x48,0x85,0xc0, 0x0f,0x84
        .long lp_e - . - 4
$2
        .byte 0xe9
        .long lp_b - . - 4
lp_e:
$3
lq_b:
$4
        .byte 0x0f,0x84
        .long lq_e - . - 4
$5
        .byte 0xe9
        .long lq_b - . - 4
lq_e:
        .byte 0x4c,0x29,0xdf
EOF
    fn_wrap b "$W/loopbody.s" | mk "$1" x64
    echo '; uw-loops {lp_b}-{lp_e} {lq_b}-{lq_e} r10' | ann "$1"
}
LL_PUSH='        .byte 0x48,0x31,0xd2, 0x48,0xb9,0x0a,0,0,0,0,0,0,0, 0x48,0xf7,0xf1, 0x48,0x83,0xc2,0x30, 0x52, 0x49,0xff,0xc2'
LL_TEST='        .byte 0x4d,0x85,0xd2'
LL_POP='        .byte 0x59, 0x88,0x0f, 0x48,0xff,0xc7, 0x49,0xff,0xca'
legacy_loops legacy_loop "$LL_PUSH" '' "$LL_TEST" "$LL_POP"
expect_all body_legacy_digit_loop --arch x86_64 "$W/legacy_loop.obj" --listing "$W/legacy_loop.lst"
# ... and must FAIL with the guard removed (the pop header is not `test r10`)
legacy_loops ll_noguard "$LL_PUSH" '' '        .byte 0x90,0x90,0x90' "$LL_POP"
expect_only body_legacy_loop_guard_removed C4b 'does not start with .test r10, r10' --arch x86_64 "$W/ll_noguard.obj" --listing "$W/ll_noguard.lst"
# ... with the guard testing a different register (r11)
legacy_loops ll_otherreg "$LL_PUSH" '' '        .byte 0x4d,0x85,0xdb' "$LL_POP"
expect_only body_legacy_loop_guard_other_reg C4b 'does not start with .test r10, r10' --arch x86_64 "$W/ll_otherreg.obj" --listing "$W/ll_otherreg.lst"
# ... with two pushes per iteration
legacy_loops ll_twopush "$LL_PUSH
        .byte 0x52" '' "$LL_TEST" "$LL_POP"
expect_only body_legacy_loop_two_pushes C4b 'exactly one 8-byte register push' --arch x86_64 "$W/ll_twopush.obj" --listing "$W/ll_twopush.lst"
# ... with R written between the loops
legacy_loops ll_midwrite "$LL_PUSH" '        .byte 0x49,0x89,0xc2' "$LL_TEST" "$LL_POP"
expect_only body_legacy_loop_counter_written_between C4b 'r10 or RSP written between the loops' --arch x86_64 "$W/ll_midwrite.obj" --listing "$W/ll_midwrite.lst"
# ... with the `inc` on a conditional path (skipped when rdx is zero)
legacy_loops ll_condinc '        .byte 0x48,0x31,0xd2, 0x48,0xb9,0x0a,0,0,0,0,0,0,0, 0x48,0xf7,0xf1, 0x48,0x83,0xc2,0x30, 0x52, 0x48,0x85,0xd2, 0x74,0x03, 0x49,0xff,0xc2' '' "$LL_TEST" "$LL_POP"
expect_only body_legacy_loop_conditional_inc C4b 'exactly one branch before its back-edge' --arch x86_64 "$W/ll_condinc.obj" --listing "$W/ll_condinc.lst"

# ExitProcess ends its path: the unbalanced fall-through after it is dead
body exitproc <<'EOF'
        subq $0x20, %rsp
        xorl %ecx, %ecx
        callq *__imp_ExitProcess(%rip)
EOF
expect_all body_exitprocess_dead_end --arch x86_64 "$W/exitproc.obj"

# a dead-end leaf (the C7 die-routine shape): entered by jmp, realigns RSP,
# ends in ExitProcess, never returns
body deadend <<'EOF'
        testq %rax, %rax
        je 1f
        jmp die_b
1:
        jmp die_e
die_b:
        andq $-16, %rsp
        subq $0x20, %rsp
        xorl %ecx, %ecx
        callq *__imp_ExitProcess(%rip)
die_e:
EOF
echo '; uw-leaf die deadend {die_b}-{die_e}' | ann deadend
expect_all body_deadend_leaf --arch x86_64 "$W/deadend.obj" --listing "$W/deadend.lst"
# ... the same die routine NOT registered: `and rsp,-16` makes the depth
# unknown outside a dead-end leaf, which C4b refuses (phase-2 review, M3:
# otherwise dropping a die routine's registration went unnoticed)
expect_only body_deadend_unregistered C4b 'makes the stack depth unknown outside a registered dead-end leaf' --arch x86_64 "$W/deadend.obj" --listing "$W/none.lst"
# ... and entered by a conditional branch, as the C7 die routines are
body deadend_jcc <<'EOF'
        testq %rax, %rax
        jne die_b
        jmp die_e
die_b:
        andq $-16, %rsp
        subq $0x20, %rsp
        xorl %ecx, %ecx
        callq *__imp_ExitProcess(%rip)
die_e:
EOF
echo '; uw-leaf die deadend {die_b}-{die_e}' | ann deadend_jcc
expect_all body_deadend_leaf_by_jcc --arch x86_64 "$W/deadend_jcc.obj" --listing "$W/deadend_jcc.lst"
expect_only body_deadend_by_jcc_unregistered C4b 'makes the stack depth unknown outside a registered dead-end leaf' --arch x86_64 "$W/deadend_jcc.obj" --listing "$W/none.lst"
# arm64: ExitProcess through adrp x16 / ldr x16 / blr x16 ends the path (R3-N1);
# without that, the path would reach the epilog 16 bytes deep
mk a64_exit a64 <<'EOF'
        .text
        .def k3; .scl 2; .type 32; .endef
        .globl k3
        .seh_proc k3
k3:
        mov x9, x9
        .seh_nop
        stp x29, x30, [sp, #-16]!
        .seh_save_fplr_x 16
        mov x29, sp
        .seh_set_fp
        .seh_endprologue
        cbz x0, 2f
        sub sp, sp, #16
        mov x0, #3
        adrp x16, __imp_ExitProcess
        ldr x16, [x16, :lo12:__imp_ExitProcess]
        blr x16
2:
        .seh_startepilogue
        mov sp, x29
        .seh_set_fp
        ldp x29, x30, [sp], #16
        .seh_save_fplr_x 16
        mov x9, x9
        .seh_nop
        .seh_endepilogue
        ret
        .seh_endproc
EOF
expect_all a64_exitprocess_dead_end --arch arm64 "$W/a64_exit.obj"
# arm64 mirror of M3: a die routine that realigns SP (`and sp, x16, #-16`)
# passes only when registered as a dead-end leaf
mk a64_die a64 <<'EOF'
        .text
        .def k4; .scl 2; .type 32; .endef
        .globl k4
        .seh_proc k4
k4:
        mov x9, x9
        .seh_nop
        stp x29, x30, [sp, #-16]!
        .seh_save_fplr_x 16
        mov x29, sp
        .seh_set_fp
        .seh_endprologue
        cbnz x0, die_b
        b die_e
die_b:
        mov x16, sp
        and sp, x16, #-16
        mov x0, #3
        adrp x16, __imp_ExitProcess
        ldr x16, [x16, :lo12:__imp_ExitProcess]
        blr x16
die_e:
        .seh_startepilogue
        mov sp, x29
        .seh_set_fp
        ldp x29, x30, [sp], #16
        .seh_save_fplr_x 16
        mov x9, x9
        .seh_nop
        .seh_endepilogue
        ret
        .seh_endproc
EOF
echo '; uw-leaf die deadend {die_b}-{die_e}' | ann a64_die
expect_all a64_deadend_leaf --arch arm64 "$W/a64_die.obj" --listing "$W/a64_die.lst"
expect_only a64_deadend_unregistered C4b 'makes the stack depth unknown outside a registered dead-end leaf' --arch arm64 "$W/a64_die.obj" --listing "$W/none.lst"

# ... and the dead end is decided by the import's NAME: the same code calling
# another import walks on into the unbalanced epilogue
sed 's/__imp_ExitProcess/__imp_ExitThread/' "$W/exitproc.s" | mk exitthread x64
expect body_other_import_not_dead_end C4b FAIL --arch x86_64 "$W/exitthread.obj"
sed 's/__imp_ExitProcess/__imp_ExitThread/g' "$W/a64_exit.s" | mk a64_exitthread a64
expect a64_other_import_not_dead_end C4b FAIL --arch arm64 "$W/a64_exitthread.obj"

# a called internal leaf with its own frame (the C7 parse-leaf shape): its
# `add rsp,0x100; ret` and bare `ret` are epilogues to both unwinders, which
# land on the leaf's return site; C6 then needs the second unwind (R3-M4)
body leaf <<'EOF'
        callq leaf_b
        jmp leaf_e
leaf_b:
        testq %rax, %rax
        je 2f
        subq $0x100, %rsp
        movq $0, (%rsp)
        addq $0x100, %rsp
        retq
2:
        retq
leaf_e:
EOF
echo '; uw-leaf parse called {leaf_b}-{leaf_e}' | ann leaf
expect_all body_called_leaf_two_step --arch x86_64 "$W/leaf.obj" --listing "$W/leaf.lst"

# an rbp write after the prologue: C4 (C6 sees the broken frame too)
body rbpw <<'EOF'
        movq %rax, %rbp
EOF
out=$(python3 "$CHK" --rules C4 --arch x86_64 "$W/rbpw.obj" 2>&1)
case "$out" in "C4: FAIL"*"writes rbp"*) N=$((N + 1)); echo "  case body_rbp_write: C4 FAIL as required" ;;
    *) fail body_rbp_write "want C4 FAIL (writes rbp), got: $out" ;; esac

# naked functions: zero-code records; RSP motion in one is C5
mk naked x64 <<'EOF'
        .text
        .def n1; .scl 2; .type 32; .endef
        .globl n1
        .seh_proc n1
n1:
        .seh_endprologue
        movl $1, %eax
        retq
        .seh_endproc
EOF
echo '; uw-naked n1' | ann naked
expect_all naked_rsp_neutral --arch x86_64 "$W/naked.obj" --listing "$W/naked.lst"
expect_only naked_unmarked C5 'not marked naked' --arch x86_64 "$W/naked.obj" --listing "$W/none.lst"
mk naked_push x64 <<'EOF'
        .text
        .def n2; .scl 2; .type 32; .endef
        .globl n2
        .seh_proc n2
n2:
        .seh_endprologue
        pushq %rax
        popq %rax
        retq
        .seh_endproc
EOF
echo '; uw-naked n2' | ann naked_push
# (C6 fails as well: the leaf rule is wrong while the push is live)
expect naked_rsp_write C5 FAIL --arch x86_64 "$W/naked_push.obj" --listing "$W/naked_push.lst"

# Wine-only epilogue rule (N-Mi2): a jmp INSIDE the function to a pop/ret
# sequence is an epilogue to Wine (it follows the jmp), not to Windows. Here the
# jmp at +0x5 runs with a push live, so AT THAT OFFSET only the Wine rule set
# unwinds wrongly; at the pops after it both do (and C4b sees the imbalance).
body wine_jmp <<'EOF'
        pushq %rax
        jmp 1f
1:
EOF
out=$(python3 "$CHK" --rules C6 --verbose --arch x86_64 "$W/wine_jmp.obj" 2>&1)
if grep -q '^C6: FAIL' <<< "$out" && grep -q 'C6 problem: b: wine rule at +0x5: ' <<< "$out" \
   && ! grep -q 'C6 problem: b: native rule at +0x5: ' <<< "$out"; then
    N=$((N + 1)); echo "  case wine_only_epilogue_jmp: at the jmp (+0x5) C6 fails under the Wine rule only, as required"
else fail wine_only_epilogue_jmp "want a Wine-only C6 problem at +0x5, got: $(tr '\n' '|' <<< "$out" | head -c 400)"; fi

# SAVE_NONVOL before SET_FPREG (the shape spec section 4.2 gives the legacy
# backend). wine-9.0 computes the establisher frame from the frame register
# even inside the prologue (signal_x86_64.c RtlVirtualUnwind), so at the one
# offset between the save and `mov rbp,rsp` it restores the saved register
# from the caller's rbp. C6 reports exactly that offset; native is correct.
mk save_nonvol x64 <<'EOF'
        .text
        .def s1; .scl 2; .type 32; .endef
        .globl s1
        .seh_proc s1
s1:
        pushq %rbx
        .seh_pushreg %rbx
        pushq %rbp
        .seh_pushreg %rbp
        subq $0x28, %rsp
        .seh_stackalloc 0x28
        movq %r12, 0x20(%rsp)
        .seh_savereg %r12, 0x20
        movq %rsp, %rbp
        .seh_setframe %rbp, 0
        .seh_endprologue
        movq 0x20(%rsp), %r12
        addq $0x28, %rsp
        popq %rbp
        popq %rbx
        retq
        .seh_endproc
EOF
out=$(python3 "$CHK" --rules $ALLR --verbose --arch x86_64 "$W/save_nonvol.obj" 2>&1)
if [ "$(grep -c ': PASS' <<< "$out")" = 5 ] && grep -q '^C6: FAIL' <<< "$out" \
   && grep -q '^C3: FAIL' <<< "$out" && grep -q 's1: SAVE_NONVOL store at +0x6 comes before SET_FPREG' <<< "$out" \
   && [ "$(grep -c 'C6 problem' <<< "$out")" = 1 ] && grep -q 'C6 problem: s1: wine rule at +0xb: R12 restored' <<< "$out"; then
    N=$((N + 1)); echo "  case save_nonvol_before_set_fpreg: C3 FAIL (amended order, ruling (b)), C6 FAIL at exactly +0xb under the Wine rule (wine-9.0 frame rule), C1 C2 C4 C4b C5 PASS"
else fail save_nonvol_before_set_fpreg "got: $(tr '\n' '|' <<< "$out" | head -c 500)"; fi

# the legacy x64 prologue of ruling (b): the r12 save FOLLOWS SET_FPREG, as
# [rsp+d] and as [rbp+d] -- every rule passes, C6 under both rule sets
for SV in 'movq %r12, 0x20(%rsp)' 'movq %r12, 0x20(%rbp)'; do
    SVN=rsp; case "$SV" in *rbp*) SVN=rbp ;; esac
    mk save_after_$SVN x64 <<EOF
        .text
        .def s2; .scl 2; .type 32; .endef
        .globl s2
        .seh_proc s2
s2:
        pushq %rbx
        .seh_pushreg %rbx
        pushq %rbp
        .seh_pushreg %rbp
        subq \$0x28, %rsp
        .seh_stackalloc 0x28
        movq %rsp, %rbp
        .seh_setframe %rbp, 0
        $SV
        .seh_savereg %r12, 0x20
        .seh_endprologue
        movq %rax, %r12
        movq 0x20(%rsp), %r12
        addq \$0x28, %rsp
        popq %rbp
        popq %rbx
        retq
        .seh_endproc
EOF
    expect_all save_nonvol_after_set_fpreg_$SVN --arch x86_64 "$W/save_after_$SVN.obj"
done
# after SET_FPREG only SAVE_NONVOL stores may follow: an allocation there fails C3
mk alloc_after_fp x64 <<'EOF'
        .text
        .def s3; .scl 2; .type 32; .endef
        .globl s3
        .seh_proc s3
s3:
        pushq %rbp
        .seh_pushreg %rbp
        movq %rsp, %rbp
        .seh_setframe %rbp, 0
        subq $0x20, %rsp
        .seh_stackalloc 0x20
        .seh_endprologue
        addq $0x20, %rsp
        popq %rbp
        retq
        .seh_endproc
EOF
out=$(python3 "$CHK" --rules C3 --arch x86_64 "$W/alloc_after_fp.obj" 2>&1)
case "$out" in
    "C3: FAIL s3: prologue instruction at +0x4 (sub) follows SET_FPREG and is not a SAVE_NONVOL store"*)
        N=$((N + 1)); echo "  case neg_c3_alloc_after_set_fpreg: C3 FAIL as required" ;;
    *) fail neg_c3_alloc_after_set_fpreg "got: $(tr '\n' '|' <<< "$out" | head -c 300)" ;;
esac

# alignment (phase-2 review, M2): a frame that CALLS must keep RSP 16-aligned
# at its calls -- 8 + 8 x pushes + ALLOC = 0 mod 16. One push and a 0x18
# allocation is 8 + 8 + 24 = 40: C3 fails if the function calls, and the very
# same frame in a leaf passes.
for AL in call leaf; do
    CALL=''; [ "$AL" = call ] && CALL='        callq al_leaf'
    mk align_$AL x64 <<EOF
        .text
        .def al_f; .scl 2; .type 32; .endef
        .globl al_f
        .seh_proc al_f
al_f:
        pushq %rbp
        .seh_pushreg %rbp
        subq \$0x18, %rsp
        .seh_stackalloc 0x18
        movq %rsp, %rbp
        .seh_setframe %rbp, 0
        .seh_endprologue
$CALL
        addq \$0x18, %rsp
        popq %rbp
        retq
        .seh_endproc
        .def al_leaf; .scl 2; .type 32; .endef
        .globl al_leaf
        .seh_proc al_leaf
al_leaf:
        pushq %rbp
        .seh_pushreg %rbp
        movq %rsp, %rbp
        .seh_setframe %rbp, 0
        .seh_endprologue
        popq %rbp
        retq
        .seh_endproc
EOF
done
expect_only neg_c3_misaligned_calling_frame C3 'al_f: frame misaligns RSP at its calls: 8 \+ 8\*1 pushes \+ ALLOC 24 = 40' --arch x86_64 "$W/align_call.obj"
expect_all pos_c3_misaligned_leaf_frame --arch x86_64 "$W/align_leaf.obj"

# ---- the phase-1 reviewer's adversarial cases, pinned --------------------
# a call into the MIDDLE of a function: neither a BeginAddress nor a leaf (C2)
mk midcall x64 <<'EOF'
        .text
        .def m1; .scl 2; .type 32; .endef
        .globl m1
        .seh_proc m1
m1:
        pushq %rbp
        .seh_pushreg %rbp
        movq %rsp, %rbp
        .seh_setframe %rbp, 0
        .seh_endprologue
        callq m2_mid
        popq %rbp
        retq
        .seh_endproc
        .def m2; .scl 2; .type 32; .endef
        .globl m2
        .seh_proc m2
m2:
        pushq %rbp
        .seh_pushreg %rbp
        movq %rsp, %rbp
        .seh_setframe %rbp, 0
        .seh_endprologue
        nop
m2_mid:
        popq %rbp
        retq
        .seh_endproc
EOF
expect adv_mid_function_call C2 FAIL --arch x86_64 "$W/midcall.obj"
# epilogues that are not the prologue's mirror (C4): pops reversed, one missing
mk_epi() {   # <name> <epilogue lines>
    { printf '        .text\n        .def e; .scl 2; .type 32; .endef\n        .globl e\n        .seh_proc e\ne:\n'
      printf '        pushq %%rbx\n        .seh_pushreg %%rbx\n        pushq %%rbp\n        .seh_pushreg %%rbp\n'
      printf '        movq %%rsp, %%rbp\n        .seh_setframe %%rbp, 0\n        .seh_endprologue\n'
      printf '%s\n        retq\n        .seh_endproc\n' "$2"; } | mk "$1" x64
}
mk_epi epi_reversed "$(printf '        popq %%rbx\n        popq %%rbp')"
expect adv_pops_reversed C4 FAIL --arch x86_64 "$W/epi_reversed.obj"
mk_epi epi_missing "$(printf '        popq %%rbp')"
expect adv_pop_missing C4 FAIL --arch x86_64 "$W/epi_missing.obj"
# a bare ret in the body, outside any registered leaf (C4)
body bare_ret <<'EOF'
        testq %rax, %rax
        je 1f
        retq
1:
EOF
expect adv_bare_ret_outside_leaf C4 FAIL --arch x86_64 "$W/bare_ret.obj"
# UNWIND_INFO header mutations of h1 (fp_frames): version 2, the EHANDLER flag
# (C1); FrameOffset 1, SizeOfProlog one too long (C3)
python3 - "$W/fp_frames.obj" "$W" <<'EOF'
import struct, sys
b0 = open(sys.argv[1], 'rb').read()
def sec(b, name):
    n = struct.unpack_from('<H', b, 2)[0]; opt = struct.unpack_from('<H', b, 16)[0]
    for i in range(n):
        o = 20 + opt + 40 * i
        if b[o:o + 8].rstrip(b'\0').decode() == name:
            return struct.unpack_from('<I', b, o + 20)[0]
x = sec(b0, '.xdata')
for name, off, val in (('ver2', 0, 0x02), ('ehandler', 0, 0x01 | (1 << 3)), ('frameoff1', 3, 0x15), ('prolog_plus1', 1, None)):
    b = bytearray(b0)
    b[x + off] = val if val is not None else b[x + off] + 1
    open('%s/hdr_%s.obj' % (sys.argv[2], name), 'wb').write(b)
EOF
expect adv_unwind_info_version_2 C1 FAIL --arch x86_64 "$W/hdr_ver2.obj"
expect adv_unwind_info_ehandler_flag C1 FAIL --arch x86_64 "$W/hdr_ehandler.obj"
expect adv_frame_offset_1 C3 FAIL --arch x86_64 "$W/hdr_frameoff1.obj"
expect adv_frame_offset_1_c6 C6 FAIL --arch x86_64 "$W/hdr_frameoff1.obj"
expect adv_size_of_prolog_plus_1 C3 FAIL --arch x86_64 "$W/hdr_prolog_plus1.obj"
# --functions / --code-end are refused without --oracle
out=$(python3 "$CHK" --rules C6 --arch x86_64 "$OR/nest8_fp.exe" --listing "$OR/nest8_fp.asm" --functions f3 2>&1); rc=$?
if [ "$rc" = 2 ] && grep -q 'add --oracle' <<< "$out"; then N=$((N + 1)); echo "  case escape_hatch_needs_oracle: --functions refused without --oracle (rc 2)"
else fail escape_hatch_needs_oracle "rc=$rc: $out"; fi

# ---- committed prototype images (spec section 2.4 / 1.3) ------------------
out=$(python3 "$CHK" --rules C6 --verbose --arch x86_64 "$OR/nest8_uw.exe" --listing "$OR/nest8_uw.asm" --oracle --code-end 32c 2>&1)
if grep -q '^C6: FAIL' <<< "$out" && grep -q 'C6 problem: f2: native rule at +0x98: ' <<< "$out"; then
    N=$((N + 1)); echo "  case proto_static_rsp_nest8_uw: C6 FAIL, incl. f2+0x98 (= +0x11a9, the RetAddr-0x10 frame cdb measured)"
else fail proto_static_rsp_nest8_uw "want C6 FAIL at f2+0x98, got: $(grep -v problem <<< "$out" | tr '\n' '|' | head -c 300)"; fi
out=$(python3 "$CHK" --rules C3,C4,C4b,C5,C6 --arch x86_64 "$OR/nest8_fp.exe" --listing "$OR/nest8_fp.asm" --oracle --code-end 33f --functions f3,f2 2>&1)
if [ "$(grep -c ': PASS (restricted to 2 functions by --functions (--oracle)' <<< "$out")" = 5 ]; then
    N=$((N + 1)); echo "  case proto_frame_pointer_nest8_fp: C3..C6 PASS, each saying it was restricted to f3 and f2 (main is split by the prototype's pre-prologue argv block)"
else fail proto_frame_pointer_nest8_fp "got: $(tr '\n' '|' <<< "$out" | head -c 400)"; fi
echo "selftest: $N cases behaved"
