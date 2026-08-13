#!/bin/bash
# Differential test: IR vs legacy backends, x86_64 + arm64.
# For each program, compile+run through all four backends and compare exit codes.
# Any disagreement is a parity bug. arm64 runs under qemu-aarch64-static if present.
KRC="${KRC:-./build/krc3}"
# A stale $KRC silently invalidates every row here. It bit us once as a false
# RED (a Jun-10 krc3 still refused `continue` in a `for` loop, which the
# compiler has supported for months) -- but the dangerous direction is a false
# GREEN: an old binary agreeing with itself across all four backends while the
# real compiler diverges. Refuse to run rather than report on the wrong binary.
if [ -f "$KRC" ]; then
    newest_src=$(ls -t src/*.kr 2>/dev/null | head -1)
    if [ -n "$newest_src" ] && [ "$newest_src" -nt "$KRC" ]; then
        echo "ERROR: $KRC is older than $newest_src -- it does not contain the current compiler." >&2
        echo "       Rebuild (make build) or point KRC at a current binary, e.g. KRC=./build/krc2 $0" >&2
        exit 2
    fi
else
    echo "ERROR: $KRC does not exist. Set KRC= or run 'make build'." >&2
    exit 2
fi
QEMU="$(command -v qemu-aarch64-static || true)"
TMP=/tmp/difftest_$$
DIV=0; TOTAL=0; KNOWN=0
run_one() { # arch flags -> echoes exit code or "CERR"
    local out="$TMP.$2"
    if $KRC --arch="$1" $3 "$TMP.kr" -o "$out" >/dev/null 2>&1; then
        if [ "$1" = "arm64" ]; then
            [ -n "$QEMU" ] || { echo "SKIP"; return; }
            chmod +x "$out"; $QEMU "$out" >/dev/null 2>&1; echo $?
        else
            chmod +x "$out"; "$out" >/dev/null 2>&1; echo $?
        fi
    else echo "CERR"; fi
}
diff_case() {
    local name="$1"; local src="$2"
    TOTAL=$((TOTAL+1))
    printf '%s\n' "$src" > "$TMP.kr"
    local ir_x=$(run_one x86_64 irx "")
    local lg_x=$(run_one x86_64 lgx "--legacy")
    local ir_a=$(run_one arm64 ira "")
    local lg_a=$(run_one arm64 lga "--legacy")
    # Compare all non-SKIP results against the IR-x86 baseline
    local base="$ir_x"; local bad=0
    for v in "$lg_x" "$ir_a" "$lg_a"; do
        [ "$v" = "SKIP" ] && continue
        [ "$v" != "$base" ] && bad=1
    done
    if [ "$bad" = "1" ] || [ "$base" = "CERR" ]; then
        DIV=$((DIV+1))
        printf "DIVERGE  %-26s IRx86=%s legx86=%s IRa64=%s lega64=%s\n" "$name" "$ir_x" "$lg_x" "$ir_a" "$lg_a"
    fi
    rm -f "$TMP".*
}

# Agreement AND a specific value. diff_case only asks whether the four
# configs match each other, so for anything where the agreed value is itself
# the point — evaluation order, say — it cannot fail as long as every backend
# moves together. value_case pins the number.
value_case() { # name src expected
    local name="$1"; local src="$2"; local exp="$3"
    TOTAL=$((TOTAL+1))
    printf '%s\n' "$src" > "$TMP.kr"
    local ir_x=$(run_one x86_64 irx "")
    local lg_x=$(run_one x86_64 lgx "--legacy")
    local ir_a=$(run_one arm64 ira "")
    local lg_a=$(run_one arm64 lga "--legacy")
    local bad=0
    for v in "$ir_x" "$lg_x" "$ir_a" "$lg_a"; do
        [ "$v" = "SKIP" ] && continue
        [ "$v" != "$exp" ] && bad=1
    done
    if [ "$bad" = "1" ]; then
        DIV=$((DIV+1))
        printf "DIVERGE  %-26s IRx86=%s legx86=%s IRa64=%s lega64=%s (expected %s on every config)\n" \
            "$name" "$ir_x" "$lg_x" "$ir_a" "$lg_a" "$exp"
    fi
    rm -f "$TMP".*
}

# Known evaluation-order divergence between the backends (see the eval-order
# investigation): the case is EXPECTED to disagree, with a specific value per
# backend. It does not fail the run — which order is right is an open language
# decision — but the expected values are PINNED: if either backend's order
# changes (including a fix), this goes red so the change is made consciously
# and this entry is updated or promoted to a plain diff_case.
#
# No case needs it right now: the evaluation-order split it was written for
# was closed by making the order left-to-right, address-before-value, and the
# three rows moved to value_case. Kept for the next real split.
known_div_case() { # name src expected_ir expected_legacy
    local name="$1"; local src="$2"; local exp_ir="$3"; local exp_lg="$4"
    TOTAL=$((TOTAL+1))
    printf '%s\n' "$src" > "$TMP.kr"
    local ir_x=$(run_one x86_64 irx "")
    local lg_x=$(run_one x86_64 lgx "--legacy")
    local ir_a=$(run_one arm64 ira "")
    local lg_a=$(run_one arm64 lga "--legacy")
    local bad=0
    [ "$ir_x" != "$exp_ir" ] && bad=1
    [ "$lg_x" != "$exp_lg" ] && bad=1
    [ "$ir_a" != "SKIP" ] && [ "$ir_a" != "$exp_ir" ] && bad=1
    [ "$lg_a" != "SKIP" ] && [ "$lg_a" != "$exp_lg" ] && bad=1
    if [ "$bad" = "1" ]; then
        DIV=$((DIV+1))
        printf "DIVERGE  %-26s IRx86=%s legx86=%s IRa64=%s lega64=%s (pinned known-divergent case CHANGED; expected IR=%s legacy=%s)\n" \
            "$name" "$ir_x" "$lg_x" "$ir_a" "$lg_a" "$exp_ir" "$exp_lg"
    else
        KNOWN=$((KNOWN+1))
        printf "KNOWN-DIVERGE  %-20s IR=%s legacy=%s (evaluation-order split, pinned)\n" \
            "$name" "$exp_ir" "$exp_lg"
    fi
    rm -f "$TMP".*
}

# ---- arithmetic ----
diff_case "add"        'fn main(){exit(10+20+3)}'
diff_case "sub"        'fn main(){exit(50-8)}'
diff_case "mul"        'fn main(){exit(6*7)}'
diff_case "div"        'fn main(){exit(100/3)}'
diff_case "mod"        'fn main(){exit(100%7)}'
diff_case "div_pow2"   'fn main(){u64 x=0; u64 i=0; while i<200 {x=x+1; i=i+1} exit(x/8)}'
diff_case "mod_pow2"   'fn main(){u64 x=0; u64 i=0; while i<203 {x=x+1; i=i+1} exit(x%8)}'
diff_case "div_by1"    'fn main(){u64 x=0; u64 i=0; while i<47 {x=x+1; i=i+1} exit(x/1)}'
diff_case "mod_by1"    'fn main(){u64 x=0; u64 i=0; while i<47 {x=x+1; i=i+1} exit(x%1)}'
diff_case "mod_pow2_2" 'fn main(){u64 x=0; u64 i=0; while i<201 {x=x+1; i=i+1} exit(x%2)}'
diff_case "sdiv_pow2"  'fn main(){i64 a=0-16; i64 b=a/8; exit(b+3)}'
diff_case "precedence" 'fn main(){exit(2+3*4-1)}'
diff_case "paren"      'fn main(){exit((2+3)*4)}'
diff_case "signed_div" 'fn main(){i64 a=0-12; i64 b=5; exit(f64_to_int(int_to_f64(0)))}'
# ---- bitwise ----
diff_case "and"        'fn main(){exit(12 & 10)}'
diff_case "or"         'fn main(){exit(12 | 1)}'
diff_case "xor"        'fn main(){exit(12 ^ 10)}'
diff_case "shl"        'fn main(){exit(1 << 5)}'
diff_case "shr"        'fn main(){exit(160 >> 2)}'
diff_case "bnot"       'fn main(){u64 x=0; exit((~x) & 255)}'
# ---- comparisons (unsigned) ----
diff_case "lt"  'fn main(){u64 a=3; u64 b=5; exit(a<b)}'
diff_case "ge"  'fn main(){u64 a=5; exit(a>=5)}'
diff_case "eq"  'fn main(){exit(7==7)}'
diff_case "ne"  'fn main(){exit(7!=8)}'
# ---- signed comparisons ----
diff_case "signed_lt" 'fn main(){i64 a=0-3; if signed_lt(a,0){exit(1)} exit(0)}'
# ---- signed arithmetic (i64): div/mod/shift must be type-directed in ALL backends ----
diff_case "signed_div_neg" 'fn main(){i64 a=0-17; i64 b=5; exit((a/b) & 255)}'
diff_case "signed_mod_neg" 'fn main(){i64 a=0-17; i64 b=5; exit((a%b) & 255)}'
diff_case "signed_shr_neg" 'fn main(){i64 a=0-16; exit((a>>1) & 255)}'
# ---- signed comparison OPERATORS (i64): <, <=, >, >= must be signed in ALL backends ----
diff_case "signed_lt_op"   'fn main(){i64 a=0-5; i64 b=3; if a<b {exit(1)} exit(2)}'
diff_case "signed_lt_zero" 'fn main(){i64 a=0-5; if a<0 {exit(1)} exit(2)}'
diff_case "signed_gt_op"   'fn main(){i64 a=0-5; i64 b=3; if a>b {exit(1)} exit(2)}'
diff_case "signed_le_op"   'fn main(){i64 a=0-5; i64 b=0-5; if a<=b {exit(1)} exit(2)}'
diff_case "signed_ge_neg"  'fn main(){i64 a=0-2; i64 b=0-9; if a>=b {exit(1)} exit(2)}'
# ---- legacy/arm64 backend parity (critique H8/H11/H13/M14/H6) ----
diff_case "high_bit_cond"  'fn main(){u64 x = 1 << 35; if x {exit(1)} exit(2)}'
diff_case "u16_fields"     'struct P{u16 a;u16 b} fn main(){P p; p.a=5; p.b=7; exit(p.a + p.b)}'
diff_case "nan_lt"         'import "std/math_float.kr"
fn main(){f64 n = int_to_f64(0)/int_to_f64(0); if n < int_to_f64(1) {exit(1)} exit(2)}'
diff_case "signed_param"   'fn isneg(i64 a)->u64{ if a<0 {return 1} return 0 }
fn main(){exit(isneg(0-3))}'
# ---- control flow ----
diff_case "break_in_match" 'fn main(){u64 i=0; while i<10 { match i { 3 => { break } _ => {} } i=i+1 } exit(i)}'
diff_case "if_else"  'fn main(){u64 x=5; if x>3{exit(1)}else{exit(0)}}'
diff_case "elseif3"  'fn f(u64 x)->u64{if x>90{return 5}else if x>80{return 4}else if x>70{return 3}else{return 1}}
fn main(){exit(f(75))}'
diff_case "while_sum" 'fn main(){u64 i=0; u64 s=0; while i<10{s=s+i; i=i+1} exit(s)}'
diff_case "for_sum"  'fn main(){u64 s=0; for i in 0..5{s=s+i} exit(s)}'
diff_case "for_continue" 'fn main(){u64 s=0; for i in 0..10{ if i==3 { continue } s=s+i} exit(s)}'
diff_case "break"    'fn main(){u64 i=0; while i<100{if i==7{break} i=i+1} exit(i)}'
diff_case "continue" 'fn main(){u64 s=0; u64 i=0; while i<10{i=i+1; if i==3{continue} s=s+1} exit(s)}'
diff_case "nested_if" 'fn main(){u64 x=8; if x>5{if x<10{exit(2)}} exit(0)}'
diff_case "match"    'fn main(){u64 x=2; match x{1=>{exit(10)} 2=>{exit(20)} 3=>{exit(30)}} exit(0)}'
diff_case "match_default" 'fn main(){u64 x=9; match x{1=>{exit(10)} 2=>{exit(20)}} exit(99)}'
diff_case "ternary"  'fn main(){u64 x=5; exit(x>3 ? 1 : 0)}'
diff_case "and_sc"   'static u64 g=0
fn s()->u64{g=9; return 1}
fn main(){u64 r=0 && s(); exit(g)}'
diff_case "or_val"   'fn main(){exit(0 || 7)}'
# ---- functions ----
diff_case "recursion" 'fn fib(u64 n)->u64{if n<=1{return n} return fib(n-1)+fib(n-2)}
fn main(){exit(fib(10))}'
diff_case "many_args" 'fn f(u64 a,u64 b,u64 c,u64 d,u64 e,u64 g,u64 h,u64 i)->u64{return a+b+c+d+e+g+h+i}
fn main(){exit(f(1,2,3,4,5,6,7,8))}'
diff_case "call_in_arg" 'fn d(u64 x)->u64{return x*2}
fn main(){exit(d(d(3)))}'
diff_case "method"   'struct P{u64 x;u64 y}
fn P.s(P self)->u64{return self.x+self.y}
fn main(){P p=P{x:3,y:4}; exit(p.s())}'
# ---- structs ----
diff_case "struct_field" 'struct P{u64 x;u64 y}
fn main(){P p; p.x=10; p.y=5; exit(p.x-p.y)}'
diff_case "struct_arg"  'struct P{u64 x;u64 y}
fn add(P p)->u64{return p.x+p.y}
fn main(){P p=P{x:6,y:9}; exit(add(p))}'
diff_case "tuple_destruct" 'fn dm(u64 a,u64 b)->u64{return (a/b,a%b)}
fn main(){(u64 q,u64 r)=dm(17,5); exit(q*10+r)}'
# ---- arrays / slices ----
diff_case "static_arr" 'static u8[4] buf
fn main(){store8(buf,65); store8(buf+1,66); exit(load8(buf)+load8(buf+1))}'
diff_case "slice_len"  'fn t([u64] xs)->u64{u64 s=0; u64 i=0; while i<xs.len{s=s+xs[i]; i=i+1} return s}
fn main(){exit(1)}'
# ---- pointers ----
diff_case "load_store" 'fn main(){u64 p=alloc(8); store64(p,42); exit(load64(p))}'
diff_case "load_store16" 'fn main(){u64 p=alloc(8); store16(p,300); exit(load16(p)-256)}'
# ---- floats ----
diff_case "float_add" 'fn main(){f64 a=int_to_f64(3); f64 b=int_to_f64(4); exit(f64_to_int(a+b))}'
diff_case "float_mul" 'fn main(){f64 a=int_to_f64(6); f64 b=int_to_f64(7); exit(f64_to_int(a*b))}'
diff_case "float_cmp" 'fn main(){f64 a=int_to_f64(3); f64 b=int_to_f64(5); if a<b{exit(1)} exit(0)}'
diff_case "f32_add"   'fn main(){f32 a=int_to_f32(2); f32 b=int_to_f32(3); exit(f32_to_int(a+b))}'
# ---- atomics ----
diff_case "atomic"    'fn main(){u64 p=alloc(8); atomic_store(p,5); atomic_add(p,3); exit(atomic_load(p))}'
# ---- bitfield builtins ----
diff_case "bitfield"  'fn main(){u64 v=0; v=bit_set(v,2); v=bit_set(v,4); exit(v)}'
# ---- globals ----
diff_case "global_mut" 'static u64 g=5
fn bump(){g=g+10}
fn main(){bump(); bump(); exit(g)}'
# ---- sizeof ----
diff_case "sizeof"    'fn main(){exit(sizeof(u64))}'

# Allocation-failure parity. This harness runs x86_64 IR, x86_64 legacy, arm64
# IR *and* arm64 legacy, which is the only automated coverage the arm64 legacy
# alloc/dealloc guards have -- run_test_a64 is IR-only and tests/diff/run.sh's
# backend mode is host-arch. Note it compares the four against each other and
# does not assert an absolute, so it locks in agreement going forward rather
# than detecting the original defect (pre-fix all four segfaulted, and so
# agreed); the asserting rows live in run_tests.sh.
diff_case "alloc_oom"    'fn main(){ u64 p = alloc(0xFFFFFFFFFFFF0000)  if p != 0 { exit(1) }  exit(42) }'
diff_case "dealloc_null" 'fn main(){ dealloc(0)  exit(43) }'
diff_case "alloc_ok"     'fn main(){ u64 p = alloc(64)  if p == 0 { exit(1) }  store64(p, 999)  u64 v = load64(p)  dealloc(p)  if v != 999 { exit(2) }  exit(44) }'

# ---- evaluation order with interfering side effects ----
# seq encodes execution order in decimal digits: f_i appends digit i.
# These lock in the orders both backends currently share; no earlier case had
# two side-effecting operands in one expression, which is why the deref-store
# divergence below survived 73 green parity runs.
diff_case "order_args" 'static u64 seq=0
fn a()->u64{seq=seq*10+1; return 5}
fn b()->u64{seq=seq*10+2; return 6}
fn g(u64 x,u64 y)->u64{return x+y}
fn main(){g(a(),b()); exit(seq)}'
diff_case "order_binop" 'static u64 seq=0
fn a()->u64{seq=seq*10+1; return 5}
fn b()->u64{seq=seq*10+2; return 6}
fn main(){u64 x=a()+b(); if x==999 {exit(255)} exit(seq)}'
diff_case "order_store32" 'static u64 seq=0
static u64 gbuf=0
fn fa()->u64{seq=seq*10+1; return gbuf}
fn fv()->u64{seq=seq*10+2; return 7}
fn main(){gbuf=alloc(8); store32(fa(),fv()); exit(seq)}'
# Stores evaluate the destination ADDRESS (including the subscript) before the
# value, left to right — docs/LANGUAGE.md §4. These are value_case, not
# diff_case: all four configs used to agree on 21 here, so a row that only
# compared the backends against each other would have stayed green through
# both the old order and the new one.
value_case "order_idx_store" 'static u64 seq=0
static u8[16] arr
fn ai()->u64{seq=seq*10+1; return 3}
fn fv()->u64{seq=seq*10+2; return 7}
fn main(){arr[ai()]=fv(); if arr[3]!=7 {exit(255)} exit(seq)}' 12
# `for i in START..END` evaluates both bounds exactly once, before the loop.
# The bound is a VALUE: IR parked the vreg the variable itself lives in, so
# the loop's back-edge wrote the body's new n straight into the "parked" bound
# and IR ran 100 trips where legacy ran 3. These two rows are the pair that
# split.
diff_case "order_for_bounds" 'static u64 seq=0
fn a()->u64{seq=seq*10+1; return 1}
fn b()->u64{seq=seq*10+2; return 2}
fn main(){for i in a()..b() {} exit(seq)}'
diff_case "for_bound_is_a_value" 'fn main(){u64 n=3; u64 c=0
for i in 0..n { n=100; c=c+1 }
exit(c)}'
# These two used to be known_div_case, pinned at IR=12 / legacy=21. The legacy
# backends now evaluate the address first too, so both legs read 12 and the
# rows are plain value-pinned cases. DO NOT silently re-pin them — a red here
# means an evaluation-order change that needs an owner decision.
value_case "order_deref_store" 'static u64 seq=0
static u64 gbuf=0
fn fa()->u64{seq=seq*10+1; return gbuf}
fn fv()->u64{seq=seq*10+2; return 7}
fn main(){gbuf=alloc(8); unsafe{*(fa() as uint32)=fv()}; if load32(gbuf)!=7 {exit(255)} exit(seq)}' 12
value_case "order_sfield_store" 'static u64 seq=0
struct P{u64 x;u64 y}
fn ai()->u64{seq=seq*10+1; return 3}
fn fv()->u64{seq=seq*10+2; return 7}
fn main(){P[10] pts; pts[ai()].x=fv(); if pts[3].x!=7 {exit(255)} exit(seq)}' 12
# The subscript runs before the WHOLE value expression, and the value itself
# runs left to right: 123. Every config used to say 231 — the entire value
# expression ahead of the index — so this is not a two-way swap.
value_case "order_idx_store_whole" 'static u64 seq=0
static u64[16] arr64
fn a()->u64{seq=seq*10+1; return 3}
fn fv()->u64{seq=seq*10+2; return 5}
fn b()->u64{seq=seq*10+3; return 4}
fn main(){arr64[a()]=fv()+b(); if arr64[3]!=9 {exit(255)} exit(seq)}' 123
# The store parks the SUBSCRIPT across the value expression now, so a builtin
# in the value must not destroy it. Measured at 0 on both legacy backends when
# the ordering change was applied without the per-site scratch slots.
value_case "order_idx_store_value_clobbers" 'static u64[16] vc
fn ai()->u64{return 3}
fn main(){u64 m=0; vc[ai()]=write(1,m,0)+77; exit(vc[3])}' 77

# --- builtin ARGUMENT parking ---------------------------------------------
# The argument half of the temp_slot_0/temp_slot_1 family. A multi-argument
# builtin parked already-evaluated arguments in the two shared scratch slots
# while it evaluated the rest, and the rest is free to write those same slots.
# Each of these disagreed IR-vs-legacy on BOTH arches before the fix; the
# measured legacy value is in the comment so a regression is recognisable.
#
# No `import` here on purpose: this harness writes its source to /tmp, where
# `std/` would resolve against the INSTALLED tree rather than this checkout.

# Nested builtin in another builtin's argument list. signed_lt parks its first
# operand, bit_range parks two — write's fd (2) replaced them. legacy: 1+0=1.
value_case "arg_builtin_nested" 'fn main(){u64 s=0
u64 a=signed_lt(5,3+write(2,s,0))
u64 b=bit_range(255,0,4+write(2,s,0))
exit(a+b)}' 15

# store64 parks an ADDRESS, so the clobber was a wild store: legacy SEGFAULTED
# (139) rather than returning a wrong number.
value_case "arg_store64_addr" 'fn main(){u64 s=0
u64 buf=alloc(64)
store64(buf,77+write(2,s,0))
exit(load64(buf))}' 77

# An f-string keeps its running OUTPUT OFFSET in temp_slot_1 across the whole
# segment loop, so a builtin in an interpolation walks the destination pointer
# off the buffer. 'A'+'0'+'B' = 179; legacy read back 114.
value_case "arg_fstring_interp" 'fn main(){u64 s=0
u64 p=f"A{write(2,s,0)}B"
exit(load8(p)+load8(p+1)+load8(p+2))}' 179

# Tuple returns park each element across the evaluation of the later ones.
value_case "arg_tuple_return" 'fn two()->u64{return (11+write(2,"F",0),22+write(2,"G",0))}
fn main(){(u64 a,u64 b)=two(); exit(a+b)}' 33

# No nested call at all: a fractional float LITERAL lowers as int+frac/divisor
# using BOTH scratch slots, so fma_f64s own operands destroyed its parked
# arguments. 2.5*4.5+1.25 = 12.5; legacy produced 0.
value_case "arg_float_literal_scratch" 'fn main(){f64 r=fma_f64(2.5,4.5,1.25)
u64 g=f64_to_int(r*100.0)
exit(g-1000)}' 250

# --- `/=` and `%=` on the legacy backends ----------------------------------
# Both legacy BinOp operator chains paired every compound token with its base
# operator EXCEPT SlashEq (48) with `/` (32) and PercentEq (49) with `%` (33).
# An op_kind matching no arm emitted nothing at all, leaving the accumulator
# holding the LHS, which the enclosing store then wrote back unchanged. Both
# IR backends were correct (ir.kr already spelled `op_kind == 32 || 48`), so
# this was a real IR-vs-legacy divergence: 113 on IR, 253 on legacy — the
# unmodified 23 and 23 rather than the 11 and 3 the division produced.
# The plain-variable form was equally broken, so it is pinned here too.
value_case "divassign_idx" 'fn main(){u64[8] a
a[3]=23
a[3]/=2
u64[8] b
b[3]=23
b[3]%=5
exit(a[3]*10+b[3])}' 113
value_case "divassign_plain" 'fn main(){uint64 x=23
x/=2
uint64 y=23
y%=5
exit(x*10+y)}' 113
# Signed operands must keep using idiv/sdiv, not div/udiv: -24/5 = -4 and
# -24%5 = -4, so (0-s)*10+(0-t) = 44. The discard defect left both at -24,
# which reads back as 264 & 255 = 8.
value_case "divassign_signed" 'fn main(){int64 s=0-24
s/=5
int64 t=0-24
t%=5
exit((0-s)*10+(0-t))}' 44

echo "----"
echo "Differential: $((TOTAL-DIV-KNOWN))/$TOTAL agree across backends, $KNOWN known-divergent (pinned), $DIV diverged."
if [ "$DIV" = "0" ]; then echo "PARITY OK"; else echo "PARITY GAPS FOUND"; exit 1; fi
