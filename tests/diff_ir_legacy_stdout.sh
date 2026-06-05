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

echo "----"
echo "Stdout differential: $((TOTAL-DIV))/$TOTAL agree, $DIV diverged."
[ "$DIV" = "0" ] && echo "PARITY OK" || echo "PARITY GAPS FOUND"
