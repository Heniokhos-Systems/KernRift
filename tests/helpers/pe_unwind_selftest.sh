#!/bin/bash
# pe_unwind_selftest.sh <workdir> -- self-test of tests/helpers/pe_unwind_check.py
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
# Prints one line per case, then a summary line. Exit 0 = every case behaved;
# 1 = a case did not (the line says which); 77 = a required tool is absent
# (the last line says which -- the suite turns that into a counted SKIP).
set -u
W="${1:?usage: pe_unwind_selftest.sh <workdir>}"
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
expect proto_image_C1 C1 PASS --arch x86_64 "$OR/nest8_fp.exe"

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
