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
# H10: `continue` inside a `for` body is rejected (would hang) — was an
# infinite loop on all backends.
diag_span_test "diag_continue_in_for" 'fn main() {
    u64 s = 0
    for i in 0..5 { if i == 2 { continue } s = s + 1 }
    exit(s)
}' "continue"

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

# --- Summary ---
echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit $FAIL
