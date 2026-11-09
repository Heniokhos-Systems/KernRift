# pe_unwind_selftest_optc.sh -- part `optc` of pe_unwind_selftest.sh (sourced
# by it, never run alone): the option-C frame shapes and rule C3b (#143,
# spec sections 2.5.3 and 2.5.4; plan A19a).
#
# Positives: SP-fixed x64 frames (IR with and without rbp pushed as a colour,
# legacy with SAVE_NONVOL r12), arm64 shape S1, shape S2 at every boundary of
# its low allocation (4080, 4096, 4112, 16 777 200), the D fallback at
# 16 777 216, and the arm64 legacy frame without set_fp, all pass C1..C6 and
# C3b, and so does an arm64 legacy folded frame at OUT = 488 (#143 A19d(iii)).
# Negatives: an SP-fixed record over a body that writes RSP/SP (one case per
# instruction class) fails C3b, an S1 save offset of 512, the folded frame at
# OUT = 496 and an rbp write without PUSH_NONVOL fail C3, and a zero-size
# allocation fails C3.

# ---- x86_64 ----------------------------------------------------------------
X_G='        .def g; .scl 2; .type 32; .endef
        .globl g
        .seh_proc g
g:
        subq $8, %rsp
        .seh_stackalloc 8
        .seh_endprologue
        movq %rcx, %rax
        addq $8, %rsp
        retq
        .seh_endproc'
# xfix <name> <body file>: an SP-fixed IR frame (push rbx, push r12, sub 40)
# around a body, plus the callee g
xfix() {
    { printf '        .text\n        .def f; .scl 2; .type 32; .endef\n        .globl f\n        .seh_proc f\nf:\n'
      printf '        pushq %%rbx\n        .seh_pushreg %%rbx\n        pushq %%r12\n        .seh_pushreg %%r12\n'
      printf '        subq $40, %%rsp\n        .seh_stackalloc 40\n        .seh_endprologue\n'
      cat "$2"
      printf '        addq $40, %%rsp\n        popq %%r12\n        popq %%rbx\n        retq\n        .seh_endproc\n'
      printf '%s\n' "$X_G"; } | mk "$1" x64
}
xbody() { cat > "$W/xbody.s"; xfix "$1" "$W/xbody.s"; }

xbody x_fixed <<'EOF'
        movq %rcx, %rbx
        callq g
        addq %rbx, %rax
EOF
expect_all optc_x64_ir_sp_fixed --arch x86_64 "$W/x_fixed.obj"

mk x_rbp_colour x64 <<EOF
        .text
        .def f; .scl 2; .type 32; .endef
        .globl f
        .seh_proc f
f:
        pushq %rbx
        .seh_pushreg %rbx
        pushq %rbp
        .seh_pushreg %rbp
        subq \$8, %rsp
        .seh_stackalloc 8
        .seh_endprologue
        movq %rcx, %rbp
        callq g
        addq %rbp, %rax
        addq \$8, %rsp
        popq %rbp
        popq %rbx
        retq
        .seh_endproc
$X_G
EOF
expect_all optc_x64_ir_sp_fixed_rbp_colour --arch x86_64 "$W/x_rbp_colour.obj"

mk x_legacy x64 <<EOF
        .text
        .def f; .scl 2; .type 32; .endef
        .globl f
        .seh_proc f
f:
        pushq %rbx
        .seh_pushreg %rbx
        subq \$64, %rsp
        .seh_stackalloc 64
        movq %r12, 24(%rsp)
        .seh_savereg %r12, 24
        .seh_endprologue
        movq %rcx, %r12
        callq g
        addq %r12, %rax
        movq 24(%rsp), %r12
        addq \$64, %rsp
        popq %rbx
        retq
        .seh_endproc
$X_G
EOF
expect_all optc_x64_legacy_sp_fixed_save_nonvol --arch x86_64 "$W/x_legacy.obj"

# an SP-moving (frame-pointer) record over a body that moves no RSP: the
# conservative default passes
mk x_fp_fixed_body x64 <<EOF
        .text
        .def f; .scl 2; .type 32; .endef
        .globl f
        .seh_proc f
