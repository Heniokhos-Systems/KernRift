#!/bin/bash
# Differential test #2: compares full STDOUT (not just exit code) across
# IR vs legacy, x86_64 + arm64. Targets the subtle paths most likely to
# diverge: printing, float formatting, signed-negative arithmetic, struct
# return-by-value, nested structs, defer, fstrings.
KRC="${KRC:-./build/krc3}"
QEMU="$(command -v qemu-aarch64-static || true)"
TMP=/tmp/diffo_$$
DIV=0; TOTAL=0
out_one() {
    local arch="$1"; local flags="$2"; local o="$TMP.$3"
    if $KRC --arch="$arch" $flags "$TMP.kr" -o "$o" >/dev/null 2>&1; then
        if [ "$arch" = "arm64" ]; then
            [ -n "$QEMU" ] || { echo "<SKIP>"; return; }
            chmod +x "$o"; timeout 10 $QEMU "$o" 2>/dev/null || echo "<TIMEOUT/$?>"
        else chmod +x "$o"; timeout 10 "$o" 2>/dev/null || echo "<TIMEOUT/$?>"; fi
    else echo "<CERR>"; fi
}
dc() {
    local name="$1"; local src="$2"
    TOTAL=$((TOTAL+1))
    printf '%s\n' "$src" > "$TMP.kr"
    local a=$(out_one x86_64 "" irx)
    local b=$(out_one x86_64 "--legacy" lgx)
    local c=$(out_one arm64 "" ira)
    local d=$(out_one arm64 "--legacy" lga)
    local bad=0
    [ "$a" = "<CERR>" ] && bad=1
    for v in "$b" "$c" "$d"; do
        [ "$v" = "<SKIP>" ] && continue
        [ "$v" != "$a" ] && bad=1
    done
    if [ "$bad" = "1" ]; then
        DIV=$((DIV+1))
        echo "DIVERGE  $name"
        echo "   IRx86 : [$a]"
        echo "   legx86: [$b]"
        echo "   IRa64 : [$c]"
        echo "   lega64: [$d]"
    fi
    rm -f "$TMP".*
}

