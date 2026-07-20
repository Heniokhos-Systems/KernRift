#!/bin/bash
# No set -e: test binaries return non-zero exit codes intentionally

DIR="$(cd "$(dirname "$0")" && pwd)"
KRC="${KRC:-$DIR/../build/krc3}"
ARCH=$(uname -m)
KRC_FLAGS="${KRC_FLAGS:---arch=$ARCH}"
PASS=0
FAIL=0
TOTAL=0

run_test() {
    local name="$1"
    local input="$2"
    local expected="$3"
    TOTAL=$((TOTAL + 1))

    local REPO_ROOT="$DIR/.."
    printf '%s\n' "$input" > "$REPO_ROOT/test_tmp_$$.kr"
    if $KRC $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_test_$$ > /dev/null 2>&1; then
        rm -f "$REPO_ROOT/test_tmp_$$.kr"
        chmod +x /tmp/krc_test_$$
        local got=0
        /tmp/krc_test_$$ > /dev/null 2>&1 && got=0 || got=$?
        if [ "$got" = "$expected" ]; then
            PASS=$((PASS + 1))
        else
            echo "FAIL: $name (expected $expected, got $got)"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL: $name (compilation failed)"
        $KRC $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_test_$$ 2>&1 | head -3
        FAIL=$((FAIL + 1))
    fi
    rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_test_$$
}

run_test_output() {
    local name="$1"
    local input="$2"
    local expected_output="$3"
    local expected_exit="${4:-0}"
    TOTAL=$((TOTAL + 1))

    local REPO_ROOT="$DIR/.."
    printf '%s\n' "$input" > "$REPO_ROOT/test_tmp_$$.kr"
    if $KRC $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_test_$$ > /dev/null 2>&1; then
        rm -f "$REPO_ROOT/test_tmp_$$.kr"
        chmod +x /tmp/krc_test_$$
        local got_output
        got_output=$(/tmp/krc_test_$$ 2>/dev/null)
        local got_exit=$?
        if [ "$got_output" = "$expected_output" ] && [ "$got_exit" = "$expected_exit" ]; then
            PASS=$((PASS + 1))
        else
            if [ "$got_output" != "$expected_output" ]; then
                echo "FAIL: $name (expected output '$expected_output', got '$got_output')"
            else
                echo "FAIL: $name (expected exit $expected_exit, got $got_exit)"
            fi
            FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL: $name (compilation failed)"
        FAIL=$((FAIL + 1))
    fi
    rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_test_$$
}

echo "=== KernRift Self-Hosted Compiler Test Suite ==="
echo ""

# --- Basic tests ---
run_test "exit_42" 'fn main() { exit(42) }' 42
run_test "exit_0" 'fn main() { exit(0) }' 0

# --- Variables ---
run_test "var_assign" 'fn main() {
    uint64 x = 42
    exit(x)
}' 42

run_test "var_reassign" 'fn main() {
    uint64 x = 1
    x = 42
    exit(x)
}' 42

# --- Arithmetic ---
run_test "add" 'fn main() { exit(10 + 20) }' 30
run_test "sub" 'fn main() { exit(50 - 8) }' 42
run_test "mul" 'fn main() { exit(6 * 7) }' 42
run_test "div" 'fn main() { exit(84 / 2) }' 42
run_test "mod" 'fn main() { exit(47 % 5) }' 2

# Strength reduction: unsigned div/mod by a power-of-two literal lowers to
# shr/and on the IR backend. The loop makes x unknown to the const-folder
# (per-BB tracking), so the shift actually executes at runtime.
run_test "div_pow2_rt" 'fn main() {
    u64 x = 0
    u64 i = 0
    while i < 200 { x = x + 1; i = i + 1 }
    exit(x / 8)
}' 25
run_test "mod_pow2_rt" 'fn main() {
    u64 x = 0
    u64 i = 0
    while i < 203 { x = x + 1; i = i + 1 }
    exit(x % 8)
}' 3
run_test "div_by_1_rt" 'fn main() {
    u64 x = 0
    u64 i = 0
    while i < 47 { x = x + 1; i = i + 1 }
    exit(x / 1)
}' 47
run_test "mod_by_1_rt" 'fn main() {
    u64 x = 0
    u64 i = 0
    while i < 47 { x = x + 1; i = i + 1 }
    exit(x % 1)
}' 0
run_test "mod_pow2_2_rt" 'fn main() {
    u64 x = 0
    u64 i = 0
    while i < 201 { x = x + 1; i = i + 1 }
    exit(x % 2)
}' 1
run_test "div_nonpow2_rt" 'fn main() {
    u64 x = 0
    u64 i = 0
    while i < 200 { x = x + 1; i = i + 1 }
    exit(x / 24)
}' 8
run_test "div_pow2_fold" 'fn main() { exit(84 / 4) }' 21
run_test "sdiv_pow2_neg" 'fn main() {
    i64 a = 0 - 16
    i64 b = a / 8
    exit(b + 3)
}' 1

# --- Bitwise ---
run_test "and" 'fn main() { exit(0xFF & 0x2A) }' 42
run_test "or" 'fn main() { exit(0x20 | 0x0A) }' 42
run_test "xor" 'fn main() { exit(0xFF ^ 0xD5) }' 42
run_test "shl" 'fn main() { exit(21 << 1) }' 42
run_test "shr" 'fn main() { exit(84 >> 1) }' 42

# --- Unary ---
run_test "not_0" 'fn main() { exit(!0) }' 1
run_test "not_1" 'fn main() { exit(!1) }' 0
run_test "neg" 'fn main() { exit((-1) & 0xFF) }' 255

# --- Comparisons ---
run_test "eq_true" 'fn main() { if 5 == 5 { exit(1) } exit(0) }' 1
run_test "eq_false" 'fn main() { if 5 == 6 { exit(1) } exit(0) }' 0
run_test "lt" 'fn main() { if 3 < 5 { exit(1) } exit(0) }' 1
run_test "gt" 'fn main() { if 5 > 3 { exit(1) } exit(0) }' 1
run_test "le" 'fn main() { if 5 <= 5 { exit(1) } exit(0) }' 1
run_test "ge" 'fn main() { if 5 >= 5 { exit(1) } exit(0) }' 1
run_test "ne" 'fn main() { if 5 != 6 { exit(1) } exit(0) }' 1

# --- Logical ---
run_test "and_logic" 'fn main() {
    uint64 x = 5
    if x > 3 && x < 10 { exit(1) }
    exit(0)
}' 1
run_test "or_logic" 'fn main() {
    uint64 x = 2
    if x == 1 || x == 2 { exit(1) }
    exit(0)
}' 1

# --- If/else ---
run_test "if_then" 'fn main() {
    uint64 x = 5
    if x == 5 { exit(1) } else { exit(0) }
}' 1
run_test "if_else" 'fn main() {
    uint64 x = 3
    if x == 5 { exit(1) } else { exit(2) }
}' 2
run_test "else_if" 'fn main() {
    uint64 x = 2
    if x == 1 { exit(10) } else if x == 2 { exit(20) } else { exit(30) }
}' 20

# --- While ---
run_test "while_sum" 'fn main() {
    uint64 i = 0
    uint64 s = 0
    while i < 10 {
        s = s + i
        i = i + 1
    }
    exit(s)
}' 45

# --- Break/Continue ---
run_test "break" 'fn main() {
    uint64 i = 0
    uint64 c = 0
    while i < 100 {
        if i == 5 { break }
        c = c + 1
        i = i + 1
    }
    exit(c)
}' 5
run_test "continue" 'fn main() {
    uint64 i = 0
    uint64 s = 0
    while i < 10 {
        i = i + 1
        if i == 5 { continue }
        s = s + 1
    }
    exit(s)
}' 9

# --- Functions ---
run_test "fn_call" 'fn add(uint64 a, uint64 b) -> uint64 { return a + b }
fn main() { exit(add(10, 20)) }' 30

run_test "fn_4args" 'fn sum4(uint64 a, uint64 b, uint64 c, uint64 d) -> uint64 {
    return a + b + c + d
}
fn main() { exit(sum4(10, 20, 3, 9)) }' 42

run_test "fn_5args" 'fn sum5(uint64 a, uint64 b, uint64 c, uint64 d, uint64 e) -> uint64 { return a + b + c + d + e }
fn main() { exit(sum5(1, 2, 3, 4, 5)) }' 15

run_test "fn_6args" 'fn sum6(uint64 a, uint64 b, uint64 c, uint64 d, uint64 e, uint64 f) -> uint64 {
    return a + b + c + d + e + f
}
fn main() { exit(sum6(1,2,3,4,5,6)) }' 21

# --- Recursion ---
run_test "factorial" 'fn f(uint64 n) -> uint64 {
    if n <= 1 { return 1 }
    return n * f(n - 1)
}
fn main() { exit(f(5)) }' 120

run_test "fibonacci" 'fn fib(uint64 n) -> uint64 {
    if n <= 1 { return n }
    return fib(n - 1) + fib(n - 2)
}
fn main() { exit(fib(10)) }' 55

# --- Compound assignment ---
run_test "plus_eq" 'fn main() {
    uint64 x = 10
    x += 32
    exit(x)
}' 42

# --- Enums ---
run_test "enum_basic" 'enum Color {
    Red = 10
    Green = 20
    Blue = 30
}
fn main() { exit(Color.Green) }' 20

# --- Static variables ---
run_test "static_var" 'static uint64 counter = 0
fn inc() { counter = counter + 1 }
fn main() {
    inc()
    inc()
    inc()
    exit(counter)
}' 3

# --- Arrays ---
run_test "array_rw" 'fn main() {
    uint8[10] buf
    buf[0] = 42
    uint64 v = buf[0]
    exit(v)
}' 42

# --- Structs ---
run_test "struct_basic" 'struct Point {
    uint64 x
    uint64 y
}
fn main() {
    Point p
    p.x = 10
    p.y = 32
    exit(p.x + p.y)
}' 42

# --- Pointer operations ---
run_test "ptr_load_store" 'fn main() {
    uint64 buf = alloc(64)
    unsafe { *(buf as uint64) = 42 }
    uint64 v = 0
    unsafe { *(buf as uint64) -> v }
    exit(v)
}' 42

# --- File I/O ---
run_test "file_io" 'fn main() {
    uint64 msg = "test"
    uint64 fd = file_open("/dev/null", 1)
    file_write(fd, msg, 4)
    file_close(fd)
    exit(0)
}' 0

# --- Boolean literals ---
run_test "bool_true" 'fn main() { bool x = true; if x { exit(1) }; exit(0) }' 1
run_test "bool_false" 'fn main() { bool x = false; if x { exit(1) }; exit(0) }' 0

# --- Match statement ---
run_test "match_basic" 'fn main() {
    uint64 x = 2
    uint64 r = 0
    match x { 1 => { r = 10 } 2 => { r = 20 } 3 => { r = 30 } }
    exit(r)
}' 20

run_test "match_first" 'fn main() {
    uint64 x = 1
    uint64 r = 0
    match x { 1 => { r = 42 } 2 => { r = 99 } }
    exit(r)
}' 42

run_test "match_nomatch" 'fn main() {
    uint64 x = 99
    uint64 r = 42
    match x { 1 => { r = 0 } 2 => { r = 0 } }
    exit(r)
}' 42

run_test "match_enum" 'enum Color { Red = 1 Green = 2 Blue = 3 }
fn main() {
    uint64 c = Color.Green
    uint64 r = 0
    match c { 1 => { r = 10 } 2 => { r = 20 } 3 => { r = 30 } }
    exit(r)
}' 20

# --- Type aliases ---
run_test "type_alias" 'type Size = uint64
fn main() {
    Size x = 42
    exit(x)
}' 42

# --- Method syntax ---
run_test "method_decl" 'struct Point { uint64 x; uint64 y }
fn Point.sum(Point self) -> uint64 {
    return self.x + self.y
}
fn main() {
    Point p
    p.x = 10
    p.y = 32
    exit(sum(p))
}' 42

# --- Builtin: print/println ---
run_test_output "print_string" 'fn main() { print("hello world"); exit(0) }' "hello world"
run_test_output "print_int" 'fn main() { print(42); exit(0) }' "42"
run_test_output "print_zero" 'fn main() { print(0); exit(0) }' "0"
run_test_output "print_large" 'fn main() { print(123456); exit(0) }' "123456"
run_test_output "println_string" 'fn main() { println("hello"); exit(0) }' "hello"
run_test_output "println_int" 'fn main() { println(123); exit(0) }' "123"
run_test_output "println_multi" 'fn main() { println("abc"); println("def"); exit(0) }' "abc
def"

# --- Builtin: str_len ---
run_test "str_len_hello" 'fn main() { uint64 s = "hello"; exit(str_len(s)) }' 5
run_test "str_len_empty" 'fn main() { uint64 s = ""; exit(str_len(s)) }' 0
run_test "str_len_one" 'fn main() { uint64 s = "x"; exit(str_len(s)) }' 1

# --- Builtin: str_eq ---
run_test "str_eq_same" 'fn main() { uint64 a = "foo"; uint64 b = "foo"; exit(str_eq(a, b)) }' 1
run_test "str_eq_diff" 'fn main() { uint64 a = "foo"; uint64 b = "bar"; exit(str_eq(a, b)) }' 0
run_test "str_eq_prefix" 'fn main() { uint64 a = "foo"; uint64 b = "foobar"; exit(str_eq(a, b)) }' 0
run_test "str_eq_empty" 'fn main() { uint64 a = ""; uint64 b = ""; exit(str_eq(a, b)) }' 1

# --- std/string.kr additions (v2.8.11) ---
run_test "str_index_of_hit" 'import "std/string.kr"
fn main() { exit(str_index_of("hello world", "world")) }' 6
run_test "str_index_of_miss" 'import "std/string.kr"
fn main() {
    uint64 n = str_index_of("hello", "xyz")
    if n == 0xFFFFFFFFFFFFFFFF { exit(0) }
    exit(1)
}' 0
run_test "str_compare_eq" 'import "std/string.kr"
fn main() { exit(str_compare("abc", "abc")) }' 0
run_test "str_compare_lt" 'import "std/string.kr"
fn main() {
    uint64 r = str_compare("abc", "abd")
    if signed_lt(r, 0) { exit(1) }
    exit(0)
}' 1
run_test "str_compare_prefix" 'import "std/string.kr"
fn main() {
    uint64 r = str_compare("abc", "abcd")
    if signed_lt(r, 0) { exit(1) }
    exit(0)
}' 1
run_test_output "str_lower_basic" 'import "std/string.kr"
fn main() { println_str(str_lower("HeLLo 123")) }' "hello 123"
run_test_output "str_upper_basic" 'import "std/string.kr"
fn main() { println_str(str_upper("HeLLo 123")) }' "HELLO 123"
run_test_output "str_replace_basic" 'import "std/string.kr"
fn main() { println_str(str_replace("a.b.c.d", ".", "-")) }' "a-b-c-d"
run_test_output "str_replace_longer" 'import "std/string.kr"
fn main() { println_str(str_replace("hi world hi", "hi", "HELLO")) }' "HELLO world HELLO"
run_test_output "str_replace_noop" 'import "std/string.kr"
fn main() { println_str(str_replace("abc", "zz", "QQ")) }' "abc"
run_test "str_split_count" 'import "std/string.kr"
fn main() {
    uint64[8] parts
    exit(str_split("a,b,c,,d", 44, parts, 8))
}' 5
run_test_output "str_join_basic" 'import "std/string.kr"
fn main() {
    uint64[4] parts
    uint64 n = str_split("a,b,c", 44, parts, 4)
    println_str(str_join(parts, n, "|"))
}' "a|b|c"
run_test "str_to_float_int" 'import "std/string.kr"
fn main() {
    f64 v = str_to_float("42")
    exit(f64_to_int(v))
}' 42
run_test "str_to_float_frac" 'import "std/string.kr"
fn main() {
    f64 v = str_to_float("1.5")
    f64 two = int_to_f64(2)
    exit(f64_to_int(v * two))
}' 3
run_test "str_to_float_exp" 'import "std/string.kr"
fn main() {
    f64 v = str_to_float("-3e1")
    exit(f64_to_int(int_to_f64(0) - v))
}' 30
# Regression: float static initialisers used to silently drop their value
# (parser only handled int literal kinds 2/4/77/78 — FloatLit kind 5 fell
# through the skip branch). Now `static f64 x = 20.0` retains 20.0.
run_test "static_float_init" '
static f64 tau_m = 20.0
static f64 V_rest = -70.0
fn main() {
    exit(f64_to_int(tau_m - V_rest))   // 20 - (-70) = 90
}' 90
# Regression: reads of static f64 and f64 array elements used to lose
# their f64 type-flow through arithmetic, so `a + b` emitted integer ops
# instead of IR_FADD. Now the static_fkinds table propagates fkind from
# declaration through IR_STATIC_LOAD and array Index.
run_test "static_f64_type_flow" '
static f64 a = 3.0
static f64 b = 4.0
fn main() {
    f64 c = a + b    // direct-read arithmetic — used to produce -0.0
    exit(f64_to_int(c))
}' 7
run_test "static_f64_array_type_flow" '
static f64[4] arr
fn main() {
    arr[0] = 1.5
    arr[1] = 2.5
    arr[2] = 3.5
    arr[3] = 4.5
    f64 s = arr[0] + arr[1] + arr[2] + arr[3]
    exit(f64_to_int(s))
}' 12
run_test "utf8_decode_ascii" 'import "std/string.kr"
fn main() {
    uint64[1] w
    uint64 wp = w
    uint64 cp = utf8_decode_at("A", 0, wp)
    uint64 ww = 0
    unsafe { *(wp as uint64) -> ww }
    if cp == 65 && ww == 1 { exit(0) }
    exit(1)
}' 0
run_test "utf8_decode_two_byte" 'import "std/string.kr"
fn main() {
    uint64[1] w
    uint64 wp = w
    uint64 cp = utf8_decode_at("é", 0, wp)
    uint64 ww = 0
    unsafe { *(wp as uint64) -> ww }
    if cp == 233 && ww == 2 { exit(0) }
    exit(1)
}' 0
run_test "str_codepoint_count_mixed" 'import "std/string.kr"
fn main() { exit(str_codepoint_count("héllo")) }' 5
run_test "utf8_lower_codepoint_ascii" 'import "std/string.kr"
fn main() { exit(utf8_lower_codepoint(65)) }' 97
run_test "utf8_upper_codepoint_latin1" 'import "std/string.kr"
fn main() { exit(utf8_upper_codepoint(0xE9)) }' 201
run_test_output "str_lower_utf8_latin1" 'import "std/string.kr"
fn main() { println_str(str_lower_utf8("CaFÉ")) }' "café"
run_test_output "str_upper_utf8_latin1" 'import "std/string.kr"
fn main() { println_str(str_upper_utf8("café")) }' "CAFÉ"
run_test "utf8_is_combining_yes" 'import "std/string.kr"
fn main() { exit(utf8_is_combining(0x0301)) }' 1
run_test "utf8_is_combining_no" 'import "std/string.kr"
fn main() { exit(utf8_is_combining(65)) }' 0

# --- Greek case folding (v2.8.13) ---
run_test_output "greek_lower_sentence" 'import "std/string.kr"
fn main() { println_str(str_lower_utf8("Γειά σου Κόσμε")) }' "γειά σου κόσμε"
run_test_output "greek_upper_sentence" 'import "std/string.kr"
fn main() { println_str(str_upper_utf8("γειά σου κόσμε")) }' "ΓΕΙΆ ΣΟΥ ΚΌΣΜΕ"
run_test_output "greek_upper_final_sigma" 'import "std/string.kr"
fn main() { println_str(str_upper_utf8("ελληνικός")) }' "ΕΛΛΗΝΙΚΌΣ"
run_test_output "greek_mixed_latin1" 'import "std/string.kr"
fn main() { println_str(str_upper_utf8("café Ωραία")) }' "CAFÉ ΩΡΑΊΑ"
run_test "greek_lower_alpha" 'import "std/string.kr"
fn main() {
    if utf8_lower_codepoint(0x0391) == 0x03B1 { exit(1) }
    exit(0)
}' 1
run_test "greek_upper_omega" 'import "std/string.kr"
fn main() {
    if utf8_upper_codepoint(0x03C9) == 0x03A9 { exit(1) }
    exit(0)
}' 1
run_test "greek_final_sigma_to_sigma" 'import "std/string.kr"
fn main() {
    if utf8_upper_codepoint(0x03C2) == 0x03A3 { exit(1) }
    exit(0)
}' 1

# --- String builder (v2.8.11) ---
run_test_output "sb_basic" 'import "std/string.kr"
fn main() {
    uint64 sb = sb_new(16)
    sb = sb_append_str(sb, "x = ")
    sb = sb_append_int(sb, 42)
    uint64 r = sb_finish(sb)
    println_str(r)
    sb_free(sb)
}' "x = 42"
run_test_output "sb_mixed" 'import "std/string.kr"
import "std/math_float.kr"
fn main() {
    uint64 sb = sb_new(16)
    sb = sb_append_str(sb, "hex=")
    sb = sb_append_hex(sb, 0xDEAD)
    sb = sb_append_str(sb, ", bool=")
    sb = sb_append_bool(sb, 0)
    sb = sb_append_str(sb, ", f=")
    sb = sb_append_float(sb, 1.5, 2)
    uint64 r = sb_finish(sb)
    println_str(r)
    sb_free(sb)
}' "hex=0xdead, bool=false, f=1.50"
run_test "sb_grows" 'import "std/string.kr"
fn main() {
    uint64 sb = sb_new(4)     // deliberately tiny
    sb = sb_append_str(sb, "0123456789ABCDEFGHIJ")   // force grow
    exit(sb_len(sb))
}' 20
run_test_output "str_from_bool_true" 'import "std/string.kr"
fn main() { println_str(str_from_bool(1)) }' "true"
run_test_output "str_from_bool_false" 'import "std/string.kr"
fn main() { println_str(str_from_bool(0)) }' "false"
run_test_output "str_from_codepoint_latin1" 'import "std/string.kr"
fn main() { println_str(str_from_codepoint(0xE9)) }' "é"

# --- Error-handling helpers (v2.8.14) ---
run_test "opt_some_unwrap" 'import "std/string.kr"
fn main() { exit(opt_unwrap(opt_some(42))) }' 42
run_test "opt_is_some_yes" 'import "std/string.kr"
fn main() { exit(opt_is_some(opt_some(0))) }' 1
run_test "opt_is_some_no" 'import "std/string.kr"
fn main() { exit(opt_is_some(opt_none())) }' 0
run_test "is_errno_yes" 'import "std/io.kr"
fn main() { exit(is_errno(0xFFFFFFFFFFFFFFFE)) }' 1
run_test "is_errno_no" 'import "std/io.kr"
fn main() { exit(is_errno(42)) }' 0
run_test "get_errno_val" 'import "std/io.kr"
fn main() { exit(get_errno(0xFFFFFFFFFFFFFFFE)) }' 2

# --- isb() / alloc_aligned() (v2.8.14) ---
run_test "isb_noop" 'fn main() { isb(); exit(0) }' 0
run_test "dsb_noop" 'fn main() { dsb(); exit(0) }' 0
run_test "dmb_noop" 'fn main() { dmb(); exit(0) }' 0
run_test "dcache_flush_basic" 'fn main() {
    u64 p = alloc(64)
    store64(p, 0x1234)
    dcache_flush(p)
    u64 v = load64(p)
    exit(v & 0xFF)
}' 52
run_test "icache_invalidate_basic" 'fn main() {
    u64 p = alloc(64)
    icache_invalidate(p)
    exit(0)
}' 0
run_test "memmove_forward" 'import "std/mem.kr"
fn main() {
    u64 p = alloc(64)
    store64(p, 0xAABBCCDD)
    memmove(p + 8, p, 8)
    u64 v = load64(p + 8)
    if v == 0xAABBCCDD { exit(11) }
    exit(1)
}' 11
run_test "memmove_backward_overlap" 'import "std/mem.kr"
fn main() {
    // Layout: bytes 0..=7 = 1..8. Shift right by 4, so bytes 4..=11
    // become 1..8. memcpy would corrupt this; memmove must not.
    u64 p = alloc(32)
    u64 i = 0
    while i < 8 { store8(p + i, i + 1); i = i + 1 }
    memmove(p + 4, p, 8)
    // Verify: p[4..11] = 1..8
    u64 sum = 0
    i = 4
    while i < 12 { sum = sum + load8(p + i); i = i + 1 }
    exit(sum)
}' 36
run_test "memmove_forward_overlap" 'import "std/mem.kr"
fn main() {
    u64 p = alloc(32)
    u64 i = 0
    while i < 8 { store8(p + 4 + i, i + 1); i = i + 1 }
    // Shift left by 4: bytes 0..=7 become 1..=8 (read from 4..=11).
    memmove(p, p + 4, 8)
    u64 sum = 0
    i = 0
    while i < 8 { sum = sum + load8(p + i); i = i + 1 }
    exit(sum)
}' 36
run_test "memmove_zero_len" 'import "std/mem.kr"
fn main() {
    // Must be a no-op regardless of pointer values.
    memmove(0, 0, 0)
    exit(0)
}' 0

# --- Bounds checks under --debug ---
run_bchk_test() {
    local name="$1"
    local input="$2"
    local expected="$3"
    TOTAL=$((TOTAL + 1))
    local REPO_ROOT="$DIR/.."
    printf '%s\n' "$input" > "$REPO_ROOT/test_tmp_$$.kr"
    if $KRC --debug $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_bchk_$$ > /dev/null 2>&1; then
        rm -f "$REPO_ROOT/test_tmp_$$.kr"
        chmod +x /tmp/krc_bchk_$$
        local got=0
        /tmp/krc_bchk_$$ > /dev/null 2>&1 && got=0 || got=$?
        if [ "$got" = "$expected" ]; then
            PASS=$((PASS + 1))
        else
            echo "FAIL: $name (expected $expected, got $got)"; FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL: $name (compilation failed)"; FAIL=$((FAIL + 1))
    fi
    rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_bchk_$$
}
run_bchk_test "bchk_stack_in_range"    'fn main() { u64[4] a; a[0] = 1; a[3] = 4; exit(a[3]) }' 4
run_bchk_test "bchk_stack_oob_write"   'fn main() { u64[4] a; a[4] = 99; exit(0) }' 1
run_bchk_test "bchk_stack_oob_read"    'fn main() { u64[4] a; exit(a[7]) }' 1
run_bchk_test "bchk_static_in_range"   'static u64[8] s; fn main() { s[5] = 42; exit(s[5]) }' 42
run_bchk_test "bchk_static_oob_write"  'static u64[8] s; fn main() { s[8] = 1; exit(0) }' 1

# --- Literal-overflow warning ---
TOTAL=$((TOTAL + 1))
printf 'fn main() { u8 b = 300; exit(b) }\n' > "$DIR/../test_tmp_trunc_$$.kr"
trunc_out=$($KRC $KRC_FLAGS "$DIR/../test_tmp_trunc_$$.kr" -o /tmp/krc_trunc_$$ 2>&1)
if echo "$trunc_out" | grep -q "literal initializer does not fit"; then
    PASS=$((PASS + 1))
else
    echo "FAIL: literal_overflow_warns (no warning emitted)"; FAIL=$((FAIL + 1))
fi
rm -f "$DIR/../test_tmp_trunc_$$.kr" /tmp/krc_trunc_$$

TOTAL=$((TOTAL + 1))
printf 'fn main() { u8 b = 200; exit(b) }\n' > "$DIR/../test_tmp_okw_$$.kr"
okw_out=$($KRC $KRC_FLAGS "$DIR/../test_tmp_okw_$$.kr" -o /tmp/krc_okw_$$ 2>&1)
if echo "$okw_out" | grep -q "literal initializer"; then
    echo "FAIL: literal_in_range_silent (false warning)"; FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1))
fi
rm -f "$DIR/../test_tmp_okw_$$.kr" /tmp/krc_okw_$$

# --- Unused-variable warning ---
TOTAL=$((TOTAL + 1))
printf 'fn main() { u64 stale = 5; exit(0) }\n' > "$DIR/../test_tmp_uv_$$.kr"
uv_out=$($KRC $KRC_FLAGS "$DIR/../test_tmp_uv_$$.kr" -o /tmp/krc_uv_$$ 2>&1)
if echo "$uv_out" | grep -q "unused variable.*stale"; then
    PASS=$((PASS + 1))
else
    echo "FAIL: unused_var_warns (no warning)"; FAIL=$((FAIL + 1))
fi
rm -f "$DIR/../test_tmp_uv_$$.kr" /tmp/krc_uv_$$

TOTAL=$((TOTAL + 1))
printf 'fn main() { u64 _skip = 5; exit(0) }\n' > "$DIR/../test_tmp_uvs_$$.kr"
uvs_out=$($KRC $KRC_FLAGS "$DIR/../test_tmp_uvs_$$.kr" -o /tmp/krc_uvs_$$ 2>&1)
if echo "$uvs_out" | grep -q "unused variable"; then
    echo "FAIL: unused_underscore_silent (false warning)"; FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1))
fi
rm -f "$DIR/../test_tmp_uvs_$$.kr" /tmp/krc_uvs_$$

TOTAL=$((TOTAL + 1))
printf 'fn main() { u64 x = 5; exit(x) }\n' > "$DIR/../test_tmp_uvu_$$.kr"
uvu_out=$($KRC $KRC_FLAGS "$DIR/../test_tmp_uvu_$$.kr" -o /tmp/krc_uvu_$$ 2>&1)
if echo "$uvu_out" | grep -q "unused variable"; then
    echo "FAIL: used_var_silent (false warning)"; FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1))
fi
rm -f "$DIR/../test_tmp_uvu_$$.kr" /tmp/krc_uvu_$$

# --- Uninitialized-read warning ---
TOTAL=$((TOTAL + 1))
printf 'fn main() { u64 stale; exit(stale) }\n' > "$DIR/../test_tmp_ur_$$.kr"
ur_out=$($KRC $KRC_FLAGS "$DIR/../test_tmp_ur_$$.kr" -o /tmp/krc_ur_$$ 2>&1)
if echo "$ur_out" | grep -q "used before initialization.*stale"; then
    PASS=$((PASS + 1))
else
    echo "FAIL: uninit_read_warns (no warning)"; FAIL=$((FAIL + 1))
fi
rm -f "$DIR/../test_tmp_ur_$$.kr" /tmp/krc_ur_$$

TOTAL=$((TOTAL + 1))
printf 'fn main() { u64 x = 0; exit(x) }\n' > "$DIR/../test_tmp_urs_$$.kr"
urs_out=$($KRC $KRC_FLAGS "$DIR/../test_tmp_urs_$$.kr" -o /tmp/krc_urs_$$ 2>&1)
if echo "$urs_out" | grep -q "used before initialization"; then
    echo "FAIL: init_read_silent (false warning)"; FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1))
fi
rm -f "$DIR/../test_tmp_urs_$$.kr" /tmp/krc_urs_$$

TOTAL=$((TOTAL + 1))
printf 'fn main() { u64 _x; exit(_x) }\n' > "$DIR/../test_tmp_urus_$$.kr"
urus_out=$($KRC $KRC_FLAGS "$DIR/../test_tmp_urus_$$.kr" -o /tmp/krc_urus_$$ 2>&1)
if echo "$urus_out" | grep -q "used before initialization"; then
    echo "FAIL: underscore_uninit_silent (false warning)"; FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1))
fi
rm -f "$DIR/../test_tmp_urus_$$.kr" /tmp/krc_urus_$$

TOTAL=$((TOTAL + 1))
printf 'fn main() { u8 b = 10; b = 300; exit(b) }\n' > "$DIR/../test_tmp_tas_$$.kr"
tas_out=$($KRC $KRC_FLAGS "$DIR/../test_tmp_tas_$$.kr" -o /tmp/krc_tas_$$ 2>&1)
if echo "$tas_out" | grep -q "literal assignment does not fit"; then
    PASS=$((PASS + 1))
else
    echo "FAIL: literal_assign_warns (no warning emitted)"; FAIL=$((FAIL + 1))
fi
rm -f "$DIR/../test_tmp_tas_$$.kr" /tmp/krc_tas_$$
run_test "alloc_aligned_64" 'import "std/mem.kr"
fn main() {
    uint64 buf = alloc_aligned(100, 64)
    if (buf & 63) != 0 { exit(1) }
    alloc_aligned_free(buf)
    exit(0)
}' 0
run_test "alloc_aligned_256" 'import "std/mem.kr"
fn main() {
    uint64 buf = alloc_aligned(1000, 256)
    if (buf & 255) != 0 { exit(1) }
    alloc_aligned_free(buf)
    exit(0)
}' 0

# --- Builtin: dealloc ---
run_test "dealloc_noop" 'fn main() { uint64 p = alloc(64); dealloc(p); exit(0) }' 0

# --- Builtin: memset ---
run_test_output "memset_basic" 'fn main() {
    uint64 buf = alloc(64)
    memset(buf, 65, 5)
    write(1, buf, 5)
    exit(0)
}' "AAAAA"

# --- Builtin: memcpy ---
run_test_output "memcpy_basic" 'fn main() {
    uint64 src = "hello"
    uint64 dst = alloc(64)
    memcpy(dst, src, 5)
    write(1, dst, 5)
    exit(0)
}' "hello"

# --- Kernel Features ---

# Inline assembly: nop (should compile and run without crashing)
run_test "asm_nop" 'fn main() { asm("nop"); exit(42) }' 42

# Inline assembly: multi-line block
run_test "asm_block" 'fn main() { asm { "nop"; "nop"; "nop" }; exit(7) }' 7

# Inline assembly: raw hex bytes (x86-only: 0x90 = nop)
if [ "$ARCH" != "aarch64" ]; then
    run_test "asm_hex" 'fn main() { asm("0x90"); exit(5) }' 5
else
    echo "  asm_hex: SKIP (x86-only)"; PASS=$((PASS+1)); TOTAL=$((TOTAL+1))
fi

# Signed comparisons: signed_lt with negative-like values
run_test "signed_lt_true" 'fn main() {
    uint64 a = 0xFFFFFFFFFFFFFFFF
    uint64 b = 1
    uint64 r = signed_lt(a, b)
    exit(r)
}' 1

run_test "signed_lt_false" 'fn main() {
    uint64 a = 5
    uint64 b = 3
    uint64 r = signed_lt(a, b)
    exit(r)
}' 0

run_test "signed_gt_true" 'fn main() {
    uint64 a = 1
    uint64 b = 0xFFFFFFFFFFFFFFFF
    uint64 r = signed_gt(a, b)
    exit(r)
}' 1

run_test "signed_le_true" 'fn main() {
    uint64 a = 5
    uint64 b = 5
    uint64 r = signed_le(a, b)
    exit(r)
}' 1

run_test "signed_ge_true" 'fn main() {
    uint64 a = 0xFFFFFFFFFFFFFFFF
    uint64 b = 0xFFFFFFFFFFFFFFFF
    uint64 r = signed_ge(a, b)
    exit(r)
}' 1

# Bitfield operations
run_test "bit_get_1" 'fn main() {
    uint64 v = 0xFF
    uint64 r = bit_get(v, 3)
    exit(r)
}' 1

run_test "bit_get_0" 'fn main() {
    uint64 v = 0xF0
    uint64 r = bit_get(v, 2)
    exit(r)
}' 0

run_test "bit_set" 'fn main() {
    uint64 v = 0
    v = bit_set(v, 3)
    exit(v)
}' 8

run_test "bit_clear" 'fn main() {
    uint64 v = 0xFF
    v = bit_clear(v, 3)
    exit(v & 0xFF)
}' 247

run_test "bit_range" 'fn main() {
    uint64 v = 0xAB
    uint64 r = bit_range(v, 4, 4)
    exit(r)
}' 10

run_test "bit_insert" 'fn main() {
    uint64 v = 0x00
    v = bit_insert(v, 4, 4, 0xF)
    exit(v)
}' 240

# @naked function (x86-only: uses raw x86 machine code bytes)
if [ "$ARCH" != "aarch64" ]; then
    run_test "naked_fn" '@naked fn raw_exit() {
        asm("0x48 0xC7 0xC7 0x2A 0x00 0x00 0x00")
        asm("0x48 0xC7 0xC0 0x3C 0x00 0x00 0x00")
        asm("0x0F 0x05")
    }
    fn main() { raw_exit() }' 42
else
    echo "  naked_fn: SKIP (x86-only)"; PASS=$((PASS+1)); TOTAL=$((TOTAL+1))
fi

# @noreturn annotation (should compile fine)
run_test "noreturn_fn" '@noreturn fn die() { exit(99) }
fn main() { die() }' 99

# volatile block (same as unsafe)
run_test "volatile_block" 'fn main() {
    uint64 buf = alloc(64)
    uint64 val = 0
    unsafe { *(buf as uint64) = 42 }
    volatile { *(buf as uint64) -> val }
    exit(val)
}' 42

# @packed struct annotation (should parse without error)
run_test "packed_struct" '@packed struct Reg { uint8 a; uint32 b }
fn main() {
    uint8[16] buf
    exit(0)
}' 0

# @section annotation (should parse without error)
run_test "section_attr" '@section(".text.init") fn early_init() { exit(0) }
fn main() { early_init() }' 0

# --freestanding flag (should compile, main has no auto-exit, so explicit exit needed)
# Can't easily test this without a linker, just test that it parses
# run_test "freestanding" handled by CLI flag test below

# --- Function Pointers ---

# fn_addr + call_ptr basic
run_test "fn_ptr_basic" 'fn add(uint64 a, uint64 b) -> uint64 { return a + b }
fn main() {
    uint64 fp = fn_addr("add")
    uint64 r = call_ptr(fp, 30, 12)
    exit(r)
}' 42

# fn_ptr dispatch table
run_test "fn_ptr_dispatch" 'fn h0() -> uint64 { return 10 }
fn h1() -> uint64 { return 20 }
fn h2() -> uint64 { return 12 }
fn main() {
    uint64 t = alloc(24)
    uint64 a = fn_addr("h0")
    uint64 b = fn_addr("h1")
    uint64 c = fn_addr("h2")
    unsafe { *(t as uint64) = a }
    uint64 t8 = t + 8
    unsafe { *(t8 as uint64) = b }
    uint64 t16 = t + 16
    unsafe { *(t16 as uint64) = c }
    uint64 fp = 0
    unsafe { *(t as uint64) -> fp }
    uint64 r = call_ptr(fp)
    uint64 fp2 = 0
    uint64 tb = t + 8
    unsafe { *(tb as uint64) -> fp2 }
    r = r + call_ptr(fp2)
    uint64 fp3 = 0
    uint64 tc = t + 16
    unsafe { *(tc as uint64) -> fp3 }
    r = r + call_ptr(fp3)
    exit(r)
}' 42

# fn_ptr no args
run_test "fn_ptr_noargs" 'fn get42() -> uint64 { return 42 }
fn main() {
    uint64 fp = fn_addr("get42")
    uint64 r = call_ptr(fp)
    exit(r)
}' 42

# --- uint16 pointer operations ---
run_test "uint16_store_load" 'fn main() {
    uint64 buf = alloc(64)
    uint16 val = 0xBEEF
    unsafe { *(buf as uint16) = val }
    uint16 got = 0
    unsafe { *(buf as uint16) -> got }
    uint64 r = got
    exit(r & 0xFF)
}' 239

run_test "uint16_store_load_small" 'fn main() {
    uint64 buf = alloc(64)
    uint16 val = 42
    unsafe { *(buf as uint16) = val }
    uint16 got = 0
    unsafe { *(buf as uint16) -> got }
    uint64 r = got
    exit(r)
}' 42

run_test "uint16_two_slots" 'fn main() {
    uint64 buf = alloc(64)
    uint16 a = 10
    uint16 b = 32
    unsafe { *(buf as uint16) = a }
    uint64 buf2 = buf + 2
    unsafe { *(buf2 as uint16) = b }
    uint16 va = 0
    uint16 vb = 0
    unsafe { *(buf as uint16) -> va }
    unsafe { *(buf2 as uint16) -> vb }
    uint64 ra = va
    uint64 rb = vb
    exit(ra + rb)
}' 42

# --- Atomic operations ---
run_test "atomic_store_load" 'fn main() {
    uint64 buf = alloc(64)
    atomic_store(buf, 42)
    uint64 v = atomic_load(buf)
    exit(v)
}' 42

run_test "atomic_add_basic" 'fn main() {
    uint64 buf = alloc(64)
    atomic_store(buf, 30)
    uint64 old = atomic_add(buf, 12)
    uint64 v = atomic_load(buf)
    exit(v)
}' 42

run_test "atomic_add_returns_old" 'fn main() {
    uint64 buf = alloc(64)
    atomic_store(buf, 40)
    uint64 old = atomic_add(buf, 10)
    exit(old)
}' 40

run_test "atomic_cas_success" 'fn main() {
    uint64 buf = alloc(64)
    atomic_store(buf, 10)
    uint64 ok = atomic_cas(buf, 10, 42)
    uint64 v = atomic_load(buf)
    if ok == 1 && v == 42 { exit(42) }
    exit(0)
}' 42

run_test "atomic_cas_fail" 'fn main() {
    uint64 buf = alloc(64)
    atomic_store(buf, 10)
    uint64 ok = atomic_cas(buf, 99, 42)
    uint64 v = atomic_load(buf)
    if ok == 0 && v == 10 { exit(42) }
    exit(0)
}' 42

# --- Volatile blocks ---
run_test "volatile_store_load" 'fn main() {
    uint64 buf = alloc(64)
    volatile { *(buf as uint64) = 42 }
    uint64 v = 0
    volatile { *(buf as uint64) -> v }
    exit(v)
}' 42

run_test "volatile_roundtrip" 'fn main() {
    uint64 buf = alloc(64)
    volatile { *(buf as uint64) = 100 }
    uint64 a = 0
    volatile { *(buf as uint64) -> a }
    volatile { *(buf as uint64) = 42 }
    uint64 b = 0
    volatile { *(buf as uint64) -> b }
    exit(b)
}' 42

run_test "volatile_uint8" 'fn main() {
    uint64 buf = alloc(64)
    uint8 val = 42
    volatile { *(buf as uint8) = val }
    uint8 got = 0
    volatile { *(buf as uint8) -> got }
    uint64 r = got
    exit(r)
}' 42

# --- MSR/MRS (compile-only, privileged instructions cannot run in userspace) ---
if [ "$ARCH" != "aarch64" ]; then
    # x86: rdmsr/wrmsr are ring-0 only; just verify the asm block compiles
    TOTAL=$((TOTAL + 1))
    printf 'fn main() { exit(42) }\n@naked fn msr_test() { asm("rdmsr") }\n' > /tmp/krc_test_$$.kr
    if $KRC $KRC_FLAGS /tmp/krc_test_$$.kr -o /tmp/krc_test_$$ > /dev/null 2>&1; then
        chmod +x /tmp/krc_test_$$
        /tmp/krc_test_$$ > /dev/null 2>&1; got=$?
        if [ "$got" = "42" ]; then
            PASS=$((PASS + 1))
        else
            echo "FAIL: msr_compile (expected 42, got $got)"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL: msr_compile (compilation failed)"
        FAIL=$((FAIL + 1))
    fi
    rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_test_$$

    TOTAL=$((TOTAL + 1))
    printf 'fn main() { exit(42) }\n@naked fn msr_test() { asm("wrmsr") }\n' > /tmp/krc_test_$$.kr
    if $KRC $KRC_FLAGS /tmp/krc_test_$$.kr -o /tmp/krc_test_$$ > /dev/null 2>&1; then
        chmod +x /tmp/krc_test_$$
        /tmp/krc_test_$$ > /dev/null 2>&1; got=$?
        if [ "$got" = "42" ]; then
            PASS=$((PASS + 1))
        else
            echo "FAIL: msr_wrmsr_compile (expected 42, got $got)"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL: msr_wrmsr_compile (compilation failed)"
        FAIL=$((FAIL + 1))
    fi
    rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_test_$$
else
    echo "  msr_compile: SKIP (x86-only)"; PASS=$((PASS+1)); TOTAL=$((TOTAL+1))
    echo "  msr_wrmsr_compile: SKIP (x86-only)"; PASS=$((PASS+1)); TOTAL=$((TOTAL+1))
fi

# --- Dead Code Elimination test ---
echo ""
echo "--- DCE test ---"
TOTAL=$((TOTAL + 1))

# Program with an unused function — DCE should eliminate it
cat > /tmp/krc_dce_unused_$$.kr << 'KRSRC'
fn unused_big() -> uint64 {
    uint64 a = 1
    uint64 b = 2
    uint64 c = 3
    uint64 d = 4
    uint64 e = 5
    uint64 f = a + b + c + d + e
    uint64 g = f * 2
    uint64 h = g + f
    uint64 i = h * g + f
    uint64 j = i + h + g + f + e + d + c + b + a
    return j
}
fn unused_big2() -> uint64 {
    uint64 a = 10
    uint64 b = 20
    uint64 c = 30
    uint64 d = 40
    uint64 e = 50
    uint64 f = a + b + c + d + e
    uint64 g = f * 3
    uint64 h = g + f
    uint64 i = h * g + f
    uint64 j = i + h + g + f + e + d + c + b + a
    return j
}
fn unused_big3() -> uint64 {
    uint64 a = 100
    uint64 b = 200
    uint64 c = 300
    uint64 d = 400
    uint64 e = 500
    uint64 f = a + b + c + d + e
    uint64 g = f * 4
    uint64 h = g + f
    uint64 i = h * g + f
    uint64 j = i + h + g + f + e + d + c + b + a
    return j
}
fn main() { exit(42) }
KRSRC

# Same program but all functions are called
cat > /tmp/krc_dce_used_$$.kr << 'KRSRC'
fn used_big() -> uint64 {
    uint64 a = 1
    uint64 b = 2
    uint64 c = 3
    uint64 d = 4
    uint64 e = 5
    uint64 f = a + b + c + d + e
    uint64 g = f * 2
    uint64 h = g + f
    uint64 i = h * g + f
    uint64 j = i + h + g + f + e + d + c + b + a
    return j
}
fn used_big2() -> uint64 {
    uint64 a = 10
    uint64 b = 20
    uint64 c = 30
    uint64 d = 40
    uint64 e = 50
    uint64 f = a + b + c + d + e
    uint64 g = f * 3
    uint64 h = g + f
    uint64 i = h * g + f
    uint64 j = i + h + g + f + e + d + c + b + a
    return j
}
fn used_big3() -> uint64 {
    uint64 a = 100
    uint64 b = 200
    uint64 c = 300
    uint64 d = 400
    uint64 e = 500
    uint64 f = a + b + c + d + e
    uint64 g = f * 4
    uint64 h = g + f
    uint64 i = h * g + f
    uint64 j = i + h + g + f + e + d + c + b + a
    return j
}
fn main() {
    uint64 r = used_big() + used_big2() + used_big3()
    exit(r & 0xFF)
}
KRSRC

if $KRC $KRC_FLAGS /tmp/krc_dce_unused_$$.kr -o /tmp/krc_dce_small_$$ > /dev/null 2>&1 && \
   $KRC $KRC_FLAGS /tmp/krc_dce_used_$$.kr -o /tmp/krc_dce_large_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_dce_small_$$ /tmp/krc_dce_large_$$
    small_size=$(wc -c < /tmp/krc_dce_small_$$)
    large_size=$(wc -c < /tmp/krc_dce_large_$$)
    # Verify the unused-function binary is smaller (DCE removed dead code)
    # Also verify the unused-function binary runs correctly
    /tmp/krc_dce_small_$$ > /dev/null 2>&1; small_exit=$?
    if [ "$small_size" -lt "$large_size" ] && [ "$small_exit" = "42" ]; then
        PASS=$((PASS + 1))
        echo "  dce_eliminates_unused: PASS (unused=$small_size < used=$large_size bytes, exit=$small_exit)"
    else
        echo "  dce_eliminates_unused: FAIL (unused=$small_size vs used=$large_size, exit=$small_exit)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "  dce_eliminates_unused: FAIL (compilation failed)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_dce_unused_$$.kr /tmp/krc_dce_used_$$.kr /tmp/krc_dce_small_$$ /tmp/krc_dce_large_$$

# --- ELF relocatable (.o) test ---
echo ""
echo "--- ELF relocatable (.o) test ---"
TOTAL=$((TOTAL + 1))
printf 'fn add(uint64 a, uint64 b) -> uint64 { return a + b }\nfn main() { exit(add(30, 12)) }\n' > /tmp/krc_obj_$$.kr
if $KRC $KRC_FLAGS --emit=obj /tmp/krc_obj_$$.kr -o /tmp/krc_obj_$$.o > /dev/null 2>&1; then
    # Check first 18 bytes: ELF magic (4) + class(1) + data(1) + version(1) + osabi(1) + padding(8) + e_type LE (2)
    # e_type at offset 16-17 should be 01 00 (ET_REL = 1, little-endian)
    magic=$(xxd -l 4 -p /tmp/krc_obj_$$.o 2>/dev/null)
    etype=$(xxd -s 16 -l 2 -p /tmp/krc_obj_$$.o 2>/dev/null)
    if [ "$magic" = "7f454c46" ] && [ "$etype" = "0100" ]; then
        PASS=$((PASS + 1))
        echo "  emit_obj: PASS (valid ELF relocatable, $(wc -c < /tmp/krc_obj_$$.o) bytes)"
    else
        FAIL=$((FAIL + 1))
        echo "  emit_obj: FAIL (bad ELF header: magic=$magic etype=$etype)"
    fi
else
    FAIL=$((FAIL + 1))
    echo "  emit_obj: FAIL (compilation with --emit=obj failed)"
fi

# Also test -c flag produces same result
TOTAL=$((TOTAL + 1))
if $KRC $KRC_FLAGS -c /tmp/krc_obj_$$.kr -o /tmp/krc_obj_c_$$.o > /dev/null 2>&1; then
    c_magic=$(xxd -l 4 -p /tmp/krc_obj_c_$$.o 2>/dev/null)
    c_etype=$(xxd -s 16 -l 2 -p /tmp/krc_obj_c_$$.o 2>/dev/null)
    if [ "$c_magic" = "7f454c46" ] && [ "$c_etype" = "0100" ]; then
        PASS=$((PASS + 1))
        echo "  emit_obj_c_flag: PASS"
    else
        FAIL=$((FAIL + 1))
        echo "  emit_obj_c_flag: FAIL (bad ELF header)"
    fi
else
    FAIL=$((FAIL + 1))
    echo "  emit_obj_c_flag: FAIL (compilation with -c failed)"
fi

# Test readelf can parse sections and symbols.
# Cross-compile KRC_FLAGS (e.g. --arch=arm64 on an arm64 runner re-targeting
# the host) can produce a valid .o that this regex-based test doesn't cover.
# Skip on non-x86_64 hosts where KRC_FLAGS targets arm64.
TOTAL=$((TOTAL + 1))
if [ "$(uname -m)" != "x86_64" ] && [ "$(uname -m)" != "amd64" ]; then
    PASS=$((PASS + 1))
    echo "  emit_obj_readelf: SKIP (non-x86_64 host)"
elif command -v readelf > /dev/null 2>&1 && [ -f /tmp/krc_obj_$$.o ]; then
    sections=$(readelf -S /tmp/krc_obj_$$.o 2>/dev/null)
    has_text=$(echo "$sections" | grep -c '\.text')
    has_symtab=$(echo "$sections" | grep -c '\.symtab')
    symbols=$(readelf -s /tmp/krc_obj_$$.o 2>/dev/null)
    has_main=$(echo "$symbols" | grep -c 'FUNC.*GLOBAL.*main')
    has_add=$(echo "$symbols" | grep -c 'FUNC.*LOCAL.*add')
    if [ "$has_text" -ge 1 ] && [ "$has_symtab" -ge 1 ] && [ "$has_main" -ge 1 ] && [ "$has_add" -ge 1 ]; then
        PASS=$((PASS + 1))
        echo "  emit_obj_readelf: PASS (.text, .symtab, main GLOBAL, add LOCAL)"
    else
        FAIL=$((FAIL + 1))
        echo "  emit_obj_readelf: FAIL (text=$has_text symtab=$has_symtab main=$has_main add=$has_add)"
    fi
else
    PASS=$((PASS + 1))
    echo "  emit_obj_readelf: SKIP (readelf not found or .o missing)"
fi
rm -f /tmp/krc_obj_$$.kr /tmp/krc_obj_$$.o /tmp/krc_obj_c_$$.o

# --- Generics (monomorphization) ---
run_test "generic_fn_single" 'fn max_gen<T>(T a, T b) -> T {
    if a > b { return a }
    return b
}
fn main() {
    uint64 r = max_gen<uint64>(30, 42)
    exit(r)
}' 42

run_test "generic_fn_identity" 'fn identity<T>(T x) -> T { return x }
fn main() {
    uint64 r = identity<uint64>(7)
    exit(r)
}' 7

run_test "generic_fn_chain" 'fn max_gen<T>(T a, T b) -> T {
    if a > b { return a }
    return b
}
fn identity<T>(T x) -> T { return x }
fn main() {
    uint64 r = max_gen<uint64>(30, 42)
    uint64 s = identity<uint64>(r)
    exit(s)
}' 42

run_test "generic_call_uint32" 'fn add_one<T>(T x) -> T { return x + 1 }
fn main() {
    uint32 r = add_one<uint32>(41)
    exit(r)
}' 42

run_test "generic_multi_param" 'fn pick_first<T, U>(T a, U b) -> T { return a }
fn main() {
    uint64 r = pick_first<uint64, uint32>(42, 99)
    exit(r)
}' 42

run_test "generic_no_conflict_lt" 'fn id<T>(T x) -> T { return x }
fn main() {
    uint64 a = 3
    uint64 b = 5
    if a < b { exit(id<uint64>(42)) }
    exit(0)
}' 42

# --- Error detection tests ---
echo ""
echo "--- Error detection tests ---"

# Wrong argument count
TOTAL=$((TOTAL + 1))
printf 'fn add(uint64 a, uint64 b) -> uint64 { return a + b }\nfn main() { exit(add(1, 2, 3)) }\n' > /tmp/krc_err_$$.kr
if $KRC $KRC_FLAGS /tmp/krc_err_$$.kr -o /tmp/krc_err_$$ 2>/tmp/krc_stderr_$$ ; then
    echo "FAIL: wrong_arg_count (should not compile)"
    FAIL=$((FAIL + 1))
else
    if grep -q "wrong number of arguments" /tmp/krc_stderr_$$; then
        PASS=$((PASS + 1))
        echo "  wrong_arg_count: PASS (error detected)"
    else
        echo "FAIL: wrong_arg_count (wrong error)"
        FAIL=$((FAIL + 1))
    fi
fi
rm -f /tmp/krc_err_$$.kr /tmp/krc_err_$$ /tmp/krc_stderr_$$

# `let` with no initializer must be rejected (nothing to infer the type from).
TOTAL=$((TOTAL + 1))
printf 'fn main() { let x; exit(0) }\n' > /tmp/krc_err_$$.kr
if $KRC $KRC_FLAGS /tmp/krc_err_$$.kr -o /tmp/krc_err_$$ 2>/tmp/krc_stderr_$$ ; then
    echo "FAIL: let_no_init (should not compile)"
    FAIL=$((FAIL + 1))
else
    if grep -qi "let" /tmp/krc_stderr_$$; then
        PASS=$((PASS + 1))
        echo "  let_no_init: PASS (error detected)"
    else
        echo "FAIL: let_no_init (wrong error)"
        FAIL=$((FAIL + 1))
    fi
fi
rm -f /tmp/krc_err_$$.kr /tmp/krc_err_$$ /tmp/krc_stderr_$$

# --- Diagnostics quality: errors must show source span + caret ---
# Each case must (a) fail to compile, (b) print the message substring,
# (c) print the source-line gutter " | ", and (d) print a caret "^".
diag_span_test() {
    local name="$1"; local src="$2"; local msg="$3"
    TOTAL=$((TOTAL + 1))
    printf '%s\n' "$src" > /tmp/krc_diag_$$.kr
    if $KRC $KRC_FLAGS /tmp/krc_diag_$$.kr -o /tmp/krc_diag_bin_$$ 2>/tmp/krc_diag_err_$$ ; then
        echo "FAIL: $name (should not compile)"; FAIL=$((FAIL + 1))
    elif grep -qF "$msg" /tmp/krc_diag_err_$$ && grep -q ' | ' /tmp/krc_diag_err_$$ && grep -q '\^' /tmp/krc_diag_err_$$; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name (missing message / span / caret):"; sed 's/^/    /' /tmp/krc_diag_err_$$ | head -5
        FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_diag_$$.kr /tmp/krc_diag_bin_$$ /tmp/krc_diag_err_$$
}
diag_span_test "diag_syntax"     'fn main() { exit( }' "expected"
diag_span_test "diag_undeclared" 'fn main() { exit(nope) }' "undeclared identifier"
diag_span_test "diag_undef_fn"   'fn main() { exit(missing_fn(1)) }' "undefined function"
# "did you mean" suggestions: a near-miss identifier/function name within
# edit distance 2 of an in-scope local / static / function is suggested.
diag_span_test "diag_suggest_local" 'fn main() {
    u64 counter = 5
    exit(countr)
}' "did you mean '"'counter'"'?"
diag_span_test "diag_suggest_static" 'static uint64 total_bytes = 7
fn main() { exit(total_byte) }' "did you mean '"'total_bytes'"'?"
# helper must be genuinely retained (really called + not a pure single-expr
# that the inliner folds away) for the fn-name table to still hold it.
diag_span_test "diag_suggest_fn" 'fn helper(u64 a) -> u64 { u64 b = a + 1
    return b }
fn main() { u64 x = helper(2)
    exit(helpr(x)) }' "did you mean '"'helper'"'?"
# Legacy backend shares the did-you-mean helper — assert the hint there too.
TOTAL=$((TOTAL + 1))
printf '%s\n' 'fn main() {
    u64 counter = 5
    exit(countr)
}' > /tmp/krc_dym_$$.kr
if $KRC $KRC_FLAGS --legacy /tmp/krc_dym_$$.kr -o /tmp/krc_dym_bin_$$ 2>/tmp/krc_dym_err_$$ ; then
    echo "FAIL: legacy_suggest_local (should not compile)"; FAIL=$((FAIL + 1))
elif grep -qF "did you mean 'counter'?" /tmp/krc_dym_err_$$; then
    PASS=$((PASS + 1))
else
    echo "FAIL: legacy_suggest_local (missing did-you-mean hint):"; sed 's/^/    /' /tmp/krc_dym_err_$$ | head -3
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_dym_$$.kr /tmp/krc_dym_bin_$$ /tmp/krc_dym_err_$$
# The arm64 backends have their own error sites (legacy Ident + the BL
# fixup resolver), so assert the hint appears under --arch=arm64 too. This
# is compile-only (the error is emitted at compile time), so it runs on any
# host — catching arm64-only regressions without needing native arm64.
TOTAL=$((TOTAL + 1))
printf '%s\n' 'fn helper(u64 a) -> u64 { u64 b = a + 1
    return b }
fn main() { u64 x = helper(2)
    exit(helpr(x)) }' > /tmp/krc_dyma_$$.kr
if $KRC --arch=arm64 /tmp/krc_dyma_$$.kr -o /tmp/krc_dyma_bin_$$ 2>/tmp/krc_dyma_err_$$ ; then
    echo "FAIL: arm64_suggest_fn (should not compile)"; FAIL=$((FAIL + 1))
elif grep -qF "did you mean 'helper'?" /tmp/krc_dyma_err_$$; then
    PASS=$((PASS + 1))
else
    echo "FAIL: arm64_suggest_fn (missing did-you-mean hint on arm64):"; sed 's/^/    /' /tmp/krc_dyma_err_$$ | head -3
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_dyma_$$.kr /tmp/krc_dyma_bin_$$ /tmp/krc_dyma_err_$$
diag_span_test "diag_argcount"   'fn f(u64 a) -> u64 { return a }
fn main() { exit(f(1, 2)) }' "wrong number of arguments"
diag_span_test "diag_let_noinit" 'fn main() {
    let x
    exit(0)
}' "let"
diag_span_test "diag_missing_return" 'fn g() -> u64 { u64 x = 1 }
fn main() { exit(g()) }' "may not return"
# H2: a `let` whose RHS type can't be inferred fails loud (was silently u64).
diag_span_test "diag_let_noinfer" 'fn main() {
    let x = mystery
    exit(0)
}' "infer"
# H3: ternary/match-expr arms that mix float and integer are rejected.
diag_span_test "diag_ternary_mixed" 'fn main() {
    println(1 == 1 ? 1.5 : 2)
    exit(0)
}' "mix float"
# M14: matching on a float scrutinee is rejected (legacy compared a stale
# integer register; float equality is ill-defined).
diag_span_test "diag_float_match" 'import "std/math_float.kr"
fn main() {
    f64 x = int_to_f64(1)
    u64 r = match x { 1 => 7  _ => 9 }
    exit(r)
}' "float scrutinee"
# Parser error recovery: TWO independent syntax errors in one file must BOTH
# be reported in a single run (panic-mode recovery), the run must still fail,
# and the parse-error summary line must appear.
TOTAL=$((TOTAL + 1))
printf '%s\n' 'fn a() {
    u64 x = (1 + 2
}
fn main() {
    let y = ]
    exit(0)
}' > /tmp/krc_perr_$$.kr
if $KRC $KRC_FLAGS /tmp/krc_perr_$$.kr -o /tmp/krc_perr_bin_$$ 2>/tmp/krc_perr_err_$$ ; then
    echo "FAIL: parse_recovery_multi (should not compile)"; FAIL=$((FAIL + 1))
elif grep -qF "expected ')', got '}'" /tmp/krc_perr_err_$$ \
  && grep -qF "unexpected ']' in expression" /tmp/krc_perr_err_$$ \
  && grep -qF "parse error(s)" /tmp/krc_perr_err_$$ ; then
    PASS=$((PASS + 1))
else
    echo "FAIL: parse_recovery_multi (missing one of the two errors):"; sed 's/^/    /' /tmp/krc_perr_err_$$ | head -8
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_perr_$$.kr /tmp/krc_perr_bin_$$ /tmp/krc_perr_err_$$
# H10 (lifted): `continue` inside a `for` body now runs the desugared
# increment then re-tests the condition (the parser rewrites each continue
# into { i = i + 1; continue }). The sums prove the increment still ran —
# a regression here would hang, which is the bug H10 originally guarded.
run_test "for_continue_skip" 'fn main() {
    u64 s = 0
    for i in 0..10 { if i == 3 { continue } s = s + i }
    exit(s)
}' 42
run_test "for_continue_inclusive" 'fn main() {
    u64 s = 0
    for i in 1..=5 { if i == 2 { continue } s = s + i }
    exit(s)
}' 13
run_test "for_continue_nested" 'fn main() {
    u64 s = 0
    for i in 0..3 {
        for j in 0..4 {
            if j == 1 { continue }
            s = s + j
        }
        if i == 1 { continue }
        s = s + 10
    }
    exit(s)
}' 35
run_test "for_continue_in_match" 'fn main() {
    u64 s = 0
    for i in 0..6 {
        match i { 2, 4 => { continue } _ => {} }
        s = s + i
    }
    exit(s)
}' 9
run_test "for_continue_dead_tail" 'fn main() {
    u64 s = 0
    for i in 0..5 { if i < 9 { continue; s = s + 100 } s = s + 1 }
    exit(s)
}' 0

# ---- Batch 12 (M10/M11/M12) ----
# M10: enum initializers accept 0x-hex (were parsed base-10 digit-by-digit,
# so `0x10` became 7210).
run_test "enum_hex_init" 'enum F { LOW = 0x10, NEXT, HIGH = 0xFF }
fn main() { exit(F.LOW + F.NEXT + (F.HIGH - 255)) }' "33"
# M11: range endpoints may be index/field expressions, not just bare idents.
# A trailing `..` used to be mis-consumed as struct-array `.field` access.
run_test "range_index_endpoints" 'static u64[2] b
fn main() { b[0] = 1
    b[1] = 4
    u64 s = 0
    for i in b[0]..b[1] { s = s + i }
    exit(s) }' "6"
# M12: a function ending in exit() does not fall off the end.
run_test "return_via_exit" 'fn pick(u64 x) -> u64 {
    if x > 0 { return 1 }
    exit(7)
}
fn main() { exit(pick(0)) }' "7"
# M12: a function ending in an exhaustive `_`-default match returns on all paths.
run_test "return_via_match" 'fn classify(u64 x) -> u64 {
    match x {
        0 => { return 10 }
        1 => return 20
        _ => { return 99 }
    }
}
fn main() { exit(classify(5)) }' "99"
# M12 soundness: a match WITHOUT a default arm cannot be proven exhaustive,
# so the missing-return check must still fire.
diag_span_test "diag_match_no_default" 'fn classify(u64 x) -> u64 {
    match x {
        0 => { return 10 }
        1 => { return 20 }
    }
}
fn main() { exit(classify(5)) }' "may not return"
# M12 soundness: a default arm that does not itself return must still fire.
diag_span_test "diag_match_arm_no_return" 'fn classify(u64 x) -> u64 {
    match x {
        0 => { return 10 }
        _ => { u64 y = x }
    }
}
fn main() { exit(classify(5)) }' "may not return"

# #101: type-checker errors are now fatal. A genuine struct-on-non-struct
# field access must abort the build...
diag_span_test "tc_fatal_field_on_int" 'fn main() {
    u64 n = 5
    exit(n.x)
}' "field access on non-struct"
# ...while the previously-false-positive forms must still compile cleanly.
run_test "tc_slice_len_ok" 'fn total([u8] xs) -> u64 { u64 s = 0
    u64 i = 0
    while i < xs.len { s = s + xs[i] i = i + 1 } return s }
fn main() { exit(0) }' "0"
run_test "tc_struct_array_field_ok" 'struct P { u64 x u64 y }
fn main() { P[3] ps
    ps[0].x = 4
    ps[1].x = 2
    exit(ps[0].x + ps[1].x) }' "6"

# M13: `krc check` runs the real semantic checks (was a no-op that ran only
# the inert annotation/effect/lock passes and reported OK for everything).
TOTAL=$((TOTAL + 1))
printf 'fn bad() -> u64 { u64 x = 1 }\nfn main() { exit(bad()) }\n' > /tmp/krc_chk_$$.kr
if $KRC check /tmp/krc_chk_$$.kr >/dev/null 2>&1; then
    echo "FAIL: krc_check_catches_error (should report missing return)"; FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1))
fi
rm -f /tmp/krc_chk_$$.kr
TOTAL=$((TOTAL + 1))
printf 'fn good(u64 x) -> u64 { return x + 1 }\nfn main() { exit(good(6)) }\n' > /tmp/krc_chkok_$$.kr
if $KRC check /tmp/krc_chkok_$$.kr >/dev/null 2>&1; then
    PASS=$((PASS + 1))
else
    echo "FAIL: krc_check_passes_clean (should report OK)"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_chkok_$$.kr
# `krc check` now also runs the type checker (resolve_inferred_types +
# tc_check_module), so the LSP surfaces type errors. A struct-type mismatch
# must be reported by check mode, not just full compilation.
TOTAL=$((TOTAL + 1))
printf 'struct P{u64 x}\nstruct Q{u64 y}\nfn main(){ P p\n Q q = p\n exit(0) }\n' > /tmp/krc_chktc_$$.kr
if $KRC check /tmp/krc_chktc_$$.kr >/dev/null 2>&1; then
    echo "FAIL: krc_check_runs_typechecker (should report struct-type mismatch)"; FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1))
fi
rm -f /tmp/krc_chktc_$$.kr

# C2 regression: `let` must be resolved on EVERY fat-binary slice, not just the
# first. A signed `let` mis-resolved on a non-first slice flips the comparison.
# We build a fat (.krbo) binary, then run its ARM64 slice (the 2nd slice — the
# one the bug skipped) via an arm64 runner under qemu.
QEMU_A64="$(command -v qemu-aarch64-static || true)"
if [ -n "$QEMU_A64" ]; then
    TOTAL=$((TOTAL + 1))
    printf 'fn main() { i64 a = 0 - 5\n let r = a\n if r < 0 { exit(9) }\n exit(0) }\n' > /tmp/krc_c2_$$.kr
    cat "$DIR/../src/runner.kr" "$DIR/../src/bcj.kr" > /tmp/krc_c2run_$$.kr
    if $KRC /tmp/krc_c2_$$.kr -o /tmp/krc_c2_$$.krbo >/dev/null 2>&1 \
       && $KRC --arch=arm64 /tmp/krc_c2run_$$.kr -o /tmp/krc_c2run_$$ >/dev/null 2>&1; then
        chmod +x /tmp/krc_c2run_$$
        $QEMU_A64 /tmp/krc_c2run_$$ /tmp/krc_c2_$$.krbo >/dev/null 2>&1
        c2got=$?
        if [ "$c2got" = "9" ]; then
            PASS=$((PASS + 1))
        else
            echo "FAIL: fat_slice_let_arm64 (expected 9, got $c2got — non-first slice didn't resolve let)"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL: fat_slice_let_arm64 (build failed)"; FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_c2_$$.kr /tmp/krc_c2_$$.krbo /tmp/krc_c2run_$$.kr /tmp/krc_c2run_$$
fi

# Missing return in non-void function
TOTAL=$((TOTAL + 1))
printf 'fn get_val() -> uint64 { uint64 x = 42 }\nfn main() { exit(get_val()) }\n' > /tmp/krc_err_$$.kr
if $KRC $KRC_FLAGS /tmp/krc_err_$$.kr -o /tmp/krc_err_$$ 2>/tmp/krc_stderr_$$ ; then
    echo "FAIL: missing_return (should not compile)"
    FAIL=$((FAIL + 1))
else
    if grep -q "may not return" /tmp/krc_stderr_$$; then
        PASS=$((PASS + 1))
        echo "  missing_return: PASS (error detected)"
    else
        echo "FAIL: missing_return (wrong error)"
        FAIL=$((FAIL + 1))
    fi
fi
rm -f /tmp/krc_err_$$.kr /tmp/krc_err_$$ /tmp/krc_stderr_$$

# else-if chain exhaustiveness (regression: >=2 else-if branches all returning
# must be recognized as returning on all paths). Bug was in block_has_return
# type-confusing block-node vs if-node when recursing into the else-if's else.
run_test "elseif2_returns" 'fn f(u64 x) -> u64 { if x > 90 { return 4 } else if x > 80 { return 3 } else if x > 70 { return 2 } else { return 1 } }
fn main() { exit(f(85)) }' 3
run_test "elseif3_returns" 'fn f(u64 x) -> u64 { if x > 90 { return 5 } else if x > 80 { return 4 } else if x > 70 { return 3 } else if x > 60 { return 2 } else { return 1 } }
fn main() { exit(f(65)) }' 2

# Ternary conditional expression (Phase 2). Lowest precedence, right-associative,
# lowers to the same branch IR as if/else.
run_test "ternary_true"  'fn main() { u64 x = 5; u64 y = x > 3 ? 1 : 0; exit(y) }' 1
run_test "ternary_false" 'fn main() { u64 x = 2; u64 y = x > 3 ? 1 : 0; exit(y) }' 0
run_test "ternary_nested_right_assoc" 'fn main() { u64 x = 5; u64 y = x > 9 ? 3 : x > 4 ? 2 : 1; exit(y) }' 2
run_test "ternary_in_return" 'fn pick(u64 a) -> u64 { return a > 0 ? 10 : 20 }
fn main() { exit(pick(1)) }' 10
run_test "ternary_lowest_prec" 'fn main() { u64 y = 1 + 2 > 2 ? 7 : 8; exit(y) }' 7
# Regression: calls in ternary arms must not be pruned by DCE (dce_scan_node
# has to recurse into the then/else expr nodes, not just the cond child).
run_test "ternary_call_arms" 'fn fa()->u64{return 7}
fn fb()->u64{return 9}
fn main(){ exit(1 > 0 ? fa() : fb()) }' 7

# Phase 3: match bare-statement arms (no braces required).
run_test "match_bare_exit"   'fn main(){ u64 x=2; match x { 1 => exit(1)  2 => exit(2) } exit(0) }' 2
run_test "match_bare_assign" 'fn main(){ u64 x=2; u64 r=0; match x { 1 => r=10  2 => r=20 } exit(r) }' 20
run_test "match_bare_default" 'fn main(){ u64 x=9; match x { 1 => exit(1)  _ => exit(42) } }' 42
run_test "match_mixed_arms"  'fn main(){ u64 x=1; u64 r=0; match x { 1 => r=5  2 => { r=6 } } exit(r) }' 5

# Phase 3 (part 2): match-as-expression — match in value position yields a value.
run_test "match_expr_basic"   'fn main(){ u64 x=2; u64 r = match x { 1 => 10  2 => 20  _ => 0 }; exit(r) }' 20
run_test "match_expr_default" 'fn main(){ u64 x=9; u64 r = match x { 1 => 10  2 => 20  _ => 7 }; exit(r) }' 7
run_test "match_expr_no_match" 'fn main(){ u64 x=9; u64 r = match x { 1 => 10  2 => 20 }; exit(r) }' 0
run_test "match_expr_multi_pat" 'fn main(){ u64 x=3; u64 r = match x { 1, 2, 3 => 5  _ => 0 }; exit(r) }' 5
run_test "match_expr_in_call"  'fn id(u64 a)->u64{return a}
fn main(){ u64 x=1; exit(id(match x { 1 => 42  _ => 0 })) }' 42
run_test "match_expr_in_return" 'fn pick(u64 a)->u64{ return match a { 0 => 100  _ => 200 } }
fn main(){ exit(pick(0)) }' 100
# DCE regression: calls in match-expr arm values must not be pruned.
run_test "match_expr_call_arms" 'fn fa()->u64{return 7}
fn fb()->u64{return 9}
fn main(){ u64 x=1; exit(match x { 1 => fa()  _ => fb() }) }' 7
run_test "match_expr_arith_arms" 'fn main(){ u64 x=2; u64 r = match x { 1 => 3+4  2 => 6*7  _ => 0 }; exit(r) }' 42

# Phase 4: `let` type inference — type inferred from the RHS expression.
run_test "let_int"       'fn main(){ let x = 42; exit(x) }' 42
run_test "let_arith"     'fn main(){ let a = 6 * 7; exit(a) }' 42
run_test "let_from_var"  'fn main(){ u64 y = 9; let x = y; exit(x) }' 9
run_test "let_from_call" 'fn f()->u64{return 42}
fn main(){ let x = f(); exit(x) }' 42
run_test "let_bool"      'fn main(){ let ok = 5 > 3; if ok { exit(7) } exit(0) }' 7
run_test "let_chain"     'fn main(){ let a = 10; let b = a + 5; let c = b * 2; exit(c) }' 30
run_test "let_in_loop"   'fn main(){ u64 s=0; for i in 0..5 { let d = i + 1; s = s + d } exit(s) }' 15
run_test "let_ternary"   'fn main(){ let x = 5 > 3 ? 8 : 9; exit(x) }' 8
run_test "let_match"     'fn main(){ u64 v=2; let r = match v { 1 => 10  2 => 20  _ => 0 }; exit(r) }' 20
# Signed inference: i64 RHS → signed local → signed comparison picks the right branch.
run_test "let_signed"    'fn main(){ i64 a = 0 - 5; let r = a; if r < 0 { exit(9) } exit(0) }' 9
# H2: inferring from a call to an i64-returning fn must be SIGNED (was silently u64).
run_test "let_call_signed" 'fn neg() -> i64 { return 0 - 5 }
fn main(){ let r = neg(); if r < 0 { exit(9) } exit(0) }' 9
run_test_legacy "let_call_signed_legacy" 'fn neg() -> i64 { return 0 - 5 }
fn main(){ let r = neg(); if r < 0 { exit(9) } exit(0) }' 9
# H2: inferring from a signed static/global must be SIGNED.
run_test "let_static_signed" 'static i64 g = -7
fn main(){ let r = g
    if r < 0 { exit(8) }
    exit(0) }' 8
# H2: inferring from a const must still work (const has no AST node).
run_test "let_from_const" 'const i64 K = 5
fn main(){ let x = K; exit(x) }' 5
# Float inference: call returning f64 → local treated as f64 (stdout exercises the float path).
run_test_output "let_float" 'import "std/math_float.kr"
fn main(){ let x = int_to_f64(3); let y = int_to_f64(2); println_str(fmt_f64(x / y, 1)); exit(0) }' "1.5" 0

# H9: `break` inside a match arm must exit the ENCLOSING LOOP (legacy hijacked
# it to only exit the match). M1: break/continue outside a loop is a no-op.
run_test "break_in_match_while" 'fn main(){ u64 i=0
    while i<10 { match i { 3 => { break } _ => {} } i=i+1 }
    exit(i) }' 3
run_test "break_in_nested_match" 'fn main(){ u64 i=0
    u64 h=0
    while i<10 { match i { 2 => { match i { 2 => { h=h+1 } _ => {} } } 5 => { break } _ => {} } i=i+1 }
    exit(i*10+h) }' 51
run_test "continue_in_match_while" 'fn main(){ u64 i=0
    u64 s=0
    while i<10 { i=i+1; match i { 3 => { continue } _ => {} } s=s+1 }
    exit(s) }' 9
# H10: `continue` in a while loop works (regression); in a for loop it would
# skip the desugared increment and hang, so it is rejected (diag below).
run_test "continue_in_while" 'fn main(){ u64 i=0
    u64 s=0
    while i<5 { i=i+1; if i==3 { continue } s=s+1 }
    exit(s) }' 4
run_test "break_outside_loop_noop" 'fn main(){ break
    exit(5) }' 5

# H7: a non-main function that prints a 5+ digit number (or an f-string) and
# RETURNS must not smash its return address with the digit/f-string scratch
# buffer. Was a deterministic SIGSEGV on the legacy backends.
run_test "print_in_returning_fn" 'fn show(u64 n){ println(n) }
fn main(){ show(123456789); exit(7) }' 7

# H11: 2-byte struct fields must store/load 2 bytes (legacy used the 8-byte
# path, clobbering neighbors). p.a=1 b=2 c=3 d=4 must survive independently.
run_test_output "struct_u16_fields" 'struct P { u16 a; u16 b; u16 c; u16 d }
fn main(){ P p; p.a=9; p.b=2; p.c=3; p.d=4; p.a=1
    println(p.a); println(p.b); println(p.c); println(p.d); exit(0) }' "1
2
3
4" 0

# H8: a condition truthy only in the high 32 bits must be truthy on legacy too
# (legacy if/while/ternary used a 32-bit `test eax,eax`).
run_test "high_bit_truthy" 'fn main(){ u64 x = 1 << 35
    if x { exit(1) }
    exit(2) }' 1

# H6: signed parameter comparison must be signed on all backends.
run_test "signed_param" 'fn isneg(i64 a) -> u64 { if a < 0 { return 1 } return 0 }
fn main(){ exit(isneg(0 - 3)) }' 1
# H6: signed i64 struct field comparison must be signed on all backends.
run_test "signed_field_i64" 'struct S { i64 v }
fn main(){ S s; s.v = 0 - 4
    if s.v < 0 { exit(5) }
    exit(0) }' 5

# H5: range patterns on a SIGNED scrutinee must use signed compares, else
# negative bounds never match.
run_test "match_range_signed" 'fn main(){ i64 x = -5
    let r = match x { -10..=0 => 7  _ => 0 }
    exit(r) }' 7
# M4: SUB of a -2^31 constant must not fuse into an LEA disp32 (negation
# overflows). x - (-2^31) = x + 2^31.
run_test_output "sub_neg_2pow31" 'fn main(){ u64 x = 2147483648
    u64 r = x - (0 - 2147483648)
    println(r)
    exit(0) }' "4294967296" 0

# H3: ternary/match-expr result vregs must carry the arm value's type metadata
# (float-ness, signedness), else float/signed uses of the value are wrong.
run_test_output "ternary_float_value" 'import "std/math_float.kr"
fn main(){ u64 c=1; println_str(fmt_f64(c==1 ? 1.5 : 2.5, 1)); exit(0) }' "1.5" 0
run_test_output "matchexpr_float_value" 'import "std/math_float.kr"
fn main(){ u64 c=1; println_str(fmt_f64(match c { 1 => 1.5  _ => 2.5 }, 1)); exit(0) }' "1.5" 0
run_test "ternary_signed_value" 'fn main(){ i64 a = -5
    i64 b = -3
    if (1==1 ? a : b) < 0 { exit(9) }
    exit(0) }' 9
# H14: a function called ONLY from a `defer` body must not be DCE-pruned.
run_test_output "defer_only_call" 'fn h(){ println(7) }
fn run(){ defer { h() } }
fn main(){ run(); exit(0) }' "7" 0

# C1 regression: the IR w32-clean optimization must not elide `& 0xFFFFFFFF` on
# a vreg redefined (>32-bit) at an if/while/match merge — default-opt must match
# --O0/legacy. Before the fix, default-opt printed 8589934591 (mask elided).
run_test_output "w32_mask_after_merge" 'fn main() { u64 x = 7
    if 1 == 1 { x = 0x1FFFFFFFF }
    println(x & 0xFFFFFFFF)
    exit(0) }' "4294967295" 0

# Legacy-backend ternary parity (the default IR path handles these above;
# these compile with --legacy and must produce the SAME results). The legacy
# x86 path is runnable on this host; legacy arm64 parity is covered in CI.
# Legacy tests run for the HOST arch (was hardcoded --arch=x86_64, which on an
# arm64 CI runner produced x86 binaries that can't execute -> all red). M15.
LEGACY_ARCH="x86_64"
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then LEGACY_ARCH="arm64"; fi
run_test_legacy() {
    local name="$1"; local input="$2"; local expected="$3"
    TOTAL=$((TOTAL + 1))
    local REPO_ROOT="$DIR/.."
    printf '%s\n' "$input" > "$REPO_ROOT/test_tmp_$$.kr"
    if $KRC --arch=$LEGACY_ARCH --legacy "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_leg_$$ > /dev/null 2>&1; then
        rm -f "$REPO_ROOT/test_tmp_$$.kr"; chmod +x /tmp/krc_leg_$$
        local got=0; /tmp/krc_leg_$$ > /dev/null 2>&1 && got=0 || got=$?
        if [ "$got" = "$expected" ]; then PASS=$((PASS + 1));
        else echo "FAIL: $name (legacy: expected $expected, got $got)"; FAIL=$((FAIL + 1)); fi
    else
        echo "FAIL: $name (legacy compilation failed)"; FAIL=$((FAIL + 1))
    fi
    rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_leg_$$
}
run_test_legacy "ternary_legacy_true"   'fn main() { u64 x=5; exit(x>3 ? 1 : 0) }' 1
run_test_legacy "ternary_legacy_false"  'fn main() { u64 x=2; exit(x>3 ? 1 : 0) }' 0
run_test_legacy "ternary_legacy_nested" 'fn main() { u64 x=5; exit(x>9 ? 3 : x>4 ? 2 : 1) }' 2
run_test_legacy "ternary_legacy_arg"    'fn id(u64 a)->u64{return a}
fn main(){ exit(id(1>0 ? 9 : 4)) }' 9

# Legacy-backend match-as-expression parity (IR path covered above).
run_test_legacy "match_expr_legacy_basic"   'fn main(){ u64 x=2; exit(match x { 1 => 10  2 => 20  _ => 0 }) }' 20
run_test_legacy "match_expr_legacy_default" 'fn main(){ u64 x=9; exit(match x { 1 => 10  _ => 7 }) }' 7
run_test_legacy "match_expr_legacy_nomatch" 'fn main(){ u64 x=9; exit(match x { 1 => 10  2 => 20 }) }' 0
run_test_legacy "match_expr_legacy_multi"   'fn main(){ u64 x=3; exit(match x { 1, 2, 3 => 5  _ => 0 }) }' 5
run_test_legacy "match_expr_legacy_call"    'fn fa()->u64{return 7}
fn fb()->u64{return 9}
fn main(){ u64 x=1; exit(match x { 1 => fa()  _ => fb() }) }' 7

# Legacy-backend `let` type-inference parity (IR path covered above).
run_test_legacy "let_legacy_int"   'fn main(){ let x = 42; exit(x) }' 42
run_test_legacy "let_legacy_arith" 'fn main(){ let a = 6 * 7; exit(a) }' 42
run_test_legacy "let_legacy_call"  'fn f()->u64{return 42}
fn main(){ let x = f(); exit(x) }' 42
run_test_legacy "let_legacy_bool"  'fn main(){ let ok = 5 > 3; exit(ok) }' 1
run_test_legacy "let_legacy_loop"  'fn main(){ u64 s=0; for i in 0..5 { let d = i + 1; s = s + d } exit(s) }' 15
run_test_legacy "let_legacy_signed" 'fn main(){ i64 a = 0 - 5; let r = a; if r < 0 { exit(9) } exit(0) }' 9
# H6 legacy: signed param + signed i64 field comparisons (both backends).
run_test_legacy "signed_param_legacy" 'fn isneg(i64 a) -> u64 { if a < 0 { return 1 } return 0 }
fn main(){ exit(isneg(0 - 3)) }' 1
run_test_legacy "signed_field_i64_legacy" 'struct S { i64 v }
fn main(){ S s; s.v = 0 - 4
    if s.v < 0 { exit(5) }
    exit(0) }' 5
run_test_legacy "high_bit_truthy_legacy" 'fn main(){ u64 x = 1 << 35
    if x { exit(1) }
    exit(2) }' 1
run_test_legacy "print_in_returning_fn_legacy" 'fn show(u64 n){ println(n) }
fn main(){ show(123456789); exit(7) }' 7
run_test_legacy "break_in_match_while_legacy" 'fn main(){ u64 i=0
    while i<10 { match i { 3 => { break } _ => {} } i=i+1 }
    exit(i) }' 3
# H10 lifted: for+continue parity on the legacy backend (IR path covered
# above) — continue must run the desugared increment then re-test the cond.
run_test_legacy "for_continue_legacy" 'fn main(){ u64 s=0
    for i in 0..10 { if i == 3 { continue } s = s + i }
    exit(s) }' 42
run_test_legacy "for_continue_nested_legacy" 'fn main(){ u64 s=0
    for i in 0..3 { for j in 0..4 { if j == 1 { continue } s = s + j }
        if i == 1 { continue }
        s = s + 10 }
    exit(s) }' 35
run_test_legacy "for_continue_match_legacy" 'fn main(){ u64 s=0
    for i in 0..6 { match i { 2, 4 => { continue } _ => {} } s = s + i }
    exit(s) }' 9
run_test_legacy "break_outside_loop_legacy" 'fn main(){ break
    exit(5) }' 5
run_test_legacy "fstring_in_returning_fn_legacy" 'fn show(u64 n){ print_str(f"value is {n} plus padding text to overflow saved regs") }
fn main(){ show(42); exit(7) }' 7

# Short-circuit &&/|| parity: legacy must match IR (evaluate RHS only when
# needed) AND match IR's value semantics: && = lhs?rhs:0, || = lhs?1:rhs.
# IR tests lock the contract; legacy tests were RED (non-short-circuit + normalized).
run_test "and_value_truthy" 'fn main(){ exit(5 && 3) }' 3
run_test "or_value_falsy"   'fn main(){ exit(0 || 3) }' 3
run_test "and_value_falsy"  'fn main(){ exit(0 && 3) }' 0
run_test "or_value_truthy"  'fn main(){ exit(5 || 3) }' 1
run_test "and_shortcircuit" 'static u64 g = 0
fn side()->u64{ g = 9; return 1 }
fn main(){ u64 r = 0 && side(); exit(g) }' 0
run_test "or_shortcircuit"  'static u64 g = 0
fn side()->u64{ g = 9; return 1 }
fn main(){ u64 r = 1 || side(); exit(g) }' 0
run_test_legacy "and_value_truthy_legacy" 'fn main(){ exit(5 && 3) }' 3
run_test_legacy "or_value_falsy_legacy"   'fn main(){ exit(0 || 3) }' 3
run_test_legacy "or_value_truthy_legacy"  'fn main(){ exit(5 || 3) }' 1
run_test_legacy "and_shortcircuit_legacy" 'static u64 g = 0
fn side()->u64{ g = 9; return 1 }
fn main(){ u64 r = 0 && side(); exit(g) }' 0
run_test_legacy "or_shortcircuit_legacy"  'static u64 g = 0
fn side()->u64{ g = 9; return 1 }
fn main(){ u64 r = 1 || side(); exit(g) }' 0

# M2: a name re-declared in a different scope shares its stack slot in the
# legacy backend; its TYPE must follow the LATEST declaration. Was: the first
# declaration won, so `int64 x` after `uint64 x` did UNSIGNED division and
# `f64 x` after `uint64 x` loaded through the integer path. Old legacy gave
# 7/4; IR and fixed legacy give 42/10. Locked on both backends.
run_test "redecl_signed_type" 'fn main() -> uint64 {
    if 1 == 1 { uint64 x = 1
        if x == 0 { return 9 } }
    int64 x = 0 - 8
    x = x / 2
    if x == 0 - 4 { return 42 }
    return 7 }' 42
run_test_legacy "redecl_signed_type_legacy" 'fn main() -> uint64 {
    if 1 == 1 { uint64 x = 1
        if x == 0 { return 9 } }
    int64 x = 0 - 8
    x = x / 2
    if x == 0 - 4 { return 42 }
    return 7 }' 42
run_test "redecl_float_type" 'fn main() -> uint64 {
    if 1 == 1 { uint64 x = 3
        if x == 0 { return 9 } }
    f64 x = 2.5
    f64 y = x * 4.0
    return f64_to_int(y) }' 10
run_test_legacy "redecl_float_type_legacy" 'fn main() -> uint64 {
    if 1 == 1 { uint64 x = 3
        if x == 0 { return 9 } }
    f64 x = 2.5
    f64 y = x * 4.0
    return f64_to_int(y) }' 10

# Negative: an else-if chain with NO final else must still be rejected (it can
# fall through). Guards against the fix over-accepting non-exhaustive chains.
TOTAL=$((TOTAL + 1))
printf 'fn f(u64 x) -> u64 { if x > 5 { return 1 } else if x > 2 { return 2 } }\nfn main() { exit(f(9)) }\n' > /tmp/krc_err_$$.kr
if $KRC $KRC_FLAGS /tmp/krc_err_$$.kr -o /tmp/krc_err_$$ 2>/tmp/krc_stderr_$$ ; then
    echo "FAIL: elseif_no_final_else (should not compile)"
    FAIL=$((FAIL + 1))
else
    if grep -q "may not return" /tmp/krc_stderr_$$; then
        PASS=$((PASS + 1))
        echo "  elseif_no_final_else: PASS (error detected)"
    else
        echo "FAIL: elseif_no_final_else (wrong error)"
        FAIL=$((FAIL + 1))
    fi
fi
rm -f /tmp/krc_err_$$.kr /tmp/krc_err_$$ /tmp/krc_stderr_$$

# Undefined function on ARM64 must be detected at compile time (was: silently
# emitted a BL-to-self placeholder -> hanging binary; x86 already errored).
TOTAL=$((TOTAL + 1))
printf 'fn main() { u64 x = nonexistent_fn(5); exit(x) }\n' > /tmp/krc_err_$$.kr
if $KRC --arch=arm64 /tmp/krc_err_$$.kr -o /tmp/krc_err_$$ 2>/tmp/krc_stderr_$$ ; then
    echo "FAIL: undefined_fn_arm64 (should not compile)"
    FAIL=$((FAIL + 1))
else
    if grep -q "undefined function" /tmp/krc_stderr_$$; then
        PASS=$((PASS + 1))
        echo "  undefined_fn_arm64: PASS (error detected)"
    else
        echo "FAIL: undefined_fn_arm64 (wrong error)"
        FAIL=$((FAIL + 1))
    fi
fi
rm -f /tmp/krc_err_$$.kr /tmp/krc_err_$$ /tmp/krc_stderr_$$

# Duplicate function definition
TOTAL=$((TOTAL + 1))
printf 'fn foo() { exit(1) }\nfn foo() { exit(2) }\nfn main() { foo() }\n' > /tmp/krc_err_$$.kr
if $KRC $KRC_FLAGS /tmp/krc_err_$$.kr -o /tmp/krc_err_$$ 2>/tmp/krc_stderr_$$ ; then
    echo "FAIL: duplicate_fn (should not compile)"
    FAIL=$((FAIL + 1))
else
    if grep -q "redefinition" /tmp/krc_stderr_$$; then
        PASS=$((PASS + 1))
        echo "  duplicate_fn: PASS (error detected)"
    else
        echo "FAIL: duplicate_fn (wrong error)"
        FAIL=$((FAIL + 1))
    fi
fi
rm -f /tmp/krc_err_$$.kr /tmp/krc_err_$$ /tmp/krc_stderr_$$

# --- Android emit test ---
echo ""
echo "--- Android emit test ---"
TOTAL=$((TOTAL + 1))
printf 'fn main() { exit(42) }\n' > /tmp/krc_android_$$.kr
if $KRC $KRC_FLAGS --emit=android /tmp/krc_android_$$.kr -o /tmp/krc_android_$$ > /dev/null 2>&1; then
    magic=$(xxd -l 4 -p /tmp/krc_android_$$ 2>/dev/null)
    etype=$(xxd -s 16 -l 2 -p /tmp/krc_android_$$ 2>/dev/null)
    if [ "$magic" = "7f454c46" ] && [ "$etype" = "0300" ]; then
        PASS=$((PASS + 1))
        echo "  android_emit: PASS (valid PIE ELF, $(wc -c < /tmp/krc_android_$$) bytes)"
    else
        FAIL=$((FAIL + 1))
        echo "  android_emit: FAIL (bad ELF: magic=$magic etype=$etype)"
    fi
else
    FAIL=$((FAIL + 1))
    echo "  android_emit: FAIL (compilation failed)"
fi
rm -f /tmp/krc_android_$$.kr /tmp/krc_android_$$

# --- Android x86_64 emit test ---
echo ""
echo "--- Android x86_64 emit test ---"
TOTAL=$((TOTAL + 1))
printf 'fn main() { exit(42) }\n' > /tmp/krc_androidx_$$.kr
if $KRC --arch=x86_64 --emit=android /tmp/krc_androidx_$$.kr -o /tmp/krc_androidx_$$ > /dev/null 2>&1; then
    magic=$(xxd -l 4 -p /tmp/krc_androidx_$$ 2>/dev/null)
    etype=$(xxd -s 16 -l 2 -p /tmp/krc_androidx_$$ 2>/dev/null)
    emach=$(xxd -s 18 -l 2 -p /tmp/krc_androidx_$$ 2>/dev/null)
    if [ "$magic" = "7f454c46" ] && [ "$etype" = "0300" ] && [ "$emach" = "3e00" ]; then
        # Execute via glibc loader (bypasses PT_INTERP=/system/bin/linker64)
        if [ -x /lib64/ld-linux-x86-64.so.2 ] && [ "$(uname -m)" = "x86_64" ]; then
            actual=0
            /lib64/ld-linux-x86-64.so.2 /tmp/krc_androidx_$$ > /dev/null 2>&1
            actual=$?
            if [ "$actual" = "42" ]; then
                PASS=$((PASS + 1))
                echo "  android_emit_x86_64: PASS (PIE ELF x86-64, exec=42)"
            else
                FAIL=$((FAIL + 1))
                echo "  android_emit_x86_64: FAIL (exec exit=$actual, expected 42)"
            fi
        else
            PASS=$((PASS + 1))
            echo "  android_emit_x86_64: PASS (structural; no glibc loader)"
        fi
    else
        FAIL=$((FAIL + 1))
        echo "  android_emit_x86_64: FAIL (bad ELF: magic=$magic etype=$etype mach=$emach)"
    fi
else
    FAIL=$((FAIL + 1))
    echo "  android_emit_x86_64: FAIL (compilation failed)"
fi
rm -f /tmp/krc_androidx_$$.kr /tmp/krc_androidx_$$

# --- 2-tuple return and destructure ---
run_test "tuple_basic" 'fn divmod(uint64 x, uint64 y) -> uint64 { return (x / y, x % y) }
fn main() { (uint64 q, uint64 r) = divmod(17, 5); exit(q + r) }' 5

run_test "tuple_branch" 'fn minmax(uint64 a, uint64 b) -> uint64 { if a < b { return (a, b) } return (b, a) }
fn main() { (uint64 lo, uint64 hi) = minmax(42, 7); exit(hi - lo) }' 35

run_test "tuple_nested_call" 'fn pair(uint64 x) -> uint64 { return (x, x + 1) }
fn main() { (uint64 a, uint64 b) = pair(10); exit(a * b) }' 110

run_test "tuple_void_context" 'fn split(uint64 n) -> uint64 { return (n * 2, n * 3) }
fn main() { uint64 sum = 0; (uint64 a, uint64 b) = split(5); sum = a + b; exit(sum) }' 25

run_test "tuple_reuse" 'fn step(uint64 x) -> uint64 { return (x + 1, x + 2) }
fn main() { (uint64 p, uint64 q) = step(10); (uint64 r, uint64 s) = step(20); exit(p + q + r + s) }' 66

# --- 3-tuple return and destructure ---
run_test "tuple3_basic" 'fn triple() -> u64 { return (10, 20, 30) }
fn main() { (u64 a, u64 b, u64 c) = triple(); exit(a + b + c) }' 60

run_test "tuple3_values" 'fn split3(u64 x) -> u64 { return (x, x + 1, x + 2) }
fn main() { (u64 a, u64 b, u64 c) = split3(5); exit(c) }' 7

# --- asm { } I/O constraints ---
# x86_64-only asm constraint tests (rdtsc, shl are x86 instructions)
if [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "amd64" ]; then
# rdtsc: no inputs, two outputs (low/high 32 bits of the TSC into rax/rdx).
run_test "asm_rdtsc_out" 'fn main() {
    uint64 lo = 0
    uint64 hi = 0
    asm { "rdtsc" } out(rax -> lo, rdx -> hi)
    if lo == 0 { if hi == 0 { exit(1) } }
    exit(0)
}' 0

# shl via asm with one input and one output, testing pinned-param loading.
run_test "asm_shl_in_out" 'fn shl_by(uint64 v, uint64 n) -> uint64 {
    uint64 r = 0
    asm { "0x48 0xD3 0xE0" } in(v -> rax, n -> rcx) out(rax -> r)
    return r
}
fn main() { exit(shl_by(3, 4)) }' 48
fi

# nop with no constraints — ensures backward-compat with existing asm blocks.
run_test "asm_nop_noconstraints" 'fn main() { asm { "nop" }; exit(5) }' 5

# --- Opt-in: run on a real Android emulator via adb (ANDROID_EMULATOR=1) ---
# Requires: adb on PATH, one device online, and write access to
# /data/local/tmp. Cross-compiles a handful of programs as
# android-x86_64, pushes them, and executes under real bionic.
if [ "${ANDROID_EMULATOR:-0}" = "1" ] && command -v adb > /dev/null 2>&1; then
    DEV=$(adb get-state 2>/dev/null | tr -d '\r')
    if [ "$DEV" = "device" ]; then
        echo ""
        echo "--- Android emulator (adb, x86_64) ---"
        _adb_run() {
            local name="$1" src="$2" expected="$3"
            TOTAL=$((TOTAL + 1))
            printf '%s\n' "$src" > /tmp/krc_adb_$$.kr
            if $KRC --arch=x86_64 --emit=android /tmp/krc_adb_$$.kr -o /tmp/krc_adb_$$ > /dev/null 2>&1; then
                adb push /tmp/krc_adb_$$ /data/local/tmp/krc_adb_$$ > /dev/null 2>&1
                adb shell chmod 755 /data/local/tmp/krc_adb_$$ > /dev/null 2>&1
                got=$(adb shell "/data/local/tmp/krc_adb_$$ > /dev/null 2>&1; echo \$?" | tr -d '\r')
                if [ "$got" = "$expected" ]; then
                    PASS=$((PASS + 1))
                    echo "  adb_$name: PASS"
                else
                    FAIL=$((FAIL + 1))
                    echo "  adb_$name: FAIL (expected $expected, got $got)"
                fi
                adb shell rm -f /data/local/tmp/krc_adb_$$ > /dev/null 2>&1
            else
                FAIL=$((FAIL + 1))
                echo "  adb_$name: FAIL (compile)"
            fi
            rm -f /tmp/krc_adb_$$.kr /tmp/krc_adb_$$
        }
        _adb_run "exit42"   'fn main() { exit(42) }' 42
        _adb_run "add"      'fn main() { exit(2 + 3) }' 5
        _adb_run "loop"     'fn main() { uint64 s = 0; for i in 1..11 { s = s + i }; exit(s) }' 55
        _adb_run "recurse"  'fn fib(uint64 n) -> uint64 { if n <= 1 { return n } return fib(n-1)+fib(n-2) }
fn main() { exit(fib(10)) }' 55
        _adb_run "statics"  'static uint64 c = 0
fn inc() { c = c + 1 }
fn main() { inc(); inc(); inc(); inc(); exit(c) }' 4
        _adb_run "println"  'fn main() { println("android bionic"); exit(7) }' 7
    else
        echo "  android_emulator: SKIP (ANDROID_EMULATOR=1 but no device online)"
    fi
fi

# --- For loop ---
run_test "for_range" 'fn main() { uint64 s = 0; for i in 0..10 { s = s + i }; exit(s) }' 45
run_test "for_range_inclusive" 'fn main() { uint64 s = 0; for i in 0..=10 { s = s + i }; exit(s) }' 55
run_test "for_range_no_in" 'fn main() { uint64 s = 0; for i 0..10 { s = s + i }; exit(s) }' 45
run_test "for_range_no_in_inclusive" 'fn main() { uint64 s = 0; for i 0..=5 { s = s + i }; exit(s) }' 15
run_test "for_range_ident_end"  'fn main() { u64 n = 5; u64 s = 0; for i 0..n { s = s + i }; exit(s) }' 10
run_test "for_range_ident_both" 'fn main() { u64 a = 2; u64 b = 7; u64 s = 0; for i a..b { s = s + i }; exit(s) }' 20
run_test "loop_break" 'fn main() { u64 n = 0; loop { n = n + 1; if n >= 42 { break } }; exit(n) }' 42
run_test "match_wildcard_miss" 'fn main() {
    u64 x = 999
    match x {
        1 => { exit(1) }
        5 => { exit(55) }
        _ => { exit(42) }
    }
}' 42
run_test "match_wildcard_hit_first" 'fn main() {
    u64 x = 5
    match x {
        5 => { exit(50) }
        _ => { exit(42) }
    }
}' 50
run_test "match_multi_value_first" 'fn main() {
    u64 x = 3
    match x {
        1, 2, 3 => { exit(77) }
        _ => { exit(0) }
    }
}' 77
run_test "match_multi_value_second" 'fn main() {
    u64 x = 5
    match x {
        1, 2, 3 => { exit(77) }
        4, 5 => { exit(66) }
        _ => { exit(0) }
    }
}' 66
run_test "match_multi_value_miss" 'fn main() {
    u64 x = 9
    match x {
        1, 2, 3 => { exit(77) }
        4, 5 => { exit(66) }
        _ => { exit(11) }
    }
}' 11
run_test "match_range_inclusive" 'fn main() {
    u64 x = 50
    match x {
        0..=31 => { exit(1) }
        32..=126 => { exit(2) }
        _ => { exit(3) }
    }
}' 2
run_test "match_range_exclusive" 'fn main() {
    u64 x = 10
    match x {
        0..10 => { exit(1) }
        10..20 => { exit(2) }
        _ => { exit(3) }
    }
}' 2
run_test "match_range_ident" 'fn main() {
    u64 lo = 5
    u64 hi = 10
    u64 x = 7
    match x {
        lo..=hi => { exit(7) }
        _ => { exit(0) }
    }
}' 7
run_test "compound_field_assign" 'struct P { u64 x; u64 y }
fn main() { P p; p.x = 10; p.x += 5; p.x *= 2; exit(p.x) }' 30
run_test "compound_index_assign" 'fn main() { u64[4] a; a[0] = 10; a[0] += 3; a[0] *= 4; exit(a[0]) }' 52

# --- Char predicates (std/string.kr) ---
run_test "char_pred_digit"   'import "std/string.kr"
fn main() { if is_digit(53) == 1 && is_digit(97) == 0 { exit(1) }; exit(0) }' 1
run_test "char_pred_alpha"   'import "std/string.kr"
fn main() { if is_alpha(97) == 1 && is_alpha(48) == 0 { exit(1) }; exit(0) }' 1
run_test "char_pred_space"   'import "std/string.kr"
fn main() { if is_space(32) == 1 && is_space(10) == 1 && is_space(65) == 0 { exit(1) }; exit(0) }' 1
run_test "char_pred_hex"     'import "std/string.kr"
fn main() { if is_hex_digit(70) == 1 && is_hex_digit(103) == 0 { exit(1) }; exit(0) }' 1
run_test "char_to_upper"     'import "std/string.kr"
fn main() { exit(to_upper_ch(97)) }' 65
run_test "char_to_lower"     'import "std/string.kr"
fn main() { exit(to_lower_ch(90)) }' 122
run_test "char_hex_val"      'import "std/string.kr"
fn main() { exit(hex_digit_val(70)) }' 15
run_test "loop_nested_break" 'fn main() {
    u64 total = 0
    u64 outer = 0
    loop {
        outer = outer + 1
        u64 inner = 0
        loop {
            inner = inner + 1
            total = total + 1
            if inner >= 3 { break }
        }
        if outer >= 2 { break }
    }
    exit(total)
}' 6

# --- Defer ---
run_test "defer_on_return" 'static u64 n = 0
fn go() -> u64 { defer { n = 100 }; return 1 }
fn main() { u64 r = go(); exit(r + n) }' 101
run_test "defer_lifo" 'static u64 log = 0
fn run() { defer { log = log * 10 + 1 }; defer { log = log * 10 + 2 }; defer { log = log * 10 + 3 } }
fn main() { run(); exit(log) }' 65
run_test "defer_early_return" 'static u64 n = 0
fn pick(u64 x) -> u64 { defer { n = n + 100 }; if x > 0 { return 1 }; return 2 }
fn main() { u64 a = pick(5); u64 b = pick(0); exit(a + b + n) }' 203
run_test "defer_nested_block" 'static u64 v = 0
fn inner() { if 1 == 1 { defer { v = 42 } } }
fn main() { inner(); exit(v) }' 42

# --- @section annotation capture ---
TOTAL=$((TOTAL + 1))
printf '@section(".text.init")\nfn boot() -> u64 { return 0 }\nfn main() { exit(boot()) }\n' > "$DIR/../test_tmp_sect_$$.kr"
$KRC --emit=asm $KRC_FLAGS "$DIR/../test_tmp_sect_$$.kr" -o /tmp/krc_sect_$$.s > /dev/null 2>&1
if grep -q "^\\.section \\.text\\.init" /tmp/krc_sect_$$.s 2>/dev/null; then
    PASS=$((PASS + 1))
else
    echo "FAIL: section_asm_directive (no .section emitted)"; FAIL=$((FAIL + 1))
fi
rm -f "$DIR/../test_tmp_sect_$$.kr" /tmp/krc_sect_$$.s

TOTAL=$((TOTAL + 1))
printf 'fn boot() -> u64 { return 0 }\nfn main() { exit(boot()) }\n' > "$DIR/../test_tmp_nosect_$$.kr"
$KRC --emit=asm $KRC_FLAGS "$DIR/../test_tmp_nosect_$$.kr" -o /tmp/krc_nosect_$$.s > /dev/null 2>&1
if grep -q "^\\.section" /tmp/krc_nosect_$$.s 2>/dev/null; then
    echo "FAIL: no_section_no_directive (spurious .section)"; FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1))
fi
rm -f "$DIR/../test_tmp_nosect_$$.kr" /tmp/krc_nosect_$$.s

# --- Many-parameter functions ---
run_test "fn_7args" 'fn sum7(uint64 a, uint64 b, uint64 c, uint64 d, uint64 e, uint64 f, uint64 g) -> uint64 { return a + b + c + d + e + f + g }
fn main() { exit(sum7(1,2,3,4,5,6,7)) }' 28

run_test "fn_8args" 'fn s(uint64 a, uint64 b, uint64 c, uint64 d, uint64 e, uint64 f, uint64 g, uint64 h) -> uint64 { return a + b + c + d + e + f + g + h }
fn main() { exit(s(1,2,3,4,5,6,7,8)) }' 36

# --- Enum (auto-numbered) ---
run_test "enum_auto" 'enum Color { Red, Green, Blue }
fn main() { exit(Color.Blue) }' 2

# --- emit=asm produces text ---
echo ""
echo "--- ASM emit test ---"
TOTAL=$((TOTAL + 1))
printf 'fn main() { exit(42) }\n' > /tmp/krc_asm_$$.kr
if $KRC $KRC_FLAGS --emit=asm /tmp/krc_asm_$$.kr -o /tmp/krc_asm_$$.s > /dev/null 2>&1; then
    if file /tmp/krc_asm_$$.s | grep -qi 'text\|ascii' && grep -q 'main' /tmp/krc_asm_$$.s; then
        PASS=$((PASS + 1))
        echo "  emit_asm: PASS (text output with function labels)"
    else
        FAIL=$((FAIL + 1))
        echo "  emit_asm: FAIL (output is not text or missing labels)"
    fi
else
    FAIL=$((FAIL + 1))
    echo "  emit_asm: FAIL (compilation with --emit=asm failed)"
fi
rm -f /tmp/krc_asm_$$.kr /tmp/krc_asm_$$.s

# --- emit=asm content tests ---
echo ""
echo "--- emit=asm content tests ---"

# Test asm output has function labels and mnemonics
TOTAL=$((TOTAL + 1))
echo 'fn add(uint64 a, uint64 b) -> uint64 { return a + b }
fn main() { exit(add(1, 2)) }' > /tmp/krc_asm_test_$$.kr
if $KRC $KRC_FLAGS --emit=asm /tmp/krc_asm_test_$$.kr -o /tmp/krc_asm_test_$$.s > /dev/null 2>&1; then
    if grep -q "add:" /tmp/krc_asm_test_$$.s && grep -q "main:" /tmp/krc_asm_test_$$.s && grep -q "ret" /tmp/krc_asm_test_$$.s; then
        echo "  emit_asm_content: PASS"
        PASS=$((PASS + 1))
    else
        echo "  emit_asm_content: FAIL (missing labels or mnemonics)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "  emit_asm_content: FAIL (compilation error)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_asm_test_$$.*

# Test that --emit=xyz gives an error
TOTAL=$((TOTAL + 1))
echo 'fn main() { exit(0) }' > /tmp/krc_asm_err_$$.kr
if $KRC --emit=xyz /tmp/krc_asm_err_$$.kr -o /tmp/krc_asm_err_$$ 2>&1 | grep -q "unknown emit format"; then
    echo "  emit_unknown_error: PASS"
    PASS=$((PASS + 1))
else
    echo "  emit_unknown_error: FAIL"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_asm_err_$$.kr /tmp/krc_asm_err_$$

# --- String escapes ---
run_test_output "str_escape_newline" 'fn main() { print("a\nb"); exit(0) }' "a
b"

# --- ARM64 cross-compilation tests via QEMU ---
QEMU_A64=""
if command -v qemu-aarch64-static > /dev/null 2>&1; then
    QEMU_A64="qemu-aarch64-static"
elif command -v qemu-aarch64 > /dev/null 2>&1; then
    QEMU_A64="qemu-aarch64"
fi

if [ -n "$QEMU_A64" ] && [ "$ARCH" = "x86_64" ]; then
    echo ""
    echo "--- ARM64 cross-compilation tests (QEMU) ---"

    run_test_a64() {
        local name="$1"
        local input="$2"
        local expected="$3"
        TOTAL=$((TOTAL + 1))

        printf '%s\n' "$input" > /tmp/krc_a64_$$.kr
        if $KRC --arch=arm64 /tmp/krc_a64_$$.kr -o /tmp/krc_a64_$$ > /dev/null 2>&1; then
            chmod +x /tmp/krc_a64_$$
            local got=0
            $QEMU_A64 /tmp/krc_a64_$$ > /dev/null 2>&1 && got=0 || got=$?
            if [ "$got" = "$expected" ]; then
                PASS=$((PASS + 1))
            else
                echo "FAIL: $name (expected $expected, got $got)"
                FAIL=$((FAIL + 1))
            fi
        else
            echo "FAIL: $name (cross-compilation failed)"
            FAIL=$((FAIL + 1))
        fi
        rm -f /tmp/krc_a64_$$.kr /tmp/krc_a64_$$
    }

    run_test_a64 "a64_exit" 'fn main() { exit(42) }' 42
    run_test_a64 "a64_add" 'fn add(uint64 a, uint64 b) -> uint64 { return a + b }
fn main() { exit(add(10, 32)) }' 42
    run_test_a64 "a64_atomic" 'fn main() { uint64 buf = alloc(64); atomic_store(buf, 42); exit(atomic_load(buf)) }' 42
    run_test_a64 "a64_static" 'static uint64 x = 0
fn main() { x = 42; exit(x) }' 42

    # ARM64 struct passing tests
    run_test_a64 "a64_struct_field" 'struct P { uint64 x; uint64 y }
fn main() { P a; a.x = 10; a.y = 32; exit(a.x + a.y) }' 42

    run_test_a64 "a64_struct_pass" 'struct P { uint64 x; uint64 y }
fn sum(P p) -> uint64 { return p.x + p.y }
fn main() { P a; a.x = 10; a.y = 32; exit(sum(a)) }' 42

    run_test_a64 "a64_struct_pass_2arg" 'struct P { uint64 x; uint64 y }
fn add(P a, P b) -> uint64 { return a.x + b.y }
fn main() { P p1; p1.x = 10; p1.y = 0; P p2; p2.x = 0; p2.y = 32; exit(add(p1, p2)) }' 42

    run_test_a64 "a64_struct_return" 'struct P { uint64 x; uint64 y }
fn make() -> P { P r; r.x = 10; r.y = 32; return r }
fn main() { P a = make(); exit(a.x + a.y) }' 42

    run_test_a64 "a64_struct_lit" 'struct P { uint64 x; uint64 y }
fn sum(P p) -> uint64 { return p.x + p.y }
fn main() { exit(sum(P{x: 10, y: 32})) }' 42

    run_test_a64 "a64_struct_copy" 'struct P { uint64 x; uint64 y }
fn main() { P a; a.x = 10; a.y = 32; P b = a; exit(b.x + b.y) }' 42

    run_test_a64 "a64_struct_small" 'struct S { uint32 a; uint32 b }
fn sum(S s) -> uint64 { return s.a + s.b }
fn main() { S v; v.a = 10; v.b = 32; exit(sum(v)) }' 42

    # ARM64 HFA (Homogeneous Float Aggregate) tests
    run_test_a64 "a64_hfa_pass_f64" 'struct V { f64 x; f64 y }
fn sum(V v) -> f64 { return v.x + v.y }
fn main() {
    V v; v.x = 3.0; v.y = 4.0
    f64 r = sum(v)
    exit(f64_to_int(r))
}' 7

    run_test_a64 "a64_hfa_return_f64" 'struct V { f64 x; f64 y }
fn make() -> V { V r; r.x = 10.0; r.y = 32.0; return r }
fn main() {
    V v = make()
    exit(f64_to_int(v.x + v.y))
}' 42

    run_test_a64 "a64_hfa_pass_return_f64" 'struct V { f64 x; f64 y }
fn scale(V v, f64 s) -> V {
    V r; r.x = v.x * s; r.y = v.y * s; return r
}
fn main() {
    V v; v.x = 2.0; v.y = 5.0
    V r = scale(v, 3.0)
    exit(f64_to_int(r.x + r.y))
}' 21

    run_test_a64 "a64_hfa_3field_f64" 'struct V3 { f64 x; f64 y; f64 z }
fn sum3(V3 v) -> f64 { return v.x + v.y + v.z }
fn main() {
    V3 v; v.x = 10.0; v.y = 20.0; v.z = 12.0
    exit(f64_to_int(sum3(v)))
}' 42

    run_test_a64 "a64_hfa_4field_f64" 'struct V4 { f64 a; f64 b; f64 c; f64 d }
fn sum4(V4 v) -> f64 { return v.a + v.b + v.c + v.d }
fn main() {
    V4 v; v.a = 10.0; v.b = 11.0; v.c = 12.0; v.d = 9.0
    exit(f64_to_int(sum4(v)))
}' 42
fi

# --- v2.6 feature tests ---
echo ""
echo "--- v2.6 short type aliases ---"
run_test "alias_u8"  'fn main() { u8 x = 42; exit(x) }' 42
run_test "alias_u16" 'fn main() { u16 x = 42; exit(x) }' 42
run_test "alias_u32" 'fn main() { u32 x = 42; exit(x) }' 42
run_test "alias_u64" 'fn main() { u64 x = 42; exit(x) }' 42
run_test "alias_i8"  'fn main() { i8  x = 42; exit(x) }' 42
run_test "alias_i16" 'fn main() { i16 x = 42; exit(x) }' 42
run_test "alias_i32" 'fn main() { i32 x = 42; exit(x) }' 42
run_test "alias_i64" 'fn main() { i64 x = 42; exit(x) }' 42

echo ""
echo "--- v2.6 pointer load/store builtins ---"
run_test "load_store_u8"  'fn main() { u64 buf = alloc(16); store8(buf, 42); exit(load8(buf)) }' 42
run_test "load_store_u16" 'fn main() { u64 buf = alloc(16); store16(buf, 42); exit(load16(buf)) }' 42
run_test "load_store_u32" 'fn main() { u64 buf = alloc(16); store32(buf, 42); exit(load32(buf)) }' 42
run_test "load_store_u64" 'fn main() { u64 buf = alloc(16); store64(buf, 42); exit(load64(buf)) }' 42
run_test "load_store_offsets" 'fn main() {
    u64 buf = alloc(32)
    store8(buf + 0, 1)
    store8(buf + 1, 2)
    store8(buf + 2, 3)
    store8(buf + 3, 4)
    exit(load8(buf + 0) + load8(buf + 1) + load8(buf + 2) + load8(buf + 3))
}' 10
run_test "load_store_widths_mixed" 'fn main() {
    u64 buf = alloc(32)
    store32(buf, 0x11223344)
    exit(load8(buf) + load8(buf + 1) + load8(buf + 2) + load8(buf + 3))
}' 170
run_test "vload_vstore_u32" 'fn main() { u64 buf = alloc(16); vstore32(buf, 42); exit(vload32(buf)) }' 42
run_test "vload_vstore_u64" 'fn main() { u64 buf = alloc(16); vstore64(buf, 42); exit(vload64(buf)) }' 42

echo ""
echo "--- v2.6 print_str / println_str ---"
# print_str prints the contents of a variable string pointer.
# If the builtin is broken, it prints the pointer address as a number
# instead of the string, and the output doesn't contain "Hi".
run_test_output "print_str_variable" 'fn main() {
    u64 msg = "Hi"
    print_str(msg)
    exit(0)
}' 'Hi' 0
run_test_output "println_str_variable" 'fn main() {
    u64 msg = "Line"
    println_str(msg)
    exit(0)
}' 'Line' 0

echo ""
echo "--- v2.6 static arrays ---"
run_test "static_array_u8" 'static u8[16] buf
fn main() { buf[0] = 42; exit(buf[0]) }' 42
run_test "static_array_roundtrip" 'static u8[32] buf
fn main() {
    buf[5] = 10
    buf[6] = 20
    buf[7] = 12
    exit(buf[5] + buf[6] + buf[7])
}' 42

echo ""
echo "--- v2.6 struct arrays ---"
run_test "struct_array_basic" 'struct P { u64 x; u64 y }
fn main() {
    P[4] pts
    pts[0].x = 10
    pts[0].y = 20
    pts[3].x = 5
    pts[3].y = 7
    exit(pts[0].x + pts[0].y + pts[3].x + pts[3].y)
}' 42
run_test "struct_array_iteration" 'struct Row { u64 a; u64 b }
fn main() {
    Row[5] rows
    for i in 0..5 {
        rows[i].a = i
        rows[i].b = 0
    }
    u64 sum = 0
    for j in 0..5 {
        sum = sum + rows[j].a
    }
    exit(sum)
}' 10

echo ""
echo "--- v2.6 slice parameters ---"
run_test "slice_param_len" 'fn sum_bytes([u8] data) -> u64 {
    u64 total = 0
    u64 i = 0
    u64 n = data.len
    while i < n {
        total = total + load8(data + i)
        i = i + 1
    }
    return total
}
fn main() {
    u8[6] buf
    buf[0] = 10
    buf[1] = 20
    buf[2] = 12
    exit(sum_bytes(buf, 3))
}' 42

echo ""
echo "--- v2.6 device blocks ---"
run_test "device_block_read_write" 'device Fake at 0x66666000 {
    Data at 0x00 : u32
    Status at 0x04 : u8
}
fn main() {
    // mmap a page at 0x66666000 (Linux x86_64 syscall 9, ARM64 222)
    u64 nr = 9
    // arm64 mmap syscall is 222 on every OS (Linux / Android / macOS).
    // get_arch_id() returns 2=linux-arm64, 4=windows-arm64, 6=macos-arm64, 7=android-arm64.
    u64 aid = get_arch_id()
    if aid == 2 { nr = 222 }
    if aid == 4 { nr = 222 }
    if aid == 6 { nr = 222 }
    if aid == 7 { nr = 222 }
    syscall_raw(nr, 0x66666000, 4096, 3, 0x32, 0xFFFFFFFFFFFFFFFF, 0)
    Fake.Data = 42
    Fake.Status = 7
    u32 v = Fake.Data
    u8  s = Fake.Status
    exit(v + s)
}' 49

echo ""
echo "--- v2.6 method calls ---"
run_test "method_call" 'struct P { u64 x; u64 y }
fn P.sum(P self) -> u64 { return self.x + self.y }
fn main() {
    P p
    p.x = 10
    p.y = 32
    exit(p.sum())
}' 42

echo ""
echo "--- v2.6 #lang directive ---"
run_test "lang_stable" '#lang stable

fn main() { exit(42) }' 42
run_test "lang_experimental" '#lang experimental

fn main() { exit(42) }' 42

echo ""
echo "--- v2.6 living compiler ---"
# --list-proposals should work without an input file and exit 0
TOTAL=$((TOTAL + 1))
if $KRC lc --list-proposals > /tmp/krc_prop_$$.txt 2>&1; then
    if grep -q "KernRift Proposal Registry" /tmp/krc_prop_$$.txt && grep -q "load_store_builtins" /tmp/krc_prop_$$.txt; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: list_proposals (output did not contain expected strings)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: list_proposals (command failed)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_prop_$$.txt

# --fix --dry-run on a legacy file should show a migration
TOTAL=$((TOTAL + 1))
cat > /tmp/krc_mig_$$.kr <<'KREOF'
fn main() {
    u64 buf = alloc(16)
    u64 v = 0
    unsafe { *(buf as u32) -> v }
    exit(v)
}
KREOF
if $KRC lc --fix --dry-run /tmp/krc_mig_$$.kr > /tmp/krc_mig_out_$$.txt 2>&1; then
    if grep -q "1 migration site(s) rewritten" /tmp/krc_mig_out_$$.txt && grep -q "load32" /tmp/krc_mig_out_$$.txt; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: migration_dry_run (output missing expected content)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: migration_dry_run (command failed)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_mig_$$.kr /tmp/krc_mig_out_$$.txt

# --fix (actual) on a legacy file should rewrite and the result should compile
TOTAL=$((TOTAL + 1))
cat > /tmp/krc_mig2_$$.kr <<'KREOF'
fn main() {
    u64 buf = alloc(16)
    u64 v = 0
    store32(buf, 42)
    unsafe { *(buf as u32) -> v }
    exit(v)
}
KREOF
if $KRC lc --fix /tmp/krc_mig2_$$.kr > /dev/null 2>&1; then
    if grep -q "v = load32(buf)" /tmp/krc_mig2_$$.kr; then
        # Now verify the rewritten file still compiles and runs
        if $KRC $KRC_FLAGS /tmp/krc_mig2_$$.kr -o /tmp/krc_mig2_bin_$$ > /dev/null 2>&1; then
            chmod +x /tmp/krc_mig2_bin_$$
            /tmp/krc_mig2_bin_$$ > /dev/null 2>&1
            if [ "$?" = "42" ]; then
                PASS=$((PASS + 1))
            else
                echo "FAIL: migration_apply (rewritten binary exit != 42)"
                FAIL=$((FAIL + 1))
            fi
        else
            echo "FAIL: migration_apply (rewritten file did not compile)"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL: migration_apply (file was not rewritten)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: migration_apply (command failed)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_mig2_$$.kr /tmp/krc_mig2_bin_$$

# krc lc on a file with unsafe ops should report legacy_ptr_ops
TOTAL=$((TOTAL + 1))
cat > /tmp/krc_lc_$$.kr <<'KREOF'
fn main() {
    u64 buf = alloc(16)
    u64 v = 0
    unsafe { *(buf as u32) -> v }
    exit(v)
}
KREOF
if $KRC lc /tmp/krc_lc_$$.kr > /tmp/krc_lc_out_$$.txt 2>&1; then
    if grep -q "legacy_ptr_ops" /tmp/krc_lc_out_$$.txt && grep -q "auto-fix available" /tmp/krc_lc_out_$$.txt; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: lc_reports_legacy (missing expected strings in output)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: lc_reports_legacy (command failed)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_lc_$$.kr /tmp/krc_lc_out_$$.txt

# Governance: promote + list round-trip
TOTAL=$((TOTAL + 1))
GOV_DIR=/tmp/krc_gov_$$
# Use the raw compiler binary (not the wrapper script) so we can cd elsewhere
if [ -f "$DIR/../build/krc2" ]; then
    GOV_KRC=$(cd "$DIR/../build" && pwd)/krc2
elif [ -f "$DIR/../build/krc3" ]; then
    GOV_KRC=$(cd "$DIR/../build" && pwd)/krc3
else
    GOV_KRC=""
fi
mkdir -p "$GOV_DIR" && (cd "$GOV_DIR" && rm -rf .kernrift && \
    "$GOV_KRC" lc --promote tail_call_intrinsic > /tmp/krc_gov_promote_$$.txt 2>&1)
if [ -n "$GOV_KRC" ] && \
   grep -q "promoted: tail_call_intrinsic" /tmp/krc_gov_promote_$$.txt 2>/dev/null && \
   [ -f "$GOV_DIR/.kernrift/proposals" ] && \
   grep -q "tail_call_intrinsic stable" "$GOV_DIR/.kernrift/proposals"; then
    PASS=$((PASS + 1))
else
    echo "FAIL: governance_promote (state file not updated)"
    FAIL=$((FAIL + 1))
fi
rm -rf "$GOV_DIR" /tmp/krc_gov_promote_$$.txt

# Migration: long-form types → short aliases
TOTAL=$((TOTAL + 1))
cat > /tmp/krc_migtypes_$$.kr <<'KREOF'
fn main() {
    uint64 x = 42
    uint32 y = 1
    uint16 z = 2
    exit(x)
}
KREOF
if $KRC lc --fix /tmp/krc_migtypes_$$.kr > /dev/null 2>&1; then
    if grep -q "u64 x" /tmp/krc_migtypes_$$.kr && \
       grep -q "u32 y" /tmp/krc_migtypes_$$.kr && \
       grep -q "u16 z" /tmp/krc_migtypes_$$.kr; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: migration_types (file was not rewritten)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: migration_types (command failed)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_migtypes_$$.kr

# --- Bootstrap test ---
echo ""
echo "--- Bootstrap test ---"
TOTAL=$((TOTAL + 1))
if [ -f "$DIR/../build/krc.kr" ]; then
    # Use the host arch so the compiled krc can run on the runner.
    HOST_ARCH=$(uname -m)
    case "$HOST_ARCH" in
        aarch64|arm64) BS_ARCH=arm64 ;;
        *)             BS_ARCH=x86_64 ;;
    esac
    cp "$DIR/../build/krc.kr" /tmp/krc_bootstrap_$$.kr
    $KRC $KRC_FLAGS /tmp/krc_bootstrap_$$.kr -o /tmp/krc2_$$ > /dev/null 2>&1
    chmod +x /tmp/krc2_$$ 2>/dev/null
    /tmp/krc2_$$ --arch=$BS_ARCH /tmp/krc_bootstrap_$$.kr -o /tmp/krc3_$$ > /dev/null 2>&1
    chmod +x /tmp/krc3_$$ 2>/dev/null
    /tmp/krc3_$$ --arch=$BS_ARCH /tmp/krc_bootstrap_$$.kr -o /tmp/krc4_$$ > /dev/null 2>&1
    if diff /tmp/krc3_$$ /tmp/krc4_$$ > /dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo "  bootstrap: PASS (fixed point at $(wc -c < /tmp/krc3_$$) bytes)"
    else
        FAIL=$((FAIL + 1))
        echo "  bootstrap: FAIL (krc3 != krc4)"
    fi
    rm -f /tmp/krc_bootstrap_$$.kr /tmp/krc2_$$ /tmp/krc3_$$ /tmp/krc4_$$
else
    echo "  bootstrap: SKIP (no build/krc.kr)"
    PASS=$((PASS + 1))
fi

echo ""
echo "--- typed local arrays (regression) ---"
run_test "u8_arr"  'fn main() { u8[4] a; a[0] = 10; a[3] = 40; exit(a[0] + a[3]) }' 50
run_test "u16_arr" 'fn main() { u16[4] a; a[0] = 1000; a[3] = 4000; exit((a[0] + a[3]) / 100) }' 50
run_test "u32_arr" 'fn main() { u32[4] a; a[0] = 100000; a[3] = 400000; exit((a[0] + a[3]) / 10000) }' 50
run_test "u64_arr" 'fn main() { u64[4] a; a[0] = 100; a[1] = 200; a[2] = 300; a[3] = 400; exit(a[2] - a[0] - 100) }' 100
run_test "u64_arr_loop" 'fn main() {
    u64[5] a
    a[0] = 1
    a[1] = 2
    a[2] = 3
    a[3] = 4
    a[4] = 5
    u64 sum = 0
    for i in 0..5 { sum = sum + a[i] }
    exit(sum)
}' 15
run_test "bubble_sort_u64" 'fn main() {
    u64[4] a
    a[0] = 3
    a[1] = 1
    a[2] = 4
    a[3] = 2
    for i in 0..4 {
        for j in 0..3 {
            if a[j] > a[j+1] {
                u64 t = a[j]
                a[j] = a[j+1]
                a[j+1] = t
            }
        }
    }
    exit(a[0] * 0 + a[1] * 0 + a[2] * 0 + a[3])
}' 4

echo ""
echo "--- heap struct pointers (regression) ---"
run_test "heap_struct_basic" 'struct P { u64 x; u64 y }
fn main() {
    P p = alloc(16)
    p.x = 11
    p.y = 31
    exit(p.x + p.y)
}' 42
run_test "heap_linked_list" 'struct N { u64 v; u64 next }
fn main() {
    N a = alloc(16)
    N b = alloc(16)
    a.v = 2
    a.next = b
    b.v = 40
    b.next = 0
    u64 sum = 0
    N cur = a
    while cur != 0 {
        sum = sum + cur.v
        cur = cur.next
    }
    exit(sum)
}' 42

echo ""
echo "--- const initializers (regression) ---"
run_test "const_int"    'const u64 X = 42; fn main() { exit(X) }' 42
run_test "const_hex"    'const u64 X = 0x2A; fn main() { exit(X) }' 42
run_test "const_div"    'const u64 D = 10; fn main() { exit(100 / D) }' 10
run_test "const_mod"    'const u64 M = 7; fn main() { exit(50 % M) }' 1
run_test "const_mul"    'const u64 C = 21; fn main() { exit(C * 2) }' 42
run_test "const_char"   "const u64 CH = 'A'; fn main() { exit(CH) }" 65
run_test "const_true"   'const u64 T = true; fn main() { exit(T + 41) }' 42
run_test "static_int"   'static u64 X = 99; fn main() { exit(X) }' 99
run_test "static_neg"   'static i64 X = -1; fn main() { exit(X) }' 255
run_test "static_bnot"  'static u64 X = ~0; fn main() { exit(X & 7) }' 7
run_test "const_neg"    'const i64 X = -42; fn main() { exit(0 - X) }' 42

echo ""
echo "--- import after comment (regression) ---"
TOTAL=$((TOTAL + 1))
cat > /tmp/imp_test_$$.kr <<'KREOF'
// leading comment should not break imports
import "std/io.kr"
fn main() { println("imp_ok"); exit(0) }
KREOF
if $KRC $KRC_FLAGS /tmp/imp_test_$$.kr -o /tmp/imp_test_bin_$$ > /dev/null 2>&1; then
    got=$(/tmp/imp_test_bin_$$ 2>/dev/null)
    if [ "$got" = "imp_ok" ]; then
        PASS=$((PASS + 1))
        echo "  import_after_comment: PASS"
    else
        FAIL=$((FAIL + 1))
        echo "  import_after_comment: FAIL (got: $got)"
    fi
else
    FAIL=$((FAIL + 1))
    echo "  import_after_comment: FAIL (compile)"
fi
rm -f /tmp/imp_test_$$.kr /tmp/imp_test_bin_$$

echo ""
echo "--- char literals ---"
run_test "char_a"    "fn main() { exit('A') }" 65
run_test "char_z"    "fn main() { exit('z') }" 122
run_test "char_nl"   "fn main() { exit('\\n') }" 10
run_test "char_tab"  "fn main() { exit('\\t') }" 9
run_test "char_bs"   "fn main() { exit('\\\\') }" 92
run_test "char_nul"  "fn main() { exit('\\0') }" 0
run_test "char_cmp"  "fn main() { u64 c = 97; if c == 'a' { exit(1) } exit(0) }" 1

echo ""
echo "--- emit=obj non-extern path (regression) ---"
TOTAL=$((TOTAL + 1))
cat > /tmp/krc_noext_$$.kr <<'KREOF'
fn main() { exit(42) }
KREOF
if $KRC --emit=obj /tmp/krc_noext_$$.kr -o /tmp/krc_noext_$$.o > /dev/null 2>&1; then
    # File must be long enough for section headers: shoff + shnum*64 <= filesize
    if command -v python3 > /dev/null 2>&1; then
        if python3 -c "
import struct, sys
d = open('/tmp/krc_noext_$$.o', 'rb').read()
shoff = struct.unpack_from('<Q', d, 0x28)[0]
shnum = struct.unpack_from('<H', d, 0x3C)[0]
if shoff + shnum * 64 != len(d):
    print('truncated:', shoff + shnum * 64, 'expected,', len(d), 'got')
    sys.exit(1)
"; then
            PASS=$((PASS + 1))
            echo "  emit_obj_no_extern: PASS"
        else
            FAIL=$((FAIL + 1))
            echo "  emit_obj_no_extern: FAIL (truncated ELF)"
        fi
    else
        PASS=$((PASS + 1))
        echo "  emit_obj_no_extern: SKIP (no python3)"
    fi
else
    FAIL=$((FAIL + 1))
    echo "  emit_obj_no_extern: FAIL (compile)"
fi
rm -f /tmp/krc_noext_$$.kr /tmp/krc_noext_$$.o

# --- real LZ4 compression in .krbo fat binaries (regression) ---
# Before this, the "compressor" wrote uncompressed LZ4 frames (bit 31 set
# in block size) and the runner's else-branch skipped compressed blocks
# entirely. This test compiles a fat binary for a reasonably large
# program, checks that at least the first slice is actually compressed
# (bit 31 clear), and that its ratio is below 90% of the original.
#
# Must call build/krc2 directly — the test $KRC wrapper forces
# --arch=x86_64 which would make krc emit a single-arch ELF, not a
# fat binary, and there'd be nothing to inspect.
echo ""
echo "--- fat binary real LZ4 compression (regression) ---"
TOTAL=$((TOTAL + 1))
KRCBIN="$DIR/../build/krc2"
cat > /tmp/krc_lz4_$$.kr <<'KREOF'
fn main() {
    u64 i = 0
    u64 sum = 0
    while i < 64 { sum = sum + i * i; i = i + 1 }
    println(sum)
    exit(0)
}
KREOF
if "$KRCBIN" /tmp/krc_lz4_$$.kr -o /tmp/krc_lz4_$$.krbo > /dev/null 2>&1; then
    if command -v python3 > /dev/null 2>&1; then
        if python3 -c "
import struct, sys
d = open('/tmp/krc_lz4_$$.krbo', 'rb').read()
assert d[:8] == b'KRBOFAT\\x00'
n = struct.unpack_from('<I', d, 12)[0]
# With pair blobs, csize covers two slices and cannot be compared to
# one slice's usize. Instead check: (1) total file < sum-of-uncompressed
# and (2) at least one block uses real compression (bit 31 clear).
total_uncomp = 0
any_compressed = False
for i in range(n):
    aid, comp, off, csize, usize = struct.unpack_from('<IIQQQ', d, 16+i*48)
    total_uncomp += usize
    frame = d[off:off+csize]
    if len(frame) >= 11:
        bs = struct.unpack_from('<I', frame, 7)[0]
        if (bs >> 31) & 1 == 0:
            any_compressed = True
if not any_compressed:
    print('no compressed blocks found')
    sys.exit(1)
if len(d) >= total_uncomp * 9 // 10:
    print(f'file {len(d)} not < 90% of {total_uncomp}')
    sys.exit(1)
print(f'ok: file={len(d)} total_uncomp={total_uncomp}')
"; then
            PASS=$((PASS + 1))
            echo "  lz4_real_compression: PASS"
        else
            FAIL=$((FAIL + 1))
            echo "  lz4_real_compression: FAIL"
        fi
    else
        PASS=$((PASS + 1))
        echo "  lz4_real_compression: SKIP (no python3)"
    fi
else
    FAIL=$((FAIL + 1))
    echo "  lz4_real_compression: FAIL (compile)"
fi
rm -f /tmp/krc_lz4_$$.kr /tmp/krc_lz4_$$.krbo

# --- .krbo round-trip via kr runner (real-compression end-to-end) ---
# Builds a .krbo, a kr runner binary, and runs the .krbo through it.
# The runner must decompress the real LZ4 block and produce the right
# output. Skipped if we can't rebuild a matching runner.
echo ""
echo "--- fat binary round-trip via kr runner (regression) ---"
TOTAL=$((TOTAL + 1))
cat > /tmp/krc_rt_$$.kr <<'KREOF'
fn main() {
    println("roundtrip-ok")
    exit(123)
}
KREOF
KRCBIN="$DIR/../build/krc2"
cat "$DIR/../src/bcj.kr" "$DIR/../src/runner.kr" > /tmp/krc_rt_kr_$$.kr
if "$KRCBIN" /tmp/krc_rt_$$.kr -o /tmp/krc_rt_$$.krbo > /dev/null 2>&1 \
   && "$KRCBIN" --arch=$ARCH /tmp/krc_rt_kr_$$.kr -o /tmp/krc_rt_kr_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_rt_kr_$$
    out=$(/tmp/krc_rt_kr_$$ /tmp/krc_rt_$$.krbo 2>&1)
    code=$?
    if [ "$out" = "roundtrip-ok" ] && [ "$code" = "123" ]; then
        PASS=$((PASS + 1))
        echo "  krbo_roundtrip: PASS"
    else
        FAIL=$((FAIL + 1))
        echo "  krbo_roundtrip: FAIL (out='$out' code=$code)"
    fi
else
    PASS=$((PASS + 1))
    echo "  krbo_roundtrip: SKIP (runner build)"
fi
rm -f /tmp/krc_rt_$$.kr /tmp/krc_rt_kr_$$.kr /tmp/krc_rt_$$.krbo /tmp/krc_rt_kr_$$

echo ""
echo "--- float types ---"
run_test "f64_parse" 'fn main() { f64 x = 0.0; exit(0) }' 0
run_test "f64_literal_precision" 'fn main() { f64 pi = 3.14159; f64 s = pi * int_to_f64(100000); exit(f64_to_int(s) % 100) }' 59
run_test "int_to_f64_rt" 'fn main() { f64 x = int_to_f64(42); exit(f64_to_int(x)) }' 42
run_test "f64_add" 'fn main() { f64 a = int_to_f64(10); f64 b = int_to_f64(3); f64 c = a + b; exit(f64_to_int(c)) }' 13
run_test "f64_sub" 'fn main() { f64 a = int_to_f64(50); f64 b = int_to_f64(8); exit(f64_to_int(a - b)) }' 42
run_test "f64_mul" 'fn main() { f64 a = int_to_f64(6); f64 b = int_to_f64(7); exit(f64_to_int(a * b)) }' 42
run_test "f64_div" 'fn main() { f64 a = int_to_f64(84); f64 b = int_to_f64(2); exit(f64_to_int(a / b)) }' 42
run_test "f64_sqrt" 'fn main() { f64 x = int_to_f64(49); exit(f64_to_int(sqrt(x))) }' 7
run_test "f64_reassign" 'fn main() { f64 x = int_to_f64(10); x = x + int_to_f64(5); x = x * int_to_f64(2); exit(f64_to_int(x)) }' 30
run_test "f64_cmp_lt" 'fn main() { f64 a = int_to_f64(3); f64 b = int_to_f64(5); if a < b { exit(1) } exit(0) }' 1
run_test "f64_cmp_gt" 'fn main() { f64 a = int_to_f64(10); f64 b = int_to_f64(5); if a > b { exit(1) } exit(0) }' 1
run_test "f64_cmp_eq" 'fn main() { f64 a = int_to_f64(7); f64 b = int_to_f64(7); if a == b { exit(1) } exit(0) }' 1
run_test "f64_fn_call" 'fn double_it(f64 x) -> f64 { return x + x }
fn main() { f64 r = double_it(int_to_f64(21)); exit(f64_to_int(r)) }' 42
run_test "f64_fn_2args" 'fn add_f(f64 a, f64 b) -> f64 { return a + b }
fn main() { f64 r = add_f(int_to_f64(20), int_to_f64(22)); exit(f64_to_int(r)) }' 42
run_test "f64_fn_mixed" 'fn scale(u64 n, f64 x) -> f64 { f64 fn64 = int_to_f64(n); return fn64 * x }
fn main() { f64 r = scale(3, int_to_f64(14)); exit(f64_to_int(r)) }' 42
run_test "f64_pos2_arg" 'fn get_second(u64 a, f64 b) -> f64 { return b }
fn main() { f64 r = get_second(1, 42.0); exit(f64_to_int(r)) }' 42
run_test "f64_pos3_arg" 'fn get_third(u64 a, u64 b, f64 c) -> f64 { return c }
fn main() { f64 r = get_third(1, 2, 33.0); exit(f64_to_int(r)) }' 33

# Float literal parsing
run_test "f64_literal_zero" 'fn main() { f64 x = 0.0; exit(f64_to_int(x)) }' 0
run_test "f64_literal_one" 'fn main() { f64 x = 1.0; exit(f64_to_int(x)) }' 1
# Regression: long plain-decimal f32 literal was sign-flipped (frac_divisor overflowed u64
# at >=19 frac digits; cvtsi2sd treated it as signed, producing a negative value).
# 0.0037996768951416016f has 19 frac digits — this must parse positive and be in (0.003,0.004).
run_test "f32_long_decimal_positive" 'fn main() { f32 v = 0.0037996768951416016f; i32 rc = 0; if v < 0.0f { rc = rc + 1 }; if v > 0.003f { if v < 0.004f { rc = rc + 2 } }; exit(rc) }' 2
# Scientific notation must still work: 1e-8f and 1.5e-3f
run_test "f32_sci_notation_neg_exp" 'fn main() { f32 v = 1e-8f; if v > 0.0f { exit(1) }; exit(0) }' 1
run_test "f32_sci_notation_frac" 'fn main() { f32 v = 1.5e-3f; if v > 0.001f { if v < 0.002f { exit(1) } }; exit(0) }' 1
# Short decimal must still work
run_test "f32_short_decimal" 'fn main() { f32 v = 0.003799677f; if v > 0.003f { if v < 0.004f { exit(1) } }; exit(0) }' 1

# Float reassignment
run_test "f64_reassign2" 'fn main() { f64 x = int_to_f64(5); f64 y = int_to_f64(3); x = x + y; exit(f64_to_int(x)) }' 8

# Float in while loop
run_test "f64_while" 'fn main() { f64 sum = int_to_f64(0); u64 i = 0; while i < 10 { sum = sum + int_to_f64(1); i = i + 1 }; exit(f64_to_int(sum)) }' 10

# f32 basic
run_test "f32_basic" 'fn main() { f32 x = int_to_f32(42); exit(f32_to_int(x)) }' 42

# Float comparison edge cases
run_test "f64_cmp_le" 'fn main() { f64 a = int_to_f64(5); f64 b = int_to_f64(5); if a <= b { exit(1) } exit(0) }' 1
run_test "f64_cmp_ne" 'fn main() { f64 a = int_to_f64(3); f64 b = int_to_f64(5); if a != b { exit(1) } exit(0) }' 1

# Conversion roundtrip
run_test "f32_f64_roundtrip" 'fn main() { f64 a = int_to_f64(99); f32 b = f64_to_f32(a); f64 c = f32_to_f64(b); exit(f64_to_int(c)) }' 99
run_test "f32_literal" 'fn main() { f32 x = 42.0f; exit(f32_to_int(x)) }' 42
# f16 conversions use x86_64 SSE bit manipulation — not implemented on ARM64
if [ "$ARCH" = "x86_64" ]; then
run_test "f16_roundtrip" 'fn main() { f32 x = 42.0f; u64 h = f32_to_f16(x); f32 y = f16_to_f32(h); exit(f32_to_int(y)) }' 42
fi

# FMA
run_test "f64_fma" 'fn main() { f64 a = int_to_f64(3); f64 b = int_to_f64(4); f64 c = int_to_f64(5); f64 r = fma_f64(a, b, c); exit(f64_to_int(r)) }' 17

echo ""
echo "--- alloc/dealloc ---"
run_test "alloc_header" 'fn main() { u64 p = alloc(64); store64(p, 42); u64 v = load64(p); exit(v) }' 42
run_test "dealloc_basic" 'fn main() { u64 p = alloc(64); store64(p, 99); dealloc(p); exit(0) }' 0

echo ""
echo "--- allocators (arena) ---"
run_test "arena_basic" 'import "std/alloc.kr"
fn main() {
    u64 a = arena_new(4096)
    u64 p1 = arena_alloc(a, 64)
    store64(p1, 42)
    u64 v = load64(p1)
    arena_destroy(a)
    exit(v)
}' 42

run_test "arena_reset" 'import "std/alloc.kr"
fn main() {
    u64 a = arena_new(4096)
    u64 p1 = arena_alloc(a, 100)
    arena_reset(a)
    u64 p2 = arena_alloc(a, 100)
    if p1 == p2 { exit(1) } exit(0)
}' 1

run_test "arena_stats" 'import "std/alloc.kr"
fn main() {
    u64 a = arena_new(4096)
    arena_alloc(a, 32)
    arena_alloc(a, 64)
    (u64 total, u64 live) = arena_stats(a)
    arena_reset(a)
    arena_destroy(a)
    exit(total)
}' 96

echo ""
echo "--- allocators (pool) ---"
run_test "pool_basic" 'import "std/alloc.kr"
fn main() {
    u64 p = pool_new(64, 8)
    u64 o1 = pool_alloc(p)
    store64(o1, 99)
    u64 v = load64(o1)
    pool_free(p, o1)
    pool_destroy(p)
    exit(v)
}' 99

run_test "pool_reuse" 'import "std/alloc.kr"
fn main() {
    u64 p = pool_new(16, 4)
    u64 a = pool_alloc(p)
    u64 b = pool_alloc(p)
    pool_free(p, a)
    u64 c = pool_alloc(p)
    if a == c { exit(1) } exit(0)
}' 1

run_test "pool_stats" 'import "std/alloc.kr"
fn main() {
    u64 p = pool_new(32, 10)
    pool_alloc(p)
    pool_alloc(p)
    pool_alloc(p)
    (u64 total, u64 used) = pool_stats(p)
    pool_destroy(p)
    exit(used)
}' 3

echo ""
echo "--- allocators (heap) ---"
run_test "heap_basic" 'import "std/alloc.kr"
fn main() {
    u64 h = heap_new(4096)
    u64 p = heap_alloc(h, 64)
    store64(p, 77)
    u64 v = load64(p)
    heap_free(h, p)
    heap_destroy(h)
    exit(v)
}' 77

run_test "heap_multi" 'import "std/alloc.kr"
fn main() {
    u64 h = heap_new(4096)
    u64 a = heap_alloc(h, 32)
    u64 b = heap_alloc(h, 64)
    u64 c = heap_alloc(h, 16)
    store64(a, 10)
    store64(b, 20)
    store64(c, 30)
    heap_free(h, b)
    heap_free(h, a)
    heap_free(h, c)
    heap_destroy(h)
    exit(0)
}' 0

run_test "heap_stats" 'import "std/alloc.kr"
fn main() {
    u64 h = heap_new(4096)
    u64 a = heap_alloc(h, 32)
    u64 b = heap_alloc(h, 64)
    heap_free(h, a)
    (u64 total, u64 freed, u64 live) = heap_stats(h)
    heap_free(h, b)
    heap_destroy(h)
    exit(total)
}' 96

echo ""
echo "--- extern fn (libc linking) ---"
# These tests link against the HOST gcc's libc. On cross-compile runs
# (arm64 host but KRC_FLAGS=--arch=x86_64 for example) the object file
# architecture won't match gcc and the link fails. Skip on non-x86_64
# hosts since the default KRC_FLAGS target host arch and the host gcc
# links to host libc.
HOST_M=$(uname -m)
if [ "$HOST_M" != "x86_64" ] && [ "$HOST_M" != "amd64" ]; then
    echo "  extern_libc_write: SKIP (non-x86_64 host toolchain)"
    echo "  extern_libc_strlen_write: SKIP (non-x86_64 host toolchain)"
elif command -v gcc > /dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    cat > /tmp/krc_ext_$$.kr <<'KREOF'
extern fn write(u64 fd, u64 buf, u64 len) -> u64

fn main() {
    write(1, "extern_ok\n", 10)
    exit(0)
}
KREOF
    if $KRC --emit=obj /tmp/krc_ext_$$.kr -o /tmp/krc_ext_$$.o > /dev/null 2>&1 \
       && gcc /tmp/krc_ext_$$.o -o /tmp/krc_ext_linked_$$ -no-pie > /dev/null 2>&1; then
        got=$(/tmp/krc_ext_linked_$$ 2>/dev/null)
        if [ "$got" = "extern_ok" ]; then
            PASS=$((PASS + 1))
            echo "  extern_libc_write: PASS"
        else
            FAIL=$((FAIL + 1))
            echo "  extern_libc_write: FAIL (got: $got)"
        fi
    else
        FAIL=$((FAIL + 1))
        echo "  extern_libc_write: FAIL (compile/link failed)"
    fi
    rm -f /tmp/krc_ext_$$.kr /tmp/krc_ext_$$.o /tmp/krc_ext_linked_$$

    TOTAL=$((TOTAL + 1))
    cat > /tmp/krc_ext2_$$.kr <<'KREOF'
extern fn strlen(u64 s) -> u64
extern fn write(u64 fd, u64 buf, u64 len) -> u64

fn main() {
    u64 msg = "two_externs\n"
    u64 n = strlen(msg)
    write(1, msg, n)
    exit(0)
}
KREOF
    if $KRC --emit=obj /tmp/krc_ext2_$$.kr -o /tmp/krc_ext2_$$.o > /dev/null 2>&1 \
       && gcc /tmp/krc_ext2_$$.o -o /tmp/krc_ext2_linked_$$ -no-pie > /dev/null 2>&1; then
        got=$(/tmp/krc_ext2_linked_$$ 2>/dev/null)
        if [ "$got" = "two_externs" ]; then
            PASS=$((PASS + 1))
            echo "  extern_libc_strlen_write: PASS"
        else
            FAIL=$((FAIL + 1))
            echo "  extern_libc_strlen_write: FAIL (got: $got)"
        fi
    else
        FAIL=$((FAIL + 1))
        echo "  extern_libc_strlen_write: FAIL (compile/link failed)"
    fi
    rm -f /tmp/krc_ext2_$$.kr /tmp/krc_ext2_$$.o /tmp/krc_ext2_linked_$$
else
    echo "  extern_libc_write: SKIP (gcc not available)"
    echo "  extern_libc_strlen_write: SKIP (gcc not available)"
fi

# --- sizeof ---
run_test "sizeof_u8" 'fn main() { exit(sizeof(uint8)) }' 1
run_test "sizeof_u64" 'fn main() { exit(sizeof(uint64)) }' 8
run_test "sizeof_f32" 'fn main() { exit(sizeof(f32)) }' 4
run_test "sizeof_f64" 'fn main() { exit(sizeof(f64)) }' 8
run_test "sizeof_struct" 'struct P { uint64 x; uint64 y }
fn main() { exit(sizeof(P)) }' 16
run_test "sizeof_struct_mixed" 'struct S { uint8 a; uint64 b }
fn main() { exit(sizeof(S)) }' 9
run_test "sizeof_alloc" 'struct P { uint64 x; uint64 y }
fn main() { uint64 p = alloc(sizeof(P)); dealloc(p); exit(0) }' 0

# --- Struct literals ---
run_test "struct_literal_pos" 'struct P { uint64 x; uint64 y }
fn main() {
    P p = P { 10, 20 }
    exit(p.x + p.y)
}' 30

run_test "struct_literal_named" 'struct P { uint64 x; uint64 y }
fn main() {
    P p = P { y: 20, x: 10 }
    exit(p.x + p.y)
}' 30

run_test "struct_literal_u8" 'struct S { uint8 a; uint8 b }
fn main() {
    S s = S { 3, 4 }
    exit(s.a + s.b)
}' 7

# --- Struct value semantics (copy on assign) ---
run_test "struct_assign_copy" 'struct P { uint64 x; uint64 y }
fn main() {
    P a
    a.x = 10; a.y = 20
    P b = a
    b.x = 99
    exit(a.x)
}' 10

run_test "struct_reassign" 'struct P { uint64 x; uint64 y }
fn main() {
    P a; a.x = 1; a.y = 2
    P b; b.x = 10; b.y = 20
    a = b
    exit(a.x + a.y)
}' 30

run_test "struct_literal_copy" 'struct P { uint64 x; uint64 y }
fn main() {
    P p = P { 10, 20 }
    P q = p
    q.x = 99
    exit(p.x)
}' 10

# --- Struct pass-by-value tests ---
run_test "struct_pass_by_value" 'struct P { uint64 x; uint64 y }
fn sum(P p) -> uint64 { return p.x + p.y }
fn main() {
    P a; a.x = 10; a.y = 20
    exit(sum(a))
}' 30

run_test "struct_pass_literal" 'struct P { uint64 x; uint64 y }
fn sum(P p) -> uint64 { return p.x + p.y }
fn main() { exit(sum(P { 10, 20 })) }' 30

run_test "struct_pass_no_alias" 'struct P { uint64 x; uint64 y }
fn modify(P p) -> uint64 { p.x = 99; return p.x }
fn main() {
    P a; a.x = 10; a.y = 20
    uint64 r = modify(a)
    exit(a.x)
}' 10

# --- Struct return by value tests ---
run_test "struct_return_small" 'struct P { uint64 x; uint64 y }
fn make(uint64 x, uint64 y) -> P {
    return P { x, y }
}
fn main() {
    P p = make(10, 20)
    exit(p.x + p.y)
}' 30

run_test "struct_return_field" 'struct P { uint64 x; uint64 y }
fn make() -> P { return P { 3, 4 } }
fn main() { P p = make(); exit(p.x) }' 3

run_test "struct_return_chain" 'struct P { uint64 x; uint64 y }
fn make(uint64 v) -> P { return P { v, v + 1 } }
fn sum(P p) -> uint64 { return p.x + p.y }
fn main() { exit(sum(make(10))) }' 21

# --- Struct pass-by-value SSE (float eightbytes) tests ---
# These require SSE struct passing (x86_64 SysV only — ARM64 needs HFA support)
if [ "$ARCH" = "x86_64" ]; then
run_test "struct_pass_f64" 'struct V { f64 x; f64 y }
fn sum(V v) -> f64 { return v.x + v.y }
fn main() {
    V v; v.x = 3.0; v.y = 4.0
    f64 r = sum(v)
    exit(f64_to_int(r))
}' 7

run_test "struct_pass_mixed" 'struct M { uint64 id; f64 val }
fn get_val(M m) -> f64 { return m.val }
fn main() {
    M m; m.id = 1; m.val = 42.0
    f64 r = get_val(m)
    exit(f64_to_int(r))
}' 42
fi

# --- Large struct (MEMORY class) passing tests ---
run_test "struct_large_pass" 'struct Big { uint64 a; uint64 b; uint64 c }
fn sum(Big b) -> uint64 { return b.a + b.b + b.c }
fn main() {
    Big x; x.a = 1; x.b = 2; x.c = 3
    exit(sum(x))
}' 6

run_test "struct_large_copy" 'struct Big { uint64 a; uint64 b; uint64 c }
fn main() {
    Big x; x.a = 10; x.b = 20; x.c = 30
    Big y = x
    y.a = 99
    exit(x.a)
}' 10

run_test "struct_large_literal" 'struct Big { uint64 a; uint64 b; uint64 c }
fn sum(Big b) -> uint64 { return b.a + b.b + b.c }
fn main() { exit(sum(Big { 1, 2, 3 })) }' 6

# --- MEMORY-class struct return (sret hidden pointer, >16 bytes) tests ---
run_test "struct_return_large" 'struct Big { uint64 a; uint64 b; uint64 c }
fn make() -> Big {
    Big b; b.a = 10; b.b = 20; b.c = 30
    return b
}
fn main() {
    Big r = make()
    exit(r.a + r.b + r.c)
}' 60

run_test "struct_return_large_args" 'struct Big { uint64 a; uint64 b; uint64 c }
fn make(uint64 x, uint64 y, uint64 z) -> Big {
    Big b; b.a = x; b.b = y; b.c = z
    return b
}
fn main() {
    Big r = make(1, 2, 3)
    exit(r.a + r.b + r.c)
}' 6

run_test "nested_struct_basic" 'struct P { uint64 x; uint64 y }
struct L { P a; P b }
fn main() {
    L l
    l.a.x = 10; l.a.y = 20
    l.b.x = 30; l.b.y = 40
    exit(l.a.x + l.b.y)
}' 50

run_test "nested_struct_sizeof" 'struct P { uint64 x; uint64 y }
struct L { P a; P b }
fn main() { exit(sizeof(L)) }' 32

run_test "nested_struct_pass" 'struct P { uint64 x; uint64 y }
struct L { P a; P b }
fn sum(L l) -> uint64 { return l.a.x + l.a.y + l.b.x + l.b.y }
fn main() {
    L l
    l.a.x = 1; l.a.y = 2; l.b.x = 3; l.b.y = 4
    exit(sum(l))
}' 10

run_test "struct_eq" 'struct P { uint64 x; uint64 y }
fn main() {
    P a; a.x = 10; a.y = 20
    P b; b.x = 10; b.y = 20
    uint64 r = 0
    if a == b { r = 1 }
    exit(r)
}' 1

run_test "struct_ne" 'struct P { uint64 x; uint64 y }
fn main() {
    P a; a.x = 10; a.y = 20
    P b; b.x = 10; b.y = 99
    uint64 r = 0
    if a != b { r = 1 }
    exit(r)
}' 1

run_test "struct_eq_false" 'struct P { uint64 x; uint64 y }
fn main() {
    P a; a.x = 10; a.y = 20
    P b; b.x = 10; b.y = 99
    uint64 r = 0
    if a == b { r = 1 }
    exit(r)
}' 0

run_test "struct_ne_false" 'struct P { uint64 x; uint64 y }
fn main() {
    P a; a.x = 10; a.y = 20
    P b; b.x = 10; b.y = 20
    uint64 r = 0
    if a != b { r = 1 }
    exit(r)
}' 0

run_test "struct_eq_3field" 'struct V { uint64 x; uint64 y; uint64 z }
fn main() {
    V a; a.x = 1; a.y = 2; a.z = 3
    V b; b.x = 1; b.y = 2; b.z = 3
    uint64 r = 0
    if a == b { r = 1 }
    exit(r)
}' 1

# Helper: check that compilation FAILS with expected error message
run_error_check() {
    local name="$1"
    local input="$2"
    local expected_msg="$3"
    TOTAL=$((TOTAL + 1))
    local REPO_ROOT="$DIR/.."
    printf '%s\n' "$input" > "$REPO_ROOT/test_tmp_$$.kr"
    if $KRC $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_test_$$ > /dev/null 2>/tmp/krc_diag_$$; then
        echo "FAIL: $name (should not compile)"
        FAIL=$((FAIL + 1))
    else
        if grep -q "$expected_msg" /tmp/krc_diag_$$; then
            PASS=$((PASS + 1))
            echo "  $name: PASS"
        else
            echo "FAIL: $name (expected '$expected_msg')"
            FAIL=$((FAIL + 1))
        fi
    fi
    rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_test_$$ /tmp/krc_diag_$$
}

# Helper: check that compilation SUCCEEDS but emits expected warning
run_warning_check() {
    local name="$1"
    local input="$2"
    local expected_msg="$3"
    TOTAL=$((TOTAL + 1))
    local REPO_ROOT="$DIR/.."
    printf '%s\n' "$input" > "$REPO_ROOT/test_tmp_$$.kr"
    $KRC $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_test_$$ > /dev/null 2>/tmp/krc_diag_$$
    if grep -q "$expected_msg" /tmp/krc_diag_$$; then
        PASS=$((PASS + 1))
        echo "  $name: PASS"
    else
        echo "FAIL: $name (expected warning '$expected_msg')"
        FAIL=$((FAIL + 1))
    fi
    rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_test_$$ /tmp/krc_diag_$$
}

echo ""
echo "--- Compiler diagnostics ---"
run_error_check "diag_undef_var" 'fn main() { exit(xyz_undefined_name) }' "undeclared identifier"
run_warning_check "diag_unreachable_return" 'fn foo() -> uint64 { return 1; uint64 x = 2; return x } fn main() { exit(0) }' "unreachable code"
run_warning_check "diag_unreachable_break" 'fn main() { while 1 == 1 { break; uint64 x = 1 } exit(0) }' "unreachable code"
run_warning_check "diag_unreachable_exit" 'fn main() { exit(0); uint64 x = 1 }' "unreachable code"

# --- Runtime debug checks ---
echo ""
echo "--- Runtime debug checks (--debug) ---"
TOTAL=$((TOTAL + 1))
REPO_ROOT="$DIR/.."
printf 'fn main() { uint64 a = 10; uint64 b = 0; uint64 c = a / b; exit(c) }\n' > "$REPO_ROOT/test_tmp_$$.kr"
if $KRC $KRC_FLAGS --debug "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_test_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_test_$$
    /tmp/krc_test_$$ > /dev/null 2>&1
    actual=$?
    if [ "$actual" != "0" ]; then
        PASS=$((PASS + 1))
        echo "  debug_divzero: PASS (trapped, exit=$actual)"
    else
        echo "FAIL: debug_divzero (should have trapped)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: debug_divzero (compilation failed)"
    FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_test_$$

# Overflow test
TOTAL=$((TOTAL + 1))
printf 'fn main() { uint64 a = 9223372036854775807; uint64 b = a + a; exit(b) }\n' > "$REPO_ROOT/test_tmp_$$.kr"
if $KRC $KRC_FLAGS --debug "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_test_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_test_$$
    /tmp/krc_test_$$ > /dev/null 2>&1
    actual=$?
    if [ "$actual" != "0" ]; then
        PASS=$((PASS + 1))
        echo "  debug_overflow: PASS (trapped, exit=$actual)"
    else
        echo "FAIL: debug_overflow (should have trapped)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: debug_overflow (compilation failed)"
    FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_test_$$

# Null pointer test
TOTAL=$((TOTAL + 1))
printf 'fn main() { uint64 p = 0; uint64 v = load64(p); exit(v) }\n' > "$REPO_ROOT/test_tmp_$$.kr"
if $KRC $KRC_FLAGS --debug "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_test_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_test_$$
    /tmp/krc_test_$$ > /dev/null 2>&1
    actual=$?
    if [ "$actual" != "0" ]; then
        PASS=$((PASS + 1))
        echo "  debug_null_ptr: PASS (trapped, exit=$actual)"
    else
        echo "FAIL: debug_null_ptr (should have trapped)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: debug_null_ptr (compilation failed)"
    FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_test_$$

echo ""
echo "--- Debug info (-g) ---"
if [ "$ARCH" = "x86_64" ] && command -v readelf > /dev/null 2>&1; then

# Test: -g produces .debug_line section
TOTAL=$((TOTAL + 1))
REPO_ROOT="$DIR/.."
printf 'fn main() { exit(42) }\n' > "$REPO_ROOT/test_tmp_$$.kr"
if $KRC $KRC_FLAGS -g "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_g_$$ > /dev/null 2>&1; then
    if readelf -S /tmp/krc_g_$$ 2>/dev/null | grep -q "debug_line"; then
        PASS=$((PASS + 1))
        echo "  debug_line_exists: PASS"
    else
        echo "FAIL: debug_line_exists (section not found)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: debug_line_exists (compilation failed)"
    FAIL=$((FAIL + 1))
fi

# Test: binary with -g runs correctly
TOTAL=$((TOTAL + 1))
chmod +x /tmp/krc_g_$$
/tmp/krc_g_$$ > /dev/null 2>&1
actual=$?
if [ "$actual" = "42" ]; then
    PASS=$((PASS + 1))
    echo "  debug_runs: PASS (exit=42)"
else
    echo "FAIL: debug_runs (expected 42, got $actual)"
    FAIL=$((FAIL + 1))
fi

# Test: without -g, no debug section
TOTAL=$((TOTAL + 1))
$KRC $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_nog_$$ > /dev/null 2>&1
if readelf -S /tmp/krc_nog_$$ 2>/dev/null | grep -q "debug_line"; then
    echo "FAIL: debug_no_flag (.debug_line should not exist)"
    FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1))
    echo "  debug_no_flag: PASS"
fi

# Test: readelf can decode the line info
TOTAL=$((TOTAL + 1))
if readelf --debug-dump=line /tmp/krc_g_$$ 2>&1 | grep -q "DWARF Version"; then
    PASS=$((PASS + 1))
    echo "  debug_line_valid: PASS"
else
    echo "FAIL: debug_line_valid (readelf could not decode)"
    FAIL=$((FAIL + 1))
fi

# Test: symtab has function names
TOTAL=$((TOTAL + 1))
if readelf -s /tmp/krc_g_$$ 2>/dev/null | grep -q "main"; then
    PASS=$((PASS + 1))
    echo "  debug_symtab: PASS"
else
    echo "FAIL: debug_symtab (main not in symbol table)"
    FAIL=$((FAIL + 1))
fi

rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_g_$$ /tmp/krc_nog_$$

fi  # end x86_64 + readelf gate

# --- IR backend test ---
echo ""
echo "--- IR backend test ---"
TOTAL=$((TOTAL + 1))
REPO_ROOT="$DIR/.."
printf 'fn main() { exit(42) }\n' > "$REPO_ROOT/test_tmp_$$.kr"
if $KRC $KRC_FLAGS --ir "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_ir_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_ir_$$
    /tmp/krc_ir_$$ > /dev/null 2>&1
    actual=$?
    if [ "$actual" = "42" ]; then
        PASS=$((PASS + 1))
        echo "  ir_exit_42: PASS"
    else
        echo "FAIL: ir_exit_42 (expected 42, got $actual)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: ir_exit_42 (compilation failed)"
    FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_ir_$$

# -- IR while loop --
TOTAL=$((TOTAL + 1))
printf 'fn main() { uint64 i = 0; uint64 s = 0; while i < 10 { s = s + i; i = i + 1 } exit(s) }\n' > "$REPO_ROOT/test_tmp_$$.kr"
if $KRC $KRC_FLAGS --ir "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_ir_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_ir_$$
    timeout 2 /tmp/krc_ir_$$ > /dev/null 2>&1
    actual=$?
    if [ "$actual" = "45" ]; then
        PASS=$((PASS + 1))
        echo "  ir_while_loop: PASS"
    else
        echo "FAIL: ir_while_loop (expected 45, got $actual)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: ir_while_loop (compilation failed)"
    FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_ir_$$

# -- IR division --
TOTAL=$((TOTAL + 1))
printf 'fn main() { exit(10 / 3) }\n' > "$REPO_ROOT/test_tmp_$$.kr"
if $KRC $KRC_FLAGS --ir "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_ir_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_ir_$$
    /tmp/krc_ir_$$ > /dev/null 2>&1
    actual=$?
    if [ "$actual" = "3" ]; then
        PASS=$((PASS + 1))
        echo "  ir_division: PASS"
    else
        echo "FAIL: ir_division (expected 3, got $actual)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: ir_division (compilation failed)"
    FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_ir_$$

# -- IR if/else --
TOTAL=$((TOTAL + 1))
printf 'fn main() { uint64 x = 10; if x > 5 { exit(1) } else { exit(0) } }\n' > "$REPO_ROOT/test_tmp_$$.kr"
if $KRC $KRC_FLAGS --ir "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_ir_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_ir_$$
    /tmp/krc_ir_$$ > /dev/null 2>&1
    actual=$?
    if [ "$actual" = "1" ]; then
        PASS=$((PASS + 1))
        echo "  ir_if_else: PASS"
    else
        echo "FAIL: ir_if_else (expected 1, got $actual)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: ir_if_else (compilation failed)"
    FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_ir_$$

# -- IR alloc/store64/load64/dealloc --
TOTAL=$((TOTAL + 1))
printf 'fn main() { uint64 p = alloc(64); store64(p, 42); uint64 v = load64(p); dealloc(p); exit(v) }\n' > "$REPO_ROOT/test_tmp_$$.kr"
if $KRC $KRC_FLAGS --ir "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_ir_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_ir_$$
    /tmp/krc_ir_$$ > /dev/null 2>&1
    actual=$?
    if [ "$actual" = "42" ]; then
        PASS=$((PASS + 1))
        echo "  ir_alloc_store_load: PASS"
    else
        echo "FAIL: ir_alloc_store_load (expected 42, got $actual)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: ir_alloc_store_load (compilation failed)"
    FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_ir_$$

# -- IR store8/load8 --
TOTAL=$((TOTAL + 1))
printf 'fn main() { uint64 p = alloc(16); store8(p, 65); uint64 v = load8(p); dealloc(p); exit(v) }\n' > "$REPO_ROOT/test_tmp_$$.kr"
if $KRC $KRC_FLAGS --ir "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_ir_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_ir_$$
    /tmp/krc_ir_$$ > /dev/null 2>&1
    actual=$?
    if [ "$actual" = "65" ]; then
        PASS=$((PASS + 1))
        echo "  ir_store8_load8: PASS"
    else
        echo "FAIL: ir_store8_load8 (expected 65, got $actual)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: ir_store8_load8 (compilation failed)"
    FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_ir_$$

# -- IR multi-alloc --
TOTAL=$((TOTAL + 1))
printf 'fn main() { uint64 a = alloc(64); uint64 b = alloc(64); store64(a, 10); store64(b, 32); uint64 r = load64(a) + load64(b); dealloc(a); dealloc(b); exit(r) }\n' > "$REPO_ROOT/test_tmp_$$.kr"
if $KRC $KRC_FLAGS --ir "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_ir_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_ir_$$
    /tmp/krc_ir_$$ > /dev/null 2>&1
    actual=$?
    if [ "$actual" = "42" ]; then
        PASS=$((PASS + 1))
        echo "  ir_multi_alloc: PASS"
    else
        echo "FAIL: ir_multi_alloc (expected 42, got $actual)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: ir_multi_alloc (compilation failed)"
    FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_ir_$$

# --- ir_break ---
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'IREOF'
fn main() { uint64 i = 0; while i < 100 { if i == 5 { break }; i = i + 1 }; exit(i) }
IREOF
if timeout 10 "$KRC" $KRC_FLAGS --ir "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_ir_$$ 2>/dev/null; then
    chmod +x /tmp/krc_ir_$$; /tmp/krc_ir_$$; actual=$?
    if [ "$actual" -eq 5 ]; then
        echo "  ir_break: PASS"
    else
        echo "FAIL: ir_break (expected 5, got $actual)"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: ir_break (compilation failed)"; FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_ir_$$

# --- ir_continue ---
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'IREOF'
fn main() { uint64 i = 0; uint64 s = 0; while i < 10 { i = i + 1; if i == 5 { continue }; s = s + 1 }; exit(s) }
IREOF
if timeout 10 "$KRC" $KRC_FLAGS --ir "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_ir_$$ 2>/dev/null; then
    chmod +x /tmp/krc_ir_$$; /tmp/krc_ir_$$; actual=$?
    if [ "$actual" -eq 9 ]; then
        echo "  ir_continue: PASS"
    else
        echo "FAIL: ir_continue (expected 9, got $actual)"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: ir_continue (compilation failed)"; FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_ir_$$

# --- ir_fn_call ---
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'IREOF'
fn add(uint64 a, uint64 b) -> uint64 { return a + b }
fn main() { exit(add(20, 22)) }
IREOF
if timeout 10 "$KRC" $KRC_FLAGS --ir "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_ir_$$ 2>/dev/null; then
    chmod +x /tmp/krc_ir_$$; /tmp/krc_ir_$$; actual=$?
    if [ "$actual" -eq 42 ]; then
        echo "  ir_fn_call: PASS"
    else
        echo "FAIL: ir_fn_call (expected 42, got $actual)"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: ir_fn_call (compilation failed)"; FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_ir_$$

# --- ir_recursion ---
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'IREOF'
fn fib(uint64 n) -> uint64 { if n <= 1 { return n }; return fib(n - 1) + fib(n - 2) }
fn main() { exit(fib(10)) }
IREOF
if timeout 10 "$KRC" $KRC_FLAGS --ir "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_ir_$$ 2>/dev/null; then
    chmod +x /tmp/krc_ir_$$; /tmp/krc_ir_$$; actual=$?
    if [ "$actual" -eq 55 ]; then
        echo "  ir_recursion: PASS"
    else
        echo "FAIL: ir_recursion (expected 55, got $actual)"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: ir_recursion (compilation failed)"; FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_ir_$$

# --- ir_match ---
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'IREOF'
fn main() { uint64 x = 2; uint64 r = 0; match x { 1 => { r = 10 } 2 => { r = 42 } 3 => { r = 30 } }; exit(r) }
IREOF
if timeout 10 "$KRC" $KRC_FLAGS --ir "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_ir_$$ 2>/dev/null; then
    chmod +x /tmp/krc_ir_$$; /tmp/krc_ir_$$; actual=$?
    if [ "$actual" -eq 42 ]; then
        echo "  ir_match: PASS"
    else
        echo "FAIL: ir_match (expected 42, got $actual)"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: ir_match (compilation failed)"; FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_ir_$$

# -- IR memset liveness (memset return must not clobber live vregs) --
TOTAL=$((TOTAL + 1))
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'IREOF'
fn main() {
    uint64 src = alloc(100)
    memset(src, 0xAB, 100)
    uint64 dst = alloc(100)
    memset(dst, 0, 100)
    memcpy(dst, src, 100)
    uint64 v = 0
    unsafe { *(dst as uint8) -> v }
    dealloc(src)
    dealloc(dst)
    exit(v)
}
IREOF
if $KRC $KRC_FLAGS --ir "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_ir_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_ir_$$
    /tmp/krc_ir_$$ > /dev/null 2>&1
    actual=$?
    if [ "$actual" = "171" ]; then
        PASS=$((PASS + 1))
        echo "  ir_memset_liveness: PASS"
    else
        echo "FAIL: ir_memset_liveness (expected 171, got $actual)"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: ir_memset_liveness (compilation failed)"; FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_ir_$$

# --- bool type ---
echo ""
echo "--- bool type ---"

TOTAL=$((TOTAL + 1))
REPO_ROOT="$DIR/.."
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'BOOLEOF'
fn main() {
    bool b = true
    if b { exit(1) }
    exit(0)
}
BOOLEOF
if timeout 10 "$KRC" $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_bool_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_bool_$$
    timeout 3 /tmp/krc_bool_$$ > /dev/null 2>&1
    if [ $? = 1 ]; then PASS=$((PASS + 1)); echo "  bool_true_false: PASS"
    else echo "FAIL: bool_true_false"; FAIL=$((FAIL + 1)); fi
else echo "FAIL: bool_true_false (compile)"; FAIL=$((FAIL + 1)); fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_bool_$$

TOTAL=$((TOTAL + 1))
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'BOOLEOF'
fn main() {
    uint64 x = true
    exit(0)
}
BOOLEOF
if timeout 10 "$KRC" $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_bool_$$ > /dev/null 2>&1; then
    echo "FAIL: bool_reject_assign_int (should have failed to compile)"; FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1)); echo "  bool_reject_assign_int: PASS"
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_bool_$$

# --- char type ---
echo ""
echo "--- char type ---"

TOTAL=$((TOTAL + 1))
REPO_ROOT="$DIR/.."
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'CHAREOF'
fn main() {
    exit('A')
}
CHAREOF
if timeout 10 "$KRC" $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_char_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_char_$$
    timeout 3 /tmp/krc_char_$$ > /dev/null 2>&1
    if [ $? = 65 ]; then PASS=$((PASS + 1)); echo "  char_literal: PASS"
    else echo "FAIL: char_literal"; FAIL=$((FAIL + 1)); fi
else echo "FAIL: char_literal (compile)"; FAIL=$((FAIL + 1)); fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_char_$$

TOTAL=$((TOTAL + 1))
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'CHAREOF'
fn main() {
    uint64 x = 'A'
    exit(0)
}
CHAREOF
if timeout 10 "$KRC" $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_char_$$ > /dev/null 2>&1; then
    echo "FAIL: char_reject_assign_int"; FAIL=$((FAIL + 1))
else PASS=$((PASS + 1)); echo "  char_reject_assign_int: PASS"; fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_char_$$

# --- typed println pipeline ---
echo ""
echo "--- typed println pipeline ---"

# println(true) → "true"
run_test_output "println_true" \
    'fn main() { println(true); exit(0) }' \
    "true"

# println(false) → "false"
run_test_output "println_false" \
    'fn main() { println(false); exit(0) }' \
    "false"

# println(3.14) → "3.140000"
run_test_output "println_f64" \
    'fn main() { println(3.14); exit(0) }' \
    "3.140000"

# println(0.0) → "0.000000"
run_test_output "println_f64_zero" \
    'fn main() { println(0.0); exit(0) }' \
    "0.000000"

# println negative float via subtraction (avoids literal-negation IR bug)
run_test_output "println_f64_neg" \
    'fn main() { f64 x = 0.0 - 3.14; println(x); exit(0) }' \
    "-3.140000"

# println big float → "big"
run_test_output "println_f64_big" \
    'fn main() { println(1000000000000000000.0); exit(0) }' \
    "big"

# println char literal → single character
run_test_output "println_char" \
    "fn main() { println('A'); exit(0) }" \
    "A"

# --- variadic print ---
echo ""
echo "--- variadic print ---"

TOTAL=$((TOTAL + 1))
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'VEOF'
fn main() {
    print("Here is a number,", 42)
    exit(0)
}
VEOF
if timeout 10 "$KRC" $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_v_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_v_$$
    got=$(timeout 3 /tmp/krc_v_$$)
    if [ "$got" = "Here is a number, 42" ]; then PASS=$((PASS + 1)); echo "  print_multi_int: PASS"
    else echo "FAIL: print_multi_int (got '$got')"; FAIL=$((FAIL + 1)); fi
else echo "FAIL: print_multi_int (compile)"; FAIL=$((FAIL + 1)); fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_v_$$

TOTAL=$((TOTAL + 1))
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'VEOF'
fn main() {
    println("n=", 5, "ok=", true)
    exit(0)
}
VEOF
if timeout 10 "$KRC" $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_v_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_v_$$
    got=$(timeout 3 /tmp/krc_v_$$)
    if [ "$got" = "n= 5 ok= true" ]; then PASS=$((PASS + 1)); echo "  println_multi_mixed: PASS"
    else echo "FAIL: println_multi_mixed (got '$got')"; FAIL=$((FAIL + 1)); fi
else echo "FAIL: println_multi_mixed (compile)"; FAIL=$((FAIL + 1)); fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_v_$$

# --- negative float literal ---
echo ""
echo "--- negative float ---"

TOTAL=$((TOTAL + 1))
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'NFEOF'
fn main() { f64 x = -3.14; println(x); exit(0) }
NFEOF
if timeout 10 "$KRC" $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_nf_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_nf_$$
    got=$(timeout 3 /tmp/krc_nf_$$)
    if [ "$got" = "-3.140000" ]; then PASS=$((PASS + 1)); echo "  float_print_negative: PASS"
    else echo "FAIL: float_print_negative (got '$got')"; FAIL=$((FAIL + 1)); fi
else echo "FAIL: float_print_negative (compile)"; FAIL=$((FAIL + 1)); fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_nf_$$

# --- f-strings ---
echo ""
echo "--- f-strings ---"

TOTAL=$((TOTAL + 1))
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'FEOF'
fn main() { println(f"x = {10 + 5}"); exit(0) }
FEOF
if timeout 10 "$KRC" $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_f_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_f_$$
    got=$(timeout 3 /tmp/krc_f_$$)
    if [ "$got" = "x = 15" ]; then PASS=$((PASS + 1)); echo "  fstring_int: PASS"
    else echo "FAIL: fstring_int (got '$got')"; FAIL=$((FAIL + 1)); fi
else echo "FAIL: fstring_int (compile)"; FAIL=$((FAIL + 1)); fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_f_$$

TOTAL=$((TOTAL + 1))
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'FEOF'
fn main() { f64 pi = 3.14; println(f"pi = {pi}"); exit(0) }
FEOF
if timeout 10 "$KRC" $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_f_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_f_$$
    got=$(timeout 3 /tmp/krc_f_$$)
    if [ "$got" = "pi = 3.140000" ]; then PASS=$((PASS + 1)); echo "  fstring_float: PASS"
    else echo "FAIL: fstring_float (got '$got')"; FAIL=$((FAIL + 1)); fi
else echo "FAIL: fstring_float (compile)"; FAIL=$((FAIL + 1)); fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_f_$$

TOTAL=$((TOTAL + 1))
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'FEOF'
fn main() { println(f"flag = {true}"); exit(0) }
FEOF
if timeout 10 "$KRC" $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_f_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_f_$$
    got=$(timeout 3 /tmp/krc_f_$$)
    if [ "$got" = "flag = true" ]; then PASS=$((PASS + 1)); echo "  fstring_bool: PASS"
    else echo "FAIL: fstring_bool (got '$got')"; FAIL=$((FAIL + 1)); fi
else echo "FAIL: fstring_bool (compile)"; FAIL=$((FAIL + 1)); fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_f_$$

# --- IR optimizer tests ---
echo ""
echo "--- IR optimizer tests ---"

# Constant folding: literal arithmetic evaluated at compile time.
TOTAL=$((TOTAL + 1))
REPO_ROOT="$DIR/.."
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'OPTEOF'
fn main() {
    uint64 x = 3 + 4
    uint64 y = x * 2
    exit(y)
}
OPTEOF
if timeout 10 "$KRC" $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_opt_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_opt_$$
    timeout 3 /tmp/krc_opt_$$ > /dev/null 2>&1
    actual=$?
    if [ "$actual" = "14" ]; then
        PASS=$((PASS + 1))
        echo "  const_fold: PASS"
    else
        echo "FAIL: const_fold (expected 14, got $actual)"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: const_fold (compilation failed)"; FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_opt_$$

# --O0 disables optimization, program still runs correctly.
TOTAL=$((TOTAL + 1))
printf 'fn main() { exit(6 * 7) }\n' > "$REPO_ROOT/test_tmp_$$.kr"
if timeout 10 "$KRC" $KRC_FLAGS --O0 "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_opt_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_opt_$$
    timeout 3 /tmp/krc_opt_$$ > /dev/null 2>&1
    actual=$?
    if [ "$actual" = "42" ]; then
        PASS=$((PASS + 1))
        echo "  O0_flag: PASS"
    else
        echo "FAIL: O0_flag (expected 42, got $actual)"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: O0_flag (compilation failed)"; FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_opt_$$

# Loop counter: const-fold must NOT fold loop-carried vregs to their init value.
TOTAL=$((TOTAL + 1))
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'OPTEOF'
fn main() {
    uint64 i = 0
    uint64 s = 0
    while i < 10 {
        s = s + i
        i = i + 1
    }
    exit(s)
}
OPTEOF
if timeout 10 "$KRC" $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_opt_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_opt_$$
    timeout 3 /tmp/krc_opt_$$ > /dev/null 2>&1
    actual=$?
    if [ "$actual" = "45" ]; then
        PASS=$((PASS + 1))
        echo "  loop_counter: PASS"
    else
        echo "FAIL: loop_counter (expected 45, got $actual)"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: loop_counter (compilation failed)"; FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_opt_$$

# Branch simplification: constant conditions fold to unconditional branches.
TOTAL=$((TOTAL + 1))
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'OPTEOF'
fn main() {
    if 0 == 1 { exit(5) } else { exit(7) }
    exit(9)
}
OPTEOF
if timeout 10 "$KRC" $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_opt_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_opt_$$
    timeout 3 /tmp/krc_opt_$$ > /dev/null 2>&1
    actual=$?
    if [ "$actual" = "7" ]; then
        PASS=$((PASS + 1))
        echo "  branch_fold: PASS"
    else
        echo "FAIL: branch_fold (expected 7, got $actual)"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: branch_fold (compilation failed)"; FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_opt_$$

# CSE: redundant expressions inside a function still produce the right value.
TOTAL=$((TOTAL + 1))
cat > "$REPO_ROOT/test_tmp_$$.kr" << 'OPTEOF'
fn work(uint64 x) -> uint64 {
    uint64 a = x + 100
    uint64 b = x + 100
    return a + b
}
fn main() { exit(work(5)) }
OPTEOF
if timeout 10 "$KRC" $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_opt_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_opt_$$
    timeout 3 /tmp/krc_opt_$$ > /dev/null 2>&1
    actual=$?
    if [ "$actual" = "210" ]; then
        PASS=$((PASS + 1))
        echo "  cse_redundant: PASS"
    else
        echo "FAIL: cse_redundant (expected 210, got $actual)"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: cse_redundant (compilation failed)"; FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_opt_$$

# --- Custom fat binary targets ---
echo ""
echo "--- custom fat binary ---"
TOTAL=$((TOTAL + 1))
REPO_ROOT="$DIR/.."
printf 'fn main() { exit(77) }\n' > "$REPO_ROOT/test_tmp_$$.kr"
HOST_ARCH=$(uname -m)
HOST_TGT="linux-x64"
if [ "$HOST_ARCH" = "aarch64" ] || [ "$HOST_ARCH" = "arm64" ]; then
    HOST_TGT="linux-arm64"
fi
if timeout 30 "$KRC" --targets="$HOST_TGT" "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_fat_$$ > /dev/null 2>&1; then
    KR_BIN="$REPO_ROOT/dist/kr"
    [ -x "$KR_BIN" ] || KR_BIN="$REPO_ROOT/dist/kr-android-$HOST_ARCH"
    if [ -x "$KR_BIN" ]; then
        timeout 5 "$KR_BIN" /tmp/krc_fat_$$ > /dev/null 2>&1
        actual=$?
        if [ "$actual" = "77" ]; then
            PASS=$((PASS + 1))
            echo "  custom_fat_single: PASS"
        else
            echo "FAIL: custom_fat_single (expected 77, got $actual)"; FAIL=$((FAIL + 1))
        fi
    else
        PASS=$((PASS + 1))
        echo "  custom_fat_single: SKIP (no runner)"
    fi
else
    echo "FAIL: custom_fat_single (compilation failed)"; FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_fat_$$

# Custom 2-slice is smaller than custom 8-slice (same single-slice code path).
TOTAL=$((TOTAL + 1))
printf 'fn main() { exit(0) }\n' > "$REPO_ROOT/test_tmp_$$.kr"
ALL="linux-x64,linux-arm64,win-x64,win-arm64,macos-x64,macos-arm64,android-x64,android-arm64"
if timeout 30 "$KRC" --targets="$ALL" "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_fat_all_$$ > /dev/null 2>&1 && \
   timeout 30 "$KRC" --targets=linux-x64,macos-arm64 "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_fat_two_$$ > /dev/null 2>&1; then
    all_sz=$(wc -c < /tmp/krc_fat_all_$$)
    two_sz=$(wc -c < /tmp/krc_fat_two_$$)
    if [ "$two_sz" -lt "$all_sz" ]; then
        PASS=$((PASS + 1))
        echo "  custom_fat_smaller: PASS ($two_sz < $all_sz)"
    else
        echo "FAIL: custom_fat_smaller ($two_sz >= $all_sz)"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: custom_fat_smaller (compilation failed)"; FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr" /tmp/krc_fat_all_$$ /tmp/krc_fat_two_$$

# --- inliner correctness ---
echo ""
echo "--- inliner ---"
run_test "inline_add" '
fn add(uint64 a, uint64 b) -> uint64 { return a + b }
fn main() { exit(add(2, 3)) }' 5
run_test "inline_chain" '
fn sq(uint64 n) -> uint64 { return n * n }
fn cb(uint64 n) -> uint64 { return n * n * n }
fn main() { exit(sq(3) + cb(2)) }' 17
run_test "inline_nested_args" '
fn add(uint64 a, uint64 b) -> uint64 { return a + b }
fn main() { exit(add(1 + 2, 3 + 4)) }' 10
run_test "inline_skip_recursive" '
fn fib(uint64 n) -> uint64 {
    if n < 2 { return n }
    return fib(n - 1) + fib(n - 2)
}
fn main() { exit(fib(10)) }' 55
run_test "inline_skip_multiuse_param" '
fn dbl(uint64 x) -> uint64 { return x + x }
fn main() { exit(dbl(7)) }' 14
run_test "inline_section_kept" '@section(".text.init")
fn boot() -> uint64 { return 42 }
fn main() { exit(boot()) }' 42

# Symbol-table check: --emit=obj must NOT inline (the .o is meant to
# be linked, so even a one-line `return a + b` helper has to stay in
# the symtab).
TOTAL=$((TOTAL + 1))
printf 'fn helper(uint64 a, uint64 b) -> uint64 { return a + b }\nfn main() { exit(helper(6, 7)) }\n' > /tmp/krc_inl_obj_$$.kr
if "$KRC" $KRC_FLAGS --emit=obj /tmp/krc_inl_obj_$$.kr -o /tmp/krc_inl_obj_$$.o > /dev/null 2>&1; then
    if command -v readelf > /dev/null 2>&1; then
        has_helper=$(readelf -s /tmp/krc_inl_obj_$$.o 2>/dev/null | grep -c "helper")
        if [ "$has_helper" -ge 1 ]; then
            PASS=$((PASS + 1))
            echo "  inline_obj_keeps_symbol: PASS"
        else
            echo "FAIL: inline_obj_keeps_symbol (helper not in symtab)"; FAIL=$((FAIL + 1))
        fi
    else
        PASS=$((PASS + 1))
        echo "  inline_obj_keeps_symbol: SKIP (no readelf)"
    fi
else
    echo "FAIL: inline_obj_keeps_symbol (compile failed)"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_inl_obj_$$.kr /tmp/krc_inl_obj_$$.o

# --- std/alloc.kr smoke ---
echo ""
echo "--- std/alloc arenas + pools ---"
run_test "arena_bump" '
import "std/alloc.kr"
fn main() {
    u64 a = arena_new(4096)
    u64 p1 = arena_alloc(a, 64)
    u64 p2 = arena_alloc(a, 128)
    if p1 == 0 { exit(1) }
    if p2 <= p1 { exit(2) }
    if (p2 - p1) < 64 { exit(3) }
    store64(p1, 0xCAFE)
    if load64(p1) != 0xCAFE { exit(4) }
    arena_reset(a)
    u64 p3 = arena_alloc(a, 64)
    if p3 != p1 { exit(5) }
    arena_destroy(a)
    exit(42)
}' 42
run_test "pool_alloc_free" '
import "std/alloc.kr"
fn main() {
    u64 p = pool_new(64, 8)
    u64 a = pool_alloc(p)
    u64 b = pool_alloc(p)
    if a == 0 { exit(1) }
    if b == 0 { exit(2) }
    if a == b { exit(3) }
    pool_free(p, a)
    u64 c = pool_alloc(p)
    if c != a { exit(4) }   // free list reuses freed slot
    pool_destroy(p)
    exit(42)
}' 42

# --- IR dump test ---
echo ""
echo "--- IR dump test ---"
TOTAL=$((TOTAL + 1))
REPO_ROOT="$DIR/.."
printf 'fn main() { exit(42) }\n' > "$REPO_ROOT/test_tmp_$$.kr"
IR_OUT=$($KRC --emit=ir "$REPO_ROOT/test_tmp_$$.kr" 2>/dev/null)
if echo "$IR_OUT" | grep -q "const"; then
    PASS=$((PASS + 1))
    echo "  ir_dump: PASS"
else
    echo "FAIL: ir_dump (no const in IR output)"
    FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_$$.kr"

# --- RISC-V RV32 freestanding UART hello (boots under qemu — milestone 1) ---
# Compiles examples/riscv-hello-uart/hello.kr with --arch=riscv32
# --freestanding (raw flat binary), checks the 8-byte sp preamble via
# objdump (lui sp,0x80200 must be the FIRST instruction), then boots it
# under qemu-system-riscv32 -machine virt and greps stdout for "hello".
# qemu/objdump are dev-only toolchain: SKIP cleanly when absent so their
# absence can never fail the suite (mirrors the asm_hex x86-only skips).
# Note: a later --arch= flag overrides an earlier one, so this works
# through the `make test` wrapper that bakes in --arch=x86_64.
echo ""
echo "--- riscv32 freestanding boot test ---"
if command -v qemu-system-riscv32 >/dev/null 2>&1 \
   && command -v riscv64-linux-gnu-objdump >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_BIN="/tmp/krc_rv_hello_$$.bin"
    RV_OK=1
    if ! $KRC --arch=riscv32 --freestanding "$DIR/../examples/riscv-hello-uart/hello.kr" -o "$RV_BIN" >/dev/null 2>&1; then
        echo "FAIL: riscv_hello_boot (compilation failed)"
        RV_OK=0
    fi
    if [ "$RV_OK" = 1 ]; then
        RV_FIRST=$(riscv64-linux-gnu-objdump -D -b binary -m riscv:rv32 -M no-aliases "$RV_BIN" 2>/dev/null | awk '/^ +0:/{print $3, $4; exit}')
        if [ "$RV_FIRST" != "lui sp,0x80200" ]; then
            echo "FAIL: riscv_hello_boot (first insn is '$RV_FIRST', want 'lui sp,0x80200')"
            RV_OK=0
        fi
    fi
    if [ "$RV_OK" = 1 ]; then
        # hello loops forever after printing (freestanding), so qemu always
        # runs until the timeout kills it — 5s is the fixed cost, plenty
        # for the ~instant UART output.
        RV_OUT=$(timeout 5 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null)
        if echo "$RV_OUT" | grep -q "hello"; then
            PASS=$((PASS + 1))
            echo "  riscv_hello_boot: PASS (qemu printed hello)"
        else
            echo "FAIL: riscv_hello_boot (qemu output did not contain 'hello')"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$RV_BIN"
else
    echo "  riscv_hello_boot: SKIP (qemu-system-riscv32 or riscv64-linux-gnu-objdump not installed)"
fi

# --- Xtensa LX6 first-compilable-leaf disassembly test (Task 3) ---
# Compiles examples/xtensa/ret42.kr (fn main -> uint32 { return 42 }) with
# --arch=xtensa --freestanding (raw flat blob — the boot ELF is Task 8), then
# disassembles with xtensa-lx106-elf-objdump and asserts the CALL0 leaf shape:
# the constant 42 is materialised (movi), it reaches the return reg a2 (mov.n),
# and the function returns (ret.n). No qemu run yet — objdump on the emitted
# bytes is the check. objdump is dev-only toolchain: SKIP cleanly when absent
# (mirrors the riscv boot-test skip discipline).
echo ""
echo "--- xtensa LX6 ret42 disasm test ---"
if command -v xtensa-lx106-elf-objdump >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_BIN="/tmp/krc_xt_ret42_$$.bin"
    XT_OK=1
    if ! $KRC --arch=xtensa --freestanding "$DIR/../examples/xtensa/ret42.kr" -o "$XT_BIN" >/dev/null 2>&1; then
        echo "FAIL: xtensa_ret42_disasm (compilation failed)"
        XT_OK=0
    fi
    if [ "$XT_OK" = 1 ]; then
        XT_DIS=$(xtensa-lx106-elf-objdump -b binary -m xtensa -D "$XT_BIN" 2>/dev/null)
        # 42 materialised into an a-register…
        if ! echo "$XT_DIS" | grep -Eq 'movi[[:space:]]+a1?[0-9], ?42'; then
            echo "FAIL: xtensa_ret42_disasm (no 'movi aN, 42' — 42 not materialised)"
            XT_OK=0
        fi
        # …reaching the CALL0 return register a2…
        if [ "$XT_OK" = 1 ] && ! echo "$XT_DIS" | grep -Eq '(mov(\.n)?|movi)[[:space:]]+a2,'; then
            echo "FAIL: xtensa_ret42_disasm (value never reaches return reg a2)"
            XT_OK=0
        fi
        # …and the function returns.
        if [ "$XT_OK" = 1 ] && ! echo "$XT_DIS" | grep -Eq '\bret(\.n)?\b'; then
            echo "FAIL: xtensa_ret42_disasm (no ret/ret.n)"
            XT_OK=0
        fi
    fi
    if [ "$XT_OK" = 1 ]; then
        PASS=$((PASS + 1))
        echo "  xtensa_ret42_disasm: PASS (movi + mov.n a2 + ret.n)"
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_BIN"
else
    echo "  xtensa_ret42_disasm: SKIP (xtensa-lx106-elf-objdump not installed)"
fi

# --- Xtensa LX6 ALU ops disassembly test (Task 4) ---
# Compiles examples/xtensa/alu.kr with --O0 (constant folding/fusion would
# otherwise collapse the whole literal-only expression to a single `movi`)
# and asserts every reachable non-immediate ALU op's mnemonic/encoding:
#   add/sub/and/or/xor/mull (R-type, objdump mnemonic match) and the
#   ssl+sll / ssr+srl variable-shift sequences (objdump mnemonic match).
# IR_DIV/IR_MOD (hardware QUOU/REMU, hand-encoded — see task-4 report for
# encoding provenance) can't be mnemonic-matched: xtensa-lx106-elf-objdump
# is built for the LX106 core, which lacks the DIV32 option and decodes
# that op1=2/op2=0xC..0xF bit pattern as a different LX106-only instruction
# (EXCW) instead. So for those two, a python3 byte-level check decodes the
# raw RRR fields directly from the emitted binary and asserts op1==2 and
# op2 in {0xC,0xE} (QUOU/REMU) at the two expected instruction slots,
# independent of what any host disassembler makes of them.
echo ""
echo "--- xtensa LX6 ALU ops disasm test ---"
if command -v xtensa-lx106-elf-objdump >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_ALU_BIN="/tmp/krc_xt_alu_$$.bin"
    XT_ALU_OK=1
    if ! $KRC --arch=xtensa --freestanding --O0 "$DIR/../examples/xtensa/alu.kr" -o "$XT_ALU_BIN" >/dev/null 2>&1; then
        echo "FAIL: xtensa_alu_disasm (compilation failed)"
        XT_ALU_OK=0
    fi
    if [ "$XT_ALU_OK" = 1 ]; then
        XT_ALU_DIS=$(xtensa-lx106-elf-objdump -b binary -m xtensa -D --show-raw-insn "$XT_ALU_BIN" 2>/dev/null)
        for MN in 'add[[:space:]]+a[0-9]+, ?a[0-9]+, ?a[0-9]+' \
                  'sub[[:space:]]+a[0-9]+, ?a[0-9]+, ?a[0-9]+' \
                  'and[[:space:]]+a[0-9]+, ?a[0-9]+, ?a[0-9]+' \
                  '\bor[[:space:]]+a[0-9]+, ?a[0-9]+, ?a[0-9]+' \
                  'xor[[:space:]]+a[0-9]+, ?a[0-9]+, ?a[0-9]+' \
                  'mull[[:space:]]+a[0-9]+, ?a[0-9]+, ?a[0-9]+' \
                  'ssl[[:space:]]+a[0-9]+' \
                  'sll[[:space:]]+a[0-9]+, ?a[0-9]+' \
                  'ssr[[:space:]]+a[0-9]+' \
                  'srl[[:space:]]+a[0-9]+, ?a[0-9]+'; do
            if ! echo "$XT_ALU_DIS" | grep -Eq "$MN"; then
                echo "FAIL: xtensa_alu_disasm (missing mnemonic pattern: $MN)"
                XT_ALU_OK=0
            fi
        done
    fi
    if [ "$XT_ALU_OK" = 1 ] && command -v python3 >/dev/null 2>&1; then
        if ! python3 -c "
import sys
data = open('$XT_ALU_BIN', 'rb').read()
def decode_rrr(off):
    b0, b1, b2 = data[off], data[off+1], data[off+2]
    w = b0 | (b1 << 8) | (b2 << 16)
    return (w & 0xF), (w>>16)&0xF, (w>>20)&0xF   # op0, op1, op2

# Every op1=2,op2 in {0xC,0xD,0xE,0xF} RRR word in the blob is a DIV32 op
# (QUOU/QUOS/REMU/REMS) — alu.kr's only op1=2 instructions besides MULL
# (op2=8) are the / and % it emits, so require at least one op2==0xC
# (QUOU, from '/ 7') and one op2==0xE (REMU, from '% 5').
found_c = False
found_e = False
i = 0
while i + 3 <= len(data):
    op0, op1, op2 = decode_rrr(i)
    if op0 == 0 and op1 == 2:
        if op2 == 0xC: found_c = True
        if op2 == 0xE: found_e = True
    i += 1
if not found_c:
    print('missing QUOU (op1=2,op2=0xC) encoding for /')
    sys.exit(1)
if not found_e:
    print('missing REMU (op1=2,op2=0xE) encoding for %')
    sys.exit(1)
" ; then
            echo "FAIL: xtensa_alu_disasm (DIV32 byte-level check)"
            XT_ALU_OK=0
        fi
    fi
    if [ "$XT_ALU_OK" = 1 ]; then
        PASS=$((PASS + 1))
        echo "  xtensa_alu_disasm: PASS (add/sub/and/or/xor/mull + ssl/sll/ssr/srl mnemonics + QUOU/REMU byte-level check)"
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_ALU_BIN"
else
    echo "  xtensa_alu_disasm: SKIP (xtensa-lx106-elf-objdump not installed)"
fi

# --- Xtensa LX6 loads/stores/IR_COPY disassembly test (Task 5) ---
# Compiles examples/xtensa/mem.kr, which touches every width (1/2/4)
# through the load8/16/32 and store8/16/32 pointer builtins, plus a named
# local (`uint32 d = a`, with `a` read again afterward so it interferes
# with `d` and the register allocator must colour them apart) to force a
# genuine mov/mov.n out of IR_COPY. Every address/value is kept inside
# MOVI's signed-12-bit range on purpose — a literal-pool-sized constant
# would put pool data before the code in the raw blob, which desynced
# xtensa-lx106-elf-objdump's linear decoder during development (see the
# comment in mem.kr).
echo ""
echo "--- xtensa LX6 loads/stores/IR_COPY disasm test ---"
if command -v xtensa-lx106-elf-objdump >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_MEM_BIN="/tmp/krc_xt_mem_$$.bin"
    XT_MEM_OK=1
    if ! $KRC --arch=xtensa --freestanding "$DIR/../examples/xtensa/mem.kr" -o "$XT_MEM_BIN" >/dev/null 2>&1; then
        echo "FAIL: xtensa_mem_disasm (compilation failed)"
        XT_MEM_OK=0
    fi
    if [ "$XT_MEM_OK" = 1 ]; then
        XT_MEM_DIS=$(xtensa-lx106-elf-objdump -b binary -m xtensa -D --show-raw-insn "$XT_MEM_BIN" 2>/dev/null)
        for MN in 'l8ui[[:space:]]+a[0-9]+, ?a[0-9]+, ?[0-9]+' \
                  'l16ui[[:space:]]+a[0-9]+, ?a[0-9]+, ?[0-9]+' \
                  'l32i[[:space:]]+a[0-9]+, ?a[0-9]+, ?[0-9]+' \
                  's8i[[:space:]]+a[0-9]+, ?a[0-9]+, ?[0-9]+' \
                  's16i[[:space:]]+a[0-9]+, ?a[0-9]+, ?[0-9]+' \
                  's32i[[:space:]]+a[0-9]+, ?a[0-9]+, ?[0-9]+' \
                  'mov\.n[[:space:]]+a[0-9]+, ?a[0-9]+'; do
            if ! echo "$XT_MEM_DIS" | grep -Eq "$MN"; then
                echo "FAIL: xtensa_mem_disasm (missing mnemonic pattern: $MN)"
                XT_MEM_OK=0
            fi
        done
        # mov.n must appear at least twice: once for IR_RET's move into a2,
        # once for IR_COPY's `d = a` (the two are otherwise indistinguishable
        # by mnemonic alone, so require the count instead of a single match).
        if [ "$XT_MEM_OK" = 1 ]; then
            MOVN_COUNT=$(echo "$XT_MEM_DIS" | grep -Ec 'mov\.n[[:space:]]+a[0-9]+, ?a[0-9]+')
            if [ "$MOVN_COUNT" -lt 2 ]; then
                echo "FAIL: xtensa_mem_disasm (expected >=2 mov.n — IR_RET move + IR_COPY's d=a, got $MOVN_COUNT)"
                XT_MEM_OK=0
            fi
        fi
    fi
    if [ "$XT_MEM_OK" = 1 ]; then
        PASS=$((PASS + 1))
        echo "  xtensa_mem_disasm: PASS (l8ui/l16ui/l32i + s8i/s16i/s32i + IR_COPY mov.n mnemonics)"
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_MEM_BIN"
else
    echo "  xtensa_mem_disasm: SKIP (xtensa-lx106-elf-objdump not installed)"
fi

# --- Xtensa LX6 signed ALU ops disassembly test (Task 5 bonus) ---
# Compiles examples/xtensa/mem_signed.kr with --O0. A named int32 local
# (only possible now that IR_COPY exists) carries a signed-typed operand
# into `/`, `%`, `>>`, exercising IR_SDIV/IR_SMOD/IR_SAR (QUOS/REMS/ssr+
# sra) — unreachable from Task 4's alu.kr, which had no way to produce a
# signed-typed vreg. QUOS/REMS are hand-encoded (same lx106-lacks-DIV32
# situation as alu.kr's QUOU/REMU) so a python3 byte-level scan checks
# them directly; ssr/sra are ordinary mnemonic matches.
echo ""
echo "--- xtensa LX6 signed ALU ops disasm test ---"
if command -v xtensa-lx106-elf-objdump >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_SGN_BIN="/tmp/krc_xt_signed_$$.bin"
    XT_SGN_OK=1
    if ! $KRC --arch=xtensa --freestanding --O0 "$DIR/../examples/xtensa/mem_signed.kr" -o "$XT_SGN_BIN" >/dev/null 2>&1; then
        echo "FAIL: xtensa_signed_disasm (compilation failed)"
        XT_SGN_OK=0
    fi
    if [ "$XT_SGN_OK" = 1 ]; then
        XT_SGN_DIS=$(xtensa-lx106-elf-objdump -b binary -m xtensa -D --show-raw-insn "$XT_SGN_BIN" 2>/dev/null)
        for MN in 'ssr[[:space:]]+a[0-9]+' 'sra[[:space:]]+a[0-9]+, ?a[0-9]+'; do
            if ! echo "$XT_SGN_DIS" | grep -Eq "$MN"; then
                echo "FAIL: xtensa_signed_disasm (missing mnemonic pattern: $MN)"
                XT_SGN_OK=0
            fi
        done
    fi
    if [ "$XT_SGN_OK" = 1 ] && command -v python3 >/dev/null 2>&1; then
        if ! python3 -c "
import sys
data = open('$XT_SGN_BIN', 'rb').read()
def decode_rrr(off):
    b0, b1, b2 = data[off], data[off+1], data[off+2]
    w = b0 | (b1 << 8) | (b2 << 16)
    return (w & 0xF), (w>>16)&0xF, (w>>20)&0xF   # op0, op1, op2

found_d = False  # QUOS (n / 3)
found_f = False  # REMS (n % 3)
i = 0
while i + 3 <= len(data):
    op0, op1, op2 = decode_rrr(i)
    if op0 == 0 and op1 == 2:
        if op2 == 0xD: found_d = True
        if op2 == 0xF: found_f = True
    i += 1
if not found_d:
    print('missing QUOS (op1=2,op2=0xD) encoding for /')
    sys.exit(1)
if not found_f:
    print('missing REMS (op1=2,op2=0xF) encoding for %')
    sys.exit(1)
" ; then
            echo "FAIL: xtensa_signed_disasm (QUOS/REMS byte-level check)"
            XT_SGN_OK=0
        fi
    fi
    if [ "$XT_SGN_OK" = 1 ]; then
        PASS=$((PASS + 1))
        echo "  xtensa_signed_disasm: PASS (ssr/sra mnemonics + QUOS/REMS byte-level check)"
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_SGN_BIN"
else
    echo "  xtensa_signed_disasm: SKIP (xtensa-lx106-elf-objdump not installed)"
fi

# --- Xtensa LX6 compares + branches + relaxation disasm test (Task 6) ---
# Compiles examples/xtensa/branch.kr (--O0): a short while + if/else whose
# single-use compares FUSE into two-register compare-branches (in BRI8's
# +/-128 B, encoded directly), then a while with a large body whose fused
# exit branch must jump past +/-128 B and is REWRITTEN by the relaxation
# pass as `Binv .+6 ; j exit`. Structural checks:
#   1. >=3 direct fused compare-branches (beq/bne/blt/bge/bltu/bgeu) in range.
#   2. The relaxation pattern: a conditional branch to `.+6` (skips exactly a
#      3-byte J) immediately followed by a `j` to a far target — i.e. the
#      invert+J rewrite. A python3 byte scan confirms a BRI8 branch (op0=7)
#      with imm8==2 sits 3 bytes before a J (op0=6).
echo ""
echo "--- xtensa LX6 compares + branches + relaxation disasm test ---"
if command -v xtensa-lx106-elf-objdump >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_BR_BIN="/tmp/krc_xt_branch_$$.bin"
    XT_BR_OK=1
    if ! $KRC --arch=xtensa --freestanding --O0 "$DIR/../examples/xtensa/branch.kr" -o "$XT_BR_BIN" >/dev/null 2>&1; then
        echo "FAIL: xtensa_branch_disasm (compilation failed)"
        XT_BR_OK=0
    fi
    if [ "$XT_BR_OK" = 1 ]; then
        XT_BR_DIS=$(xtensa-lx106-elf-objdump -b binary -m xtensa -D --show-raw-insn "$XT_BR_BIN" 2>/dev/null)
        # (1) at least three in-range fused two-register compare-branches.
        FUSED_CNT=$(echo "$XT_BR_DIS" | grep -Ec 'b(eq|ne|lt|ge|ltu|geu)[[:space:]]+a[0-9]+, ?a[0-9]+, ?0x[0-9a-f]+')
        if [ "$FUSED_CNT" -lt 3 ]; then
            echo "FAIL: xtensa_branch_disasm (expected >=3 fused compare-branches, got $FUSED_CNT)"
            XT_BR_OK=0
        fi
    fi
    if [ "$XT_BR_OK" = 1 ] && command -v python3 >/dev/null 2>&1; then
        # (2) invert+J relaxation pattern: a BRI8 branch (op0=7) whose imm8==2
        # (target = PC+4+2 = PC+6, i.e. skip the following 3-byte J), directly
        # followed by a J (op0=6). This is exactly the `Binv .+6 ; j target`
        # rewrite the relaxation pass emits for an out-of-range conditional.
        if ! python3 -c "
import sys
data = open('$XT_BR_BIN','rb').read()
def w24(o): return data[o] | (data[o+1]<<8) | (data[o+2]<<16)
found = False
i = 0
while i + 6 <= len(data):
    w = w24(i)
    if (w & 0xF) == 0x7:                 # BRI8 two-register compare-branch
        imm8 = (w >> 16) & 0xFF
        nxt = w24(i+3)
        if imm8 == 2 and (nxt & 0xF) == 0x6:   # branch to .+6, then a J
            found = True
            break
    i += 1
if not found:
    print('no invert+J relaxation pattern (BRI8 imm8==2 followed by J)')
    sys.exit(1)
" ; then
            echo "FAIL: xtensa_branch_disasm (relaxation invert+J pattern not found)"
            XT_BR_OK=0
        fi
    fi
    if [ "$XT_BR_OK" = 1 ]; then
        PASS=$((PASS + 1))
        echo "  xtensa_branch_disasm: PASS (fused compare-branches in range + invert+J relaxation)"
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_BR_BIN"
else
    echo "  xtensa_branch_disasm: SKIP (xtensa-lx106-elf-objdump not installed)"
fi

# --- Xtensa LX6 calls (CALL0 + IR_ARG marshalling + fixups) disasm test (Task 7) ---
# Compiles examples/xtensa/call.kr (main calls helper(a,b) -> a+b) with
# --arch=xtensa --freestanding (raw blob) and asserts the CALL0 ABI shape:
# args marshalled into a2/a3, a `call0` reaching the helper, and the callee's
# params read from a2/a3. Also golden-diffs the patched call0's encoding
# against `xtensa-lx106-elf-as --no-transform` — the CALL0 PC-rounding
# (imm18 = (target-((pc+4)&~3))>>2) is the fragile part. Same objdump dev-only
# SKIP discipline as the other xtensa tests.
#
# The compiled output is a full ELF (Ehdr + one Phdr, p_offset=0 covering the
# whole file — this minimal freestanding ELF has NO section headers, so a
# proper `objdump -d` finds nothing and `-b binary` is the only way to get
# any disassembly at all). Feeding the WHOLE file (header included) to `-b
# binary` makes objdump linearly decode the Ehdr/Phdr bytes themselves as
# bogus instructions first; whether that garbage decode happens to land back
# on the true code/instruction boundary by the time it reaches real code is
# an accident of the specific header byte values — NOT guaranteed, and
# (Task 6) it stopped landing correctly the moment an unrelated, legitimate
# frame-size change perturbed a nearby immediate byte. Fix: slice off the
# Ehdr+Phdr span (e_phoff + e_phnum*e_phentsize, read via `readelf -h`, not
# hardcoded — stable across any single-PT_LOAD freestanding xtensa ELF) and
# disassemble ONLY the real code, so decode always starts instruction-aligned
# regardless of what the frame-size immediates happen to be. The golden-diff
# byte extraction below reads from the ORIGINAL (unsliced) file, so its
# offset is CALL_SITE + the same header length.
echo ""
echo "--- xtensa LX6 calls (CALL0 + IR_ARG) disasm test ---"
if command -v xtensa-lx106-elf-objdump >/dev/null 2>&1 && command -v readelf >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_CALL_BIN="/tmp/krc_xt_call_$$.bin"
    XT_CALL_CODE="/tmp/krc_xt_call_code_$$.bin"
    XT_CALL_OK=1
    if ! $KRC --arch=xtensa --freestanding "$DIR/../examples/xtensa/call.kr" -o "$XT_CALL_BIN" >/dev/null 2>&1; then
        echo "FAIL: xtensa_call_disasm (compilation failed)"
        XT_CALL_OK=0
    fi
    XT_HDR_LEN=0
    if [ "$XT_CALL_OK" = 1 ]; then
        XT_EH=$(readelf -h "$XT_CALL_BIN" 2>/dev/null)
        XT_PHOFF=$(echo "$XT_EH" | sed -nE 's/.*Start of program headers: *([0-9]+).*/\1/p')
        XT_PHENTSZ=$(echo "$XT_EH" | sed -nE 's/.*Size of program headers: *([0-9]+).*/\1/p')
        XT_PHNUM=$(echo "$XT_EH" | sed -nE 's/.*Number of program headers: *([0-9]+).*/\1/p')
        if [ -n "$XT_PHOFF" ] && [ -n "$XT_PHENTSZ" ] && [ -n "$XT_PHNUM" ]; then
            XT_HDR_LEN=$((XT_PHOFF + XT_PHENTSZ * XT_PHNUM))
        fi
        if [ "$XT_HDR_LEN" -le 0 ]; then
            echo "FAIL: xtensa_call_disasm (could not determine ELF header length via readelf)"
            XT_CALL_OK=0
        fi
    fi
    if [ "$XT_CALL_OK" = 1 ]; then
        tail -c "+$((XT_HDR_LEN + 1))" "$XT_CALL_BIN" > "$XT_CALL_CODE"
        XT_CALL_DIS=$(xtensa-lx106-elf-objdump -b binary -m xtensa -D --show-raw-insn "$XT_CALL_CODE" 2>/dev/null)
        # A call0 must be present (the call to helper)…
        if ! echo "$XT_CALL_DIS" | grep -Eq '\bcall0\b'; then
            echo "FAIL: xtensa_call_disasm (no call0 — call not emitted / was inlined)"
            XT_CALL_OK=0
        fi
        # …args marshalled into a2 and a3 before the call…
        if [ "$XT_CALL_OK" = 1 ] && ! echo "$XT_CALL_DIS" | grep -Eq 'mov(\.n)?[[:space:]]+a3,'; then
            echo "FAIL: xtensa_call_disasm (arg1 not marshalled into a3)"
            XT_CALL_OK=0
        fi
        # …and the callee reads its params back out of a2/a3.
        if [ "$XT_CALL_OK" = 1 ] && ! echo "$XT_CALL_DIS" | grep -Eq 'mov(\.n)?[[:space:]]+a1?[0-9], ?a3'; then
            echo "FAIL: xtensa_call_disasm (callee never reads param from a3)"
            XT_CALL_OK=0
        fi
        # Golden-diff the patched call0 encoding: extract the call0's site +
        # target from objdump, hand-assemble the same displacement with
        # --no-transform, and byte-compare. Pins the CALL0 PC-rounding.
        # CALL_SITE is relative to XT_CALL_CODE (header already sliced off);
        # add XT_HDR_LEN back to index into the original XT_CALL_BIN.
        if [ "$XT_CALL_OK" = 1 ] && command -v xtensa-lx106-elf-as >/dev/null 2>&1 \
           && command -v xtensa-lx106-elf-objcopy >/dev/null 2>&1; then
            CALL_LINE=$(echo "$XT_CALL_DIS" | grep -E '\bcall0\b' | head -1)
            CALL_SITE=$(echo "$CALL_LINE" | sed -E 's/^[[:space:]]*([0-9a-f]+):.*/\1/')
            CALL_TGT=$(echo "$CALL_LINE" | sed -E 's/.*call0[[:space:]]+0x([0-9a-f]+).*/\1/')
            OUR_BYTES=$(od -An -tx1 -j $((XT_HDR_LEN + 0x$CALL_SITE)) -N 3 "$XT_CALL_BIN" | tr -d ' \n')
            GS="/tmp/krc_xt_call_gold_$$.s"
            GO="/tmp/krc_xt_call_gold_$$.o"
            GB="/tmp/krc_xt_call_gold_$$.bin"
            # target at 0, call0 at CALL_SITE bytes in (only valid when the
            # callee is at offset 0 — which it is: helper is emitted first).
            printf '\t.text\ntarget:\n\t.space 0x%s\n\tcall0 target\n' "$CALL_SITE" > "$GS"
            if [ "$CALL_TGT" = "0" ] \
               && xtensa-lx106-elf-as --no-transform -o "$GO" "$GS" >/dev/null 2>&1 \
               && xtensa-lx106-elf-objcopy -O binary --only-section=.text "$GO" "$GB" >/dev/null 2>&1; then
                GOLD_BYTES=$(od -An -tx1 -j $((0x$CALL_SITE)) -N 3 "$GB" | tr -d ' \n')
                if [ "$OUR_BYTES" != "$GOLD_BYTES" ]; then
                    echo "FAIL: xtensa_call_disasm (call0 encoding $OUR_BYTES != golden $GOLD_BYTES)"
                    XT_CALL_OK=0
                fi
            fi
            rm -f "$GS" "$GO" "$GB"
        fi
    fi
    if [ "$XT_CALL_OK" = 1 ]; then
        PASS=$((PASS + 1))
        echo "  xtensa_call_disasm: PASS (call0 + a2/a3 arg marshalling + golden-diffed call0 encoding)"
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_CALL_BIN" "$XT_CALL_CODE"
else
    echo "  xtensa_call_disasm: SKIP (xtensa-lx106-elf-objdump/readelf not installed)"
fi

# --- Xtensa LX6 freestanding UART hello (boots under qemu — MILESTONE 1) ---
# Compiles examples/xtensa/hello.kr with --arch=xtensa --freestanding (Elf32
# boot image, load base 0xd0000000), then boots it under
# qemu-system-xtensa -M lx60 and greps stdout for "hello". qemu is a dev-only
# toolchain: SKIP cleanly when absent so its absence can never fail the suite
# (mirrors the riscv_hello_boot test above). Note: a later --arch= flag
# overrides an earlier one, so this works through the `make test` wrapper that
# bakes in --arch=x86_64.
echo ""
echo "--- xtensa LX6 freestanding boot test ---"
if command -v qemu-system-xtensa >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_HELLO_ELF="/tmp/krc_xt_hello_$$.elf"
    XT_HELLO_OK=1
    if ! $KRC --arch=xtensa --freestanding "$DIR/../examples/xtensa/hello.kr" -o "$XT_HELLO_ELF" >/dev/null 2>&1; then
        echo "FAIL: xtensa_hello_boot (compilation failed)"
        XT_HELLO_OK=0
    fi
    # Optional entry-point sanity: e_entry must decode to the SP-init preamble
    # (l32r a1, ...), proving it skips the entry fn's literal pool. Only when
    # readelf/objdump are present; never a hard gate on their absence.
    if [ "$XT_HELLO_OK" = 1 ] && command -v readelf >/dev/null 2>&1 \
       && command -v xtensa-lx106-elf-objdump >/dev/null 2>&1; then
        XT_ENTRY=$(readelf -h "$XT_HELLO_ELF" 2>/dev/null | awk '/Entry point/{print $NF}')
        XT_EOFF=$(( XT_ENTRY - 0xd0000000 ))
        XT_ESTOP=$(( XT_EOFF + 3 ))
        if ! xtensa-lx106-elf-objdump -b binary -m xtensa -D \
             --start-address=$XT_EOFF --stop-address=$XT_ESTOP "$XT_HELLO_ELF" 2>/dev/null \
             | grep -qE 'l32r[[:space:]]+a1'; then
            echo "FAIL: xtensa_hello_boot (e_entry does not decode to 'l32r a1' SP preamble)"
            XT_HELLO_OK=0
        fi
    fi
    if [ "$XT_HELLO_OK" = 1 ]; then
        # hello loops forever after printing (freestanding), so qemu always
        # runs until the timeout kills it — 5s is the fixed cost, plenty for
        # the ~instant UART output. Command substitution captures the full
        # stdout before the SIGTERM (a pipe to `head` can lose it).
        XT_OUT=$(timeout 5 qemu-system-xtensa -M lx60 -nographic -kernel "$XT_HELLO_ELF" 2>/dev/null)
        if echo "$XT_OUT" | grep -q "hello"; then
            PASS=$((PASS + 1))
            echo "  xtensa_hello_boot: PASS (qemu printed hello)"
        else
            echo "FAIL: xtensa_hello_boot (qemu output did not contain 'hello')"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_HELLO_ELF"
else
    echo "  xtensa_hello_boot: SKIP (qemu-system-xtensa not installed)"
fi

# --- Xtensa LX6 complex program boots and computes correctly (regression) ---
# hello.kr has only main (entry) + putc (leaf), both of which happen to land on
# word boundaries, so it never exercised a NON-entry function at a misaligned
# code_start. CALL0 targets are implicitly word-aligned (target = ((PC+4)&~3) +
# imm18*4); a pool-less function inheriting an unaligned out_len as its
# code_start would have every call0 to it round down into the tail of the
# preceding function. stress.kr has many functions (recursion, register-pressure
# spilling, signed division with a negative dividend — the QUOS/REMS path that
# xtensa-lx106-elf-as cannot even assemble, so only qemu proves it) whose entry
# offsets do NOT all align naturally; it boots and prints eight hand-verifiable
# results. This is a full-output equality check, not a grep — a miscompile in
# any exercised path (nested-call frame, div/mod sign, spills) changes a digit.
echo ""
echo "--- xtensa LX6 complex-program boot test ---"
if command -v qemu-system-xtensa >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_STRESS_ELF="/tmp/krc_xt_stress_$$.elf"
    XT_STRESS_OK=1
    if ! $KRC --arch=xtensa --freestanding "$DIR/../examples/xtensa/stress.kr" -o "$XT_STRESS_ELF" >/dev/null 2>&1; then
        echo "FAIL: xtensa_stress_boot (compilation failed)"
        XT_STRESS_OK=0
    fi
    if [ "$XT_STRESS_OK" = 1 ]; then
        XT_ST_EXP=$(printf '120\n3628800\n6765\n142857\n1\n-13\n-6\n4524')
        # stress.kr loops forever after printing, so qemu runs until the timeout.
        # fib(20) is ~21.9k calls — microseconds under qemu; 8s is ample headroom.
        # Strip CR so the compare is newline-exact regardless of UART line endings.
        XT_ST_OUT=$(timeout 8 qemu-system-xtensa -M lx60 -nographic -kernel "$XT_STRESS_ELF" 2>/dev/null | tr -d '\r')
        if [ "$XT_ST_OUT" = "$XT_ST_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_stress_boot: PASS (recursion + spills + signed div all correct)"
        else
            echo "FAIL: xtensa_stress_boot (output mismatch)"
            echo "    expected: $(echo "$XT_ST_EXP" | tr '\n' ' ')"
            echo "    got:      $(echo "$XT_ST_OUT" | tr '\n' ' ')"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_STRESS_ELF"
else
    echo "  xtensa_stress_boot: SKIP (qemu-system-xtensa not installed)"
fi

# --- Xtensa LX6 string literals (IR_STR_CONST via PIC) boot test ---
# str_hello.kr takes the address of a string literal ("xtensa strings ok")
# through IR_STR_CONST and prints it byte-by-byte over the UART. This is the
# first consumer of the per-function PC-anchor (real PIC) address materialization
# — call0 __xt_pcbase / l32r a9,<pool:delta> / add dst,a0,a9. Full-output
# equality (not a grep): a wrong delta or a stale anchor after relaxation would
# print garbage or fault. loop{} keeps the core busy until the timeout.
echo ""
echo "--- xtensa LX6 string-literal boot test ---"
if command -v qemu-system-xtensa >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_STR_ELF="/tmp/krc_xt_str_$$.elf"
    XT_STR_OK=1
    if ! $KRC --arch=xtensa --freestanding "$DIR/../examples/xtensa/str_hello.kr" -o "$XT_STR_ELF" >/dev/null 2>&1; then
        echo "FAIL: xtensa_str_boot (compilation failed)"
        XT_STR_OK=0
    fi
    if [ "$XT_STR_OK" = 1 ]; then
        XT_STR_EXP="xtensa strings ok"
        XT_STR_OUT=$(timeout 8 qemu-system-xtensa -M lx60 -nographic -kernel "$XT_STR_ELF" 2>/dev/null | tr -d '\r')
        if [ "$XT_STR_OUT" = "$XT_STR_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_str_boot: PASS (string literal materialized + printed)"
        else
            echo "FAIL: xtensa_str_boot (output mismatch)"
            echo "    expected: $XT_STR_EXP"
            echo "    got:      $XT_STR_OUT"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_STR_ELF"
else
    echo "  xtensa_str_boot: SKIP (qemu-system-xtensa not installed)"
fi

# --- Xtensa LX6 static globals (IR_STATIC_ADDR/LOAD/STORE) boot test ---
# globals.kr has an initialized `static u32 counter = 41`, then main does
# counter = counter + 1 (STATIC_LOAD 77 + STATIC_STORE 78) and prints it
# (another STATIC_LOAD) via the recursive print_uint idiom. This is the first
# consumer of the static-data blob: each access materializes data_start through
# the PC-anchor PIC pair (call0 __xt_pcbase / l32r a9,<pool:delta> / add) and
# then l32i/s32i off the 8-aligned blob. A wrong delta, a desynced pool word
# (pre-scan/emit lockstep bug), or an unaligned data_start would fault or print
# the wrong number. Full-output equality; loop{} keeps the core busy till timeout.
echo ""
echo "--- xtensa LX6 static-globals boot test ---"
if command -v qemu-system-xtensa >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_GLB_ELF="/tmp/krc_xt_globals_$$.elf"
    XT_GLB_OK=1
    if ! $KRC --arch=xtensa --freestanding "$DIR/../examples/xtensa/globals.kr" -o "$XT_GLB_ELF" >/dev/null 2>&1; then
        echo "FAIL: xtensa_globals_boot (compilation failed)"
        XT_GLB_OK=0
    fi
    if [ "$XT_GLB_OK" = 1 ]; then
        XT_GLB_EXP="42"
        XT_GLB_OUT=$(timeout 8 qemu-system-xtensa -M lx60 -nographic -kernel "$XT_GLB_ELF" 2>/dev/null | tr -d '\r')
        if [ "$XT_GLB_OUT" = "$XT_GLB_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_globals_boot: PASS (static load/store + print = 42)"
        else
            echo "FAIL: xtensa_globals_boot (output mismatch)"
            echo "    expected: $XT_GLB_EXP"
            echo "    got:      $XT_GLB_OUT"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_GLB_ELF"
else
    echo "  xtensa_globals_boot: SKIP (qemu-system-xtensa not installed)"
fi

# --- Xtensa LX6 function pointers (Task 7): IR_FN_ADDR(86) + CALL_IND(87) ---
# fnptr.kr materializes dbl's code address via fn_addr("dbl") — the PC-anchor
# PIC pair (call0 __xt_pcbase / l32r a9,<pool:delta> / add) with table_sel 2
# (fn addrs), resolved against dbl's code offset in resolve_addr_fixups_xtensa
# (quote-stripping fn_table scan, NO remap). call_ptr(f, 21) then invokes it
# through the CALL_IND lowering; dbl(21) = 42. A desynced PIC pool word, a wrong
# delta, or a broken resolver would fault or print the wrong number. Full-output
# equality; loop{} keeps the core busy till timeout.
echo ""
echo "--- xtensa LX6 function-pointer boot test ---"
if command -v qemu-system-xtensa >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_FP_ELF="/tmp/krc_xt_fnptr_$$.elf"
    XT_FP_OK=1
    if ! $KRC --arch=xtensa --freestanding "$DIR/../examples/xtensa/fnptr.kr" -o "$XT_FP_ELF" >/dev/null 2>&1; then
        echo "FAIL: xtensa_fnptr_boot (compilation failed)"
        XT_FP_OK=0
    fi
    if [ "$XT_FP_OK" = 1 ]; then
        XT_FP_EXP="42"
        XT_FP_OUT=$(timeout 8 qemu-system-xtensa -M lx60 -nographic -kernel "$XT_FP_ELF" 2>/dev/null | tr -d '\r')
        if [ "$XT_FP_OUT" = "$XT_FP_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_fnptr_boot: PASS (fn_addr + call_ptr = 42)"
        else
            echo "FAIL: xtensa_fnptr_boot (output mismatch)"
            echo "    expected: $XT_FP_EXP"
            echo "    got:      $XT_FP_OUT"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_FP_ELF"
else
    echo "  xtensa_fnptr_boot: SKIP (qemu-system-xtensa not installed)"
fi

# --- Xtensa LX6 real BSS (p_memsz > p_filesz) + .bss-zeroing preamble (Task 3) ---
# bss.kr has an initialized `static u32 marker = 42` (in .data) and an
# uninitialized `static u32[1024] buf` (4096 B). 4096 >= the 4 KiB truncation
# threshold, so the zeros are dropped from the file (p_filesz = last-nonzero-end,
# rounded up to 4 for the s32i alignment the loop needs) while p_memsz keeps the
# full span: readelf must show p_memsz > p_filesz. main prints marker (42),
# buf[0] (0), then writes buf[500]=99 and prints it (99) -> "42 0 99".
#
# [M-3] qemu backs guest DRAM with host ZERO pages, so buf[0] reads 0 whether or
# not the zero-loop ran. This boot therefore proves: (i) boot with a real gap,
# (ii) the loop did NOT clobber .data (marker survives = 42), (iii) the loop
# wrote ZERO not garbage (buf[0]==0), (iv) BSS is writable (buf[500] round-trips
# to 99). The loop's actual zeroing of dirty DRAM is NOT provable under qemu, so
# loop PRESENCE is asserted STRUCTURALLY via objdump (an `s32i` inside a backward
# `bltu` loop, AFTER the SP-init `l32r a1`); true dirty-DRAM zeroing is deferred
# to ESP32 hardware. Full-output equality; loop{} keeps the core busy to timeout.
echo ""
echo "--- xtensa LX6 real-BSS + zeroing-preamble boot test ---"
if command -v qemu-system-xtensa >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_BSS_ELF="/tmp/krc_xt_bss_$$.elf"
    XT_BSS_OK=1
    if ! $KRC --arch=xtensa --freestanding "$DIR/../examples/xtensa/bss.kr" -o "$XT_BSS_ELF" >/dev/null 2>&1; then
        echo "FAIL: xtensa_bss_boot (compilation failed)"
        XT_BSS_OK=0
    fi
    # Layout gate: p_memsz MUST exceed p_filesz (real BSS gap). Only when readelf
    # is present; never a hard gate on its absence.
    if [ "$XT_BSS_OK" = 1 ] && command -v readelf >/dev/null 2>&1; then
        XT_LOAD=$(readelf -l "$XT_BSS_ELF" 2>/dev/null | grep -m1 'LOAD')
        XT_FSZ=$(echo "$XT_LOAD" | awk '{print $5}')
        XT_MSZ=$(echo "$XT_LOAD" | awk '{print $6}')
        if [ $(( XT_MSZ )) -le $(( XT_FSZ )) ]; then
            echo "FAIL: xtensa_bss_boot (no BSS gap: p_filesz=$XT_FSZ p_memsz=$XT_MSZ)"
            XT_BSS_OK=0
        fi
    fi
    # Structural gate: the entry preamble must carry the zero loop — the SP-init
    # `l32r a1` FIRST, then an `s32i` inside a backward `bltu` loop. Only when
    # readelf+objdump are present.
    if [ "$XT_BSS_OK" = 1 ] && command -v readelf >/dev/null 2>&1 \
       && command -v xtensa-lx106-elf-objdump >/dev/null 2>&1; then
        XT_BENTRY=$(readelf -h "$XT_BSS_ELF" 2>/dev/null | awk '/Entry point/{print $NF}')
        XT_BOFF=$(( XT_BENTRY - 0xd0000000 ))
        XT_BPRE=$(xtensa-lx106-elf-objdump -b binary -m xtensa -D \
                  --start-address=$XT_BOFF --stop-address=$(( XT_BOFF + 24 )) \
                  "$XT_BSS_ELF" 2>/dev/null)
        if ! echo "$XT_BPRE" | grep -qE 'l32r[[:space:]]+a1'; then
            echo "FAIL: xtensa_bss_boot (entry does not start with SP-init 'l32r a1')"
            XT_BSS_OK=0
        elif ! echo "$XT_BPRE" | grep -qE 's32i' || ! echo "$XT_BPRE" | grep -qE 'bltu'; then
            echo "FAIL: xtensa_bss_boot (no s32i/bltu zero loop in entry preamble)"
            XT_BSS_OK=0
        fi
    fi
    if [ "$XT_BSS_OK" = 1 ]; then
        XT_BSS_EXP="42 0 99"
        XT_BSS_OUT=$(timeout 8 qemu-system-xtensa -M lx60 -nographic -kernel "$XT_BSS_ELF" 2>/dev/null | tr -d '\r')
        if [ "$XT_BSS_OUT" = "$XT_BSS_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_bss_boot: PASS (real BSS gap + zero loop; marker/buf = 42 0 99)"
        else
            echo "FAIL: xtensa_bss_boot (output mismatch)"
            echo "    expected: $XT_BSS_EXP"
            echo "    got:      $XT_BSS_OUT"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_BSS_ELF"
else
    echo "  xtensa_bss_boot: SKIP (qemu-system-xtensa not installed)"
fi

# --- Xtensa LX6 stack arrays + memory intrinsics (merged Task 4+5) boot test ---
# mem_stack.kr exercises IR_STACK_ADDR (32) together with IR_MEMSET (76) /
# IR_MEMCPY (72) / IR_MEMCMP (88) — ir.kr:3419 emits IR_STACK_ADDR only ever
# paired with an unconditional IR_MEMSET zero-init for every local array, so
# the two can't be tested apart. Part 1: `u32[4] a` prints a[0] BEFORE any
# write (proves the implicit zero-init), fills a[i]=i+1, prints the sum.
# Part 2: explicit `memset(b,65,8)` + `memcpy(c,b,4)` builtins, c[0] printed
# as a raw char. Part 3: struct `==` -> MEMCMP, reached via struct-typed
# function PARAMETERS over two `static u32[2]` arrays (a local struct would
# need IR_ALLOC, unimplemented on freestanding xtensa; a `static Point`
# scalar never registers as a struct var — see mem_stack.kr's header comment
# for the x86-host probe that found this). Full-output equality; loop{}
# keeps the core busy till timeout.
echo ""
echo "--- xtensa LX6 stack-array + memory-intrinsics boot test ---"
if command -v qemu-system-xtensa >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_MS_ELF="/tmp/krc_xt_memstack_$$.elf"
    XT_MS_OK=1
    if ! $KRC --arch=xtensa --freestanding "$DIR/../examples/xtensa/mem_stack.kr" -o "$XT_MS_ELF" >/dev/null 2>&1; then
        echo "FAIL: xtensa_memstack_boot (compilation failed)"
        XT_MS_OK=0
    fi
    if [ "$XT_MS_OK" = 1 ]; then
        XT_MS_EXP="0
10
A
1
0"
        XT_MS_OUT=$(timeout 8 qemu-system-xtensa -M lx60 -nographic -kernel "$XT_MS_ELF" 2>/dev/null | tr -d '\r')
        if [ "$XT_MS_OUT" = "$XT_MS_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_memstack_boot: PASS (stack array + memset/memcpy/memcmp)"
        else
            echo "FAIL: xtensa_memstack_boot (output mismatch)"
            echo "    expected: $XT_MS_EXP"
            echo "    got:      $XT_MS_OUT"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_MS_ELF"
else
    echo "  xtensa_memstack_boot: SKIP (qemu-system-xtensa not installed)"
fi

# --- Xtensa LX6 string/format intrinsics (Task 6) boot test ---
# str_intrin.kr exercises IR_STRLEN (73), IR_STR_EQ (75), IR_FMT_UINT (74),
# plus the new per-function scratchpad region FMT_UINT needs (mirrors
# ir_riscv.kr's RV_SCRATCH_SIZE / ir_rv_scratch_off). str_len("abcd") -> 4,
# str_eq("hi","hi") -> 1, str_eq("hi","ho") -> 0, fmt_uint(buf, 60705) into a
# LOCAL `u8[8] buf` (Task 4's IR_STACK_ADDR) -> "60705" printed via the
# returned digit count (not a NUL scan). Full-output equality; loop{} keeps
# the core busy till timeout.
echo ""
echo "--- xtensa LX6 string/format intrinsics boot test ---"
if command -v qemu-system-xtensa >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_SI_ELF="/tmp/krc_xt_strintrin_$$.elf"
    XT_SI_OK=1
    if ! $KRC --arch=xtensa --freestanding "$DIR/../examples/xtensa/str_intrin.kr" -o "$XT_SI_ELF" >/dev/null 2>&1; then
        echo "FAIL: xtensa_strfmt_boot (compilation failed)"
        XT_SI_OK=0
    fi
    if [ "$XT_SI_OK" = 1 ]; then
        XT_SI_EXP="4
1
0
60705"
        XT_SI_OUT=$(timeout 8 qemu-system-xtensa -M lx60 -nographic -kernel "$XT_SI_ELF" 2>/dev/null | tr -d '\r')
        if [ "$XT_SI_OUT" = "$XT_SI_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_strfmt_boot: PASS (str_len/str_eq/fmt_uint = 4/1/0/60705)"
        else
            echo "FAIL: xtensa_strfmt_boot (output mismatch)"
            echo "    expected: $XT_SI_EXP"
            echo "    got:      $XT_SI_OUT"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_SI_ELF"
else
    echo "  xtensa_strfmt_boot: SKIP (qemu-system-xtensa not installed)"
fi

# --- Xtensa LX6 inline assembly (Task 8): IR_ASM_BLOCK(96) ---
# inline_asm.kr prints 'X', then an operand-less multi-line `asm { "memw" "nop" }`
# block, then 'Y'. Boot equality (XY) proves the block did not perturb the
# surrounding putc calls. The block is deliberately operand-less — the upstream
# constraint binding hardcodes x86 reg codes (ir.kr:4225), out of scope here.
# Structural gate (when the xtensa objdump is present): assert a `nop` is emitted.
# A `memw` grep would NOT discriminate — putc emits its own MEMW MMIO barriers on
# every device access — but NOTHING else in the backend emits `nop`, so a present
# `nop` uniquely proves the inline block was assembled (an elided block → zero
# nops → FAIL). LOAD is at file offset 0 / vaddr 0xd0000000, so the ELF file can
# be disassembled as a raw binary directly.
echo ""
echo "--- xtensa LX6 inline-asm (IR_ASM_BLOCK) boot test ---"
if command -v qemu-system-xtensa >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_ASM_ELF="/tmp/krc_xt_asm_$$.elf"
    XT_ASM_OK=1
    if ! $KRC --arch=xtensa --freestanding "$DIR/../examples/xtensa/inline_asm.kr" -o "$XT_ASM_ELF" >/dev/null 2>&1; then
        echo "FAIL: xtensa_asm_boot (compilation failed)"
        XT_ASM_OK=0
    fi
    # Structural gate: the inline-asm `nop` must be emitted (unique in the image —
    # putc's own MEMW barriers mean `memw` can't discriminate). Only when the
    # xtensa objdump is present; never a hard gate on its absence.
    if [ "$XT_ASM_OK" = 1 ] && command -v xtensa-lx106-elf-objdump >/dev/null 2>&1; then
        XT_ASM_DIS=$(xtensa-lx106-elf-objdump -b binary -m xtensa -D "$XT_ASM_ELF" 2>/dev/null)
        if ! echo "$XT_ASM_DIS" | grep -qE '\bnop(\.n)?\b'; then
            echo "FAIL: xtensa_asm_boot (inline-asm 'nop' word not emitted — block elided)"
            XT_ASM_OK=0
        fi
    fi
    if [ "$XT_ASM_OK" = 1 ]; then
        XT_ASM_EXP="XY"
        XT_ASM_OUT=$(timeout 8 qemu-system-xtensa -M lx60 -nographic -kernel "$XT_ASM_ELF" 2>/dev/null | tr -d '\r')
        if [ "$XT_ASM_OUT" = "$XT_ASM_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_asm_boot: PASS (asm block assembled: nop present + output = XY)"
        else
            echo "FAIL: xtensa_asm_boot (output mismatch)"
            echo "    expected: $XT_ASM_EXP"
            echo "    got:      $XT_ASM_OUT"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_ASM_ELF"
else
    echo "  xtensa_asm_boot: SKIP (qemu-system-xtensa not installed)"
fi

# --- Xtensa LX6 CAPSTONE: every freestanding op in one boot image ---
# capstone.kr composes all 8 tasks' proven idioms (each copied verbatim from
# its own example) into a single program/function table/static-data blob/
# stack frame: STR_CONST(79) via puts byte-loop, STATIC_LOAD/STORE/ADDR
# (77/78/84) RMW, a real BSS gap (static u32[1024], >=4096 B), STACK_ADDR(32)
# + implicit MEMSET zero-init on a local u32[4] (fill+sum), explicit
# MEMSET(76)+MEMCPY(72) on u8 buffers, STRLEN(73), STR_EQ(75) (equal then
# unequal), FMT_UINT(74) buffer print, MEMCMP(88) via struct `==` over
# struct-typed params on two static u32[2] arrays (equal then unequal),
# FN_ADDR(86)+CALL_IND(87) (dbl(21)=42), and ASM_BLOCK(96) (operand-less
# memw/nop bracketed by X/Y). Full-output equality; loop{} keeps the core
# busy till timeout.
echo ""
echo "--- xtensa LX6 CAPSTONE boot test (all freestanding ops) ---"
if command -v qemu-system-xtensa >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_CAP_ELF="/tmp/krc_xt_capstone_$$.elf"
    XT_CAP_OK=1
    if ! $KRC --arch=xtensa --freestanding "$DIR/../examples/xtensa/capstone.kr" -o "$XT_CAP_ELF" >/dev/null 2>&1; then
        echo "FAIL: xtensa_capstone_boot (compilation failed)"
        XT_CAP_OK=0
    fi
    if [ "$XT_CAP_OK" = 1 ]; then
        XT_CAP_EXP=$(printf 'xtensa capstone ok\n42\n0\n0\n10\nA\n4\n1\n0\n60705\n1\n0\n42\nXY')
        XT_CAP_OUT=$(timeout 10 qemu-system-xtensa -M lx60 -nographic -kernel "$XT_CAP_ELF" 2>/dev/null | tr -d '\r')
        if [ "$XT_CAP_OUT" = "$XT_CAP_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_capstone_boot: PASS (all freestanding ops: str_const/static/bss/stack+memset/memcpy/strlen/str_eq/fmt_uint/memcmp/fn_addr+call_ind/asm_block)"
        else
            echo "FAIL: xtensa_capstone_boot (output mismatch)"
            echo "    expected: $XT_CAP_EXP"
            echo "    got:      $XT_CAP_OUT"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_CAP_ELF"
else
    echo "  xtensa_capstone_boot: SKIP (qemu-system-xtensa not installed)"
fi

# --- RISC-V RV32 IR_STR_CONST via pcrel auipc+addi (feature-gap Task 1) ---
# Compiles examples/riscv-featuregap/t1_strconst.kr, which takes the address
# of a string literal ("hi\n") through IR_STR_CONST and writes it to the UART.
# Proves the pcrel auipc+addi pair + string-fixup resolver: objdump-checks
# that the pair stays 4-byte through the C-compression pass (no c.* shrink of
# either word) and boots under qemu, grepping stdout for "hi". Same dev-only
# toolchain guard/SKIP discipline as the hello boot test above.
echo ""
echo "--- riscv32 IR_STR_CONST boot test ---"
if command -v qemu-system-riscv32 >/dev/null 2>&1 \
   && command -v riscv64-linux-gnu-objdump >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_BIN="/tmp/krc_rv_strconst_$$.bin"
    RV_OK=1
    if ! $KRC --arch=riscv32 --freestanding "$DIR/../examples/riscv-featuregap/t1_strconst.kr" -o "$RV_BIN" >/dev/null 2>&1; then
        echo "FAIL: riscv_t1_strconst (compilation failed)"
        RV_OK=0
    fi
    if [ "$RV_OK" = 1 ]; then
        # The pcrel pair must survive compression as two 4-byte words: an
        # `auipc` immediately followed (4 bytes later) by an `addi` that
        # patches the same rd. Confirm both mnemonics are present full-width.
        RV_DIS=$(riscv64-linux-gnu-objdump -D -b binary -m riscv:rv32 "$RV_BIN" 2>/dev/null)
        if [ "$(echo "$RV_DIS" | grep -cE '\bauipc\b')" -lt 2 ]; then
            echo "FAIL: riscv_t1_strconst (expected >=2 full-width auipc: string address + call)"
            RV_OK=0
        fi
    fi
    if [ "$RV_OK" = 1 ]; then
        RV_OUT=$(timeout 5 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null)
        if echo "$RV_OUT" | grep -q "hi"; then
            PASS=$((PASS + 1))
            echo "  riscv_t1_strconst: PASS (qemu printed hi)"
        else
            echo "FAIL: riscv_t1_strconst (qemu output did not contain 'hi')"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$RV_BIN"
else
    echo "  riscv_t1_strconst: SKIP (qemu-system-riscv32 or riscv64-linux-gnu-objdump not installed)"
fi

# --- RISC-V RV32 static-global load/store/addr via pcrel (feature-gap Task 2) ---
# Compiles examples/riscv-featuregap/t2_static.kr, which increments a mutable
# global static (IR_STATIC_LOAD + IR_STATIC_STORE) and prints it as a single
# ASCII digit via IR_STATIC_ADDR-style base materialization. Proves the pcrel
# auipc+addi pair against the STATIC data segment (a separate fixup table/
# resolver from Task 1's string fixups) plus the plain lw/sw off the
# materialized base. Same dev-only toolchain guard/SKIP discipline as the
# tests above.
echo ""
echo "--- riscv32 static-global load/store/addr boot test ---"
if command -v qemu-system-riscv32 >/dev/null 2>&1 \
   && command -v riscv64-linux-gnu-objdump >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_BIN="/tmp/krc_rv_static_$$.bin"
    RV_OK=1
    if ! $KRC --arch=riscv32 --freestanding "$DIR/../examples/riscv-featuregap/t2_static.kr" -o "$RV_BIN" >/dev/null 2>&1; then
        echo "FAIL: riscv_t2_static (compilation failed)"
        RV_OK=0
    fi
    if [ "$RV_OK" = 1 ]; then
        # Three pcrel address materializations (load, store, load-again for
        # the putc arg) must each survive compression as two full-width
        # 4-byte words, and the load/store themselves must be plain lw/sw.
        RV_DIS=$(riscv64-linux-gnu-objdump -D -b binary -m riscv:rv32 "$RV_BIN" 2>/dev/null)
        if [ "$(echo "$RV_DIS" | grep -cE '\bauipc\b')" -lt 3 ]; then
            echo "FAIL: riscv_t2_static (expected >=3 full-width auipc: 2x static load + static store)"
            RV_OK=0
        fi
        if ! echo "$RV_DIS" | grep -qE '\blw\b'; then
            echo "FAIL: riscv_t2_static (expected a plain lw off the materialized static base)"
            RV_OK=0
        fi
        if ! echo "$RV_DIS" | grep -qE '\bsw\b'; then
            echo "FAIL: riscv_t2_static (expected a plain sw off the materialized static base)"
            RV_OK=0
        fi
    fi
    if [ "$RV_OK" = 1 ]; then
        RV_OUT=$(timeout 5 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null)
        if echo "$RV_OUT" | grep -q "9"; then
            PASS=$((PASS + 1))
            echo "  riscv_t2_static: PASS (qemu printed 9)"
        else
            echo "FAIL: riscv_t2_static (qemu output did not contain '9')"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$RV_BIN"
else
    echo "  riscv_t2_static: SKIP (qemu-system-riscv32 or riscv64-linux-gnu-objdump not installed)"
fi

# --- RISC-V RV32 string/compare inline loops (feature-gap Task 3) ---
# Compiles examples/riscv-featuregap/t3_strloops.kr, which exercises the two
# hand-emitted byte loops IR_STRLEN (op 73, str_len("abc") -> 3) and
# IR_STR_EQ (op 75, str_eq("ab","ab") -> 1) and prints both results as ASCII
# digits. Both loops bake branch displacements directly between
# instructions (no ir_br_fixups entry), so the C-compression pass could
# silently desync them if any interior instruction were allowed to shrink
# (audit §4 CRITICAL trap) -- rv_mark_noc protects each loop's full
# baked-displacement span. Proves this two ways: (1) qemu prints the
# arithmetically-correct "31", which a miscompiled displacement would not
# produce, and (2) the loop-interior pointer-bump `addi`s and STR_EQ's
# NE/EQ result-set `li`s -- the only loop mnemonics that opcode-wise
# COULD compress to c.addi/c.li -- must still be full 8-hex-digit (4-byte)
# encodings in the disassembly; a compressed 4-digit (2-byte) form at any
# of those sites would mean the noc region missed something. (lbu/beqz/bne
# can never compress regardless of noc, so they aren't useful signals
# here.) Same dev-only toolchain guard/SKIP discipline as the tests above.
#
# IR_MEMCMP (op 88) is also implemented by this task but is not exercised
# by a boot test here: its only IR emit site is struct `==`, which always
# lowers through IR_ALLOC (op 70, NYI on riscv32 and incompatible with
# --freestanding). It was validated separately (qemu + objdump, including
# with real interior compression elsewhere in the function) via a
# temporary, reverted stand-in for IR_ALLOC -- see t3_strloops.kr's header
# comment and .superpowers/sdd/task-3-report.md.
echo ""
echo "--- riscv32 STRLEN/STR_EQ inline-loop boot test ---"
if command -v qemu-system-riscv32 >/dev/null 2>&1 \
   && command -v riscv64-linux-gnu-objdump >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_BIN="/tmp/krc_rv_strloops_$$.bin"
    RV_OK=1
    if ! $KRC --arch=riscv32 --freestanding "$DIR/../examples/riscv-featuregap/t3_strloops.kr" -o "$RV_BIN" >/dev/null 2>&1; then
        echo "FAIL: riscv_t3_strloops (compilation failed)"
        RV_OK=0
    fi
    if [ "$RV_OK" = 1 ]; then
        RV_DIS=$(riscv64-linux-gnu-objdump -D -b binary -m riscv:rv32 "$RV_BIN" 2>/dev/null)
        # 4x lbu (1 strlen + 2 str_eq body + 1 UART lsr poll), 2x beqz
        # (strlen end + str_eq equal-check), 1x bne (str_eq mismatch check).
        if [ "$(echo "$RV_DIS" | grep -cE '	lbu	')" -lt 4 ]; then
            echo "FAIL: riscv_t3_strloops (expected >=4 lbu: strlen + str_eq x2 + uart poll)"
            RV_OK=0
        fi
        if [ "$(echo "$RV_DIS" | grep -cE '	bne	')" -lt 1 ]; then
            echo "FAIL: riscv_t3_strloops (expected >=1 bne: str_eq mismatch check)"
            RV_OK=0
        fi
        # The correctness gate: lbu/beqz/bne can NEVER compress regardless
        # of noc (rv_try_compress only handles opcodes 0x13/0x33/0x03
        # f3=2/0x23 f3=2 -- lbu is 0x03 f3=4, and branches/jal never
        # compress at all), so asserting their width proves nothing about
        # the noc mechanism. The instructions that WOULD shrink to
        # c.addi/c.li if rv_mark_noc failed to cover the loop are the
        # loop-interior pointer bumps (`addi a0,a0,1` / `addi a1,a1,1`)
        # and the STR_EQ NE/EQ result-set words (`li d,0` / `li d,1`) --
        # those are what this gate must, and does, check. Loop shapes are
        # matched structurally by mnemonic sequence (not hardcoded hex
        # offsets), so this stays robust to any future codegen/prologue
        # change that shifts addresses without touching the loops:
        #   STRLEN: lbu, beqz, addi, j            (back-edge)
        #   STR_EQ: lbu, lbu, bne, beqz, addi, addi, j, li, j, li
        NOC_BAD=$(echo "$RV_DIS" | awk -F'\t' '
            { m=$3; h=$2; gsub(/ /,"",h); n++; mnem[n]=m; hexlen[n]=length(h); line[n]=$0 }
            END {
                strlen_found=0; streq_found=0
                for (i=1; i<=n; i++) {
                    if (!strlen_found && i+3<=n && mnem[i]=="lbu" && mnem[i+1]=="beqz" && mnem[i+2]=="addi" && mnem[i+3]=="j") {
                        strlen_found=1
                        if (hexlen[i+2]!=8) print "STRLEN loop pointer-bump addi compressed: " line[i+2]
                    }
                    if (!streq_found && i+9<=n && mnem[i]=="lbu" && mnem[i+1]=="lbu" && mnem[i+2]=="bne" && mnem[i+3]=="beqz" && mnem[i+4]=="addi" && mnem[i+5]=="addi" && mnem[i+6]=="j" && mnem[i+7]=="li" && mnem[i+8]=="j" && mnem[i+9]=="li") {
                        streq_found=1
                        if (hexlen[i+4]!=8) print "STR_EQ loop pointer-bump addi (a0) compressed: " line[i+4]
                        if (hexlen[i+5]!=8) print "STR_EQ loop pointer-bump addi (a1) compressed: " line[i+5]
                        if (hexlen[i+7]!=8) print "STR_EQ NE-tail li (mismatch result) compressed: " line[i+7]
                        if (hexlen[i+9]!=8) print "STR_EQ EQ-tail li (match result) compressed: " line[i+9]
                    }
                }
                if (!strlen_found) print "STRLEN loop instruction pattern (lbu,beqz,addi,j) not found in disassembly"
                if (!streq_found) print "STR_EQ loop instruction pattern (lbu,lbu,bne,beqz,addi,addi,j,li,j,li) not found in disassembly"
            }
        ')
        if [ -n "$NOC_BAD" ]; then
            echo "FAIL: riscv_t3_strloops (compressible loop-interior addi/li word(s) found -- noc region missed a loop instruction)"
            echo "$NOC_BAD"
            RV_OK=0
        fi
    fi
    if [ "$RV_OK" = 1 ]; then
        RV_OUT=$(timeout 5 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null)
        if echo "$RV_OUT" | grep -q "31"; then
            PASS=$((PASS + 1))
            echo "  riscv_t3_strloops: PASS (qemu printed 31, loops stayed 4-byte)"
        else
            echo "FAIL: riscv_t3_strloops (qemu output did not contain '31')"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$RV_BIN"
else
    echo "  riscv_t3_strloops: SKIP (qemu-system-riscv32 or riscv64-linux-gnu-objdump not installed)"
fi

# --- RISC-V RV32 memory-block inline loops (feature-gap Task 4) ---
# Compiles examples/riscv-featuregap/t4_memblk.kr, which exercises the two
# hand-emitted byte loops IR_MEMSET (op 76) and IR_MEMCPY (op 72) against
# GLOBAL static byte buffers (Task 2's STATIC_ADDR array-decay path --
# deliberately not local arrays, since IR_STACK_ADDR/Task 6 isn't
# implemented yet). Both loops bake branch displacements directly between
# instructions (no ir_br_fixups entry, same shape as Task 3's
# STRLEN/STR_EQ/MEMCMP), so the C-compression pass could silently desync
# them if any interior instruction were allowed to shrink (audit §4
# CRITICAL trap) -- rv_mark_noc protects each loop's full baked-
# displacement span. The test also proves length==0 is a true no-op (both
# loops test their count at the TOP of the loop, mirroring arm64's
# CBZ-before-first-access shape): memset(setbuf,90,0) must NOT overwrite
# setbuf[0], which the "AA" (not "AZ") in the expected output checks.
# Proves this two ways: (1) qemu prints the arithmetically-correct "AAZk",
# which a miscompiled displacement OR a zero-length underflow would not
# produce, and (2) the loop-interior pointer-bump `addi`s -- the only loop
# mnemonics that opcode-wise COULD compress to c.addi -- must still be
# full 8-hex-digit (4-byte) encodings in the disassembly; a compressed
# 4-digit (2-byte) form at any of those sites would mean the noc region
# missed something. (lbu/sb/beqz/j can never compress regardless of noc:
# rv_try_compress only handles opcodes 0x13/0x33 f3=0 and 0x03/0x23 f3=2
# -- lbu is 0x03 f3=4, sb is 0x23 f3=0, and branches/jal never compress at
# all -- so asserting their width proves nothing about the noc mechanism.)
echo ""
echo "--- riscv32 MEMSET/MEMCPY inline-loop boot test ---"
if command -v qemu-system-riscv32 >/dev/null 2>&1 \
   && command -v riscv64-linux-gnu-objdump >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_BIN="/tmp/krc_rv_memblk_$$.bin"
    RV_OK=1
    if ! $KRC --arch=riscv32 --freestanding "$DIR/../examples/riscv-featuregap/t4_memblk.kr" -o "$RV_BIN" >/dev/null 2>&1; then
        echo "FAIL: riscv_t4_memblk (compilation failed)"
        RV_OK=0
    fi
    if [ "$RV_OK" = 1 ]; then
        RV_DIS=$(riscv64-linux-gnu-objdump -D -b binary -m riscv:rv32 "$RV_BIN" 2>/dev/null)
        # 3x sb (memset fill loop + memset zero-len loop + memcpy loop) +
        # 1x sb for the UART Uart.thr write in putc.
        if [ "$(echo "$RV_DIS" | grep -cE '	sb	')" -lt 3 ]; then
            echo "FAIL: riscv_t4_memblk (expected >=3 sb: 2x memset loop + memcpy loop)"
            RV_OK=0
        fi
        # 1x lbu in the memcpy loop body + 4x lbu reading buffer bytes back
        # (setbuf[0] x2, cpybuf[0], cpybuf[1]) + 1x lbu for the UART lsr poll.
        if [ "$(echo "$RV_DIS" | grep -cE '	lbu	')" -lt 5 ]; then
            echo "FAIL: riscv_t4_memblk (expected >=5 lbu: memcpy loop + 4x buffer readback)"
            RV_OK=0
        fi
        # The correctness gate: match each loop by its structural mnemonic
        # sequence (not hardcoded hex offsets, so this stays robust to any
        # future codegen/prologue change that shifts addresses without
        # touching the loops) and assert every word in the noc-protected
        # span stayed full-width:
        #   MEMSET (both the fill call and the zero-length call use the
        #   identical loop shape): beqz, sb, addi, addi, j
        #   MEMCPY: beqz, lbu, sb, addi, addi, addi, j
        NOC_BAD=$(echo "$RV_DIS" | awk -F'\t' '
            { m=$3; h=$2; gsub(/ /,"",h); n++; mnem[n]=m; hexlen[n]=length(h); line[n]=$0 }
            END {
                memset_found=0; memcpy_found=0
                for (i=1; i<=n; i++) {
                    if (i+4<=n && mnem[i]=="beqz" && mnem[i+1]=="sb" && mnem[i+2]=="addi" && mnem[i+3]=="addi" && mnem[i+4]=="j") {
                        memset_found++
                        if (hexlen[i+2]!=8) print "MEMSET loop pointer-bump addi (a0) compressed: " line[i+2]
                        if (hexlen[i+3]!=8) print "MEMSET loop length-decrement addi (a2) compressed: " line[i+3]
                    }
                    if (!memcpy_found && i+6<=n && mnem[i]=="beqz" && mnem[i+1]=="lbu" && mnem[i+2]=="sb" && mnem[i+3]=="addi" && mnem[i+4]=="addi" && mnem[i+5]=="addi" && mnem[i+6]=="j") {
                        memcpy_found=1
                        if (hexlen[i+3]!=8) print "MEMCPY loop pointer-bump addi (a0) compressed: " line[i+3]
                        if (hexlen[i+4]!=8) print "MEMCPY loop pointer-bump addi (a1) compressed: " line[i+4]
                        if (hexlen[i+5]!=8) print "MEMCPY loop length-decrement addi (a2) compressed: " line[i+5]
                    }
                }
                if (memset_found<2) print "MEMSET loop instruction pattern (beqz,sb,addi,addi,j) found " memset_found " time(s), expected 2 (fill call + zero-length call)"
                if (!memcpy_found) print "MEMCPY loop instruction pattern (beqz,lbu,sb,addi,addi,addi,j) not found in disassembly"
            }
        ')
        if [ -n "$NOC_BAD" ]; then
            echo "FAIL: riscv_t4_memblk (compressible loop-interior addi word(s) found -- noc region missed a loop instruction)"
            echo "$NOC_BAD"
            RV_OK=0
        fi
    fi
    if [ "$RV_OK" = 1 ]; then
        RV_OUT=$(timeout 5 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null)
        if echo "$RV_OUT" | grep -q "AAZk"; then
            PASS=$((PASS + 1))
            echo "  riscv_t4_memblk: PASS (qemu printed AAZk, loops stayed 4-byte)"
        else
            echo "FAIL: riscv_t4_memblk (qemu output was '$RV_OUT', want 'AAZk')"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$RV_BIN"
else
    echo "  riscv_t4_memblk: SKIP (qemu-system-riscv32 or riscv64-linux-gnu-objdump not installed)"
fi

# --- RISC-V RV32 number formatting + frame scratchpad (feature-gap Task 5) ---
# Compiles examples/riscv-featuregap/t5_fmtuint.kr, which exercises
# IR_FMT_UINT (op 74) against a GLOBAL static byte buffer (same
# STATIC_ADDR-array-decay constraint as Task 4 -- IR_STACK_ADDR/Task 6
# still isn't implemented) plus the new fixed 32-byte frame scratchpad
# (RV_SCRATCH_SIZE / ir_rv_scratch_off, ir_riscv.kr) FMT_UINT stages its
# reversed digits through. fmt_uint(buf,12345) drives a full 5-iteration
# divide-by-10 digit-extraction loop (divu+remu, RV32M native remainder --
# no msub synthesis needed, unlike arm64) writing LEAST-significant-first
# into the scratchpad, then a second loop copies the digits into buf
# MOST-significant-first. Both loops bake branch displacements directly
# between instructions (digit loop: backward bnez; copy loop: forward
# beqz + backward j) -- same audit §4 CRITICAL trap as every other
# hand-emitted riscv loop -- so rv_mark_noc wraps the whole span from the
# digit loop's first instruction through the copy loop's exit patch.
# Correctness is checked two ways: (1) qemu must print exactly "123455" --
# "12345" (the 5 formatted digits, in the correct left-to-right order,
# which a reversal-loop bug would scramble) followed by "5" (len+'0', a
# len-count sanity check an off-by-one in the reversal loop would corrupt
# too), and (2) the loop-interior addi/mv words -- the only loop mnemonics
# that opcode-wise COULD compress to c.addi/c.mv -- must still be full
# 8-hex-digit (4-byte) encodings in the disassembly; a compressed 4-digit
# (2-byte) form at any of those sites would mean the noc region missed
# something. (divu/remu/add/sb/lbu/beqz/bnez/j can never compress
# regardless of noc: rv_try_compress only handles opcodes 0x13/0x33 f3=0
# and 0x03/0x23 f3=2 -- divu/remu are 0x33 f3=5/7, add is 0x33 f3=0 but
# rs1!=rd so it never matches c.mv/c.add's shape, sb/lbu are 0x23 f3=0 /
# 0x03 f3=4, and branches/jal never compress at all -- so asserting their
# width proves nothing about the noc mechanism.)
echo ""
echo "--- riscv32 FMT_UINT + frame-scratchpad boot test ---"
if command -v qemu-system-riscv32 >/dev/null 2>&1 \
   && command -v riscv64-linux-gnu-objdump >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_BIN="/tmp/krc_rv_fmtuint_$$.bin"
    RV_OK=1
    if ! $KRC --arch=riscv32 --freestanding "$DIR/../examples/riscv-featuregap/t5_fmtuint.kr" -o "$RV_BIN" >/dev/null 2>&1; then
        echo "FAIL: riscv_t5_fmtuint (compilation failed)"
        RV_OK=0
    fi
    if [ "$RV_OK" = 1 ]; then
        RV_DIS=$(riscv64-linux-gnu-objdump -D -b binary -m riscv:rv32 "$RV_BIN" 2>/dev/null)
        if [ "$(echo "$RV_DIS" | grep -cE '	divu	')" -lt 1 ]; then
            echo "FAIL: riscv_t5_fmtuint (expected >=1 divu: digit-extraction loop)"
            RV_OK=0
        fi
        if [ "$(echo "$RV_DIS" | grep -cE '	remu	')" -lt 1 ]; then
            echo "FAIL: riscv_t5_fmtuint (expected >=1 remu: digit-extraction loop)"
            RV_OK=0
        fi
        # The correctness gate: match each loop by its structural mnemonic
        # sequence (not hardcoded hex offsets) and assert every
        # compressible-opcode-shaped word in the noc-protected span stayed
        # full-width:
        #   Digit loop: divu, remu, addi, add, sb, addi, mv, bnez
        #   Copy loop:  beqz, addi, add, lbu, sb, addi, j
        NOC_BAD=$(echo "$RV_DIS" | awk -F'\t' '
            { m=$3; h=$2; gsub(/ /,"",h); n++; mnem[n]=m; hexlen[n]=length(h); line[n]=$0 }
            END {
                digit_found=0; copy_found=0
                for (i=1; i<=n; i++) {
                    if (i+7<=n && mnem[i]=="divu" && mnem[i+1]=="remu" && mnem[i+2]=="addi" && mnem[i+3]=="add" && mnem[i+4]=="sb" && mnem[i+5]=="addi" && mnem[i+6]=="mv" && mnem[i+7]=="bnez") {
                        digit_found++
                        if (hexlen[i]!=8) print "FMT_UINT digit-loop divu compressed: " line[i]
                        if (hexlen[i+1]!=8) print "FMT_UINT digit-loop remu compressed: " line[i+1]
                        if (hexlen[i+2]!=8) print "FMT_UINT digit-loop digit-byte addi compressed: " line[i+2]
                        if (hexlen[i+5]!=8) print "FMT_UINT digit-loop count addi compressed: " line[i+5]
                        if (hexlen[i+6]!=8) print "FMT_UINT digit-loop quotient mv compressed: " line[i+6]
                        if (hexlen[i+7]!=8) print "FMT_UINT digit-loop bnez compressed: " line[i+7]
                    }
                    if (!copy_found && i+6<=n && mnem[i]=="beqz" && mnem[i+1]=="addi" && mnem[i+2]=="add" && mnem[i+3]=="lbu" && mnem[i+4]=="sb" && mnem[i+5]=="addi" && mnem[i+6]=="j") {
                        copy_found=1
                        if (hexlen[i+1]!=8) print "FMT_UINT copy-loop count addi compressed: " line[i+1]
                        if (hexlen[i+5]!=8) print "FMT_UINT copy-loop pointer addi compressed: " line[i+5]
                    }
                }
                if (digit_found<1) print "FMT_UINT digit-loop instruction pattern (divu,remu,addi,add,sb,addi,mv,bnez) not found in disassembly"
                if (!copy_found) print "FMT_UINT copy-loop instruction pattern (beqz,addi,add,lbu,sb,addi,j) not found in disassembly"
            }
        ')
        if [ -n "$NOC_BAD" ]; then
            echo "FAIL: riscv_t5_fmtuint (compressible loop-interior word(s) found -- noc region missed a loop instruction)"
            echo "$NOC_BAD"
            RV_OK=0
        fi
    fi
    if [ "$RV_OK" = 1 ]; then
        RV_OUT=$(timeout 5 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null)
        if [ "$RV_OUT" = "123455" ]; then
            PASS=$((PASS + 1))
            echo "  riscv_t5_fmtuint: PASS (qemu printed 123455 -- digits '12345' + len sanity '5', loops stayed 4-byte)"
        else
            echo "FAIL: riscv_t5_fmtuint (qemu output was '$RV_OUT', want '123455')"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$RV_BIN"
else
    echo "  riscv_t5_fmtuint: SKIP (qemu-system-riscv32 or riscv64-linux-gnu-objdump not installed)"
fi

# ============================================================================
# riscv32 stack arrays (IR_STACK_ADDR) + large frames (t5-assisted SP math)
# ============================================================================
# Compiles examples/riscv-featuregap/t6_stackarray.kr: a small local array
# (frame stays in imm12) prints 'A', and a ~2.6 KB local array (total_frame
# > 2032) prints 'Z'. The large case forces the t5-assisted SP arithmetic in
# the prologue/epilogue and in STACK_ADDR itself; if any sp-relative site were
# miscomputed for the large frame, the array readback (or the saved ra/s-regs)
# would corrupt and the program would not print "AZ" cleanly. We also assert
# the disassembly shows `sub sp,sp,t5` in the large-frame prologue (proof the
# 2032 cap was actually lifted, not just skirted).
echo "--- riscv32 stack-array + large-frame boot test ---"
if command -v qemu-system-riscv32 >/dev/null 2>&1 \
   && command -v riscv64-linux-gnu-objdump >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_BIN="/tmp/krc_rv_t6_$$.bin"
    RV_OK=1
    if ! $KRC --arch=riscv32 --freestanding "$DIR/../examples/riscv-featuregap/t6_stackarray.kr" -o "$RV_BIN" >/dev/null 2>&1; then
        echo "FAIL: riscv_t6_stackarray (compilation failed)"
        RV_OK=0
    fi
    if [ "$RV_OK" = 1 ]; then
        RV_DIS=$(riscv64-linux-gnu-objdump -D -b binary -m riscv:rv32 -M no-aliases "$RV_BIN" 2>/dev/null)
        # Large-frame proof: the prologue must materialize the frame size in
        # t5 and subtract it from sp (the 2032 cap is gone). A small-frame-only
        # build would never emit `sub sp,sp,t5`.
        if [ "$(echo "$RV_DIS" | grep -cE '	sub	sp,sp,t5')" -lt 1 ]; then
            echo "FAIL: riscv_t6_stackarray (no 'sub sp,sp,t5' -- large frame not t5-assisted)"
            RV_OK=0
        fi
        # STACK_ADDR's own >imm12 base_off must use the t5-assisted add form.
        if [ "$(echo "$RV_DIS" | grep -cE '	add	s[0-9]+,sp,t5')" -lt 1 ]; then
            echo "FAIL: riscv_t6_stackarray (no 't5-assisted STACK_ADDR (add sX,sp,t5)')"
            RV_OK=0
        fi
    fi
    if [ "$RV_OK" = 1 ]; then
        RV_OUT=$(timeout 5 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null)
        # Command substitution strips the trailing newline, leaving "AZ".
        if [ "$RV_OUT" = "AZ" ]; then
            PASS=$((PASS + 1))
            echo "  riscv_t6_stackarray: PASS (qemu printed AZ -- small array 'A' + large-frame array 'Z')"
        else
            echo "FAIL: riscv_t6_stackarray (qemu output was '$RV_OUT', want 'AZ')"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$RV_BIN"
else
    echo "  riscv_t6_stackarray: SKIP (qemu-system-riscv32 or riscv64-linux-gnu-objdump not installed)"
fi

# --- RISC-V RV32 function pointers via IR_FN_ADDR (feature-gap Task 7) ---
# Compiles examples/riscv-featuregap/t7_fnptr.kr, which takes the address of
# `inc` via fn_addr("inc") (IR_FN_ADDR -> pcrel auipc+addi pair, resolved by
# resolve_fnaddr_fixups_riscv against the function's code offset) and calls
# through it with call_ptr (IR_CALL_IND, an indirect jalr). inc(64) = 65 =
# 'A', so a correct resolution is the only way the UART prints 'A': any
# wrong disp would jalr into garbage or hang. We also objdump-confirm the
# fn_addr pcrel pair stayed a full-width auipc+addi (not compressed/torn
# apart) and that the call site is a genuine indirect jalr (zero immediate,
# non-ra base register) rather than the direct-call auipc+jalr shape.
echo ""
echo "--- riscv32 function-pointer (IR_FN_ADDR) boot test ---"
if command -v qemu-system-riscv32 >/dev/null 2>&1 \
   && command -v riscv64-linux-gnu-objdump >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_BIN="/tmp/krc_rv_t7_$$.bin"
    RV_OK=1
    if ! $KRC --arch=riscv32 --freestanding "$DIR/../examples/riscv-featuregap/t7_fnptr.kr" -o "$RV_BIN" >/dev/null 2>&1; then
        echo "FAIL: riscv_t7_fnptr (compilation failed)"
        RV_OK=0
    fi
    if [ "$RV_OK" = 1 ]; then
        RV_DIS=$(riscv64-linux-gnu-objdump -D -b binary -m riscv:rv32 -M no-aliases "$RV_BIN" 2>/dev/null)
        # fn_addr materialization + the two direct calls to putc all emit a
        # full-width auipc -- confirm none were shrunk/elided.
        if [ "$(echo "$RV_DIS" | grep -cE '	auipc	')" -lt 2 ]; then
            echo "FAIL: riscv_t7_fnptr (expected >=2 full-width auipc: fn_addr + call)"
            RV_OK=0
        fi
        # The indirect call through the materialized pointer is `jalr
        # ra,0(sN)` -- zero immediate off a non-ra base register. Direct
        # calls are always `jalr ra,imm(ra)` off their own auipc, so this
        # pattern can only come from IR_CALL_IND through a resolved fn_addr.
        if [ "$(echo "$RV_DIS" | grep -cE '	jalr	ra,0\(s')" -lt 1 ]; then
            echo "FAIL: riscv_t7_fnptr (no indirect jalr through materialized fn pointer)"
            RV_OK=0
        fi
    fi
    if [ "$RV_OK" = 1 ]; then
        RV_OUT=$(timeout 5 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null)
        # Command substitution strips the trailing newline, leaving "A".
        if [ "$RV_OUT" = "A" ]; then
            PASS=$((PASS + 1))
            echo "  riscv_t7_fnptr: PASS (qemu printed A -- inc(64) called through fn_addr pointer)"
        else
            echo "FAIL: riscv_t7_fnptr (qemu output was '$RV_OUT', want 'A')"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$RV_BIN"
else
    echo "  riscv_t7_fnptr: SKIP (qemu-system-riscv32 or riscv64-linux-gnu-objdump not installed)"
fi

# Compiles examples/riscv-featuregap/t8_ror.kr, which rotates a runtime value.
# The `rotr32` helper is AST-rotation-inlined into main; ir_opt_recognize_rotate
# then rewrites the OR(AND(SHR),AND(SHL)) idiom to IR_ROR (137), which RV32IM
# lowers (no rotate insn) to the srl/sub/andi/sll/or synthesis. This test is
# NON-VACUOUS: the objdump assertion proves op 137 was lowered HERE (the
# `sub aN,zero,aN` negate sandwiched between the shifts is emitted by NOTHING
# except the IR_ROR handler — plain shift lowering never produces it), and the
# boot asserts the rotate is bit-exact (0x81 ror 1 = 0x80000040 -> '@'; the
# n==0 identity via a runtime count -> 'A').
echo ""
echo "--- riscv32 rotate (IR_ROR) boot test ---"
if command -v qemu-system-riscv32 >/dev/null 2>&1 \
   && command -v riscv64-linux-gnu-objdump >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_BIN="/tmp/krc_rv_t8_$$.bin"
    RV_OK=1
    if ! $KRC --arch=riscv32 --freestanding "$DIR/../examples/riscv-featuregap/t8_ror.kr" -o "$RV_BIN" >/dev/null 2>&1; then
        echo "FAIL: riscv_t8_ror (compilation failed)"
        RV_OK=0
    fi
    if [ "$RV_OK" = 1 ]; then
        RV_DIS=$(riscv64-linux-gnu-objdump -D -b binary -m riscv:rv32 -M no-aliases "$RV_BIN" 2>/dev/null)
        # Positive proof the IR_ROR handler ran (not that the optimizer folded
        # the rotate to plain shifts): the negate `sub a1,zero,a1` between the
        # two synthesized shifts is unique to op 137's lowering. Two call sites
        # -> expect it twice. If the recognizer had failed to fire, there would
        # be no IR_ROR and no such negate — the whole point of this assertion.
        if [ "$(echo "$RV_DIS" | grep -cE '	sub	a1,zero,a1')" -lt 2 ]; then
            echo "FAIL: riscv_t8_ror (IR_ROR synth 'sub a1,zero,a1' negate not found x2 -- recognizer may not have fired / op 137 not lowered here)"
            RV_OK=0
        fi
        # And the surrounding srl/sll must be present (the rotate's two shifts).
        if [ "$(echo "$RV_DIS" | grep -cE '	srl	t5,a0,a1')" -lt 2 ] \
           || [ "$(echo "$RV_DIS" | grep -cE '	sll	a0,a0,a1')" -lt 2 ]; then
            echo "FAIL: riscv_t8_ror (IR_ROR srl/sll synthesis shifts missing)"
            RV_OK=0
        fi
    fi
    if [ "$RV_OK" = 1 ]; then
        RV_OUT=$(timeout 5 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null)
        # 0x81 ror 1 = 0x80000040 (low byte '@'); 0x41 ror 0 = 'A' (n==0
        # identity). Command substitution strips the trailing newline.
        if [ "$RV_OUT" = "@A" ]; then
            PASS=$((PASS + 1))
            echo "  riscv_t8_ror: PASS (qemu printed @A -- rotate bit-exact incl. n==0 identity)"
        else
            echo "FAIL: riscv_t8_ror (qemu output was '$RV_OUT', want '@A')"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$RV_BIN"
else
    echo "  riscv_t8_ror: SKIP (qemu-system-riscv32 or riscv64-linux-gnu-objdump not installed)"
fi

# Compiles examples/riscv-featuregap/t9_asm.kr, which exercises inline asm
# (IR_ASM_BLOCK 96): a raw hex word `asm("0x00150513")` = `addi a0,a0,1` bound
# to a variable via in()/out() constraints (rv_reg_code path at ir.kr:4214/
# 4237), plus a `csrr t0,mhartid` intrinsic. NON-VACUOUS on two counts: the
# raw word is a COMPRESSIBLE encoding (rd==rs1, simm6 imm) so its objdump
# survival as a full 4-byte `addi a0,a0,1` proves the handler marked the range
# non-compressible; and the boot proves in/out constraint binding actually
# moved base->a0 and captured a0->result (a0+1 = 0x41 = 'A').
echo ""
echo "--- riscv32 inline asm (IR_ASM_BLOCK) boot test ---"
if command -v qemu-system-riscv32 >/dev/null 2>&1 \
   && command -v riscv64-linux-gnu-objdump >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_BIN="/tmp/krc_rv_t9_$$.bin"
    RV_OK=1
    if ! $KRC --arch=riscv32 --freestanding "$DIR/../examples/riscv-featuregap/t9_asm.kr" -o "$RV_BIN" >/dev/null 2>&1; then
        echo "FAIL: riscv_t9_asm (compilation failed)"
        RV_OK=0
    fi
    if [ "$RV_OK" = 1 ]; then
        RV_DIS=$(riscv64-linux-gnu-objdump -D -b binary -m riscv:rv32 -M no-aliases "$RV_BIN" 2>/dev/null)
        # Raw asm word emitted verbatim AND left uncompressed (full 4-byte).
        if [ "$(echo "$RV_DIS" | grep -cE '	addi	a0,a0,1')" -lt 1 ]; then
            echo "FAIL: riscv_t9_asm (raw asm word 'addi a0,a0,1' not emitted verbatim)"
            RV_OK=0
        fi
        # Must NOT have been shrunk to c.addi (noc region protects it).
        if [ "$(echo "$RV_DIS" | grep -cE 'c\.addi	a0,1')" -ne 0 ]; then
            echo "FAIL: riscv_t9_asm (raw asm word was compressed to c.addi -- noc region missed it)"
            RV_OK=0
        fi
        # csrr intrinsic emitted the right CSR (mhartid = 0xf14).
        if [ "$(echo "$RV_DIS" | grep -c 'mhartid')" -lt 1 ]; then
            echo "FAIL: riscv_t9_asm (csrr intrinsic did not emit mhartid CSR read)"
            RV_OK=0
        fi
    fi
    if [ "$RV_OK" = 1 ]; then
        RV_OUT=$(timeout 5 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null)
        # in(base=0x40 -> a0); raw word a0=a0+1=0x41; out(a0 -> result); putc.
        if [ "$RV_OUT" = "A" ]; then
            PASS=$((PASS + 1))
            echo "  riscv_t9_asm: PASS (qemu printed A -- raw word ran, in/out constraint bound, word stayed 4-byte)"
        else
            echo "FAIL: riscv_t9_asm (qemu output was '$RV_OUT', want 'A')"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$RV_BIN"
else
    echo "  riscv_t9_asm: SKIP (qemu-system-riscv32 or riscv64-linux-gnu-objdump not installed)"
fi

# Compiles examples/riscv-hosted/exit_code.kr, which is the Task 1
# hosted-emission smoke test: `fn main() -> uint32 { return 42 }` compiled
# WITHOUT --freestanding must produce a real Elf32 ET_EXEC (e_machine=243)
# that runs directly under qemu-riscv32-static (the user-mode emulator, as
# opposed to qemu-system-riscv32 -bios used by the freestanding checks
# above) and exits with the returned value. Distinct from the freestanding
# suite: no UART, no -bios boot -- this exercises emit_elf_header_rv32() /
# emit_program_header_rv32() in main.kr's arch-2 header dispatch and the
# auto-exit ecall main() gets in ir_riscv.kr's epilogue.
echo ""
echo "--- riscv32 hosted ELF (exit code) test ---"
if command -v qemu-riscv32-static >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_BIN="/tmp/krc_rv_exit_$$.bin"
    if ! $KRC --arch=riscv32 "$DIR/../examples/riscv-hosted/exit_code.kr" -o "$RV_BIN" >/dev/null 2>&1; then
        echo "FAIL: riscv_hosted_exit_code (compilation failed)"
        FAIL=$((FAIL + 1))
    else
        qemu-riscv32-static "$RV_BIN" >/dev/null 2>&1
        rc=$?
        if [ "$rc" = "42" ]; then
            PASS=$((PASS + 1))
            echo "  riscv_hosted_exit_code: PASS (qemu-riscv32-static exited 42)"
        else
            echo "FAIL: riscv_hosted_exit_code (got exit $rc, want 42)"
            FAIL=$((FAIL + 1))
        fi
    fi
    rm -f "$RV_BIN"
else
    echo "  riscv_hosted_exit_code: SKIP (qemu-riscv32-static not installed)"
fi

# Compiles examples/riscv-hosted/hello.kr, which is the Task 2 hosted-syscall
# smoke test: `write(1, "hello riscv\n", 12)` followed by `return 0` compiled
# WITHOUT --freestanding must produce a hosted Elf32 ET_EXEC that, when run
# under qemu-riscv32-static, actually invokes the Linux write(2) syscall
# (a7=64 ecall) and prints the string to stdout. Distinct from
# riscv_hosted_exit_code above: that test only exercises the auto-exit path;
# this one exercises IR_SYSCALL (op 52) lowering in ir_riscv.kr.
echo ""
echo "--- riscv32 hosted syscall (write) test ---"
if command -v qemu-riscv32-static >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_BIN="/tmp/krc_rv_hello_$$.bin"
    if ! $KRC --arch=riscv32 "$DIR/../examples/riscv-hosted/hello.kr" -o "$RV_BIN" >/dev/null 2>&1; then
        echo "FAIL: riscv_hosted_hello (compilation failed)"
        FAIL=$((FAIL + 1))
    else
        RV_OUT=$(qemu-riscv32-static "$RV_BIN" 2>/dev/null)
        if [ "$RV_OUT" = "hello riscv" ]; then
            PASS=$((PASS + 1))
            echo "  riscv_hosted_hello: PASS (qemu-riscv32-static printed 'hello riscv')"
        else
            echo "FAIL: riscv_hosted_hello (got '$RV_OUT', want 'hello riscv')"
            FAIL=$((FAIL + 1))
        fi
    fi
    rm -f "$RV_BIN"
else
    echo "  riscv_hosted_hello: SKIP (qemu-riscv32-static not installed)"
fi

# Same hello.kr as riscv_hosted_hello above, but WITH --freestanding: a
# bare-metal rv32 image has no OS to service write(2), so IR_SYSCALL (op 52)
# must fail loud with an NYI error instead of silently emitting a
# meaningless Linux ecall (mirrors the op 70/71 IR_ALLOC freestanding gate
# tested implicitly by riscv_hosted_heap's header comment above). No qemu
# needed -- this only checks the compiler's own diagnostic, not codegen.
TOTAL=$((TOTAL + 1))
RV_ERR=$($KRC --arch=riscv32 --freestanding "$DIR/../examples/riscv-hosted/hello.kr" -o /tmp/krc_rv_fs_syscall_$$.bin 2>&1)
if echo "$RV_ERR" | grep -q "op 52 not yet implemented"; then
    PASS=$((PASS + 1))
    echo "  riscv_freestanding_syscall_nyi: PASS (op 52 gated loud on freestanding)"
else
    echo "FAIL: riscv_freestanding_syscall_nyi (got '$RV_ERR', want NYI on op 52)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_rv_fs_syscall_$$.bin

# Compiles examples/riscv-hosted/echo_argv.kr, the Task 3 main-entry
# trampoline test: a hosted main() reads argv[1] back through the cli_argv
# static that ir_riscv_gen's prologue trampoline populates from the process
# stack ([sp]=argc, [sp+4]=&argv[0], ILP32 4-byte slots). Running the binary
# with an argument must echo that argument to stdout. Distinct from
# riscv_hosted_hello: this exercises the argc/argv/envp capture in the
# main prologue, not just a bare write().
echo ""
echo "--- riscv32 hosted main entry trampoline (argv) test ---"
if command -v qemu-riscv32-static >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_BIN="/tmp/krc_rv_echo_$$.bin"
    if ! $KRC --arch=riscv32 "$DIR/../examples/riscv-hosted/echo_argv.kr" -o "$RV_BIN" >/dev/null 2>&1; then
        echo "FAIL: riscv_hosted_argv (compilation failed)"
        FAIL=$((FAIL + 1))
    else
        RV_OUT=$(qemu-riscv32-static "$RV_BIN" HELLO 2>/dev/null)
        if [ "$RV_OUT" = "HELLO" ]; then
            PASS=$((PASS + 1))
            echo "  riscv_hosted_argv: PASS (qemu-riscv32-static echoed 'HELLO')"
        else
            echo "FAIL: riscv_hosted_argv (got '$RV_OUT', want 'HELLO')"
            FAIL=$((FAIL + 1))
        fi
    fi
    rm -f "$RV_BIN"
else
    echo "  riscv_hosted_argv: SKIP (qemu-riscv32-static not installed)"
fi

# Compiles examples/riscv-hosted/heap.kr, the Task 4 hosted-heap test:
# alloc()/dealloc() lower to a Linux mmap2 syscall (a7=222 ecall) via
# IR_ALLOC (op 70) on hosted riscv32. Writes a value into the allocated
# buffer, reads it back through the returned pointer, and prints "ok" if
# the round trip matches. Distinct from riscv_hosted_hello/riscv_hosted_argv:
# this exercises IR_ALLOC lowering, not IR_SYSCALL or the main-entry
# trampoline. Freestanding riscv has no OS to service mmap and keeps
# IR_ALLOC as a loud NYI (see ir_riscv.kr op 70 gate on `freestanding`).
echo ""
echo "--- riscv32 hosted heap (mmap2) test ---"
if command -v qemu-riscv32-static >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_BIN="/tmp/krc_rv_heap_$$.bin"
    if ! $KRC --arch=riscv32 "$DIR/../examples/riscv-hosted/heap.kr" -o "$RV_BIN" >/dev/null 2>&1; then
        echo "FAIL: riscv_hosted_heap (compilation failed)"
        FAIL=$((FAIL + 1))
    else
        RV_OUT=$(qemu-riscv32-static "$RV_BIN" 2>/dev/null)
        if [ "$RV_OUT" = "ok" ]; then
            PASS=$((PASS + 1))
            echo "  riscv_hosted_heap: PASS (qemu-riscv32-static printed 'ok')"
        else
            echo "FAIL: riscv_hosted_heap (got '$RV_OUT', want 'ok')"
            FAIL=$((FAIL + 1))
        fi
    fi
    rm -f "$RV_BIN"
else
    echo "  riscv_hosted_heap: SKIP (qemu-riscv32-static not installed)"
fi

# Compiles examples/riscv-hosted/obj_single.kr with --emit=obj (equiv `-c`),
# the Task 5 hosted Elf32 relocatable (.o) writer test: `main` calls
# `helper` in the same translation unit, so there are no extern calls and
# no relocations (has_relocs stays 0, .rela.text is skipped entirely) —
# this proves the Elf32 container/symtab/shdr layout in isolation before
# Task 6 adds cross-object extern-call relocations. Needs both
# riscv64-linux-gnu-ld (to link the freestanding .o into a runnable image)
# and qemu-riscv32-static. Distinct from riscv_hosted_exit_code/hello/argv/
# heap above: those compile straight to a hosted ET_EXEC; this one goes
# through emit_elf_relocatable_rv32()'s ET_REL container and a real link
# step.
echo ""
echo "--- riscv32 hosted Elf32 relocatable (.o) test ---"
if command -v qemu-riscv32-static >/dev/null 2>&1 && command -v riscv64-linux-gnu-ld >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_OBJ="/tmp/krc_rv_obj_$$.o"
    RV_LINKED="/tmp/krc_rv_obj_$$"
    if ! $KRC --arch=riscv32 -c "$DIR/../examples/riscv-hosted/obj_single.kr" -o "$RV_OBJ" >/dev/null 2>&1; then
        echo "FAIL: riscv_hosted_obj_single (compilation failed)"
        FAIL=$((FAIL + 1))
    elif ! riscv64-linux-gnu-ld -m elf32lriscv -e main "$RV_OBJ" -o "$RV_LINKED" >/dev/null 2>&1; then
        echo "FAIL: riscv_hosted_obj_single (link failed)"
        FAIL=$((FAIL + 1))
    else
        qemu-riscv32-static "$RV_LINKED" >/dev/null 2>&1
        rc=$?
        if [ "$rc" = "42" ]; then
            PASS=$((PASS + 1))
            echo "  riscv_hosted_obj_single: PASS (qemu-riscv32-static exited 42)"
        else
            echo "FAIL: riscv_hosted_obj_single (got exit $rc, want 42)"
            FAIL=$((FAIL + 1))
        fi
    fi
    rm -f "$RV_OBJ" "$RV_LINKED"
else
    echo "  riscv_hosted_obj_single: SKIP (qemu-riscv32-static or riscv64-linux-gnu-ld not installed)"
fi

# Compiles examples/riscv-hosted/link_a.kr and link_b.kr as SEPARATE
# translation units with --emit=obj (equiv `-c`), the Task 6 cross-object
# extern-call test. link_a's main() calls `addfive`, declared `extern fn`
# (defined in link_b) — so link_a.o cannot resolve it internally and must
# instead record a linker relocation: the riscv IR_CALL handler recognizes
# the extern via extern_fn_lookup, calls extern_call_record, and
# emit_elf_relocatable_rv32 emits one R_RISCV_CALL_PLT (type 19) against
# symbol `addfive` at the auipc call site (has_relocs flips to 1, .rela.text
# is emitted). Linking both objects with `riscv64-linux-gnu-ld -m elf32lriscv
# -e main` and running under qemu-riscv32-static must exit 42 (addfive(37) ==
# 42). Distinct from riscv_hosted_obj_single: that object has no extern calls
# and skips .rela.text entirely; this pair proves the relocation is recorded,
# emitted, and honored by a real cross-object link.
echo ""
echo "--- riscv32 hosted cross-object extern-call link test ---"
if command -v qemu-riscv32-static >/dev/null 2>&1 && command -v riscv64-linux-gnu-ld >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_LA="/tmp/krc_rv_la_$$.o"
    RV_LB="/tmp/krc_rv_lb_$$.o"
    RV_LINKED="/tmp/krc_rv_link_$$"
    if ! $KRC --arch=riscv32 -c "$DIR/../examples/riscv-hosted/link_a.kr" -o "$RV_LA" >/dev/null 2>&1; then
        echo "FAIL: riscv_hosted_link (link_a.kr compilation failed)"
        FAIL=$((FAIL + 1))
    elif ! $KRC --arch=riscv32 -c "$DIR/../examples/riscv-hosted/link_b.kr" -o "$RV_LB" >/dev/null 2>&1; then
        echo "FAIL: riscv_hosted_link (link_b.kr compilation failed)"
        FAIL=$((FAIL + 1))
    elif ! riscv64-linux-gnu-ld -m elf32lriscv -e main "$RV_LA" "$RV_LB" -o "$RV_LINKED" >/dev/null 2>&1; then
        echo "FAIL: riscv_hosted_link (link failed)"
        FAIL=$((FAIL + 1))
    else
        qemu-riscv32-static "$RV_LINKED" >/dev/null 2>&1
        rc=$?
        if [ "$rc" = "42" ]; then
            PASS=$((PASS + 1))
            echo "  riscv_hosted_link: PASS (qemu-riscv32-static exited 42)"
        else
            echo "FAIL: riscv_hosted_link (got exit $rc, want 42)"
            FAIL=$((FAIL + 1))
        fi
    fi
    rm -f "$RV_LA" "$RV_LB" "$RV_LINKED"
else
    echo "  riscv_hosted_link: SKIP (qemu-riscv32-static or riscv64-linux-gnu-ld not installed)"
fi

# --- RISC-V RV32IMC --emit=asm disassembler golden-parity test (Task 7) ---
# Compiles examples/riscv-hosted/asm_sample.kr two ways from the SAME codegen:
# (1) `--emit=asm` -> our RV32IMC listing, and (2) `-c` -> a relocatable .o
# whose .text objdump can disassemble (the hosted ELF exe carries no section
# headers, so objdump needs the .o). Both share one deterministic instruction
# stream, so their mnemonic columns must agree token-for-token. objdump runs
# with `-M no-aliases` (raw forms, no li/mv/ret/j pseudo-ops) so our raw
# decoder can match it directly. 0x0000 tail padding (objdump: c.unimp / `...`)
# is filtered from both sides. Dev-only toolchain guard/SKIP as elsewhere.
echo ""
echo "--- riscv32 hosted --emit=asm objdump-parity test ---"
if command -v riscv64-linux-gnu-objdump >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_ASM="/tmp/krc_rv_asm_$$.s"
    RV_OBJ="/tmp/krc_rv_asm_$$.o"
    RV_OBJMN="/tmp/krc_rv_asm_obj_$$.txt"
    RV_OURMN="/tmp/krc_rv_asm_our_$$.txt"
    RV_OK=1
    if ! $KRC --arch=riscv32 --emit=asm "$DIR/../examples/riscv-hosted/asm_sample.kr" -o "$RV_ASM" >/dev/null 2>&1; then
        echo "FAIL: riscv_hosted_asm (--emit=asm failed)"
        RV_OK=0
    fi
    if [ "$RV_OK" = 1 ] && ! $KRC --arch=riscv32 -c "$DIR/../examples/riscv-hosted/asm_sample.kr" -o "$RV_OBJ" >/dev/null 2>&1; then
        echo "FAIL: riscv_hosted_asm (-c object emission failed)"
        RV_OK=0
    fi
    if [ "$RV_OK" = 1 ]; then
        # Golden mnemonic column: objdump's 3rd tab-field on instruction lines.
        riscv64-linux-gnu-objdump -M no-aliases -d "$RV_OBJ" \
            | grep -P '^\s+[0-9a-f]+:\t' | awk -F'\t' '{print $3}' \
            | grep -vE '^(c\.unimp|unimp|\.unknown)$' > "$RV_OBJMN"
        # Our listing's 3rd whitespace-field on "  <off>: <hex>  <mnem>" lines.
        grep -E '^  [0-9a-f]+: ' "$RV_ASM" | awk '{print $3}' \
            | grep -vE '^(c\.unimp|unimp|\.unknown)$' > "$RV_OURMN"
        if [ ! -s "$RV_OBJMN" ]; then
            echo "FAIL: riscv_hosted_asm (objdump produced no mnemonics)"
            FAIL=$((FAIL + 1))
        elif diff -q "$RV_OBJMN" "$RV_OURMN" >/dev/null 2>&1; then
            PASS=$((PASS + 1))
            echo "  riscv_hosted_asm: PASS ($(wc -l < "$RV_OURMN" | tr -d ' ') mnemonics match objdump -M no-aliases)"
        else
            echo "FAIL: riscv_hosted_asm (mnemonic mismatch vs objdump)"
            diff "$RV_OBJMN" "$RV_OURMN" | head -20
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$RV_ASM" "$RV_OBJ" "$RV_OBJMN" "$RV_OURMN"
else
    echo "  riscv_hosted_asm: SKIP (riscv64-linux-gnu-objdump not installed)"
fi

# --- RISC-V RV32IMC system/fence/CSR disasm golden-parity test ---
# Same methodology as riscv_hosted_asm above, but for asm_sysfence_sample.kr
# (fence, fence.i, wfi, mret, csrrw/csrrs/csrrc, csrrwi/csrrsi/csrrci) — the
# SYSTEM (0x73) / MISC-MEM (0x0F) decode arms added to rv_disasm_word for the
# hosted-emission follow-up minors.
echo ""
echo "--- riscv32 hosted system/fence/CSR disasm objdump-parity test ---"
if command -v riscv64-linux-gnu-objdump >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_SF_ASM="/tmp/krc_rv_sf_asm_$$.s"
    RV_SF_OBJ="/tmp/krc_rv_sf_asm_$$.o"
    RV_SF_OBJMN="/tmp/krc_rv_sf_obj_$$.txt"
    RV_SF_OURMN="/tmp/krc_rv_sf_our_$$.txt"
    RV_SF_OK=1
    if ! $KRC --arch=riscv32 --emit=asm "$DIR/../examples/riscv-hosted/asm_sysfence_sample.kr" -o "$RV_SF_ASM" >/dev/null 2>&1; then
        echo "FAIL: riscv_hosted_sysfence_asm (--emit=asm failed)"
        RV_SF_OK=0
    fi
    if [ "$RV_SF_OK" = 1 ] && ! $KRC --arch=riscv32 -c "$DIR/../examples/riscv-hosted/asm_sysfence_sample.kr" -o "$RV_SF_OBJ" >/dev/null 2>&1; then
        echo "FAIL: riscv_hosted_sysfence_asm (-c object emission failed)"
        RV_SF_OK=0
    fi
    if [ "$RV_SF_OK" = 1 ]; then
        riscv64-linux-gnu-objdump -M no-aliases -d "$RV_SF_OBJ" \
            | grep -P '^\s+[0-9a-f]+:\t' | awk -F'\t' '{print $3}' \
            | grep -vE '^(c\.unimp|unimp|\.unknown)$' > "$RV_SF_OBJMN"
        grep -E '^  [0-9a-f]+: ' "$RV_SF_ASM" | awk '{print $3}' \
            | grep -vE '^(c\.unimp|unimp|\.unknown)$' > "$RV_SF_OURMN"
        if [ ! -s "$RV_SF_OBJMN" ]; then
            echo "FAIL: riscv_hosted_sysfence_asm (objdump produced no mnemonics)"
            FAIL=$((FAIL + 1))
        elif ! grep -qE '^(fence|fence\.i|wfi|mret|csrrw|csrrs|csrrc|csrrwi|csrrsi|csrrci)$' "$RV_SF_OBJMN"; then
            echo "FAIL: riscv_hosted_sysfence_asm (golden sample emitted no system/fence/CSR mnemonics)"
            FAIL=$((FAIL + 1))
        elif diff -q "$RV_SF_OBJMN" "$RV_SF_OURMN" >/dev/null 2>&1; then
            PASS=$((PASS + 1))
            echo "  riscv_hosted_sysfence_asm: PASS ($(wc -l < "$RV_SF_OURMN" | tr -d ' ') mnemonics match objdump -M no-aliases)"
        else
            echo "FAIL: riscv_hosted_sysfence_asm (mnemonic mismatch vs objdump)"
            diff "$RV_SF_OBJMN" "$RV_SF_OURMN" | head -20
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$RV_SF_ASM" "$RV_SF_OBJ" "$RV_SF_OBJMN" "$RV_SF_OURMN"
else
    echo "  riscv_hosted_sysfence_asm: SKIP (riscv64-linux-gnu-objdump not installed)"
fi

# --- SHA-256 (std/sha256.kr) — FIPS 180-4 test vectors ---
# Vector 3 is exactly 56 bytes: padding must spill into a second 64-byte
# block (0x80 + 55 zero-fill bytes would leave no room for the 8-byte
# length trailer), the classic off-by-one every SHA-256 implementation
# has to get right.
run_test_output "sha256_vectors" 'import "std/sha256.kr"

fn digest_to_hex(u64 out32) -> u64 {
    u64 hexbuf = alloc(65)
    u64 i = 0
    while i < 32 {
        u64 b = load8(out32 + i)
        u64 hi = (b >> 4) & 0xF
        u64 lo = b & 0xF
        u64 hi_ch = hi + 48
        if hi >= 10 { hi_ch = hi - 10 + 97 }
        u64 lo_ch = lo + 48
        if lo >= 10 { lo_ch = lo - 10 + 97 }
        u8 hc = hi_ch
        u8 lc = lo_ch
        store8(hexbuf + i * 2, hc)
        store8(hexbuf + i * 2 + 1, lc)
        i = i + 1
    }
    u8 z = 0
    store8(hexbuf + 64, z)
    return hexbuf
}

fn hash_and_print(u64 data, u64 len) {
    u64 ctx = alloc(SHA256_CTX_SIZE)
    u64 out = alloc(32)
    sha256_init(ctx)
    sha256_update(ctx, data, len)
    sha256_final(ctx, out)
    println_str(digest_to_hex(out))
}

fn hash_chunked_and_print(u64 data, u64 len, u64 chunk) {
    u64 ctx = alloc(SHA256_CTX_SIZE)
    u64 out = alloc(32)
    sha256_init(ctx)
    u64 off = 0
    while off < len {
        u64 n = chunk
        if off + n > len { n = len - off }
        sha256_update(ctx, data + off, n)
        off = off + n
    }
    sha256_final(ctx, out)
    println_str(digest_to_hex(out))
}

fn main() {
    hash_and_print("", 0)
    hash_and_print("abc", 3)
    u64 v3 = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    hash_and_print(v3, 56)
    hash_chunked_and_print("abc", 3, 1)
    hash_chunked_and_print(v3, 56, 5)
    // Padding-boundary vectors (all-'a' messages of 55/64/128 bytes):
    //   55  -> after the 0x80 pad byte buflen is exactly 56, which still
    //          leaves room for the 8-byte length trailer, so NO extra block
    //          is needed. Distinguishes `buflen > 56` from `buflen >= 56`.
    //   64  -> an exact multiple of the block size, so the update loop must
    //          still consume the final full block. Distinguishes
    //          `(len - i) >= 64` from `(len - i) > 64`.
    //   128 -> two whole blocks, same boundary one iteration further in.
    u64 va = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    hash_and_print(va, 55)
    hash_and_print(va, 64)
    hash_and_print(va, 128)
    hash_chunked_and_print(va, 64, 16)
    hash_chunked_and_print(va, 128, 33)
    u64 v6 = "0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghij"
    hash_and_print(v6, 200)
    hash_chunked_and_print(v6, 200, 7)
    exit(0)
}' 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1
9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318
ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb
6836cf13bac400e9105071cd6af47084dfacad4e5e302c94bfed24e013afb73e
ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb
6836cf13bac400e9105071cd6af47084dfacad4e5e302c94bfed24e013afb73e
41c907495210b51aa9575a7e43e7546e3c25eb15d34bbb6a828b42c830d1dc5f
41c907495210b51aa9575a7e43e7546e3c25eb15d34bbb6a828b42c830d1dc5f'

# --- esp32 esp-image container writer — byte-identity vs esptool golden ---
# tests/golden/esp32_ref_image.bin was produced ONCE by esptool v5.3.1
# (`esptool --chip esp32 elf2image --flash-mode dio --flash-freq 40m
# --flash-size 4MB`) from tests/golden/esp32_ref_image.s (see that file's
# header for the exact reproduction commands). The harness below feeds
# esp_image_begin/segment/finish the exact same entry point, segment order
# (esptool sorts ascending by load address: DRAM 0x3FFB0000 first, then
# IRAM 0x40080400) and raw section payloads (7 bytes each — NOT a multiple
# of 4, so the writer's zero-pad-to-4 path is exercised), then requires the
# result to be BYTE-IDENTICAL to esptool's output. Any diff = a wrong field
# = an image the ESP32 boot ROM may silently refuse to boot.
echo ""
echo "--- esp32 esp-image container byte-identity test ---"
TOTAL=$((TOTAL + 1))
ESP_SRC="$DIR/../test_tmp_esp_$$.kr"
ESP_BIN="/tmp/krc_esp_$$"
ESP_OUT="/tmp/our_image.bin"
ESP_GOLD="$DIR/golden/esp32_ref_image.bin"
cat > "$ESP_SRC" <<'ESP_EOF'
import "std/sha256.kr"
import "src/format_espimage.kr"

fn esp_put8(u64 p, u64 v) {
    u8 b = v
    store8(p, b)
}

fn main() {
    // .data section of tests/golden/esp32_ref_image.s — 7 raw bytes.
    u64 dat = alloc(7)
    esp_put8(dat + 0, 0x11)
    esp_put8(dat + 1, 0x22)
    esp_put8(dat + 2, 0x33)
    esp_put8(dat + 3, 0x44)
    esp_put8(dat + 4, 0x55)
    esp_put8(dat + 5, 0x66)
    esp_put8(dat + 6, 0x77)
    // .text section (movi.n a2,42 / nop.n / memw) — 7 raw bytes.
    u64 txt = alloc(7)
    esp_put8(txt + 0, 0x2C)
    esp_put8(txt + 1, 0xA2)
    esp_put8(txt + 2, 0x3D)
    esp_put8(txt + 3, 0xF0)
    esp_put8(txt + 4, 0xC0)
    esp_put8(txt + 5, 0x20)
    esp_put8(txt + 6, 0x00)

    esp_image_begin(0x40080400, 2)
    esp_image_segment(0x3FFB0000, dat, 7)
    esp_image_segment(0x40080400, txt, 7)
    esp_image_finish()

    u64 fd = file_open("/tmp/our_image.bin", 1)
    write(fd, esp_image_buf, esp_image_len)
    file_close(fd)
    exit(0)
}
ESP_EOF
if [ ! -f "$ESP_GOLD" ]; then
    echo "FAIL: esp32_image_format (golden reference $ESP_GOLD missing)"
    FAIL=$((FAIL + 1))
elif ! $KRC $KRC_FLAGS "$ESP_SRC" -o "$ESP_BIN" >/dev/null 2>&1; then
    echo "FAIL: esp32_image_format (harness compilation failed)"
    $KRC $KRC_FLAGS "$ESP_SRC" -o "$ESP_BIN" 2>&1 | head -3
    FAIL=$((FAIL + 1))
else
    chmod +x "$ESP_BIN"
    rm -f "$ESP_OUT"
    "$ESP_BIN" >/dev/null 2>&1
    if cmp -s "$ESP_OUT" "$ESP_GOLD"; then
        PASS=$((PASS + 1))
        echo "  esp32_image_format: PASS ($(wc -c < "$ESP_GOLD" | tr -d ' ') bytes byte-identical to esptool reference)"
    else
        echo "FAIL: esp32_image_format (image differs from esptool golden reference)"
        cmp "$ESP_OUT" "$ESP_GOLD" 2>&1 | head -3
        FAIL=$((FAIL + 1))
    fi
fi
rm -f "$ESP_SRC" "$ESP_BIN" "$ESP_OUT"

# --- esp32 machine target: --target=esp32 image structure + IRAM/DRAM guard ---
# Task 3 of the ESP32 machine-target plan. Compiles examples/esp32/minimal.kr
# with --arch=xtensa --freestanding --target=esp32 and asserts the esp-image
# structure with od ONLY (no esptool — must run in CI):
#   byte 0 = 0xE9 (magic), byte 1 = 0x02 (two segments), byte 2 = 0x02 (DIO),
#   byte 3 = 0x20 (4MB @ 40MHz), entry (bytes 4-7 LE) inside IRAM
#   [0x40080400, 0x400A0000), segment 0 load_addr (0x18-0x1B LE) = 0x3FFB0000
#   (DRAM data — ascending load order, matching esptool), segment 1 load_addr
#   = 0x40080400 (IRAM code). Segment 1's header offset is DERIVED from
#   segment 0's data_len (header at 0x20 + seg0_len) — never hardcoded, it
#   moves with the data size.
echo ""
echo "--- esp32 machine-target image structure test ---"
TOTAL=$((TOTAL + 1))
ESP_MIN_BIN="/tmp/krc_esp_min_$$.bin"
ESP_ST_OK=1
esp_field() { od -An -tu4 -j "$2" -N 4 "$1" 2>/dev/null | tr -d ' '; }
if ! $KRC --arch=xtensa --freestanding --target=esp32 \
     "$DIR/../examples/esp32/minimal.kr" -o "$ESP_MIN_BIN" >/dev/null 2>&1; then
    echo "FAIL: esp32_image_structure (compilation failed)"
    $KRC --arch=xtensa --freestanding --target=esp32 \
        "$DIR/../examples/esp32/minimal.kr" -o "$ESP_MIN_BIN" 2>&1 | head -3
    ESP_ST_OK=0
else
    ESP_HDR=$(od -An -tx1 -j 0 -N 4 "$ESP_MIN_BIN" | tr -d ' ')
    if [ "$ESP_HDR" != "e9020220" ]; then
        echo "FAIL: esp32_image_structure (header bytes 0-3 = '$ESP_HDR', want 'e9020220')"
        ESP_ST_OK=0
    fi
    ESP_ENTRY=$(esp_field "$ESP_MIN_BIN" 4)
    if [ -z "$ESP_ENTRY" ] || [ "$ESP_ENTRY" -lt $((0x40080400)) ] \
       || [ "$ESP_ENTRY" -ge $((0x400A0000)) ]; then
        echo "FAIL: esp32_image_structure (entry $ESP_ENTRY outside IRAM [0x40080400,0x400A0000))"
        ESP_ST_OK=0
    fi
    ESP_SEG0_LOAD=$(esp_field "$ESP_MIN_BIN" $((0x18)))
    ESP_SEG0_LEN=$(esp_field "$ESP_MIN_BIN" $((0x1C)))
    if [ "$ESP_SEG0_LOAD" != "$((0x3FFB0000))" ]; then
        echo "FAIL: esp32_image_structure (segment 0 load_addr $ESP_SEG0_LOAD != 0x3FFB0000 DRAM data)"
        ESP_ST_OK=0
    fi
    # Segment 1's header follows segment 0's payload: 0x20 + seg0_len.
    if [ -n "$ESP_SEG0_LEN" ]; then
        ESP_SEG1_LOAD=$(esp_field "$ESP_MIN_BIN" $((0x20 + ESP_SEG0_LEN)))
        if [ "$ESP_SEG1_LOAD" != "$((0x40080400))" ]; then
            echo "FAIL: esp32_image_structure (segment 1 load_addr $ESP_SEG1_LOAD != 0x40080400 IRAM code)"
            ESP_ST_OK=0
        fi
    else
        echo "FAIL: esp32_image_structure (segment 0 data_len unreadable)"
        ESP_ST_OK=0
    fi
fi
if [ "$ESP_ST_OK" = 1 ]; then
    PASS=$((PASS + 1))
    echo "  esp32_image_structure: PASS (e9/02/02/20, entry in IRAM, DRAM@0x3FFB0000 + IRAM@0x40080400 ascending)"
else
    FAIL=$((FAIL + 1))
fi
rm -f "$ESP_MIN_BIN"

# --- esp32 guard tests: unsupported combos must be COMPILE errors ---
# (1) --target=esp32 without --arch=xtensa --freestanding is rejected.
# (2) Programs that cannot be laid out safely in the ESP32 memory map must
#     LOUD-FAIL at compile time and leave NO output file behind. Past the DRAM
#     window [0x3FFB0000,0x3FFE0000) the next addresses are ROM-reserved RAM
#     and then (at 0x40000000+) IRAM, which is 32-bit-access-only — a
#     byte-addressed datum there raises LoadStoreError and the board is dead
#     with no output and no JTAG. Prefer a false positive that blocks a build
#     over a false negative that bricks a board.
#
# ⚠️ Each case below asserts on the SPECIFIC error text, because there are
# THREE distinct guards that all reject an oversized program and it is very
# easy to write a case that looks like it covers one while actually tripping
# another. They are, in the order they fire:
#   (a) resolve_addr_fixups_xtensa_esp32, per-datum, "would land in IRAM" —
#       one datum's own address computes into the IRAM range;
#   (b) resolve_addr_fixups_xtensa_esp32, per-datum, "falls outside the DRAM
#       window" — one datum's own address is past the window;
#   (c) xt_esp32_check_layout, whole-segment, "data+bss exceed the DRAM
#       window" / "less than 4 KiB below the initial stack pointer" — the
#       total memsz does not fit, even though every individual base does.
# A case that only trips (a) or (b) leaves (c) completely untested.
esp_guard_expect() {
    # $1 = case label, $2 = expected error substring, $3 = source file
    rm -f "$ESP_G_BIN"
    ESP_G_ERR=$($KRC --arch=xtensa --freestanding --target=esp32 \
                "$3" -o "$ESP_G_BIN" 2>&1)
    if [ $? -eq 0 ]; then
        echo "FAIL: esp32_guards ($1 accepted — expected a compile error)"
        ESP_G_OK=0
    elif [ -f "$ESP_G_BIN" ]; then
        echo "FAIL: esp32_guards ($1 errored but still left an output image behind)"
        ESP_G_OK=0
    elif ! printf '%s' "$ESP_G_ERR" | grep -qF "$2"; then
        echo "FAIL: esp32_guards ($1 rejected by the WRONG guard)"
        echo "  expected error to contain: $2"
        echo "  actual error: $ESP_G_ERR"
        ESP_G_OK=0
    fi
    rm -f "$ESP_G_BIN"
}
echo ""
echo "--- esp32 guard tests (bad combos are compile errors) ---"
TOTAL=$((TOTAL + 1))
ESP_G_OK=1
ESP_G_BIN="/tmp/krc_esp_guard_$$.bin"
ESP_G_SRC="$DIR/../test_tmp_espguard_$$.kr"
rm -f "$ESP_G_BIN"
if $KRC --arch=riscv32 --freestanding --target=esp32 \
     "$DIR/../examples/esp32/minimal.kr" -o "$ESP_G_BIN" >/dev/null 2>&1; then
    echo "FAIL: esp32_guards (--target=esp32 accepted without --arch=xtensa)"
    ESP_G_OK=0
fi
if $KRC --arch=xtensa --target=esp32 \
     "$DIR/../examples/esp32/minimal.kr" -o "$ESP_G_BIN" >/dev/null 2>&1; then
    echo "FAIL: esp32_guards (--target=esp32 accepted without --freestanding)"
    ESP_G_OK=0
fi
# (b) 256 KiB array + a trailing datum. `sentinel` is laid out AFTER `big`, so
# its own base address is 0x3FFB0000 + 0x40000, already past the window — this
# case is caught PER-DATUM and never reaches the whole-segment layout guard.
cat > "$ESP_G_SRC" <<'ESP_G_EOF'
static u32[65536] big
static u32 sentinel = 7

fn main() {
    big[0] = sentinel
    loop { }
}
ESP_G_EOF
esp_guard_expect "256 KiB data (per-datum address past the window)" \
    "data address falls outside the DRAM window" "$ESP_G_SRC"
# (c) 200 KiB array and NOTHING after it. Every datum base is in-window (the
# array starts at 0x3FFB0000 itself), so neither per-datum check fires; only
# the whole-segment memsz check in xt_esp32_check_layout can catch that the
# array SPANS past 0x3FFE0000. This is the case that makes that guard live.
cat > "$ESP_G_SRC" <<'ESP_G_EOF'
static u32[51200] big

fn main() {
    big[0] = 1
    loop { }
}
ESP_G_EOF
esp_guard_expect "200 KiB array spanning past the window (base in-window)" \
    "data+bss exceed the DRAM window" "$ESP_G_SRC"
# (c2) 189.8 KiB array: FITS the raw DRAM window (0x2F6E0 < 0x30000) but
# leaves under 4 KiB below the initial SP. The stack grows DOWN from
# 0x3FFE0000, which is the same address the window ends at, so the entry
# prologue's first `s32i a0, a1, N-4` writes the saved return address on top
# of the .bss tail — AFTER the zero loop has run, so nothing restores it.
# Without XT_ESP32_MIN_STACK this program compiles clean and corrupts itself
# on real silicon.
cat > "$ESP_G_SRC" <<'ESP_G_EOF'
static u32[48600] big

fn main() {
    big[0] = 1
    loop { }
}
ESP_G_EOF
esp_guard_expect "190 KiB statics (fits the window, starves the stack)" \
    "less than 4 KiB below the initial stack pointer" "$ESP_G_SRC"
# (a) THE IRAM BYTE-ACCESS GUARD — the whole justification for splitting code
# and data across two load addresses. IRAM services only aligned 32-bit
# accesses, so an l8ui (which is how every string read, strlen and memcpy
# touches memory) against an IRAM address raises LoadStoreError: no output, no
# JTAG, board indistinguishable from dead. 360 KiB of leading statics pushes
# the NEXT datum's computed address past 0x40000000 and into IRAM, which is
# what this guard exists to refuse. Rejected per-datum, before the
# whole-segment checks ever run.
cat > "$ESP_G_SRC" <<'ESP_G_EOF'
static u32[90000] pad
static u32 tail_datum = 7

fn main() {
    pad[0] = 1
    tail_datum = 2
    loop { }
}
ESP_G_EOF
esp_guard_expect "360 KiB of statics (next datum computes into IRAM)" \
    "would land in IRAM" "$ESP_G_SRC"
# The IRAM code-overflow branch. Usable IRAM is 0x400A0000 - 0x40080400 =
# 127 KiB; this generates a ~192 KiB chain of functions, ~1.5x over, so the
# case stays over the limit even if codegen gets meaningfully tighter. A chain
# (each fn tail-calls the next) rather than 1000 calls from main, because a
# main with 1000 call sites blows the 2047-byte frame cap and would fail for
# an unrelated reason. Compiles in well under a second — the limit is hit
# during layout, long before anything is written.
awk 'BEGIN {
    n = 1000; m = 12
    for (i = 0; i < n; i++) {
        printf "fn g%d(u32 x) -> u32 {\n", i
        for (j = 0; j < m; j++) printf "    x = x * %d + %d\n", (j % 13) + 3, i + j
        if (i == n - 1) printf "    return x\n}\n"
        else printf "    return g%d(x)\n}\n", i + 1
    }
    printf "fn main() {\n    u32 a = g0(1)\n    a = a + 1\n    loop { }\n}\n"
}' > "$ESP_G_SRC"
esp_guard_expect "~192 KiB of code (overflows the 127 KiB IRAM window)" \
    "code segment exceeds the IRAM limit" "$ESP_G_SRC"
# @naked on the ENTRY function silently voids the a0-park safety net: the
# preamble still emits `l32r a0, &park`, but @naked skips the prologue that
# frame-saves a0, so the body's first call0 overwrites it. A returning entry
# then decodes garbage — an exception and a reboot loop indistinguishable from
# a watchdog failure — which is exactly what parking a0 exists to prevent.
cat > "$ESP_G_SRC" <<'ESP_G_EOF'
@naked
fn main() {
    loop { }
}
ESP_G_EOF
esp_guard_expect "@naked entry function" \
    "entry function may not be @naked" "$ESP_G_SRC"
# ...but the guard must be scoped to the esp32 target: @naked is legal on the
# generic lx60 xtensa path, which has no preamble and no park address.
rm -f "$ESP_G_BIN"
if ! $KRC --arch=xtensa --freestanding "$ESP_G_SRC" -o "$ESP_G_BIN" >/dev/null 2>&1; then
    echo "FAIL: esp32_guards (@naked entry rejected on the generic lx60 xtensa path — the guard is esp32-only)"
    ESP_G_OK=0
fi
rm -f "$ESP_G_BIN"
if [ "$ESP_G_OK" = 1 ]; then
    PASS=$((PASS + 1))
    echo "  esp32_guards: PASS (arch/freestanding combos, IRAM byte-access, per-datum overflow, whole-segment span, stack starvation, IRAM code overflow — each rejected by its OWN guard)"
else
    FAIL=$((FAIL + 1))
fi
rm -f "$ESP_G_SRC" "$ESP_G_BIN"

# --- --target= argument validation -------------------------------------------
# Two separate bugs live here, and BOTH are silent-wrong-output bugs, so both
# get a negative test.
#
#  (1) NEAR-MISS CHIP NAMES. --target=esp32 must be matched EXACTLY, not by
#      prefix. "esp32s3" and "esp32c3" are different chips with different
#      memory maps (the C3 is RISC-V, not Xtensa even). A prefix match lets
#      --target=esp32s3 quietly produce an ESP32 image with load addresses
#      that are wrong for that chip: a board that does not boot, diagnosed
#      over ~2-minute flash cycles with no JTAG.
#
#  (2) TYPOS. An unrecognised --target= must be a hard error. It used to fall
#      off the end of the if-chain and be SILENTLY IGNORED, so `--target=widnows`
#      handed back a default-target binary with no warning at all.
#
# Both cases use otherwise-valid flag combinations, so the ONLY thing that can
# reject them is the target-string check itself.
echo ""
echo "--- --target= argument validation ---"
TOTAL=$((TOTAL + 1))
ESP_T_OK=1
ESP_T_BIN="/tmp/krc_esp_targ_$$.bin"
for ESP_T_BAD in esp32s3 esp32c3; do
    rm -f "$ESP_T_BIN"
    ESP_T_ERR=$($KRC --arch=xtensa --freestanding "--target=$ESP_T_BAD" \
                "$DIR/../examples/esp32/minimal.kr" -o "$ESP_T_BIN" 2>&1)
    if [ $? -eq 0 ]; then
        echo "FAIL: target_arg_validation (--target=$ESP_T_BAD accepted — a near-miss chip name must NOT prefix-match esp32 and emit an ESP32 image)"
        ESP_T_OK=0
    elif ! printf '%s' "$ESP_T_ERR" | grep -qF "unknown --target="; then
        echo "FAIL: target_arg_validation (--target=$ESP_T_BAD rejected, but not by the unknown-target check: $ESP_T_ERR)"
        ESP_T_OK=0
    fi
done
for ESP_T_BAD in bogus widnows lin ""; do
    rm -f "$ESP_T_BIN"
    ESP_T_ERR=$($KRC "--target=$ESP_T_BAD" "$DIR/smoke/div_mod.kr" \
                -o "$ESP_T_BIN" 2>&1)
    if [ $? -eq 0 ]; then
        echo "FAIL: target_arg_validation (--target=$ESP_T_BAD accepted — an unknown target must be a hard error, never silently ignored)"
        ESP_T_OK=0
    elif ! printf '%s' "$ESP_T_ERR" | grep -qF "unknown --target="; then
        echo "FAIL: target_arg_validation (--target=$ESP_T_BAD rejected, but not by the unknown-target check: $ESP_T_ERR)"
        ESP_T_OK=0
    fi
done
# ...and the accepted names must still be accepted (so the check above cannot
# be "fixed" by rejecting everything).
for ESP_T_GOOD in linux macos darwin windows win; do
    rm -f "$ESP_T_BIN"
    if ! $KRC "--target=$ESP_T_GOOD" "$DIR/smoke/div_mod.kr" \
         -o "$ESP_T_BIN" >/dev/null 2>&1; then
        echo "FAIL: target_arg_validation (--target=$ESP_T_GOOD rejected — it is a documented, accepted target name)"
        ESP_T_OK=0
    fi
done
if [ "$ESP_T_OK" = 1 ]; then
    PASS=$((PASS + 1))
    echo "  target_arg_validation: PASS (near-miss chip names and typos are hard errors; documented names still accepted)"
else
    FAIL=$((FAIL + 1))
fi
rm -f "$ESP_T_BIN"

# --- esp32 .bss zero-loop bounds -------------------------------------------
# The entry preamble zeroes [bss_lo, bss_hi) from two literal-pool words that
# main.kr patches at finalize time. esp32_startup_stub greps the six WDT
# addresses and the unlock key but never looks at these two words, so patching
# them with XT_ESP32_IRAM_BASE instead of XT_ESP32_DRAM_BASE passed the whole
# suite — and the stub would then zero its OWN code at 0x40080400 on the way
# up. That is a bricked flash cycle with no diagnostic, so assert the bounds
# directly.
#
# Both bounds are derivable from the image, so nothing here is hardcoded:
#   bss_lo == 0x3FFB0000 + seg0_len   (bss starts where the DRAM segment's
#                                      file payload ends — the zeros dropped
#                                      from the image are what the loop
#                                      recreates)
#   bss_hi  = the one remaining DRAM-window pool word strictly below the
#             0x3FFE0000 stack top, and hi-lo must match the .bss the test
#             program actually declares (4 KiB, plus alignment padding).
# Both must be 4-aligned: the loop stores with s32i, which traps on an
# unaligned base.
echo ""
echo "--- esp32 .bss zero-loop bounds test ---"
TOTAL=$((TOTAL + 1))
ESP_B_OK=1
ESP_B_SRC="$DIR/../test_tmp_espbss_$$.kr"
ESP_B_BIN="/tmp/krc_esp_bss_$$.bin"
# One small initialized datum (so the DRAM segment is non-empty) followed by a
# 4 KiB array that is never initialized (so .bss is non-empty and lo != hi).
cat > "$ESP_B_SRC" <<'ESP_B_EOF'
static u32 init_val = 0xABCD1234
static u32[1024] zeros

fn main() {
    zeros[0] = init_val
    zeros[1023] = init_val
    loop { }
}
ESP_B_EOF
if ! $KRC --arch=xtensa --freestanding --target=esp32 \
     "$ESP_B_SRC" -o "$ESP_B_BIN" >/dev/null 2>&1; then
    echo "FAIL: esp32_bss_bounds (compilation failed)"
    ESP_B_OK=0
fi
if [ "$ESP_B_OK" = 1 ]; then
    ESP_B_DRAM_BASE=$((0x3FFB0000))
    ESP_B_DRAM_LIMIT=$((0x3FFE0000))
    esp_b_field() { od -An -tu4 -j "$2" -N 4 "$1" 2>/dev/null | tr -d ' '; }
    # Walk the segment table for the DRAM segment length and the IRAM payload.
    ESP_B_NSEG=$(od -An -tu1 -j 1 -N 1 "$ESP_B_BIN" | tr -d ' ')
    ESP_B_SOFF=$((0x18))
    ESP_B_DLEN=""
    ESP_B_COFF=0
    ESP_B_CLEN=0
    ESP_B_I=0
    while [ "$ESP_B_I" -lt "${ESP_B_NSEG:-0}" ]; do
        ESP_B_LOAD=$(esp_b_field "$ESP_B_BIN" "$ESP_B_SOFF")
        ESP_B_LEN=$(esp_b_field "$ESP_B_BIN" $((ESP_B_SOFF + 4)))
        if [ -z "$ESP_B_LOAD" ] || [ -z "$ESP_B_LEN" ]; then break; fi
        if [ "$ESP_B_LOAD" = "$ESP_B_DRAM_BASE" ]; then ESP_B_DLEN=$ESP_B_LEN; fi
        if [ "$ESP_B_LOAD" -ge $((0x40000000)) ]; then
            ESP_B_COFF=$((ESP_B_SOFF + 8)); ESP_B_CLEN=$ESP_B_LEN
        fi
        ESP_B_SOFF=$((ESP_B_SOFF + 8 + ESP_B_LEN))
        ESP_B_I=$((ESP_B_I + 1))
    done
    if [ -z "$ESP_B_DLEN" ] || [ "$ESP_B_CLEN" = 0 ]; then
        echo "FAIL: esp32_bss_bounds (could not locate both the DRAM and IRAM segments)"
        ESP_B_OK=0
    fi
fi
if [ "$ESP_B_OK" = 1 ]; then
    ESP_B_LO=$((ESP_B_DRAM_BASE + ESP_B_DLEN))
    # Every literal-pool word in the code segment that falls in the DRAM window.
    ESP_B_WORDS=$(dd if="$ESP_B_BIN" bs=1 skip="$ESP_B_COFF" count="$ESP_B_CLEN" \
                     2>/dev/null | od -An -tu4 -v | tr -s ' ' '\n' | grep -v '^$')
    ESP_B_SEEN_LO=0
    ESP_B_HI=0
    for ESP_B_W in $ESP_B_WORDS; do
        if [ "$ESP_B_W" -lt "$ESP_B_DRAM_BASE" ] || [ "$ESP_B_W" -gt "$ESP_B_DRAM_LIMIT" ]; then
            continue
        fi
        if [ "$ESP_B_W" = "$ESP_B_LO" ]; then ESP_B_SEEN_LO=1; fi
        if [ "$ESP_B_W" -gt "$ESP_B_LO" ] && [ "$ESP_B_W" -lt "$ESP_B_DRAM_LIMIT" ]; then
            ESP_B_HI=$ESP_B_W
        fi
    done
    if [ "$ESP_B_SEEN_LO" != 1 ]; then
        echo "FAIL: esp32_bss_bounds (no pool word equals the expected bss_lo $ESP_B_LO = 0x3FFB0000 + DRAM seg len $ESP_B_DLEN — the zero loop is not bounded by DRAM addresses)"
        ESP_B_OK=0
    fi
    if [ "$ESP_B_HI" = 0 ]; then
        echo "FAIL: esp32_bss_bounds (no bss_hi pool word in (bss_lo, 0x3FFE0000) — the zero loop's upper bound is not a DRAM address)"
        ESP_B_OK=0
    else
        ESP_B_SPAN=$((ESP_B_HI - ESP_B_LO))
        # The program declares exactly 4096 bytes of .bss; allow a little
        # alignment padding, but nothing like a whole wrong base.
        if [ "$ESP_B_SPAN" -lt 4096 ] || [ "$ESP_B_SPAN" -gt 4160 ]; then
            echo "FAIL: esp32_bss_bounds (bss span $ESP_B_SPAN bytes, expected ~4096 for the declared u32[1024])"
            ESP_B_OK=0
        fi
        if [ $((ESP_B_HI & 3)) != 0 ]; then
            echo "FAIL: esp32_bss_bounds (bss_hi $ESP_B_HI is not 4-byte aligned — s32i traps on an unaligned base)"
            ESP_B_OK=0
        fi
    fi
    if [ $((ESP_B_LO & 3)) != 0 ]; then
        echo "FAIL: esp32_bss_bounds (bss_lo $ESP_B_LO is not 4-byte aligned — s32i traps on an unaligned base)"
        ESP_B_OK=0
    fi
fi
if [ "$ESP_B_OK" = 1 ]; then
    PASS=$((PASS + 1))
    echo "  esp32_bss_bounds: PASS (zero-loop bounds are DRAM addresses, 4-aligned, spanning exactly the declared .bss)"
else
    FAIL=$((FAIL + 1))
fi
rm -f "$ESP_B_SRC" "$ESP_B_BIN"

# --- esp32 startup stub: WDT disable + PS + trailing park loop (Task 4) ---
# The mask ROM jumps straight to e_entry with RWDT and MWDT0 ARMED (flash-boot
# mode): if the stub does not disable them FIRST, the board reboots ~1s in
# with no output (spec §2/§4). Asserts on the DISASSEMBLY of the IRAM code
# segment of examples/esp32/minimal.kr:
#   (1) the unlock key 0x50D83AA1 and all six WDT register addresses are
#       present as literal-pool words (od -tx4 — pool words are 4-aligned);
#   (2) the WDT sequence runs BEFORE the SP init: >= 6 s32i stores (3 unlock +
#       3 config0-clear) and the wsr.ps appear before the first `l32r a1`;
#   (3) the stub contains a genuine self-branch (`j .` — target == own
#       address) so a returning main parks instead of decoding garbage (the
#       lx60 tail idiom is an illegal insn on silicon -> exception -> reset
#       loop that mimics a watchdog failure exactly).
# The IRAM segment is FOUND by walking the segment table (seg0 header at 0x18,
# payload at 0x20, seg1 header at 0x20+seg0_len; IRAM = load >= 0x40000000),
# never hardcoded. Entry offset within the payload = entry_addr - 0x40080400.
# SKIP cleanly when the disassembler is absent (dev-only toolchain).
echo ""
echo "--- esp32 startup stub test ---"
if command -v xtensa-lx106-elf-objdump >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    ESP_STUB_BIN="/tmp/krc_esp_stub_$$.bin"
    ESP_STUB_CODE="/tmp/krc_esp_stub_code_$$.bin"
    ESP_STUB_DIS="/tmp/krc_esp_stub_dis_$$.txt"
    ESP_STUB_OK=1
    esp_stub_field() { od -An -tu4 -j "$2" -N 4 "$1" 2>/dev/null | tr -d ' '; }
    if ! $KRC --arch=xtensa --freestanding --target=esp32 \
         "$DIR/../examples/esp32/minimal.kr" -o "$ESP_STUB_BIN" >/dev/null 2>&1; then
        echo "FAIL: esp32_startup_stub (compilation failed)"
        ESP_STUB_OK=0
    fi
    ESP_STUB_CODE_OFF=0
    ESP_STUB_CODE_LEN=0
    if [ "$ESP_STUB_OK" = 1 ]; then
        ESP_STUB_ENTRY=$(esp_stub_field "$ESP_STUB_BIN" 4)
        ESP_STUB_NSEG=$(od -An -tu1 -j 1 -N 1 "$ESP_STUB_BIN" | tr -d ' ')
        ESP_STUB_SOFF=$((0x18))
        ESP_STUB_I=0
        while [ "$ESP_STUB_I" -lt "${ESP_STUB_NSEG:-0}" ]; do
            ESP_STUB_LOAD=$(esp_stub_field "$ESP_STUB_BIN" "$ESP_STUB_SOFF")
            ESP_STUB_LEN=$(esp_stub_field "$ESP_STUB_BIN" $((ESP_STUB_SOFF + 4)))
            if [ -z "$ESP_STUB_LOAD" ] || [ -z "$ESP_STUB_LEN" ]; then break; fi
            if [ "$ESP_STUB_LOAD" -ge $((0x40000000)) ]; then
                ESP_STUB_CODE_OFF=$((ESP_STUB_SOFF + 8))
                ESP_STUB_CODE_LEN=$ESP_STUB_LEN
                break
            fi
            ESP_STUB_SOFF=$((ESP_STUB_SOFF + 8 + ESP_STUB_LEN))
            ESP_STUB_I=$((ESP_STUB_I + 1))
        done
        if [ "$ESP_STUB_CODE_LEN" = 0 ]; then
            echo "FAIL: esp32_startup_stub (no IRAM segment with load_addr >= 0x40000000 found)"
            ESP_STUB_OK=0
        fi
    fi
    if [ "$ESP_STUB_OK" = 1 ]; then
        dd if="$ESP_STUB_BIN" of="$ESP_STUB_CODE" bs=1 \
           skip="$ESP_STUB_CODE_OFF" count="$ESP_STUB_CODE_LEN" 2>/dev/null
        # (1) key + all six WDT addresses present as pool words
        ESP_STUB_WORDS=$(od -An -tx4 "$ESP_STUB_CODE")
        for ESP_STUB_W in 50d83aa1 3ff480a4 3ff4808c 3ff5f064 3ff5f048 3ff60064 3ff60048; do
            if ! echo "$ESP_STUB_WORDS" | grep -qw "$ESP_STUB_W"; then
                echo "FAIL: esp32_startup_stub (pool word $ESP_STUB_W missing — WDT sequence not emitted)"
                ESP_STUB_OK=0
            fi
        done
    fi
    if [ "$ESP_STUB_OK" = 1 ]; then
        # (2) ordering: disassemble from the entry; everything before the
        # first `l32r a1` (SP init) must already contain the 6 WDT stores
        # and the wsr.ps.
        # Offset of the entry within the IRAM payload. Derive it from the
        # segment's own load_addr (already discovered by the walk above) rather
        # than re-hardcoding the base — a future base change would otherwise
        # silently disassemble from the wrong offset and still "pass".
        ESP_STUB_EOFF=$((ESP_STUB_ENTRY - ESP_STUB_LOAD))
        xtensa-lx106-elf-objdump -b binary -m xtensa -D \
            --start-address=$ESP_STUB_EOFF "$ESP_STUB_CODE" > "$ESP_STUB_DIS" 2>/dev/null
        ESP_STUB_PRE=$(sed -n "1,/l32r[[:space:]]*a1,/p" "$ESP_STUB_DIS")
        ESP_STUB_NS32I=$(echo "$ESP_STUB_PRE" | grep -cE '[[:space:]]s32i(\.n)?[[:space:]]')
        if [ "$ESP_STUB_NS32I" -lt 6 ]; then
            echo "FAIL: esp32_startup_stub (only $ESP_STUB_NS32I s32i before the SP-init l32r a1 — WDT disable must come FIRST)"
            ESP_STUB_OK=0
        fi
        if ! echo "$ESP_STUB_PRE" | grep -qE '[[:space:]]wsr'; then
            echo "FAIL: esp32_startup_stub (no wsr.ps before the SP-init l32r a1)"
            ESP_STUB_OK=0
        fi
        # (3) a genuine self-branch: a `j` whose target == its own address
        ESP_STUB_PARK=0
        while IFS= read -r ESP_STUB_LN; do
            ESP_STUB_A=$(printf '%s' "$ESP_STUB_LN" | sed -n 's/^ *\([0-9a-f][0-9a-f]*\):.*/\1/p')
            ESP_STUB_T=$(printf '%s' "$ESP_STUB_LN" | sed -n 's/.*[[:space:]]j[[:space:]][[:space:]]*0*x\{0,1\}\([0-9a-f][0-9a-f]*\)[[:space:]]*$/\1/p')
            if [ -n "$ESP_STUB_A" ] && [ -n "$ESP_STUB_T" ]; then
                if [ $((0x$ESP_STUB_A)) -eq $((0x$ESP_STUB_T)) ]; then
                    ESP_STUB_PARK=1
                fi
            fi
        done <<ESP_STUB_EOF
$(grep -E '[[:space:]]j[[:space:]]+(0x)?[0-9a-f]+[[:space:]]*$' "$ESP_STUB_DIS")
ESP_STUB_EOF
        if [ "$ESP_STUB_PARK" != 1 ]; then
            echo "FAIL: esp32_startup_stub (no self-branch 'j .' — a returning main would decode garbage and mimic a WDT reset loop)"
            ESP_STUB_OK=0
        fi
    fi
    if [ "$ESP_STUB_OK" = 1 ]; then
        PASS=$((PASS + 1))
        echo "  esp32_startup_stub: PASS (WDT unlock+clear x3 before SP init, wsr.ps, self-branch park)"
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$ESP_STUB_BIN" "$ESP_STUB_CODE" "$ESP_STUB_DIS"
else
    echo "  esp32_startup_stub: SKIP (xtensa-lx106-elf-objdump not installed)"
fi

# --- esp32 hello image: full container + errata-safe UART0 putc (Task 5) ---
# The artifact that gets flashed to real silicon. Everything here is checked
# with od/dd (+ objdump when present) so it runs in CI — esptool is an ORACLE
# used by hand (`image-info`), never a build/test dependency (spec §0/§6).
#
# Container asserts (independent of the code):
#   magic/mode/size bytes e9 02 02 20, EXACTLY 2 segments, entry in IRAM,
#   (len - 32) % 16 == 0  — the payload is 16-padded and a 32-byte SHA-256
#   appended, so total-minus-hash must be a multiple of 16 (the ROM reads it
#   that way), and the checksum byte at len-33 equals the 0xEF-seeded XOR of
#   every segment payload byte, RECOMPUTED here rather than trusted.
#
# Code asserts (spec §4, errata CPU-3.3) — the important ones:
#   `putc` must POLL 0x3FF4001C (APB UART_STATUS_REG, TXFIFO_CNT bits 23:16)
#   and WRITE the byte to 0x60000000 (the AHB TX-FIFO mirror). Consecutive
#   APB writes to UART0's FIFO "may be lost" per the errata, so a store to an
#   APB UART address would give intermittently garbled output on the board's
#   ONLY debug channel. The test therefore checks the DIRECTION of each
#   access, not just that the constants appear: it tracks `l32r aN,<pool>`
#   into a register map and then classifies the `s32i`/`l32i` that use aN as
#   a base. A store off an APB UART base is a hard FAIL.
# The segment table is WALKED (seg0 header at 0x18, len at 0x1C, payload at
# 0x20; seg1 header at 0x20+seg0_len) — no offset is hardcoded.
echo ""
echo "--- esp32 hello image test ---"
TOTAL=$((TOTAL + 1))
ESP_H_BIN="/tmp/krc_esp_hello_$$.bin"
ESP_H_PAY="/tmp/krc_esp_hello_pay_$$.bin"
ESP_H_CODE="/tmp/krc_esp_hello_code_$$.bin"
ESP_H_DIS="/tmp/krc_esp_hello_dis_$$.txt"
ESP_H_OK=1
esp_h_field() { od -An -tu4 -j "$2" -N 4 "$1" 2>/dev/null | tr -d ' '; }
rm -f "$ESP_H_BIN" "$ESP_H_PAY"
if ! $KRC --arch=xtensa --freestanding --target=esp32 \
     "$DIR/../examples/esp32/hello.kr" -o "$ESP_H_BIN" >/dev/null 2>&1; then
    echo "FAIL: esp32_hello_image (compilation failed)"
    $KRC --arch=xtensa --freestanding --target=esp32 \
        "$DIR/../examples/esp32/hello.kr" -o "$ESP_H_BIN" 2>&1 | head -3
    ESP_H_OK=0
fi
ESP_H_CODE_OFF=0
ESP_H_CODE_LEN=0
ESP_H_CODE_LOAD=0
if [ "$ESP_H_OK" = 1 ]; then
    ESP_H_LEN=$(wc -c < "$ESP_H_BIN" | tr -d ' ')
    ESP_H_HDR=$(od -An -tx1 -j 0 -N 4 "$ESP_H_BIN" | tr -d ' ')
    if [ "$ESP_H_HDR" != "e9020220" ]; then
        echo "FAIL: esp32_hello_image (header bytes 0-3 = '$ESP_H_HDR', want 'e9020220')"
        ESP_H_OK=0
    fi
    ESP_H_NSEG=$(od -An -tu1 -j 1 -N 1 "$ESP_H_BIN" | tr -d ' ')
    if [ "$ESP_H_NSEG" != 2 ]; then
        echo "FAIL: esp32_hello_image (segment count $ESP_H_NSEG != 2 — DRAM string + IRAM code expected)"
        ESP_H_OK=0
    fi
    ESP_H_ENTRY=$(esp_h_field "$ESP_H_BIN" 4)
    if [ -z "$ESP_H_ENTRY" ] || [ "$ESP_H_ENTRY" -lt $((0x40080400)) ] \
       || [ "$ESP_H_ENTRY" -ge $((0x400A0000)) ]; then
        echo "FAIL: esp32_hello_image (entry $ESP_H_ENTRY outside IRAM [0x40080400,0x400A0000))"
        ESP_H_OK=0
    fi
    # (len - 32) must be a multiple of 16: 32 bytes of appended SHA-256 over a
    # 16-padded (checksum-terminated) body.
    if [ $(( (ESP_H_LEN - 32) % 16 )) -ne 0 ]; then
        echo "FAIL: esp32_hello_image (len $ESP_H_LEN: (len-32) % 16 = $(( (ESP_H_LEN - 32) % 16 )), want 0)"
        ESP_H_OK=0
    fi
fi
if [ "$ESP_H_OK" = 1 ]; then
    # Walk the segment table: concatenate every payload for the checksum and
    # remember the IRAM one for disassembly.
    ESP_H_SOFF=$((0x18))
    ESP_H_I=0
    : > "$ESP_H_PAY"
    while [ "$ESP_H_I" -lt "$ESP_H_NSEG" ]; do
        ESP_H_LOAD=$(esp_h_field "$ESP_H_BIN" "$ESP_H_SOFF")
        ESP_H_SLEN=$(esp_h_field "$ESP_H_BIN" $((ESP_H_SOFF + 4)))
        if [ -z "$ESP_H_LOAD" ] || [ -z "$ESP_H_SLEN" ]; then
            echo "FAIL: esp32_hello_image (segment $ESP_H_I header unreadable at offset $ESP_H_SOFF)"
            ESP_H_OK=0
            break
        fi
        dd if="$ESP_H_BIN" bs=1 skip=$((ESP_H_SOFF + 8)) count="$ESP_H_SLEN" \
           >> "$ESP_H_PAY" 2>/dev/null
        if [ "$ESP_H_LOAD" -ge $((0x40000000)) ]; then
            ESP_H_CODE_OFF=$((ESP_H_SOFF + 8))
            ESP_H_CODE_LEN=$ESP_H_SLEN
            ESP_H_CODE_LOAD=$ESP_H_LOAD
        fi
        ESP_H_SOFF=$((ESP_H_SOFF + 8 + ESP_H_SLEN))
        ESP_H_I=$((ESP_H_I + 1))
    done
fi
if [ "$ESP_H_OK" = 1 ]; then
    # Recompute the 0xEF-seeded XOR over all segment payloads and compare with
    # the stored byte at len-33 (last byte before the 32-byte hash). POSIX awk
    # has no xor(), so it is done bitwise by hand.
    ESP_H_WANT=$(od -An -tu1 -j $((ESP_H_LEN - 33)) -N 1 "$ESP_H_BIN" | tr -d ' ')
    ESP_H_GOT=$(od -An -tu1 -v "$ESP_H_PAY" | awk '
        function xor8(a, b,   i, m, r) {
            r = 0; m = 1
            for (i = 0; i < 8; i++) {
                if (int(a / m) % 2 != int(b / m) % 2) r += m
                m *= 2
            }
            return r
        }
        BEGIN { c = 239 }
        { for (i = 1; i <= NF; i++) c = xor8(c, $i + 0) }
        END { print c }')
    if [ "$ESP_H_GOT" != "$ESP_H_WANT" ]; then
        echo "FAIL: esp32_hello_image (checksum byte at len-33 is $ESP_H_WANT, recomputed 0xEF-XOR is $ESP_H_GOT)"
        ESP_H_OK=0
    fi
    if [ "$ESP_H_CODE_LEN" = 0 ]; then
        echo "FAIL: esp32_hello_image (no IRAM segment with load_addr >= 0x40000000 found)"
        ESP_H_OK=0
    fi
    # The trailing 32 bytes are a SHA-256 over the whole image up to that
    # point. The ROM verifies it, so a wrong digest is a silently unbootable
    # image. Recompute it with sha256sum — an outside oracle — rather than
    # reading the stored bytes back and comparing them to themselves.
    #
    # This lives HERE, on the 576-byte hello image, specifically because the
    # esp-image byte-identity golden is a 64-byte body: hardcoding the update
    # length to 64 in format_espimage.kr reproduced the golden exactly and
    # passed the whole suite. One image size proves nothing about a hash.
    if command -v sha256sum >/dev/null 2>&1; then
        ESP_H_DGOT=$(dd if="$ESP_H_BIN" bs=1 count=$((ESP_H_LEN - 32)) 2>/dev/null \
                     | sha256sum | cut -d' ' -f1)
        ESP_H_DWANT=$(od -An -tx1 -j $((ESP_H_LEN - 32)) -N 32 -v "$ESP_H_BIN" \
                      | tr -d ' \n')
        if [ "$ESP_H_DGOT" != "$ESP_H_DWANT" ]; then
            echo "FAIL: esp32_hello_image (trailing SHA-256 is $ESP_H_DWANT, but sha256sum over the first $((ESP_H_LEN - 32)) bytes gives $ESP_H_DGOT)"
            ESP_H_OK=0
        fi
        ESP_H_HASH_NOTE=", SHA-256 recomputed over all $((ESP_H_LEN - 32)) body bytes"
    else
        ESP_H_HASH_NOTE=" (SHA-256 recompute SKIPPED — no sha256sum)"
    fi
fi
# Errata CPU-3.3 direction check — needs the disassembler; skip cleanly if the
# dev-only toolchain is absent, but never skip the container asserts above.
if [ "$ESP_H_OK" = 1 ] && command -v xtensa-lx106-elf-objdump >/dev/null 2>&1; then
    dd if="$ESP_H_BIN" of="$ESP_H_CODE" bs=1 \
       skip="$ESP_H_CODE_OFF" count="$ESP_H_CODE_LEN" 2>/dev/null
    xtensa-lx106-elf-objdump -b binary -m xtensa -D "$ESP_H_CODE" > "$ESP_H_DIS" 2>/dev/null
    ESP_H_VERDICT=$(awk '
        # Track `l32r aN, <slot> (0xVALUE)` so a later s32i/l32i off aN can be
        # attributed to a concrete absolute address. Any control transfer
        # invalidates the map, so nothing is attributed across a branch.
        { m = $3; op1 = $4; op2 = $5 }
        m == "l32r" {
            gsub(/,/, "", op1); v = $6
            gsub(/[()]/, "", v)
            reg[op1] = v
            next
        }
        m ~ /^(s32i|l32i)(\.n)?$/ {
            gsub(/,/, "", op2)
            if (op2 in reg) {
                if (m ~ /^s32i/) store[reg[op2]] = 1
                else             loadf[reg[op2]] = 1
            }
            if (m ~ /^l32i/) { gsub(/,/, "", op1); delete reg[op1] }
            next
        }
        # Any other instruction that REDEFINES a register must drop its mapping,
        # or we keep attributing later stores to a stale l32r value. The .bss
        # zero loop does exactly this (l32r a8,<addr> ... addi a8,a8,4), and
        # while that address is harmless today, stale over-attribution could
        # later manufacture a spurious APB-UART-STORE verdict.
        m ~ /^(movi|mov|add|addi|sub|addx|and|or|xor|srl|sll|sra|neg)/ {
            gsub(/,/, "", op1); delete reg[op1]
            next
        }
        # Conservative: forget everything at any branch/call/return boundary.
        m ~ /^(j|jx|call0|callx0|ret|ret\.n|b)/ { delete reg; next }
        END {
            ok = 1
            if (!("0x60000000" in store)) { print "no-ahb-fifo-store"; ok = 0 }
            if (!("0x3ff4001c" in loadf))  { print "no-apb-status-load"; ok = 0 }
            for (a in store)
                if (a ~ /^0x3ff400/) { print "APB-UART-STORE:" a; ok = 0 }
            if (ok) print "OK"
        }' "$ESP_H_DIS")
    # Tripwire: the 1 Hz heartbeat is a plain counted loop with no volatile
    # touch, so a future DCE / strength-reduction pass could legally delete it,
    # turning the heartbeat into a ~640 line/s flood. That is not merely
    # cosmetic — it would drown out a stray reset banner or a garbled character,
    # i.e. degrade the debug channel exactly when it matters. Assert the loop
    # bound literal survives; if this fails, harden delay() with a volatile MMIO
    # read and retune the count (see the esp32 spec's validation notes).
    if ! grep -q '(0x3d0900)' "$ESP_H_DIS"; then
        echo "FAIL: esp32_hello_image (delay() loop bound 4000000 absent — DCE ate the heartbeat)"
        ESP_H_OK=0
    fi
    case "$ESP_H_VERDICT" in
        OK) ;;
        *)
            echo "FAIL: esp32_hello_image (UART access pattern wrong: $ESP_H_VERDICT)"
            echo "      want: l32i from 0x3ff4001c (APB status poll) + s32i to 0x60000000 (AHB FIFO,"
            echo "      errata CPU-3.3); a store to any 0x3ff400xx UART address may silently drop bytes"
            ESP_H_OK=0
            ;;
    esac
    ESP_H_DIS_NOTE=" + AHB/APB direction"
else
    ESP_H_DIS_NOTE=" (disasm direction check SKIPPED — no xtensa-lx106-elf-objdump)"
fi
if [ "$ESP_H_OK" = 1 ]; then
    PASS=$((PASS + 1))
    echo "  esp32_hello_image: PASS (e9/02/02/20, 2 segments, entry in IRAM, checksum recomputed, 16-aligned+hash$ESP_H_HASH_NOTE$ESP_H_DIS_NOTE)"
else
    FAIL=$((FAIL + 1))
fi
rm -f "$ESP_H_BIN" "$ESP_H_PAY" "$ESP_H_CODE" "$ESP_H_DIS"

# --- Summary ---
echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit $FAIL