f:
        pushq %rbp
        .seh_pushreg %rbp
        movq %rsp, %rbp
        .seh_setframe %rbp, 0
        .seh_endprologue
        callq g
        popq %rbp
        retq
        .seh_endproc
$X_G
EOF
expect_all optc_x64_frame_pointer_over_fixed_body --arch x86_64 "$W/x_fp_fixed_body.obj"

# negatives: each RSP-writing instruction class in the body of an SP-fixed
# record fails C3b
xbody x_shadow <<'EOF'
        subq $0x20, %rsp
        callq g
        addq $0x20, %rsp
EOF
expect optc_neg_x64_shadow_c3b C3b FAIL --arch x86_64 "$W/x_shadow.obj"
expect optc_neg_x64_shadow_c6 C6 FAIL --arch x86_64 "$W/x_shadow.obj"
xbody x_push <<'EOF'
        pushq %rax
        popq %rax
EOF
expect optc_neg_x64_push_pop C3b FAIL --arch x86_64 "$W/x_push.obj"
xbody x_pushimm <<'EOF'
        pushq $7
        popq %rax
EOF
expect optc_neg_x64_push_imm C3b FAIL --arch x86_64 "$W/x_pushimm.obj"
xbody x_pushf <<'EOF'
        pushfq
        popfq
EOF
expect optc_neg_x64_pushf_popf C3b FAIL --arch x86_64 "$W/x_pushf.obj"
xbody x_xchg <<'EOF'
        xchgq %rax, %rsp
        xchgq %rax, %rsp
EOF
expect optc_neg_x64_xchg_rsp C3b FAIL --arch x86_64 "$W/x_xchg.obj"
xbody x_leave <<'EOF'
        leaveq
EOF
expect optc_neg_x64_leave C3b FAIL --arch x86_64 "$W/x_leave.obj"
xbody x_enter <<'EOF'
        .byte 0xc8, 0x00, 0x00, 0x00    # enter 0, 0
EOF
expect optc_neg_x64_enter C3b FAIL --arch x86_64 "$W/x_enter.obj"
xbody x_and <<'EOF'
        andq $-16, %rsp
EOF
expect optc_neg_x64_and_rsp C3b FAIL --arch x86_64 "$W/x_and.obj"
# rbp written by the body of a FrameRegister-0 record that did not push it
xbody x_rbp_nopush <<'EOF'
        movq %rcx, %rbp
EOF
expect_only optc_neg_x64_rbp_without_push_nonvol C3 'without a PUSH_NONVOL rbp' --arch x86_64 "$W/x_rbp_nopush.obj"
# a zero-size allocation (sub rsp,0 with ALLOC 0): C3. llvm-mc refuses
# `.seh_stackalloc 0`, so a 136-byte frame (ALLOC_LARGE/0, imm32 forms) is
# assembled and both immediates and the code's size are zeroed
mk x_zero x64 <<EOF
        .text
        .def f; .scl 2; .type 32; .endef
        .globl f
        .seh_proc f
f:
        pushq %rbx
        .seh_pushreg %rbx
        subq \$136, %rsp
        .seh_stackalloc 136
        .seh_endprologue
        movq %rcx, %rax
        addq \$136, %rsp
        popq %rbx
        retq
        .seh_endproc
EOF
python3 - "$W/x_zero.obj" <<'PYZ'
import struct, sys
b = bytearray(open(sys.argv[1], 'rb').read())
def sec(name):
    n = struct.unpack_from('<H', b, 2)[0]; opt = struct.unpack_from('<H', b, 16)[0]
    for i in range(n):
        o = 20 + opt + 40 * i
        if b[o:o + 8].rstrip(b'\0').decode() == name:
            return struct.unpack_from('<I', b, o + 20)[0]
for pat in (b'\x48\x81\xec\x88\x00\x00\x00', b'\x48\x81\xc4\x88\x00\x00\x00'):
    i = b.index(pat)
    b[i + 3:i + 7] = b'\0\0\0\0'