dc "print_str"   'fn main(){ print_str("hello"); exit(0) }'
dc "println_int" 'fn main(){ println(12345); exit(0) }'
dc "int_to_str"  'import "std/string.kr"
fn main(){ u64 s=int_to_str(98765); println_str(s); exit(0) }'
dc "print_loop"  'fn main(){ u64 i=0; while i<5{ println(i); i=i+1 } exit(0) }'
dc "neg_print"   'fn main(){ i64 n=0-42; println(n); exit(0) }'
dc "neg_print_labeled" 'fn main(){ i64 n=0-42; println("x=", n); exit(0) }'
dc "neg_fstring"       'fn main(){ i64 n=0-42; println(f"x={n}"); exit(0) }'
dc "fmt_f64"     'import "std/math_float.kr"
fn main(){ f64 x=int_to_f64(1); f64 y=int_to_f64(3); println_str(fmt_f64(x/y, 6)); exit(0) }'
dc "fmt_f64_neg" 'import "std/math_float.kr"
fn main(){ f64 x=int_to_f64(0)-int_to_f64(7); println_str(fmt_f64(x/int_to_f64(2), 4)); exit(0) }'
dc "sqrt"        'import "std/math_float.kr"
fn main(){ println_str(fmt_f64(sqrt(int_to_f64(2)), 6)); exit(0) }'
dc "signed_divmod_neg" 'fn main(){ i64 a=0-17; i64 b=5; println(a/b); println(a%b); exit(0) }'
dc "struct_return" 'struct P{u64 x;u64 y}
fn mk(u64 a,u64 b)->P{ P p; p.x=a; p.y=b; return p }
fn main(){ P q=mk(11,22); println(q.x); println(q.y); exit(0) }'
dc "nested_struct" 'struct Inner{u64 v}
struct Outer{Inner a; u64 b}
fn main(){ Outer o; o.a.v=7; o.b=3; println(o.a.v+o.b); exit(0) }'
dc "struct_array" 'struct P{u64 x;u64 y}
fn main(){ P[3] ps; ps[0].x=1; ps[1].x=2; ps[2].x=3; println(ps[0].x+ps[1].x+ps[2].x); exit(0) }'
dc "fstring"     'fn main(){ u64 n=42; println_str(f"n is {n}"); exit(0) }'
dc "match_expr"  'fn main(){ u64 x=3; println(match x { 1 => 10  2 => 20  3 => 30  _ => 0 }); println(match x { 1,2,3 => 5  _ => 0 }); println(match x { 9 => 1 }); exit(0) }'
dc "let_infer"   'fn f()->u64{return 9}
fn main(){ let a = 6 * 7; let b = f(); let c = a + b; u64 t=0; for i in 0..4 { let d = i*2; t = t + d } println(a); println(b); println(c); println(t); exit(0) }'
dc "many_println" 'fn main(){ u64 i=0; u64 s=1; while i<10{ s=s*2; i=i+1 } println(s); exit(0) }'
dc "deep_recursion" 'fn sum(u64 n)->u64{ if n==0{return 0} return n+sum(n-1) }
fn main(){ println(sum(100)); exit(0) }'
# A float expression earlier in the function used to leave the legacy backends'
# expr_is_float set, so the NEXT string-literal argument was filed as an f64,
# routed to xmm0/d0, and every integer argument shifted one register down. The
# ordering is the whole assertion: "FIRST_|SECOND", not just "no crash".
dc "strarg_after_float" 'fn pp(u64 a,u64 b){ print_str(a); print_str("|"); print_str(b); print_str("\n") }
fn main(){ f64 x=1.5; f64 y=x+1.0; pp("FIRST_","SECOND"); exit(0) }'
dc "strarg_nested_float_call" 'fn mkf(f64 v,u64 p)->u64{ return "SECOND" }
fn pp(u64 a,u64 b){ print_str(a); print_str("|"); print_str(b); print_str("\n") }
fn main(){ f64 x=1.5; pp("FIRST_", mkf(x,7)); exit(0) }'
# An f-string interpolating a float needed its own clear at the END of the
# f-string arm. Only argument 1 is printed: the legacy f-string renders a float
# as "?" while the IR renders the value, which is a SEPARATE, pre-existing
# divergence this row must not accidentally pin.
dc "fstring_float_then_arg" 'fn pp(u64 a,u64 b){ println(b) }
fn main(){ f64 x=1.5; pp(f"v={x}", 8738); exit(0) }'
# The IR vreg float-kind slot spells 3=bool and 4=char, and testing it as
# `!= 0` for "is a float" put both on the FMUL/FDIV path -- the IR was the
# WRONG side here, the opposite of every other row in this file. `+`/`-`
# survived (denormal add is bit-exact), so these rows multiply and divide.
dc "bool_char_arith" "fn main(){ bool b=true; char c='A'; println(b*2); println(c*2); println(c/5); exit(0) }"
# `as f16` and `static f16` spell 3 = f16 in a DIFFERENT namespace, and that 3
# arrived in the vreg slot meaning bool, so the IR printed 21520 as "true".
dc "f16_deref_typing" 'fn main(){ u64 p=alloc(64); store64(p,0xAAAAAAAAAAAAAAAA); store16(p,21520); unsafe { *(p as f16) -> g } println(g); println(g*2); exit(0) }'
# f16_to_f32 on legacy arm64 emitted FCVT Dd,Sn instead of FCVT Sd,Hn and
# returned 0.0f for everything -- with no deref anywhere.
dc "f16_to_f32_value" 'import "std/math_float.kr"
fn main(){ f32 v=65.0f; u64 h=f32_to_f16(v); println(h); println_str(fmt_f32(f16_to_f32(h),4)); exit(0) }'

echo "----"
echo "Stdout differential: $((TOTAL-DIV))/$TOTAL agree, $DIV diverged."
if [ "$DIV" = "0" ]; then echo "PARITY OK"; else echo "PARITY GAPS FOUND"; exit 1; fi