x = sec('.xdata')
for k in range(b[x + 2]):
    op = b[x + 4 + 2 * k + 1]
    if op == 0x01:                       # ALLOC_LARGE, OpInfo 0: size/8 in the next slot
        assert struct.unpack_from('<H', b, x + 6 + 2 * k)[0] == 17
        struct.pack_into('<H', b, x + 6 + 2 * k, 0)
        break
else:
    raise SystemExit('no ALLOC_LARGE/0 code')
open(sys.argv[1], 'wb').write(b)
PYZ
expect optc_neg_x64_zero_size_alloc C3 FAIL --arch x86_64 "$W/x_zero.obj"

# ---- arm64 -----------------------------------------------------------------
A_K='        .def k; .scl 2; .type 32; .endef
        .globl k
        .seh_proc k
k:
        sub sp, sp, #16
        .seh_stackalloc 16
        stp x29, x30, [sp, #0]
        .seh_save_fplr 0
        .seh_endprologue
        add x0, x0, #1
        .seh_startepilogue
        ldp x29, x30, [sp, #0]
        .seh_save_fplr 0
        add sp, sp, #16
        .seh_stackalloc 16
        .seh_endepilogue
        ret
        .seh_endproc'
# afix <name> <body file>: an S1 frame (sub 48, x19/x20 at 16, fplr at 32)
afix() {
    { printf '        .text\n        .def f; .scl 2; .type 32; .endef\n        .globl f\n        .seh_proc f\nf:\n'
      printf '        sub sp, sp, #48\n        .seh_stackalloc 48\n'
      printf '        stp x19, x20, [sp, #16]\n        .seh_save_regp x19, 16\n'
      printf '        stp x29, x30, [sp, #32]\n        .seh_save_fplr 32\n        .seh_endprologue\n'
      cat "$2"
      printf '        .seh_startepilogue\n        ldp x29, x30, [sp, #32]\n        .seh_save_fplr 32\n'
      printf '        ldp x19, x20, [sp, #16]\n        .seh_save_regp x19, 16\n'
      printf '        add sp, sp, #48\n        .seh_stackalloc 48\n        .seh_endepilogue\n        ret\n        .seh_endproc\n'
      printf '%s\n' "$A_K"; } | mk "$1" a64
}
abody() { cat > "$W/abody.s"; afix "$1" "$W/abody.s"; }

abody a_s1 <<'EOF'
        mov x19, x0
        bl k
        add x0, x0, x19
EOF
expect_all optc_a64_s1 --arch arm64 "$W/a_s1.obj"

# S2 at low = hi*4096 + lo: the lsl #12 instruction only when hi > 0, the #lo
# one only when lo > 0 (spec 2.5.3 boundaries)
s2() {   # <name> <hi> <lo>
    local hi="$2" lo="$3" pro="" epi=""
    [ "$hi" -gt 0 ] && pro="$pro        sub sp, sp, #$hi, lsl #12
        .seh_stackalloc $((hi * 4096))
"
    [ "$lo" -gt 0 ] && pro="$pro        sub sp, sp, #$lo
        .seh_stackalloc $lo
"
    [ "$lo" -gt 0 ] && epi="$epi        add sp, sp, #$lo
        .seh_stackalloc $lo
"
    [ "$hi" -gt 0 ] && epi="$epi        add sp, sp, #$hi, lsl #12
        .seh_stackalloc $((hi * 4096))
"
    mk "$1" a64 <<EOF
        .text
        .def f; .scl 2; .type 32; .endef
        .globl f
        .seh_proc f
f:
        sub sp, sp, #32
        .seh_stackalloc 32
        stp x19, x20, [sp, #0]
        .seh_save_regp x19, 0
        stp x29, x30, [sp, #16]
        .seh_save_fplr 16
$pro        .seh_endprologue
        mov x19, x0
        bl k
        add x0, x0, x19
        .seh_startepilogue
$epi        ldp x29, x30, [sp, #16]
        .seh_save_fplr 16
        ldp x19, x20, [sp, #0]
        .seh_save_regp x19, 0
        add sp, sp, #32
        .seh_stackalloc 32
        .seh_endepilogue
        ret
        .seh_endproc
$A_K
EOF
}
s2 a_s2_4080 0 4080
expect_all optc_a64_s2_low_4080_no_lsl12 --arch arm64 "$W/a_s2_4080.obj"
s2 a_s2_4096 1 0
expect_all optc_a64_s2_low_4096_lsl12_only --arch arm64 "$W/a_s2_4096.obj"
s2 a_s2_4112 1 16
expect_all optc_a64_s2_low_4112_both --arch arm64 "$W/a_s2_4112.obj"
s2 a_s2_max 4095 4080
expect_all optc_a64_s2_low_16777200_largest --arch arm64 "$W/a_s2_max.obj"

# 16 777 216 does not fit S2 (hi = 4096 does not encode): the D shape, with
# the frame pointer, through mov x16 + sub sp, sp, x16
mk a_d_16m a64 <<EOF
        .text
        .def f; .scl 2; .type 32; .endef
        .globl f
        .seh_proc f
f:
        sub sp, sp, #32
        .seh_stackalloc 32
        stp x19, x20, [sp, #0]
        .seh_save_regp x19, 0
        stp x29, x30, [sp, #16]
        .seh_save_fplr 16
        add x29, sp, #16
        .seh_add_fp 16
        movz x16, #0x100, lsl #16
        .seh_nop
        sub sp, sp, x16
        .seh_stackalloc 16777216
        .seh_endprologue
        mov x19, x0
        bl k
        add x0, x0, x19
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
$A_K
EOF
expect_all optc_a64_d_fallback_16777216 --arch arm64 "$W/a_d_16m.obj"

# arm64 legacy SP-fixed: A10's frame without set_fp, epilog sharing every code
mk a_legacy a64 <<EOF
        .text
        .def f; .scl 2; .type 32; .endef
        .globl f
        .seh_proc f
f:
        sub sp, sp, #48
        .seh_stackalloc 48
        stp x29, x30, [sp]
        .seh_save_fplr 0
        stp x19, x20, [sp, #16]
        .seh_save_regp x19, 16
        .seh_endprologue
        mov x19, x0
        bl k
        add x0, x0, x19
        .seh_startepilogue
        ldp x19, x20, [sp, #16]
        .seh_save_regp x19, 16
        ldp x29, x30, [sp]
        .seh_save_fplr 0
        add sp, sp, #48
        .seh_stackalloc 48
        .seh_endepilogue
        ret
        .seh_endproc
$A_K
EOF
expect_all optc_a64_legacy_sp_fixed --arch arm64 "$W/a_legacy.obj"

# negatives
abody a_sub16 <<'EOF'
        sub sp, sp, #16
        bl k
        add sp, sp, #16
EOF
expect optc_neg_a64_sub_sp_c3b C3b FAIL --arch arm64 "$W/a_sub16.obj"
expect optc_neg_a64_sub_sp_c6 C6 FAIL --arch arm64 "$W/a_sub16.obj"
abody a_preidx <<'EOF'
        str x0, [sp, #-16]!
        ldr x0, [sp], #16
EOF
expect optc_neg_a64_str_pre_index C3b FAIL --arch arm64 "$W/a_preidx.obj"
abody a_preidx_w <<'EOF'
        str w0, [sp, #-16]!
        ldr w0, [sp], #16
EOF
expect optc_neg_a64_str_w_pre_index C3b FAIL --arch arm64 "$W/a_preidx_w.obj"
abody a_pair32 <<'EOF'
        stp w0, w1, [sp, #-16]!
        ldp w0, w1, [sp], #16
EOF
expect optc_neg_a64_stp_w_pre_index C3b FAIL --arch arm64 "$W/a_pair32.obj"
abody a_movsp <<'EOF'
        mov x9, sp
        mov sp, x9
EOF
expect optc_neg_a64_mov_sp C3b FAIL --arch arm64 "$W/a_movsp.obj"
# an S1 save at offset 512 cannot be encoded (Z*8, Z < 64): the nearest code
# (504) does not describe it, C3
mk a_s1_512 a64 <<EOF
        .text
        .def f; .scl 2; .type 32; .endef
        .globl f
        .seh_proc f
f:
        sub sp, sp, #528
        .seh_stackalloc 528
        str x19, [sp, #512]
        .seh_save_reg x19, 504
        .seh_endprologue
        add x19, x0, #1
        .seh_startepilogue
        ldr x19, [sp, #512]
        .seh_save_reg x19, 504
        add sp, sp, #528
        .seh_stackalloc 528
        .seh_endepilogue
        ret
        .seh_endproc
EOF
expect optc_neg_a64_s1_save_offset_512 C3 FAIL --arch arm64 "$W/a_s1_512.obj"
# The arm64 legacy fold's 488 boundary (#143 A19d(iii), option (a)): a folded
# frame saves x29/x30 at [sp,#OUT] and x19/x20 at [sp,#OUT+16]. OUT = 488 puts
# x19/x20 at 504, the last offset save_regp encodes (Z*8, Z < 64): C1..C6 and
# C3b pass. OUT = 496 would put x19 at 512: the nearest code (504) does not
# describe it, C3 -- which is why the pre-scan keeps OUT > 488 SP-moving.
mk a_fold_488 a64 <<EOF
        .text
        .def f; .scl 2; .type 32; .endef
        .globl f
        .seh_proc f
f:
        sub sp, sp, #544
        .seh_stackalloc 544
        stp x29, x30, [sp, #488]
        .seh_save_fplr 488
        stp x19, x20, [sp, #504]
        .seh_save_regp x19, 504
        .seh_endprologue
        mov x19, x0
        bl k
        add x0, x0, x19
        .seh_startepilogue
        ldp x19, x20, [sp, #504]
        .seh_save_regp x19, 504
        ldp x29, x30, [sp, #488]
        .seh_save_fplr 488
        add sp, sp, #544
        .seh_stackalloc 544
        .seh_endepilogue
        ret
        .seh_endproc
$A_K
EOF
expect_all optc_a64_legacy_fold_out_488 --arch arm64 "$W/a_fold_488.obj"
mk a_fold_496 a64 <<EOF
        .text
        .def f; .scl 2; .type 32; .endef
        .globl f
        .seh_proc f
f:
        sub sp, sp, #544
        .seh_stackalloc 544
        stp x29, x30, [sp, #496]
        .seh_save_fplr 496
        str x19, [sp, #512]
        .seh_save_reg x19, 504
        .seh_endprologue
        mov x19, x0
        bl k
        add x0, x0, x19
        .seh_startepilogue
        ldr x19, [sp, #512]
        .seh_save_reg x19, 504
        ldp x29, x30, [sp, #496]
        .seh_save_fplr 496
        add sp, sp, #544
        .seh_stackalloc 544
        .seh_endepilogue
        ret
        .seh_endproc
$A_K
EOF
expect optc_neg_a64_legacy_fold_out_496 C3 FAIL --arch arm64 "$W/a_fold_496.obj"
# an S2 frame that keeps a zero `sub sp, sp, #0` after its lsl #12 one: C3
mk a_zero a64 <<EOF
        .text
        .def f; .scl 2; .type 32; .endef
        .globl f
        .seh_proc f
f:
        sub sp, sp, #16
        .seh_stackalloc 16
        stp x29, x30, [sp, #0]
        .seh_save_fplr 0
        sub sp, sp, #1, lsl #12
        .seh_stackalloc 4096
        sub sp, sp, #0
        .seh_stackalloc 0
        .seh_endprologue
        add x0, x0, #1
        .seh_startepilogue
        add sp, sp, #0
        .seh_stackalloc 0
        add sp, sp, #1, lsl #12
        .seh_stackalloc 4096
        ldp x29, x30, [sp, #0]
        .seh_save_fplr 0
        add sp, sp, #16
        .seh_stackalloc 16
        .seh_endepilogue
        ret
        .seh_endproc
EOF
expect optc_neg_a64_zero_size_alloc C3 FAIL --arch arm64 "$W/a_zero.obj"
