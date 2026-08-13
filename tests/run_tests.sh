#!/bin/bash
# No set -e: test binaries return non-zero exit codes intentionally

DIR="$(cd "$(dirname "$0")" && pwd)"
KRC="${KRC:-$DIR/../build/krc3}"
ARCH=$(uname -m)
KRC_FLAGS="${KRC_FLAGS:---arch=$ARCH}"
# Arch for tests that COMPILE AND THEN EXECUTE the artifact. Hardcoding
# --arch=x86_64 in those makes an arm64 runner produce a binary it cannot run:
# the shell returns 126 ("cannot execute"), which a test then misreports as a
# wrong answer -- float_literal_return_values announced "check #126 failed"
# when there is no check 126. Use --arch=x86_64 only where the artifact is
# inspected rather than run (--emit=ir/obj/lkm/android).
RUN_ARCH="x86_64"
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then RUN_ARCH="arm64"; fi
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

# Like run_test, but bounds wall-clock time. A timeout is reported distinctly
# from a wrong exit code, because "took too long" and "computed the wrong
# answer" are different failures and conflating them hides regressions.
run_test_timed() {
    local name="$1"
    local input="$2"
    local expected="$3"
    local secs="$4"
    TOTAL=$((TOTAL + 1))

    local REPO_ROOT="$DIR/.."
    printf '%s\n' "$input" > "$REPO_ROOT/test_tmp_$$.kr"
    if $KRC $KRC_FLAGS "$REPO_ROOT/test_tmp_$$.kr" -o /tmp/krc_test_$$ > /dev/null 2>&1; then
        chmod +x /tmp/krc_test_$$
        local got=0
        timeout "$secs" /tmp/krc_test_$$ > /dev/null 2>&1 && got=0 || got=$?
        if [ "$got" = "124" ]; then
            echo "FAIL: $name (exceeded ${secs}s wall clock)"
            FAIL=$((FAIL + 1))
        elif [ "$got" = "$expected" ]; then
            PASS=$((PASS + 1))
        else
            echo "FAIL: $name (expected $expected, got $got)"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL: $name (compilation failed)"
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

# --- str_to_float exponent handling ---
# Negative exponents used to multiply by 1/10 once per digit. 1/10 is inexact
# in binary, so the error compounded: one multiply survived, two did not.
# These two cases both failed before the exactly-built power-of-ten fix.
run_test "str_to_float_neg_exp" 'import "std/string.kr"
fn main() {
    if str_to_float("1.5e-2") == 0.015 { exit(0) }
    exit(1)
}' 0
run_test "str_to_float_neg_exp_alt" 'import "std/string.kr"
fn main() {
    if str_to_float("15e-3") == 0.015 { exit(0) }
    exit(1)
}' 0
# Positive controls: these passed before and must keep passing.
run_test "str_to_float_pos_exp" 'import "std/string.kr"
fn main() {
    if str_to_float("1e2") == 100.0 { exit(0) }
    exit(1)
}' 0
run_test "str_to_float_signed" 'import "std/string.kr"
fn main() {
    if str_to_float("-3.14e2") == 0.0 - 314.0 { exit(0) }
    exit(1)
}' 0
# The exponent loop is clamped at 400 because 10^309 is already +inf. This is
# TIMED, not just checked for exit code: without the clamp the loop still
# terminates, it just takes ~0.58 s per parse (measured), so a plain exit-code
# test passes against the unfixed stdlib and proves nothing. 50 parses is
# ~29 s unclamped versus instant clamped.
run_test_timed "str_to_float_exp_clamped" 'import "std/string.kr"
fn main() {
    u64 n = 0
    u64 hits = 0
    while n < 50 {
        f64 v = str_to_float("1e999999999")
        if v > 1.0 { hits = hits + 1 }
        n = n + 1
    }
    if hits == 50 { exit(0) }
    exit(1)
}' 0 5
# Exactness across the negative-exponent range. Every one of these is a
# distinct number of compounding steps in the old implementation.
run_test "str_to_float_neg_exp_range" 'import "std/string.kr"
fn main() {
    if str_to_float("1e-1") != 0.1 { exit(1) }
    if str_to_float("1e-2") != 0.01 { exit(2) }
    if str_to_float("1e-3") != 0.001 { exit(3) }
    if str_to_float("1e-4") != 0.0001 { exit(4) }
    if str_to_float("1e-5") != 0.00001 { exit(5) }
    if str_to_float("1e-6") != 0.000001 { exit(6) }
    if str_to_float("1e-7") != 0.0000001 { exit(7) }
    exit(0)
}' 0
# Mantissa/exponent combinations, and the equivalent spellings of one value.
run_test "str_to_float_equivalent_spellings" 'import "std/string.kr"
fn main() {
    f64 a = str_to_float("0.015")
    if str_to_float("1.5e-2") != a { exit(1) }
    if str_to_float("15e-3")  != a { exit(2) }
    if str_to_float("150e-4") != a { exit(3) }
    if str_to_float("1.5E-2") != a { exit(4) }
    exit(0)
}' 0
# Accepted syntax that is easy to regress: leading +, bare .5, trailing .,
# capital E, explicit +exponent, and a trailing-garbage stop.
run_test "str_to_float_syntax_forms" 'import "std/string.kr"
fn main() {
    if str_to_float("+3.5")   != 3.5   { exit(1) }
    if str_to_float(".5")     != 0.5   { exit(2) }
    if str_to_float("5.")     != 5.0   { exit(3) }
    if str_to_float("1E3")    != 1000.0 { exit(4) }
    if str_to_float("1e+3")   != 1000.0 { exit(5) }
    if str_to_float("3.5abc") != 3.5   { exit(6) }
    if str_to_float("0e0")    != 0.0   { exit(7) }
    exit(0)
}' 0
# No-digit inputs return 0.0 rather than reading past the string.
run_test "str_to_float_no_digits" 'import "std/string.kr"
fn main() {
    if str_to_float("")    != 0.0 { exit(1) }
    if str_to_float("abc") != 0.0 { exit(2) }
    if str_to_float("e5")  != 0.0 { exit(3) }
    if str_to_float("-")   != 0.0 { exit(4) }
    exit(0)
}' 0
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

# --- Three verified stdlib crashes (fmt_f64, vec_remove, sqrt_int) ---
# fmt_f64_pos computed leading_zeros = decimals - frac_len as an unsigned
# u64. With decimals=0, frac_len is always >= 1 (fmt_dec(0) == "0"), so the
# subtraction underflowed to ~2^64 and the zero-pad loop wrote far past the
# alloc(total) buffer -> SIGSEGV on every call. Now decimals==0 skips the
# fractional section entirely (matches printf "%.0f").
run_test_output "fmt_f64_zero_decimals" 'import "std/math_float.kr"
fn main() { println_str(fmt_f64(int_to_f64(7), 0)) }' "7"
run_test_output "fmt_f32_zero_decimals" 'import "std/math_float.kr"
fn main() { println_str(fmt_f32(f64_to_f32(int_to_f64(7)), 0)) }' "7"
run_test_output "fmt_f64_zero_decimals_negative" 'import "std/math_float.kr"
fn main() { println_str(fmt_f64(int_to_f64(0) - int_to_f64(9), 0)) }' "-9"
# |value| >= 2^63 saturates f64_to_int, so int_part no longer reconstructs
# aval's integer part and `frac` can land outside [0,1). frac_len then
# exceeds `decimals`, and the fractional copy loop wrote past the `total`
# allocation -> SIGSEGV. Reached via str_to_float since float literals cap
# at 1e18. Now frac is clamped to [0,1) before use, so this cannot corrupt
# the heap; the printed value is documented as wrong-but-safe for such
# out-of-range magnitudes (this does not assert an exact string — only
# that it terminates cleanly with a nonempty, sane-looking result).
run_test "fmt_f64_extreme_magnitude_no_crash" 'import "std/math_float.kr"
import "std/string.kr"
fn main() {
    f64 v = str_to_float("1e22")
    u64 s = fmt_f64(v, 12)
    u64 len = str_len(s)
    if len > 0 { exit(0) }
    exit(1)
}' 0
# vec_remove(v, idx) computed len - 1 as unsigned. On an empty vec (len==0)
# this underflows to ~2^64, turning the shift loop's bound into a runaway
# out-of-bounds read/write -> SIGSEGV. Now a no-op on an empty vec.
run_test "vec_remove_empty_no_crash" 'import "std/vec.kr"
fn main() {
    u64 v = vec_new()
    vec_remove(v, 0)
    exit(42)
}' 42
# An out-of-range idx on a non-empty vec did not crash (the shift loop
# condition `i < len - 1` is false immediately since idx >= len), but it
# silently decremented the stored length anyway, corrupting the vec even
# though nothing was actually removed. Now out-of-range idx is a no-op.
run_test "vec_remove_out_of_range_no_corrupt" 'import "std/vec.kr"
fn main() {
    u64 v = vec_new()
    vec_push(v, 10)
    vec_push(v, 20)
    vec_push(v, 30)
    vec_remove(v, 99)
    exit(vec_len(v))
}' 3
# sqrt_int(n) seeded y = (x + 1) / 2 with x = n. At n == u64::MAX, x + 1
# overflows to 0, so y becomes 0; the next iteration then divides n/x by
# zero -> SIGFPE. Now the one x for which x+1 overflows (u64::MAX) is
# special-cased with the exact value the addition would have produced,
# leaving every other n bit-for-bit unchanged. Verified against Python 3's
# math.isqrt across a range spanning small values, both sides of 2^32,
# both sides of 2^63, and both sides of 2^64 (isqrt(2^64-1) == 4294967295).
run_test "sqrt_int_max_no_crash_matches_isqrt" 'import "std/math.kr"
fn main() {
    u64 fails = 0
    if sqrt_int(0) != 0 { fails = fails + 1 }
    if sqrt_int(1) != 1 { fails = fails + 1 }
    if sqrt_int(2) != 1 { fails = fails + 1 }
    if sqrt_int(4) != 2 { fails = fails + 1 }
    if sqrt_int(99) != 9 { fails = fails + 1 }
    if sqrt_int(4294967296) != 65536 { fails = fails + 1 }
    if sqrt_int(4294967295) != 65535 { fails = fails + 1 }
    if sqrt_int(9223372036854775808) != 3037000499 { fails = fails + 1 }
    if sqrt_int(9223372036854775807) != 3037000499 { fails = fails + 1 }
    if sqrt_int(18446744073709551614) != 4294967295 { fails = fails + 1 }
    if sqrt_int(0xFFFFFFFFFFFFFFFF) != 4294967295 { fails = fails + 1 }
    exit(fails)
}' 0

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

# --- Store-statement RHS counts as a use (analysis walker) ---
# The stmt walker used to skip Index-store (arr[i] = v) and FieldAccess-store
# (obj.f = v) statements entirely, so a variable whose only consumer was such
# a store was falsely reported unused. Each case below must compile with NO
# unused-variable warning AND produce the right exit code.
run_store_use_test() {
    local name="$1"
    local src="$2"
    local expected="$3"
    TOTAL=$((TOTAL + 1))
    printf '%s\n' "$src" > "$DIR/../test_tmp_su_$$.kr"
    local su_out
    su_out=$($KRC $KRC_FLAGS "$DIR/../test_tmp_su_$$.kr" -o /tmp/krc_su_$$ 2>&1)
    if echo "$su_out" | grep -q "unused variable"; then
        echo "FAIL: $name (false unused-variable warning)"; FAIL=$((FAIL + 1))
    else
        local got=0
        /tmp/krc_su_$$ > /dev/null 2>&1 && got=0 || got=$?
        if [ "$got" = "$expected" ]; then
            PASS=$((PASS + 1))
        else
            echo "FAIL: $name (expected exit $expected, got $got)"; FAIL=$((FAIL + 1))
        fi
    fi
    rm -f "$DIR/../test_tmp_su_$$.kr" /tmp/krc_su_$$
}
run_store_use_test "idx_store_rhs_use" \
    'fn main() { u64[4] a; u64 v = 7; a[0] = v; exit(a[0]) }' 7
run_store_use_test "idx_store_index_use" \
    'fn main() { u64[4] a; u64 i = 1; a[i] = 3; exit(a[1]) }' 3
run_store_use_test "idx_store_nested_rhs_use" \
    'fn add2(u64 x, u64 y) -> u64 { return x + y } fn main() { u64[4] a; u64 s0 = 2; u64 s1 = 3; a[0] = (s0 + s1) & 255; u64 c = 12; a[1] = add2(c, 2); exit(a[0] + a[1]) }' 19
run_store_use_test "idx_store_compound_rhs_use" \
    'fn main() { u64[4] a; a[0] = 1; u64 v = 6; a[0] += v; exit(a[0]) }' 7
run_store_use_test "field_store_rhs_use" \
    'struct SuP { u64 x  u64 y } fn main() { SuP p; u64 v = 9; p.x = v; exit(p.x) }' 9
run_store_use_test "idx_field_store_rhs_use" \
    'struct SuQ { u64 x  u64 y } fn main() { SuQ[4] q; u64 v = 5; q[0].x = v; exit(q[0].x) }' 5

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

# Signedness must survive a CALL RESULT used directly as an operand.
# Regression: the signed flag lived only on a vreg, and a call's result vreg
# was never tagged from the callee's declared return type — so `neg() >> 1`
# emitted SHR (logical) instead of SAR, and `/` `%` chose DIV/MOD over
# SDIV/SMOD. Silently wrong for negatives. Worse, a pure single-expression
# callee is INLINED (even at --O0), splicing an untyped body in, which loses
# the signedness before the IR sees a call at all. Assigning to a typed local
# first always worked, which is what masked it. Each case exits 0 only if the
# direct-call form agrees with the via-local form.
run_test "signed_ret_shift_i32" 'fn neg() -> i32 { return 0 - 32 }
fn main() {
    i32 a = neg()
    i32 viaLocal = a >> 1
    i32 direct = neg() >> 1
    if viaLocal != direct { exit(1) }
    if direct != (0 - 16) { exit(2) }
    exit(0)
}' 0

run_test "signed_ret_shift_i64" 'fn neg() -> i64 { return 0 - 32 }
fn main() {
    i64 a = neg()
    if (a >> 1) != (neg() >> 1) { exit(1) }
    if (neg() >> 1) != (0 - 16) { exit(2) }
    exit(0)
}' 0

run_test "signed_ret_divmod" 'fn neg() -> i64 { return 0 - 10 }
fn main() {
    i64 a = neg()
    if (a / 3) != (neg() / 3) { exit(1) }
    if (a % 3) != (neg() % 3) { exit(2) }
    exit(0)
}' 0

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

# volatile block. NOTE: this row passes even with the data3 f64 miscompile
# present, because exit(val) never does arithmetic on the loaded value -- the
# vreg was mistyped f64 but a plain register move looks identical. The rows
# below are the ones that actually exercise it.
run_test "volatile_block" 'fn main() {
    uint64 buf = alloc(64)
    uint64 val = 0
    unsafe { *(buf as uint64) = 42 }
    volatile { *(buf as uint64) -> val }
    exit(val)
}' 42

# The miscompile: parser.kr wrote a bare 1 into data3 as a "volatile flag"
# while the unsafe path wrote the FLOAT KIND into the same slot, and IR
# lowering read it as the float kind. Every volatile load was therefore typed
# f64, so integer arithmetic on it produced 0.
run_test "volatile_load_not_mistyped_f64" 'fn main() {
    u64 p = alloc(64)
    store32(p, 4)
    volatile { *(p as u32) -> v }
    u64 w = v / 2
    exit(w)
}' 2

# The same program with `unsafe` was always correct -- it is the control that
# proves the defect was volatile-specific, not a bug in the load itself.
run_test "unsafe_load_control_still_correct" 'fn main() {
    u64 p = alloc(64)
    store32(p, 4)
    unsafe { *(p as u32) -> v }
    u64 w = v / 2
    exit(w)
}' 2

# A genuine f64 through a volatile load must still be typed f64 -- the fix
# must not simply clear the float kind.
run_test "volatile_load_f64_still_float" 'fn main() {
    u64 p = alloc(64)
    unsafe { *(p as f64) = 6.5 }
    volatile { *(p as f64) -> d }
    f64 e = d * 2.0
    if e > 12.9 { if e < 13.1 { exit(9) } }
    exit(1)
}' 9

# Volatile now lowers to IR_VLOAD/IR_VSTORE, so it inherits their width
# correctness: a u8 volatile store must not clobber its neighbours. Before
# that it went through the plain IR_STORE path.
run_test "volatile_narrow_store_no_clobber" 'fn main() {
    u64 p = alloc(64)
    store32(p + 8, 77)
    volatile { *(p + 4 as u8) = 3 }
    exit(load32(p + 8))
}' 77

# The barrier itself, asserted on emitted bytes with a control, on ALL FOUR
# backend/arch combinations.
#
# Covering only the default (x86_64 IR) is what let a real regression through
# once already: re-encoding the AST volatile marker from 1 to bit 4 silently
# stopped the LEGACY backends firing, because they tested `data3 == 1` rather
# than the bit. The IR-only assertion stayed green through it. Behaviour cannot
# catch a missing fence either -- a dropped barrier changes no exit code -- so
# this pins the instruction on every path that emits one.
#
# Expected barrier per config: x86 mfence (0f ae f0) on both backends;
# arm64 IR LDAR (size field in bits 31:30, so 08/48/88/c8 dff...) since
# volatile lowers to IR_VLOAD; arm64 legacy DSB SY (d5033f9f).
# Compile-only, so arches may be pinned.
TOTAL=$((TOTAL + 1))
VBAR_OK=1
printf 'fn main() { u64 p = alloc(64)  volatile { *(p as u32) -> v }  u64 w = v + 1  exit(0) }\n' > "$DIR/../vbar_v_$$.kr"
printf 'fn main() { u64 p = alloc(64)  unsafe { *(p as u32) -> v }  u64 w = v + 1  exit(0) }\n' > "$DIR/../vbar_u_$$.kr"
vbar_count() { # <arch> <flags> <srcfile> -> barrier count on stdout
    local _o
    _o=$($KRC --arch="$1" $2 --emit=asm "$3" 2>&1)
    local _l
    _l=$(printf '%s' "$_o" | sed -n 's/.* -> \(.*\) (asm listing)$/\1/p')
    if [ ! -f "$_l" ]; then echo "NOLISTING"; return; fi
    if [ "$1" = "x86_64" ]; then
        grep -ci '0f ae f0' "$_l"
    else
        grep -ciE 'd5033f9f|: (08|48|88|c8)dff' "$_l"
    fi
    rm -f "$_l"
}
for _cfg in "x86_64:" "x86_64:--legacy" "arm64:" "arm64:--legacy"; do
    _a="${_cfg%%:*}"; _f="${_cfg##*:}"
    _nv=$(vbar_count "$_a" "$_f" "$DIR/../vbar_v_$$.kr")
    _nu=$(vbar_count "$_a" "$_f" "$DIR/../vbar_u_$$.kr")
    if [ "$_nv" = "NOLISTING" ] || [ "$_nu" = "NOLISTING" ]; then
        VBAR_OK=0; echo "  $_a ${_f:-IR}: could not locate asm listing"
    else
        [ "$_nv" -ge 1 ] || { VBAR_OK=0; echo "  $_a ${_f:-IR}: volatile emitted NO barrier"; }
        [ "$_nu" = "0" ] || { VBAR_OK=0; echo "  $_a ${_f:-IR}: unsafe wrongly emitted $_nu barrier(s)"; }
    fi
done
if [ "$VBAR_OK" = "1" ]; then
    echo "  volatile_block_emits_barrier: PASS (all 4 configs fence; unsafe fences on none)"
    PASS=$((PASS + 1))
else
    echo "FAIL: volatile_block_emits_barrier"
    FAIL=$((FAIL + 1))
fi
rm -f "$DIR/../vbar_v_$$.kr" "$DIR/../vbar_u_$$.kr"

# The `-> dest` binding must work WITHOUT pre-declaring dest, on every backend.
# The IR backend auto-declared via ir_var_set; the legacy backends silently
# dropped the value and then failed at the first USE with "use of undeclared
# identifier" -- for `unsafe` as well as `volatile`. Compile-and-run all four.
TOTAL=$((TOTAL + 1))
VBIND_OK=1
# These rows EXECUTE, so they must follow $RUN_ARCH rather than naming an arch.
# Hardcoding x86_64 here made the native ARM64 CI job produce a binary it could
# not run (exit 126, reported as a wrong answer) -- the exact trap documented at
# the top of this file.
#
# Host arch runs natively; the other arch runs under qemu when available.
# Resolve qemu LOCALLY: $QEMU_A64 is not set until ~line 2950, far below here,
# so referencing it would be empty and skip configs in silence.
VBIND_OTHER="arm64"
if [ "$RUN_ARCH" = "arm64" ]; then VBIND_OTHER="x86_64"; fi
VBIND_QEMU=""
if [ "$VBIND_OTHER" = "arm64" ]; then
    VBIND_QEMU="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
fi
printf 'fn main() { u64 p = alloc(64)  store32(p, 4)  volatile { *(p as u32) -> v }  exit(v / 2) }\n' > "$DIR/../vbind_v_$$.kr"
printf 'fn main() { u64 p = alloc(64)  store32(p, 4)  unsafe { *(p as u32) -> v }  exit(v / 2) }\n' > "$DIR/../vbind_u_$$.kr"
VBIND_RAN=0
vbind_run() { # <arch> <flags> <src> <runner-or-empty>
    local _bin="/tmp/krc_vbind_$$"
    if ! $KRC --arch="$1" $2 "$3" -o "$_bin" >/dev/null 2>&1; then
        VBIND_OK=0; echo "  $(basename $3) $1 ${2:-IR}: COMPILE FAILED"
        return
    fi
    if [ -n "$4" ]; then $4 "$_bin" >/dev/null 2>&1; else "$_bin" >/dev/null 2>&1; fi
    local _rc=$?
    VBIND_RAN=$((VBIND_RAN + 1))
    [ "$_rc" = "2" ] || { VBIND_OK=0; echo "  $(basename $3) $1 ${2:-IR}: got $_rc, want 2"; }
    rm -f "$_bin"
}
for _src in "$DIR/../vbind_v_$$.kr" "$DIR/../vbind_u_$$.kr"; do
    vbind_run "$RUN_ARCH" ""          "$_src" ""
    vbind_run "$RUN_ARCH" "--legacy"  "$_src" ""
    if [ -n "$VBIND_QEMU" ]; then
        vbind_run "$VBIND_OTHER" ""         "$_src" "$VBIND_QEMU"
        vbind_run "$VBIND_OTHER" "--legacy" "$_src" "$VBIND_QEMU"
    fi
done
# Guard against the loop silently doing nothing. 2 sources x 2 host configs
# always; x2 more per source when the other arch is runnable.
VBIND_WANT=4
if [ -n "$VBIND_QEMU" ]; then VBIND_WANT=8; fi
[ "$VBIND_RAN" = "$VBIND_WANT" ] || { VBIND_OK=0; echo "  only $VBIND_RAN/$VBIND_WANT config-runs executed"; }
if [ "$VBIND_OK" = "1" ]; then
    echo "  ptrload_dest_binding_all_backends: PASS (volatile+unsafe bind dest, $VBIND_RAN config-runs)"
    PASS=$((PASS + 1))
else
    echo "FAIL: ptrload_dest_binding_all_backends"
    FAIL=$((FAIL + 1))
fi
rm -f "$DIR/../vbind_v_$$.kr" "$DIR/../vbind_u_$$.kr"

# Compound assignment must evaluate its index/address subexpression EXACTLY
# ONCE, on every backend.
#
# `arr[i()] += v()` used to desugar to a read-side Index node that pointed at
# the SAME index-expression node as the store side, so each backend evaluated
# it independently: the observed order was index, value, index (seq 121) on all
# four backends instead of index, value (seq 12). `*(p as T) += v` did not
# parse at all.
#
# `seq` records execution order as decimal digits, so this row FAILS on a
# double evaluation rather than merely on a wrong stored value -- a row that
# only checked the stored value, or only that the program compiles, passes
# against both of those defects and catches neither.
#
# These rows EXECUTE, so they follow $RUN_ARCH rather than naming an arch;
# the other arch runs under qemu when it is available.
TOTAL=$((TOTAL + 1))
CEVAL_OK=1
CEVAL_OTHER="arm64"
if [ "$RUN_ARCH" = "arm64" ]; then CEVAL_OTHER="x86_64"; fi
CEVAL_QEMU=""
if [ "$CEVAL_OTHER" = "arm64" ]; then
    CEVAL_QEMU="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
fi

# 1. arr[i()] OP= v() -- index once, then value => seq 12, and arr[3] == 5+7.
cat > "$DIR/../ceval_idx_$$.kr" <<'CEVAL_IDX'
static u64 seq = 0
static u8[16] arr
fn ai() -> u64 { seq = seq * 10 + 1  return 3 }
fn fv() -> u64 { seq = seq * 10 + 2  return 7 }
fn main() {
    arr[3] = 5
    arr[ai()] += fv()
    if seq != 12 { exit(1) }
    if arr[3] != 12 { exit(2) }
    exit(7)
}
CEVAL_IDX

# 2. unsafe { *(ap() as uint32) OP= fv() } -- address once, then value.
cat > "$DIR/../ceval_ptr_$$.kr" <<'CEVAL_PTR'
static u64 seq = 0
static u8[16] buf
fn ap() -> u64 { seq = seq * 10 + 1  return buf }
fn fv() -> u64 { seq = seq * 10 + 2  return 3 }
fn main() {
    store32(buf, 5)
    unsafe { *(ap() as uint32) += fv() }
    if seq != 12 { exit(1) }
    if load32(buf) != 8 { exit(2) }
    exit(7)
}
CEVAL_PTR

# 3. Plain `arr[i()] = v()` evaluates the SUBSCRIPT first (12), the same as
#    the `OP=` form above -- the destination address is evaluated before the
#    value on every backend (docs/LANGUAGE.md §4). This used to be pinned at
#    21 while the language had no stated rule; it is pinned at 12 now so the
#    plain and compound forms cannot drift apart again.
cat > "$DIR/../ceval_plain_$$.kr" <<'CEVAL_PLAIN'
static u64 seq = 0
static u8[16] arr
fn ai() -> u64 { seq = seq * 10 + 1  return 3 }
fn fv() -> u64 { seq = seq * 10 + 2  return 7 }
fn main() {
    arr[ai()] = fv()
    if seq != 12 { exit(1) }
    if arr[3] != 7 { exit(2) }
    exit(7)
}
CEVAL_PLAIN

CEVAL_RAN=0
ceval_run() { # <arch> <flags> <src> <runner-or-empty>
    local _bin="/tmp/krc_ceval_$$"
    if ! $KRC --arch="$1" $2 "$3" -o "$_bin" >/dev/null 2>&1; then
        CEVAL_OK=0; echo "  $(basename $3) $1 ${2:-IR}: COMPILE FAILED"
        return
    fi
    if [ -n "$4" ]; then $4 "$_bin" >/dev/null 2>&1; else "$_bin" >/dev/null 2>&1; fi
    local _rc=$?
    CEVAL_RAN=$((CEVAL_RAN + 1))
    # 7 = reached the end with every assertion satisfied. 1 = wrong evaluation
    # order (the double-eval defect), 2 = wrong stored value.
    [ "$_rc" = "7" ] || { CEVAL_OK=0; echo "  $(basename $3) $1 ${2:-IR}: got $_rc, want 7"; }
    rm -f "$_bin"
}
for _src in "$DIR/../ceval_idx_$$.kr" "$DIR/../ceval_ptr_$$.kr" "$DIR/../ceval_plain_$$.kr"; do
    ceval_run "$RUN_ARCH" ""          "$_src" ""
    ceval_run "$RUN_ARCH" "--legacy"  "$_src" ""
    if [ -n "$CEVAL_QEMU" ]; then
        ceval_run "$CEVAL_OTHER" ""         "$_src" "$CEVAL_QEMU"
        ceval_run "$CEVAL_OTHER" "--legacy" "$_src" "$CEVAL_QEMU"
    fi
done
# Guard against the loop silently doing nothing. 3 sources x 2 host configs
# always; x2 more per source when the other arch is runnable.
CEVAL_WANT=6
if [ -n "$CEVAL_QEMU" ]; then CEVAL_WANT=12; fi
[ "$CEVAL_RAN" = "$CEVAL_WANT" ] || { CEVAL_OK=0; echo "  only $CEVAL_RAN/$CEVAL_WANT config-runs executed"; }
if [ "$CEVAL_OK" = "1" ]; then
    echo "  compound_assign_evaluates_index_once: PASS ($CEVAL_RAN config-runs)"
    PASS=$((PASS + 1))
else
    echo "FAIL: compound_assign_evaluates_index_once"
    FAIL=$((FAIL + 1))
fi
# --- `<<=` and `>>=` --------------------------------------------------------
# TokenKind.LtLtEq (53) / GtGtEq (54) were declared in the enum, referenced by
# parser.kr's 45..54 compound-assign range and by ir.kr's operator mapping, but
# the lexer never emitted them: `<<` matched first and the trailing `=` became
# "unexpected '=' in expression". The legacy (non-IR) backends were a second,
# quieter defect -- their operator chains stopped at 52, so once the token DID
# lex, `a <<= n` fell off the end of the if/else chain and emitted nothing at
# all, leaving the destination unchanged with no diagnostic.
#
# Hence three things are asserted, not one:
#   * that it PARSES              (source 1/2/3 compile at all)
#   * that it computes the VALUE  (source 3 -- a row that only checks the
#     program compiles passes against the legacy no-op defect and catches it
#     on neither backend)
#   * that it evaluates the index/address exactly ONCE and before the value
#     (sources 1 and 2 -- `seq` records execution order as decimal digits, so
#     the new operators are pinned to the same CompoundTemp machinery the
#     other nine OP= forms use, rather than growing a second, double-evaluating
#     path of their own)
#
# These rows EXECUTE, so they follow $RUN_ARCH rather than naming an arch.
TOTAL=$((TOTAL + 1))
SHA_OK=1
SHA_OTHER="arm64"
if [ "$RUN_ARCH" = "arm64" ]; then SHA_OTHER="x86_64"; fi
SHA_QEMU=""
if [ "$SHA_OTHER" = "arm64" ]; then
    SHA_QEMU="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
fi

# 1. arr[i()] <<= v() -- index once, then value => seq 12, and arr[3] == 5<<3.
cat > "$DIR/../shassign_idx_$$.kr" <<'SHASSIGN_IDX'
static u64 seq = 0
static u8[16] arr
fn ai() -> u64 { seq = seq * 10 + 1  return 3 }
fn fv() -> u64 { seq = seq * 10 + 2  return 3 }
fn main() {
    arr[3] = 5
    arr[ai()] <<= fv()
    if seq != 12 { exit(1) }
    if arr[3] != 40 { exit(2) }
    exit(7)
}
SHASSIGN_IDX

# 2. unsafe { *(ap() as uint32) <<= fv() } -- address once, then value.
cat > "$DIR/../shassign_ptr_$$.kr" <<'SHASSIGN_PTR'
static u64 seq = 0
static u8[16] buf
fn ap() -> u64 { seq = seq * 10 + 1  return buf }
fn fv() -> u64 { seq = seq * 10 + 2  return 3 }
fn main() {
    store32(buf, 5)
    unsafe { *(ap() as uint32) <<= fv() }
    if seq != 12 { exit(1) }
    if load32(buf) != 40 { exit(2) }
    exit(7)
}
SHASSIGN_PTR

# 3. VALUES on every target form: plain variable, array element, deref, and a
#    SIGNED >>= (which must be arithmetic, not logical).
cat > "$DIR/../shassign_val_$$.kr" <<'SHASSIGN_VAL'
static u64[8] a
static u8[16] buf
fn main() {
    uint64 v = 3
    v <<= 4
    if v != 48 { exit(1) }
    v >>= 1
    if v != 24 { exit(2) }
    a[3] = 5
    a[3] <<= 3
    if a[3] != 40 { exit(3) }
    a[3] >>= 2
    if a[3] != 10 { exit(4) }
    store32(buf, 7)
    unsafe { *(buf as uint32) <<= 2 }
    if load32(buf) != 28 { exit(5) }
    unsafe { *(buf as uint32) >>= 1 }
    if load32(buf) != 14 { exit(6) }
    int64 s = 0 - 64
    s >>= 3
    if s != 0 - 8 { exit(8) }
    exit(7)
}
SHASSIGN_VAL

SHA_RAN=0
sha_run() { # <arch> <flags> <src> <runner-or-empty>
    local _bin="/tmp/krc_shassign_$$"
    if ! $KRC --arch="$1" $2 "$3" -o "$_bin" >/dev/null 2>&1; then
        SHA_OK=0; echo "  $(basename $3) $1 ${2:-IR}: COMPILE FAILED"
        return
    fi
    if [ -n "$4" ]; then $4 "$_bin" >/dev/null 2>&1; else "$_bin" >/dev/null 2>&1; fi
    local _rc=$?
    SHA_RAN=$((SHA_RAN + 1))
    # 7 = every assertion satisfied. Anything else names the assertion that
    # failed; 1 on sources 1/2 is specifically a wrong evaluation order.
    [ "$_rc" = "7" ] || { SHA_OK=0; echo "  $(basename $3) $1 ${2:-IR}: got $_rc, want 7"; }
    rm -f "$_bin"
}
for _src in "$DIR/../shassign_idx_$$.kr" "$DIR/../shassign_ptr_$$.kr" "$DIR/../shassign_val_$$.kr"; do
    sha_run "$RUN_ARCH" ""          "$_src" ""
    sha_run "$RUN_ARCH" "--legacy"  "$_src" ""
    if [ -n "$SHA_QEMU" ]; then
        sha_run "$SHA_OTHER" ""         "$_src" "$SHA_QEMU"
        sha_run "$SHA_OTHER" "--legacy" "$_src" "$SHA_QEMU"
    fi
done
# Guard against the loop silently doing nothing.
SHA_WANT=6
if [ -n "$SHA_QEMU" ]; then SHA_WANT=12; fi
[ "$SHA_RAN" = "$SHA_WANT" ] || { SHA_OK=0; echo "  only $SHA_RAN/$SHA_WANT config-runs executed"; }
if [ "$SHA_OK" = "1" ]; then
    echo "  shift_assign_ops: PASS ($SHA_RAN config-runs)"
    PASS=$((PASS + 1))
else
    echo "FAIL: shift_assign_ops"
    FAIL=$((FAIL + 1))
fi
rm -f "$DIR/../shassign_idx_$$.kr" "$DIR/../shassign_ptr_$$.kr" "$DIR/../shassign_val_$$.kr"
# `for i in START..END` must evaluate BOTH bounds exactly once, before the
# first iteration, on every backend.
#
# The desugar builds `{ i = START; while i < END { body; i++ } }`, and a While
# re-tests its condition every trip, so END used to run once per CONDITION
# TEST: `for i in a()..b()` called b() three times for two iterations (seq 122
# instead of 12), and `for i in 0..len(x)` re-called len() on every iteration.
#
# `seq` records execution order as decimal digits and the counters count calls,
# so these rows FAIL on a repeated evaluation. A row asserting only that the
# loop runs the right number of TIMES passes against the defect unchanged --
# the trip count was always correct, only the side effects were wrong -- so the
# order assertions and the count assertions are made separately below.
#
# These rows EXECUTE, so they follow $RUN_ARCH rather than naming an arch;
# the other arch runs under qemu when it is available.
TOTAL=$((TOTAL + 1))
FEVAL_OK=1
FEVAL_OTHER="arm64"
if [ "$RUN_ARCH" = "arm64" ]; then FEVAL_OTHER="x86_64"; fi
FEVAL_QEMU=""
if [ "$FEVAL_OTHER" = "arm64" ]; then
    FEVAL_QEMU="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
fi

# 1. Both bounds evaluated once, in source order, and the loop still runs the
#    right number of times. a() -> 1, b() -> 2, so exactly one trip.
cat > "$DIR/../feval_order_$$.kr" <<'FEVAL_ORDER'
static u64 seq = 0
static u64 trips = 0
fn a() -> u64 { seq = seq * 10 + 1  return 1 }
fn b() -> u64 { seq = seq * 10 + 2  return 2 }
fn main() {
    for i in a()..b() { trips = trips + 1 }
    if seq != 12 { exit(1) }
    if trips != 1 { exit(2) }
    exit(7)
}
FEVAL_ORDER

# 2. Iteration counts, asserted on their own: empty, single, many, inclusive.
#    This is the check that CANNOT see the double-evaluation defect, which is
#    exactly why it is separate from the order rows rather than standing in
#    for them.
cat > "$DIR/../feval_count_$$.kr" <<'FEVAL_COUNT'
fn main() {
    uint64 n = 0
    for i in 5..5 { n = n + 1 }
    if n != 0 { exit(1) }
    uint64 m = 0
    for j in 0..1 { m = m + 1 }
    if m != 1 { exit(2) }
    uint64 k = 0
    uint64 sum = 0
    for p in 3..10 { k = k + 1  sum = sum + p }
    if k != 7 { exit(3) }
    if sum != 42 { exit(4) }
    uint64 q = 0
    for r in 0..=3 { q = q + 1 }
    if q != 4 { exit(5) }
    exit(7)
}
FEVAL_COUNT

# 3. Nested loops: each level's bound runs once per ENTRY of that level, not
#    once per condition test. A single shared park slot would also redden here.
cat > "$DIR/../feval_nest_$$.kr" <<'FEVAL_NEST'
static u64 no = 0
static u64 ni = 0
static u64 body = 0
fn oe() -> u64 { no = no + 1  return 2 }
fn ie() -> u64 { ni = ni + 1  return 3 }
fn main() {
    for i in 0..oe() {
        for j in 0..ie() { body = body + 1 }
    }
    if no != 1 { exit(1) }
    if ni != 2 { exit(2) }
    if body != 6 { exit(3) }
    exit(7)
}
FEVAL_NEST

# 4. break and continue change neither the bound evaluation count nor the
#    trip count.
cat > "$DIR/../feval_flow_$$.kr" <<'FEVAL_FLOW'
static u64 nb = 0
static u64 nc = 0
static u64 hit_b = 0
static u64 hit_c = 0
fn eb() -> u64 { nb = nb + 1  return 10 }
fn ec() -> u64 { nc = nc + 1  return 10 }
fn main() {
    for i in 0..eb() {
        hit_b = hit_b + 1
        if i == 3 { break }
    }
    for j in 0..ec() {
        if j == 5 { continue }
        hit_c = hit_c + 1
    }
    if nb != 1 { exit(1) }
    if nc != 1 { exit(2) }
    if hit_b != 4 { exit(3) }
    if hit_c != 9 { exit(4) }
    exit(7)
}
FEVAL_FLOW

# 5. A user-written `while` MUST still re-evaluate its condition every trip.
#    Deliberately written in the SAME shape as the for-range condition -- the
#    side-effecting call on the right of a `<` -- so an over-broad hoist that
#    parked every While's compare rhs reddens here instead of passing quietly.
cat > "$DIR/../feval_while_$$.kr" <<'FEVAL_WHILE'
static u64 calls = 0
static u64 i = 0
fn lim() -> u64 { calls = calls + 1  return 4 }
fn main() {
    uint64 trips = 0
    while i < lim() { i = i + 1  trips = trips + 1 }
    if calls != 5 { exit(1) }
    if trips != 4 { exit(2) }
    exit(7)
}
FEVAL_WHILE

# 6. The bound is a VALUE, not an alias: assigning to the variable the end
#    bound was computed from must not lengthen the loop. This is the row that
#    caught the IR backend parking the variable's own vreg -- lowering a bare
#    `n` hands back the vreg the VARIABLE lives in, and the loop's back-edge
#    parallel-move then wrote the body's new value straight into the "parked"
#    bound, so IR ran 100 trips where both legacy backends ran 3.
cat > "$DIR/../feval_snap_$$.kr" <<'FEVAL_SNAP'
fn main() {
    uint64 n = 3
    uint64 c = 0
    for i in 0..n { n = 100  c = c + 1 }
    if c != 3 { exit(1) }
    if n != 100 { exit(2) }
    exit(7)
}
FEVAL_SNAP

FEVAL_RAN=0
feval_run() { # <arch> <flags> <src> <runner-or-empty>
    local _bin="/tmp/krc_feval_$$"
    if ! $KRC --arch="$1" $2 "$3" -o "$_bin" >/dev/null 2>&1; then
        FEVAL_OK=0; echo "  $(basename $3) $1 ${2:-IR}: COMPILE FAILED"
        return
    fi
    if [ -n "$4" ]; then $4 "$_bin" >/dev/null 2>&1; else "$_bin" >/dev/null 2>&1; fi
    local _rc=$?
    FEVAL_RAN=$((FEVAL_RAN + 1))
    # 7 = reached the end with every assertion satisfied. Anything else names
    # the assertion that failed (see the exit codes in each source above).
    [ "$_rc" = "7" ] || { FEVAL_OK=0; echo "  $(basename $3) $1 ${2:-IR}: got $_rc, want 7"; }
    rm -f "$_bin"
}
for _src in "$DIR/../feval_order_$$.kr" "$DIR/../feval_count_$$.kr" \
            "$DIR/../feval_nest_$$.kr" "$DIR/../feval_flow_$$.kr" \
            "$DIR/../feval_while_$$.kr" "$DIR/../feval_snap_$$.kr"; do
    feval_run "$RUN_ARCH" ""          "$_src" ""
    feval_run "$RUN_ARCH" "--legacy"  "$_src" ""
    if [ -n "$FEVAL_QEMU" ]; then
        feval_run "$FEVAL_OTHER" ""         "$_src" "$FEVAL_QEMU"
        feval_run "$FEVAL_OTHER" "--legacy" "$_src" "$FEVAL_QEMU"
    fi
done
# Guard against the loop silently doing nothing. 6 sources x 2 host configs
# always; x2 more per source when the other arch is runnable.
FEVAL_WANT=12
if [ -n "$FEVAL_QEMU" ]; then FEVAL_WANT=24; fi
[ "$FEVAL_RAN" = "$FEVAL_WANT" ] || { FEVAL_OK=0; echo "  only $FEVAL_RAN/$FEVAL_WANT config-runs executed"; }
if [ "$FEVAL_OK" = "1" ]; then
    echo "  for_range_evaluates_bounds_once: PASS ($FEVAL_RAN config-runs)"
    PASS=$((PASS + 1))
else
    echo "FAIL: for_range_evaluates_bounds_once"
    FAIL=$((FAIL + 1))
fi
rm -f "$DIR/../feval_order_$$.kr" "$DIR/../feval_count_$$.kr" \
      "$DIR/../feval_nest_$$.kr" "$DIR/../feval_flow_$$.kr" \
      "$DIR/../feval_while_$$.kr" "$DIR/../feval_snap_$$.kr"
# --- store sites get a PRIVATE scratch slot --------------------------------
# The legacy backends have exactly one pair of scratch slots per function,
# temp_slot_0 / temp_slot_1. Every store used to park one operand there while
# it evaluated the other -- and the other operand is an arbitrary expression
# that is free to park something in the SAME slot. `write` does exactly that
# with its fd, so
#
#     arr64[ write(1, msg, 0) + 3 ] = 77
#
# stored the fd (1) instead of 77 on both legacy backends while both IR
# backends stored 77. Store sites now call alloc_scratch_slot() for a nameless
# frame slot of their own.
#
# Every row ASSERTS THE STORED VALUE, not that it compiles: the defect
# compiled perfectly and produced the wrong number, so a compile-only row
# passes against it on all four configs. The exit code IS the loaded-back
# value, so a row cannot go green by not storing at all.
#
# These rows EXECUTE, so they follow $RUN_ARCH rather than naming an arch.
TOTAL=$((TOTAL + 1))
TSLOT_OK=1
TSLOT_OTHER="arm64"
if [ "$RUN_ARCH" = "arm64" ]; then TSLOT_OTHER="x86_64"; fi
TSLOT_QEMU=""
if [ "$TSLOT_OTHER" = "arm64" ]; then
    TSLOT_QEMU="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
fi

# 1. Indexed store into a static array; the SUBSCRIPT clobbers the slot.
cat > "$DIR/../tslot_idx_$$.kr" <<'TSLOT_IDX'
static u64[16] arr64
fn main() {
    u64 msg = 0
    arr64[ write(1, msg, 0) + 3 ] = 77
    exit(arr64[3])
}
TSLOT_IDX

# 2. PtrStore; the ADDRESS expression clobbers the slot.
cat > "$DIR/../tslot_ptr_$$.kr" <<'TSLOT_PTR'
fn main() {
    u64 m = 0
    u64[16] pa
    u64 base = pa
    unsafe { *((base + 8 * (write(1, m, 0) + 3)) as uint64) = 77 }
    exit(pa[3])
}
TSLOT_PTR

# 3. Struct-array element field write; the SUBSCRIPT clobbers the slot.
cat > "$DIR/../tslot_sfield_$$.kr" <<'TSLOT_SFIELD'
struct TsPt { u64 x  u64 y }
fn main() {
    u64 m = 0
    TsPt[4] pts
    pts[ write(1, m, 0) + 2 ].x = 77
    exit(pts[2].x)
}
TSLOT_SFIELD

# 4. Two clobbering stores in one function must not collide with each other
#    either -- a per-site slot has to be per SITE, not one extra shared slot.
cat > "$DIR/../tslot_two_$$.kr" <<'TSLOT_TWO'
static u64[16] a2
fn main() {
    u64 m = 0
    a2[ write(1, m, 0) + 3 ] = 40
    a2[ write(1, m, 0) + 4 ] = 37
    exit(a2[3] + a2[4])
}
TSLOT_TWO

# 5. The mirror image, and the reason the private slots had to land BEFORE
#    the left-to-right ordering change: now that the destination address is
#    evaluated first, the parked operand is the INDEX and the clobbering
#    builtin sits in the VALUE. Measured: this shape returns 77 with both
#    changes, 77 with neither -- and 0 on both legacy backends with the
#    ordering change alone. It is the one row that only the pair makes green.
cat > "$DIR/../tslot_val_$$.kr" <<'TSLOT_VAL'
static u64[16] vc
fn ai() -> u64 { return 3 }
fn main() {
    u64 m = 0
    vc[ ai() ] = write(1, m, 0) + 77
    exit(vc[3])
}
TSLOT_VAL

TSLOT_RAN=0
tslot_run() { # <arch> <flags> <src> <runner-or-empty>
    local _bin="/tmp/krc_tslot_$$"
    if ! $KRC --arch="$1" $2 "$3" -o "$_bin" >/dev/null 2>&1; then
        TSLOT_OK=0; echo "  $(basename $3) $1 ${2:-IR}: COMPILE FAILED"
        return
    fi
    if [ -n "$4" ]; then $4 "$_bin" >/dev/null 2>&1; else "$_bin" >/dev/null 2>&1; fi
    local _rc=$?
    TSLOT_RAN=$((TSLOT_RAN + 1))
    # 77 = the value actually reached memory. 1 = the parked value was replaced
    # by write's fd (the defect). Anything else = it never got stored.
    [ "$_rc" = "77" ] || { TSLOT_OK=0; echo "  $(basename $3) $1 ${2:-IR}: got $_rc, want 77"; }
    rm -f "$_bin"
}
for _src in "$DIR/../tslot_idx_$$.kr" "$DIR/../tslot_ptr_$$.kr" \
            "$DIR/../tslot_sfield_$$.kr" "$DIR/../tslot_two_$$.kr" \
            "$DIR/../tslot_val_$$.kr"; do
    tslot_run "$RUN_ARCH" ""          "$_src" ""
    tslot_run "$RUN_ARCH" "--legacy"  "$_src" ""
    if [ -n "$TSLOT_QEMU" ]; then
        tslot_run "$TSLOT_OTHER" ""         "$_src" "$TSLOT_QEMU"
        tslot_run "$TSLOT_OTHER" "--legacy" "$_src" "$TSLOT_QEMU"
    fi
done
# Guard against the loop silently doing nothing. 5 sources x 2 host configs
# always; x2 more per source when the other arch is runnable.
TSLOT_WANT=10
if [ -n "$TSLOT_QEMU" ]; then TSLOT_WANT=20; fi
[ "$TSLOT_RAN" = "$TSLOT_WANT" ] || { TSLOT_OK=0; echo "  only $TSLOT_RAN/$TSLOT_WANT config-runs executed"; }
if [ "$TSLOT_OK" = "1" ]; then
    echo "  store_sites_get_a_private_scratch_slot: PASS ($TSLOT_RAN config-runs)"
    PASS=$((PASS + 1))
else
    echo "FAIL: store_sites_get_a_private_scratch_slot"
    FAIL=$((FAIL + 1))
fi
rm -f "$DIR/../tslot_idx_$$.kr" "$DIR/../tslot_ptr_$$.kr" \
      "$DIR/../tslot_sfield_$$.kr" "$DIR/../tslot_two_$$.kr" \
      "$DIR/../tslot_val_$$.kr"

# --- evaluation order is LEFT TO RIGHT, ADDRESS BEFORE VALUE ---------------
# docs/LANGUAGE.md §4 / docs/UNDEFINED_BEHAVIOR.md. Nothing specified an
# order before this; the four constructs below were measured and DISAGREED:
#
#   construct                              IRx86 LGx86 IRa64 LGa64   now
#   unsafe{*(fa() as uint32)=fv()}           12    21    12    21  ->  12
#   pts[ai()].x=fv()  (local struct array)   12    21    12    21  ->  12
#   arr[ai()]=fv()                           21    21    21    21  ->  12
#   arr64[a()]=fv()+b()                     221   221   221   221  -> 122
#
# The third row is why this is not "make legacy match IR": both backends
# moved. The fourth is not a two-way swap -- the ENTIRE value expression
# used to run before the subscript.
#
# Each row asserts the ORDER (seq is a decimal digit per call, in execution
# order) AND the stored VALUE. Order alone would pass if the store were
# dropped; value alone would pass on any order.
#
# These rows EXECUTE, so they follow $RUN_ARCH rather than naming an arch.
TOTAL=$((TOTAL + 1))
EORD_OK=1
EORD_OTHER="arm64"
if [ "$RUN_ARCH" = "arm64" ]; then EORD_OTHER="x86_64"; fi
EORD_QEMU=""
if [ "$EORD_OTHER" = "arm64" ]; then
    EORD_QEMU="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
fi

# 1. Deref store: address expression, then value.
cat > "$DIR/../eord_deref_$$.kr" <<'EORD_DEREF'
static u64 seq = 0
static u8[16] ebuf
fn fa() -> u64 { seq = seq * 10 + 1  return ebuf }
fn fv() -> u64 { seq = seq * 10 + 2  return 9 }
fn main() {
    unsafe { *(fa() as uint32) = fv() }
    if seq != 12 { exit(1) }
    if load32(ebuf) != 9 { exit(2) }
    exit(7)
}
EORD_DEREF

# 2. Struct-array element field write: subscript, then value.
cat > "$DIR/../eord_sfield_$$.kr" <<'EORD_SFIELD'
struct EPt { u64 x  u64 y }
static u64 seq = 0
fn ai() -> u64 { seq = seq * 10 + 1  return 1 }
fn fv() -> u64 { seq = seq * 10 + 2  return 9 }
fn main() {
    EPt[4] pts
    pts[ai()].x = fv()
    if seq != 12 { exit(1) }
    if pts[1].x != 9 { exit(2) }
    exit(7)
}
EORD_SFIELD

# 3. Plain indexed store: subscript, then value. BOTH backends changed here.
cat > "$DIR/../eord_idx_$$.kr" <<'EORD_IDX'
static u64 seq = 0
static u8[16] earr
fn ai() -> u64 { seq = seq * 10 + 1  return 3 }
fn fv() -> u64 { seq = seq * 10 + 2  return 9 }
fn main() {
    earr[ai()] = fv()
    if seq != 12 { exit(1) }
    if earr[3] != 9 { exit(2) }
    exit(7)
}
EORD_IDX

# 4. Subscript before the WHOLE value expression, and the value itself
#    left-to-right: 122, not 221 and not 212.
cat > "$DIR/../eord_whole_$$.kr" <<'EORD_WHOLE'
static u64 seq = 0
static u64[16] earr64
fn a()  -> u64 { seq = seq * 10 + 1  return 3 }
fn fv() -> u64 { seq = seq * 10 + 2  return 5 }
fn b()  -> u64 { seq = seq * 10 + 3  return 4 }
fn main() {
    earr64[a()] = fv() + b()
    if seq != 123 { exit(1) }
    if earr64[3] != 9 { exit(2) }
    exit(7)
}
EORD_WHOLE

EORD_RAN=0
eord_run() { # <arch> <flags> <src> <runner-or-empty>
    local _bin="/tmp/krc_eord_$$"
    if ! $KRC --arch="$1" $2 "$3" -o "$_bin" >/dev/null 2>&1; then
        EORD_OK=0; echo "  $(basename $3) $1 ${2:-IR}: COMPILE FAILED"
        return
    fi
    if [ -n "$4" ]; then $4 "$_bin" >/dev/null 2>&1; else "$_bin" >/dev/null 2>&1; fi
    local _rc=$?
    EORD_RAN=$((EORD_RAN + 1))
    # 7 = order and value both correct. 1 = wrong order, 2 = wrong value.
    [ "$_rc" = "7" ] || { EORD_OK=0; echo "  $(basename $3) $1 ${2:-IR}: got $_rc, want 7"; }
    rm -f "$_bin"
}
for _src in "$DIR/../eord_deref_$$.kr" "$DIR/../eord_sfield_$$.kr" \
            "$DIR/../eord_idx_$$.kr" "$DIR/../eord_whole_$$.kr"; do
    eord_run "$RUN_ARCH" ""          "$_src" ""
    eord_run "$RUN_ARCH" "--legacy"  "$_src" ""
    if [ -n "$EORD_QEMU" ]; then
        eord_run "$EORD_OTHER" ""         "$_src" "$EORD_QEMU"
        eord_run "$EORD_OTHER" "--legacy" "$_src" "$EORD_QEMU"
    fi
done
# Guard against the loop silently doing nothing. 4 sources x 2 host configs
# always; x2 more per source when the other arch is runnable.
EORD_WANT=8
if [ -n "$EORD_QEMU" ]; then EORD_WANT=16; fi
[ "$EORD_RAN" = "$EORD_WANT" ] || { EORD_OK=0; echo "  only $EORD_RAN/$EORD_WANT config-runs executed"; }
if [ "$EORD_OK" = "1" ]; then
    echo "  store_evaluates_address_before_value: PASS ($EORD_RAN config-runs)"
    PASS=$((PASS + 1))
else
    echo "FAIL: store_evaluates_address_before_value"
    FAIL=$((FAIL + 1))
fi
rm -f "$DIR/../eord_deref_$$.kr" "$DIR/../eord_sfield_$$.kr" \
      "$DIR/../eord_idx_$$.kr" "$DIR/../eord_whole_$$.kr"
# --- @naked bodies must not write callee-saved registers (IR backend) -------
#
# @naked means "no prologue": the body saves nothing, so every register it
# writes is destroyed for whatever it interrupted. The IR backend used to
# hand naked bodies the default six-colour file, which is callee-saved ONLY
# (rbx, r12-r15, rbp) -- reported from a real OS project as an interrupt stub
# clobbering rbx while the interrupted fs_lookup held a name pointer there.
#
# The check has to read the EMITTED CODE. A row that merely RUNS the stub
# passes against this bug, because the corruption only shows up in the caller
# after the interrupt returns. So: --emit=asm (the IR path, and it emits every
# function regardless of reachability), carve the naked function's byte column
# out of the listing, disassemble it, and fail on any instruction whose
# DESTINATION is callee-saved. --emit=obj is the LEGACY backend, which has
# always been clean here; measuring with it would hide the defect completely.
echo ""
echo "--- @naked callee-saved register discipline (IR backend) ---"

# Byte column of one function in an --emit=asm listing, as a hex string.
# Listing shape: "  <hex offset>: <hex bytes>  <mnemonic text>", with the
# mnemonic separated by two spaces and often absent entirely, so the bytes
# are the only column that is always there.
nk_bytes() { # <listing> <label>
    awk -v fn="$2:" '
      $0 == fn { inf = 1; next }
      inf && /^[A-Za-z_.]/ { inf = 0 }
      inf {
        line = $0 " "
        sub(/^[ ]*[0-9a-f]+: /, "", line)
        while (match(line, /^[0-9a-f][0-9a-f] /)) {
          printf "%s", substr(line, 1, 2)
          line = substr(line, 4)
        }
      }
    ' "$1"
}

# Disassemble a hex byte string as x86-64 and print every instruction that
# WRITES a callee-saved register: destination-last operand in AT&T syntax,
# plus the pop forms.
nk_x86_bad() { # <hex>
    local _b="/tmp/krc_naked_$$.bin"
    printf '%s' "$1" | xxd -r -p > "$_b"
    objdump -D -b binary -m i386:x86-64 "$_b" 2>/dev/null \
        | grep -E ',%(rbx|ebx|bx|bl|bh|rbp|ebp|bp|bpl|r1[2-5][dwb]?)$|pop +%(rbx|rbp|r1[2-5])$'
    rm -f "$_b"
}

# 32-bit words of one function in an arm64 --emit=asm listing.
nk_a64_words() { # <listing> <label>
    awk -v fn="$2:" '
      $0 == fn { inf = 1; next }
      inf && /^[A-Za-z_.]/ { inf = 0 }
      inf {
        line = $0
        sub(/^[ ]*[0-9a-f]+: /, "", line)
        if (line ~ /^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]/) {
          print substr(line, 1, 8)
        }
      }
    ' "$1"
}

# 1. The reported repro: a naked ISR stub that calls a normal function.
#    Before the fix the IR backend put the (unread) call result in rbx and
#    then emitted a dead `xor rax,rax; jmp` AFTER the user's iretq.
cat > "$DIR/../naked_repro_$$.kr" <<'NAKED_REPRO'
static u64 counter = 0
fn handler() { counter = counter + 1 }
@naked
fn stub_a() {
    asm { "push rax" }
    handler()
    asm { "pop rax" }
    asm { "iretq" }
}
fn main() -> uint32 { u64 keep = fn_addr("stub_a")  counter = counter + keep  loop { } }
NAKED_REPRO

# 2. std/idt.kr's own isr_common. Before the fix it wrote rbx, r12, r13 AND
#    r14 -- it survived only because its reporter halts, so the post-call
#    capture never executed. A returning handler was corrupted for real.
cat > "$DIR/../naked_idt_$$.kr" <<'NAKED_IDT'
import "std/idt.kr"
fn main() -> uint32 { idt_init()  return 0 }
NAKED_IDT

# 3. A naked body that keeps a value live ACROSS the call. No register file
#    can make that correct (every register a naked body may safely use is
#    caller-saved, and there is no frame to spill into), so the compiler has
#    to SAY so. Warning, not error: std/idt.kr and every stub that calls a
#    handler must still build.
cat > "$DIR/../naked_warn_$$.kr" <<'NAKED_WARN'
static u64 counter = 0
fn handler() -> u64 { counter = counter + 1  return counter }
@naked
fn stub_w() {
    u64 keep = counter + 7
    u64 got = handler()
    counter = keep + got
}
fn main() -> uint32 { u64 k = fn_addr("stub_w")  counter = counter + k  return 0 }
NAKED_WARN

# 4. Same shape as (1) but portable, for the arm64 IR backend, which shared
#    the defect (temporaries landed in x19-x22, all AAPCS callee-saved).
cat > "$DIR/../naked_a64_$$.kr" <<'NAKED_A64'
static u64 counter = 0
fn handler(u64 a, u64 b, u64 c) { counter = counter + a + b + c }
@naked
fn stub_a() {
    u64 x = counter
    u64 y = counter + 1
    u64 z = counter + 2
    handler(x, y, z)
}
fn main() -> uint32 { u64 keep = fn_addr("stub_a")  counter = counter + keep  return 0 }
NAKED_A64

NK_ASM1="/tmp/krc_naked_a1_$$.s"
NK_ASM2="/tmp/krc_naked_a2_$$.s"
NK_ASM3="/tmp/krc_naked_a3_$$.s"

# Both x86_64 rows COMPILE only (they disassemble the listing, they never
# execute it), so pinning --arch=x86_64 is correct here.
if ! command -v objdump >/dev/null 2>&1 || ! command -v xxd >/dev/null 2>&1; then
    echo "  naked_stub_no_callee_saved_x86: SKIP (objdump/xxd not installed)"
    echo "  naked_isr_common_no_callee_saved: SKIP (objdump/xxd not installed)"
else
    TOTAL=$((TOTAL + 1))
    NK1_OK=1
    NK1_NOTES=""
    if ! $KRC --arch=x86_64 --target=none --emit=asm "$DIR/../naked_repro_$$.kr" -o "$NK_ASM1" >/dev/null 2>&1; then
        NK1_OK=0; NK1_NOTES=" (--emit=asm failed)"
    else
        NK1_HEX=$(nk_bytes "$NK_ASM1" stub_a)
        # Guard against a silently-empty extraction: a check that cannot
        # fail is not a check. The stub is push/call/pop/iretq = 10 bytes.
        if [ ${#NK1_HEX} -lt 16 ]; then
            NK1_OK=0; NK1_NOTES="$NK1_NOTES (extracted only ${#NK1_HEX} hex chars for stub_a)"
        else
            NK1_BAD=$(nk_x86_bad "$NK1_HEX")
            if [ -n "$NK1_BAD" ]; then
                NK1_OK=0
                NK1_NOTES="$NK1_NOTES (writes callee-saved: $(echo "$NK1_BAD" | tr '\n' ';'))"
            fi
            # Dead tail: a naked body gets no synthesised return sequence, so
            # the last thing emitted must be the user's own iretq (48 cf).
            case "$NK1_HEX" in
                *48cf) : ;;
                *) NK1_OK=0; NK1_NOTES="$NK1_NOTES (code emitted after the user's iretq: ...${NK1_HEX#${NK1_HEX%????????}})" ;;
            esac
        fi
    fi
    if [ "$NK1_OK" = 1 ]; then
        PASS=$((PASS + 1)); echo "  naked_stub_no_callee_saved_x86: PASS (no rbx/rbp/r12-r15 write, no tail past iretq)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: naked_stub_no_callee_saved_x86:$NK1_NOTES"
    fi

    TOTAL=$((TOTAL + 1))
    NK2_OK=1
    NK2_NOTES=""
    if ! $KRC --arch=x86_64 --target=none --emit=asm "$DIR/../naked_idt_$$.kr" -o "$NK_ASM2" >/dev/null 2>&1; then
        NK2_OK=0; NK2_NOTES=" (--emit=asm failed)"
    else
        NK2_HEX=$(nk_bytes "$NK_ASM2" isr_common)
        if [ ${#NK2_HEX} -lt 40 ]; then
            NK2_OK=0; NK2_NOTES="$NK2_NOTES (extracted only ${#NK2_HEX} hex chars for isr_common)"
        else
            NK2_BAD=$(nk_x86_bad "$NK2_HEX")
            if [ -n "$NK2_BAD" ]; then
                NK2_OK=0
                NK2_NOTES="$NK2_NOTES (writes callee-saved: $(echo "$NK2_BAD" | tr '\n' ';'))"
            fi
        fi
    fi
    if [ "$NK2_OK" = 1 ]; then
        PASS=$((PASS + 1)); echo "  naked_isr_common_no_callee_saved: PASS (std/idt.kr isr_common, no rbx/rbp/r12-r15 write)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: naked_isr_common_no_callee_saved:$NK2_NOTES"
    fi
fi

# The unsafe-scratch diagnostic. Must be a WARNING (build still succeeds) and
# must name the register, which is what turns a multi-hour "filesystem bug"
# hunt into a one-line read.
TOTAL=$((TOTAL + 1))
NK3_OUT=$($KRC --arch=x86_64 --emit=asm "$DIR/../naked_warn_$$.kr" -o "$NK_ASM3" 2>&1)
NK3_RC=$?
NK3_OK=1
NK3_NOTES=""
[ "$NK3_RC" = 0 ] || { NK3_OK=0; NK3_NOTES=" (exit $NK3_RC -- must be a warning, not an error)"; }
case "$NK3_OUT" in
    *"warning: @naked function 'stub_w'"*) : ;;
    *) NK3_OK=0; NK3_NOTES="$NK3_NOTES (no @naked warning naming stub_w)" ;;
esac
case "$NK3_OUT" in
    *r10*|*r11*|*rsi*|*rdi*|*r8*|*r9*) : ;;
    *) NK3_OK=0; NK3_NOTES="$NK3_NOTES (warning does not name the register at risk)" ;;
esac
if [ "$NK3_OK" = 1 ]; then
    PASS=$((PASS + 1)); echo "  naked_live_across_call_warns: PASS (warns and names the register, build still succeeds)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: naked_live_across_call_warns:$NK3_NOTES"
fi

# arm64 IR shared the defect. No aarch64 disassembler is assumed here, so the
# check reads the destination-register field (bits 4:0) of each emitted word
# and fails on x19-x28. B/BL words are skipped -- their low bits are part of
# the branch offset, not a register number. The probe's naked body contains
# no other branch form, which is what makes that exclusion sufficient.
TOTAL=$((TOTAL + 1))
NK4_ASM="/tmp/krc_naked_a4_$$.s"
NK4_OK=1
NK4_NOTES=""
if ! $KRC --arch=arm64 --emit=asm "$DIR/../naked_a64_$$.kr" -o "$NK4_ASM" >/dev/null 2>&1; then
    NK4_OK=0; NK4_NOTES=" (--emit=asm failed)"
else
    NK4_N=0
    for _w in $(nk_a64_words "$NK4_ASM" stub_a); do
        NK4_N=$((NK4_N + 1))
        _wv=$((0x$_w))
        _top=$((_wv & 0xFC000000))
        if [ "$_top" = "$((0x14000000))" ] || [ "$_top" = "$((0x94000000))" ]; then continue; fi
        _rd=$((_wv & 31))
        if [ "$_rd" -ge 19 ] && [ "$_rd" -le 28 ]; then
            NK4_OK=0; NK4_NOTES="$NK4_NOTES (word $_w writes x$_rd)"
        fi
    done
    if [ "$NK4_N" -lt 5 ]; then
        NK4_OK=0; NK4_NOTES="$NK4_NOTES (extracted only $NK4_N words for stub_a)"
    fi
fi
if [ "$NK4_OK" = 1 ]; then
    PASS=$((PASS + 1)); echo "  naked_stub_no_callee_saved_arm64: PASS (no x19-x28 destination)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: naked_stub_no_callee_saved_arm64:$NK4_NOTES"
fi

rm -f "$DIR/../naked_repro_$$.kr" "$DIR/../naked_idt_$$.kr" \
      "$DIR/../naked_warn_$$.kr" "$DIR/../naked_a64_$$.kr"
rm -f "$NK_ASM1" "$NK_ASM2" "$NK_ASM3" "$NK4_ASM"

# --- builtin ARGUMENT parking gets a private scratch slot ------------------
# The argument half of the temp_slot_0/temp_slot_1 family whose STORE half is
# covered by store_sites_get_a_private_scratch_slot above.
#
# A builtin with more than one argument parked the arguments it had already
# evaluated in temp_slot_0 / temp_slot_1 while it evaluated the rest -- and the
# rest is an arbitrary expression which is free to write those same two slots.
# Three node kinds do: a Call (every multi-arg builtin), a fractional float
# LITERAL (it lowers as int + frac/divisor using both slots as scratch), and an
# f-string (it keeps its running output offset in temp_slot_1). So
#
#     write(1, outer, write(2, inner, 3) + 1)
#
# ran the OUTER write with the INNER write's fd and buffer: nothing on stdout
# and "IN" twice on stderr, on both legacy backends, while both IR backends
# printed OUT/IN correctly.
#
# THESE ROWS ASSERT BOTH STREAMS SEPARATELY. The corruption is in *which fd*
# and *which buffer* the builtin receives, so a row that only checks the exit
# code -- or only checks that the program compiles -- passes against the defect
# on all four configs. Each row also refuses an empty capture, so an empty
# stdout compared against an empty expectation cannot report green.
#
# These rows EXECUTE, so they follow $RUN_ARCH rather than naming an arch.
TOTAL=$((TOTAL + 1))
ASLOT_OK=1
ASLOT_OTHER="arm64"
if [ "$RUN_ARCH" = "arm64" ]; then ASLOT_OTHER="x86_64"; fi
ASLOT_QEMU=""
if [ "$ASLOT_OTHER" = "arm64" ]; then
    ASLOT_QEMU="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
fi

# 1. The repro: a builtin call nested in another builtin's argument list.
cat > "$DIR/../aslot_write_$$.kr" <<'ASLOT_WRITE'
fn main() {
    u64 outer = "OUT\n"
    u64 inner = "IN\n"
    write(1, outer, write(2, inner, 3) + 1)
    exit(0)
}
ASLOT_WRITE

# 2. Value corruption in three more builtins: the parked argument comes back
#    as the nested write's fd. store64 parks an ADDRESS, so it segfaults.
cat > "$DIR/../aslot_val_$$.kr" <<'ASLOT_VAL'
fn main() {
    u64 s = "X\n"
    u64 a = signed_lt(5, 3 + write(2, s, 0))
    u64 b = bit_range(255, 0, 4 + write(2, s, 0))
    u64 buf = alloc(64)
    store64(buf, 77 + write(2, s, 0))
    u64 c = load64(buf)
    if a == 0  { write(1, "A\n", 2) }
    if b == 15 { write(1, "B\n", 2) }
    if c == 77 { write(1, "C\n", 2) }
    write(2, "done\n", 5)
    exit(0)
}
ASLOT_VAL

# 3. f-string: the running output offset lives in temp_slot_1 for the whole
#    segment loop, so a builtin in an interpolation walks the destination
#    pointer off the buffer (this one SEGFAULTED, it did not merely misprint).
cat > "$DIR/../aslot_fstr_$$.kr" <<'ASLOT_FSTR'
import "std/io.kr"
fn main() {
    u64 s = "X\n"
    println(f"A{write(2, s, 0)}B{write(2, s, 0)}C")
    write(2, "fs\n", 3)
    exit(0)
}
ASLOT_FSTR

# 4. Tuple returns park each element across the evaluation of the later ones.
cat > "$DIR/../aslot_tuple_$$.kr" <<'ASLOT_TUPLE'
fn two() -> u64 {
    return (11 + write(2, "F\n", 0), 22 + write(2, "G\n", 0))
}
fn three() -> u64 {
    return (31 + write(2, "H\n", 0), 32 + write(2, "I\n", 0), 33 + write(2, "J\n", 0))
}
fn main() {
    (u64 a, u64 b) = two()
    (u64 x, u64 y, u64 z) = three()
    if a == 11 { write(1, "a\n", 2) }
    if b == 22 { write(1, "b\n", 2) }
    if x == 31 { write(1, "x\n", 2) }
    if y == 32 { write(1, "y\n", 2) }
    if z == 33 { write(1, "z\n", 2) }
    write(2, "tup\n", 4)
    exit(0)
}
ASLOT_TUPLE

# 5. No nested call at all: a fractional float LITERAL uses both slots as
#    scratch, so fma_f64's parked arguments are destroyed by its own operands.
cat > "$DIR/../aslot_flit_$$.kr" <<'ASLOT_FLIT'
fn main() {
    f64 r = fma_f64(2.5, 4.5, 1.25)
    u64 g = f64_to_int(r * 100.0)
    if g == 1250 { write(1, "flit\n", 5) } else { write(1, "BAD\n", 4) }
    write(2, "fl\n", 3)
    exit(0)
}
ASLOT_FLIT

aslot_want_out() {
    case "$1" in
        *aslot_write_*) printf 'OUT\n' ;;
        *aslot_val_*)   printf 'A\nB\nC\n' ;;
        *aslot_fstr_*)  printf 'A0B0C\n' ;;
        *aslot_tuple_*) printf 'a\nb\nx\ny\nz\n' ;;
        *aslot_flit_*)  printf 'flit\n' ;;
    esac
}
aslot_want_err() {
    case "$1" in
        *aslot_write_*) printf 'IN\n' ;;
        *aslot_val_*)   printf 'done\n' ;;
        *aslot_fstr_*)  printf 'fs\n' ;;
        *aslot_tuple_*) printf 'tup\n' ;;
        *aslot_flit_*)  printf 'fl\n' ;;
    esac
}

ASLOT_RAN=0
aslot_run() { # <arch> <flags> <src> <runner-or-empty>
    local _bin="/tmp/krc_aslot_$$"
    local _eo="/tmp/krc_aslot_eo_$$"
    local _tag="$(basename $3) $1 ${2:-IR}"
    if ! $KRC --arch="$1" $2 "$3" -o "$_bin" >/dev/null 2>&1; then
        ASLOT_OK=0; echo "  $_tag: COMPILE FAILED"
        return
    fi
    local _out
    if [ -n "$4" ]; then _out=$($4 "$_bin" 2>"$_eo"); else _out=$("$_bin" 2>"$_eo"); fi
    local _err="$(cat "$_eo")"
    local _wo="$(aslot_want_out "$3")"
    local _we="$(aslot_want_err "$3")"
    ASLOT_RAN=$((ASLOT_RAN + 1))
    # A missing expectation would make every comparison vacuous.
    if [ -z "$_wo" ] || [ -z "$_we" ]; then
        ASLOT_OK=0; echo "  $_tag: no expectation recorded for this source"
    # An empty capture compared against a non-empty expectation must fail
    # loudly rather than looking like a mismatch of trailing whitespace.
    elif [ -z "$_out" ]; then
        ASLOT_OK=0; echo "  $_tag: EMPTY stdout, want $(printf '%s' "$_wo" | tr '\n' '/')"
    elif [ "$_out" != "$_wo" ]; then
        ASLOT_OK=0
        echo "  $_tag: stdout $(printf '%s' "$_out" | tr '\n' '/') want $(printf '%s' "$_wo" | tr '\n' '/')"
    elif [ "$_err" != "$_we" ]; then
        ASLOT_OK=0
        echo "  $_tag: stderr $(printf '%s' "$_err" | tr '\n' '/') want $(printf '%s' "$_we" | tr '\n' '/')"
    fi
    rm -f "$_bin" "$_eo"
}
for _src in "$DIR/../aslot_write_$$.kr" "$DIR/../aslot_val_$$.kr" \
            "$DIR/../aslot_fstr_$$.kr" "$DIR/../aslot_tuple_$$.kr" \
            "$DIR/../aslot_flit_$$.kr"; do
    aslot_run "$RUN_ARCH" ""          "$_src" ""
    aslot_run "$RUN_ARCH" "--legacy"  "$_src" ""
    if [ -n "$ASLOT_QEMU" ]; then
        aslot_run "$ASLOT_OTHER" ""         "$_src" "$ASLOT_QEMU"
        aslot_run "$ASLOT_OTHER" "--legacy" "$_src" "$ASLOT_QEMU"
    fi
done
# Guard against the loop silently doing nothing. 5 sources x 2 host configs
# always; x2 more per source when the other arch is runnable.
ASLOT_WANT=10
if [ -n "$ASLOT_QEMU" ]; then ASLOT_WANT=20; fi
[ "$ASLOT_RAN" = "$ASLOT_WANT" ] || { ASLOT_OK=0; echo "  only $ASLOT_RAN/$ASLOT_WANT config-runs executed"; }
if [ "$ASLOT_OK" = "1" ]; then
    echo "  builtin_args_get_a_private_scratch_slot: PASS ($ASLOT_RAN config-runs)"
    PASS=$((PASS + 1))
else
    echo "FAIL: builtin_args_get_a_private_scratch_slot"
    FAIL=$((FAIL + 1))
fi
rm -f "$DIR/../aslot_write_$$.kr" "$DIR/../aslot_val_$$.kr" \
      "$DIR/../aslot_fstr_$$.kr" "$DIR/../aslot_tuple_$$.kr" \
      "$DIR/../aslot_flit_$$.kr"

# --- `/=` and `%=` ----------------------------------------------------------
# Both legacy backends' BinOp operator chains listed the compound tokens for
# every operator EXCEPT SlashEq (48) and PercentEq (49): x86 had arms for
# 45/46/47/50/51/52 and paired 43||53, 44||54, but `/` (32) and `%` (33) stood
# alone; arm64 paired 30||45, 31||46, 22||47, 23||50, 24||51, 25||52, 43||53,
# 44||54 and likewise left 32 and 33 unpaired. An op_kind that matches no arm
# falls out of the whole if/else chain having emitted nothing, so the
# accumulator still held the LHS and the enclosing store wrote that unchanged
# value back. `x /= v`, `arr[i] /= v` and the deref form all compiled clean,
# raised no diagnostic, and silently discarded the result on BOTH legacy
# backends while the IR backends were correct -- a genuine IR/legacy
# divergence, mirrored in tests/diff_ir_legacy.sh.
#
# Note this was never specific to the indexed form: the plain-variable
# `x /= v` was equally broken, because the defect is in the shared BinOp
# lowering that the parser's desugar feeds, not in any store path. Source 3
# therefore pins the plain forms as controls alongside the indexed ones -- a
# fix that only taught the indexed store about `/=` would look complete
# without them.
#
# Three things are asserted, not one:
#   * that it computes the VALUE (source 3 -- a row asserting only that the
#     program compiles, or only a non-zero exit, passes against this bug)
#   * that `/` and `%` stay SIGNED for signed operands (source 3's tail --
#     -24/5 must be -4 and -24%5 must be -4, not the unsigned garbage a
#     udiv/div would produce)
#   * that the index/address is evaluated exactly ONCE and before the value
#     (sources 1 and 2 -- `seq` records execution order as decimal digits, so
#     these two operators are pinned to the same CompoundTemp machinery the
#     other eight OP= forms use rather than growing a double-evaluating path)
#
# These rows EXECUTE, so they follow $RUN_ARCH rather than naming an arch.
TOTAL=$((TOTAL + 1))
DMA_OK=1
DMA_OTHER="arm64"
if [ "$RUN_ARCH" = "arm64" ]; then DMA_OTHER="x86_64"; fi
DMA_QEMU=""
if [ "$DMA_OTHER" = "arm64" ]; then
    DMA_QEMU="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
fi

# 1. arr[i()] /= v() -- index once, then value => seq 12, and arr[3] == 30/4.
cat > "$DIR/../dmassign_idx_$$.kr" <<'DMASSIGN_IDX'
static u64 seq = 0
static u8[16] arr
fn ai() -> u64 { seq = seq * 10 + 1  return 3 }
fn fv() -> u64 { seq = seq * 10 + 2  return 4 }
fn main() {
    arr[3] = 30
    arr[ai()] /= fv()
    if seq != 12 { exit(1) }
    if arr[3] != 7 { exit(2) }
    exit(7)
}
DMASSIGN_IDX

# 2. unsafe { *(ap() as uint32) %= fv() } -- address once, then value.
cat > "$DIR/../dmassign_ptr_$$.kr" <<'DMASSIGN_PTR'
static u64 seq = 0
static u8[16] buf
fn ap() -> u64 { seq = seq * 10 + 1  return buf }
fn fv() -> u64 { seq = seq * 10 + 2  return 4 }
fn main() {
    store32(buf, 30)
    unsafe { *(ap() as uint32) %= fv() }
    if seq != 12 { exit(1) }
    if load32(buf) != 2 { exit(2) }
    exit(7)
}
DMASSIGN_PTR

# 3. VALUES on every target form: plain variable (the control), array element,
#    deref, and signed `/=` / `%=` which must truncate toward zero.
cat > "$DIR/../dmassign_val_$$.kr" <<'DMASSIGN_VAL'
static u64[8] a
static u8[16] buf
fn main() {
    uint64 v = 23
    v /= 2
    if v != 11 { exit(1) }
    v %= 4
    if v != 3 { exit(2) }
    a[3] = 23
    a[3] /= 2
    if a[3] != 11 { exit(3) }
    a[3] %= 5
    if a[3] != 1 { exit(4) }
    store32(buf, 30)
    unsafe { *(buf as uint32) /= 4 }
    if load32(buf) != 7 { exit(5) }
    unsafe { *(buf as uint32) %= 4 }
    if load32(buf) != 3 { exit(6) }
    int64 s = 0 - 24
    s /= 5
    if s != 0 - 4 { exit(8) }
    int64 t = 0 - 24
    t %= 5
    if t != 0 - 4 { exit(9) }
    exit(7)
}
DMASSIGN_VAL

DMA_RAN=0
dma_run() { # <arch> <flags> <src> <runner-or-empty>
    local _bin="/tmp/krc_dmassign_$$"
    if ! $KRC --arch="$1" $2 "$3" -o "$_bin" >/dev/null 2>&1; then
        DMA_OK=0; echo "  $(basename $3) $1 ${2:-IR}: COMPILE FAILED"
        return
    fi
    if [ -n "$4" ]; then $4 "$_bin" >/dev/null 2>&1; else "$_bin" >/dev/null 2>&1; fi
    local _rc=$?
    DMA_RAN=$((DMA_RAN + 1))
    # 7 = every assertion satisfied. Anything else names the assertion that
    # failed; 1 on sources 1/2 is specifically a wrong evaluation order, and
    # the discard defect reports 2 there and 1/3/5/8 on source 3.
    [ "$_rc" = "7" ] || { DMA_OK=0; echo "  $(basename $3) $1 ${2:-IR}: got $_rc, want 7"; }
    rm -f "$_bin"
}
for _src in "$DIR/../dmassign_idx_$$.kr" "$DIR/../dmassign_ptr_$$.kr" "$DIR/../dmassign_val_$$.kr"; do
    dma_run "$RUN_ARCH" ""          "$_src" ""
    dma_run "$RUN_ARCH" "--legacy"  "$_src" ""
    if [ -n "$DMA_QEMU" ]; then
        dma_run "$DMA_OTHER" ""         "$_src" "$DMA_QEMU"
        dma_run "$DMA_OTHER" "--legacy" "$_src" "$DMA_QEMU"
    fi
done
# Guard against the loop silently doing nothing. 3 sources x 2 host configs
# always; x2 more per source when the other arch is runnable.
DMA_WANT=6
if [ -n "$DMA_QEMU" ]; then DMA_WANT=12; fi
[ "$DMA_RAN" = "$DMA_WANT" ] || { DMA_OK=0; echo "  only $DMA_RAN/$DMA_WANT config-runs executed"; }
if [ "$DMA_OK" = "1" ]; then
    echo "  divmod_assign_ops: PASS ($DMA_RAN config-runs)"
    PASS=$((PASS + 1))
else
    echo "FAIL: divmod_assign_ops"
    FAIL=$((FAIL + 1))
fi
rm -f "$DIR/../dmassign_idx_$$.kr" "$DIR/../dmassign_ptr_$$.kr" \
      "$DIR/../dmassign_val_$$.kr"

# --- Documentation pins (2026-08-14) ----------------------------------------
#
# The 2026-08-06 docs audit found ~163 false claims across 20 docs. They all
# rotted for the same reason: NOTHING CHECKED THEM. Correcting the prose alone
# just restarts the clock, so each of the six rows below asserts the measured
# reality behind a claim I have just re-verified. If the behaviour changes, the
# row goes red and names the doc that has to change with it.
#
# Every row here guards against passing VACUOUSLY: an empty grep capture, a
# renamed symbol, or a probe that produced no output FAILS the row rather than
# sailing through a comparison of "" against "".

# 1. Block comments are NOT implemented. `/* ... */` is not lexed; the `/` is
#    lexed as a divide operator and the parser then chokes.
#
#    SUBTLETY, and the exact reason the "block comments are supported" claim
#    survived: a SINGLE-LINE `/* x */` at TOP LEVEL compiles clean. That is an
#    accident, not support -- before a declaration the parser skips tokens it
#    does not recognise, so the whole comment is swallowed and never reaches an
#    expression context. Anyone who probes block comments by putting one at the
#    top of a file therefore "confirms" a feature that does not exist. THE
#    TOP-LEVEL FORM IS NOT A VALID PROBE. Pin the statement position instead,
#    which genuinely errors, and pin the top-level accident too so that a
#    partial implementation cannot land unnoticed.
#
#    Parse-only: a parse error is reached before any codegen, so the arch is
#    irrelevant -- $RUN_ARCH is used purely because it is always a valid value.
TOTAL=$((TOTAL + 1))
BC_OK=1
cat > "$DIR/../docpin_bc_body_$$.kr" <<'BC_BODY'
fn main() {
    /* inside a function body */
    exit(0)
}
BC_BODY
cat > "$DIR/../docpin_bc_top_$$.kr" <<'BC_TOP'
/* top level single line */
fn main() {
    exit(0)
}
BC_TOP
# Capture the COMPILER's status, not a later grep's. Reading `grep`'s exit code
# and calling it the compiler's is a mistake I made twice on 2026-08-13.
bc_out=$($KRC --arch=$RUN_ARCH "$DIR/../docpin_bc_body_$$.kr" -o /tmp/krc_bc_$$ 2>&1)
bc_rc=$?
rm -f /tmp/krc_bc_$$
if [ "$bc_rc" = "0" ]; then
    BC_OK=0
    echo "  block comment in a STATEMENT position compiled -- block comments appear to be implemented now"
fi
# Assert the diagnostic, not merely a non-zero exit: any unrelated breakage
# also exits non-zero, and would otherwise keep this row green for the wrong
# reason.
if ! printf '%s' "$bc_out" | grep -q 'error: unexpected token in expression'; then
    BC_OK=0
    echo "  expected 'error: unexpected token in expression', got: $(printf '%s' "$bc_out" | head -2)"
fi
# ...and that it points at the `/*` line (line 2 of the probe), so a parse
# error somewhere else in the file cannot satisfy this row.
if ! printf '%s' "$bc_out" | grep -q 'docpin_bc_body_.*\.kr:2:5: error:'; then
    BC_OK=0
    echo "  diagnostic did not point at the '/*' at line 2 col 5"
fi
# The top-level accident, pinned so a top-level-only implementation is visible.
$KRC --arch=$RUN_ARCH "$DIR/../docpin_bc_top_$$.kr" -o /tmp/krc_bct_$$ >/dev/null 2>&1
bct_rc=$?
rm -f /tmp/krc_bct_$$
if [ "$bct_rc" != "0" ]; then
    BC_OK=0
    echo "  the top-level single-line form no longer compiles (it did, by accident, on 2026-08-14)"
fi
if [ "$BC_OK" = "1" ]; then
    PASS=$((PASS + 1)); echo "  block_comments_unimplemented: PASS (statement position errors; top-level form still slips through)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: block_comments_unimplemented"
    echo "  if block comments were implemented on purpose, update docs/LANGUAGE.md and delete this row;"
    echo "  do NOT 'confirm' the feature with a top-level /* */ -- that form passes without any lexer support"
fi
rm -f "$DIR/../docpin_bc_body_$$.kr" "$DIR/../docpin_bc_top_$$.kr"

# 2. The @ctx / @effects / caps / lock-order analyses CANNOT FIRE. `ann_register`
#    and `lock_add_edge` are defined in src/analysis.kr and called from nowhere:
#    annotations are never parsed, so the tables stay empty and all four passes
#    are inert. docs/EFFECT_SYSTEM.md is therefore marked DESIGN ONLY.
#
#    Counting call sites needs care. A bare `grep -c 'ann_register(' src/*.kr`
#    is NOT zero -- it matches the `fn ann_register(` DEFINITION, and
#    `lock_add_edge` additionally matches a comment in src/main.kr that explains
#    this very situation. So: strip `//` comments first, then drop `fn` lines.
#
#    ANTI-VACUITY GUARD: also require both functions to still be DEFINED. Without
#    that, deleting or renaming them drives the call-site count to zero and this
#    row would go green on a tree where the symbols no longer exist at all.
TOTAL=$((TOTAL + 1))
# Count DEFINITIONS, not defining files: both live in src/analysis.kr, so a
# per-file count would say 1 and this row would have been born red.
ann_defs=$(cat "$DIR"/../src/*.kr | grep -cE '^[[:space:]]*fn[[:space:]]+(ann_register|lock_add_edge)[[:space:]]*\(')
ann_calls=$(cat "$DIR"/../src/*.kr \
    | sed 's://.*::' \
    | grep -E '(ann_register|lock_add_edge)[[:space:]]*\(' \
    | grep -vcE '^[[:space:]]*fn[[:space:]]')
ann_doc=$(grep -c 'Status: DESIGN ONLY' "$DIR/../docs/EFFECT_SYSTEM.md")
if [ "$ann_defs" = "2" ] && [ "$ann_calls" = "0" ] && [ "$ann_doc" = "1" ]; then
    PASS=$((PASS + 1)); echo "  effect_analyses_are_inert: PASS (both defined, 0 call sites, doc says DESIGN ONLY)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: effect_analyses_are_inert (definitions=$ann_defs want 2, call sites=$ann_calls want 0, doc DESIGN-ONLY marker=$ann_doc want 1)"
    echo "  if you WIRED THE ANALYSES UP, that is good news -- now drop the 'DESIGN ONLY' banner"
    echo "  and the four 'NOT IMPLEMENTED' headings from docs/EFFECT_SYSTEM.md in the same commit;"
    echo "  if you deleted or renamed the functions, update that doc and this row together"
fi

# 3. arm64 volatile emits NO completion barrier. On the default IR backend
#    vload32/vstore32 become LDAR/STLR -- acquire/release ORDERING, not a DSB.
#    docs/LANGUAGE.md and README.md both carry the measured table this pins:
#      x86_64 IR 2 x mfence | arm64 IR 0 x DSB (LDAR/STLR) | arm64 legacy 2 x DSB SY
#
#    MATCH ON THE ENCODING, NEVER THE MNEMONIC. The `--emit=asm` decoder prints
#    the LDAR/STLR encodings with a BLANK mnemonic field, so `grep -i stlr` finds
#    nothing on a tree that emits STLR perfectly. That is precisely how the false
#    "arm64 volatile emits DSB SY" claim survived: someone grepped for `stlr`,
#    saw zero, and concluded the barrier form must be in use.
#      88dffe.. = LDAR Wt,[Xn]    889ffe.. = STLR Wt,[Xn]
#
#    Compile-only (the listing is inspected, never executed), so pinning arches
#    here is correct and cannot break the native ARM64 CI job.
TOTAL=$((TOTAL + 1))
VOL_OK=1
cat > "$DIR/../docpin_vol_$$.kr" <<'VOL_SRC'
static u8[64] buf
fn main() {
    u32 status = vload32(buf)
    vstore32(buf, status)
    exit(0)
}
VOL_SRC
vol_check() { # <label> <arch> <extra-flags> <pattern> <want-count>
    local _asm="/tmp/krc_vol_$$.s"
    rm -f "$_asm"
    if ! $KRC --arch="$2" $3 --emit=asm "$DIR/../docpin_vol_$$.kr" -o "$_asm" >/dev/null 2>&1; then
        VOL_OK=0; echo "  $1: --emit=asm FAILED to compile"; return
    fi
    # An empty or missing listing must FAIL, not silently satisfy a want of 0.
    if [ ! -s "$_asm" ]; then
        VOL_OK=0; echo "  $1: listing is empty -- a want-0 check would have passed vacuously"; return
    fi
    local _got
    _got=$(grep -ci "$4" "$_asm")
    [ "$_got" = "$5" ] || { VOL_OK=0; echo "  $1: '$4' appears $_got time(s), want $5"; }
    rm -f "$_asm"
}
vol_check "arm64 IR LDAR"     arm64  ""          '88dffe' 1
vol_check "arm64 IR STLR"     arm64  ""          '889ffe' 1
vol_check "arm64 IR no DSB"   arm64  ""          'dsb'    0
vol_check "x86_64 IR mfence"  x86_64 ""          'mfence' 2
vol_check "arm64 legacy DSB"  arm64  "--legacy"  'dsb'    2
if [ "$VOL_OK" = "1" ]; then
    PASS=$((PASS + 1)); echo "  arm64_volatile_no_dsb: PASS (LDAR+STLR, 0 DSB; x86 2 mfence; legacy 2 DSB)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: arm64_volatile_no_dsb"
    echo "  the volatile lowering changed -- update the barrier tables in docs/LANGUAGE.md"
    echo "  and README.md in the same commit; grep the ENCODING, not the mnemonic"
fi
rm -f "$DIR/../docpin_vol_$$.kr" "/tmp/krc_vol_$$.s"

# 4. `krc fmt` PRINTS TO STDOUT and does not rewrite the file. getting-started.md
#    used to say it formatted in place, which would have had readers piping over
#    their own source.
#
#    THE PROBE MUST BE DELIBERATELY MIS-FORMATTED. My first version of this row
#    used an already-canonical `fn main() { exit(0) }`, and it PASSED against a
#    compiler I had patched to write the formatted text straight back over the
#    input -- because reformatting canonical source reproduces it byte for byte,
#    so the in-place write left the hash alone. A hash check is only evidence if
#    formatting actually changes the bytes. Hence the ragged indentation below,
#    plus an explicit assertion that stdout DIFFERS from the input: if the
#    formatter ever becomes a no-op on this probe, the row fails and says so
#    rather than going quietly vacuous again.
TOTAL=$((TOTAL + 1))
FMT_OK=1
cat > "$DIR/../docpin_fmt_$$.kr" <<'FMT_SRC'
fn main()    {
exit(0)
}
FMT_SRC
fmt_orig=$(cat "$DIR/../docpin_fmt_$$.kr")
fmt_before=$(md5sum < "$DIR/../docpin_fmt_$$.kr")
fmt_out=$($KRC fmt "$DIR/../docpin_fmt_$$.kr" 2>/dev/null)
fmt_after=$(md5sum < "$DIR/../docpin_fmt_$$.kr")
if [ "$fmt_before" != "$fmt_after" ]; then
    FMT_OK=0; echo "  krc fmt REWROTE the input file"
fi
if [ -z "$fmt_out" ]; then
    FMT_OK=0; echo "  krc fmt produced no stdout -- the unchanged hash proves nothing here"
fi
if [ "$fmt_out" = "$fmt_orig" ]; then
    FMT_OK=0
    echo "  krc fmt did not reformat the probe, so the unchanged hash is vacuous"
    echo "  -- make the probe messier, or this row stops proving anything"
fi
if ! printf '%s' "$fmt_out" | grep -q 'fn main()'; then
    FMT_OK=0; echo "  krc fmt stdout did not contain the formatted source"
fi
fmt_doc=$(grep -c 'does \*not\* rewrite the file' "$DIR/../docs/getting-started.md")
if [ "$fmt_doc" != "1" ]; then
    FMT_OK=0; echo "  docs/getting-started.md no longer states that fmt does not rewrite (matches=$fmt_doc)"
fi
if [ "$FMT_OK" = "1" ]; then
    PASS=$((PASS + 1)); echo "  fmt_does_not_write_in_place: PASS (hash unchanged, formatted text on stdout)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: fmt_does_not_write_in_place"
    echo "  if you made fmt write in place, update the krc fmt row in docs/getting-started.md"
fi
rm -f "$DIR/../docpin_fmt_$$.kr"

# 5. README's advertised test count must equal what this suite actually reports.
#    README.md states it TWICE and both must agree with the total, so updating
#    one and missing the other is a red.
#
#    This row is SELF-REFERENTIAL: it is itself counted in the total. The
#    comparison therefore cannot happen here -- at this point in the file $TOTAL
#    is only a few hundred, with ~17 800 lines of rows still to run. Part A
#    below parses and validates README; PART B, DOWN IN THE SUMMARY BLOCK, does
#    the comparison once $TOTAL is final. TOTAL is incremented HERE so that the
#    number README must state includes this row.
TOTAL=$((TOTAL + 1))
README_COUNTS=$(grep -oE '\*\*[0-9]+ tests\*\*' "$DIR/../README.md" | grep -oE '[0-9]+')
# An empty capture must FAIL, never compare "" against "" and pass.
README_N=$(printf '%s\n' "$README_COUNTS" | grep -c '^[0-9][0-9]*$')
README_UNIQ=$(printf '%s\n' "$README_COUNTS" | sort -u | tr '\n' ' ' | sed 's/ *$//')

# 6. std/ DOES NOT COMPILE FOR riscv32, and that is a DELIBERATE SCOPE BOUNDARY,
#    NOT A GAP. The stdlib is written for 64-bit hosts; riscv32 exists as
#    scaffolding for the Xtensa/ESP32 backend. Every std module is rejected at
#    its first u64. DO NOT "FIX" THIS by widening riscv32 or by rewriting std/ in
#    uint32 -- if the scope decision is ever actually reversed, change the docs
#    and this row together, deliberately.
#
#    Assert the ERROR TEXT, not just a non-zero exit: a missing file, a bad flag
#    or any unrelated failure also exits non-zero and would keep this row green
#    while proving nothing. Compile-only, so --arch=riscv32 is pinned safely.
TOTAL=$((TOTAL + 1))
RV_OK=1
RV_SEEN=0
RV_BAD=0
for _std in "$DIR"/../std/*.kr; do
    RV_SEEN=$((RV_SEEN + 1))
    rv_out=$($KRC --arch=riscv32 "$_std" -o /tmp/krc_rv_$$ 2>&1)
    rm -f /tmp/krc_rv_$$
    if ! printf '%s' "$rv_out" | grep -q 'error: 64-bit integers not supported on riscv32; use uint32'; then
        RV_OK=0
        RV_BAD=$((RV_BAD + 1))
        [ "$RV_BAD" -le 3 ] && echo "  $(basename "$_std"): not rejected at a u64 -- got: $(printf '%s' "$rv_out" | head -1)"
    fi
done
# Guard the loop against doing nothing: an empty glob would leave RV_OK=1.
if [ "$RV_SEEN" != "35" ]; then
    RV_OK=0
    echo "  swept $RV_SEEN std modules, expected 35 -- the glob found the wrong set"
fi
if [ "$RV_OK" = "1" ]; then
    PASS=$((PASS + 1)); echo "  std_rejected_on_riscv32: PASS (all $RV_SEEN modules rejected at their first u64)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: std_rejected_on_riscv32 ($RV_BAD of $RV_SEEN modules not rejected as expected)"
    echo "  std/ on riscv32 is a deliberate 64-bit-host scope decision, not a missing feature."
    echo "  If it was reversed on purpose, update README.md and docs/ and change this row too."
fi

rm -f "$DIR/../ceval_idx_$$.kr" "$DIR/../ceval_ptr_$$.kr" "$DIR/../ceval_plain_$$.kr"

# File-scope struct statics: `static Point[N] pts` and `static Point sp`.
#
# These SILENTLY LOST DATA on all four backends. struct_var_table is reset per
# function, so a file-scope static could never be in it; every field access
# fell through to the enum/zero path and the store emitted nothing while the
# load returned 0. On top of that the parser sized `static Point[10]` at one
# WORD per element (80 bytes, not 160), and `pts[i]` as a value loaded 8 bytes
# where the element ADDRESS was meant, so dereferencing it segfaulted.
#
# Every row below ASSERTS A VALUE. A row that only checked "it compiles" passed
# against the whole defect, which is why the plain-`static Point` read was the
# only symptom anyone ever saw (it errored) while the write went missing in
# silence. r10 is the LOCAL positive control that always worked: if the fix
# ever regresses locals, that row goes red rather than the bug hiding.
TOTAL=$((TOTAL + 1))
SSTR_OK=1
# These rows EXECUTE, so they follow $RUN_ARCH rather than naming an arch.
SSTR_OTHER="arm64"
if [ "$RUN_ARCH" = "arm64" ]; then SSTR_OTHER="x86_64"; fi
SSTR_QEMU=""
if [ "$SSTR_OTHER" = "arm64" ]; then
    SSTR_QEMU="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
fi
SSTR_HDR='struct Point { u64 x  u64 y }
static Point[10] pts
static Point sp
static uint64 sguard
'
sstr_src() { printf '%s%s\n' "$SSTR_HDR" "$1" > "$DIR/../sstr_$2_$$.kr"; }
# const index, both fields, write-then-read
sstr_src 'fn main() { pts[3].x = 50  pts[3].y = 60  exit(pts[3].x + pts[3].y - 60) }' cidx
# computed index, and element 3 must not alias element 7
sstr_src 'fn main() { u64 i = 7  pts[3].x = 9  pts[i].x = 50  if pts[3].x != 9 { exit(1) }  exit(pts[i].x) }' vidx
# field write -> RAW read at base+48 (element 3, field x, stride must be 16)
sstr_src 'fn main() { pts[3].x = 50  u64 b = pts  u64 p = b + 48  u64 v = 0  unsafe { *(p as u64) -> v }  exit(v) }' fwrr
# RAW write at base+48 -> FIELD read
sstr_src 'fn main() { u64 b = pts  u64 p = b + 48  unsafe { *(p as u64) = 50 }  exit(pts[3].x) }' rwfr
# pts[i] AS A VALUE is the element ADDRESS: stride 16, and dereferencing it
# must return the stored field rather than segfaulting (was rc 139).
sstr_src 'fn main() { pts[3].x = 50  u64 e0 = pts[0]  u64 e1 = pts[1]  if e1 - e0 != 16 { exit(1) }  u64 e3 = pts[3]  u64 v = 0  unsafe { *(e3 as u64) -> v }  exit(v) }' eval
# plain `static Point sp`: write-then-read on both fields, bare `sp` decays to
# its address, and element 9 of pts must not reach sp or sguard (160B reserved)
sstr_src 'fn main() { sguard = 7  sp.x = 20  sp.y = 30  pts[9].y = 99  if sp.x != 20 { exit(1) }  if sp.y != 30 { exit(2) }  if sguard != 7 { exit(3) }  u64 b = sp  u64 v = 0  unsafe { *(b as u64) -> v }  if v != 20 { exit(4) }  exit(sp.x + sp.y) }' plain
# LOCAL struct array + local plain struct: the positive control
sstr_src 'fn main() { Point[4] loc  Point lp  loc[2].x = 20  loc[2].y = 30  lp.x = 0  u64 a = loc[0]  u64 c = loc[1]  if c - a != 16 { exit(1) }  exit(loc[2].x + loc[2].y + lp.x) }' local
SSTR_RAN=0
sstr_run() { # <arch> <flags> <src> <runner-or-empty> <expected>
    local _bin="/tmp/krc_sstr_$$"
    if ! $KRC --arch="$1" $2 "$3" -o "$_bin" >/dev/null 2>&1; then
        SSTR_OK=0; echo "  $(basename $3) $1 ${2:-IR}: COMPILE FAILED"
        return
    fi
    if [ -n "$4" ]; then $4 "$_bin" >/dev/null 2>&1; else "$_bin" >/dev/null 2>&1; fi
    local _rc=$?
    SSTR_RAN=$((SSTR_RAN + 1))
    [ "$_rc" = "$5" ] || { SSTR_OK=0; echo "  $(basename $3) $1 ${2:-IR}: got $_rc, want $5"; }
    rm -f "$_bin"
}
for _pair in "cidx:50" "vidx:50" "fwrr:50" "rwfr:50" "eval:50" "plain:50" "local:50"; do
    _s="$DIR/../sstr_${_pair%%:*}_$$.kr"
    _w="${_pair##*:}"
    sstr_run "$RUN_ARCH" ""          "$_s" ""            "$_w"
    sstr_run "$RUN_ARCH" "--legacy"  "$_s" ""            "$_w"
    if [ -n "$SSTR_QEMU" ]; then
        sstr_run "$SSTR_OTHER" ""         "$_s" "$SSTR_QEMU" "$_w"
        sstr_run "$SSTR_OTHER" "--legacy" "$_s" "$SSTR_QEMU" "$_w"
    fi
done
# Guard against the loop silently doing nothing. 7 sources x 2 host configs
# always; x2 more per source when the other arch is runnable.
SSTR_WANT=14
if [ -n "$SSTR_QEMU" ]; then SSTR_WANT=28; fi
[ "$SSTR_RAN" = "$SSTR_WANT" ] || { SSTR_OK=0; echo "  only $SSTR_RAN/$SSTR_WANT config-runs executed"; }
if [ "$SSTR_OK" = "1" ]; then
    echo "  file_scope_struct_statics_all_backends: PASS ($SSTR_RAN config-runs)"
    PASS=$((PASS + 1))
else
    echo "FAIL: file_scope_struct_statics_all_backends"
    FAIL=$((FAIL + 1))
fi
rm -f "$DIR/../sstr_cidx_$$.kr" "$DIR/../sstr_vidx_$$.kr" "$DIR/../sstr_fwrr_$$.kr" \
      "$DIR/../sstr_rwfr_$$.kr" "$DIR/../sstr_eval_$$.kr" "$DIR/../sstr_plain_$$.kr" \
      "$DIR/../sstr_local_$$.kr"

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

# atomic_cas_hit_then_miss: the same HIT/MISS/CELL sequence as
# tests/esp32/cas_single.mlr (100 -> 200 succeeds, then 100 -> 300 fails
# because the cell is now 200), reduced to one exit code. This is the
# x86_64 regression coverage for Task 7 (IR_ATOMIC_CAS / xtensa S32C1I):
# no test exercises op 93 on xtensa itself (KernRift has no
# std/esp32_clk.kr / esp32_uart.kr for a standalone esp32 fixture yet),
# so this proves the shared front-end contract both backends rely on --
# imm-as-vreg desired operand, BOOLEAN 1/0 (not old-value) result, and a
# second CAS on the same cell not corrupting what the first one wrote.
# A broken emitter fails this: returning the old word instead of a
# boolean makes ok_hit=100 (!= 1) or ok_miss=200 (!= 0); a reversed
# comparison polarity flips which of ok_hit/ok_miss is 1 vs 0; and reusing
# the caller's `desired` register instead of a scratch (the S32C1I
# destructive-register bug this port specifically guards against) would
# leave v with a stale value after the second call. Any of those makes
# the `if` condition false and the test exits 0, not 42.
run_test "atomic_cas_hit_then_miss" 'fn main() {
    uint64 buf = alloc(64)
    atomic_store(buf, 100)
    uint64 ok_hit = atomic_cas(buf, 100, 200)
    uint64 ok_miss = atomic_cas(buf, 100, 300)
    uint64 v = atomic_load(buf)
    if ok_hit == 1 && ok_miss == 0 && v == 200 { exit(42) }
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

# -c takes no value: -c=1 must be REJECTED, not silently swallowed. -c is
# matched with str_eq_full, which matches the bare spelling only, so
# `-c=1` used to fall through to the final `else { input_path = arg }` and
# be silently ignored -- measured: exit 0 and a 176-byte EXECUTABLE (the
# default emit mode) instead of a .o.
TOTAL=$((TOTAL + 1))
rm -f /tmp/krc_c_eq_$$.o
c_eq_out=$($KRC $KRC_FLAGS -c=1 /tmp/krc_obj_$$.kr -o /tmp/krc_c_eq_$$.o 2>&1); c_eq_st=$?
if [ $c_eq_st -ne 0 ] && echo "$c_eq_out" | grep -q "takes no value" && [ ! -f /tmp/krc_c_eq_$$.o ]; then
    PASS=$((PASS + 1)); echo "  dash_c_rejects_value: PASS"
else
    FAIL=$((FAIL + 1)); echo "FAIL: dash_c_rejects_value (exit=$c_eq_st, artifact=$([ -f /tmp/krc_c_eq_$$.o ] && echo yes || echo no), out=$(echo "$c_eq_out" | head -1))"
fi
rm -f /tmp/krc_c_eq_$$.o

# -h takes no value: -h=1 must be REJECTED, not silently swallowed. -h is
# matched with str_eq_full (bare spelling only), so `-h=1` used to fall
# through to the final `else { input_path = arg }` and be silently treated
# as an input filename instead of printing help -- measured: exit 0, no
# usage text. Note this is NOT the same shape as `--help=1`, which is
# matched with str_starts_with like every other `=`-less flag and is
# therefore out of scope here (see the --image-header/--reset-vector/-c
# rows above) -- deliberately left accepting a value it ignores.
TOTAL=$((TOTAL + 1))
h_eq_out=$($KRC -h=1 2>&1); h_eq_st=$?
if [ $h_eq_st -ne 0 ] && echo "$h_eq_out" | grep -q "takes no value"; then
    PASS=$((PASS + 1)); echo "  dash_h_rejects_value: PASS"
else
    FAIL=$((FAIL + 1)); echo "FAIL: dash_h_rejects_value (exit=$h_eq_st, out=$(echo "$h_eq_out" | head -1))"
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

# --- @export controls STB_GLOBAL vs STB_LOCAL in --emit=obj symtab ---
# @export is parsed and stored in ast_data4 bit 2 but used to have ZERO
# effect on ELF symbol binding: every function except main was emitted
# STB_LOCAL regardless, so a C driver could never link against a KernRift
# .o (nm showed lowercase `t name`, not `T name`). Fixed by threading
# ann_flags & 4 through gen_function/gen_function_a64 into export_fn_table,
# which emit_elf_relocatable consults when deciding LOCAL vs GLOBAL.
# --arch=x86_64 is pinned deliberately: this row only compiles and inspects
# the .o with readelf, it never executes the artifact, so it is safe to run
# on any host arch (see feedback_arch_pinned_rows).
echo ""
echo "--- @export symbol binding (--emit=obj) ---"
TOTAL=$((TOTAL + 1))
printf '@export\nfn addsix(u64 a, u64 b) -> u64 { return a + b + 6 }\n\nfn helper(u64 x) -> u64 { return x * 2 }\n\nfn main() -> uint32 { uint64 r = helper(1); exit(0) }\n' > /tmp/krc_export_$$.kr
if $KRC --arch=x86_64 --emit=obj /tmp/krc_export_$$.kr -o /tmp/krc_export_$$.o > /dev/null 2>&1 \
    && command -v readelf > /dev/null 2>&1; then
    symbols=$(readelf -sW /tmp/krc_export_$$.o 2>/dev/null)
    addsix_global=$(echo "$symbols" | grep -c 'FUNC.*GLOBAL.*addsix')
    helper_local=$(echo "$symbols" | grep -c 'FUNC.*LOCAL.*helper')
    main_global=$(echo "$symbols" | grep -c 'FUNC.*GLOBAL.*main')
    if [ "$addsix_global" -ge 1 ] && [ "$helper_local" -ge 1 ] && [ "$main_global" -ge 1 ]; then
        PASS=$((PASS + 1))
        echo "  export_symbol_global: PASS (@export addsix=GLOBAL, un-annotated helper=LOCAL, main=GLOBAL)"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: export_symbol_global (addsix_global=$addsix_global helper_local=$helper_local main_global=$main_global)"
        echo "$symbols"
    fi
else
    if command -v readelf > /dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        echo "FAIL: export_symbol_global (compilation with --emit=obj failed)"
    else
        PASS=$((PASS + 1))
        echo "  export_symbol_global: SKIP (readelf not found)"
    fi
fi
rm -f /tmp/krc_export_$$.kr /tmp/krc_export_$$.o

# --- ELF relocatable: large symbol table structural test (regression) ---
# Every --emit=obj test above compiles a two-function toy program, whose
# .strtab is a few hundred bytes. That never approached the .strtab buffer's
# cap (a fixed alloc(8192) in all four relocatable emitters, fixed in
# commit "size the relocatable .strtab from the actual symbol names"), so
# none of them could have caught the overflow: writing symbol names past
# that 8192-byte allocation stomps whatever memory the allocator placed
# next, up to and including the code buffer itself. KernRift's own object
# file (.strtab ~16.9 KB against the 8192 cap) happens not to show visible
# corruption today -- that is heap-layout luck, not correctness, so
# self-compiling isn't a reliable regression input either.
#
# This test instead generates 100 functions with deliberately long (~600
# byte) distinct names, pushing .strtab to roughly 60 KB -- about 7x the
# cap -- which reproduces real corruption deterministically against the
# pre-fix compiler on this allocator (mmap-per-alloc, no guard pages): the
# overrun lands on a live buffer and the emitted .text begins with symbol
# name bytes instead of machine code. It then validates structure two ways:
#   1. No two sections' [sh_offset, sh_offset+sh_size) ranges overlap --
#      catches this whole bug class (a buffer overrunning into another
#      region), not just this one instance.
#   2. .text's first bytes are not printable ASCII identifier characters --
#      the precise signature this bug produces.
echo ""
echo "--- ELF relocatable large symbol table structure (regression) ---"
TOTAL=$((TOTAL + 1))
BIGSYM_KR=/tmp/krc_bigsym_$$.kr
BIGSYM_O=/tmp/krc_bigsym_$$.o
if command -v python3 > /dev/null 2>&1; then
    xcount=$((600 - 4 - 1 - 6))
    xs=$(printf 'x%.0s' $(seq 1 $xcount))
    i=0
    while [ $i -lt 100 ]; do
        pad=$(printf '%06d' $i)
        r=$((i % 97))
        printf 'fn sym_%s_%s(uint64 a) -> uint64 { return a + %d }\n' "$xs" "$pad" "$r"
        i=$((i + 1))
    done > "$BIGSYM_KR"
    printf 'fn main() { exit(0) }\n' >> "$BIGSYM_KR"

    if $KRC $KRC_FLAGS --emit=obj "$BIGSYM_KR" -o "$BIGSYM_O" > /dev/null 2>&1; then
        if python3 -c "
import struct, sys

d = open('$BIGSYM_O', 'rb').read()
shoff = struct.unpack_from('<Q', d, 0x28)[0]
shnum = struct.unpack_from('<H', d, 0x3C)[0]
shstrndx = struct.unpack_from('<H', d, 0x3E)[0]

SHT_NOBITS = 8
secs = []
for i in range(shnum):
    base = shoff + i * 64
    name_off, stype, flags, addr, offset, size = struct.unpack_from('<IIQQQQ', d, base)
    secs.append((name_off, stype, offset, size))

shstr_off = secs[shstrndx][2]
def secname(name_off):
    end = d.index(b'\x00', shstr_off + name_off)
    return d[shstr_off + name_off:end].decode()

# 1) No two sections with file content overlap in [offset, offset+size).
ranges = sorted(
    (off, off + size, secname(nm))
    for (nm, st, off, size) in secs
    if size > 0 and st != SHT_NOBITS
)
overlap = None
for a, b in zip(ranges, ranges[1:]):
    if a[1] > b[0]:
        overlap = (a, b)
        break
if overlap:
    print('FAIL: sections overlap:', overlap)
    sys.exit(1)

# 2) .text must start with code, not identifier text.
text = None
for (nm, st, off, size) in secs:
    if secname(nm) == '.text':
        text = d[off:off + 8]
        break
if text is None:
    print('FAIL: no .text section found')
    sys.exit(1)
def is_ident_byte(b):
    return (65 <= b <= 90) or (97 <= b <= 122) or (48 <= b <= 57) or b == 0x5F
if all(is_ident_byte(b) for b in text):
    print('FAIL: .text starts with identifier text, not code:', text)
    sys.exit(1)

print('OK: sections non-overlapping, .text = ' + text.hex())
"; then
            PASS=$((PASS + 1))
            echo "  emit_obj_large_symtab_structure: PASS"
        else
            FAIL=$((FAIL + 1))
            echo "  emit_obj_large_symtab_structure: FAIL (corrupted/overlapping object, see above)"
        fi
    else
        FAIL=$((FAIL + 1))
        echo "  emit_obj_large_symtab_structure: FAIL (compilation failed)"
    fi
else
    PASS=$((PASS + 1))
    echo "  emit_obj_large_symtab_structure: SKIP (no python3)"
fi
rm -f "$BIGSYM_KR" "$BIGSYM_O"

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
# H2 legacy-backend companion of let_call_signed above -- moved down here
# (this is where run_test_legacy is defined; a call before this point is a
# bash "command not found", not a deferred call, since this file has no
# function-hoisting: it silently ran zero times).
run_test_legacy "let_call_signed_legacy" 'fn neg() -> i64 { return 0 - 5 }
fn main(){ let r = neg(); if r < 0 { exit(9) } exit(0) }' 9
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

# --- alloc() must return 0 on exhaustion, and dealloc(0) must be a no-op ---
# docs/UNDEFINED_BEHAVIOR.md promises "alloc returns 0. Callers must check."
# It did not: alloc stored its 8-byte size header through the raw mmap result,
# so a failed allocation SEGFAULTED INSIDE alloc (exit 139) and the documented
# null check was unreachable code. dealloc(0) faulted too -- it reads the size
# header at [ptr-8] before the munmap.
#
# These rows run on the HOST arch through the IR backend and again through
# run_test_legacy, because alloc/dealloc are lowered inline and SEPARATELY in
# each backend. --emit=obj and --emit=lkm select the legacy codegen with no
# --legacy on the command line, so an IR-only fix would leave `krc --emit=obj`
# faulting while plain `krc` returned 0. The arm64 twins live in the QEMU
# block further down (inside its `if`, or they would silently never run).
#
# The size is 0xFFFFFFFFFFFF0000, not a merely huge one: 16 TiB fits a 128 TiB
# user VA and fails only under the default vm.overcommit_memory=0 heuristic,
# so it would flip green on any host with overcommit_memory=1. A length past
# TASK_SIZE is refused by get_unmapped_area whatever the overcommit policy,
# and still survives the emitted `size + 8` without wrapping to 0.
run_test "alloc_oom_returns_zero" 'fn main() {
    u64 p = alloc(0xFFFFFFFFFFFF0000)
    if p == 0 { exit(42) }
    exit(7)
}' 42
run_test "alloc_oom_not_eight" 'fn main() {
    u64 p = alloc(0xFFFFFFFFFFFF0000)
    if p == 8 { exit(8) }
    if p != 0 { exit(9) }
    exit(42)
}' 42
run_test "alloc_success_header_intact" 'fn main() {
    u64 p = alloc(1000)
    if p == 0 { exit(1) }
    unsafe { *(p as uint64) = 3735928559 }
    u64 v = 0
    unsafe { *(p as uint64) -> v }
    if v != 3735928559 { exit(2) }
    u64 h = p - 8
    u64 sz = 0
    unsafe { *(h as uint64) -> sz }
    if sz != 1000 { exit(3) }
    dealloc(p)
    exit(42)
}' 42
run_test "dealloc_zero_no_fault" 'fn main() {
    dealloc(0)
    u64 p = alloc(0xFFFFFFFFFFFF0000)
    dealloc(p)
    exit(42)
}' 42
run_test_legacy "alloc_oom_returns_zero_legacy" 'fn main() {
    u64 p = alloc(0xFFFFFFFFFFFF0000)
    if p == 0 { exit(42) }
    exit(7)
}' 42
run_test_legacy "alloc_oom_not_eight_legacy" 'fn main() {
    u64 p = alloc(0xFFFFFFFFFFFF0000)
    if p == 8 { exit(8) }
    if p != 0 { exit(9) }
    exit(42)
}' 42
run_test_legacy "alloc_success_header_intact_legacy" 'fn main() {
    u64 p = alloc(1000)
    if p == 0 { exit(1) }
    unsafe { *(p as uint64) = 3735928559 }
    u64 v = 0
    unsafe { *(p as uint64) -> v }
    if v != 3735928559 { exit(2) }
    u64 h = p - 8
    u64 sz = 0
    unsafe { *(h as uint64) -> sz }
    if sz != 1000 { exit(3) }
    dealloc(p)
    exit(42)
}' 42
run_test_legacy "dealloc_zero_no_fault_legacy" 'fn main() {
    dealloc(0)
    u64 p = alloc(0xFFFFFFFFFFFF0000)
    dealloc(p)
    exit(42)
}' 42

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

# Legacy-path parity for struct-arg by-value uniformity + by-reference
# method self (fix/struct-param-writes). The legacy Index lowering used to
# load 8 garbage bytes for a struct-sized array element, and method self
# was received as a by-value copy (writes silently lost).
run_test_legacy "struct_arg_elem_data_legacy" 'struct P { u64 x; u64 y }
fn sum(P c) -> u64 { return c.x + c.y }
fn main() {
    P[3] arr
    arr[2].x = 30; arr[2].y = 12
    exit(sum(arr[2]))
}' 42

run_test_legacy "struct_arg_elem_byval_legacy" 'struct P { u64 x; u64 y }
fn poke(P c) -> u64 { c.x = 99; return c.x }
fn main() {
    P[3] arr
    arr[1].x = 42; arr[1].y = 2
    u64 r = poke(arr[1])
    exit(arr[1].x)
}' 42

run_test_legacy "method_self_mutation_legacy" 'struct P { u64 x; u64 y }
fn P.bump(P self) { self.x = 42 }
fn main() {
    P p; p.x = 1; p.y = 2
    p.bump()
    exit(p.x)
}' 42

run_test_legacy "method_self_nested_recv_legacy" 'struct P { u64 x; u64 y }
struct W { P p; u64 z }
fn P.setx(P self, u64 v) { self.x = v }
fn main() {
    W w; w.p.x = 1
    w.p.setx(42)
    exit(w.p.x)
}' 42

run_test_legacy "method_self_elem_recv_legacy" 'struct P { u64 x; u64 y }
fn P.setx(P self, u64 v) { self.x = v }
fn main() {
    P[3] arr
    arr[2].x = 1
    arr[2].setx(42)
    exit(arr[2].x)
}' 42

# Semantics lock: plain struct params stay by-value on the legacy path.
run_test_legacy "struct_arg_no_alias_legacy" 'struct P { u64 x; u64 y }
fn poke(P c) -> u64 { c.x = 99; return c.x }
fn main() {
    P p; p.x = 42; p.y = 2
    u64 r = poke(p)
    exit(p.x)
}' 42

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

# --- asm blocks must not destroy the CALLER's callee-saved registers ---
# The prologue's push set used to be built purely from colours the register
# allocator handed out, so a callee-saved register touched only by an asm
# block was neither pushed nor popped (MLRift tp_spawn_raw's `in(flags ->
# r15)` SIGSEGV'd its caller for exactly this reason). Both shapes below
# must survive; each caller keeps six values live across the call, which
# forces the allocator to fill rbx/r12/r13/r14/r15/rbp.
#
# `body` is the one that matters most: r15 is written by a raw instruction
# INSIDE the opaque asm text and named in no constraint list, so only a
# whole-function "has asm -> save everything" rule catches it.
run_test "asm_callee_saved_body_write" 'fn clobber(uint64 x) -> uint64 {
    uint64 r = 0
    asm { "0x49 0x89 0xC7" } in(x -> rax) out(rax -> r)
    return r
}
fn caller(uint64 seed) -> uint64 {
    uint64 a = seed + 1
    uint64 b = seed + 2
    uint64 c = seed + 3
    uint64 d = seed + 4
    uint64 e = seed + 5
    uint64 f = seed + 6
    uint64 t = clobber(seed)
    return a + b + c + d + e + f + t
}
fn main() { exit(caller(1)) }' 28

run_test "asm_callee_saved_in_constraint" 'fn clobber(uint64 x) -> uint64 {
    uint64 r = 0
    asm { "0x4C 0x89 0xF8" } in(x -> r15) out(rax -> r)
    return r
}
fn caller(uint64 seed) -> uint64 {
    uint64 a = seed + 1
    uint64 b = seed + 2
    uint64 c = seed + 3
    uint64 d = seed + 4
    uint64 e = seed + 5
    uint64 f = seed + 6
    uint64 t = clobber(seed)
    return a + b + c + d + e + f + t
}
fn main() { exit(caller(1)) }' 28
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

    # Struct-arg by-value uniformity + by-reference method self on arm64
    # (fix/struct-param-writes; shared IR lowering, but exercised under qemu
    # so the arm64 emitters are proven too).
    run_test_a64 "a64_struct_arg_nested_byval" 'struct I { uint64 a; uint64 b }
struct O { I inn; uint64 z }
fn poke(I c) -> uint64 { c.a = 99; return c.a }
fn main() { O o; o.inn.a = 42; uint64 r = poke(o.inn); exit(o.inn.a) }' 42

    run_test_a64 "a64_struct_arg_elem_byval" 'struct P { uint64 x; uint64 y }
fn poke(P c) -> uint64 { c.x = 99; return c.x }
fn main() { P[3] arr; arr[1].x = 42; uint64 r = poke(arr[1]); exit(arr[1].x) }' 42

    run_test_a64 "a64_method_self_mutation" 'struct P { uint64 x; uint64 y }
fn P.bump(P self) { self.x = 42 }
fn main() { P p; p.x = 1; p.bump(); exit(p.x) }' 42

    run_test_a64 "a64_method_self_elem_recv" 'struct P { uint64 x; uint64 y }
fn P.setx(P self, uint64 v) { self.x = v }
fn main() { P[3] arr; arr[2].x = 1; arr[2].setx(42); exit(arr[2].x) }' 42

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

    # Regression (v2.8.32 silent miscompile): ir_opt_recognize_rotate collapses
    # the 32-bit rotation idiom into IR_ROR on EVERY target, but the arm64
    # backend had no IR_ROR handler and silently emitted NOTHING for it — the
    # dest was never written and sha256 produced a garbage digest under qemu
    # while x86_64 was fine. The loop makes acc data-dependent so const-fold
    # cannot pre-compute the rotates; both idiom shapes are exercised
    # (variable `32 - n` and constant complementary shifts, like sha256).
    # Expected value precomputed with Python's matching semantics:
    #   acc = 0x592D7436, s = 0x3A9A6225.
    run_test_a64 "a64_ror_recognize_rotate" 'fn rotr32(uint64 x, uint64 n) -> uint64 {
    uint64 lo = (x >> n) & 0xFFFFFFFF
    uint64 hi = (x << (32 - n)) & 0xFFFFFFFF
    return lo | hi
}
fn main() {
    uint64 acc = 0x12345678
    uint64 i = 1
    while i < 9 {
        acc = rotr32(acc ^ i, i)
        i = i + 1
    }
    uint64 s = (rotr32(acc, 7) ^ rotr32(acc, 18) ^ (acc >> 3)) & 0xFFFFFFFF
    if acc != 0x592D7436 { exit(1) }
    if s != 0x3A9A6225 { exit(2) }
    exit(42)
}' 42

    # --- narrow volatile access width ---
    # The arm64 IR backend emitted a 64-bit STLR/LDAR for EVERY volatile access
    # regardless of the declared width, so a u8 write clobbered 7 neighbouring
    # bytes and a u8 read pulled them in. These rows must live inside this
    # QEMU/x86_64 block: run_test_a64 is defined at :2953 and this block ends
    # at the `fi` below, so calling it later would emit "command not found",
    # never increment TOTAL, and silently pass.
    run_test_a64 "a64_device_narrow_store_no_clobber" 'device Fake at 0x66666000 {
    Data   at 0x00 : u32
    Status at 0x04 : u8
    Other  at 0x08 : u32
}
fn main() {
    u64 nr = 9
    u64 aid = get_arch_id()
    if aid == 2 { nr = 222 }
    if aid == 4 { nr = 222 }
    if aid == 6 { nr = 222 }
    if aid == 7 { nr = 222 }
    syscall_raw(nr, 0x66666000, 4096, 3, 0x32, 0xFFFFFFFFFFFFFFFF, 0)
    Fake.Other = 99
    Fake.Status = 7
    exit(Fake.Other)
}' 99

    run_test_a64 "a64_device_narrow_load_no_bleed" 'device Fake at 0x66666000 {
    Data   at 0x00 : u32
    Status at 0x04 : u8
    Other  at 0x08 : u32
}
fn main() {
    u64 nr = 9
    u64 aid = get_arch_id()
    if aid == 2 { nr = 222 }
    if aid == 4 { nr = 222 }
    if aid == 6 { nr = 222 }
    if aid == 7 { nr = 222 }
    syscall_raw(nr, 0x66666000, 4096, 3, 0x32, 0xFFFFFFFFFFFFFFFF, 0)
    store8(0x66666004, 7)
    store32(0x66666008, 0x11111111)
    u64 s = Fake.Status
    if s == 7 { exit(0) }
    exit(1)
}' 0

    run_test_a64 "a64_vstore_narrow_no_clobber" 'fn main() {
    u64 nr = 9
    u64 aid = get_arch_id()
    if aid == 2 { nr = 222 }
    if aid == 4 { nr = 222 }
    if aid == 6 { nr = 222 }
    if aid == 7 { nr = 222 }
    syscall_raw(nr, 0x66666000, 4096, 3, 0x32, 0xFFFFFFFFFFFFFFFF, 0)
    vstore32(0x66666008, 99)
    vstore8(0x66666004, 7)
    exit(vload32(0x66666008))
}' 99

    # alloc/dealloc failure guards on arm64. These MUST live inside this `if`:
    # run_test_a64 is defined within it, so a row placed after the closing `fi`
    # is a bash "command not found" that never increments TOTAL and silently
    # passes. x86_64-only rows would not have caught the arm64 half -- both
    # arm64 lowerings (ir_aarch64.kr and codegen_aarch64.kr) had the same
    # unconditional header store, measured at exit 139 before the fix.
    run_test_a64 "a64_alloc_oom_returns_zero" 'fn main() {
    u64 p = alloc(0xFFFFFFFFFFFF0000)
    if p == 0 { exit(42) }
    exit(7)
}' 42
    run_test_a64 "a64_alloc_oom_not_eight" 'fn main() {
    u64 p = alloc(0xFFFFFFFFFFFF0000)
    if p == 8 { exit(8) }
    if p != 0 { exit(9) }
    exit(42)
}' 42
    run_test_a64 "a64_alloc_success_header_intact" 'fn main() {
    u64 p = alloc(1000)
    if p == 0 { exit(1) }
    unsafe { *(p as uint64) = 3735928559 }
    u64 v = 0
    unsafe { *(p as uint64) -> v }
    if v != 3735928559 { exit(2) }
    u64 h = p - 8
    u64 sz = 0
    unsafe { *(h as uint64) -> sz }
    if sz != 1000 { exit(3) }
    dealloc(p)
    exit(42)
}' 42
    run_test_a64 "a64_dealloc_zero_no_fault" 'fn main() {
    dealloc(0)
    u64 p = alloc(0xFFFFFFFFFFFF0000)
    dealloc(p)
    exit(42)
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

# Narrow volatile access width. NOTE: device_block_read_write above passes even
# with the width bug present -- its overlapping 64-bit stores still truncate to
# the expected reads -- so it is NOT width coverage. These rows are.
# They compile at the host arch, so they are the arm64 coverage on the native
# ubuntu-24.04-arm CI job; the a64_* twins above cover the x86_64 job via QEMU.
run_test "device_narrow_store_no_clobber" 'device Fake at 0x66666000 {
    Data   at 0x00 : u32
    Status at 0x04 : u8
    Other  at 0x08 : u32
}
fn main() {
    u64 nr = 9
    u64 aid = get_arch_id()
    if aid == 2 { nr = 222 }
    if aid == 4 { nr = 222 }
    if aid == 6 { nr = 222 }
    if aid == 7 { nr = 222 }
    syscall_raw(nr, 0x66666000, 4096, 3, 0x32, 0xFFFFFFFFFFFFFFFF, 0)
    Fake.Other = 99
    Fake.Status = 7
    exit(Fake.Other)
}' 99

# The store row cannot catch a load-side regression: a fresh mmap page is
# zero-filled, so an over-wide load still yields the right low byte. The
# neighbour must be dirtied first.
run_test "device_narrow_load_no_bleed" 'device Fake at 0x66666000 {
    Data   at 0x00 : u32
    Status at 0x04 : u8
    Other  at 0x08 : u32
}
fn main() {
    u64 nr = 9
    u64 aid = get_arch_id()
    if aid == 2 { nr = 222 }
    if aid == 4 { nr = 222 }
    if aid == 6 { nr = 222 }
    if aid == 7 { nr = 222 }
    syscall_raw(nr, 0x66666000, 4096, 3, 0x32, 0xFFFFFFFFFFFFFFFF, 0)
    store8(0x66666004, 7)
    store32(0x66666008, 0x11111111)
    u64 s = Fake.Status
    if s == 7 { exit(0) }
    exit(1)
}' 0

# Same defect reached through the vstore*/vload* builtins instead of a device
# block -- they emit the same two IR opcodes.
run_test "vstore_narrow_no_clobber" 'fn main() {
    u64 nr = 9
    u64 aid = get_arch_id()
    if aid == 2 { nr = 222 }
    if aid == 4 { nr = 222 }
    if aid == 6 { nr = 222 }
    if aid == 7 { nr = 222 }
    syscall_raw(nr, 0x66666000, 4096, 3, 0x32, 0xFFFFFFFFFFFFFFFF, 0)
    vstore32(0x66666008, 99)
    vstore8(0x66666004, 7)
    exit(vload32(0x66666008))
}' 99

# The runtime rows above catch the value corruption but not WHICH instruction
# produced it: swapping the acquire/release forms for a plain load/store plus a
# barrier would keep them green while dropping the ordering guarantee MMIO
# depends on. Pin the emitted words for all eight forms.
#
# Asserts the hex column, NOT a mnemonic -- main.kr has no STLR/LDAR decoder at
# any width, so these listing lines have a blank mnemonic column and a grep for
# "stlrb" would silently never fire.
#
# Five hex digits only: word = base | (Rn << 5) | Rt, so bits 11:8 are
# 0xC | ((Rn >> 3) & 3) and the 6th digit varies with the address register.
# Bits 31:12 are pure base bits and allocation-independent.
TOTAL=$((TOTAL + 1))
cat > /tmp/krc_venc_$$.kr <<'KREOF'
device D at 0x40000000 {
    B at 0x00 : u8
    H at 0x08 : u16
    W at 0x10 : u32
    X at 0x18 : u64
}
fn main() {
    D.B = 1
    D.H = 2
    D.W = 3
    D.X = 4
    u64 a = D.B
    u64 b = D.H
    u64 c = D.W
    u64 e = D.X
    exit(a + b + c + e)
}
KREOF
$KRC --arch=arm64 --emit=asm /tmp/krc_venc_$$.kr > /tmp/krc_venc_out_$$ 2>&1
VENC_LISTING=$(sed -n 's/.* -> \(.*\) (asm listing)$/\1/p' /tmp/krc_venc_out_$$)
VENC_OK=1
if [ -z "$VENC_LISTING" ] || [ ! -f "$VENC_LISTING" ]; then
    VENC_OK=0
    echo "  could not locate asm listing (got '$VENC_LISTING')"
else
    # Assert the SEQUENCE, not just presence. Presence alone would still pass
    # if two widths were permuted (u8 -> STLRH, u16 -> STLRB): all eight words
    # would still appear, and every runtime row above would stay green, because
    # a 2-byte store at 0x04 still never reaches the witness at 0x08. The
    # fixture writes B,H,W,X then reads B,H,W,X, and volatile ops are
    # side-effecting and non-hoistable, so this order is stable.
    VENC_SEQ=$(grep -oiE ': (089ff|489ff|889ff|c89ff|08dff|48dff|88dff|c8dff)' "$VENC_LISTING" \
        | sed 's/^: //' | tr 'A-F' 'a-f' | tr '\n' ' ')
    VENC_WANT="089ff 489ff 889ff c89ff 08dff 48dff 88dff c8dff "
    if [ "$VENC_SEQ" != "$VENC_WANT" ]; then
        VENC_OK=0
        echo "  volatile width sequence mismatch"
        echo "    want: $VENC_WANT"
        echo "    got:  $VENC_SEQ"
    fi
fi
if [ "$VENC_OK" = "1" ]; then
    echo "  arm64_narrow_volatile_encodings: PASS (STLR+LDAR B/H/W/X all emitted)"
    PASS=$((PASS + 1))
else
    echo "FAIL: arm64_narrow_volatile_encodings"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_venc_$$.kr /tmp/krc_venc_out_$$ "$VENC_LISTING"

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

# krc lc report: exact write() byte lengths (print_living_report and
# print_living_report_filtered in src/living.kr each hardcode the length of
# every literal they write instead of deriving it, and 14 of those
# constants across the two functions were wrong: 3 over-read past the
# string's own NUL (writing the NUL byte itself, which showed up as a
# stray NUL before "#lang stable" — the "    stable semantic core...\n"
# and "#lang ...\n\n" preambles) and 11 truncated their string, most of
# them report labels ("  Calls:       " etc. one byte short, and
# "\n\nFitness: " missing the trailing space so it read "Fitness:100/100").
# This row pins both failure modes at once on deterministic telemetry from
# a trivial one-function program: no stray NUL anywhere in the output, and
# every truncation-prone label present with its full, correctly-spaced text.
TOTAL=$((TOTAL + 1))
cat > /tmp/krc_lc_report_$$.kr <<'KREOF'
fn main() -> uint64 {
    return 0
}
KREOF
$KRC lc /tmp/krc_lc_report_$$.kr > /tmp/krc_lc_report_out_$$.txt 2>&1
lc_report_err=$(python3 -c "
data = open('/tmp/krc_lc_report_out_$$.txt', 'rb').read()
checks = [
    (b'\\x00' not in data, 'stray NUL byte in report output'),
    (b'    stable semantic core + adaptive surface layer\n' in data, 'core/surface preamble line wrong'),
    (b'(default \xe2\x80\x94 production-safe features only)\n\nTelemetry\n' in data, '#lang stable line wrong (over-read into Telemetry, or missing blank line)'),
    (b'  Functions:   1\n' in data, 'Functions label wrong'),
    (b'  Calls:       0\n' in data, 'Calls label truncated/misaligned'),
    (b'  Unsafe ops:  0\n' in data, 'Unsafe ops label truncated/misaligned'),
    (b'  Total ops:   1\n' in data, 'Total ops label truncated/misaligned'),
    (b'  Patterns:    0\n' in data, 'Patterns label truncated/misaligned'),
    (b'\n\nFitness: 100/100\n' in data, 'Fitness line truncated (missing space before value)'),
]
bad = [msg for ok, msg in checks if not ok]
if bad:
    print('; '.join(bad)); raise SystemExit(1)
" 2>&1)
if [ -z "$lc_report_err" ]; then
    PASS=$((PASS + 1)); echo "  lc_report_bytes_exact: PASS"
else
    FAIL=$((FAIL + 1)); echo "FAIL: lc_report_bytes_exact ($lc_report_err)"
fi
rm -f /tmp/krc_lc_report_$$.kr /tmp/krc_lc_report_out_$$.txt

# analysis.kr: same class of wrong write() byte length as the lc report
# fix above, in the kernel-safety-check diagnostics (`krc check`).
# check_critical_regions is the one of the four that is actually reachable
# right now: it pattern-matches acquire()/release()/alloc() call names
# directly in the AST, no annotation parsing required. `krc check` on a
# bare alloc() between acquire()/release() (a bare expression statement --
# check_critical_stmt only inspects ExprStmt kind, not a `let`
# initializer) fires it. The pre-fix length (48) read one byte past the
# string's own trailing \n into whatever followed it in .rodata, which
# showed up as a stray NUL byte between the diagnostic and krc's next line
# of output.
TOTAL=$((TOTAL + 1))
cat > /tmp/krc_critregion_$$.kr <<'KREOF'
fn acquire(uint64 l) { }
fn release(uint64 l) { }
fn main() {
    acquire(1)
    alloc(8)
    release(1)
    exit(0)
}
KREOF
$KRC check /tmp/krc_critregion_$$.kr > /tmp/krc_critregion_out_$$.txt 2>&1
critregion_err=$(python3 -c "
data = open('/tmp/krc_critregion_out_$$.txt', 'rb').read()
checks = [
    (b'\\x00' not in data, 'stray NUL byte in check output'),
    (b'critical-region: alloc inside critical section\n' in data, 'critical-region message missing or malformed'),
]
bad = [msg for ok, msg in checks if not ok]
if bad:
    print('; '.join(bad)); raise SystemExit(1)
" 2>&1)
if [ -z "$critregion_err" ]; then
    PASS=$((PASS + 1)); echo "  analysis_critical_region_bytes_exact: PASS"
else
    FAIL=$((FAIL + 1)); echo "FAIL: analysis_critical_region_bytes_exact ($critregion_err)"
fi
rm -f /tmp/krc_critregion_$$.kr /tmp/krc_critregion_out_$$.txt

# The other three analysis.kr write() length fixes (ctx-check :165,
# eff-check :205, lock-cycle :327) cannot be exercised the same way: their
# callers require populated annotation/lock-graph tables, and
# src/main.kr's own comment at the `run_analysis` call site says why those
# tables are permanently empty -- "annotations are not parsed yet, so
# ann_register and lock_add_edge have no callers" (grep confirms zero call
# sites for either, anywhere in src/*.kr). So there is no `.kr` program
# that can reach those three write() calls today; asserting "red before,
# green after, executed" for them would be fabricated. Pin the byte
# lengths statically instead -- read the three literals straight out of
# analysis.kr and assert each write() call's length argument equals the
# string's real encoded length, so a future length regression is still
# caught the moment it's introduced, before the day these become reachable.
TOTAL=$((TOTAL + 1))
analysis_static_err=$(python3 -c "
import re
src = open('$DIR/../src/analysis.kr', 'rb').read().decode('utf-8')
# (search text, expected write() length constant). The source shape is
# always \`uint64 msg = \"<lit>\"\` followed, a line or two later, by
# \`write(2, msg, N)\` -- not an inline write(2, \"...\", N), so the literal
# and its length live on different lines.
pairs = [
    ('ctx-check: context violation in ', 32),
    ('eff-check: undeclared effect in ', 32),
    ('lock-cycle: potential deadlock between locks\n', 45),
]
bad = []
for lit, want_len in pairs:
    real_len = len(lit.encode('utf-8'))
    if real_len != want_len:
        bad.append(f'{lit!r}: encodes to {real_len} bytes, test expected {want_len}')
        continue
    escaped = lit.replace(chr(10), '\\\\n')
    pat = 'uint64 msg = ' + re.escape('\"' + escaped + '\"')
    m = re.search(pat, src)
    if not m:
        bad.append(f'{lit!r}: literal not found in analysis.kr')
        continue
    tail = src[m.end():m.end() + 200]
    wm = re.search(r'write\(2,\s*msg,\s*(\d+)\)', tail)
    if not wm:
        bad.append(f'{lit!r}: no write(2, msg, N) within 200 chars after the literal')
        continue
    got = int(wm.group(1))
    if got != want_len:
        bad.append(f'{lit!r}: write() uses {got}, should be {want_len}')
if bad:
    print('; '.join(bad)); raise SystemExit(1)
" 2>&1)
if [ -z "$analysis_static_err" ]; then
    PASS=$((PASS + 1)); echo "  analysis_unreachable_write_lengths_pinned: PASS"
else
    FAIL=$((FAIL + 1)); echo "FAIL: analysis_unreachable_write_lengths_pinned ($analysis_static_err)"
fi

# --- std/idt.kr: interrupt descriptor table and fault reporting ---
#
# The failure this module exists to end is also the one its tests have to
# survive: a wrong gate field triple-faults, and under QEMU a triple fault is
# indistinguishable from a clean reboot. So every assertion below is on the
# INNER message the handler printed -- never an exit code, never "the guest
# stopped". Each was observed red by breaking one field at a time: an IDTR
# limit of 47, a gate with the present bit clear, a gate missing offset bits
# 31:16, and a rel32 measured 8 bytes short all killed the guest silently;
# vector 14 built as a no-error-code stub still printed `EXCEPTION 14 (#PF)`
# but with `err=0x0 rip=0x2`, which is why the RIP is range-checked and not
# merely required to be non-zero.
#
# Boot-and-wait instead of a fixed timeout: the report appears in well under a
# second, and a guest that runs off into garbage can wedge QEMU hard enough to
# ignore SIGTERM (measured -- a `timeout 5` left one spinning for five
# minutes). SIGKILL on a PID this shell owns cannot be ignored.
idt_boot_wait() {   # <-kernel|-bios> <image> <log> <marker>
    rm -f "$3"
    qemu-system-x86_64 "$1" "$2" -m 256 -serial "file:$3" \
        -display none -no-reboot >/dev/null 2>&1 &
    local qpid=$!
    local i=0
    while [ $i -lt 60 ]; do
        if grep -q "$4" "$3" 2>/dev/null; then break; fi
        sleep 0.25
        i=$((i + 1))
    done
    kill -9 $qpid >/dev/null 2>&1
    wait $qpid 2>/dev/null
}

# Whole surface must compile freestanding, including what the fault rows below
# never call. Compile-only, so the arch is pinned: std/idt.kr is x86_64 by
# construction. The `serial_putsn("BAD...")` branches are not assertions -- this
# image is never booted -- they exist so dead-code elimination cannot drop the
# calls before their asm is emitted, which is the only way a compile row can
# cover a function at all.
TOTAL=$((TOTAL + 1))
cat > "$DIR/../idtsurf_tmp_$$.kr" <<'IDTSEOF'
import "std/idt.kr"
@naked
fn my_isr() { asm { "iretq" } }
fn main() -> uint32 {
    serial_init()
    idt_init()
    idt_install_default_handlers()
    idt_set_handler(32, fn_addr("my_isr"))
    idt_set_gate(33, fn_addr("my_isr"), idt_get_cs(), 0, IDT_TYPE_TRAP)
    idt_clear_handler(33)
    idt_load()
    if idt_limit() != 4095 { serial_putsn("BADLIMIT") }
    if idt_base() != idt_table_addr() { serial_putsn("BADBASE") }
    if idt_stub_addr(1) - idt_stub_addr(0) != IDT_GATE_SIZE { serial_putsn("BADSTUB") }
    if idt_vector_has_error_code(14) == 0 { serial_putsn("BADERRVEC") }
    if idt_vector_has_error_code(15) != 0 { serial_putsn("BADERRVEC") }
    if idt_mnemonic(0) == 0 { serial_putsn("BADMNEM") }
    if idt_read_cs() == 0 { serial_putsn("BADCS") }
    halt_forever()
    return 0
}
IDTSEOF
if $KRC --target=none --arch=x86_64 --emit=image --load-addr=0x100000 \
        --stack-top=0x90000 "$DIR/../idtsurf_tmp_$$.kr" -o /tmp/idtsurf_$$.img >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  idt_full_surface_freestanding: PASS"
else
    FAIL=$((FAIL + 1)); echo "FAIL: idt_full_surface_freestanding"
    $KRC --target=none --arch=x86_64 --emit=image --load-addr=0x100000 \
         --stack-top=0x90000 "$DIR/../idtsurf_tmp_$$.kr" -o /tmp/idtsurf_$$.img 2>&1 \
         | grep error | head -3 | sed 's/^/    /'
fi
rm -f "$DIR/../idtsurf_tmp_$$.kr" /tmp/idtsurf_$$.img

# The two fields most likely to be silently wrong, read back out of the LIVE
# IDTR with SIDT -- not out of the pseudo-descriptor the module just wrote,
# which would only prove it can echo its own bytes. The base must be this
# module's table, which is what says `lidt` took effect at all.
#
#   * The IDTR limit is size MINUS ONE. 4096 is not caught by anything -- the
#     CPU only checks that the accessed gate fits -- so it is pinned here
#     rather than left to a fault row that cannot see it.
#   * The code selector differs BETWEEN IMAGE FORMS: 0x8 under multiboot,
#     0x18 from the reset vector. Hardcoding 0x8 gives a module that works
#     under -kernel and silently triple-faults under -bios (measured), which
#     is exactly why both forms are booted here and below.
TOTAL=$((TOTAL + 1))
IDTCS_K="/tmp/idtcs_k_$$.img"; IDTCS_B="/tmp/idtcs_b_$$.img"
cat > "$DIR/../idtcs_tmp_$$.kr" <<'IDTCEOF'
import "std/idt.kr"
static u8[32] idtcs_buf
fn main() -> uint32 {
    serial_init()
    idt_init()
    idt_load()
    u64 b = idtcs_buf
    serial_puts("IDTCS=")
    cstr_u64_hex0x(b, 32, idt_get_cs(), 0)
    serial_puts(b)
    serial_puts(" IDTLIMIT=")
    cstr_u64_dec(b, 32, idt_limit())
    serial_puts(b)
    serial_puts(" IDTBASE=")
    if idt_base() == idt_table_addr() { serial_puts("ours") }
    if idt_base() != idt_table_addr() { serial_puts("WRONG") }
    serial_putc(10)
    halt_forever()
    return 0
}
IDTCEOF
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  idt_selector_and_limit: PASS (SKIPPED -- no qemu-system-x86_64)"
elif ! $KRC --target=none --arch=x86_64 --emit=image --load-addr=0x100000 \
            --stack-top=0x90000 "$DIR/../idtcs_tmp_$$.kr" -o "$IDTCS_K" >/dev/null 2>&1 \
  || ! $KRC --target=none --arch=x86_64 --emit=image --reset-vector \
            --stack-top=0x90000 "$DIR/../idtcs_tmp_$$.kr" -o "$IDTCS_B" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1)); echo "FAIL: idt_selector_and_limit (compile failed)"
else
    idt_boot_wait -kernel "$IDTCS_K" "/tmp/idtcs_k_$$.log" "IDTLIMIT="
    idt_boot_wait -bios   "$IDTCS_B" "/tmp/idtcs_b_$$.log" "IDTLIMIT="
    idtcs_ok=1
    grep -q "IDTCS=0x8 IDTLIMIT=4095 IDTBASE=ours" "/tmp/idtcs_k_$$.log" 2>/dev/null || idtcs_ok=0
    grep -q "IDTCS=0x18 IDTLIMIT=4095 IDTBASE=ours" "/tmp/idtcs_b_$$.log" 2>/dev/null || idtcs_ok=0
    if [ "$idtcs_ok" = "1" ]; then
        PASS=$((PASS + 1)); echo "  idt_selector_and_limit: PASS (live IDTR: CS 0x8/-kernel 0x18/-bios, limit 4095, base ours)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: idt_selector_and_limit"
        echo "    -kernel: $(cat /tmp/idtcs_k_$$.log 2>/dev/null | tr -d '\r' | tail -1)"
        echo "    -bios:   $(cat /tmp/idtcs_b_$$.log 2>/dev/null | tr -d '\r' | tail -1)"
    fi
fi
rm -f "$DIR/../idtcs_tmp_$$.kr" "$IDTCS_K" "$IDTCS_B" "/tmp/idtcs_k_$$.log" "/tmp/idtcs_b_$$.log"

# Four real faults, in both image forms, each asserted on vector, mnemonic,
# error code AND a RIP inside the loaded payload.
#
# The error codes are not decoration: #PF here is a WRITE to an unmapped page,
# so the CPU pushes 0x2 and a build that misread the frame cannot produce it by
# accident. #DE and #BP push nothing, and the stub's `push 0` is what makes
# their frames the same shape -- get that list wrong and the RIP check fires.
#
# #BP is a trap, so its reported RIP is the instruction AFTER the int3;
# #DE/#GP/#PF are faults and report the faulting instruction itself. Both were
# confirmed against objdump of the image (int3 at 0x10134c -> rip 0x10134d).
TOTAL=$((TOTAL + 1))
cat > "$DIR/../idtflt_in_$$.kr" <<'IDTFEOF'
import "std/idt.kr"
static u64 idtflt_sink = 0
fn main() -> uint32 {
    serial_init()
    idt_init()
    idt_install_default_handlers()
    idt_load()
    u64 sel = __SEL__
    if sel == 0 {
        u64 z = idtflt_sink
        idtflt_sink = 7 / z
    }
    if sel == 3 {
        asm { "0xCC" }
    }
    if sel == 13 {
        u64 bad = 0x0000800000000000
        idtflt_sink = load64(bad)
    }
    if sel == 14 {
        u64 bad = 0x0000700000000000
        store64(bad, 1)
    }
    serial_putsn("NOFAULT")
    halt_forever()
    return 0
}
IDTFEOF
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  idt_reports_four_faults: PASS (SKIPPED -- no qemu-system-x86_64)"
else
    idtf_ok=1
    idtf_notes=""
    for idtf_case in "0 #DE 0x0" "3 #BP 0x0" "13 #GP 0x0" "14 #PF 0x2"; do
        idtf_vec="${idtf_case%% *}"
        idtf_rest="${idtf_case#* }"
        idtf_mn="${idtf_rest%% *}"
        idtf_err="${idtf_rest#* }"
        sed "s/__SEL__/$idtf_vec/" "$DIR/../idtflt_in_$$.kr" > "$DIR/../idtflt_tmp_$$.kr"
        idtf_k="/tmp/idtflt_k_$$.img"; idtf_b="/tmp/idtflt_b_$$.img"
        if ! $KRC --target=none --arch=x86_64 --emit=image --load-addr=0x100000 \
                  --stack-top=0x90000 "$DIR/../idtflt_tmp_$$.kr" -o "$idtf_k" >/dev/null 2>&1 \
        || ! $KRC --target=none --arch=x86_64 --emit=image --reset-vector \
                  --stack-top=0x90000 "$DIR/../idtflt_tmp_$$.kr" -o "$idtf_b" >/dev/null 2>&1; then
            idtf_ok=0; idtf_notes="$idtf_notes vec$idtf_vec:compile"
            continue
        fi
        # RIP must land inside the payload: [0x100000, 0x100000 + image size).
        # Derived from the artifact rather than hardcoded, so the bound stays
        # tight as the test program changes. It rejects every wrong-field RIP
        # measured while breaking this on purpose -- 0x0, 0x2 and 0x8.
        idtf_hi=$((1048576 + $(wc -c < "$idtf_k")))
        for idtf_form in kernel bios; do
            if [ "$idtf_form" = "kernel" ]; then
                idt_boot_wait -kernel "$idtf_k" "/tmp/idtflt_$$.log" "EXCEPTION"
            else
                idt_boot_wait -bios "$idtf_b" "/tmp/idtflt_$$.log" "EXCEPTION"
            fi
            # Not anchored at start-of-line: the reset-vector boot path prints
            # its own "RPL" progress marker with no trailing newline, so under
            # -bios the guest's first line reads "RPLEXCEPTION 3 (#BP) ...".
            # An anchored match reported all four -bios cases as silent triple
            # faults while the guest was in fact reporting them correctly.
            idtf_line=$(tr -d '\r' < "/tmp/idtflt_$$.log" 2>/dev/null | grep -o 'EXCEPTION .*' | head -1)
            idtf_want="EXCEPTION $idtf_vec ($idtf_mn) err=$idtf_err rip=0x"
            case "$idtf_line" in
                "$idtf_want"*) ;;
                *) idtf_ok=0; idtf_notes="$idtf_notes [$idtf_form v$idtf_vec: '${idtf_line:-<silent: triple fault?>}']"; continue ;;
            esac
            idtf_rip=$(printf '%s' "$idtf_line" | sed -n 's/.* rip=\(0x[0-9a-f]*\).*/\1/p')
            idtf_ripd=$((idtf_rip))
            if [ "$idtf_ripd" -lt 1048576 ] || [ "$idtf_ripd" -ge "$idtf_hi" ]; then
                idtf_ok=0; idtf_notes="$idtf_notes [$idtf_form v$idtf_vec: rip $idtf_rip outside payload]"
            fi
        done
        rm -f "$idtf_k" "$idtf_b"
    done
    if [ "$idtf_ok" = "1" ]; then
        PASS=$((PASS + 1)); echo "  idt_reports_four_faults: PASS (#DE #BP #GP #PF, vector+err+rip, -kernel and -bios)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: idt_reports_four_faults:$idtf_notes"
    fi
fi
rm -f "$DIR/../idtflt_in_$$.kr" "$DIR/../idtflt_tmp_$$.kr" "/tmp/idtflt_$$.log"

# --- std/gzip.kr: output must satisfy a REAL gunzip, not our own reader ---
#
# A self-written decoder would agree with a self-written encoder about a shared
# misreading of RFC 1951, so this shells out to the system gunzip and to
# `gzip -t`, which verifies the CRC-32 and ISIZE trailer rather than merely
# decoding the stream.
#
# The sizes are chosen at the stored-block boundary, which is where the
# framing actually gets exercised: 65535 is exactly one block, 65536 is two
# (the first non-final), and 0 is the empty-input path that still has to emit
# one final empty block. A test on a short string alone would never run the
# multi-block loop at all.
TOTAL=$((TOTAL + 1))
if ! command -v gunzip >/dev/null 2>&1 || ! command -v gzip >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  gzip_stored_roundtrips: PASS (SKIPPED -- no gzip/gunzip)"
elif ! $KRC --arch=$RUN_ARCH "$DIR/../examples/gzip_stored.kr" -o /tmp/krgz_$$ >/dev/null 2>&1; then
    FAIL=$((FAIL + 1)); echo "FAIL: gzip_stored_roundtrips (compile failed)"
else
    chmod +x /tmp/krgz_$$
    gz_ok=1
    gz_note=""
    for gz_n in 0 1 65535 65536 131070; do
        head -c $gz_n /dev/urandom > /tmp/krgz_in_$$ 2>/dev/null
        if ! /tmp/krgz_$$ < /tmp/krgz_in_$$ > /tmp/krgz_out_$$.gz 2>/dev/null; then
            gz_ok=0; gz_note="encoder failed at $gz_n"; break
        fi
        if ! gunzip -c /tmp/krgz_out_$$.gz > /tmp/krgz_back_$$ 2>/dev/null; then
            gz_ok=0; gz_note="gunzip rejected $gz_n"; break
        fi
        if ! cmp -s /tmp/krgz_in_$$ /tmp/krgz_back_$$; then
            gz_ok=0; gz_note="round-trip differs at $gz_n"; break
        fi
        # gzip -t re-checks CRC-32 and ISIZE, which a plain decode does not.
        if ! gzip -t /tmp/krgz_out_$$.gz >/dev/null 2>&1; then
            gz_ok=0; gz_note="gzip -t rejected $gz_n (CRC or ISIZE wrong)"; break
        fi
    done
    if [ "$gz_ok" = "1" ]; then
        PASS=$((PASS + 1)); echo "  gzip_stored_roundtrips: PASS (0/1/65535/65536/131070 B via system gunzip + gzip -t)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: gzip_stored_roundtrips ($gz_note)"
    fi
    rm -f /tmp/krgz_$$ /tmp/krgz_in_$$ /tmp/krgz_out_$$.gz /tmp/krgz_back_$$
fi

# --- lc --fix writes a backup; lc undo restores it ---
#
# `--fix` rewrites IN PLACE and nothing verifies the rewrite preserved meaning.
# Two failure modes are reachable TODAY: the byte scanner rewrites inside
# comments and string literals (measured on a copy of this compiler's own
# lexer: 141 sites, and the keyword table became `match_keyword(start, len,
# "u8", 5)` -- string shortened, length constant left at 5), and the store
# rewrite changes argument evaluation order on the legacy backend.
#
# Backup+undo covers the FIRST (corruption is loud). It does not cover the
# second, which compiles fine -- that is what the verification harness is for.
TOTAL=$((TOTAL + 1))
lcb_dir="$DIR/../lcbak_tmp_$$"
mkdir -p "$lcb_dir"
cat > "$lcb_dir/t.kr" <<'LCBEOF'
fn main() {
    uint64 buf = alloc(16)
    uint64 v = 0
    store32(buf, 42)
    unsafe { *(buf as uint32) -> v }
    exit(v)
}
LCBEOF
cp "$lcb_dir/t.kr" "$lcb_dir/orig.kr"
lcb_ok=1
lcb_why=""
"$DIR/../build/krc2" lc --fix "$lcb_dir/t.kr" >/dev/null 2>&1
# A rewrite must actually have happened, or every clause below is vacuous.
grep -q 'v = load32(buf)' "$lcb_dir/t.kr" || { lcb_ok=0; lcb_why="no rewrite happened (positive control)"; }
[ -f "$lcb_dir/t.kr.lcbak" ] || { lcb_ok=0; lcb_why="no backup written"; }
cmp -s "$lcb_dir/t.kr.lcbak" "$lcb_dir/orig.kr" || { lcb_ok=0; lcb_why="backup is not the original bytes"; }
"$DIR/../build/krc2" lc undo "$lcb_dir/t.kr" >/dev/null 2>&1
cmp -s "$lcb_dir/t.kr" "$lcb_dir/orig.kr" || { lcb_ok=0; lcb_why="undo did not restore the original"; }
# --dry-run must neither write a backup nor touch the file.
cp "$lcb_dir/orig.kr" "$lcb_dir/dry.kr"
"$DIR/../build/krc2" lc --fix --dry-run "$lcb_dir/dry.kr" >/dev/null 2>&1
[ -f "$lcb_dir/dry.kr.lcbak" ] && { lcb_ok=0; lcb_why="--dry-run wrote a backup"; }
cmp -s "$lcb_dir/dry.kr" "$lcb_dir/orig.kr" || { lcb_ok=0; lcb_why="--dry-run modified the file"; }
# undo with no backup must FAIL loudly rather than silently doing nothing.
"$DIR/../build/krc2" lc undo "$lcb_dir/dry.kr" >/dev/null 2>&1
[ "$?" != "0" ] || { lcb_ok=0; lcb_why="undo with no backup exited 0"; }
if [ "$lcb_ok" = "1" ]; then
    PASS=$((PASS + 1)); echo "  lc_fix_backup_and_undo: PASS (backup==original, undo restores, dry-run inert, missing backup errors)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: lc_fix_backup_and_undo ($lcb_why)"
fi
rm -rf "$lcb_dir"

# The scenario the seatbelt exists for: --fix on a REAL source file corrupts it
# (comments, string literals, and a keyword table whose length constant no
# longer matches its shortened string), and undo gets it back byte-identically.
# A toy input would not exercise the alias-rewrite arm at all -- the two
# pre-existing --fix rows are written entirely in short forms, which is why
# this corruption went unnoticed.
TOTAL=$((TOTAL + 1))
lcx_dir="$DIR/../lcbak2_tmp_$$"
mkdir -p "$lcx_dir"
cp "$DIR/../src/lexer.kr" "$lcx_dir/lex.kr"
lcx_ok=1
lcx_why=""
lcx_sites=$("$DIR/../build/krc2" lc --fix "$lcx_dir/lex.kr" 2>&1 | sed -n 's/^migration: \([0-9]*\) migration site.*/\1/p')
[ -n "$lcx_sites" ] && [ "$lcx_sites" -gt 50 ] || { lcx_ok=0; lcx_why="expected a large rewrite on a real file, got '${lcx_sites:-none}'"; }
cmp -s "$lcx_dir/lex.kr" "$DIR/../src/lexer.kr" && { lcx_ok=0; lcx_why="the file was NOT modified, so undo proves nothing"; }
"$DIR/../build/krc2" lc undo "$lcx_dir/lex.kr" >/dev/null 2>&1
cmp -s "$lcx_dir/lex.kr" "$DIR/../src/lexer.kr" || { lcx_ok=0; lcx_why="undo did not recover the corrupted file"; }
if [ "$lcx_ok" = "1" ]; then
    PASS=$((PASS + 1)); echo "  lc_undo_recovers_a_corrupted_source: PASS ($lcx_sites sites rewritten, fully recovered)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: lc_undo_recovers_a_corrupted_source ($lcx_why)"
fi
rm -rf "$lcx_dir"

# --- A1: the fat-binary line names the runner ---
#
# Bare `krc` emits a fat binary BY DEFAULT and the shell cannot execute one, so
# without this the default first experience is a file that does not run with
# nothing saying what does.
#
# MUST use build/krc2 bare: `make test` sets KRC='./build/krc2 --arch=x86_64',
# which emits a single ELF and no fat line at all, so $KRC could never pass.
TOTAL=$((TOTAL + 1))
printf 'fn main(){ exit(0) }\n' > "$DIR/../a1_tmp_$$.kr"
a1_out=$("$DIR/../build/krc2" "$DIR/../a1_tmp_$$.kr" -o /tmp/a1_$$.krbo 2>&1)
a1_ok=1
a1_why=""
printf '%s' "$a1_out" | grep -q 'run it with: kr' || { a1_ok=0; a1_why="no runner hint"; }
# The hint is APPENDED, so the pre-existing fields must survive verbatim --
# a reformat that dropped the slice enumeration would still name the runner.
printf '%s' "$a1_out" | grep -q 'x86_64(' || { a1_ok=0; a1_why="slice enumeration lost"; }
printf '%s' "$a1_out" | grep -q 'android-x64(' || { a1_ok=0; a1_why="slice list truncated"; }
# The hint must name the actual output path, not a fixed string.
printf '%s' "$a1_out" | grep -q "run it with: kr /tmp/a1_$$.krbo" || { a1_ok=0; a1_why="hint does not name the output path"; }
if [ "$a1_ok" = "1" ]; then
    PASS=$((PASS + 1)); echo "  fat_binary_runner_hint: PASS (names kr and the path; slice fields intact)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: fat_binary_runner_hint ($a1_why)"
fi
rm -f "$DIR/../a1_tmp_$$.kr" /tmp/a1_$$.krbo

# The custom --targets subset may EXCLUDE the host, and then `kr` fails with
# "no native binary found for this architecture" -- so the hint must appear
# only when the host slice is present. Both directions are asserted: a hint
# that was simply deleted would satisfy the negative clause on its own.
TOTAL=$((TOTAL + 1))
printf 'fn main(){ exit(0) }\n' > "$DIR/../a1c_tmp_$$.kr"
# Name the host slice by $RUN_ARCH so this does not silently invert on arm64.
if [ "$RUN_ARCH" = "arm64" ]; then a1_host=linux-arm64; a1_away=linux-x64
else a1_host=linux-x64; a1_away=linux-arm64; fi
a1c_with=$("$DIR/../build/krc2" --targets=$a1_host,win-x64 "$DIR/../a1c_tmp_$$.kr" -o /tmp/a1cw_$$.krbo 2>&1)
a1c_without=$("$DIR/../build/krc2" --targets=$a1_away,win-x64 "$DIR/../a1c_tmp_$$.kr" -o /tmp/a1cn_$$.krbo 2>&1)
a1c_ok=1
a1c_why=""
printf '%s' "$a1c_with" | grep -q 'run it with: kr' || { a1c_ok=0; a1c_why="no hint when the host slice IS present"; }
printf '%s' "$a1c_without" | grep -q 'run it with: kr' && { a1c_ok=0; a1c_why="hint present when the host slice is ABSENT (kr would fail)"; }
# Neither spelling may warn about an unrecognised target name -- a typo here
# would make the negative clause pass for the wrong reason.
printf '%s' "$a1c_with$a1c_without" | grep -q 'unknown --targets name' && { a1c_ok=0; a1c_why="a --targets name was not recognised"; }
if [ "$a1c_ok" = "1" ]; then
    PASS=$((PASS + 1)); echo "  fat_binary_hint_conditional: PASS (hint iff the host slice is in the subset)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: fat_binary_hint_conditional ($a1c_why)"
fi
rm -f "$DIR/../a1c_tmp_$$.kr" /tmp/a1cw_$$.krbo /tmp/a1cn_$$.krbo

# --- A2: a failed import reports what was actually tried ---
#
# It named ONE path having tried eleven. Measured with strace: 11 distinct
# candidates, 12 opens, of which a whole degenerate second batch looks like
# `/usr/share/kernrift//tmp/std/x.kr` because import_process re-resolves an
# already-absolute path. Only the real batch is reported, deliberately.
#
# The exact set is NOT asserted: Linux has 5 search paths, macOS 4 (its $HOME
# entry is silently absent because import_read_home reads /proc/self/environ)
# and Windows 2.
TOTAL=$((TOTAL + 1))
printf 'import "std/definitely_no_such_module.kr"\nfn main(){ exit(0) }\n' > "$DIR/../a2_tmp_$$.kr"
a2_out=$($KRC "$DIR/../a2_tmp_$$.kr" -o /dev/null 2>&1)
a2_cands=$(printf '%s' "$a2_out" | grep -c 'definitely_no_such_module')
a2_ok=1
a2_why=""
printf '%s' "$a2_out" | grep -q '  tried:' || { a2_ok=0; a2_why="no candidate list"; }
# More than one candidate: the whole point. The old message named exactly one.
[ "$a2_cands" -ge 3 ] || { a2_ok=0; a2_why="only $a2_cands lines mention the module; want the error plus >=2 candidates"; }
# At least one real system path, so the list is not just the relative attempt.
printf '%s' "$a2_out" | grep -q 'share/kernrift/std/definitely_no_such_module' || { a2_ok=0; a2_why="no system search path listed"; }
# The relative-to-importer route must be present AND labelled -- it is the one
# the old message printed, and it is not in the search table at all.
printf '%s' "$a2_out" | grep -q 'relative to the importing file' || { a2_ok=0; a2_why="relative-to-importer attempt not labelled"; }
# The degenerate second batch must NOT appear. Those paths splice an absolute
# path onto a prefix, so they contain the module name twice over a doubled
# separator or an embedded absolute segment.
printf '%s' "$a2_out" | grep -qE 'kernrift//|kernrift/[a-z/]*/(tmp|home)/' && { a2_ok=0; a2_why="degenerate second batch leaked into the report"; }
if [ "$a2_ok" = "1" ]; then
    PASS=$((PASS + 1)); echo "  import_failure_lists_candidates: PASS ($a2_cands lines, system paths listed, no degenerate batch)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: import_failure_lists_candidates ($a2_why)"
    printf '%s\n' "$a2_out" | sed 's/^/    /' | head -10
fi
rm -f "$DIR/../a2_tmp_$$.kr"

# The candidate list must RESET between imports rather than accumulating. Two
# failing imports in one file: each report must name only its own module.
#
# This replaced a row asserting that a missing TOP-LEVEL input grows no
# candidate list. That row could never fail: every import_process(input_path)
# call site is preceded by import_check_file(input_path), which exits(1) first,
# so the guarded code is unreachable from there. The guard stays as defence for
# a future call site, but it is NOT claimed to be tested.
TOTAL=$((TOTAL + 1))
printf 'import "std/alphamissing.kr"\nimport "std/betamissing.kr"\nfn main(){ exit(0) }\n' > "$DIR/../a2r_tmp_$$.kr"
a2r_out=$($KRC "$DIR/../a2r_tmp_$$.kr" -o /dev/null 2>&1)
a2r_alpha=$(printf '%s' "$a2r_out" | grep -c 'alphamissing')
a2r_beta=$(printf '%s' "$a2r_out" | grep -c 'betamissing')
# One error line + N candidates each. Without the reset the SECOND report also
# replays the first module's candidates, roughly doubling alpha's count.
if [ "$a2r_alpha" -ge 2 ] && [ "$a2r_beta" -ge 2 ] && [ "$a2r_alpha" = "$a2r_beta" ]; then
    PASS=$((PASS + 1)); echo "  import_candidates_reset_between_imports: PASS (alpha=$a2r_alpha beta=$a2r_beta, no carry-over)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: import_candidates_reset_between_imports (alpha=$a2r_alpha beta=$a2r_beta; equal and >=2 expected)"
fi
rm -f "$DIR/../a2r_tmp_$$.kr"

# --- A3: warn when an expression groups differently than it would in C ---
#
# KernRift binds & | ^ TIGHTER than + and <<, and puts all three on ONE level
# where C gives them three. So `a + b & c` is `a + (b & c)` here and
# `(a + b) & c` in C -- silently, with different results.
#
# Compile-only rows, so the arch may be pinned.
#
# TEN fire cases, one per divergent class-pair -- not a sample. The pairs were
# derived from binop_precedence vs C's ranking; a warning that caught only the
# two obvious ones would look correct while missing the all-bitwise cases
# (rows 8-10), which exist solely because KernRift collapses & ^ | to one level.
a3_fire() {
    printf 'fn main(){ u64 a=1 u64 b=2 u64 c=4 u64 d=3 u64 r = %s  exit(r) }\n' "$2" > "$DIR/../a3_tmp_$$.kr"
    a3_n=$($KRC "$DIR/../a3_tmp_$$.kr" -o /dev/null 2>&1 | grep -c 'groups differently')
    if [ "$a3_n" -ge 1 ]; then a3_pass=$((a3_pass + 1)); else
        a3_bad="$a3_bad $1"; fi
}
a3_silent() {
    printf 'fn main(){ u64 a=1 u64 b=2 u64 c=4 u64 d=3 u64 r = %s  exit(r) }\n' "$2" > "$DIR/../a3_tmp_$$.kr"
    a3_n=$($KRC "$DIR/../a3_tmp_$$.kr" -o /dev/null 2>&1 | grep -c 'groups differently')
    if [ "$a3_n" = "0" ]; then a3_pass=$((a3_pass + 1)); else
        a3_bad="$a3_bad $1"; fi
}
TOTAL=$((TOTAL + 1))
a3_pass=0
a3_bad=""
a3_fire  bitand_plus      'a + b & c'
a3_fire  bitor_shift      'a << b | c'
a3_fire  shift_plus       'a + b << c'
a3_fire  shift_mul        'c / b << a'
a3_fire  bitand_mul       'd * b & c'
a3_fire  bitand_rel       'b < a | c'
a3_fire  bitand_eq        'a == b & c'
a3_fire  xor_and          'a ^ b & c'
a3_fire  or_and           'a | b & c'
a3_fire  or_xor           'c | b ^ c'
if [ "$a3_pass" = "10" ]; then
    PASS=$((PASS + 1)); echo "  c_divergence_warns_all_ten_pairs: PASS"
else
    FAIL=$((FAIL + 1)); echo "FAIL: c_divergence_warns_all_ten_pairs ($a3_pass/10; missed:$a3_bad)"
fi

# Silence matters more than firing: a warning that fires on correct code gets
# switched off, and then the real ones are invisible too. Compound assignment
# and for-increments are included because the parser DESUGARS them into exactly
# the shape this warns about, with no mixed expression written by anyone.
TOTAL=$((TOTAL + 1))
a3_pass=0
a3_bad=""
a3_silent paren_right     'a + (b & c)'
a3_silent paren_left      '(a + b) & c'
a3_silent same_op_plus    'a + b + c'
a3_silent same_op_and     'a & b & c'
a3_silent mul_plus        'a * b + c'
a3_silent plus_mul        'a + b * c'
a3_silent logical         'a < b && c > a'
a3_silent paren_or_xor    '(a | b) ^ c'
a3_silent minus_plus      'a - b + c'
a3_silent shift_shift     'a >> b >> c'
a3_n=0
printf 'fn main(){ u64 x=7 u64 a=1 u64 b=2\n x &= a + b\n exit(x) }\n' > "$DIR/../a3_tmp_$$.kr"
a3_n=$($KRC "$DIR/../a3_tmp_$$.kr" -o /dev/null 2>&1 | grep -c 'groups differently')
[ "$a3_n" = "0" ] && a3_pass=$((a3_pass + 1)) || a3_bad="$a3_bad compound_assign"
printf 'fn main(){ u64 s=0\n for i in 0..4 { s = s + i }\n exit(s) }\n' > "$DIR/../a3_tmp_$$.kr"
a3_n=$($KRC "$DIR/../a3_tmp_$$.kr" -o /dev/null 2>&1 | grep -c 'groups differently')
[ "$a3_n" = "0" ] && a3_pass=$((a3_pass + 1)) || a3_bad="$a3_bad for_increment"
if [ "$a3_pass" = "12" ]; then
    PASS=$((PASS + 1)); echo "  c_divergence_silent_on_correct_code: PASS (12 shapes incl. desugared)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: c_divergence_silent_on_correct_code ($a3_pass/12; fired on:$a3_bad)"
fi

# A POSITIVE CONTROL for the silence row. Without this, deleting the whole
# warning would leave the silence row passing 12/12 -- the fire row above is
# what catches that, and this makes the pairing explicit rather than implied.
TOTAL=$((TOTAL + 1))
printf 'fn main(){ u64 a=1 u64 b=2 u64 c=4 u64 r = a + b & c  exit(r) }\n' > "$DIR/../a3_tmp_$$.kr"
a3_ctl=$($KRC "$DIR/../a3_tmp_$$.kr" -o /dev/null 2>&1 | grep -c 'groups differently')
printf 'fn main(){ u64 a=1 u64 b=2 u64 c=4 u64 r = a + (b & c)  exit(r) }\n' > "$DIR/../a3_tmp2_$$.kr"
a3_ctl2=$($KRC "$DIR/../a3_tmp2_$$.kr" -o /dev/null 2>&1 | grep -c 'groups differently')
if [ "$a3_ctl" -ge 1 ] && [ "$a3_ctl2" = "0" ]; then
    PASS=$((PASS + 1)); echo "  c_divergence_paren_is_the_difference: PASS (same expression, parens flip it)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: c_divergence_paren_is_the_difference (bare=$a3_ctl parenthesised=$a3_ctl2)"
fi
rm -f "$DIR/../a3_tmp_$$.kr" "$DIR/../a3_tmp2_$$.kr"

# Scale: the acceptance bar. The tree is uniformly parenthesised, so ANY output
# here is a false positive rather than a discovery. Covers the ~201k-node
# self-build plus every std module and example -- this bar was originally set
# when the tree was much smaller, and it still holds.
TOTAL=$((TOTAL + 1))
a3_scale=$($KRC "$DIR/../build/krc.kr" -o /dev/null 2>&1 | grep -c 'groups differently')
a3_std=0
for a3_f in "$DIR"/../std/*.kr; do
    a3_std=$((a3_std + $($KRC "$a3_f" -o /dev/null 2>&1 | grep -c 'groups differently')))
done
if [ "$a3_scale" = "0" ] && [ "$a3_std" = "0" ]; then
    PASS=$((PASS + 1)); echo "  c_divergence_tree_stays_clean: PASS (self-build 0, std/ 0)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: c_divergence_tree_stays_clean (self-build $a3_scale, std/ $a3_std)"
fi

# --- A4: the two diagnostic mechanism gaps ---
#
# -w exists because A3 added a warning over every expression, and a new warning
# with no off-switch is the ergonomics complaint this sub-project is meant to
# remove. Errors must be unaffected -- a -w that silenced errors would "pass" a
# broken build.
TOTAL=$((TOTAL + 1))
printf 'fn main(){ u64 a=1 u64 b=2 u64 c=4 u64 r = a + b & c  exit(r) }\n' > "$DIR/../w_tmp_$$.kr"
w_off=$($KRC "$DIR/../w_tmp_$$.kr" -o /dev/null 2>&1 | grep -c 'groups differently')
w_on=$($KRC -w "$DIR/../w_tmp_$$.kr" -o /dev/null 2>&1 | grep -c 'groups differently')
# The error probe MUST travel the path -w intercepts. Two earlier probes did
# not, and both passed while -w wrongly suppressed diag_emit ENTIRELY: an
# undefined call and a duplicate FUNCTION both go through report_error_at.
# A duplicate VARIABLE in one scope is diag_emit(sev 0), which is the branch
# that matters -- measured to vanish under that break.
printf 'fn main(){\n    u64 dupvar = 1\n    u64 dupvar = 2\n    exit(dupvar)\n}\n' > "$DIR/../w2_tmp_$$.kr"
w_err_out=$($KRC -w "$DIR/../w2_tmp_$$.kr" -o /dev/null 2>&1)
$KRC -w "$DIR/../w2_tmp_$$.kr" -o /dev/null >/dev/null 2>&1
w_err_rc=$?
w_ok=1
w_why=""
[ "$w_off" -ge 1 ] || { w_ok=0; w_why="no warning without -w (positive control)"; }
[ "$w_on" = "0" ] || { w_ok=0; w_why="-w did not suppress the warning"; }
[ "$w_err_rc" != "0" ] || { w_ok=0; w_why="-w suppressed a real ERROR (exit status)"; }
printf '%s' "$w_err_out" | grep -q 'redefinition of variable' || { w_ok=0; w_why="-w suppressed a diag_emit severity-0 error MESSAGE"; }
if [ "$w_ok" = "1" ]; then
    PASS=$((PASS + 1)); echo "  minus_w_suppresses_warnings_only: PASS (warn $w_off->0, error still exits $w_err_rc)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: minus_w_suppresses_warnings_only ($w_why)"
fi
rm -f "$DIR/../w_tmp_$$.kr" "$DIR/../w2_tmp_$$.kr"

# The diagnostic table holds 1024 and used to discard the rest in SILENCE,
# which defeats a warning whose value is coverage. The tail must account for
# every dropped entry: printed + suppressed == the number of real sites.
TOTAL=$((TOTAL + 1))
{
  echo 'fn main() {'
  echo '    u64 a=1 u64 b=2 u64 c=4'
  echo '    u64 r = 0'
  i=0
  while [ $i -lt 1200 ]; do echo '    r = a + b & c'; i=$((i + 1)); done
  echo '    exit(r & 1)'
  echo '}'
} > "$DIR/../cap_tmp_$$.kr"
cap_out=$($KRC "$DIR/../cap_tmp_$$.kr" -o /dev/null 2>&1)
cap_shown=$(printf '%s' "$cap_out" | grep -c 'groups differently')
cap_drop=$(printf '%s' "$cap_out" | sed -n 's/.*\.\.\. \([0-9]*\) further diagnostic.*/\1/p')
cap_ok=1
cap_why=""
[ "$cap_shown" = "1024" ] || { cap_ok=0; cap_why="printed $cap_shown, expected the 1024 cap"; }
[ -n "$cap_drop" ] || { cap_ok=0; cap_why="no suppression tail"; }
# The arithmetic is the point: a tail that just said "some were dropped" would
# pass a counter that counts wrong.
[ "$cap_ok" = "1" ] && [ "$((cap_shown + cap_drop))" = "1200" ] || { cap_ok=0; cap_why="${cap_why:-$cap_shown + $cap_drop != 1200}"; }
if [ "$cap_ok" = "1" ]; then
    PASS=$((PASS + 1)); echo "  diag_cap_reports_what_it_dropped: PASS (1024 shown + $cap_drop suppressed = 1200)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: diag_cap_reports_what_it_dropped ($cap_why)"
fi
# -w drops warnings at EMIT, so they must not consume the cap at all.
TOTAL=$((TOTAL + 1))
capw_out=$($KRC -w "$DIR/../cap_tmp_$$.kr" -o /dev/null 2>&1)
if [ "$(printf '%s' "$capw_out" | grep -c 'further diagnostic')" = "0" ] \
   && [ "$(printf '%s' "$capw_out" | grep -c 'groups differently')" = "0" ]; then
    PASS=$((PASS + 1)); echo "  minus_w_consumes_no_diag_cap: PASS"
else
    FAIL=$((FAIL + 1)); echo "FAIL: minus_w_consumes_no_diag_cap (suppressed warnings still filled the table)"
fi
rm -f "$DIR/../cap_tmp_$$.kr"

# --- push/pop/mov/sidt mnemonics ---
#
# These exist so std/idt.kr need not be written in raw hex. Two rows, because
# "it assembles to the right bytes" and "it does the right thing" are different
# claims and the second is the one that matters.
#
# Byte assertion. Compile-only, so the arch may be pinned. The encodings are
# asserted verbatim rather than by re-deriving them here, because a test that
# recomputes the encoding the same way the compiler does would agree with the
# compiler about a shared mistake.
TOTAL=$((TOTAL + 1))
cat > "$DIR/../mnem_tmp_$$.kr" <<'MNEOF'
fn probe() {
    asm { "push rax" }
    asm { "push r15" }
    asm { "pop r15" }
    asm { "pop rax" }
    asm { "mov r12, rax" }
    asm { "mov rax, r12" }
    asm { "mov rax, cs" }
    asm { "mov rax, [rsp+0x100]" }
    asm { "sidt [rax]" }
}
fn main() { probe()  exit(0) }
MNEOF
mnem_ok=1
mnem_note=""
if $KRC --arch=x86_64 --emit=obj "$DIR/../mnem_tmp_$$.kr" -o /tmp/mnem_$$.o >/dev/null 2>&1; then
    mnem_hex=$(od -An -tx1 -v /tmp/mnem_$$.o | tr -d ' \n')
    # push rax / push r15 / pop r15 / pop rax, contiguous.
    printf '%s' "$mnem_hex" | grep -q '504157415f58' || { mnem_ok=0; mnem_note="push/pop sequence"; }
    # mov r12,rax then mov rax,r12 -- REX.B vs REX.R. If these two were the
    # same bytes, the prefix bits would be inverted and the wrong register
    # would move whenever an operand is r8-r15.
    printf '%s' "$mnem_hex" | grep -q '4989c44c89e0' || { mnem_ok=0; mnem_note="mov REX.R/REX.B"; }
    # mov rax,cs ; mov rax,[rsp+0x100] ; sidt [rax]
    printf '%s' "$mnem_hex" | grep -q '8cc8488b8424000100000f0108' || { mnem_ok=0; mnem_note="cs/disp32/sidt"; }
else
    mnem_ok=0; mnem_note="compile failed"
fi
if [ "$mnem_ok" = "1" ]; then
    PASS=$((PASS + 1)); echo "  asm_push_pop_mov_encodings: PASS (push/pop, REX.R vs REX.B, cs, [rsp+disp32], sidt)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: asm_push_pop_mov_encodings ($mnem_note)"
fi
rm -f "$DIR/../mnem_tmp_$$.kr" /tmp/mnem_$$.o

# Runtime behaviour. This row EXECUTES, so it cannot pin an arch -- but the
# mnemonics are x86-only by construction, so it runs only where the host is
# x86_64 and says so otherwise rather than pretending to have covered it.
TOTAL=$((TOTAL + 1))
if [ "$RUN_ARCH" != "x86_64" ]; then
    PASS=$((PASS + 1)); echo "  asm_push_pop_mov_runtime: PASS (SKIPPED -- x86-only mnemonics, host is $RUN_ARCH)"
else
    cat > "$DIR/../mnemr_tmp_$$.kr" <<'MNREOF'
fn mov_through(u64 a) -> u64 {
    u64 out = 0
    asm { "mov rbx, rax" } in(a -> rax) out(rbx -> out)
    return out
}
fn push_pop(u64 a) -> u64 {
    u64 out = 0
    asm { "push rax"  "pop rbx" } in(a -> rax) out(rbx -> out)
    return out
}
// Discriminates REX.R from REX.B. `a` goes into r12, rax is then overwritten
// with `b`, and r12 is brought back into rax -- so the result must be `a`.
// With the REX bits inverted, `mov rax, r12` assembles to something that
// leaves rax alone, and the result is `b`.
//
// The obvious form (push rax; pop r13; mov rbx, r13) does NOT discriminate:
// measured, it still passed with REX.R/REX.B swapped, because rbx happened to
// already hold the expected value.
fn rex_roundtrip(u64 a, u64 b) -> u64 {
    u64 out = 0
    asm { "push rax"  "pop r12"  "mov rax, rcx"  "mov rax, r12" } in(a -> rax, b -> rcx) out(rax -> out)
    return out
}
fn main() {
    if mov_through(1234) != 1234 { exit(1) }
    if push_pop(4321) != 4321 { exit(2) }
    if rex_roundtrip(999, 555) != 999 { exit(3) }
    // If push and pop were unbalanced the stack would be off by 8 and
    // returning from these would fault rather than fail an assertion.
    if mov_through(7) + push_pop(2) != 9 { exit(4) }
    exit(9)
}
MNREOF
    mnr_ok=1
    for mnr_mode in "" "--legacy"; do
        if $KRC --arch=$RUN_ARCH $mnr_mode "$DIR/../mnemr_tmp_$$.kr" -o /tmp/mnemr_$$ >/dev/null 2>&1; then
            chmod +x /tmp/mnemr_$$
            /tmp/mnemr_$$ >/dev/null 2>&1
            mnr_rc=$?
            [ "$mnr_rc" = "9" ] || { mnr_ok=0; echo "    ${mnr_mode:-ir} exited $mnr_rc, want 9"; }
        else
            mnr_ok=0; echo "    ${mnr_mode:-ir} build failed"
        fi
    done
    if [ "$mnr_ok" = "1" ]; then
        PASS=$((PASS + 1)); echo "  asm_push_pop_mov_runtime: PASS (values moved, REX.R/REX.B distinguished, stack balanced, both backends)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: asm_push_pop_mov_runtime"
    fi
    rm -f "$DIR/../mnemr_tmp_$$.kr" /tmp/mnemr_$$
fi

# --- std/mouse.kr and examples/mouse-gui ---
#
# Compile-only row first, arch-pinned: the artifact is inspected, not executed.
TOTAL=$((TOTAL + 1))
MG_DIR="$DIR/../examples/mouse-gui"
MG_IMG="/tmp/krc_mgui_$$.img"
if [ ! -f "$MG_DIR/main.kr" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: mouse_gui_example_builds (source missing)"
elif ! $KRC --target=none --arch=x86_64 --emit=image \
            --load-addr=0x100000 --stack-top=0x90000 \
            "$MG_DIR/main.kr" -o "$MG_IMG" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1)); echo "FAIL: mouse_gui_example_builds (compile failed)"
else
    PASS=$((PASS + 1)); echo "  mouse_gui_example_builds: PASS (widgets+mouse+ramfb, --target=none)"
fi

# The behavioural row. Drives the mouse AND the keyboard over QMP and asserts
# three independent things: the cursor reached a commanded position, a click
# was attributed to the right widget AND changed pixels, and the keyboard still
# worked while the mouse was streaming.
#
# That last one is the load-bearing one. Keyboard and mouse share a single 8042
# output buffer, so two pollers each reading 0x60 steal each other's bytes.
# Measured with a second reader reintroduced: the cursor never moved at all,
# the click was never seen, and a keystroke went missing -- 3 of 3 checks red.
TOTAL=$((TOTAL + 1))
if ! command -v qemu-system-x86_64 >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  mouse_gui_example_runs: PASS (SKIPPED -- no qemu-system-x86_64/python3)"
elif [ ! -f "$MG_IMG" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: mouse_gui_example_runs (no image from the row above)"
else
    mg_out=$(timeout 200 python3 "$MG_DIR/check.py" "$MG_IMG" 2>&1)
    if printf '%s' "$mg_out" | grep -q '^PASS: cursor moved'; then
        PASS=$((PASS + 1)); echo "  mouse_gui_example_runs: PASS (cursor, click-changes-pixels, keyboard alive)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: mouse_gui_example_runs"
        printf '%s\n' "$mg_out" | grep -E '^BAD|^FAIL' | sed 's/^/    /' | head -6
    fi
fi
rm -f "$MG_IMG"

# std/mouse.kr must never read the shared port itself. This is a SOURCE
# invariant rather than a behavioural one because the failure it prevents is
# intermittent: a second reader on 0x60 only loses the bytes it happens to
# win, so a behavioural test can pass by timing luck. std/ps2.kr owns the port;
# mouse.kr is protocol only.
TOTAL=$((TOTAL + 1))
if grep -nE '\b(inb|outb)\s*\(\s*(PS2_DATA|PS2_STATUS|PS2_CMD|0x60|0x64)' "$DIR/../std/mouse.kr" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1)); echo "FAIL: mouse_never_touches_shared_port (std/mouse.kr reads 0x60/0x64 directly)"
    grep -nE '\b(inb|outb)\s*\(' "$DIR/../std/mouse.kr" | sed 's/^/    /' | head -4
else
    PASS=$((PASS + 1)); echo "  mouse_never_touches_shared_port: PASS (ps2.kr is the only owner of 0x60)"
fi

# Whole surface must compile freestanding, including what the demo never calls.
TOTAL=$((TOTAL + 1))
cat > "$DIR/../mou_tmp_$$.kr" <<'MOUEOF'
import "std/mouse.kr"
fn main() -> uint32 {
    if mouse_init() == 0 { loop { } }
    mouse_set_bounds(1024, 768)
    mouse_set_pos(10, 10)
    if mouse_poll() != 0 {
        u64 _x = mouse_x()
        u64 _y = mouse_y()
        if (mouse_buttons() & MOUSE_BTN_LEFT) != 0 { }
        if (mouse_buttons() & MOUSE_BTN_RIGHT) != 0 { }
        if (mouse_buttons() & MOUSE_BTN_MIDDLE) != 0 { }
    }
    if mouse_is_ready() == 0 { mouse_resync() }
    u64 _p = mouse_packet_count()
    u64 _r = mouse_resync_count()
    if ps2_overflowed() != 0 { ps2_clear_overflow() }
    ps2_drain()
    if ps2_kbd_pop() == PS2_EMPTY { }
    if ps2_aux_pop() == PS2_EMPTY { }
    ps2_aux_flush()
    halt_forever()
    return 0
}
MOUEOF
if $KRC --target=none --arch=x86_64 --emit=image --load-addr=0x100000 \
        --stack-top=0x90000 "$DIR/../mou_tmp_$$.kr" -o /tmp/mou_$$.img >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  mouse_full_surface_freestanding: PASS"
else
    FAIL=$((FAIL + 1)); echo "FAIL: mouse_full_surface_freestanding"
    $KRC --target=none --arch=x86_64 --emit=image --load-addr=0x100000 \
         --stack-top=0x90000 "$DIR/../mou_tmp_$$.kr" -o /tmp/mou_$$.img 2>&1 | grep error | head -3 | sed 's/^/    /'
fi
rm -f "$DIR/../mou_tmp_$$.kr" /tmp/mou_$$.img

# --- std/x86.kr + std/cstr.kr: bare-metal support modules ---
# Both must work under --target=none. cstr.kr exists because std/string.kr's
# int_to_str/str_copy ALLOCATE their result, and alloc is refused on bare metal
# -- so formatting a number needed a heap. These write into a caller buffer.
run_test "cstr_format_and_string_ops" 'import "std/cstr.kr"
fn chk(u64 a, u64 b, u64 code) { if a != b { exit(code) } }
fn main() {
    u8[64] b
    chk(cstr_u64_dec(b, 64, 0), 1, 1)
    chk(cstr_eq(b, "0"), 1, 2)
    chk(cstr_u64_dec(b, 64, 18446744073709551615), 20, 3)
    chk(cstr_eq(b, "18446744073709551615"), 1, 4)
    cstr_u64_hex(b, 64, 0xDEADBEEF, 0)
    chk(cstr_eq(b, "deadbeef"), 1, 5)
    cstr_u64_hex(b, 64, 0x1F, 8)
    chk(cstr_eq(b, "0000001f"), 1, 6)
    cstr_u64_hex0x(b, 64, 0x1000, 0)
    chk(cstr_eq(b, "0x1000"), 1, 7)
    cstr_i64_dec(b, 64, 0 - 42)
    chk(cstr_eq(b, "-42"), 1, 8)
    chk(cstr_u64_dec(b, 3, 4095), 2, 9)
    chk(cstr_eq(b, "40"), 1, 10)
    chk(cstr_copy(b, "hello", 64), 5, 11)
    chk(cstr_append(b, "!!", 64), 7, 12)
    chk(cstr_eq(b, "hello!!"), 1, 13)
    chk(cstr_find("a,b", 44), 1, 14)
    chk(cstr_find("abc", 122), CSTR_NOTFOUND, 15)
    u8[32] line
    cstr_copy(line, "echo  hi there", 32)
    u64 args = cstr_split_word(line)
    chk(cstr_eq(line, "echo"), 1, 16)
    chk(cstr_eq(args, "hi there"), 1, 17)
    chk(cstr_parse_u64("1234x", 0), 1234, 18)
    chk(cstr_parse_hex("0xff", 0), 255, 19)
    exit(9)
}' 9

# std/x86.kr: only the NON-PRIVILEGED surface can run hosted -- port I/O,
# control registers, MSRs, cli/sti and lgdt/lidt are ring 0 and fault in
# userspace. The privileged half is covered by the freestanding compile below.
#
# rdtsc is asserted to ADVANCE between two reads, not to be ordered:
# `rdtsc() < t1` was the old form, and a rdtsc broken to return a constant
# (the shape a dropped out() binding produces) passed it -- 0 < 0 is false
# (measured). Two reads of a cycle counter are never equal, and equality
# stays true across a core migration where ordering does not, so this form
# discriminates without the flake.
#
# THIS ROW EXECUTES, and std/x86.kr is x86_64-only BY CONSTRUCTION -- its own
# header says importing it on another architecture "will fail at the first asm
# block, which is the intended behaviour rather than a silent no-op". So this
# is not a row that can follow $RUN_ARCH: there is no arm64 equivalent of
# rdtsc/cpuid/pause to run. It ran natively on the ARM64 CI job and failed to
# compile ('unrecognized asm instruction rdtsc') the first time this file
# reached that job. Run it where it means something and say so where it does
# not -- a silent omission would read as coverage.
if [ "$RUN_ARCH" = "x86_64" ]; then
    run_test "x86_nonprivileged_surface" 'import "std/x86.kr"
fn main() {
    if bswap16(0x1234) != 0x3412 { exit(1) }
    if bswap32(0x11223344) != 0x44332211 { exit(2) }
    if bswap64(0x1122334455667788) != 0x8877665544332211 { exit(3) }
    if bswap32(bswap32(0xDEADBEEF)) != 0xDEADBEEF { exit(4) }
    u64 t1 = rdtsc()
    cpu_relax()
    if rdtsc() == t1 { exit(5) }
    if cpuid_eax(0) == 0 { exit(6) }
    exit(9)
}' 9
else
    echo "  x86_nonprivileged_surface: SKIP (std/x86.kr is x86_64-only by construction; host is $RUN_ARCH)"
fi

# The whole point of both modules: they compile with no OS underneath.
# Compile-only, so the arch may be pinned.
TOTAL=$((TOTAL + 1))
bm_ok=1
cat > "$DIR/../bm_tmp_$$.kr" <<'BMEOF'
import "std/cstr.kr"
import "std/x86.kr"
static u8[64] scratch
fn main() -> uint32 {
    u64 b = scratch
    cstr_u64_hex0x(b, 64, 0x1000000, 8)
    cstr_i64_dec(b, 64, 0 - 1)
    cstr_append(b, "-metal", 64)
    outb(0x3F8, 65)
    u64 v = inb(0x3F8)
    write_cr3(read_cr3())
    invlpg(0x1000)
    lgdt(0x2000)
    wrmsr(0xC0000080, rdmsr(0xC0000080))
    cli()
    sti()
    cpu_relax()
    if v == 0xFFFF { hlt() }
    loop { }
}
BMEOF
$KRC --target=none --arch=x86_64 --emit=image --load-addr=0x100000 --stack-top=0x90000      "$DIR/../bm_tmp_$$.kr" -o /tmp/bm_$$.img >/dev/null 2>&1 || { bm_ok=0; echo "  x86_64 freestanding build failed"; }
# cstr must be arch-neutral too
cat > "$DIR/../bm2_tmp_$$.kr" <<'BM2EOF'
import "std/cstr.kr"
static u8[64] scratch
fn main() -> uint32 {
    u64 b = scratch
    cstr_u64_hex0x(b, 64, 0x40080000, 8)
    cstr_u64_dec(b, 64, 12345)
    loop { }
}
BM2EOF
$KRC --target=none --arch=arm64 --emit=image --load-addr=0x40080000 --stack-top=0x40200000      "$DIR/../bm2_tmp_$$.kr" -o /tmp/bm2_$$.img >/dev/null 2>&1 || { bm_ok=0; echo "  arm64 freestanding build failed"; }
if [ "$bm_ok" = "1" ]; then
    PASS=$((PASS + 1)); echo "  bare_metal_std_modules: PASS (cstr+x86 on x86_64, cstr on arm64, --target=none)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: bare_metal_std_modules"
fi
rm -f "$DIR/../bm_tmp_$$.kr" "$DIR/../bm2_tmp_$$.kr" /tmp/bm_$$.img /tmp/bm2_$$.img

# `pause` (F3 90) as a first-class mnemonic: a spin loop should not need
# asm("0xF3 0x90"). Compile-only + byte assertion, so the arch may be pinned.
TOTAL=$((TOTAL + 1))
printf 'fn main(){ asm { "pause" }  exit(0) }\n' > "$DIR/../pz_tmp_$$.kr"
pz_out=$($KRC --arch=x86_64 --emit=asm "$DIR/../pz_tmp_$$.kr" 2>&1)
pz_l=$(printf '%s' "$pz_out" | sed -n 's/.* -> \(.*\) (asm listing)$/\1/p')
if [ -f "$pz_l" ] && grep -qi 'f3 90' "$pz_l"; then
    PASS=$((PASS + 1)); echo "  asm_pause_mnemonic: PASS (F3 90 emitted and decoded)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: asm_pause_mnemonic (no f3 90 in listing)"
fi
rm -f "$DIR/../pz_tmp_$$.kr" "$pz_l"

# --- std/fw_cfg.kr + std/ramfb.kr, and examples/ramfb-demo ---
#
# examples/ramfb-demo must keep building. Compile-only and arch-pinned: the
# artifact is inspected, not executed. Same `do not cd` rule as the tutorial
# rows above -- $KRC is a relative path.
TOTAL=$((TOTAL + 1))
RFB_DIR="$DIR/../examples/ramfb-demo"
RFB_IMG="/tmp/krc_ramfb_example_$$.img"
if [ ! -f "$RFB_DIR/main.kr" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: ramfb_example_builds (source missing)"
elif ! $KRC --target=none --arch=x86_64 --emit=image \
            --load-addr=0x100000 --stack-top=0x90000 \
            "$RFB_DIR/main.kr" -o "$RFB_IMG" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1)); echo "FAIL: ramfb_example_builds (compile failed)"
else
    # Multiboot header magic 0x1BADB002 must be within the first 8 KiB.
    if od -An -tx4 -N8192 "$RFB_IMG" 2>/dev/null | tr -d ' \n' | grep -q '1badb002'; then
        PASS=$((PASS + 1)); echo "  ramfb_example_builds: PASS (x86_64 multiboot image)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: ramfb_example_builds (no multiboot magic)"
    fi
fi

# The claim that matters for ramfb is not "it compiled" but "QEMU scanned those
# pixels out". check.py boots the image headless and compares QEMU's own
# screendump against 13 expected pixel values. Needs qemu-system-x86_64 and
# python3; noted rather than failed when absent, like the ESP rows above.
TOTAL=$((TOTAL + 1))
if ! command -v qemu-system-x86_64 >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  ramfb_example_draws: PASS (pixel check SKIPPED -- no qemu-system-x86_64/python3)"
elif [ ! -f "$RFB_IMG" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: ramfb_example_draws (no image from the row above)"
else
    rfb_out=$(timeout 60 python3 "$RFB_DIR/check.py" "$RFB_IMG" 2>&1)
    if printf '%s' "$rfb_out" | grep -q '^PASS: 13/13 pixel checks$'; then
        PASS=$((PASS + 1)); echo "  ramfb_example_draws: PASS (13/13 pixels verified via QMP screendump)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: ramfb_example_draws"
        printf '%s\n' "$rfb_out" | sed 's/^/    /' | head -8
    fi
fi
rm -f "$RFB_IMG"

# std/fw_cfg.kr's whole surface must compile freestanding, including the paths
# the demo does not exercise (DMA read, whole-file read, the LE item readers).
TOTAL=$((TOTAL + 1))
cat > "$DIR/../fwc_tmp_$$.kr" <<'FWCEOF'
import "std/fw_cfg.kr"
static u8[256] fwbuf
fn main() -> uint32 {
    if fw_cfg_present() == 0 { loop { } }
    u64 b = fwbuf
    u64 _ram = fw_cfg_ram_size()
    u64 _cpus = fw_cfg_nb_cpus()
    u64 _feat = fw_cfg_features()
    if fw_cfg_has_dma() == 0 { loop { } }
    u64 sel = fw_cfg_find_file("etc/e820")
    if sel != FW_CFG_NOTFOUND {
        fw_cfg_dma_read(sel, b, 64)
        fw_cfg_dma_write(sel, b, 64)
    }
    fw_cfg_read_file("etc/smbios", b, 256)
    fw_cfg_select(FW_CFG_SIGNATURE)
    u64 _a = fw_cfg_read8()
    u64 _c = fw_cfg_read_be16()
    u64 _d = fw_cfg_read_be32()
    u64 _e = fw_cfg_read_le32()
    u64 _f = fw_cfg_read_le64()
    fw_cfg_read_bytes(b, 4)
    loop { }
}
FWCEOF
if $KRC --target=none --arch=x86_64 --emit=image --load-addr=0x100000 \
        --stack-top=0x90000 "$DIR/../fwc_tmp_$$.kr" -o /tmp/fwc_$$.img >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  fw_cfg_full_surface_freestanding: PASS"
else
    FAIL=$((FAIL + 1)); echo "FAIL: fw_cfg_full_surface_freestanding"
fi
rm -f "$DIR/../fwc_tmp_$$.kr" /tmp/fwc_$$.img

# --- std/fw_cfg_mmio.kr: the arm64 `-M virt` transport ----------------------
#
# Same protocol as std/fw_cfg.kr, reached through MMIO at 0x09020000 instead
# of ports. Compile-only and arch-PINNED to arm64: the module is arm64-only
# (its x86 sibling is port-I/O), and this row only inspects that the whole
# surface compiles freestanding -- nothing executes on the host.
TOTAL=$((TOTAL + 1))
cat > "$DIR/../fwm_tmp_$$.kr" <<'FWMEOF'
import "std/fw_cfg_mmio.kr"
static u8[256] fwmbuf
fn main() -> uint32 {
    fw_cfg_mmio_init(0x09020000)
    if fw_cfg_present() == 0 { loop { } }
    u64 b = fwmbuf
    u64 _ram = fw_cfg_ram_size()
    u64 _cpus = fw_cfg_nb_cpus()
    u64 _feat = fw_cfg_features()
    if fw_cfg_has_dma() == 0 { loop { } }
    u64 sel = fw_cfg_find_file("etc/table-loader")
    if sel != FW_CFG_NOTFOUND {
        fw_cfg_dma_read(sel, b, 64)
        fw_cfg_dma_write(sel, b, 64)
    }
    fw_cfg_read_file("etc/smbios", b, 256)
    fw_cfg_select(FW_CFG_SIGNATURE)
    u64 _a = fw_cfg_read8()
    u64 _c = fw_cfg_read_be16()
    u64 _d = fw_cfg_read_be32()
    u64 _e = fw_cfg_read_le32()
    u64 _f = fw_cfg_read_le64()
    fw_cfg_read_bytes(b, 4)
    loop { }
}
FWMEOF
if $KRC --target=none --arch=arm64 --emit=image --image-header \
        --load-addr=0x40080000 --stack-top=0x40200000 \
        "$DIR/../fwm_tmp_$$.kr" -o /tmp/fwm_$$.img >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  fw_cfg_mmio_full_surface_freestanding: PASS"
else
    FAIL=$((FAIL + 1)); echo "FAIL: fw_cfg_mmio_full_surface_freestanding"
fi
rm -f "$DIR/../fwm_tmp_$$.kr" /tmp/fwm_$$.img

# The claim that matters is not "it compiled" but "the device answered": boot
# the module on qemu-system-aarch64 `-M virt` and read the serial log. The
# arch pin is legitimate here even though the row executes, because the
# EMULATOR executes the artifact, not the host CPU -- same reasoning as the
# ramfb/mouse-gui rows above, which run qemu-system-x86_64 on any host. When
# qemu-system-aarch64 is absent this row SKIPS and says so; it does not claim
# the coverage it did not get.
#
# Every asserted field discriminates a real bug (each was broken on purpose
# and watched fail before this row landed):
#   bfw=4      BIG-ENDIAN 16-bit selector + BE directory. The classic port
#              of this module writes the selector little-endian; measured on
#              QEMU 8.2.2, that makes the device see item 0x1900, the
#              directory read all-zero, and find_file miss -- while the
#              endian-neutral "QEMU" signature check still PASSES. This
#              field, not `present`, is the one that catches that bug.
#   cpus=2     item payloads stay little-endian over MMIO (-smp 2).
#   sig=QEMU   DMA: BE request block, address halves HIGH at +16 then LOW
#              at +20 (the low write triggers). The buffer is scrubbed
#              first, so a stale signature cannot fake this.
#   wr=1       DMA write path, against -device ramfb.
TOTAL=$((TOTAL + 1))
if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  fw_cfg_mmio_answers_on_virt: PASS (SKIPPED -- no qemu-system-aarch64; compile row above is the only coverage)"
else
cat > "$DIR/../fwmx_tmp_$$.kr" <<'FWMXEOF'
import "std/uart_pl011.kr"
import "std/fw_cfg_mmio.kr"
static u8[128] fbuf
static u64[4] rcfg
fn puts2(u64 s) {
    u64 i = 0
    loop {
        u64 c = load8(s + i)
        if c == 0 { return }
        pl011_putc(c)
        i = i + 1
    }
}
fn putd(u64 v) {
    if v < 10 { pl011_putc(48 + v) } else { pl011_putc(88) }
}
fn fail(u64 msg) {
    puts2("FWCFG-MMIO-FAIL ")
    puts2(msg)
    pl011_putc(10)
    puts2("FWCFG-MMIO-DONE\n")
    loop { }
}
fn main() -> uint32 {
    pl011_init()
    if fw_cfg_present() == 0 { fail("present") }
    if fw_cfg_has_dma() == 0 { fail("dma-feature") }
    u64 cpus = fw_cfg_nb_cpus()
    u64 sel = fw_cfg_find_file("etc/boot-fail-wait")
    if sel == FW_CFG_NOTFOUND { fail("find-file") }
    u64 bfw = fw_cfg_last_size
    u64 n = fw_cfg_read_file("etc/boot-fail-wait", fbuf, 128)
    if n != bfw { fail("read-file-len") }
    store8(fbuf, 0)
    store8(fbuf + 1, 0)
    store8(fbuf + 2, 0)
    store8(fbuf + 3, 0)
    if fw_cfg_dma_read(FW_CFG_SIGNATURE, fbuf, 4) == 0 { fail("dma-read-rc") }
    u64 rsel = fw_cfg_find_file("etc/ramfb")
    if rsel == FW_CFG_NOTFOUND { fail("no-ramfb") }
    u64 c = rcfg
    store32(c, 0)
    store32(c + 4,  fw_cfg_bswap32(0x41000000))
    store32(c + 8,  fw_cfg_bswap32(0x34325258))
    store32(c + 12, 0)
    store32(c + 16, fw_cfg_bswap32(64))
    store32(c + 20, fw_cfg_bswap32(64))
    store32(c + 24, fw_cfg_bswap32(256))
    u64 wr = fw_cfg_dma_write(rsel, c, 28)
    puts2("FWCFG-MMIO cpus=")
    putd(cpus)
    puts2(" bfw=")
    putd(bfw)
    puts2(" sig=")
    pl011_putc(load8(fbuf))
    pl011_putc(load8(fbuf + 1))
    pl011_putc(load8(fbuf + 2))
    pl011_putc(load8(fbuf + 3))
    puts2(" wr=")
    putd(wr)
    pl011_putc(10)
    puts2("FWCFG-MMIO-DONE\n")
    loop { }
}
FWMXEOF
fwm_img=/tmp/fwmx_$$.img
fwm_log=/tmp/fwmx_$$.log
if ! $KRC --target=none --arch=arm64 --emit=image --image-header \
        --load-addr=0x40080000 --stack-top=0x40200000 \
        "$DIR/../fwmx_tmp_$$.kr" -o "$fwm_img" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1)); echo "FAIL: fw_cfg_mmio_answers_on_virt (compile failed)"
else
    rm -f "$fwm_log"
    qemu-system-aarch64 -M virt -cpu cortex-a72 -smp 2 -device ramfb \
        -display none -serial "file:$fwm_log" -kernel "$fwm_img" -no-reboot \
        >/dev/null 2>&1 &
    fwm_qpid=$!
    fwm_t=0
    while [ $fwm_t -lt 120 ]; do
        grep -q 'FWCFG-MMIO-DONE' "$fwm_log" 2>/dev/null && break
        sleep 0.25
        fwm_t=$((fwm_t + 1))
    done
    kill $fwm_qpid 2>/dev/null
    wait $fwm_qpid 2>/dev/null
    if grep -q '^FWCFG-MMIO cpus=2 bfw=4 sig=QEMU wr=1$' "$fwm_log" 2>/dev/null; then
        PASS=$((PASS + 1)); echo "  fw_cfg_mmio_answers_on_virt: PASS (BE selector, LE payloads, DMA r/w observed on qemu virt)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: fw_cfg_mmio_answers_on_virt"
        sed 's/^/    /' "$fwm_log" 2>/dev/null | head -6
    fi
fi
rm -f "$DIR/../fwmx_tmp_$$.kr" "$fwm_img" "$fwm_log"
fi

# A variable used ONLY as an asm operand is still used. sema_check_stmt did not
# descend into asm constraint lists at all, so std/x86.kr's wrmsr was warned
# about for `lo` and `hi` while passing both to the instruction. Three clauses,
# because the fix must not simply silence the warning:
#   in(var -> reg)  is a USE          -> no warning
#   out(reg -> var) is an INIT only   -> still warns when the value is dead
#   an untouched variable             -> still warns
TOTAL=$((TOTAL + 1))
cat > "$DIR/../asmop_tmp_$$.kr" <<'ASMEOF'
fn f() -> uint64 {
    uint64 used_as_input = 7
    uint64 dead_out = 0
    uint64 real_out = 0
    uint64 never_touched = 0
    asm { "rdtsc" } in(used_as_input -> rcx) out(rax -> dead_out, rdx -> real_out)
    return real_out
}
fn main() { exit(f() & 1) }
ASMEOF
asm_w=$($KRC --arch=x86_64 "$DIR/../asmop_tmp_$$.kr" -o /tmp/asmop_$$ 2>&1)
asm_ok=1
printf '%s' "$asm_w" | grep -q "unused variable.*'used_as_input'" && asm_ok=0
printf '%s' "$asm_w" | grep -q "unused variable.*'real_out'" && asm_ok=0
printf '%s' "$asm_w" | grep -q "unused variable.*'dead_out'" || asm_ok=0
printf '%s' "$asm_w" | grep -q "unused variable.*'never_touched'" || asm_ok=0
if [ "$asm_ok" = "1" ]; then
    PASS=$((PASS + 1)); echo "  asm_operand_counts_as_use: PASS (in= use, out= init-only, untouched still warns)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: asm_operand_counts_as_use"
    printf '%s\n' "$asm_w" | sed 's/^/    /' | head -6
fi
rm -f "$DIR/../asmop_tmp_$$.kr" /tmp/asmop_$$

# An asm out() operand initialises its variable, so reading it afterwards is
# not a use-before-init. Without the same fix this reported a false diagnostic.
#
# The diagnostic is a WARNING, so run_test (exit code only) cannot see it:
# with the init-marking deleted from sema, the run_test form still exited 9
# and passed (measured). Assert on the compiler's stderr as well as the run.
TOTAL=$((TOTAL + 1))
#
# THIS ROW EXECUTES, so the INSTRUCTION has to follow $RUN_ARCH -- `rdtsc` is
# x86-only and the native ARM64 CI job rejected it ('unrecognized asm
# instruction'). The property under test is not x86-specific at all (an asm
# out() operand initialises its variable), so the row keeps its coverage on
# both arches rather than skipping: arm64 uses a raw-hex NOP, which the
# compiler's own hint recommends. The constraint register keeps its x86
# spelling on BOTH backends -- arm64 rejects `x0` and wants `rax`.
#
# Whatever the instruction leaves in the register is irrelevant: `v & 0`
# masks it, so only the diagnostic and the exit code are being asserted.
ASMOI_INSN='"rdtsc"'
if [ "$RUN_ARCH" != "x86_64" ]; then ASMOI_INSN='"0xD503201F"'; fi
cat > "$DIR/../asmoi_tmp_$$.kr" <<ASMOIEOF
fn g() -> uint64 {
    uint64 v
    asm { $ASMOI_INSN } out(rax -> v)
    return v & 0
}
fn main() { exit(g() + 9) }
ASMOIEOF
asmoi_ok=1
asmoi_note=""
asmoi_out=$($KRC $KRC_FLAGS "$DIR/../asmoi_tmp_$$.kr" -o /tmp/asmoi_$$ 2>&1)
if [ ! -f /tmp/asmoi_$$ ]; then
    asmoi_ok=0; asmoi_note="compile failed"
else
    printf '%s' "$asmoi_out" | grep -q "used before initialization.*'v'" \
        && { asmoi_ok=0; asmoi_note="false use-before-init diagnostic on v"; }
    chmod +x /tmp/asmoi_$$
    /tmp/asmoi_$$ >/dev/null 2>&1
    asmoi_rc=$?
    [ "$asmoi_rc" = "9" ] || { asmoi_ok=0; asmoi_note="$asmoi_note; exited $asmoi_rc, want 9"; }
fi
if [ "$asmoi_ok" = "1" ]; then
    PASS=$((PASS + 1)); echo "  asm_out_operand_initialises: PASS (no false diagnostic, ran to exit 9)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: asm_out_operand_initialises (${asmoi_note#; })"
fi
rm -f "$DIR/../asmoi_tmp_$$.kr" /tmp/asmoi_$$

# --- examples/bare-console: VGA text + PS/2 keyboard + serial ---
#
# Compile-only row first, arch-pinned: the artifact is inspected, not executed.
TOTAL=$((TOTAL + 1))
BCON_DIR="$DIR/../examples/bare-console"
BCON_IMG="/tmp/krc_bcon_$$.img"
if [ ! -f "$BCON_DIR/main.kr" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: bare_console_example_builds (source missing)"
elif ! $KRC --target=none --arch=x86_64 --emit=image \
            --load-addr=0x100000 --stack-top=0x90000 \
            "$BCON_DIR/main.kr" -o "$BCON_IMG" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1)); echo "FAIL: bare_console_example_builds (compile failed)"
else
    PASS=$((PASS + 1)); echo "  bare_console_example_builds: PASS (x86_64 multiboot image)"
fi

# The claim is that keystrokes reach the program and output reaches BOTH sinks.
# check.py types on an emulated PS/2 keyboard over QMP -- not over serial,
# which would leave the scancode translation untested -- then asserts against
# the serial log AND the VGA text buffer read out of guest memory at 0xB8000.
# Both halves were confirmed load-bearing by breaking each on purpose.
TOTAL=$((TOTAL + 1))
if ! command -v qemu-system-x86_64 >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  bare_console_example_runs: PASS (SKIPPED -- no qemu-system-x86_64/python3)"
elif [ ! -f "$BCON_IMG" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: bare_console_example_runs (no image from the row above)"
else
    bcon_out=$(timeout 120 python3 "$BCON_DIR/check.py" "$BCON_IMG" 2>&1)
    if printf '%s' "$bcon_out" | grep -q '^PASS: PS/2 input echoed'; then
        PASS=$((PASS + 1)); echo "  bare_console_example_runs: PASS (PS/2 typed, echoed on vga+serial)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: bare_console_example_runs"
        printf '%s\n' "$bcon_out" | grep -E '^BAD|^FAIL' | sed 's/^/    /' | head -6
    fi
fi
rm -f "$BCON_IMG"

# std/vga_text.kr, std/serial.kr and std/ps2.kr must each compile freestanding
# across their whole surface, including what the example does not call.
TOTAL=$((TOTAL + 1))
cat > "$DIR/../vsp_tmp_$$.kr" <<'VSPEOF'
import "std/console.kr"
static u8[64] vbuf
fn main() -> uint32 {
    console_init_quiet()
    console_set_vga(1)
    console_set_serial(1)
    vga_clear()
    vga_set_attr(vga_attr(VGA_YELLOW, VGA_BLUE))
    u64 _a = vga_get_attr()
    u64 _r = vga_get_row()
    u64 _c = vga_get_col()
    vga_put_cell(0, 0, 65, 7)
    u64 _cell = vga_get_cell(0, 0)
    vga_fill_row(1, 32, 7)
    vga_scroll()
    vga_newline()
    vga_puts("x")
    vga_putsn("y")
    vga_write_at(2, 2, "z", 7)
    vga_move_cursor(3, 3)
    vga_hide_cursor()
    vga_sync_cursor()
    serial_init_port(COM2, UART_DIVISOR_9600)
    serial_set_port(COM1)
    u64 _p = serial_get_port()
    serial_putc_raw(65)
    serial_puts("s")
    serial_putsn("t")
    serial_write("uv", 2)
    u64 _sp = serial_poll()
    if serial_has_data(COM1) != 0 { u64 _g = serial_getc() }
    if ps2_shift_held() != 0 { }
    if ps2_ctrl_held() != 0 { }
    if ps2_caps_lock() != 0 { }
    u64 _k = ps2_poll()
    if _k == PS2_KEY_UP { ps2_reboot() }
    u64 b = vbuf
    console_readline(b, 64)
    console_put_u64(1)
    console_put_i64(0 - 1)
    console_put_hex(255, 4)
    console_putsn("done")
    halt_forever()
    return 0
}
VSPEOF
if $KRC --target=none --arch=x86_64 --emit=image --load-addr=0x100000 \
        --stack-top=0x90000 "$DIR/../vsp_tmp_$$.kr" -o /tmp/vsp_$$.img >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  console_stack_full_surface_freestanding: PASS"
else
    FAIL=$((FAIL + 1)); echo "FAIL: console_stack_full_surface_freestanding"
    $KRC --target=none --arch=x86_64 --emit=image --load-addr=0x100000 \
         --stack-top=0x90000 "$DIR/../vsp_tmp_$$.kr" -o /tmp/vsp_$$.img 2>&1 | grep error | head -3 | sed 's/^/    /'
fi
rm -f "$DIR/../vsp_tmp_$$.kr" /tmp/vsp_$$.img

# vga_attr packs (bg << 4) | fg. Worth pinning because the encoding is easy to
# get backwards, and because `|` binds TIGHTER than `<<` in KernRift, so the
# expression inside vga_attr has to be parenthesised to mean what it reads as.
#
# This row EXECUTES, so it cannot simply pin an arch. std/vga_text.kr is
# x86_64-only (it imports std/x86.kr for the cursor ports), yet vga_attr itself
# is pure arithmetic and dead-code elimination drops the port-I/O functions
# before their x86 asm is ever emitted -- so it builds and runs on arm64 too.
# That is a real property of the module and not something to leave incidental:
# it runs on BOTH arches here, native plus emulator, so a change that makes the
# pure helpers drag in x86 asm fails on the x86_64 runner rather than only on
# the arm64 one.
#
# Third clause pins the other half of std/x86.kr's stated contract: a function
# that DOES touch port I/O must fail loudly on a non-x86 target, not silently
# compile to a no-op.
TOTAL=$((TOTAL + 1))
cat > "$DIR/../vattr_tmp_$$.kr" <<'VAEOF'
import "std/vga_text.kr"
fn main() {
    if vga_attr(VGA_LIGHT_GREY, VGA_BLACK) != 0x07 { exit(1) }
    if vga_attr(VGA_YELLOW, VGA_BLUE) != 0x1E { exit(2) }
    if vga_attr(VGA_BLACK, VGA_LIGHT_GREY) != 0x70 { exit(3) }
    if vga_attr(VGA_WHITE, VGA_WHITE) != 0xFF { exit(4) }
    exit(9)
}
VAEOF
cat > "$DIR/../vattr2_tmp_$$.kr" <<'VA2EOF'
import "std/vga_text.kr"
fn main() { vga_move_cursor(1, 1)  exit(9) }
VA2EOF
va_ok=1
va_note=""
# host arch, natively
if $KRC --arch=$RUN_ARCH "$DIR/../vattr_tmp_$$.kr" -o /tmp/vattr_$$ >/dev/null 2>&1; then
    chmod +x /tmp/vattr_$$
    /tmp/vattr_$$ >/dev/null 2>&1
    [ "$?" = "9" ] || { va_ok=0; va_note="native $RUN_ARCH run"; }
else
    va_ok=0; va_note="native $RUN_ARCH build"
fi
# the other arch, under an emulator when one is present
if [ "$RUN_ARCH" = "x86_64" ]; then va_other=arm64; else va_other=x86_64; fi
va_emu=""
[ "$va_other" = "arm64" ] && va_emu="$(command -v qemu-aarch64-static || true)"
[ "$va_other" = "x86_64" ] && va_emu="$(command -v qemu-x86_64-static || true)"
if [ -n "$va_emu" ]; then
    if $KRC --arch=$va_other "$DIR/../vattr_tmp_$$.kr" -o /tmp/vattr2_$$ >/dev/null 2>&1; then
        chmod +x /tmp/vattr2_$$
        $va_emu /tmp/vattr2_$$ >/dev/null 2>&1
        [ "$?" = "9" ] || { va_ok=0; va_note="$va_other run"; }
    else
        va_ok=0; va_note="$va_other build (pure helpers should not drag in x86 asm)"
    fi
else
    va_note="$va_other SKIPPED, no emulator"
fi
# port I/O on arm64 must be refused, loudly
va_err=$($KRC --arch=arm64 "$DIR/../vattr2_tmp_$$.kr" -o /tmp/vattr3_$$ 2>&1)
if [ -f /tmp/vattr3_$$ ] || ! printf '%s' "$va_err" | grep -q "unrecognized asm instruction"; then
    va_ok=0; va_note="port I/O silently accepted on arm64"
fi
if [ "$va_ok" = "1" ]; then
    PASS=$((PASS + 1)); echo "  vga_attr_packs_bg_high_fg_low: PASS (both arches; port I/O still refused on arm64${va_note:+; $va_note})"
else
    FAIL=$((FAIL + 1)); echo "FAIL: vga_attr_packs_bg_high_fg_low ($va_note)"
fi
rm -f "$DIR/../vattr_tmp_$$.kr" "$DIR/../vattr2_tmp_$$.kr" /tmp/vattr_$$ /tmp/vattr2_$$ /tmp/vattr3_$$

# --- inline-asm constraints must fail loud, on BOTH backends -----------------
#
# x86_reg_code used to return a 0xFFFF sentinel for an unrecognised register
# and every binding site then SKIPPED the binding, so `out(eax -> v)` -- the
# 32-bit spelling, or any typo -- compiled clean and did nothing. Measured
# before the fix: the program in the executing row below exited 7, not 42, on
# the IR backend AND on --legacy. The operand half had the same hole: an
# unresolvable variable name (a typo, or a static/global, which asm constraints
# have never supported) was silently dropped too.
#
# These two rows only COMPILE, so they pin --arch=x86_64 deliberately: the
# register names being checked are x86 names.
TOTAL=$((TOTAL + 1))
cat > "$DIR/../asmreg_tmp_$$.kr" <<'ASMREGEOF'
fn main() {
    uint64 v = 7
    asm { "0xb8 0x2a 0x00 0x00 0x00" } out(eax -> v)
    exit(v)
}
ASMREGEOF
cat > "$DIR/../asmvar_tmp_$$.kr" <<'ASMVAREOF'
fn main() {
    uint64 v = 7
    asm { "0x48 0x89 0xC0" } in(nosuchvar -> rax) out(rax -> v)
    exit(v)
}
ASMVAREOF
asmloud_ok=1
asmloud_note=""
for asmloud_be in "" "--legacy"; do
    asmloud_out=$($KRC --arch=x86_64 $asmloud_be "$DIR/../asmreg_tmp_$$.kr" -o /tmp/asmreg_$$ 2>&1)
    if [ -f /tmp/asmreg_$$ ]; then
        asmloud_ok=0; asmloud_note="unknown register accepted (${asmloud_be:-ir})"
    elif ! printf '%s' "$asmloud_out" | grep -q "unknown inline-asm constraint register 'eax'"; then
        asmloud_ok=0; asmloud_note="wrong/absent message for eax (${asmloud_be:-ir})"
    fi
    rm -f /tmp/asmreg_$$
    asmloud_out=$($KRC --arch=x86_64 $asmloud_be "$DIR/../asmvar_tmp_$$.kr" -o /tmp/asmvar_$$ 2>&1)
    if [ -f /tmp/asmvar_$$ ]; then
        asmloud_ok=0; asmloud_note="unknown operand accepted (${asmloud_be:-ir})"
    elif ! printf '%s' "$asmloud_out" | grep -q "inline-asm constraint variable not found: 'nosuchvar'"; then
        asmloud_ok=0; asmloud_note="wrong/absent message for nosuchvar (${asmloud_be:-ir})"
    fi
    rm -f /tmp/asmvar_$$
done
if [ "$asmloud_ok" = "1" ]; then
    PASS=$((PASS + 1)); echo "  asm_constraint_unknown_name_refused: PASS (register + operand, both backends)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: asm_constraint_unknown_name_refused ($asmloud_note)"
fi
rm -f "$DIR/../asmreg_tmp_$$.kr" "$DIR/../asmvar_tmp_$$.kr"

# Positive control for the row above: the fix must not pass by refusing
# everything. Every accepted name (rax..rdi, rsp, rbp, r8..r15) still compiles
# on both backends. rsp appears only as an OUTPUT -- feeding a value into rsp
# would destroy the stack.
TOTAL=$((TOTAL + 1))
cat > "$DIR/../asmok_tmp_$$.kr" <<'ASMOKEOF'
fn main() {
    uint64 v = 1
    uint64 o = 0
    asm { "nop" } in(v -> rax, v -> rcx, v -> rdx, v -> rbx, v -> rsi, v -> rdi, v -> rbp)
    asm { "nop" } in(v -> r8, v -> r9, v -> r10, v -> r11, v -> r12, v -> r13, v -> r14, v -> r15)
    asm { "nop" } out(rsp -> o)
    exit(0)
}
ASMOKEOF
asmok_ok=1
asmok_note=""
for asmok_be in "" "--legacy"; do
    asmok_out=$($KRC --arch=x86_64 $asmok_be "$DIR/../asmok_tmp_$$.kr" -o /tmp/asmok_$$ 2>&1)
    if [ ! -f /tmp/asmok_$$ ]; then
        asmok_ok=0
        asmok_note="accepted name refused (${asmok_be:-ir}): $(printf '%s' "$asmok_out" | grep '^error' | head -1)"
    fi
    rm -f /tmp/asmok_$$
done
if [ "$asmok_ok" = "1" ]; then
    PASS=$((PASS + 1)); echo "  asm_constraint_accepted_names_still_bind: PASS (16 names, both backends)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: asm_constraint_accepted_names_still_bind ($asmok_note)"
fi
rm -f "$DIR/../asmok_tmp_$$.kr"

# The one that EXECUTES: a correctly spelled binding must still move the value.
# This is the row that was red before the fix in its `eax` form, so it is also
# the row that proves the binding path itself was not broken by fixing it.
# x86 machine code, so it can only run on an x86_64 host -- guarded on
# $RUN_ARCH rather than pinned, and it builds for $RUN_ARCH.
TOTAL=$((TOTAL + 1))
if [ "$RUN_ARCH" = "x86_64" ]; then
    cat > "$DIR/../asmbind_tmp_$$.kr" <<'ASMBINDEOF'
fn main() {
    uint64 v = 7
    asm { "0xb8 0x2a 0x00 0x00 0x00" } out(rax -> v)
    exit(v)
}
ASMBINDEOF
    asmbind_ok=1
    asmbind_note=""
    for asmbind_be in "" "--legacy"; do
        if $KRC --arch=$RUN_ARCH $asmbind_be "$DIR/../asmbind_tmp_$$.kr" -o /tmp/asmbind_$$ >/dev/null 2>&1; then
            chmod +x /tmp/asmbind_$$
            /tmp/asmbind_$$ >/dev/null 2>&1
            asmbind_rc=$?
            [ "$asmbind_rc" = "42" ] || { asmbind_ok=0; asmbind_note="${asmbind_be:-ir} exited $asmbind_rc, want 42"; }
        else
            asmbind_ok=0; asmbind_note="${asmbind_be:-ir} build failed"
        fi
        rm -f /tmp/asmbind_$$
    done
    if [ "$asmbind_ok" = "1" ]; then
        PASS=$((PASS + 1)); echo "  asm_constraint_out_rax_binds: PASS (42 through rax, both backends)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: asm_constraint_out_rax_binds ($asmbind_note)"
    fi
    rm -f "$DIR/../asmbind_tmp_$$.kr"
else
    PASS=$((PASS + 1)); echo "  asm_constraint_out_rax_binds: SKIP (RUN_ARCH=$RUN_ARCH, x86 machine code)"
fi

# --- std/uart_16550.kr is a provider layered on std/serial.kr ----------------
#
# uart_16550.kr used to carry its own port I/O and its own 16550 register map,
# so the stdlib held two independent implementations of the same UART. It is
# now a thin shim: serial.kr drives the chip, uart_16550.kr publishes it as the
# compiler's `write`.
#
# All three rows below CROSS-COMPILE for x86_64 and run the artifact under
# qemu-system-x86_64, so pinning the arch is correct -- these are bare-metal
# x86 images, not host binaries, and the host arch does not enter into it.

# Both print providers define `write` with @builtin_override, so importing them
# together is a collision BY DESIGN and both headers say so. Pin the message,
# because the thing that makes it confusing is that it names a line in a file
# the user did not write. (Which file it names follows import order: the second
# provider imported is the redefinition.)
TOTAL=$((TOTAL + 1))
cat > "$DIR/../ucol_tmp_$$.kr" <<'UCOLEOF'
import "std/console.kr"
import "std/uart_16550.kr"
fn main() -> uint64 {
    uart16550_init()
    println_str("x")
    return 0
}
UCOLEOF
ucol_out=$($KRC --target=none --arch=x86_64 --emit=image --load-addr=0x100000 \
                --stack-top=0x90000 "$DIR/../ucol_tmp_$$.kr" -o /tmp/ucol_$$.img 2>&1)
if [ -f /tmp/ucol_$$.img ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: uart16550_console_collide_by_design (the two providers linked together)"
elif ! printf '%s' "$ucol_out" | grep -q "std/uart_16550.kr:.*error: redefinition of function"; then
    FAIL=$((FAIL + 1)); echo "FAIL: uart16550_console_collide_by_design (wrong message: $(printf '%s' "$ucol_out" | grep -m1 error))"
else
    PASS=$((PASS + 1)); echo "  uart16550_console_collide_by_design: PASS (redefinition of write, named in uart_16550.kr)"
fi
rm -f "$DIR/../ucol_tmp_$$.kr" /tmp/ucol_$$.img

# The provider alone must still make `print`/`println_str` work with no OS
# beneath it -- BOOTED, not merely compiled. serial_putsn is in the same
# program on purpose: it is reachable only because uart_16550.kr imports
# serial.kr, so its line in the log is what proves the layering rather than a
# copy. The number is computed at run time so a stale capture cannot pass.
TOTAL=$((TOTAL + 1))
cat > "$DIR/../uprov_tmp_$$.kr" <<'UPROVEOF'
import "std/uart_16550.kr"
static uint64 useed = 5000000007
fn ustamp(uint64 v) -> uint64 { return v + 9 }
fn main() -> uint64 {
    uart16550_init()
    println_str("KRUART-PROVIDER")
    print(ustamp(useed))
    println_str("")
    serial_putsn("VIA-SERIAL-KR")
    return 0
}
UPROVEOF
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  uart16550_provider_prints_on_serial: PASS (SKIPPED -- no qemu-system-x86_64)"
elif ! $KRC --target=none --arch=x86_64 --emit=image --load-addr=0x100000 \
            --stack-top=0x90000 "$DIR/../uprov_tmp_$$.kr" -o /tmp/uprov_$$.img >/dev/null 2>&1; then
    FAIL=$((FAIL + 1)); echo "FAIL: uart16550_provider_prints_on_serial (compile failed)"
    $KRC --target=none --arch=x86_64 --emit=image --load-addr=0x100000 \
         --stack-top=0x90000 "$DIR/../uprov_tmp_$$.kr" -o /tmp/uprov_$$.img 2>&1 | grep error | head -3 | sed 's/^/    /'
else
    rm -f /tmp/uprov_$$.log
    timeout 15 qemu-system-x86_64 -kernel /tmp/uprov_$$.img -m 256 \
        -serial file:/tmp/uprov_$$.log -display none -no-reboot >/dev/null 2>&1
    uprov_log=$(cat /tmp/uprov_$$.log 2>/dev/null)
    uprov_bad=""
    printf '%s' "$uprov_log" | grep -q "KRUART-PROVIDER" || uprov_bad="no banner"
    printf '%s' "$uprov_log" | grep -q "5000000016" || uprov_bad="$uprov_bad; no computed value"
    printf '%s' "$uprov_log" | grep -q "VIA-SERIAL-KR" || uprov_bad="$uprov_bad; serial.kr surface unreachable"
    if [ -z "$uprov_bad" ]; then
        PASS=$((PASS + 1)); echo "  uart16550_provider_prints_on_serial: PASS (banner, computed 5000000016 and serial_putsn on COM1)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: uart16550_provider_prints_on_serial ($uprov_bad)"
        printf '    log: %s\n' "$(printf '%s' "$uprov_log" | tr '\n' '|' | head -c 200)"
    fi
    rm -f /tmp/uprov_$$.img /tmp/uprov_$$.log
fi
rm -f "$DIR/../uprov_tmp_$$.kr"

# Importing std/serial.kr NEXT TO the provider must stay clean. It is not
# obvious that it would: the program spells the import "std/serial.kr" and
# uart_16550.kr spells the same file "serial.kr" (the sibling-import rule), so
# a resolver that deduplicated on the literal string rather than the resolved
# path would pull serial.kr in twice and redefine every function in it.
TOTAL=$((TOTAL + 1))
cat > "$DIR/../usu_tmp_$$.kr" <<'USUEOF'
import "std/serial.kr"
import "std/uart_16550.kr"
fn main() -> uint64 {
    uart16550_init()
    serial_set_port(COM1)
    if serial_get_port() != COM1 { return 1 }
    println_str("SERIAL-PLUS-UART-OK")
    uart16550_putc(65)
    uart16550_putc(10)
    return 0
}
USUEOF
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  uart16550_beside_serial_import: PASS (SKIPPED -- no qemu-system-x86_64)"
elif ! $KRC --target=none --arch=x86_64 --emit=image --load-addr=0x100000 \
            --stack-top=0x90000 "$DIR/../usu_tmp_$$.kr" -o /tmp/usu_$$.img >/dev/null 2>&1; then
    FAIL=$((FAIL + 1)); echo "FAIL: uart16550_beside_serial_import (compile failed)"
    $KRC --target=none --arch=x86_64 --emit=image --load-addr=0x100000 \
         --stack-top=0x90000 "$DIR/../usu_tmp_$$.kr" -o /tmp/usu_$$.img 2>&1 | grep error | head -3 | sed 's/^/    /'
else
    rm -f /tmp/usu_$$.log
    timeout 15 qemu-system-x86_64 -kernel /tmp/usu_$$.img -m 256 \
        -serial file:/tmp/usu_$$.log -display none -no-reboot >/dev/null 2>&1
    usu_log=$(cat /tmp/usu_$$.log 2>/dev/null)
    if printf '%s' "$usu_log" | grep -q "SERIAL-PLUS-UART-OK" && printf '%s' "$usu_log" | grep -q "^A$"; then
        PASS=$((PASS + 1)); echo "  uart16550_beside_serial_import: PASS (one serial.kr, both entry points working)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: uart16550_beside_serial_import (log: $(printf '%s' "$usu_log" | tr '\n' '|' | head -c 120))"
    fi
    rm -f /tmp/usu_$$.img /tmp/usu_$$.log
fi
rm -f "$DIR/../usu_tmp_$$.kr"

# --- std/pci.kr enumerates the real machine ----------------------------------
#
# One probe program, three machines. The point of the three is that a baked
# list of devices would pass the first and fail the other two: `-vga none` and
# `-net none` take devices away, `-device virtio-rng-pci` adds one, and the
# guest's own output has to follow.
#
# These rows CROSS-COMPILE for x86_64 and run the artifact under
# qemu-system-x86_64, so pinning the arch is right: they are bare-metal x86
# images and the host arch does not enter into it.
PCI_SRC="$DIR/../pciprobe_tmp_$$.kr"
PCI_IMG=/tmp/pciprobe_$$.img
cat > "$PCI_SRC" <<'PCIEOF'
import "std/uart_16550.kr"
import "std/cstr.kr"
import "std/pci.kr"

static u8[64] pbuf

fn p_str(u64 s) {
    u64 i = 0
    while load8(s + i) != 0 {
        uart16550_putc(load8(s + i))
        i = i + 1
    }
}

fn p_hex(u64 v, u64 width) {
    u64 b = pbuf
    cstr_u64_hex(b, 64, v, width)
    p_str(b)
}

fn p_nl() { uart16550_putc(10) }

fn p_bdf(u64 bus, u64 dev, u64 func) {
    p_hex(bus, 2)
    uart16550_putc(58)
    p_hex(dev, 2)
    uart16550_putc(46)
    p_hex(func, 1)
}

// The callback pci_scan drives through call_ptr. Six arguments is the ceiling
// (args 7+ are silently dropped), so class and subclass arrive packed.
fn on_dev(u64 bus, u64 dev, u64 func, u64 vid, u64 did, u64 cls) {
    p_str("DEV ")
    p_bdf(bus, dev, func)
    p_str(" ")
    p_hex(vid, 4)
    uart16550_putc(58)
    p_hex(did, 4)
    p_str(" cls=")
    p_hex(cls, 4)
    p_str(" hdr=")
    p_hex(pci_header_type(bus, dev, func), 2)
    p_nl()
    u64 slot = 0
    while slot < 6 {
        u64 raw = pci_bar_raw(bus, dev, func, slot)
        if raw != 0 {
            p_str("BAR ")
            p_bdf(bus, dev, func)
            p_str(" ")
            p_hex(slot, 1)
            p_str(" raw=")
            p_hex(raw, 8)
            if pci_bar_is_io(bus, dev, func, slot) != 0 { p_str(" io") }
            if pci_bar_is_64(bus, dev, func, slot) != 0 { p_str(" mem64") }
            p_str(" addr=")
            p_hex(pci_bar(bus, dev, func, slot), 8)
            p_str(" next=")
            p_hex(pci_bar_next(bus, dev, func, slot), 1)
            p_nl()
        }
        slot = slot + 1
    }
}

fn main() -> uint64 {
    uart16550_init()
    p_str("PCI-BEGIN")
    p_nl()
    pci_scan(fn_addr("on_dev"))
    p_str("FIND 8086:100e -> ")
    p_hex(pci_find_device(0x8086, 0x100E), 6)
    p_nl()
    p_str("FIND 1234:9999 -> ")
    p_hex(pci_find_device(0x1234, 0x9999), 8)
    p_nl()
    p_str("ADDR ")
    p_hex(pci_config_addr(0, 3, 0, 0), 8)
    p_str(" ")
    p_hex(pci_config_addr(0, 1, 3, 0x2C), 8)
    p_nl()
    // The mask widths, on inputs the machine itself never produces: every I/O
    // BAR QEMU hands out is 16-byte aligned, so a live one masks the same
    // under 2 bits and under 4.
    p_str("DECODE ")
    p_hex(pci_bar_decode(0x0000C04D, 0), 8)
    p_str(" ")
    p_hex(pci_bar_decode(0xFD000008, 0), 8)
    p_str(" ")
    p_hex(pci_bar_decode(0xFE00000C, 0x00000001), 9)
    p_nl()
    p_str("PCI-END")
    p_nl()
    return 0
}
PCIEOF

# The guest halts rather than exiting, so `timeout N` would always cost the
# full N. Wait for the end marker instead and kill as soon as it lands.
pci_boot() {   # pci_boot <log> <extra qemu args...>
    local log="$1"; shift
    rm -f "$log"
    timeout 40 qemu-system-x86_64 -kernel "$PCI_IMG" -m 256 \
        -display none -no-reboot -serial "file:$log" "$@" >/dev/null 2>&1 &
    local pid=$! n=0
    while [ "$n" -lt 400 ]; do
        if [ -s "$log" ] && grep -q "PCI-END" "$log" 2>/dev/null; then break; fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
        n=$((n + 1))
    done
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
}

# want_lines <log> <label> — each remaining argument is a line that must be
# present verbatim. Sets pci_bad.
pci_want() {
    local log="$1"; shift
    local want
    for want in "$@"; do
        grep -qxF "$want" "$log" 2>/dev/null || pci_bad="$pci_bad; missing '$want'"
    done
}

PCI_HAVE_QEMU=0
command -v qemu-system-x86_64 >/dev/null 2>&1 && PCI_HAVE_QEMU=1
PCI_BUILT=0
if [ "$PCI_HAVE_QEMU" = "1" ]; then
    if $KRC --target=none --arch=x86_64 --emit=image --load-addr=0x100000 \
            --stack-top=0x90000 "$PCI_SRC" -o "$PCI_IMG" >/dev/null 2>&1; then
        PCI_BUILT=1
    fi
fi

# The default i440fx machine, read through 0xCF8/0xCFC by the guest itself.
# Note what each assertion is load-bearing for:
#   * device_id differing from vendor_id proves pci_config_read16 uses the
#     sub-dword port (0xCFC + (off & 3)); reading the aligned dword instead
#     would report the vendor for every even offset.
#   * cls=0600 proves the same for pci_config_read8 at offsets 0x0B/0x0A.
#   * hdr=80 on 00:01.0 is what licenses probing functions 1-7 -- and the
#     PIIX3 answers on 0, 1 and 3 with NO function 2, so a walk that stops at
#     the first absent function finds two thirds of the machine.
#   * the 00:02.0 BAR line pins the MEMORY mask width: 4 bits, fd000008 ->
#     fd000000, where a 2-bit mask would leave the 8. The I/O width is NOT
#     observable from a live BAR here -- every I/O BAR this machine hands out
#     is 16-byte aligned, so 0000c041 masks to 0000c040 under both widths --
#     which is why DECODE feeds pci_bar_decode 0000c04d, where the two widths
#     differ. (The plan cited 0xc041 -> 0xc040 as the confirmation of the
#     2-bit mask; it is not one.)
#   * DECODE's third field also runs the 64-bit join on a synthetic high half,
#     so the 33rd bit upward is exercised even without the virtio row.
#   * ADDR pins the config address word, whose unparenthesised C spelling
#     evaluates to 0x0 in this dialect.
TOTAL=$((TOTAL + 1))
if [ "$PCI_HAVE_QEMU" = "0" ]; then
    PASS=$((PASS + 1)); echo "  pci_enumerates_default_machine: PASS (SKIPPED -- no qemu-system-x86_64)"
elif [ "$PCI_BUILT" = "0" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: pci_enumerates_default_machine (compile failed)"
    $KRC --target=none --arch=x86_64 --emit=image --load-addr=0x100000 \
         --stack-top=0x90000 "$PCI_SRC" -o "$PCI_IMG" 2>&1 | grep error | head -3 | sed 's/^/    /'
else
    pci_boot /tmp/pcidef_$$.log
    pci_bad=""
    pci_want /tmp/pcidef_$$.log \
        "DEV 00:00.0 8086:1237 cls=0600 hdr=00" \
        "DEV 00:01.0 8086:7000 cls=0601 hdr=80" \
        "DEV 00:01.1 8086:7010 cls=0101 hdr=00" \
        "DEV 00:01.3 8086:7113 cls=0680 hdr=00" \
        "DEV 00:02.0 1234:1111 cls=0300 hdr=00" \
        "DEV 00:03.0 8086:100e cls=0200 hdr=00" \
        "BAR 00:01.1 4 raw=0000c041 io addr=0000c040 next=5" \
        "BAR 00:02.0 0 raw=fd000008 addr=fd000000 next=1" \
        "FIND 8086:100e -> 000300" \
        "FIND 1234:9999 -> ffffffff" \
        "ADDR 80001800 80000b2c" \
        "DECODE 0000c04c fd000000 1fe000000"
    pci_n=$(grep -c '^DEV ' /tmp/pcidef_$$.log 2>/dev/null || echo 0)
    [ "$pci_n" = "6" ] || pci_bad="$pci_bad; $pci_n DEV lines, want 6"
    grep -q '^DEV 00:01.2' /tmp/pcidef_$$.log 2>/dev/null && pci_bad="$pci_bad; invented a function 2"
    if [ -z "$pci_bad" ]; then
        PASS=$((PASS + 1)); echo "  pci_enumerates_default_machine: PASS (6 devices, the 00:01.x function gap, address word, both BAR mask widths)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: pci_enumerates_default_machine (${pci_bad#; })"
    fi
    rm -f /tmp/pcidef_$$.log
fi

# Take two devices away. A baked list passes the row above and fails here.
TOTAL=$((TOTAL + 1))
if [ "$PCI_HAVE_QEMU" = "0" ] || [ "$PCI_BUILT" = "0" ]; then
    PASS=$((PASS + 1)); echo "  pci_tracks_the_machine: PASS (SKIPPED -- no qemu image)"
else
    pci_boot /tmp/pcicut_$$.log -vga none -net none
    pci_bad=""
    pci_want /tmp/pcicut_$$.log \
        "DEV 00:00.0 8086:1237 cls=0600 hdr=00" \
        "DEV 00:01.0 8086:7000 cls=0601 hdr=80" \
        "DEV 00:01.1 8086:7010 cls=0101 hdr=00" \
        "DEV 00:01.3 8086:7113 cls=0680 hdr=00" \
        "FIND 8086:100e -> ffffffff"
    grep -q '^DEV 00:02.0' /tmp/pcicut_$$.log 2>/dev/null && pci_bad="$pci_bad; VGA still reported under -vga none"
    grep -q '^DEV 00:03.0' /tmp/pcicut_$$.log 2>/dev/null && pci_bad="$pci_bad; e1000 still reported under -net none"
    pci_n=$(grep -c '^DEV ' /tmp/pcicut_$$.log 2>/dev/null || echo 0)
    [ "$pci_n" = "4" ] || pci_bad="$pci_bad; $pci_n DEV lines, want 4"
    if [ -z "$pci_bad" ]; then
        PASS=$((PASS + 1)); echo "  pci_tracks_the_machine: PASS (-vga none -net none: 4 devices, find returns PCI_NOT_FOUND)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: pci_tracks_the_machine (${pci_bad#; })"
    fi
    rm -f /tmp/pcicut_$$.log
fi

# The 64-bit BAR path would otherwise SHIP UNTESTED: every BAR on the default
# machine is 32-bit, so the two-slot walk never executes above. virtio-rng-pci
# appears at 00:04.0 with BAR4 = 0xfe00000c -- type bits 2:1 = 10b, so slot 5
# is its high half and pci_bar_next must skip to 6, not 5.
TOTAL=$((TOTAL + 1))
if [ "$PCI_HAVE_QEMU" = "0" ] || [ "$PCI_BUILT" = "0" ]; then
    PASS=$((PASS + 1)); echo "  pci_64bit_bar_consumes_two_slots: PASS (SKIPPED -- no qemu image)"
else
    pci_boot /tmp/pcirng_$$.log -device virtio-rng-pci
    pci_bad=""
    pci_want /tmp/pcirng_$$.log \
        "DEV 00:04.0 1af4:1005 cls=00ff hdr=00" \
        "BAR 00:04.0 4 raw=fe00000c mem64 addr=fe000000 next=6"
    grep -q '^BAR 00:04.0 5 ' /tmp/pcirng_$$.log 2>/dev/null && pci_bad="$pci_bad; reported the 64-bit BAR's high half as a BAR of its own"
    if [ -z "$pci_bad" ]; then
        PASS=$((PASS + 1)); echo "  pci_64bit_bar_consumes_two_slots: PASS (virtio-rng 00:04.0 BAR4 mem64, next=6)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: pci_64bit_bar_consumes_two_slots (${pci_bad#; })"
    fi
    rm -f /tmp/pcirng_$$.log
fi
rm -f "$PCI_SRC" "$PCI_IMG"

# The operand-shape exclusion list is duplicated verbatim across several
# functions in ir.kr, and any divergence between the copies miscompiles.
# docs/IR_REFERENCE.md §14 tells implementers to edit every one of them, so the
# doc's count and the source must agree -- it said "five" while the source had
# SEVEN, and the two it omitted (ir_compute_liveness, ir_x86_xmm_mark_unsafe)
# are in the liveness/interference path. Following it would have shipped a
# use-after-free of a register.
#
# Pin the count in BOTH places. If you add or remove a copy, this row tells you
# to update the doc in the same commit.
#
# The pattern is anchored to the WHOLE line (^ws if <chain> {$), not a
# substring. A substring count stays at 7 when one copy is extended in place
# ("|| op == 150" appended, or a new op prepended before 72) -- proven by
# injecting exactly that: the old grep -c still said 7 while the copies
# disagreed, which is the miscompile this row exists to pin. Anchoring means
# ANY textual divergence in a copy drops the count and fails the row.
TOTAL=$((TOTAL + 1))
opshape_pat='^[[:space:]]*if op == 72 \|\| op == 76 \|\| op == 83 \|\| op == 93 \|\| op == 98 \|\| op == 148 \{[[:space:]]*$'
opshape_src=$(grep -cE "$opshape_pat" "$DIR/../src/ir.kr")
opshape_doc=$(grep -c 'EIGHT separate times' "$DIR/../docs/IR_REFERENCE.md")
if [ "$opshape_src" = "8" ] && [ "$opshape_doc" = "1" ]; then
    PASS=$((PASS + 1)); echo "  ir_operand_shape_copies_pinned: PASS (8 verbatim copies, doc agrees)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: ir_operand_shape_copies_pinned (src has $opshape_src verbatim copies, want 8; docs/IR_REFERENCE.md §14 says EIGHT: $opshape_doc match)"
    echo "  if a copy no longer matches verbatim, the copies have diverged (that miscompiles);"
    echo "  if you changed the number of copies, update docs/IR_REFERENCE.md §14 in the same commit"
fi

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
# Hermetic on purpose. This used to write the source to /tmp and
# `import "std/io.kr"`, which cannot resolve relatively from /tmp and fell back
# to the SYSTEM search paths (/usr/local/share/kernrift/ etc). Those exist on a
# developer box with KernRift installed but not in CI — so in CI the import
# silently failed. The test still passed there because `println` is a BUILT-IN,
# not a symbol from io.kr: the program compiled and printed the expected text
# with the import having done nothing at all. It only surfaced once a failed
# import began aborting the compile instead of being ignored.
# Now it imports a module it creates itself and calls a function that exists
# ONLY in that module, so the assertion cannot be satisfied unless the import
# genuinely resolved.
IMPC_DIR=$(mktemp -d /tmp/krc_impc_XXXXXX)
cat > "$IMPC_DIR/impmod.kr" <<'KREOF'
fn imp_after_comment_helper() -> uint64 { return 7 }
KREOF
cat > "$IMPC_DIR/impmain.kr" <<'KREOF'
// leading comment should not break imports
import "impmod.kr"
fn main() { exit(imp_after_comment_helper() + 35) }
KREOF
if $KRC $KRC_FLAGS "$IMPC_DIR/impmain.kr" -o "$IMPC_DIR/impbin" > /dev/null 2>&1; then
    chmod +x "$IMPC_DIR/impbin"
    "$IMPC_DIR/impbin" > /dev/null 2>&1
    imp_ec=$?
    if [ "$imp_ec" -eq 42 ]; then
        PASS=$((PASS + 1))
        echo "  import_after_comment: PASS (imported symbol resolved, exit 42)"
    else
        FAIL=$((FAIL + 1))
        echo "  import_after_comment: FAIL (exit $imp_ec, expected 42)"
    fi
else
    FAIL=$((FAIL + 1))
    echo "  import_after_comment: FAIL (compile)"
fi
rm -rf "$IMPC_DIR"

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

echo ""
echo "--- extern fn: unresolved refused for executable emit modes (issue: silent wrong answer) ---"
# An `extern fn` that is never defined and never linked used to produce a
# WORKING BINARY THAT RETURNS A WRONG ANSWER, differently per backend, with
# no diagnostic: the IR backend synthesized a stub (silently returns 0), the
# legacy backend fell through with the argument still in the return register
# (silently returns the argument). Both are exit 0. Fixed: unresolved +
# CALLED extern fn is now a hard compile-time error for every emit mode that
# produces a directly-executable artifact, and --emit=obj (the mode the
# feature is actually for -- resolved by a real system linker) keeps
# accepting it.
TOTAL=$((TOTAL + 1))
cat > /tmp/krc_extir_$$.kr <<'KREOF'
extern fn missing_thing(uint64 x) -> uint64
fn main() {
    uint64 r = missing_thing(7)
    exit(r)
}
KREOF
if $KRC $KRC_FLAGS /tmp/krc_extir_$$.kr -o /tmp/krc_extir_bin_$$ > /dev/null 2>/tmp/krc_extir_err_$$; then
    echo "FAIL: extern_unresolved_refused_ir (should not compile)"
    FAIL=$((FAIL + 1))
elif [ -e /tmp/krc_extir_bin_$$ ]; then
    echo "FAIL: extern_unresolved_refused_ir (refused but left an artifact on disk)"
    FAIL=$((FAIL + 1))
elif grep -q "is never defined and this emit mode produces" /tmp/krc_extir_err_$$; then
    PASS=$((PASS + 1))
    echo "  extern_unresolved_refused_ir: PASS"
else
    echo "FAIL: extern_unresolved_refused_ir (wrong/missing diagnostic)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_extir_$$.kr /tmp/krc_extir_bin_$$ /tmp/krc_extir_err_$$

TOTAL=$((TOTAL + 1))
cat > /tmp/krc_extref_$$.kr <<'KREOF'
extern fn missing_thing(uint64 x) -> uint64
fn main() {
    uint64 r = missing_thing(7)
    exit(r)
}
KREOF
# --legacy has its own emission path (falls through with the arg still in
# the return register instead of the IR backend's synthesised-stub-returns-0)
# -- verified separately rather than assumed covered by the same check.
if $KRC $KRC_FLAGS --legacy /tmp/krc_extref_$$.kr -o /tmp/krc_extref_bin_$$ > /dev/null 2>/tmp/krc_extref_err_$$; then
    echo "FAIL: extern_unresolved_refused_legacy (should not compile)"
    FAIL=$((FAIL + 1))
elif [ -e /tmp/krc_extref_bin_$$ ]; then
    echo "FAIL: extern_unresolved_refused_legacy (refused but left an artifact on disk)"
    FAIL=$((FAIL + 1))
elif grep -q "is never defined and this emit mode produces" /tmp/krc_extref_err_$$; then
    PASS=$((PASS + 1))
    echo "  extern_unresolved_refused_legacy: PASS"
else
    echo "FAIL: extern_unresolved_refused_legacy (wrong/missing diagnostic)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_extref_$$.kr /tmp/krc_extref_bin_$$ /tmp/krc_extref_err_$$

TOTAL=$((TOTAL + 1))
# Same unresolved extern, but --emit=obj is the mode the feature exists for
# (resolved by a later system linker, not by krc2) -- must keep succeeding.
cat > /tmp/krc_extobj_$$.kr <<'KREOF'
extern fn missing_thing(uint64 x) -> uint64
fn main() {
    uint64 r = missing_thing(7)
    exit(r)
}
KREOF
if $KRC $KRC_FLAGS --emit=obj /tmp/krc_extobj_$$.kr -o /tmp/krc_extobj_$$.o > /dev/null 2>&1 \
   && [ -e /tmp/krc_extobj_$$.o ]; then
    PASS=$((PASS + 1))
    echo "  extern_unresolved_obj_still_succeeds: PASS"
else
    echo "FAIL: extern_unresolved_obj_still_succeeds (--emit=obj must keep accepting unresolved extern fn)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_extobj_$$.kr /tmp/krc_extobj_$$.o

# A RESOLVED extern (the language's actual extern-fn workflow: declare,
# --emit=obj, link with the platform linker) must keep working end to end,
# and must keep working when the object was produced by EITHER backend.
if [ "$HOST_M" = "x86_64" ] || [ "$HOST_M" = "amd64" ]; then
    if command -v gcc > /dev/null 2>&1; then
        for BACKEND_FLAG in "" "--legacy"; do
            TOTAL=$((TOTAL + 1))
            LABEL="extern_resolved_via_obj_link${BACKEND_FLAG:+_legacy}"
            cat > /tmp/krc_extres_$$.kr <<'KREOF'
extern fn strlen(u64 s) -> u64
extern fn write(u64 fd, u64 buf, u64 len) -> u64
fn main() {
    u64 msg = "extern_resolved_ok\n"
    write(1, msg, strlen(msg))
    exit(0)
}
KREOF
            if $KRC $KRC_FLAGS $BACKEND_FLAG --emit=obj /tmp/krc_extres_$$.kr -o /tmp/krc_extres_$$.o > /dev/null 2>&1 \
               && gcc /tmp/krc_extres_$$.o -o /tmp/krc_extres_bin_$$ -no-pie > /dev/null 2>&1; then
                got=$(/tmp/krc_extres_bin_$$ 2>/dev/null)
                if [ "$got" = "extern_resolved_ok" ]; then
                    PASS=$((PASS + 1))
                    echo "  $LABEL: PASS"
                else
                    FAIL=$((FAIL + 1))
                    echo "  $LABEL: FAIL (got: $got)"
                fi
            else
                FAIL=$((FAIL + 1))
                echo "  $LABEL: FAIL (compile/link failed)"
            fi
            rm -f /tmp/krc_extres_$$.kr /tmp/krc_extres_$$.o /tmp/krc_extres_bin_$$
        done
    else
        echo "  extern_resolved_via_obj_link: SKIP (gcc not available)"
        echo "  extern_resolved_via_obj_link_legacy: SKIP (gcc not available)"
    fi
else
    echo "  extern_resolved_via_obj_link: SKIP (non-x86_64 host toolchain)"
    echo "  extern_resolved_via_obj_link_legacy: SKIP (non-x86_64 host toolchain)"
fi

# --emit=obj is where a partial alloc fix would hide: main.kr selects the
# LEGACY codegen for --emit=obj and --emit=lkm with no --legacy on the command
# line, so `krc` could return 0 from a failed alloc while `krc --emit=obj`
# still segfaulted. Link and RUN, not compile-only -- the defect is in the
# emitted bytes, not in whether the object builds. MEASURED before the fix:
# this program exited 139.
if [ "$HOST_M" = "x86_64" ] || [ "$HOST_M" = "amd64" ]; then
    if command -v gcc > /dev/null 2>&1; then
        TOTAL=$((TOTAL + 1))
        cat > /tmp/krc_aobj_$$.kr <<'KREOF'
fn main() {
    u64 p = alloc(0xFFFFFFFFFFFF0000)
    if p != 0 { exit(9) }
    dealloc(p)
    dealloc(0)
    u64 q = alloc(1000)
    if q == 0 { exit(1) }
    unsafe { *(q as uint64) = 3735928559 }
    u64 v = 0
    unsafe { *(q as uint64) -> v }
    if v != 3735928559 { exit(2) }
    dealloc(q)
    exit(42)
}
KREOF
        if $KRC $KRC_FLAGS --emit=obj /tmp/krc_aobj_$$.kr -o /tmp/krc_aobj_$$.o > /dev/null 2>&1 \
           && gcc -nostdlib -static /tmp/krc_aobj_$$.o -o /tmp/krc_aobj_bin_$$ > /dev/null 2>&1; then
            /tmp/krc_aobj_bin_$$ > /dev/null 2>&1
            aobj_got=$?
            if [ "$aobj_got" = "42" ]; then
                PASS=$((PASS + 1))
                echo "  alloc_oom_emit_obj: PASS"
            else
                FAIL=$((FAIL + 1))
                echo "  alloc_oom_emit_obj: FAIL (expected 42, got $aobj_got)"
            fi
        else
            FAIL=$((FAIL + 1))
            echo "  alloc_oom_emit_obj: FAIL (compile/link failed)"
        fi
        rm -f /tmp/krc_aobj_$$.kr /tmp/krc_aobj_$$.o /tmp/krc_aobj_bin_$$
    else
        echo "  alloc_oom_emit_obj: SKIP (gcc not available)"
    fi
else
    echo "  alloc_oom_emit_obj: SKIP (non-x86_64 host toolchain)"
fi

# Regression: a normal program with no extern fn at all must be completely
# unaffected by the new check, on both backends.
run_test "extern_refusal_no_false_positive_ir" 'fn add(uint64 a, uint64 b) -> uint64 { return a + b }
fn main() { exit(add(3, 4)) }' 7
TOTAL=$((TOTAL + 1))
cat > /tmp/krc_extnofp_$$.kr <<'KREOF'
fn add(uint64 a, uint64 b) -> uint64 { return a + b }
fn main() { exit(add(3, 4)) }
KREOF
if $KRC $KRC_FLAGS --legacy /tmp/krc_extnofp_$$.kr -o /tmp/krc_extnofp_bin_$$ > /dev/null 2>&1; then
    /tmp/krc_extnofp_bin_$$
    rc=$?
    if [ "$rc" = "7" ]; then
        PASS=$((PASS + 1))
        echo "  extern_refusal_no_false_positive_legacy: PASS"
    else
        echo "FAIL: extern_refusal_no_false_positive_legacy (got exit $rc, want 7)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: extern_refusal_no_false_positive_legacy (should compile)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_extnofp_$$.kr /tmp/krc_extnofp_bin_$$

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

# --- Struct arg by-value uniformity (fix/struct-param-writes) ---
# By-value must hold for EVERY struct-lvalue argument form, not just bare
# Idents. The IR path used to copy only Ident args: a nested-struct field
# arg leaked BY REFERENCE (callee writes persisted), and a struct array
# element arg was lowered as an oversized IR_LOAD (garbage pointer,
# segfault at the callee's first field write).
run_test "struct_arg_nested_byval" 'struct I { uint64 a; uint64 b }
struct O { I inn; uint64 z }
fn poke(I c) -> uint64 { c.a = 99; return c.a }
fn main() {
    O o; o.inn.a = 42; o.inn.b = 2
    uint64 r = poke(o.inn)
    exit(o.inn.a)
}' 42

run_test "struct_arg_elem_byval" 'struct P { uint64 x; uint64 y }
fn poke(P c) -> uint64 { c.x = 99; return c.x }
fn main() {
    P[3] arr
    arr[1].x = 42; arr[1].y = 2
    uint64 r = poke(arr[1])
    exit(arr[1].x)
}' 42

# Data integrity: the callee must see the element/field CONTENTS (the
# legacy path used to load 8 garbage bytes for a struct-sized element).
run_test "struct_arg_elem_data" 'struct P { uint64 x; uint64 y }
fn sum(P c) -> uint64 { return c.x + c.y }
fn main() {
    P[3] arr
    arr[2].x = 30; arr[2].y = 12
    exit(sum(arr[2]))
}' 42

run_test "struct_arg_nested_data" 'struct I { uint64 a; uint64 b }
struct O { I inn; uint64 z }
fn sum(I c) -> uint64 { return c.a + c.b }
fn main() {
    O o; o.inn.a = 40; o.inn.b = 2; o.z = 9
    exit(sum(o.inn))
}' 42

# --- Method `self` is BY REFERENCE (LANGUAGE.md §7) ---
# `fn Struct.m(Struct self)` receives self as a reference to the caller''s
# storage: writes through self must persist. This regressed to a silent
# by-value copy when struct-by-value passing landed (v2.7.0).
run_test "method_self_mutation" 'struct P { uint64 x; uint64 y }
fn P.bump(P self) { self.x = 42 }
fn main() {
    P p; p.x = 1; p.y = 2
    p.bump()
    exit(p.x)
}' 42

run_test "method_self_mutation_arg" 'struct P { uint64 x; uint64 y }
fn P.setx(P self, uint64 v) { self.x = v }
fn P.getx(P self) -> uint64 { return self.x }
fn main() {
    P p; p.x = 1
    p.setx(41)
    exit(p.getx() + 1)
}' 42

# Nested-field receiver: w.p.setx(...) mutates the inner struct in place.
run_test "method_self_nested_recv" 'struct P { uint64 x; uint64 y }
struct W { P p; uint64 z }
fn P.setx(P self, uint64 v) { self.x = v }
fn main() {
    W w; w.p.x = 1
    w.p.setx(42)
    exit(w.p.x)
}' 42

# Array-element receiver: arr[i].setx(...) used to parse as a bare field
# access with the argument list silently DROPPED (no call, no diagnostic).
run_test "method_self_elem_recv" 'struct P { uint64 x; uint64 y }
fn P.setx(P self, uint64 v) { self.x = v }
fn main() {
    P[3] arr
    arr[2].x = 1
    arr[2].setx(42)
    exit(arr[2].x)
}' 42

# Semantics locks (pass before and after the fix — they pin the spec):
# a HEAP-backed struct variable passed as a plain param is still COPIED
# (value semantics do not depend on where the struct lives), and plain
# params never alias even when re-passed through a second call.
run_test "struct_arg_heap_byval" 'struct P { uint64 x; uint64 y }
fn poke(P c) -> uint64 { c.x = 99; return c.x }
fn main() {
    P h = alloc(16)
    h.x = 42; h.y = 2
    uint64 r = poke(h)
    exit(h.x)
}' 42

run_test "struct_arg_chain_byval" 'struct P { uint64 x; uint64 y }
fn inner(P c) { c.x = 99 }
fn outer(P c) -> uint64 { inner(c); return c.x }
fn main() {
    P p; p.x = 42; p.y = 2
    uint64 r = outer(p)
    exit(p.x)
}' 42

# Struct VarDecl initialized from an array element rides the same
# address+tracker contract (used to segfault: garbage oversized load).
run_test "struct_decl_from_elem" 'struct P { uint64 x; uint64 y }
fn main() {
    P[3] arr
    arr[1].x = 40; arr[1].y = 2
    P c = arr[1]
    c.x = c.x + 2
    exit(c.x + arr[1].y - 2 + (arr[1].x - 40))
}' 42

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
# ExprStmt after a terminator. These two were SILENTLY MISSED: the diagnostic
# is dropped when no anchor token is found, and an ExprStmt carries none of
# its own -- the token lives on the child expression (a Call's callee). So a
# bare call or println after a return produced no warning at all, while a
# declaration, assignment, if, while or return in the same position did.
run_warning_check "diag_unreachable_bare_call" 'fn g() { }
fn foo() -> uint64 { return 1  g()  return 2 }
fn main() { exit(0) }' "unreachable code"
run_warning_check "diag_unreachable_println" 'fn foo() -> uint64 { return 1  println(9)  return 2 }
fn main() { exit(0) }' "unreachable code"
run_warning_check "diag_unreachable_call_after_exit" 'fn g() { }
fn main() { exit(0)  g() }' "unreachable code"
# Code after an infinite loop. `loop { }` desugars to `while 1 == 1`, so
# nothing after it can run unless the body breaks. return/exit inside the body
# do not rescue the tail -- they leave the function entirely.
run_warning_check "diag_unreachable_after_loop" 'fn main() { loop { }  u64 d = 1 }' "unreachable code"
run_warning_check "diag_unreachable_after_loop_body" 'fn main() { u64 i = 0  loop { i = i + 1 }  u64 d = 1 }' "unreachable code"
# A break belonging to an INNER loop does not let the outer one exit.
run_warning_check "diag_unreachable_after_loop_inner_break" 'fn main() { loop { while 1 == 1 { break } }  u64 d = 1 }' "unreachable code"

# A function ending in an infinite loop cannot fall off the end, so the
# missing-return check must not fire. --target=none tells users to "end main
# with `loop { }`", and this check rejected exactly that whenever main had a
# return type -- the compiler refusing the idiom it recommends.
TOTAL=$((TOTAL + 1))
MRET_OK=1
mret() { # <name> <src> <want-error-count>
    printf '%s\n' "$2" > "$DIR/../mret_$$.kr"
    local n
    n=$($KRC $KRC_FLAGS "$DIR/../mret_$$.kr" -o /tmp/krc_mret_$$ 2>&1 | grep -c 'may not return')
    [ "$n" = "$3" ] || { MRET_OK=0; echo "  $1: got $n missing-return errors, want $3"; }
    rm -f "$DIR/../mret_$$.kr" /tmp/krc_mret_$$
}
mret "main->u32 ending in loop{}" 'fn main() -> uint32 { u64 x = 1  loop { } }' 0
mret "helper->u64 ending in loop{}" 'fn h() -> u64 { loop { } }
fn main() { exit(0) }' 0
# The check must NOT be weakened: each of these still has a real path that
# falls off the end.
mret "no return at all still errors" 'fn h() -> u64 { u64 x = 1 }
fn main() { exit(0) }' 1
mret "loop WITH break still errors" 'fn h() -> u64 { loop { break } }
fn main() { exit(0) }' 1
mret "if without else still errors" 'fn h(u64 a) -> u64 { if a > 0 { return 1 } }
fn main() { exit(0) }' 1
if [ "$MRET_OK" = "1" ]; then
    PASS=$((PASS + 1)); echo "  missing_return_infinite_loop: PASS (loop{} satisfies it; check not weakened)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: missing_return_infinite_loop"
fi

# examples/tutorial-uart must keep building. docs/tutorial-uart-driver.md walks
# through these two files and tells the reader to `make run` in that directory;
# the previous version of that claim pointed at a directory which did not exist
# at all. Nothing else in the suite compiles anything under examples/, so
# without this row the example can rot silently and the tutorial goes stale
# with it.
#
# Compile-only and arch-pinned: the artifact is inspected, not executed.
TOTAL=$((TOTAL + 1))
UEX_DIR="$DIR/../examples/tutorial-uart"
UEX_IMG="/tmp/krc_uart_example_$$.img"
if [ ! -f "$UEX_DIR/main.kr" ] || [ ! -f "$UEX_DIR/uart.kr" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: tutorial_uart_example_builds (source files missing)"
# NOTE: do not `cd` into the example directory. `make test` builds its wrapper
# as `exec ./build/krc2 ...` with a RELATIVE path, so any cd breaks $KRC.
# Imports resolve relative to the importing FILE, so an absolute main.kr still
# finds uart.kr beside it.
elif ! $KRC --target=none --arch=arm64 --emit=image --image-header \
            --load-addr=0x40080000 --stack-top=0x40200000 \
            "$UEX_DIR/main.kr" -o "$UEX_IMG" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1)); echo "FAIL: tutorial_uart_example_builds (compile failed)"
else
    # arm64 Linux Image magic 0x644d5241 lives at offset 56.
    uex_magic=$(od -An -tx4 -j56 -N4 "$UEX_IMG" 2>/dev/null | tr -d ' \n')
    if [ "$uex_magic" = "644d5241" ]; then
        PASS=$((PASS + 1)); echo "  tutorial_uart_example_builds: PASS (arm64 Image, magic ok)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: tutorial_uart_example_builds (magic '$uex_magic', want 644d5241)"
    fi
fi
rm -f "$UEX_IMG"

# docs/IR_REFERENCE.md cites src/*.kr by line number, and those rot silently:
# at the last audit 146 of 153 pointed at unrelated code while still being IN
# RANGE, so they read as valid. This checks each citation still points at the
# same source line it was recorded against, and names the ones that moved.
#
# Regenerate after editing src/ or the doc's citations:
#   python3 scripts/gen-ir-reference-citations.py
TOTAL=$((TOTAL + 1))
CITE_MANIFEST="$DIR/ir_reference_citations.txt"
if [ ! -f "$CITE_MANIFEST" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: ir_reference_citations (manifest missing)"
else
    cite_bad=$(python3 - "$CITE_MANIFEST" "$DIR/.." <<'PYEOF'
import hashlib, sys, os
manifest, root = sys.argv[1], sys.argv[2]
cache, bad = {}, []
for raw in open(manifest):
    raw = raw.strip()
    if not raw or raw.startswith("#"):
        continue
    cite, want = raw.split()
    path, num = cite.rsplit(":", 1)
    if path not in cache:
        p = os.path.join(root, path)
        cache[path] = open(p).read().split("\n") if os.path.exists(p) else []
    lines, i = cache[path], int(num)
    got = hashlib.sha1(lines[i-1].strip().encode()).hexdigest()[:12] if i-1 < len(lines) else "MISSING"
    if got != want:
        bad.append(cite)
print(" ".join(bad[:6]) + (f" (+{len(bad)-6} more)" if len(bad) > 6 else ""))
PYEOF
)
    if [ -z "$cite_bad" ]; then
        cite_n=$(grep -vc '^#' "$CITE_MANIFEST")
        PASS=$((PASS + 1)); echo "  ir_reference_citations: PASS ($cite_n citations still resolve)"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: ir_reference_citations (moved: $cite_bad)"
        echo "  fix the citations in docs/IR_REFERENCE.md, then:"
        echo "    python3 scripts/gen-ir-reference-citations.py"
    fi
fi

# examples/tutorial-btree ships the page manager from docs/tutorial-btree.md
# §2 -- the mmap-backed persistence the whole tutorial rests on. The stdlib has
# no open/mmap/msync, so it goes through syscall_raw with per-arch numbers;
# that is exactly the kind of code that rots silently.
#
# This row EXECUTES (it writes and re-reads a real file), so it builds at the
# host arch via $RUN_ARCH rather than naming one.
TOTAL=$((TOTAL + 1))
BEX_DIR="$DIR/../examples/tutorial-btree"
BEX_BIN="/tmp/krc_btree_example_$$"
if [ ! -f "$BEX_DIR/main.kr" ] || [ ! -f "$BEX_DIR/pager.kr" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: tutorial_btree_example_runs (source files missing)"
elif ! $KRC --arch="$RUN_ARCH" "$BEX_DIR/main.kr" -o "$BEX_BIN" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1)); echo "FAIL: tutorial_btree_example_runs (compile failed)"
else
    "$BEX_BIN" >/dev/null 2>&1
    bex_rc=$?
    if [ "$bex_rc" = "0" ]; then
        PASS=$((PASS + 1)); echo "  tutorial_btree_example_runs: PASS (magic + value survive msync and reopen)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: tutorial_btree_example_runs (exit $bex_rc; 1=open 2=msync 3=reopen 4=magic 5=value)"
    fi
fi
rm -f "$BEX_BIN" /tmp/kr_tutorial_btree.db

# `krc lc --ci` applies a DEFAULT fitness gate of 50, so it does not fail on
# every pattern. docs/LIVING_COMPILER.md said it did, which is the dangerous
# direction: anyone wiring the bare form into CI gets a gate that silently
# ignores everything below 50. Pin the default in the source AND that the doc
# states it, so the two cannot drift apart.
TOTAL=$((TOTAL + 1))
lc_src_default=$(grep -c 'if gate_threshold == 0 { gate_threshold = 50 }' "$DIR/../src/main.kr")
# Match a phrase that cannot be split by prose wrapping -- the first attempt
# here grepped for a sentence that the doc wraps mid-phrase, and reported the
# doc silent when it was not.
lc_doc_states=$(grep -c 'alone gates at fitness \*\*50\*\*' "$DIR/../docs/LIVING_COMPILER.md")
if [ "$lc_src_default" = "1" ] && [ "$lc_doc_states" = "1" ]; then
    PASS=$((PASS + 1)); echo "  lc_ci_default_gate_pinned: PASS (source gates at 50, doc says so)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: lc_ci_default_gate_pinned (src default-50 sites=$lc_src_default, doc mentions=$lc_doc_states)"
    echo "  if you changed the --ci default gate, update docs/LIVING_COMPILER.md in the same commit"
fi

# And the behaviour itself: a file whose only pattern is below the default must
# pass bare --ci and fail --min-fitness=1. std/alloc.kr currently reports one
# unchecked_call at 44; if the stdlib changes such that it no longer does, this
# row skips rather than failing on an unrelated edit.
TOTAL=$((TOTAL + 1))
lc_fits=$($KRC lc "$DIR/../std/alloc.kr" 2>/dev/null | grep -oE 'fitness: [0-9]+' | grep -oE '[0-9]+')
lc_max=0
for f in $lc_fits; do [ "$f" -gt "$lc_max" ] && lc_max=$f; done
if [ -z "$lc_fits" ] || [ "$lc_max" -ge 50 ]; then
    PASS=$((PASS + 1)); echo "  lc_ci_gate_behaviour: SKIP (std/alloc.kr has no sub-50-only pattern; max=$lc_max)"
else
    $KRC lc --ci "$DIR/../std/alloc.kr" >/dev/null 2>&1; lc_bare=$?
    $KRC lc --ci --min-fitness=1 "$DIR/../std/alloc.kr" >/dev/null 2>&1; lc_all=$?
    if [ "$lc_bare" = "0" ] && [ "$lc_all" = "1" ]; then
        PASS=$((PASS + 1)); echo "  lc_ci_gate_behaviour: PASS (bare --ci passes a fitness-$lc_max pattern, --min-fitness=1 catches it)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: lc_ci_gate_behaviour (bare=$lc_bare want 0, min1=$lc_all want 1)"
    fi
fi

# False-positive guard. Widening the anchor lookup must not make REACHABLE
# expression statements warn -- a call before the terminator, a call inside a
# conditional, and calls in a loop body are all live code.
TOTAL=$((TOTAL + 1))
UR_FP_OK=1
UR_FP_N=0
ur_fp() {
    printf '%s\n' "$2" > "$DIR/../ur_fp_$$.kr"
    local n
    n=$($KRC $KRC_FLAGS "$DIR/../ur_fp_$$.kr" -o /tmp/krc_urfp_$$ 2>&1 | grep -c 'unreachable')
    UR_FP_N=$((UR_FP_N + 1))
    [ "$n" = "0" ] || { UR_FP_OK=0; echo "  false positive in '$1' ($n warnings)"; }
    rm -f "$DIR/../ur_fp_$$.kr" /tmp/krc_urfp_$$
}
ur_fp "call then return" 'fn g() { }
fn f() -> u64 { g()  return 1 }
fn main() { exit(f()) }'
ur_fp "call inside if" 'fn g() { }
fn f() -> u64 { if 1 == 1 { g() }  return 1 }
fn main() { exit(f()) }'
ur_fp "calls in loop body" 'fn g() { }
fn main() { u64 i = 0  while i < 3 { g()  i = i + 1 }  exit(0) }'
ur_fp "println then exit" 'fn main() { println(1)  exit(0) }'
# An infinite loop WITH a break does not terminate the enclosing block.
ur_fp "loop with break" 'fn main() { loop { break }  u64 d = 1  exit(0) }'
ur_fp "loop, break inside if" 'fn main() { u64 i = 0  loop { if i > 0 { break }  i = i + 1 }  exit(0) }'
ur_fp "loop, break in else arm" 'fn main() { u64 i = 0  loop { if i > 0 { i = i + 1 } else { break } }  exit(0) }'
# The break hides in a statement kind the walker does not model (match). It
# must bail out rather than assume the loop is infinite -- this is the case
# that would turn a wrong answer into a warning on live code.
ur_fp "loop, break inside match" 'fn main() { u64 i = 0  loop { match i { 0 => { break } _ => { i = i + 1 } } }  exit(0) }'
ur_fp "ordinary while, real condition" 'fn main() { u64 i = 0  while i < 3 { i = i + 1 }  u64 d = 1  exit(0) }'
# Derive the count rather than asserting it, so adding a shape above cannot
# leave this line claiming a number it no longer checks.
if [ "$UR_FP_N" -lt 9 ]; then
    UR_FP_OK=0; echo "  only $UR_FP_N false-positive shapes ran (expected at least 9)"
fi
if [ "$UR_FP_OK" = "1" ]; then
    PASS=$((PASS + 1)); echo "  diag_unreachable_no_false_positives: PASS ($UR_FP_N reachable shapes stay quiet)"
else
    FAIL=$((FAIL + 1)); echo "FAIL: diag_unreachable_no_false_positives"
fi
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

# --- the inliner must traverse an Index node's AST children, not its token ---
# Regression: inline_walk's Index (kind 37) case walked `data1`, which for that
# kind is the array NAME TOKEN, and handed it to a function that indexes the
# AST arena -- a token index used as a node index. It never faulted (both
# arenas are 524288 entries, so the number is always in bounds) and it never
# produced a wrong answer (a body containing a call is not inlinable, so the
# only context-dependent guard -- the recursion check -- can never be reached
# through that edge). It simply walked an unrelated subtree while the field
# that DOES hold a node, data2 -- the stored value of `a[i] = <expr>` -- went
# unvisited, so no call on the right-hand side of an indexed assignment was
# ever offered to the inliner.
#
# `a[3] = addone(6)` is therefore the discriminating input: with the bug the IR
# for main still contains a `call`, with the fix the body is spliced in. The
# row also asserts the program's VALUE, since an inliner change that produced
# the right IR shape and the wrong arithmetic would otherwise pass.
echo ""
echo "--- inliner walks Index children ---"
TOTAL=$((TOTAL + 1))
INLIDX_OK=1
cat > "$REPO_ROOT/test_tmp_inlidx_$$.kr" <<'INLIDX'
static u64[8] a
fn addone(uint64 x) -> uint64 { return x + 1 }
fn main() {
    a[3] = addone(6)
    exit(a[3])
}
INLIDX
INLIDX_IR=$($KRC --emit=ir --arch="$RUN_ARCH" "$REPO_ROOT/test_tmp_inlidx_$$.kr" 2>/dev/null)
# Sanity first: a dump that lost its `store` is not evidence of anything.
echo "$INLIDX_IR" | grep -q "store" || { INLIDX_OK=0; echo "  no store in IR dump -- dump is not what we think"; }
if echo "$INLIDX_IR" | grep -q "call @"; then
    INLIDX_OK=0
    echo "  addone( ) still called: the indexed-assign RHS was not walked"
fi
for _fl in "" "--legacy"; do
    if $KRC --arch="$RUN_ARCH" $_fl "$REPO_ROOT/test_tmp_inlidx_$$.kr" -o "/tmp/krc_inlidx_$$" >/dev/null 2>&1; then
        "/tmp/krc_inlidx_$$"; _rc=$?
        [ "$_rc" = "7" ] || { INLIDX_OK=0; echo "  ${_fl:-IR}: got $_rc, want 7"; }
    else
        INLIDX_OK=0; echo "  ${_fl:-IR}: COMPILE FAILED"
    fi
    rm -f "/tmp/krc_inlidx_$$"
done
if [ "$INLIDX_OK" = "1" ]; then
    PASS=$((PASS + 1))
    echo "  inliner_walks_index_children: PASS"
else
    echo "FAIL: inliner_walks_index_children"
    FAIL=$((FAIL + 1))
fi
rm -f "$REPO_ROOT/test_tmp_inlidx_$$.kr"

# --- declared-type signedness must not be inherited from the initialiser ---
# Regression: `u32 ux = <i32>` inherited the RHS signed flag, so ux (and
# everything derived from it) used SIGNED ops -- `ux >> 1` became an
# ARITHMETIC shift and comparisons became signed. Invisible on x86_64/arm64,
# where a u32 occupies a 64-bit slot and never reaches the sign bit, but
# silently wrong on the 32-bit backends: 0x80000000 >> 31 gave 0xFFFFFFFF
# instead of 1. Checked in the IR, because a host run cannot see it.
TOTAL=$((TOTAL + 1))
printf 'fn main() -> uint64 {\n    i32 acc = 0 - 5\n    u32 ux = acc\n    u32 sh = ux >> 1\n    return sh\n}\n' > "$REPO_ROOT/test_tmp_$$.kr"
SGN_OUT=$($KRC --emit=ir --arch=x86_64 "$REPO_ROOT/test_tmp_$$.kr" 2>/dev/null)
rm -f "$REPO_ROOT/test_tmp_$$.kr"
# and the converse: a genuinely signed i32 shift must still be arithmetic
printf 'fn main() -> uint64 {\n    i32 a = 0 - 8\n    i32 b = a >> 1\n    return 0\n}\n' > "$REPO_ROOT/test_tmp_$$.kr"
SGN_OUT2=$($KRC --emit=ir --arch=x86_64 "$REPO_ROOT/test_tmp_$$.kr" 2>/dev/null)
rm -f "$REPO_ROOT/test_tmp_$$.kr"
if echo "$SGN_OUT" | grep -q "shr" && ! echo "$SGN_OUT" | grep -q "sar" \
   && echo "$SGN_OUT2" | grep -q "sar"; then
    PASS=$((PASS + 1))
    echo "  decl_type_signedness: PASS (u32 from i32 -> shr; i32 -> sar)"
else
    echo "FAIL: decl_type_signedness (u32-from-i32 shift: $(echo "$SGN_OUT" | grep -oE 'shr|sar' | head -1), i32 shift: $(echo "$SGN_OUT2" | grep -oE 'shr|sar' | head -1))"
    FAIL=$((FAIL + 1))
fi

# --- same, on the ASSIGNMENT path: a store cannot retype the variable ---
# `u32 ux = 7; ux = <i32>` let the rvalue's signed flag through, so ux became
# signed from that point on. The LHS local's flag is authoritative in both
# directions now. Second half checks the direction that must NOT break:
# a signed local stays signed across `x = x - n`, so `x < 0` keeps SCMP.
TOTAL=$((TOTAL + 1))
printf 'fn main() -> uint64 {\n    i32 acc = 0 - 5\n    u32 ux = 7\n    ux = acc\n    u32 sh = ux >> 1\n    return sh\n}\n' > "$REPO_ROOT/test_tmp_$$.kr"
ASG_OUT=$($KRC --emit=ir --arch=x86_64 "$REPO_ROOT/test_tmp_$$.kr" 2>/dev/null)
printf 'fn main() -> uint64 {\n    i64 x = 3\n    x = x - 5\n    if x < 0 { return 1 }\n    return 0\n}\n' > "$REPO_ROOT/test_tmp_$$.kr"
ASG_OUT2=$($KRC --emit=ir --arch=x86_64 "$REPO_ROOT/test_tmp_$$.kr" 2>/dev/null)
rm -f "$REPO_ROOT/test_tmp_$$.kr"
if echo "$ASG_OUT" | grep -q "shr" && ! echo "$ASG_OUT" | grep -q "sar" \
   && echo "$ASG_OUT2" | grep -qi "scmp"; then
    PASS=$((PASS + 1))
    echo "  assign_type_signedness: PASS (u32 = i32 -> shr; signed local keeps scmp)"
else
    echo "FAIL: assign_type_signedness (u32=i32 shift: $(echo "$ASG_OUT" | grep -oE 'shr|sar' | head -1), signed cmp: $(echo "$ASG_OUT2" | grep -oiE 'scmp_[a-z]+|cmp_[a-z]+' | head -1))"
    FAIL=$((FAIL + 1))
fi

# --- compiler tables must grow instead of hitting fixed walls ---
# Four append-only tables were fixed-size with a loud abort:
#   dce_fn_map (1024), dce_table (2048), dce_hash_tbl (8192 slots), fn_table (1024)
# The compiler's own source reached 1015 dce_fn_map entries -- NINE short of
# being unable to build itself -- and fn_table's cap meant no program with
# more than 1024 emitted functions could be compiled at all. All four now
# double on demand. 4200 functions crosses every threshold, including at
# least one dce_hash_tbl rehash (which matters because dce_add's probe loop
# is `while 1 == 1` and terminates only while the load factor stays <= 50%).
# The bodies contain a loop so the inliner cannot fold the calls away and
# leave the growth paths unexercised.
TOTAL=$((TOTAL + 1))
REPO_ROOT="$DIR/.."
MANYFN="$REPO_ROOT/test_tmp_manyfn_$$.kr"
MANYBIN="$REPO_ROOT/test_tmp_manyfn_$$.bin"
awk 'BEGIN {
    for (i = 0; i < 4200; i++)
        printf "fn g%d() -> uint64 { uint64 s = 0 uint64 j = 0 while j < 2 { s = s + 1 j = j + 1 } return s }\n", i
    print "fn main() -> uint64 {"
    print "    uint64 t = 0"
    for (i = 0; i < 4200; i++) printf "    t = t + g%d()\n", i
    print "    println(t)"
    print "    return 0"
    print "}"
}' > "$MANYFN"
rm -f "$MANYBIN"
$KRC $KRC_FLAGS "$MANYFN" -o "$MANYBIN" >/dev/null 2>&1
MANYOUT=""
if [ -f "$MANYBIN" ]; then
    chmod +x "$MANYBIN"
    MANYOUT=$("$MANYBIN" 2>/dev/null)
fi
rm -f "$MANYFN" "$MANYBIN"
if [ "$MANYOUT" = "8400" ]; then
    PASS=$((PASS + 1))
    echo "  growable_tables_4200_fns: PASS (dce_fn_map/dce_table/dce_hash/fn_table all grew)"
else
    echo "FAIL: growable_tables_4200_fns (expected 8400, got '${MANYOUT:-<no output/compile failed>}')"
    FAIL=$((FAIL + 1))
fi

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
        # hello now exit(10)s after printing (freestanding), so qemu
        # terminates itself via the sifive_test finisher instead of running
        # out the clock — 10s is generous headroom over the ~instant UART
        # output + exit.
        RV_OUT=$(timeout 10 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null); RV_ST=$?
        if [ "$RV_ST" = "10" ] && echo "$RV_OUT" | grep -q "hello"; then
            PASS=$((PASS + 1))
            echo "  riscv_hello_boot: PASS (qemu printed hello, exited 10)"
        else
            echo "FAIL: riscv_hello_boot (status $RV_ST, output did not contain 'hello', or both)"
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
        # hello now exit(30)s after printing (freestanding), so qemu
        # terminates itself via SIMCALL instead of running out the clock.
        # -semihosting is required or SIMCALL is a silent no-op and this
        # times out at 124 instead of asserting. Command substitution
        # captures the full stdout before qemu exits.
        XT_OUT=$(timeout 10 qemu-system-xtensa -M lx60 -nographic -semihosting -kernel "$XT_HELLO_ELF" 2>/dev/null); XT_ST=$?
        if [ "$XT_ST" = "30" ] && echo "$XT_OUT" | grep -q "hello"; then
            PASS=$((PASS + 1))
            echo "  xtensa_hello_boot: PASS (qemu printed hello, exited 30)"
        else
            echo "FAIL: xtensa_hello_boot (status $XT_ST, output did not contain 'hello', or both)"
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
        # stress.kr now exit(31)s after printing, so qemu terminates itself via
        # SIMCALL (-semihosting required) instead of running out the timeout.
        # fib(20) is ~21.9k calls — microseconds under qemu; 8s is ample headroom.
        # Strip CR so the compare is newline-exact regardless of UART line endings.
        XT_ST_RAW=$(timeout 8 qemu-system-xtensa -M lx60 -nographic -semihosting -kernel "$XT_STRESS_ELF" 2>/dev/null); XT_ST_STATUS=$?
        XT_ST_OUT=$(echo "$XT_ST_RAW" | tr -d '\r')
        if [ "$XT_ST_STATUS" = "31" ] && [ "$XT_ST_OUT" = "$XT_ST_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_stress_boot: PASS (recursion + spills + signed div all correct, exited 31)"
        else
            echo "FAIL: xtensa_stress_boot (output mismatch or status $XT_ST_STATUS != 31)"
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
        XT_STR_RAW=$(timeout 8 qemu-system-xtensa -M lx60 -nographic -semihosting -kernel "$XT_STR_ELF" 2>/dev/null); XT_STR_STATUS=$?
        XT_STR_OUT=$(echo "$XT_STR_RAW" | tr -d '\r')
        if [ "$XT_STR_STATUS" = "32" ] && [ "$XT_STR_OUT" = "$XT_STR_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_str_boot: PASS (string literal materialized + printed, exited 32)"
        else
            echo "FAIL: xtensa_str_boot (output mismatch or status $XT_STR_STATUS != 32)"
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
        XT_GLB_RAW=$(timeout 8 qemu-system-xtensa -M lx60 -nographic -semihosting -kernel "$XT_GLB_ELF" 2>/dev/null); XT_GLB_STATUS=$?
        XT_GLB_OUT=$(echo "$XT_GLB_RAW" | tr -d '\r')
        if [ "$XT_GLB_STATUS" = "33" ] && [ "$XT_GLB_OUT" = "$XT_GLB_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_globals_boot: PASS (static load/store + print = 42, exited 33)"
        else
            echo "FAIL: xtensa_globals_boot (output mismatch or status $XT_GLB_STATUS != 33)"
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
        XT_FP_RAW=$(timeout 8 qemu-system-xtensa -M lx60 -nographic -semihosting -kernel "$XT_FP_ELF" 2>/dev/null); XT_FP_STATUS=$?
        XT_FP_OUT=$(echo "$XT_FP_RAW" | tr -d '\r')
        if [ "$XT_FP_STATUS" = "34" ] && [ "$XT_FP_OUT" = "$XT_FP_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_fnptr_boot: PASS (fn_addr + call_ptr = 42, exited 34)"
        else
            echo "FAIL: xtensa_fnptr_boot (output mismatch or status $XT_FP_STATUS != 34)"
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

# --- Xtensa LX6 CALL_IND caller-saved-clobber regression (call ceilings) ---
# WHY THIS EXISTS: xt_seed_call_ceilings' has_call test (src/ir_xtensa.kr) must
# include IR_CALL_IND (87) alongside IR_CALL (50) / IR_ARG (51). When the wide
# register file landed it initially checked only 50/51 — and this suite still
# passed 699/699 with that live miscompile in; a sibling project's numeric
# bit-exactness tests caught it. This boot image is built so that exact
# omission changes the printed checksum: harness() keeps 8 static-derived
# values live across a ZERO-ARG call_ptr (zero args so no IR_ARG masks the
# missing op-87 check; no direct calls in the function so nothing else flags
# the block), and the callee churn() holds 10 mutually-live values so its own
# allocation writes every caller-saved colour a2,a3,a4,a6,a7. Without the
# op-87 ceiling some of the caller's live values land in a2..a7, come back
# trashed, and the weighted checksum is wrong (observed 65015 vs 32529 with
# the check reverted). Full-output equality; loop{} keeps the core busy till
# timeout.
echo ""
echo "--- xtensa LX6 CALL_IND clobber-ceiling regression boot test ---"
if command -v qemu-system-xtensa >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_CI_ELF="/tmp/krc_xt_callind_$$.elf"
    XT_CI_OK=1
    if ! $KRC --arch=xtensa --freestanding "$DIR/../examples/xtensa/callind_clobber.kr" -o "$XT_CI_ELF" >/dev/null 2>&1; then
        echo "FAIL: xtensa_callind_clobber_boot (compilation failed)"
        XT_CI_OK=0
    fi
    if [ "$XT_CI_OK" = 1 ]; then
        XT_CI_EXP="32529"
        XT_CI_RAW=$(timeout 8 qemu-system-xtensa -M lx60 -nographic -semihosting -kernel "$XT_CI_ELF" 2>/dev/null); XT_CI_STATUS=$?
        XT_CI_OUT=$(echo "$XT_CI_RAW" | tr -d '\r')
        if [ "$XT_CI_STATUS" = "35" ] && [ "$XT_CI_OUT" = "$XT_CI_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_callind_clobber_boot: PASS (8 live-across-callx0 values survive = 32529, exited 35)"
        else
            echo "FAIL: xtensa_callind_clobber_boot (output mismatch or status $XT_CI_STATUS != 35 — CALL_IND missing from xt_seed_call_ceilings?)"
            echo "    expected: $XT_CI_EXP"
            echo "    got:      $XT_CI_OUT"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_CI_ELF"
else
    echo "  xtensa_callind_clobber_boot: SKIP (qemu-system-xtensa not installed)"
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
        XT_BSS_RAW=$(timeout 8 qemu-system-xtensa -M lx60 -nographic -semihosting -kernel "$XT_BSS_ELF" 2>/dev/null); XT_BSS_STATUS=$?
        XT_BSS_OUT=$(echo "$XT_BSS_RAW" | tr -d '\r')
        if [ "$XT_BSS_STATUS" = "36" ] && [ "$XT_BSS_OUT" = "$XT_BSS_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_bss_boot: PASS (real BSS gap + zero loop; marker/buf = 42 0 99, exited 36)"
        else
            echo "FAIL: xtensa_bss_boot (output mismatch or status $XT_BSS_STATUS != 36)"
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
# scalar USED TO never register as a struct var — since fixed, but this
# example stays on the parameter form it was written for; see mem_stack.kr's
# header comment for the x86-host probe that found it). Full-output equality; loop{}
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
        XT_MS_RAW=$(timeout 8 qemu-system-xtensa -M lx60 -nographic -semihosting -kernel "$XT_MS_ELF" 2>/dev/null); XT_MS_STATUS=$?
        XT_MS_OUT=$(echo "$XT_MS_RAW" | tr -d '\r')
        if [ "$XT_MS_STATUS" = "37" ] && [ "$XT_MS_OUT" = "$XT_MS_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_memstack_boot: PASS (stack array + memset/memcpy/memcmp, exited 37)"
        else
            echo "FAIL: xtensa_memstack_boot (output mismatch or status $XT_MS_STATUS != 37)"
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
        XT_SI_RAW=$(timeout 8 qemu-system-xtensa -M lx60 -nographic -semihosting -kernel "$XT_SI_ELF" 2>/dev/null); XT_SI_STATUS=$?
        XT_SI_OUT=$(echo "$XT_SI_RAW" | tr -d '\r')
        if [ "$XT_SI_STATUS" = "38" ] && [ "$XT_SI_OUT" = "$XT_SI_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_strfmt_boot: PASS (str_len/str_eq/fmt_uint = 4/1/0/60705, exited 38)"
        else
            echo "FAIL: xtensa_strfmt_boot (output mismatch or status $XT_SI_STATUS != 38)"
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
        XT_ASM_RAW=$(timeout 8 qemu-system-xtensa -M lx60 -nographic -semihosting -kernel "$XT_ASM_ELF" 2>/dev/null); XT_ASM_STATUS=$?
        XT_ASM_OUT=$(echo "$XT_ASM_RAW" | tr -d '\r')
        if [ "$XT_ASM_STATUS" = "39" ] && [ "$XT_ASM_OUT" = "$XT_ASM_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_asm_boot: PASS (asm block assembled: nop present + output = XY, exited 39)"
        else
            echo "FAIL: xtensa_asm_boot (output mismatch or status $XT_ASM_STATUS != 39)"
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
        XT_CAP_RAW=$(timeout 10 qemu-system-xtensa -M lx60 -nographic -semihosting -kernel "$XT_CAP_ELF" 2>/dev/null); XT_CAP_STATUS=$?
        XT_CAP_OUT=$(echo "$XT_CAP_RAW" | tr -d '\r')
        if [ "$XT_CAP_STATUS" = "40" ] && [ "$XT_CAP_OUT" = "$XT_CAP_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_capstone_boot: PASS (all freestanding ops: str_const/static/bss/stack+memset/memcpy/strlen/str_eq/fmt_uint/memcmp/fn_addr+call_ind/asm_block, exited 40)"
        else
            echo "FAIL: xtensa_capstone_boot (output mismatch or status $XT_CAP_STATUS != 40)"
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

# --- Xtensa LX6 large-frame boot test (ADDMI large-frame support) ---
# bigframe.kr exercises every path the old 1020/2047-byte frame guards used
# to reject: a just-over-1KB frame (a0 slot past s32i's 1020 -> ADDMI store
# path), 12 KB of stack arrays (frame constant + STACK_ADDR bases past
# MOVI's 2047 -> movi+addmi), an 80-deep all-live local chain (spill slots
# past 1020 in BOTH directions), and an 8-arg callee whose overflow-param
# reads land past 1020. Full-output equality of six precomputed sums — a
# single wrong SP-relative address changes a digit (mutation-verified: a
# residue-split bug in the store helper kills every line after the first).
# The old compiler loud-fails this file; under1k (line 1) doubles as the
# just-under-the-cap runtime check.
echo ""
echo "--- xtensa LX6 large-frame boot test ---"
if command -v qemu-system-xtensa >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_BF_ELF="/tmp/krc_xt_bigframe_$$.elf"
    XT_BF_OK=1
    if ! $KRC --arch=xtensa --freestanding "$DIR/../examples/xtensa/bigframe.kr" -o "$XT_BF_ELF" >/dev/null 2>&1; then
        echo "FAIL: xtensa_bigframe_boot (compilation failed)"
        XT_BF_OK=0
    fi
    if [ "$XT_BF_OK" = 1 ]; then
        XT_BF_EXP=$(printf '61100\n5559680\n1499500\n928296122\n45353\n79800')
        XT_BF_RAW=$(timeout 8 qemu-system-xtensa -M lx60 -nographic -semihosting -kernel "$XT_BF_ELF" 2>/dev/null); XT_BF_STATUS=$?
        XT_BF_OUT=$(echo "$XT_BF_RAW" | tr -d '\r')
        if [ "$XT_BF_STATUS" = "41" ] && [ "$XT_BF_OUT" = "$XT_BF_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_bigframe_boot: PASS (1K/12K frames + deep spills + overflow params all correct, exited 41)"
        else
            echo "FAIL: xtensa_bigframe_boot (output mismatch or status $XT_BF_STATUS != 41)"
            echo "    expected: $(echo "$XT_BF_EXP" | tr '\n' ' ')"
            echo "    got:      $(echo "$XT_BF_OUT" | tr '\n' ' ')"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_BF_ELF"
else
    echo "  xtensa_bigframe_boot: SKIP (qemu-system-xtensa not installed)"
fi

# --- Xtensa LX6 many-argument boot test (per-function overflow reserve) ---
# The outgoing-arg reserve at the bottom of every xtensa frame used to be a
# FIXED 64 bytes = 16 slots, so 6 (CALL0 arg registers) + 16 = 22 was a hard
# ceiling and every leaf paid 64 unusable bytes. ir_xtensa_gen step 4a now
# sizes it per function from that function's own IR_ARG scan.
# many_args.kr covers all three resulting frame shapes in one boot:
#   sum24  - 18 overflow args (72 bytes): does not even COMPILE on the old
#            fixed reserve, and its stack array's IR_STACK_ADDR base is
#            measured from the reserve, so a pre-scan/accessor mismatch
#            aliases buf onto the outgoing args and changes the sum
#   sum7   - exactly ONE overflow arg: the smallest non-zero reserve (4 bytes)
#   leafsq - no call at all: a ZERO-byte reserve
# Every function is self-recursive, so the AST inliner cannot erase the calls
# — an inlined probe reports a false pass at any argument count.
# Full-output equality, not a grep: a wrong slot offset changes a digit.
echo ""
echo "--- xtensa LX6 many-argument boot test ---"
if command -v qemu-system-xtensa >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_MA_ELF="/tmp/krc_xt_manyargs_$$.elf"
    XT_MA_OK=1
    if ! $KRC --arch=xtensa --freestanding "$DIR/../examples/xtensa/many_args.kr" -o "$XT_MA_ELF" >/dev/null 2>&1; then
        echo "FAIL: xtensa_many_args_boot (compilation failed)"
        XT_MA_OK=0
    fi
    if [ "$XT_MA_OK" = 1 ]; then
        XT_MA_EXP=$(printf '319\n30\n385')
        XT_MA_RAW=$(timeout 8 qemu-system-xtensa -M lx60 -nographic -semihosting -kernel "$XT_MA_ELF" 2>/dev/null); XT_MA_STATUS=$?
        XT_MA_OUT=$(echo "$XT_MA_RAW" | tr -d '\r')
        if [ "$XT_MA_STATUS" = "42" ] && [ "$XT_MA_OUT" = "$XT_MA_EXP" ]; then
            PASS=$((PASS + 1))
            echo "  xtensa_many_args_boot: PASS (24-arg call + 1-slot and 0-slot reserves all correct, exited 42)"
        else
            echo "FAIL: xtensa_many_args_boot (output mismatch or status $XT_MA_STATUS != 42)"
            echo "    expected: $(echo "$XT_MA_EXP" | tr '\n' ' ')"
            echo "    got:      $(echo "$XT_MA_OUT" | tr '\n' ' ')"
            FAIL=$((FAIL + 1))
        fi
    else
        FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_MA_ELF"
else
    echo "  xtensa_many_args_boot: SKIP (qemu-system-xtensa not installed)"
fi

# --- Xtensa frame-cap loud guard (large frames stay loud past ADDMI range) ---
# The large-frame work caps total_frame at 32752 bytes (the largest
# 16-aligned frame whose a0 slot and ADDMI high part both encode). A frame
# past the cap must still be a LOUD compile error — never a silent
# truncation. Nine 4 KB stack arrays = ~36 KB of frame.
echo ""
echo "--- xtensa frame-cap guard test ---"
TOTAL=$((TOTAL + 1))
XT_CAP_KR="/tmp/krc_xt_framecap_$$.kr"
XT_CAP_BIN="/tmp/krc_xt_framecap_$$.bin"
cat > "$XT_CAP_KR" <<'XTCAPEOF'
fn huge() -> u32 {
    u32[1024] a1
    u32[1024] a2
    u32[1024] a3
    u32[1024] a4
    u32[1024] a5
    u32[1024] a6
    u32[1024] a7
    u32[1024] a8
    u32[1024] a9
    a1[0] = 1
    a9[1023] = 2
    return a1[0] + a9[1023]
}
fn main() -> u32 {
    return huge()
}
XTCAPEOF
XT_CAP_ERR=$($KRC --arch=xtensa --freestanding "$XT_CAP_KR" -o "$XT_CAP_BIN" 2>&1 >/dev/null)
XT_CAP_RC=$?
if [ $XT_CAP_RC -ne 0 ] && echo "$XT_CAP_ERR" | grep -q "frame exceeds 32752"; then
    PASS=$((PASS + 1))
    echo "  xtensa_framecap_guard: PASS (36 KB frame rejected loudly)"
else
    echo "FAIL: xtensa_framecap_guard (rc=$XT_CAP_RC, err='$XT_CAP_ERR')"
    FAIL=$((FAIL + 1))
fi
rm -f "$XT_CAP_KR" "$XT_CAP_BIN"

echo ""
echo "--- xtensa simcall encoding ---"
TOTAL=$((TOTAL + 1))
XT_SC_SRC="/tmp/krc_xt_simcall_$$.kr"
XT_SC_BIN="/tmp/krc_xt_simcall_$$.elf"
XT_SC_CTL="/tmp/krc_xt_simctl_$$.kr"
XT_SC_CBIN="/tmp/krc_xt_simctl_$$.elf"
# Differential: the SAME program with and without the simcall. Grepping one
# image alone could match 00 51 00 occurring by chance in unrelated bytes.
printf '@naked fn s() { asm("simcall") }\nfn main() { s() }\n' > "$XT_SC_SRC"
printf '@naked fn s() { asm("nop") }\nfn main() { s() }\n'     > "$XT_SC_CTL"
if $KRC --arch=xtensa --freestanding "$XT_SC_SRC" -o "$XT_SC_BIN"  >/dev/null 2>&1 \
   && $KRC --arch=xtensa --freestanding "$XT_SC_CTL" -o "$XT_SC_CBIN" >/dev/null 2>&1 \
   && xxd -p "$XT_SC_BIN"  | tr -d '\n' | grep -q "005100" \
   && ! xxd -p "$XT_SC_CBIN" | tr -d '\n' | grep -q "005100"; then
    PASS=$((PASS + 1))
    echo "  xtensa_simcall_encoding: PASS (0x005100 present only with simcall)"
else
    echo "FAIL: xtensa_simcall_encoding (expected 00 51 00 with simcall and absent without)"
    FAIL=$((FAIL + 1))
fi
rm -f "$XT_SC_SRC" "$XT_SC_BIN" "$XT_SC_CTL" "$XT_SC_CBIN"


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
        RV_OUT=$(timeout 10 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null); RV_ST=$?
        if [ "$RV_ST" = "77" ] && echo "$RV_OUT" | grep -q "hi"; then
            PASS=$((PASS + 1))
            echo "  riscv_t1_strconst: PASS (qemu printed hi, exited 77)"
        else
            echo "FAIL: riscv_t1_strconst (status $RV_ST, output did not contain 'hi', or both)"
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
        RV_OUT=$(timeout 10 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null); RV_ST=$?
        if [ "$RV_ST" = "21" ] && echo "$RV_OUT" | grep -q "9"; then
            PASS=$((PASS + 1))
            echo "  riscv_t2_static: PASS (qemu printed 9, exited 21)"
        else
            echo "FAIL: riscv_t2_static (status $RV_ST, output did not contain '9', or both)"
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
        RV_OUT=$(timeout 10 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null); RV_ST=$?
        if [ "$RV_ST" = "22" ] && echo "$RV_OUT" | grep -q "31"; then
            PASS=$((PASS + 1))
            echo "  riscv_t3_strloops: PASS (qemu printed 31, loops stayed 4-byte, exited 22)"
        else
            echo "FAIL: riscv_t3_strloops (status $RV_ST, output did not contain '31', or both)"
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
        RV_OUT=$(timeout 10 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null); RV_ST=$?
        if [ "$RV_ST" = "23" ] && echo "$RV_OUT" | grep -q "AAZk"; then
            PASS=$((PASS + 1))
            echo "  riscv_t4_memblk: PASS (qemu printed AAZk, loops stayed 4-byte, exited 23)"
        else
            echo "FAIL: riscv_t4_memblk (status $RV_ST, qemu output was '$RV_OUT', want 'AAZk' + status 23)"
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
        RV_OUT=$(timeout 10 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null); RV_ST=$?
        if [ "$RV_ST" = "24" ] && [ "$RV_OUT" = "123455" ]; then
            PASS=$((PASS + 1))
            echo "  riscv_t5_fmtuint: PASS (qemu printed 123455 -- digits '12345' + len sanity '5', loops stayed 4-byte, exited 24)"
        else
            echo "FAIL: riscv_t5_fmtuint (status $RV_ST, qemu output was '$RV_OUT', want '123455' + status 24)"
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
        RV_OUT=$(timeout 10 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null); RV_ST=$?
        # Command substitution strips the trailing newline, leaving "AZ".
        if [ "$RV_ST" = "25" ] && [ "$RV_OUT" = "AZ" ]; then
            PASS=$((PASS + 1))
            echo "  riscv_t6_stackarray: PASS (qemu printed AZ -- small array 'A' + large-frame array 'Z', exited 25)"
        else
            echo "FAIL: riscv_t6_stackarray (status $RV_ST, qemu output was '$RV_OUT', want 'AZ' + status 25)"
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
        RV_OUT=$(timeout 10 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null); RV_ST=$?
        # Command substitution strips the trailing newline, leaving "A".
        if [ "$RV_ST" = "26" ] && [ "$RV_OUT" = "A" ]; then
            PASS=$((PASS + 1))
            echo "  riscv_t7_fnptr: PASS (qemu printed A -- inc(64) called through fn_addr pointer, exited 26)"
        else
            echo "FAIL: riscv_t7_fnptr (status $RV_ST, qemu output was '$RV_OUT', want 'A' + status 26)"
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
        RV_OUT=$(timeout 10 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null); RV_ST=$?
        # 0x81 ror 1 = 0x80000040 (low byte '@'); 0x41 ror 0 = 'A' (n==0
        # identity). Command substitution strips the trailing newline.
        if [ "$RV_ST" = "27" ] && [ "$RV_OUT" = "@A" ]; then
            PASS=$((PASS + 1))
            echo "  riscv_t8_ror: PASS (qemu printed @A -- rotate bit-exact incl. n==0 identity, exited 27)"
        else
            echo "FAIL: riscv_t8_ror (status $RV_ST, qemu output was '$RV_OUT', want '@A' + status 27)"
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
        RV_OUT=$(timeout 10 qemu-system-riscv32 -machine virt -nographic -bios "$RV_BIN" 2>/dev/null); RV_ST=$?
        # in(base=0x40 -> a0); raw word a0=a0+1=0x41; out(a0 -> result); putc.
        if [ "$RV_ST" = "28" ] && [ "$RV_OUT" = "A" ]; then
            PASS=$((PASS + 1))
            echo "  riscv_t9_asm: PASS (qemu printed A -- raw word ran, in/out constraint bound, word stayed 4-byte, exited 28)"
        else
            echo "FAIL: riscv_t9_asm (status $RV_ST, qemu output was '$RV_OUT', want 'A' + status 28)"
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

# riscv32 allocation-failure contract. The only asserting coverage the rv32
# alloc/dealloc guards have: run_test/run_test_a64 never target riscv32, and
# tests/diff_ir_legacy.sh has no rv32 arm (there is no legacy rv32 backend).
# The threshold here is 32-bit (0xFFFFF001), not the 64-bit constant the other
# backends use, and the guard words must stay uncompressed -- rv_compress_function
# relayouts after emission, which once left the branch pointing mid-block and
# faulted alloc even on SUCCESS. That is why exit 44 (the success leg) is
# asserted alongside the OOM leg.
echo ""
echo "--- riscv32 alloc failure contract ---"
if command -v qemu-riscv32-static >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_A_SRC="/tmp/krc_rv_alloc_$$.kr"
    RV_A_BIN="/tmp/krc_rv_alloc_$$.bin"
    cat > "$RV_A_SRC" <<'RVEOF'
fn main() {
    u32 bad = alloc(0xFFFF0000)
    if bad != 0 { exit(1) }
    dealloc(bad)
    u32 ok = alloc(64)
    if ok == 0 { exit(2) }
    store32(ok, 4242)
    u32 v = load32(ok)
    dealloc(ok)
    if v != 4242 { exit(3) }
    exit(44)
}
RVEOF
    if ! $KRC --arch=riscv32 "$RV_A_SRC" -o "$RV_A_BIN" >/dev/null 2>&1; then
        echo "FAIL: riscv_alloc_oom_returns_zero (compilation failed)"
        FAIL=$((FAIL + 1))
    else
        qemu-riscv32-static "$RV_A_BIN" >/dev/null 2>&1
        rc=$?
        if [ "$rc" = "44" ]; then
            PASS=$((PASS + 1))
            echo "  riscv_alloc_oom_returns_zero: PASS (OOM->0, dealloc(0) safe, success path intact)"
        else
            echo "FAIL: riscv_alloc_oom_returns_zero (got exit $rc, want 44)"
            FAIL=$((FAIL + 1))
        fi
    fi
    rm -f "$RV_A_SRC" "$RV_A_BIN"
else
    echo "  riscv_alloc_oom_returns_zero: SKIP (qemu-riscv32-static not installed)"
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

# --- riscv32 hosted struct-arg by-value + by-reference method self ---
# fix/struct-param-writes parity on the rv32 dialect (u32 fields — the
# dialect rejects 64-bit types). One image covers: nested-field arg copied
# (by-value), array-element arg copied AND data-correct, method self
# mutation persists (by-reference), array-element method receiver.
# Exit code packs the checks: each adds a distinct value, total 42.
echo ""
echo "--- riscv32 hosted struct-param semantics test ---"
if command -v qemu-riscv32-static >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    RV_SP_KR="/tmp/krc_rv_structparam_$$.kr"
    RV_SP_BIN="/tmp/krc_rv_structparam_$$.bin"
    cat > "$RV_SP_KR" <<'RVSP'
struct P { u32 x; u32 y }
struct O { P inn; u32 z }
fn poke(P c) -> u32 { c.x = 99; return c.x }
fn sum(P c) -> u32 { return c.x + c.y }
fn P.setx(P self, u32 v) { self.x = v }
fn main() {
    u32 score = 0
    O o; o.inn.x = 7; o.inn.y = 0
    u32 r1 = poke(o.inn)
    if o.inn.x == 7 { score = score + 10 }       // nested arg stayed by-value
    P[3] arr
    arr[1].x = 5; arr[1].y = 6
    u32 r2 = poke(arr[1])
    if arr[1].x == 5 { score = score + 10 }      // element arg stayed by-value
    if sum(arr[1]) == 11 { score = score + 10 }  // element arg data correct
    P p; p.x = 1
    p.setx(4)
    if p.x == 4 { score = score + 6 }            // self write persisted
    arr[2].x = 1
    arr[2].setx(9)
    if arr[2].x == 9 { score = score + 6 }       // element receiver persisted
    exit(score)
}
RVSP
    if ! $KRC --arch=riscv32 "$RV_SP_KR" -o "$RV_SP_BIN" >/dev/null 2>&1; then
        echo "FAIL: riscv_hosted_struct_param (compilation failed)"
        FAIL=$((FAIL + 1))
    else
        qemu-riscv32-static "$RV_SP_BIN" >/dev/null 2>&1
        rc=$?
        if [ "$rc" = "42" ]; then
            PASS=$((PASS + 1))
            echo "  riscv_hosted_struct_param: PASS (all 5 semantics checks, exit 42)"
        else
            echo "FAIL: riscv_hosted_struct_param (got exit $rc, want 42)"
            FAIL=$((FAIL + 1))
        fi
    fi
    rm -f "$RV_SP_KR" "$RV_SP_BIN"
else
    echo "  riscv_hosted_struct_param: SKIP (qemu-riscv32-static not installed)"
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

echo ""
echo "--- riscv32 freestanding exit() terminates qemu ---"
if command -v qemu-system-riscv32 >/dev/null 2>&1; then
    for RV_CODE in 0 42; do
        TOTAL=$((TOTAL + 1))
        RV_E_SRC="/tmp/krc_rv_exit_${RV_CODE}_$$.kr"
        RV_E_BIN="/tmp/krc_rv_exit_${RV_CODE}_$$.bin"
        printf 'fn main() { exit(%d) }\n' "$RV_CODE" > "$RV_E_SRC"
        if $KRC --arch=riscv32 --freestanding "$RV_E_SRC" -o "$RV_E_BIN" >/dev/null 2>&1; then
            timeout 10 qemu-system-riscv32 -machine virt -nographic -bios "$RV_E_BIN" >/dev/null 2>&1
            RV_E_ST=$?
            if [ "$RV_E_ST" = "$RV_CODE" ]; then
                PASS=$((PASS + 1)); echo "  riscv32_exit_${RV_CODE}: PASS (qemu status $RV_E_ST)"
            else
                echo "FAIL: riscv32_exit_${RV_CODE} (expected status $RV_CODE, got $RV_E_ST)"; FAIL=$((FAIL + 1))
            fi
        else
            echo "FAIL: riscv32_exit_${RV_CODE} (compile failed)"; FAIL=$((FAIL + 1))
        fi
        rm -f "$RV_E_SRC" "$RV_E_BIN"
    done
else
    echo "  riscv32_exit: SKIP (qemu-system-riscv32 not installed)"
fi

# Pin the emitted constants (spec success-criterion 7). The behavioural
# tests above prove the mechanism works today; this one pins the
# *constants*, so a later edit that changes the magic word or the device
# address fails loudly at the byte level instead of silently hanging
# under qemu. The two hex strings are the little-endian byte orders of
# 0x01051293 (slli t0,a0,16) and 0x0062E2B3 (or t0,t0,t1).
TOTAL=$((TOTAL + 1))
RV_K_SRC="/tmp/krc_rv_const_$$.kr"
RV_K_BIN="/tmp/krc_rv_const_$$.bin"
printf 'fn main() { exit(1) }\n' > "$RV_K_SRC"
if $KRC --arch=riscv32 --freestanding "$RV_K_SRC" -o "$RV_K_BIN" >/dev/null 2>&1 \
   && xxd -p "$RV_K_BIN" | tr -d '\n' | grep -q "93120501" \
   && xxd -p "$RV_K_BIN" | tr -d '\n' | grep -q "b3e26200"; then
    PASS=$((PASS + 1))
    echo "  riscv32_exit_constants: PASS (slli/or words pinned)"
else
    echo "FAIL: riscv32_exit_constants (expected slli t0,a0,16 and or t0,t0,t1 words)"
    FAIL=$((FAIL + 1))
fi
rm -f "$RV_K_SRC" "$RV_K_BIN"

echo ""
echo "--- xtensa exit() ---"
TOTAL=$((TOTAL + 1))
XT_E_SRC="/tmp/krc_xt_exit_$$.kr"
printf 'fn main() { exit(42) }\n' > "$XT_E_SRC"
# esp32 must REFUSE, with the new wording, and must exit non-zero: a
# print-and-continue regression would still match the grep below while
# happily emitting SIMCALL into an ESP32 image (xtensa_framecap_guard,
# tests/run_tests.sh:5936, checks its rc the same way).
XT_REFUSE_ERR=$($KRC --arch=xtensa --freestanding --target=esp32 "$XT_E_SRC" -o /dev/null 2>&1)
XT_REFUSE_RC=$?
if [ $XT_REFUSE_RC -ne 0 ] && echo "$XT_REFUSE_ERR" | grep -q "no OS to return an exit status to"; then
    PASS=$((PASS + 1)); echo "  xtensa_esp32_exit_refused: PASS"
else
    echo "FAIL: xtensa_esp32_exit_refused (rc=$XT_REFUSE_RC, expected nonzero rc and an error mentioning 'no OS to return an exit status to')"; FAIL=$((FAIL + 1))
fi
# lx60 must terminate qemu with 42
if command -v qemu-system-xtensa >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    XT_E_BIN="/tmp/krc_xt_exit_$$.elf"
    if $KRC --arch=xtensa --freestanding "$XT_E_SRC" -o "$XT_E_BIN" >/dev/null 2>&1; then
        timeout 10 qemu-system-xtensa -M lx60 -nographic -semihosting -kernel "$XT_E_BIN" >/dev/null 2>&1
        XT_E_ST=$?
        if [ "$XT_E_ST" = "42" ]; then
            PASS=$((PASS + 1)); echo "  xtensa_lx60_exit_42: PASS"
        else
            echo "FAIL: xtensa_lx60_exit_42 (expected 42, got $XT_E_ST)"; FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL: xtensa_lx60_exit_42 (compile failed)"; FAIL=$((FAIL + 1))
    fi
    rm -f "$XT_E_BIN"
fi
rm -f "$XT_E_SRC"

# Same shape as riscv_freestanding_syscall_nyi above: op 52 carries EVERY
# syscall, not just exit(), and the SIMCALL exit lowering in ir_xtensa.kr is
# gated on imm == 231 (exit_group) specifically. A freestanding write() must
# still fail loud with the NYI error instead of silently falling through
# into the exit sequence -- if the `imm != 231` gate were removed, this
# write(1,...) call (imm == 1) would skip straight past the freestanding and
# esp32 checks and get lowered as if it were exit(1), succeeding silently
# instead of erroring, so this assertion cannot pass without the gate. Task 3
# hit exactly this bug shape on the riscv side (riscv_freestanding_syscall_nyi
# below); xtensa had no analogous coverage until now.
echo ""
echo "--- xtensa freestanding write() NYI gate ---"
TOTAL=$((TOTAL + 1))
XT_WR_SRC="/tmp/krc_xt_fs_write_$$.kr"
printf 'fn main() { write(1, "hi", 2) }\n' > "$XT_WR_SRC"
XT_WR_ERR=$($KRC --arch=xtensa --freestanding "$XT_WR_SRC" -o /dev/null 2>&1)
if echo "$XT_WR_ERR" | grep -q "xtensa: IR op 52 not yet implemented"; then
    PASS=$((PASS + 1))
    echo "  xtensa_freestanding_syscall_nyi: PASS (op 52 gated loud on freestanding write())"
else
    echo "FAIL: xtensa_freestanding_syscall_nyi (got '$XT_WR_ERR', want NYI on op 52)"
    FAIL=$((FAIL + 1))
fi
rm -f "$XT_WR_SRC"

# --- std/net.kr sockaddr byte order ---
# net_addr_ipv4 documents its `ip` argument as host order (std/net.kr header
# comment, STDLIB.md:444) but stored it raw, so the documented 0x7F000001
# resolved to 1.0.0.127 -- while sin_port two bytes earlier WAS converted via
# net_htons, leaving one struct carrying one field in each byte order.
#
# Asserts the on-the-wire bytes, not a round-trip through the same helper: a
# round-trip would pass with any self-consistent convention, including the
# broken one. Byte 0 of sin_addr must be 127 for 127.0.0.1.
#
# NOTE: this must run via run_test/run_test_output, which write the source to
# $REPO_ROOT. A .kr file outside the repo resolves `import "std/net.kr"` to the
# INSTALLED stdlib (/usr/share/kernrift/std/net.kr) and would silently test
# the wrong file.
run_test_output "net_addr_ipv4_byte_order" 'import "std/net.kr"
fn main() {
    u64 a = net_addr_ipv4(0x7F000001, 8080)
    u64 ip = a + 4
    print(load8(ip)); print_str(".")
    print(load8(ip + 1)); print_str(".")
    print(load8(ip + 2)); print_str(".")
    print(load8(ip + 3)); print_str(" ")
    u64 p = a + 2
    print(load8(p)); print_str(",")
    println(load8(p + 1))
    net_addr_free(a)
    exit(0)
}' "127.0.0.1 31,144"

# net_htonl on its own: 0x01020304 -> 0x04030201. Guards the parenthesisation
# too -- in KernRift `|` binds tighter than `<<`, so an unparenthesised
# `b0 << 24 | b1 << 16` silently computes something else entirely.
run_test "net_htonl_swaps_all_four_bytes" 'import "std/net.kr"
fn main() {
    if net_htonl(0x01020304) != 0x04030201 { exit(1) }
    if net_htonl(0x7F000001) != 0x0100007F { exit(2) }
    if net_htonl(0) != 0 { exit(3) }
    if net_htonl(0xFFFFFFFF) != 0xFFFFFFFF { exit(4) }
    exit(0)
}' 0

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

echo ""
echo "--- --target=none flag surface ---"
TN_SRC="/tmp/krc_tnone_$$.kr"
printf 'fn main() { loop { } }\n' > "$TN_SRC"

# 1. Accepted on all four arches.
for A in x86_64 arm64 riscv32 xtensa; do
    TOTAL=$((TOTAL + 1))
    if $KRC --arch=$A --target=none "$TN_SRC" -o /tmp/krc_tnone_bin_$$ >/dev/null 2>&1; then
        PASS=$((PASS + 1)); echo "  target_none_accepted_$A: PASS"
    else
        echo "FAIL: target_none_accepted_$A"; FAIL=$((FAIL + 1))
    fi
done

# 2. Cannot be a fat-binary slice: no runner extracts it, no OS execs it.
TOTAL=$((TOTAL + 1))
TN_ERR=$($KRC --targets=linux-x64,none "$TN_SRC" -o /tmp/krc_tnone_bin_$$ 2>&1); TN_ST=$?
if [ "$TN_ST" != "0" ] && echo "$TN_ERR" | grep -q "cannot appear in a fat binary"; then
    PASS=$((PASS + 1)); echo "  target_none_refused_in_fat: PASS"
else
    echo "FAIL: target_none_refused_in_fat (exit $TN_ST: '$TN_ERR')"; FAIL=$((FAIL + 1))
fi

# 3. --target=esp32 already implies bare metal; composing must not be silent.
TOTAL=$((TOTAL + 1))
TN_ERR=$($KRC --arch=xtensa --target=none --target=esp32 "$TN_SRC" -o /tmp/krc_tnone_bin_$$ 2>&1); TN_ST=$?
if [ "$TN_ST" != "0" ] && echo "$TN_ERR" | grep -q "conflicting --target"; then
    PASS=$((PASS + 1)); echo "  target_none_esp32_conflict: PASS"
else
    echo "FAIL: target_none_esp32_conflict (exit $TN_ST: '$TN_ERR')"; FAIL=$((FAIL + 1))
fi

# 4. Contradictory emit modes -- ALL FOUR of them.
#    This loop shipped naming two, `lkm` and `android`, while a reader would
#    reasonably take a list headed "contradictory emit modes" for the list.
#    macho and pe became refusals later (they are OS containers: a Mach-O
#    needs dyld and LC_MAIN, a PE's entry calls through a kernel32 import
#    slot) and were pinned only in the t6 surface, so this enumeration was
#    two-thirds of the truth from the day it stopped being all of it.
#    It is now the complete refused set. What KEEPS it complete is not this
#    line but t6_emit_table_covers_every_mode further down, which derives the
#    mode set from src/main.kr; this loop is the --target=none surface's own
#    copy and reds here for a nearer, better-named reason.
for M in lkm android macho pe; do
    TOTAL=$((TOTAL + 1))
    TN_ERR=$($KRC --arch=x86_64 --target=none --emit=$M "$TN_SRC" -o /tmp/krc_tnone_bin_$$ 2>&1); TN_ST=$?
    if [ "$TN_ST" != "0" ] && echo "$TN_ERR" | grep -q "target=none"; then
        PASS=$((PASS + 1)); echo "  target_none_refuses_emit_$M: PASS"
    else
        echo "FAIL: target_none_refuses_emit_$M (exit $TN_ST: '$TN_ERR')"; FAIL=$((FAIL + 1))
    fi
done

# 5. --target=none must never reach the fat-binary path. freestanding is a
#    static global that persists across all 8 hosted slices inside
#    compile_fat, so a fat build under target_os==4 used to strip
#    startup/exit from every slice: exit status 0, no diagnostic, and every
#    slice crashes at runtime. Assert by inspecting the artifact's header
#    (a fat binary starts with the 8-byte magic "KRBOFAT\0") rather than by
#    exit status alone, since exit status was 0 for this exact bug — a
#    correct fix might refuse outright (no file at all) or might default to
#    a single-arch binary (a valid non-fat file); either is acceptable here,
#    a KRBOFAT header is not.
TN_FAT_MAGIC="4b52424f46415400"
# 5a. No --arch at all: the default-fat-binary path. $KRC under `make test`
#     is a wrapper that unconditionally injects --arch=x86_64 ahead of every
#     test's own args (see Makefile:96), which would mask exactly the
#     "arch_set == 0" entrance this case exists to catch. Use the raw
#     compiler binary instead, same fallback `build/krc2` then `build/krc3`
#     already used for this reason by the governance test above.
if [ -f "$DIR/../build/krc2" ]; then
    TN_RAW_KRC=$(cd "$DIR/../build" && pwd)/krc2
elif [ -f "$DIR/../build/krc3" ]; then
    TN_RAW_KRC=$(cd "$DIR/../build" && pwd)/krc3
else
    TN_RAW_KRC=""
fi
TOTAL=$((TOTAL + 1))
rm -f /tmp/krc_tnone_nf1_$$
if [ -n "$TN_RAW_KRC" ]; then
    "$TN_RAW_KRC" --target=none "$TN_SRC" -o /tmp/krc_tnone_nf1_$$ >/dev/null 2>&1
fi
TN_NF1_MAGIC=""
if [ -f /tmp/krc_tnone_nf1_$$ ]; then
    TN_NF1_MAGIC=$(head -c8 /tmp/krc_tnone_nf1_$$ | od -An -tx1 | tr -d ' \n')
fi
if [ -z "$TN_RAW_KRC" ]; then
    echo "FAIL: target_none_no_arch_not_fat (no raw compiler binary found)"; FAIL=$((FAIL + 1))
elif [ "$TN_NF1_MAGIC" = "$TN_FAT_MAGIC" ]; then
    echo "FAIL: target_none_no_arch_not_fat (produced a KRBOFAT fat binary)"; FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1)); echo "  target_none_no_arch_not_fat: PASS"
fi
rm -f /tmp/krc_tnone_nf1_$$

# 5b. An explicit --targets=<list> that does not spell "none" as one of its
#     elements — the --targets=...,none refusal above cannot see this one.
TOTAL=$((TOTAL + 1))
rm -f /tmp/krc_tnone_nf2_$$
$KRC --target=none --targets=linux-x64 "$TN_SRC" -o /tmp/krc_tnone_nf2_$$ >/dev/null 2>&1
TN_NF2_MAGIC=""
if [ -f /tmp/krc_tnone_nf2_$$ ]; then
    TN_NF2_MAGIC=$(head -c8 /tmp/krc_tnone_nf2_$$ | od -An -tx1 | tr -d ' \n')
fi
if [ "$TN_NF2_MAGIC" = "$TN_FAT_MAGIC" ]; then
    echo "FAIL: target_none_targets_list_not_fat (produced a KRBOFAT fat binary)"; FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1)); echo "  target_none_targets_list_not_fat: PASS"
fi
rm -f /tmp/krc_tnone_nf2_$$

# 6. The general --target= conflict rule (added so esp32/none composition
#    cannot be silent) is a user-visible behaviour change for HOSTED targets
#    too: --target=linux --target=windows previously took last-wins and now
#    errors. Byte-identity cannot see this (both spellings still produce a
#    valid binary), so it needs its own test.
TOTAL=$((TOTAL + 1))
TN_ERR=$($KRC --arch=x86_64 --target=linux --target=windows "$TN_SRC" -o /tmp/krc_tnone_bin_$$ 2>&1); TN_ST=$?
if [ "$TN_ST" != "0" ] && echo "$TN_ERR" | grep -q "conflicting --target"; then
    PASS=$((PASS + 1)); echo "  target_hosted_conflict: PASS"
else
    echo "FAIL: target_hosted_conflict (exit $TN_ST: '$TN_ERR')"; FAIL=$((FAIL + 1))
fi

rm -f "$TN_SRC" /tmp/krc_tnone_bin_$$


# --- --debug, --legacy, emit modes and arch x OS pairs (Task 6) ------------
#
# Four loose ends, each of which is a combination the compiler ACCEPTED and
# turned into nonsense rather than refusing.
#
#  1. --debug inlines a per-OS exit(1) trap (IR_ARR_CHECK, plus the null and
#     overflow checks) into every function that indexes an array or
#     dereferences a pointer. Measured before this task: 3 syscalls in a
#     --debug bare-metal build against 1 without. It did not fail silently --
#     the Task 2 emitter guard caught it -- but it reported
#     "SYSCALL reached the emitter from 'array bounds check (--debug)'", which
#     names a thing that is not a builtin, blames the wrong layer and offers no
#     remedy. And it only fired for programs that HAPPEN to use an array:
#     the same flags on an array-free program compiled clean, so the user
#     learns about the restriction from whichever function they write next.
#  2. --legacy is a second builtin dispatch (src/codegen.kr,
#     src/codegen_aarch64.kr, ~220 target_os sites between them) with no
#     @builtin_override routing, so the whole print family is unavailable
#     there on bare metal. --emit=obj reaches the SAME codegen and is kept, so
#     none of the legacy bare-metal coverage below is lost -- see the note on
#     the choke-point and provider blocks.
#  3. --emit= never sets target_os TO A BARE-METAL ONE, so macho/pe/obj/asm/ir
#     each had no defined outcome under --target=none. macho and pe produced a
#     real OS container (an 8192-byte Mach-O, a 2048-byte PE) full of
#     bare-metal codegen, which nothing on either side can load. (The four
#     words in caps were missing and made the sentence false: `--emit=macho`,
#     `--emit=pe` and `--emit=android` DO auto-set target_os when no --target=
#     was given -- src/main.kr's "Auto-set target_os from emit_mode" block --
#     which is exactly why t6_pair_riscv32_emit_pe below has to run its check
#     on the RESOLVED OS. This file asserted both readings, 180 lines apart.)
#  4. There was NO arch x OS validation at all: `--arch=riscv32
#     --target=windows` exited 0 and wrote a 296-byte RISC-V *ELF*. The check
#     added is an ENUMERATION of the legal pairs, not a blacklist -- a
#     blacklist admits whatever pair is added next, which is the same
#     "else, assume POSIX" shape this sub-project exists to remove.
echo ""
echo "--- --debug / --legacy / emit modes / arch x OS pairs ---"
# Raw compiler binary: under `make test` $KRC is a wrapper (Makefile:96) that
# injects --arch=x86_64 ahead of every test's own arguments, which would mask
# every --arch case in this block. Same build/krc2 then build/krc3 fallback
# the blocks below use.
if [ -f "$DIR/../build/krc2" ]; then
    T6_KRC=$(cd "$DIR/../build" && pwd)/krc2
elif [ -f "$DIR/../build/krc3" ]; then
    T6_KRC=$(cd "$DIR/../build" && pwd)/krc3
else
    T6_KRC=""
fi
T6_D=$(mktemp -d)
# Array-free: proves the refusals below come from FLAG VALIDATION, not from
# the emitter backstop firing on a bounds check that happens to be present.
printf 'static uint32 acc = 0\nfn main() {\n    uint32 i = 0\n    while i < 4 { acc = acc + i\n i = i + 1 }\n    loop { }\n}\n' > "$T6_D/plain.kr"
# Uses an array, so --debug really does inline IR_ARR_CHECK here.
printf 'static uint32 acc = 0\nfn main() {\n    uint32[8] t\n    uint32 i = 0\n    while i < 8 { t[i] = i\n i = i + 1 }\n    acc = t[3]\n    loop { }\n}\n' > "$T6_D/arr.kr"

# t6_refuses <name> <expect-substring-1> <expect-substring-2> -- <krc args...>
# Asserts a NON-ZERO exit, NO artifact, both substrings present, and that the
# message is not the generic emitter backstop. Both substrings are named
# because "refuse, naming both flags" is the requirement: a message that says
# only "--target=none" leaves the user guessing which of their other flags to
# drop.
t6_refuses() {
    local name="$1" want1="$2" want2="$3"; shift 4
    TOTAL=$((TOTAL + 1))
    rm -f "$T6_D/out"
    local err st
    err=$("$T6_KRC" "$@" -o "$T6_D/out" 2>&1); st=$?
    if [ -z "$T6_KRC" ]; then
        echo "FAIL: $name (no raw compiler binary found)"; FAIL=$((FAIL + 1))
    elif [ "$st" = "0" ] || [ -f "$T6_D/out" ]; then
        echo "FAIL: $name (accepted: exit $st, artifact $([ -f "$T6_D/out" ] && echo present || echo absent))"
        FAIL=$((FAIL + 1))
    elif echo "$err" | grep -q "reached the emitter"; then
        echo "FAIL: $name (generic emitter backstop, not a flag refusal: '$err')"; FAIL=$((FAIL + 1))
    elif ! echo "$err" | grep -q -- "$want1"; then
        echo "FAIL: $name (message does not name '$want1': '$err')"; FAIL=$((FAIL + 1))
    elif ! echo "$err" | grep -q -- "$want2"; then
        echo "FAIL: $name (message does not name '$want2': '$err')"; FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1)); echo "  $name: PASS"
    fi
    rm -f "$T6_D/out"
}

# t6_builds <name> -- <krc args...>: exit 0 and an artifact on disk.
t6_builds() {
    local name="$1"; shift 2
    TOTAL=$((TOTAL + 1))
    rm -f "$T6_D/out"
    local err st
    err=$("$T6_KRC" "$@" -o "$T6_D/out" 2>&1); st=$?
    if [ -n "$T6_KRC" ] && [ "$st" = "0" ] && [ -f "$T6_D/out" ]; then
        PASS=$((PASS + 1)); echo "  $name: PASS"
    else
        echo "FAIL: $name (exit $st: '$err')"; FAIL=$((FAIL + 1))
    fi
    rm -f "$T6_D/out"
}

# 1. --debug + --target=none. On ALL FOUR arches and, critically, on the
#    array-FREE program too: the old behaviour compiled that one clean.
for A in x86_64 arm64 riscv32 xtensa; do
    t6_refuses "t6_debug_tnone_plain_$A" "--debug" "--target=none" -- \
        --arch=$A --target=none --debug "$T6_D/plain.kr"
    t6_refuses "t6_debug_tnone_arr_$A" "--debug" "--target=none" -- \
        --arch=$A --target=none --debug "$T6_D/arr.kr"
done
# Flag order must not matter: validation runs after the whole arg loop.
t6_refuses "t6_debug_tnone_order" "--debug" "--target=none" -- \
    --debug --target=none --arch=x86_64 "$T6_D/arr.kr"

# ... and --debug is UNTOUCHED everywhere else. This is the half of the
# change that a too-broad refusal breaks: --debug is a working, tested flag on
# every hosted target and on freestanding riscv32/xtensa, and the array
# program is the one that actually exercises IR_ARR_CHECK.
for A in x86_64 arm64; do
    for OS in linux macos windows; do
        t6_builds "t6_debug_hosted_${OS}_$A" -- --arch=$A --target=$OS --debug "$T6_D/arr.kr"
    done
done
t6_builds "t6_debug_freestanding_x86_64" -- --arch=x86_64 --freestanding --debug "$T6_D/plain.kr"
t6_builds "t6_debug_freestanding_riscv32" -- --arch=riscv32 --freestanding --debug "$T6_D/plain.kr"
t6_builds "t6_debug_freestanding_xtensa" -- --arch=xtensa --freestanding --debug "$T6_D/plain.kr"

# 2. --legacy + --target=none. The legacy backend has its own builtin
#    dispatch and no @builtin_override routing, so print/println/print_str/
#    println_str cannot work there on bare metal at all. Refused explicitly
#    rather than left to fail per-builtin, so that a bare-metal build never
#    silently selects the strictly less capable of two backends.
for A in x86_64 arm64 riscv32 xtensa; do
    t6_refuses "t6_legacy_tnone_$A" "--legacy" "--target=none" -- \
        --legacy --arch=$A --target=none "$T6_D/plain.kr"
done
# --legacy is meaningless alongside --emit=obj (obj always uses the legacy
# codegen). Refused anyway: the flag is an explicit request for a backend, and
# under --target=none that request is refused whatever else is on the line.
t6_refuses "t6_legacy_obj_tnone" "--legacy" "--target=none" -- \
    --legacy --emit=obj --arch=x86_64 --target=none "$T6_D/plain.kr"
# --legacy elsewhere is untouched.
for A in x86_64 arm64; do
    t6_builds "t6_legacy_hosted_$A" -- --legacy --arch=$A --target=linux "$T6_D/plain.kr"
    t6_builds "t6_legacy_freestanding_$A" -- --legacy --arch=$A --freestanding "$T6_D/plain.kr"
done

# 5. --debug on ANY path that reaches legacy arm64 codegen. codegen_aarch64
#    .kr has no array-bounds-check machinery at all (arr_count_lookup has 4
#    call sites -- codegen.kr:4457/:10403 legacy x86_64, ir.kr:3844/:4868 IR
#    x86_64 -- and none in codegen_aarch64.kr; arm64 IR checks via a
#    different mechanism, IR_ARR_CHECK op 131). Measured: `uint64[4] a;
#    a[99]` under --debug aborts (rc=1) on x86_64 legacy, x86_64 IR and
#    arm64 IR, but on legacy arm64 it silently prints a garbage value and
#    exits 0 (silent-and-exit-0 reproduces every time; the specific value
#    read does not). --debug is a safety promise; refuse rather than ship
#    it unmet with no diagnostic.
#
#    The rule is DERIVED from the codegen dispatch (arch == 1 &&
#    (emit_ir_mode == 0 || emit_mode == 3 || emit_mode == 7)), not
#    enumerated: --legacy is the obvious way in, but --emit=obj (3) and
#    --emit=lkm (7) select legacy on arm64 unconditionally, even with no
#    --legacy on the line at all (both need it for extern relocations).
#    Verified below by exhaustively trying --arch=arm64 --debug against
#    every --emit= spelling this compiler accepts today (a hardcoded
#    28-item list, checked against itself for count and NOT independently
#    cross-checked against src/main.kr here -- emit_valid_list_is_complete
#    elsewhere in this file is what derives the spelling set mechanically
#    from src/main.kr's str_eq_full(emit_str, ...) arms and would catch a
#    spelling this list drifted out of sync with; --help is not that check,
#    it lists only 8 of the 28 accepted spellings).
t6_refuses "t6_legacy_arm64_debug_refused" "--debug" "--legacy" -- \
    --legacy --arch=arm64 --debug "$T6_D/arr.kr"
# --emit=obj reaches legacy arm64 codegen with NO --legacy anywhere on the
# line -- this is the case that was missed until the rule was derived from
# the dispatch instead of enumerated from the two cases known at the time.
t6_refuses "t6_emit_obj_arm64_debug_refused" "--debug" "--emit=obj" -- \
    --arch=arm64 --emit=obj --debug "$T6_D/arr.kr"
# --emit=lkm reaches it too (same dispatch condition). It is ALSO refused
# for an unrelated reason (x86_64-only), but that check runs later --
# measured, THIS refusal wins, so the message really is the --debug one
# (t6_refuses pins both "--debug" and "arm64", so this does assert which
# message wins, not just that some refusal fired).
t6_refuses "t6_emit_lkm_arm64_debug_refused" "--debug" "arm64" -- \
    --arch=arm64 --emit=lkm --debug "$T6_D/arr.kr"
# --legacy + arm64 WITHOUT --debug must keep working (also covered by
# t6_legacy_hosted_arm64 above; repeated here with the exact repro flags,
# no --target=, for direct correspondence with the refusal case).
t6_builds "t6_legacy_arm64_no_debug_builds" -- --legacy --arch=arm64 "$T6_D/arr.kr"
# --emit=obj on arm64 WITHOUT --debug must also keep working -- it is the
# legacy backend's own normal path (obj always uses legacy, on any arch),
# untouched by this refusal because debug_mode == 0.
t6_builds "t6_emit_obj_arm64_no_debug_builds" -- --arch=arm64 --emit=obj "$T6_D/arr.kr"
# The fat-binary path (no --arch at all -- bare `krc` emits a FAT binary)
# reaches the same defective slice: compile_fat's arm64 slices honor
# --legacy exactly like the single-target path, and the default fat build
# (no --targets=) always includes all 4 arm64 (OS, arch) slices. Refuse
# there too, deliberately, rather than let it through by accident.
t6_refuses "t6_legacy_debug_fat_refused" "--debug" "--legacy" -- \
    --legacy --debug "$T6_D/arr.kr"

# Exhaustive check: every --emit= spelling this compiler accepts today,
# against --arch=arm64 --debug, with NO --legacy. Per the derived rule,
# exactly two (obj, lkm) should reach legacy arm64 codegen and be refused;
# every other spelling must still build (image/uefi refuse too, but for the
# unrelated "requires --target=none" reason -- not exercised here since no
# --target= is passed, so they hit that refusal first regardless of
# --debug). The 28-item list below is a hardcoded snapshot, not derived
# from source -- the count check just below only catches this list being
# edited down, not the compiler's accepted-spelling set drifting away from
# it. emit_valid_list_is_complete (elsewhere in this file) is the test that
# derives the spelling set mechanically from src/main.kr's
# str_eq_full(emit_str, ...) arms and would actually catch that drift.
EMIT_SPELLINGS="elfexe elf elf-arm64 elf-x86_64 linux linux-x86_64 linux-arm64 linux-x86-64 macho mac macos mac-x64 mac-arm64 darwin windows windows-x64 windows-arm64 win win-x64 win-arm64 pe obj android asm ir lkm image uefi"
EMIT_SPELLING_COUNT=$(echo $EMIT_SPELLINGS | wc -w)
TOTAL=$((TOTAL + 1))
if [ "$EMIT_SPELLING_COUNT" != "28" ]; then
    echo "FAIL: t6_emit_spelling_count (EMIT_SPELLINGS above was edited to $EMIT_SPELLING_COUNT entries, expected 28 -- this only catches an edit to the literal list, not the compiler's spelling set changing; see emit_valid_list_is_complete for that)"
    FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1)); echo "  t6_emit_spelling_count: PASS (28)"
fi
ES_BAD=""
for ES in $EMIT_SPELLINGS; do
    TOTAL=$((TOTAL + 1))
    rm -f "$T6_D/es_out"
    ES_ERR=$("$T6_KRC" --arch=arm64 --debug --emit=$ES "$T6_D/arr.kr" -o "$T6_D/es_out" 2>&1); ES_ST=$?
    ES_WANT_REFUSED=0
    if [ "$ES" = "obj" ] || [ "$ES" = "lkm" ]; then ES_WANT_REFUSED=1; fi
    if [ "$ES_WANT_REFUSED" = "1" ]; then
        if [ "$ES_ST" != "0" ] && [ ! -f "$T6_D/es_out" ]; then
            PASS=$((PASS + 1))
        else
            echo "FAIL: t6_emit_spelling_$ES (expected refused, got exit $ES_ST, artifact $([ -f "$T6_D/es_out" ] && echo present || echo absent))"
            FAIL=$((FAIL + 1)); ES_BAD="$ES_BAD $ES"
        fi
    else
        # image/uefi need --target=none (a different, already-tested
        # refusal) so they fail here too, for the OTHER reason -- assert
        # only that the message names --target=none, not --debug, so a
        # future change that makes them ALSO reach legacy arm64 codegen
        # (and starts refusing for THIS reason without --target=none) would
        # still be caught.
        if [ "$ES" = "image" ] || [ "$ES" = "uefi" ]; then
            if [ "$ES_ST" != "0" ] && echo "$ES_ERR" | grep -q -- "--target=none"; then
                PASS=$((PASS + 1))
            else
                echo "FAIL: t6_emit_spelling_$ES (expected the --target=none refusal, got exit $ES_ST: '$ES_ERR')"
                FAIL=$((FAIL + 1)); ES_BAD="$ES_BAD $ES"
            fi
        elif [ "$ES" = "ir" ]; then
            # --emit=ir dumps to STDOUT and ignores -o (see the
            # emit_accept_ir row elsewhere in this file) -- success is a
            # clean exit with a non-empty dump, not an -o artifact.
            if [ "$ES_ST" = "0" ] && [ -n "$ES_ERR" ]; then
                PASS=$((PASS + 1))
            else
                echo "FAIL: t6_emit_spelling_$ES (expected an IR dump on stdout, got exit $ES_ST: '$ES_ERR')"
                FAIL=$((FAIL + 1)); ES_BAD="$ES_BAD $ES"
            fi
        elif [ "$ES_ST" = "0" ] && [ -f "$T6_D/es_out" ]; then
            PASS=$((PASS + 1))
        else
            echo "FAIL: t6_emit_spelling_$ES (expected to build, got exit $ES_ST: '$ES_ERR')"
            FAIL=$((FAIL + 1)); ES_BAD="$ES_BAD $ES"
        fi
    fi
    rm -f "$T6_D/es_out"
done
if [ -z "$ES_BAD" ]; then
    echo "  t6_emit_spelling_enumeration: PASS (28/28 -- reaches-legacy-arm64 is exactly {obj, lkm})"
else
    echo "  t6_emit_spelling_enumeration: see failures above for:$ES_BAD"
fi

# An actual out-of-bounds index, to prove the STILL-WORKING configs really
# do trap rather than merely "not refuse" -- the refusal above must not
# have accidentally widened into something that also swallows these.
printf 'fn main() {\n    uint64[4] a\n    uint64 v = a[99]\n    println(v)\n    exit(0)\n}\n' > "$T6_D/oob.kr"

# arm64 IR: this row EXECUTES its artifact, so it is built for arm64
# deliberately and run under qemu-aarch64-static rather than natively --
# never native-executed on a mismatched host.
if [ -n "$QEMU_A64" ]; then
    TOTAL=$((TOTAL + 1))
    if $T6_KRC --arch=arm64 --debug "$T6_D/oob.kr" -o "$T6_D/oob_ir_a64" >/dev/null 2>&1; then
        chmod +x "$T6_D/oob_ir_a64"
        $QEMU_A64 "$T6_D/oob_ir_a64" >/dev/null 2>&1
        oob_ir_a64_st=$?
        if [ "$oob_ir_a64_st" != "0" ]; then
            PASS=$((PASS + 1)); echo "  t6_debug_arm64_ir_still_traps: PASS (exit $oob_ir_a64_st)"
        else
            echo "FAIL: t6_debug_arm64_ir_still_traps (exit 0 -- bounds check missing)"; FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL: t6_debug_arm64_ir_still_traps (build failed)"; FAIL=$((FAIL + 1))
    fi
    rm -f "$T6_D/oob_ir_a64"
else
    echo "  t6_debug_arm64_ir_still_traps: SKIP (no qemu-aarch64-static)"
fi

# x86_64 legacy and x86_64 obj: these rows EXECUTE their artifact natively
# (no emulator), so they are gated on $RUN_ARCH == x86_64 rather than
# pinning --arch=x86_64 unconditionally -- pinning it and running natively
# on a mismatched host (e.g. an arm64 CI runner) would give exit 126
# (cannot execute), which reads as a wrong answer rather than a wrong arch.
if [ "$RUN_ARCH" = "x86_64" ]; then
    TOTAL=$((TOTAL + 1))
    if $T6_KRC --legacy --arch=x86_64 --debug "$T6_D/oob.kr" -o "$T6_D/oob_leg_x64" >/dev/null 2>&1; then
        chmod +x "$T6_D/oob_leg_x64"
        "$T6_D/oob_leg_x64" >/dev/null 2>&1
        oob_leg_x64_st=$?
        if [ "$oob_leg_x64_st" != "0" ]; then
            PASS=$((PASS + 1)); echo "  t6_debug_legacy_x86_64_still_traps: PASS (exit $oob_leg_x64_st)"
        else
            echo "FAIL: t6_debug_legacy_x86_64_still_traps (exit 0 -- bounds check missing)"; FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL: t6_debug_legacy_x86_64_still_traps (build failed)"; FAIL=$((FAIL + 1))
    fi
    rm -f "$T6_D/oob_leg_x64"

    # --emit=obj is the other newly-widened case: on x86_64 (arch == 0) it
    # never matched the widened rule (which is arm64-only), so it must
    # still build under --debug AND the emitted relocatable object must
    # still bounds-check once linked. Mirrors the extern_resolved_via_obj
    # _link gate above (gcc, -no-pie, x86_64 host toolchain).
    if command -v gcc > /dev/null 2>&1; then
        TOTAL=$((TOTAL + 1))
        if $T6_KRC --arch=x86_64 --emit=obj --debug "$T6_D/oob.kr" -o "$T6_D/oob_obj_x64.o" >/dev/null 2>&1 \
           && gcc "$T6_D/oob_obj_x64.o" -o "$T6_D/oob_obj_x64" -no-pie >/dev/null 2>&1; then
            "$T6_D/oob_obj_x64" >/dev/null 2>&1
            oob_obj_x64_st=$?
            if [ "$oob_obj_x64_st" != "0" ]; then
                PASS=$((PASS + 1)); echo "  t6_debug_obj_x86_64_still_traps: PASS (exit $oob_obj_x64_st)"
            else
                echo "FAIL: t6_debug_obj_x86_64_still_traps (exit 0 -- bounds check missing)"; FAIL=$((FAIL + 1))
            fi
        else
            echo "FAIL: t6_debug_obj_x86_64_still_traps (build or link failed)"; FAIL=$((FAIL + 1))
        fi
        rm -f "$T6_D/oob_obj_x64.o" "$T6_D/oob_obj_x64"
    else
        echo "  t6_debug_obj_x86_64_still_traps: SKIP (no gcc)"
    fi
else
    echo "  t6_debug_legacy_x86_64_still_traps: SKIP (RUN_ARCH=$RUN_ARCH, not x86_64)"
    echo "  t6_debug_obj_x86_64_still_traps: SKIP (RUN_ARCH=$RUN_ARCH, not x86_64)"
fi
rm -f "$T6_D/oob.kr"

# 3. Every remaining --emit= mode gets a DEFINED outcome under --target=none.
#    macho and pe are OS containers -- a Mach-O needs dyld and LC_MAIN, a PE
#    needs the Windows loader and an import table -- and before this both
#    produced one, filled with bare-metal codegen, exit 0.
t6_refuses "t6_emit_macho_tnone" "--emit=macho" "--target=none" -- \
    --emit=macho --arch=x86_64 --target=none "$T6_D/plain.kr"
t6_refuses "t6_emit_pe_tnone" "--emit=pe" "--target=none" -- \
    --emit=pe --arch=x86_64 --target=none "$T6_D/plain.kr"
# The macos/darwin and windows/win/win-x64 spellings alias to the same
# emit_mode, so they must refuse too -- a check keyed on the spelling rather
# than on the resolved mode would let --emit=darwin through.
t6_refuses "t6_emit_darwin_tnone" "--emit=macho" "--target=none" -- \
    --emit=darwin --arch=x86_64 --target=none "$T6_D/plain.kr"
t6_refuses "t6_emit_winx64_tnone" "--emit=pe" "--target=none" -- \
    --emit=win-x64 --arch=arm64 --target=none "$T6_D/plain.kr"
#    obj is ALLOWED and that is a decision, not an omission: a relocatable
#    object is the normal bare-metal deliverable (you link it with your own
#    script at your own load address), it is the only relocatable output this
#    compiler has, and it is the path that keeps the legacy codegen's
#    bare-metal guards reachable -- every legacy assertion in the blocks below
#    runs through --emit=obj for exactly that reason.
t6_builds "t6_emit_obj_tnone_x86_64" -- --emit=obj --arch=x86_64 --target=none "$T6_D/plain.kr"
t6_builds "t6_emit_obj_tnone_arm64" -- --emit=obj --arch=arm64 --target=none "$T6_D/plain.kr"
t6_builds "t6_emit_obj_tnone_c_shorthand" -- -c --arch=x86_64 --target=none "$T6_D/plain.kr"
#    elfexe is the default and stays the default.
t6_builds "t6_emit_elfexe_tnone" -- --emit=elfexe --arch=x86_64 --target=none "$T6_D/plain.kr"
#    asm and ir are TEXT: they describe the build, they are not loaded by
#    anything, and --emit=ir under --target=none is already the oracle the
#    provider-routing tests read. Assert the content, not just the exit code:
#    an empty stream would satisfy exit 0.
TOTAL=$((TOTAL + 1))
T6_OUT=$("$T6_KRC" --emit=asm --arch=x86_64 --target=none "$T6_D/plain.kr" -o "$T6_D/a.s" 2>&1)
if [ -f "$T6_D/a.s" ] && grep -q "main" "$T6_D/a.s"; then
    PASS=$((PASS + 1)); echo "  t6_emit_asm_tnone: PASS"
else
    echo "FAIL: t6_emit_asm_tnone (no listing naming main: '$T6_OUT')"; FAIL=$((FAIL + 1))
fi
rm -f "$T6_D/a.s"
TOTAL=$((TOTAL + 1))
T6_OUT=$("$T6_KRC" --emit=ir --arch=x86_64 --target=none "$T6_D/plain.kr" 2>&1)
if echo "$T6_OUT" | grep -q "^function main:"; then
    PASS=$((PASS + 1)); echo "  t6_emit_ir_tnone: PASS"
else
    echo "FAIL: t6_emit_ir_tnone (no IR dump for main: '$T6_OUT')"; FAIL=$((FAIL + 1))
fi
# lkm and android were already refused (Task 1) and stay refused -- pinned
# here alongside their siblings so the emit-mode table is complete in one
# place rather than split across two blocks.
t6_refuses "t6_emit_lkm_tnone" "--emit=lkm" "--target=none" -- \
    --emit=lkm --arch=x86_64 --target=none "$T6_D/plain.kr"
t6_refuses "t6_emit_android_tnone" "--emit=android" "--target=none" -- \
    --emit=android --arch=arm64 --target=none "$T6_D/plain.kr"
#    image (8) and uefi (9) are the two bare-metal modes and BOTH WERE MISSING
#    from this table while its comment claimed completeness -- the exact defect
#    D Task 4 was written to sweep for. They belong here even though each has
#    its own dedicated block further down: this table is the one place that
#    answers "what does every emit mode do under --target=none", and a mode
#    whose answer lives only in its own block is a mode this table cannot
#    speak for. Both REQUIRE --target=none rather than merely tolerating it,
#    which is a third outcome the table had no example of.
t6_builds "t6_emit_image_tnone" -- --emit=image --arch=x86_64 --target=none --load-addr=0x400000 "$T6_D/plain.kr"
t6_builds "t6_emit_uefi_tnone" -- --emit=uefi --arch=x86_64 --target=none "$T6_D/plain.kr"
t6_builds "t6_emit_arx_tnone" -- --emit=arx --arch=x86_64 --target=none "$T6_D/plain.kr"

# 3b. COMPLETENESS, DERIVED RATHER THAN ASSERTED.
#     The comment on block 3 says the emit-mode table is complete in one place.
#     That sentence was FALSE for two whole modes and nothing noticed, because
#     nothing checked it -- a hand-written table cannot know about a mode
#     nobody added to it. So the roster below is compared against the set of
#     emit_mode values the compiler actually assigns, read out of the source
#     that assigns them. Add an `emit_mode = 10` arm without a row here and
#     this reds; that is the whole point, and it is why the check is on the
#     MODE NUMBERS and not on the spellings (16 of the 28 spellings are
#     aliases for a mode some other spelling already covers).
T6_MODE_ROWS="0:t6_emit_elfexe_tnone 1:t6_emit_macho_tnone 2:t6_emit_pe_tnone 3:t6_emit_obj_tnone_x86_64 4:t6_emit_android_tnone 5:t6_emit_asm_tnone 6:t6_emit_ir_tnone 7:t6_emit_lkm_tnone 8:t6_emit_image_tnone 9:t6_emit_uefi_tnone 10:t6_emit_arx_tnone"
TOTAL=$((TOTAL + 1))
T6_MODES_SRC=$(grep -oE 'emit_mode = [0-9]+' "$DIR/../src/main.kr" | grep -oE '[0-9]+$' | sort -un | tr '\n' ' ')
T6_MODES_TBL=$(for p in $T6_MODE_ROWS; do echo "${p%%:*}"; done | sort -un | tr '\n' ' ')
# The NAME half, which the first version of this check parsed and then threw
# away -- so it printed "each with a named row" while deleting the real
# uefi row left it green. A roster entry now has to point at a row that
# EXISTS, and "exists" means an INVOCATION, not a mention: the name must
# appear either as `t6_builds "<name>"` / `t6_refuses "<name>"` or as the
# `"  <name>: PASS` line of a hand-rolled row.
#
# THE FIRST ATTEMPT AT THIS WAS "the name occurs on some line other than the
# T6_MODE_ROWS line", AND IT WAS DEFEATED BY THIS VERY COMMENT -- the red
# experiment deleted the uefi row and the check stayed green, because the
# comment above named it. A check that a prose mention can satisfy is the
# same class of defect it exists to catch, which is why it is anchored to the
# call syntax now and why the offending word is not repeated here.
T6_NOROW=""
for p in $T6_MODE_ROWS; do
    t6_rn="${p#*:}"
    grep -qE "^t6_(builds|refuses) \"$t6_rn\"|\"  $t6_rn: PASS" "$DIR/run_tests.sh" \
        || T6_NOROW="$T6_NOROW $t6_rn"
done
if [ -z "$T6_MODES_SRC" ]; then
    echo "FAIL: t6_emit_table_covers_every_mode (could not read any 'emit_mode = N' assignment out of src/main.kr -- the derivation broke, which would make this check vacuous)"
    FAIL=$((FAIL + 1))
elif [ -n "$T6_NOROW" ]; then
    echo "FAIL: t6_emit_table_covers_every_mode (T6_MODE_ROWS names rows that do not exist in this file:$T6_NOROW -- the roster is a promise, not the coverage)"
    FAIL=$((FAIL + 1))
elif [ "$T6_MODES_SRC" = "$T6_MODES_TBL" ]; then
    PASS=$((PASS + 1)); echo "  t6_emit_table_covers_every_mode: PASS ($(echo "$T6_MODES_TBL" | wc -w | tr -d ' ') modes, each naming a row that exists)"
else
    echo "FAIL: t6_emit_table_covers_every_mode (src/main.kr assigns emit_mode values [$T6_MODES_SRC]; this block's roster covers [$T6_MODES_TBL]. Add the missing mode's row to block 3 and its entry to T6_MODE_ROWS)"
    FAIL=$((FAIL + 1))
fi

# 4. arch x OS pairs. `--arch=riscv32 --target=windows` exited 0 and wrote a
#    RISC-V ELF; nothing anywhere validated the combination.
for OS in macos windows android; do
    t6_refuses "t6_pair_riscv32_$OS" "--arch=riscv32" "--target=$OS" -- \
        --arch=riscv32 --target=$OS "$T6_D/plain.kr"
    t6_refuses "t6_pair_xtensa_$OS" "--arch=xtensa" "--target=$OS" -- \
        --arch=xtensa --target=$OS "$T6_D/plain.kr"
done
# --emit=macho / --emit=pe set target_os with no --target= on the line at all,
# so the check has to run on the RESOLVED OS, after that auto-set, or these
# two slip through.
t6_refuses "t6_pair_riscv32_emit_pe" "--arch=riscv32" "--target=windows" -- \
    --arch=riscv32 --emit=pe "$T6_D/plain.kr"
t6_refuses "t6_pair_xtensa_emit_macho" "--arch=xtensa" "--target=macos" -- \
    --arch=xtensa --emit=macho "$T6_D/plain.kr"
# Every LEGAL pair still passes validation. x86_64/arm64 x 5 build outright.
for A in x86_64 arm64; do
    for OS in linux macos windows android none; do
        t6_builds "t6_pair_ok_${A}_$OS" -- --arch=$A --target=$OS "$T6_D/plain.kr"
    done
done
# riscv32 x {linux, none} build outright. xtensa x none builds; xtensa x linux
# is legal to REQUEST -- it is the default OS value every `--arch=xtensa
# --freestanding` build already carries -- but hosted Xtensa ELF emission is
# still NYI, so it must fail with THAT message and not with the pair message.
# Asserting which failure it is, rather than skipping it, is the point: a
# pair check that rejected it would break every existing xtensa invocation.
t6_builds "t6_pair_ok_riscv32_linux" -- --arch=riscv32 --target=linux "$T6_D/plain.kr"
t6_builds "t6_pair_ok_riscv32_none" -- --arch=riscv32 --target=none "$T6_D/plain.kr"
t6_builds "t6_pair_ok_xtensa_none" -- --arch=xtensa --target=none "$T6_D/plain.kr"
t6_builds "t6_pair_ok_xtensa_freestanding" -- --arch=xtensa --freestanding "$T6_D/plain.kr"
TOTAL=$((TOTAL + 1))
T6_OUT=$("$T6_KRC" --arch=xtensa --target=linux "$T6_D/plain.kr" -o "$T6_D/out" 2>&1)
if echo "$T6_OUT" | grep -q "not a supported target pair"; then
    echo "FAIL: t6_pair_ok_xtensa_linux (rejected by the pair check; every --arch=xtensa --freestanding build carries target_os=0)"
    FAIL=$((FAIL + 1))
elif echo "$T6_OUT" | grep -q "xtensa ELF image emission not yet implemented"; then
    PASS=$((PASS + 1)); echo "  t6_pair_ok_xtensa_linux: PASS"
else
    echo "FAIL: t6_pair_ok_xtensa_linux (unexpected: '$T6_OUT')"; FAIL=$((FAIL + 1))
fi
rm -f "$T6_D/out"

# The pair table must stay an ALLOW-list. A blacklist ("reject riscv32+macos,
# riscv32+windows, ...") passes every test above and silently admits the next
# arch or OS someone adds -- which is the same else-assume-POSIX shape that
# put a Linux exit syscall in a bare-metal image in the first place. Assert
# the SHAPE of the function: every `return 1` in it is guarded by an explicit
# `if os == <n>`, and the function ends by returning 0.
TOTAL=$((TOTAL + 1))
T6_BAD=$(SRCDIR="$DIR/../src" python3 - <<'T6PY'
import os, re
src = open(os.path.join(os.environ["SRCDIR"], "main.kr")).read()
m = re.search(r"\nfn arch_os_pair_supported\(.*?\n\}\n", src, re.S)
bad = []
if not m:
    bad.append("arch_os_pair_supported not found in main.kr")
else:
    body = m.group(0)
    lines = [l.split("//")[0].rstrip() for l in body.splitlines()]
    for i, l in enumerate(lines):
        if "return 1" in l and not re.search(r"if\s+os\s*==\s*\d+\s*\{\s*return 1\s*\}", l):
            bad.append("unguarded `return 1` at body line %d: %r" % (i, l.strip()))
    tail = [l.strip() for l in lines if l.strip()]
    if tail[-1] != "}" or tail[-2] != "return 0":
        bad.append("function does not end in `return 0`; tail is %r" % tail[-3:])
print("; ".join(bad))
T6PY
)
if [ -z "$T6_BAD" ]; then
    PASS=$((PASS + 1)); echo "  t6_pair_table_is_allowlist: PASS"
else
    echo "FAIL: t6_pair_table_is_allowlist ($T6_BAD)"; FAIL=$((FAIL + 1))
fi

rm -rf "$T6_D"

# --- --emit=image / --load-addr flag surface (sub-project B1) ---
# Every interaction enumerated, none left to discovery. Each refusal names
# both flags; artifact absence is asserted alongside the message because a
# diagnostic that still writes output is half a refusal.
echo ""
echo "--- --emit=image / --load-addr flag surface ---"
IMG_SRC="$DIR/../test_tmp_img_$$.kr"
printf 'fn main() -> uint64 { return 7 }\n' > "$IMG_SRC"
img_refuses() {  # $1 name, $2 grep pattern, rest = flags
    local name="$1" pat="$2"; shift 2
    TOTAL=$((TOTAL + 1))
    rm -f /tmp/krc_img_$$
    local out; out=$($KRC $KRC_FLAGS "$IMG_SRC" -o /tmp/krc_img_$$ "$@" 2>&1); local st=$?
    if [ $st -ne 0 ] && echo "$out" | grep -q "$pat" && [ ! -f /tmp/krc_img_$$ ]; then
        PASS=$((PASS + 1)); echo "  $name: PASS"
    else
        echo "FAIL: $name (exit=$st, artifact=$([ -f /tmp/krc_img_$$ ] && echo yes || echo no), out=$(echo "$out" | head -1))"
        FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_img_$$
}
# img_refuses() puts its flags AFTER the input path and -o. That is fine for
# every row whose flag is one the parser already recognizes (the refusal is
# semantic -- e.g. "requires --target=none" -- and fires the same regardless
# of where the flag sits). It is NOT fine for a row whose entire point is an
# UNRECOGNIZED spelling (`--image-header=1`, `--reset-vector=1`): the parser's
# fallback for anything it doesn't match is `else { input_path = arg }`, so
# putting the unrecognized flag after "$IMG_SRC" -o ... makes it silently
# reassign input_path instead, and the run then fails for the WRONG reason
# ("cannot open '--image-header=1'") rather than the one the row's comment
# describes. Verified against a build of main.kr at 9e5fc70 (one commit
# before the fix that made these two spellings recognized): with flags
# after the path, imghdr_rejects_value's args produced "cannot open
# '--image-header=1'" and reset_vector_rejects_value's produced the
# unrelated pre-existing "--emit=image requires --load-addr" (that row was
# also missing --load-addr=, needed once flags move earlier); with flags
# BEFORE the path on that same pre-fix build, both instead produced the
# actual silently-swallowed-flag defect the comments describe: exit 0 and
# an unflagged/wrong-mode artifact.
img_refuses_flags_first() {  # $1 name, $2 grep pattern, rest = flags (before the input path)
    local name="$1" pat="$2"; shift 2
    TOTAL=$((TOTAL + 1))
    rm -f /tmp/krc_img_$$
    local out; out=$($KRC $KRC_FLAGS "$@" "$IMG_SRC" -o /tmp/krc_img_$$ 2>&1); local st=$?
    if [ $st -ne 0 ] && echo "$out" | grep -q "$pat" && [ ! -f /tmp/krc_img_$$ ]; then
        PASS=$((PASS + 1)); echo "  $name: PASS"
    else
        echo "FAIL: $name (exit=$st, artifact=$([ -f /tmp/krc_img_$$ ] && echo yes || echo no), out=$(echo "$out" | head -1))"
        FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_img_$$
}
# 1. image without --target=none (default OS = linux): refused, naming why.
img_refuses image_needs_target_none "requires --target=none" --arch=x86_64 --emit=image --load-addr=0x400000
# 2. image with a HOSTED --target: same refusal (the rule is about the
#    resolved OS, not about the flag's absence).
img_refuses image_hosted_target_refused "requires --target=none" --arch=arm64 --target=macos --emit=image --load-addr=0x40400000
# 3-4. riscv32/xtensa: refused, naming the raw path each arch already owns.
#    The xtensa pattern is a substring UNIQUE to the xtensa message --
#    "x86_64/arm64 only" appears in both messages, so grepping it would let
#    a defect that routes xtensa to the riscv32 refusal pass.
img_refuses image_riscv32_refused "already emits a raw boot image" --arch=riscv32 --target=none --emit=image --load-addr=0x80000000
img_refuses image_xtensa_refused "xtensa raw emission" --arch=xtensa --target=none --emit=image --load-addr=0xd0000000
# 5. image without --load-addr: refused.
img_refuses image_needs_load_addr "requires --load-addr" --arch=x86_64 --target=none --emit=image
# 6. arm64 unaligned load addr: refused, and the message states the
#    asymmetry (x86_64 accepts any address) -- a shared diagnostic would be
#    wrong on one arch (spec R2).
img_refuses image_a64_unaligned_refused "must be 4096-aligned on arm64" --arch=arm64 --target=none --emit=image --load-addr=0x40400100
# 7. --load-addr without --emit=image: refused. Pinned because BEFORE this
#    commit the flag was silently consumed as an input filename (V7).
img_refuses load_addr_needs_image "only meaningful with --emit=image" --arch=x86_64 --load-addr=0x400000
# 8-9. malformed values: refused at parse, not silently zero.
img_refuses load_addr_bad_hex "decimal or 0x-prefixed hex" --arch=x86_64 --target=none --emit=image --load-addr=0xZZ
img_refuses load_addr_empty "decimal or 0x-prefixed hex" --arch=x86_64 --target=none --emit=image --load-addr=
# 10. -g with image: refused (the DWARF footer would land inside the blob).
img_refuses image_dash_g_refused "conflicts with --emit=image" --arch=arm64 --target=none --emit=image --load-addr=0x40400000 -g
# 11. --legacy with image: the existing target=none refusal fires (pinned so
#     check ordering can never quietly reopen it).
img_refuses image_legacy_refused "conflicts with --target=none" --arch=x86_64 --target=none --emit=image --load-addr=0x400000 --legacy
# 12. --emit last-wins: elfexe then image behaves as image (the refusal
#     proves image won the chain).
img_refuses image_emit_last_wins "requires --target=none" --arch=x86_64 --emit=elfexe --emit=image --load-addr=0x400000
# 13. --load-addr=0: refused. Zero parses fine and passes the arm64
#     alignment check, but is indistinguishable from unset in every report
#     and stub that consumes it.
img_refuses image_load_addr_zero_refused "load-addr=0 is refused" --arch=arm64 --target=none --emit=image --load-addr=0
# 14-15. --targets= interactions (V12: --targets FORCES the fat path even
#     with --emit=). Safe only by check ordering -- these rows pin it
#     so a reorder cannot reopen A's Task-1 fat-path Critical.
img_refuses image_targets_no_none "requires --target=none" --arch=x86_64 --emit=image --load-addr=0x400000 --targets=linux-x64
img_refuses image_targets_with_none "cannot build a fat binary" --arch=x86_64 --target=none --emit=image --load-addr=0x400000 --targets=linux-x64

# 16. NO --arch AT ALL: must refuse. V11: with emit_set=1 the fat-guard
#     "pass --arch" refusal never fires and arch silently defaults to
#     x86_64 -- which would skip the arm64 alignment validation entirely.
#     Uses the RAW build/krc2: the make-test wrapper injects --arch=x86_64,
#     which is the exact condition under test.
TOTAL=$((TOTAL + 1))
if [ -f "$DIR/../build/krc2" ]; then IMG_RAW_KRC=$(cd "$DIR/../build" && pwd)/krc2; else IMG_RAW_KRC=""; fi
rm -f /tmp/krc_imgna_$$
imgna_out=$("$IMG_RAW_KRC" "$IMG_SRC" -o /tmp/krc_imgna_$$ --target=none --emit=image --load-addr=0x40400100 2>&1); imgna_st=$?
if [ -n "$IMG_RAW_KRC" ] && [ $imgna_st -ne 0 ] \
   && echo "$imgna_out" | grep -q "requires an explicit --arch" && [ ! -f /tmp/krc_imgna_$$ ]; then
    PASS=$((PASS + 1)); echo "  image_needs_explicit_arch: PASS"
else
    echo "FAIL: image_needs_explicit_arch (exit=$imgna_st, out=$(echo "$imgna_out" | head -1))"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_imgna_$$

# 18. -g under --target=none WITHOUT image stays ACCEPTED -- pinned by
#     sub-project A; the new refusal must not widen.
TOTAL=$((TOTAL + 1))
if $KRC $KRC_FLAGS "$IMG_SRC" -o /tmp/krc_img_g_$$ --arch=arm64 --target=none -g >/dev/null 2>&1 && [ -f /tmp/krc_img_g_$$ ]; then
    PASS=$((PASS + 1)); echo "  target_none_dash_g_still_accepted: PASS"
else
    echo "FAIL: target_none_dash_g_still_accepted (A's pinned acceptance regressed)"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_img_g_$$
# $IMG_SRC IS DELETED AT THE END OF THE --stack-top= SECTION BELOW, NOT HERE.
# img_refuses() compiles $IMG_SRC, and every row it serves in that section used
# to run with the file already gone. Those rows still passed, because every
# diagnostic they assert is emitted during ARGUMENT VALIDATION, before the
# source is opened -- but that made them insensitive to their own input, and a
# refusal that fires any LATER (the finalize block's 1 GiB and stack-vs-image
# rules do) could not be written with img_refuses at all: it got
# "cannot open '...': file not found" instead. Keeping the source alive is
# what lets stacktop_arm64_refused_inside_image use the same helper.

# --- --stack-top= flag surface (sub-project B2) ---
# D4: the flag's PRESENCE is the opt-in for stub emission. THIS SECTION IS
# ABOUT THE FLAG SURFACE ONLY -- what the compiler accepts and what it
# refuses. The emitted bytes are pinned two sections down (the arm64 stub and
# the x86_64 multiboot header + trampoline), so an accept row here proves only
# that the compiler got past validation and wrote an artifact; row 5's accept,
# for one, now carries the full 226-byte x86 trampoline. Every refusal asserts
# THREE clauses via img_refuses(): nonzero exit, the diagnostic text, and no
# artifact written -- B1 Task 6 shipped a hole where a refusal that printed
# the right message, wrote nothing and exited 0 passed a two-clause check.
echo ""
echo "--- --stack-top= flag surface (B2) ---"
STK_SRC="$DIR/../test_tmp_stk_$$.kr"
printf 'fn main() -> uint64 { return 7 }\n' > "$STK_SRC"

# 1. --stack-top outside --emit=image: refused. Gated on --emit=image, NOT
#    --target=none (review I6) -- --target=none is the WIDER set (riscv32
#    and xtensa raw emission both live under it without this flag meaning
#    anything), so this row deliberately keeps --target=none on the line and
#    drops only --emit=image, to prove the gate is the narrower flag.
img_refuses stacktop_requires_image "only meaningful with --emit=image" --arch=arm64 --target=none --stack-top=0x40400000

# 2. arm64: a stack top that is not 16-byte aligned is refused -- aarch64
#    faults on the first SP-relative stack access otherwise, the same
#    constraint make_stub.py already enforces.
img_refuses stacktop_arm64_alignment "must be 16-byte aligned on arm64" --arch=arm64 --target=none --emit=image --load-addr=0x40400000 --stack-top=0x40500004

# 3. arm64: a stack top >= 2^32 is refused -- the movz/movk pair the stub
#    patches into the entry code covers bits 31:0 only. 0x100000000 is
#    itself 16-byte aligned, isolating the range check from row 2's.
img_refuses stacktop_range "must be below 2^32 on arm64" --arch=arm64 --target=none --emit=image --load-addr=0x40400000 --stack-top=0x100000000

# 4. --stack-top=0 is refused, arch-independently. Zero parses cleanly and
#    passes every alignment/range check on both arches, but is
#    indistinguishable from "unset" in every report and stub that will
#    consume it (mirrors --load-addr=0's existing refusal).
img_refuses stacktop_zero_refused "stack-top=0 is refused" --arch=x86_64 --target=none --emit=image --load-addr=0x400000 --stack-top=0

# 5. x86_64 ACCEPTS a stack top that is not 16-byte aligned -- the asymmetry
#    with arm64 is deliberate (D4) and must be pinned as an ACCEPT, not a
#    refusal: a shared alignment rule would be wrong on one of the two
#    arches. 0x90001 is neither 16-byte aligned nor 4-byte aligned.
TOTAL=$((TOTAL + 1))
rm -f /tmp/krc_stk_$$
if $KRC $KRC_FLAGS "$STK_SRC" -o /tmp/krc_stk_$$ --arch=x86_64 --target=none --emit=image --load-addr=0x400000 --stack-top=0x90001 >/dev/null 2>&1 \
   && [ -f /tmp/krc_stk_$$ ]; then
    PASS=$((PASS + 1)); echo "  stacktop_x86_accepts_unaligned_16: PASS"
else
    echo "FAIL: stacktop_x86_accepts_unaligned_16"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_stk_$$

# 6. x86_64 has its OWN range rule, independent of arm64's 2^32/alignment
#    rules (review C4/N2): a stack top >= 0x80000000 is refused because the
#    assembler widens `mov $imm,%rsp` from a 7-byte sign-extended form to a
#    10-byte movabs at that boundary, moving every later patch site while
#    the file stays 226 bytes (measured) -- a fixed-offset patch table would
#    silently patch the wrong bytes above this line.
img_refuses stacktop_x86_range "below 0x80000000 on x86_64" --arch=x86_64 --target=none --emit=image --load-addr=0x400000 --stack-top=0x80000000

# 6b. x86_64's other bound: a stack top whose first push lands in 0x1000-0x4000
#     collides with the boot stub's identity-map page tables and is refused.
#     Same row family as #6 -- both bounds come from the flag value alone, no
#     image size needed. The rules that DO need the image size (the 1 GiB fit
#     and the stack-vs-image overlap) fire in the --emit=image finalize and are
#     covered by rows 7-8 below, by stub_x86_stack_top_refused_inside_image and
#     by stub_x86_image_end_refused_above_map.
#
#     0x2000 IS THE INTERIOR OF THE BAND, not an edge. Both edges are pinned
#     separately by 6c-6e below, and they have to be: this row is green under
#     the wrong rule as well as the right one, which is how the off-by-eight
#     survived from Task 1 to the final review.
img_refuses stacktop_x86_range_collision "0x1000-0x4000 on x86_64" --arch=x86_64 --target=none --emit=image --load-addr=0x400000 --stack-top=0x2000

# 6c-6e. BOTH EDGES OF THAT BAND, because both were off by eight from Task 1
#     until the final review found it. The rule is about the trampoline's FIRST
#     PUSH, which writes [stack_top-8, stack_top) -- the same +8 convention row
#     7's stack-vs-image check uses -- and the shipped test was on the POINTER:
#
#       * 0x1000 was REFUSED. Its push lands at [0xFF8, 0x1000), entirely below
#         the page tables. A legal configuration was rejected.
#       * 0x4000 was ACCEPTED. Its push lands at [0x3FF8, 0x4000) -- the last
#         eight bytes of the page directory, i.e. PDE 511, which maps the top
#         2 MiB of the identity-mapped GiB. The guest overwrites an entry of
#         the map it is about to run under, silently and on its first call.
#
#     Both edges are pinned as rows because a one-sided fix is exactly how the
#     off-by-eight got here: the refusal above (6b, 0x2000) is green under BOTH
#     the wrong rule and the right one, so it could never have caught this.
#     0x4007 is the last refused value and 0x4008 the first accepted one.
stk_accepts() {   # $1 label, $2... krc args -- the accept twin of img_refuses
    local label="$1"; shift
    TOTAL=$((TOTAL + 1))
    local art=/tmp/krc_stk_acc_$$
    rm -f "$art"
    if $KRC $KRC_FLAGS "$STK_SRC" -o "$art" "$@" >/dev/null 2>&1 && [ -f "$art" ]; then
        PASS=$((PASS + 1)); echo "  $label: PASS"
    else
        echo "FAIL: $label (refused, or exited 0 without writing $art)"; FAIL=$((FAIL + 1))
    fi
    rm -f "$art"
}
stk_accepts stacktop_x86_page_table_low_edge_accepted \
    --arch=x86_64 --target=none --emit=image --load-addr=0x400000 --stack-top=0x1000
img_refuses stacktop_x86_page_table_high_edge_refused "0x1000-0x4000 on x86_64" \
    --arch=x86_64 --target=none --emit=image --load-addr=0x400000 --stack-top=0x4000
img_refuses stacktop_x86_page_table_last_refused "0x1000-0x4000 on x86_64" \
    --arch=x86_64 --target=none --emit=image --load-addr=0x400000 --stack-top=0x4007
stk_accepts stacktop_x86_page_table_first_accepted \
    --arch=x86_64 --target=none --emit=image --load-addr=0x400000 --stack-top=0x4008

# 7. arm64 refuses a stack top INSIDE THE IMAGE, exactly as x86_64 does.
#    This rule is architecture-independent -- the first push writes
#    [stack_top-8, stack_top) and overwriting the program's own bytes needs
#    no page tables -- but it shipped gated on `arch == 0`. Before the fix
#    this command exited 0 and wrote a 56-byte image whose first push landed
#    at 0x40400008, inside its own code, while the x86_64 twin
#    (stub_x86_stack_top_refused_inside_image) refused the identical shape.
#    0x40400010 is 16-byte aligned and below 2^32, so rows 2 and 3's bounds
#    cannot be what refuses it.
img_refuses stacktop_arm64_refused_inside_image "starts inside the image" --arch=arm64 --target=none --emit=image --load-addr=0x40400000 --stack-top=0x40400010

# 8. ...and the boot gate's own arm64 pair still ACCEPTS. Row 7's rule fires
#    on a band eight bytes wide past the image end, so this row is the proof
#    that widening it did not make the gate's configuration illegal: the same
#    --load-addr with the gate's 0x40800000 stack top, 4 MiB clear of a ~1 KiB
#    image, must still compile and write an artifact.
TOTAL=$((TOTAL + 1))
rm -f /tmp/krc_stk_a64_$$
if $KRC $KRC_FLAGS "$STK_SRC" -o /tmp/krc_stk_a64_$$ --arch=arm64 --target=none --emit=image --load-addr=0x40400000 --stack-top=0x40800000 >/dev/null 2>&1 \
   && [ -f /tmp/krc_stk_a64_$$ ]; then
    PASS=$((PASS + 1)); echo "  stacktop_arm64_above_image_accepted: PASS"
else
    echo "FAIL: stacktop_arm64_above_image_accepted (the gate's own arm64 stack top is now refused)"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_stk_a64_$$

# --- --image-header flag surface (sub-project C, Task 1) ---
# Rows 1-3 are three-clause refusals via img_refuses(), same as the
# --stack-top= rows just above; a refused build produces no artifact, so no
# header is emitted on those three lines. Row 4 is the one ACCEPTED case
# (--emit=image, --arch=arm64, --stack-top= all present), and since Task 2 it
# DOES emit a real 64-byte header -- this section stopped being emission-free
# then, whatever its heading still says about Task 1.
#
# WHAT ROW 4 PROVES IS PURE-PREFIX, NOT BYTE-NEUTRALITY. Two different claims:
#   * pure-prefix  -- the FLAGGED artifact is the UNFLAGGED one with exactly 64
#     bytes in front of it. That is row 4, in three clauses, below.
#   * byte-neutrality -- the UNFLAGGED artifact is bit-identical to what this
#     compiler produced BEFORE the flag existed. NO ROW IN THIS TREE PROVES
#     THAT. It was measured once, off-tree, against a compiler built from the
#     branch point across 8 configurations; a measurement in a report is not a
#     check in a suite.
# What row 4 does bound is the regression that matters most here: if the header
# were ever emitted WITHOUT the flag, both builds would grow by 64 and clause 2
# (flagged == unflagged + 64) would go red. That is a default-on guard, not a
# byte-neutrality proof.
#
# (Two earlier drafts of this comment were wrong in opposite directions: the
# first pointed at a "byte-neutrality section further down" that was never
# written, and its correction claimed row 4 was that proof. Neither held.)
echo ""
echo "--- --image-header flag surface (C, Task 1) ---"

# 1. --image-header without --stack-top=: refused. An otherwise-valid arm64
#    --emit=image line (arch, target, load-addr all present and legal) is
#    used so the ONLY thing missing is --stack-top=, isolating this refusal
#    from the arm64-only and emit=image-only ones below.
img_refuses imghdr_requires_stack_top "requires --stack-top=" --arch=arm64 --target=none --emit=image --load-addr=0x40400000 --image-header

# 2. --image-header on x86_64: refused, even with a --stack-top= that is
#    otherwise legal for x86_64's own multiboot path -- the header this flag
#    prefixes is arm64's Linux Image format, not x86_64's. --stack-top= is
#    included so this row cannot pass under row 1's rule instead of its own.
img_refuses imghdr_requires_arm64 "requires --arch=arm64" --arch=x86_64 --target=none --emit=image --load-addr=0x400000 --stack-top=0x90000 --image-header

# 3. --image-header outside --emit=image: refused. Mirrors
#    stacktop_requires_image above -- --target=none alone (no --emit=image)
#    is otherwise a legal, accepted build (target_none_dash_g_still_accepted,
#    named rather than by ordinal: ordinals rot the moment a row is inserted
#    above them), so --image-header is the only thing that can fail this line.
img_refuses imghdr_requires_emit_image "only meaningful with --emit=image" --arch=arm64 --target=none --image-header

# 3b. --image-header=<anything>: refused with a diagnostic, not silently
#     swallowed. --image-header is matched with str_eq_full, which matches
#     the bare spelling only, so `--image-header=1` used to fall through to
#     the final `else { input_path = arg }` and be silently ignored -- an
#     otherwise-valid build (same flags as imghdr_pure_prefix below) produced
#     the UNFLAGGED 56-byte artifact at exit 0 instead of the 120-byte
#     header-prefixed one, with no indication the flag had been dropped.
#     img_refuses_flags_first, not img_refuses: the unrecognized spelling
#     has to land BEFORE the input path or the parser's unrecognized-flag
#     fallback reassigns input_path to it instead, and the row fails for
#     "cannot open '--image-header=1'" rather than this claim.
img_refuses_flags_first imghdr_rejects_value "image-header takes no value" --arch=arm64 --target=none --emit=image --load-addr=0x40400000 --stack-top=0x40800000 --image-header=1

# 4. --image-header ACCEPTED on a valid arm64 config, and the header is a PURE
#    PREFIX: the flagged artifact is the unflagged one with exactly 64 bytes
#    in front of it.
#
#    THIS ROW REPLACES Task 1's `imghdr_task1_byte_neutral`, which asserted the
#    two builds were byte-IDENTICAL. That was true only while Task 1 emitted
#    nothing; Task 2 emits the real header, so identity is now the WRONG claim
#    and the old row was written to go red rather than quietly keep passing.
#    It was rewritten, not widened.
#
#    THREE CLAUSES, AND THE FIRST IS NOT DECORATION. The old row's guard was
#    `[ -f a ] && [ -f b ] && cmp -s a b`, and TWO EMPTY FILES satisfy all
#    three (confirmed by construction: `: > a; : > b; cmp -s a b` exits 0). A
#    +64 delta has the same hole -- 0 and 64 satisfy it as happily as 56 and
#    120 -- so the unflagged size is asserted NONZERO on its own. The three
#    clauses are:
#      1. size(unflagged) > 0        -- there is an artifact to prefix at all
#      2. size(flagged) == size(unflagged) + 64  -- exactly the header, no pad
#      3. bytes[64:] of flagged == bytes[0:] of unflagged
#
#    CLAUSE 3 IS NOT A CLAIM THAT THE PAYLOAD IS UNTOUCHED. It is a claim about
#    THIS program. `$STK_SRC` is `fn main() -> uint64 { return 7 }`, which has
#    no page-relative references, so its payload genuinely does not move when
#    the header shifts everything by 64. A program that DOES have them has its
#    ADRP page arithmetic re-baked around the header and its payload bytes
#    differ -- which is correct, and is what imghdr_page_refs_rebaked below
#    asserts positively. Do not generalise clause 3 into "the flag never
#    changes a payload byte"; that is false, and asserting it would forbid the
#    re-baking the header depends on.
ihdr_a=/tmp/krc_ihdr_a_$$
ihdr_b=/tmp/krc_ihdr_b_$$
rm -f "$ihdr_a" "$ihdr_b"
TOTAL=$((TOTAL + 1))
ihdr_sa=0; ihdr_sb=0
if $KRC $KRC_FLAGS "$STK_SRC" -o "$ihdr_a" --arch=arm64 --target=none --emit=image --load-addr=0x40400000 --stack-top=0x40800000 >/dev/null 2>&1 \
   && $KRC $KRC_FLAGS "$STK_SRC" -o "$ihdr_b" --arch=arm64 --target=none --emit=image --load-addr=0x40400000 --stack-top=0x40800000 --image-header >/dev/null 2>&1 \
   && [ -f "$ihdr_a" ] && [ -f "$ihdr_b" ]; then
    ihdr_sa=$(stat -c%s "$ihdr_a"); ihdr_sb=$(stat -c%s "$ihdr_b")
fi
if [ "$ihdr_sa" -gt 0 ] && [ "$ihdr_sb" = "$(( ihdr_sa + 64 ))" ] \
   && cmp -s <(tail -c +65 "$ihdr_b") "$ihdr_a"; then
    PASS=$((PASS + 1)); echo "  imghdr_pure_prefix: PASS ($ihdr_sa B + 64 = $ihdr_sb B, flagged[64:] == unflagged)"
else
    echo "FAIL: imghdr_pure_prefix (unflagged=$ihdr_sa B flagged=$ihdr_sb B, want flagged == unflagged + 64 with unflagged > 0 and flagged[64:] byte-equal)"; FAIL=$((FAIL + 1))
fi
rm -f "$ihdr_a" "$ihdr_b"

# THE OTHER HALF OF THIS SECTION IS BELOW, not missing: the rows that read the
# 64 emitted bytes field by field live in `--image-header: the 64 emitted bytes
# (C, Task 2)`, after the `--emit=image` behaviour section, because one of them
# needs that section's `img_a64_adrp_targets` decoder. That section's own
# header says the same thing from the other end. (Stated in both places on
# purpose: I1 in this sub-project was a comment pointing at a section that did
# not exist, so a forward reference here is only safe if the target names
# itself as the target.)

# --- --reset-vector flag surface (sub-project E, Task 1) ---
# `krc` alone, given --reset-vector on --emit=image, produces a 65536-byte
# x86_64 artifact bootable by `qemu-system-x86_64 -bios` and nothing else --
# no GNU as, no ld, no --defsym, no concatenation script. THIS SECTION IS THE
# FLAG SURFACE ONLY: the stage bytes it guards are asserted two sections
# below, in `--reset-vector: the emitted stage`, and booted by leg L9.
#
# 14 ROWS. Ten are `img_refuses` (three clauses each: nonzero exit, the
# diagnostic text, no artifact left on disk), three are `stk_accepts` twins
# pinning the accepting side of a band edge, and one -- payload too large --
# is hand-written and different in kind, explained at its own row below.
#
# THE COUNT AND THE TENSE WERE BOTH WRONG UNTIL THE FINAL REVIEW. This block
# said "six of the seven rows" (correct when written, falsified by review r1
# adding four band-edge rows and two 4 GiB rows) and "will (Task 2) produce"
# and "it emits no stage bytes" -- stale forward references still standing
# three commits after Task 2 landed and booted. A count and a tense are
# exactly the two things a comment cannot be pinned on, so they are the two
# things to re-derive when touching this file: `grep -cE '^(img_refuses|
# stk_accepts) '` over the section is where the 13 comes from (row 1b below,
# --reset-vector=<value>, added the fourteenth without touching the other
# thirteen's numbering).
echo ""
echo "--- --reset-vector flag surface (E, Task 1) ---"

# 1. arm64: refused. arm64 resets directly into AArch64 state, not through
#    the real/protected/long-mode transition this form builds; riscv32 and
#    xtensa already have their own raw paths via --freestanding.
img_refuses reset_vector_requires_x86_64 "requires --arch=x86_64" \
    --target=none --arch=arm64 --emit=image --reset-vector --stack-top=0x90000

# 1b. --reset-vector=<anything>: refused with a diagnostic, not silently
#     swallowed. --reset-vector is matched with str_eq_full, which matches
#     the bare spelling only, so `--reset-vector=1` used to fall through to
#     the final `else { input_path = arg }` and be silently ignored --
#     measured: exit 0 and a 256-byte MULTIBOOT artifact (the plain
#     --emit=image + --stack-top= form), not the 65536-byte reset-vector
#     image the flag asked for. That measurement needs --load-addr= present
#     (a "plain --emit=image" build requires it -- see image_needs_load_addr
#     above), so it is added here; the row's flags also have to land BEFORE
#     the input path (img_refuses_flags_first, not img_refuses) or the
#     unrecognized spelling reassigns input_path instead and the row fails
#     for the unrelated, pre-existing "--emit=image requires --load-addr"
#     rather than this claim.
img_refuses_flags_first reset_vector_rejects_value "reset-vector takes no value" \
    --target=none --arch=x86_64 --emit=image --reset-vector=1 --stack-top=0x90000 --load-addr=0x100000

# 2. --target=linux: refused by the EXISTING --emit=image rule, unchanged --
#    --reset-vector adds no target requirement of its own beyond what
#    --emit=image already enforces, so this row pins that the shared refusal
#    still fires with the new flag present (not merely tested in its
#    absence).
img_refuses reset_vector_requires_target_none "requires --target=none" \
    --target=linux --arch=x86_64 --emit=image --reset-vector --stack-top=0x90000

# 3. --emit=elf: refused. Mirrors --load-addr=/--stack-top=/--image-header's
#    own "only meaningful with --emit=image" rows just below them in
#    src/main.kr -- this flag selects a FORM of the flat image, so it needs
#    one to select. Pattern is the flag's OWN wording, not the shared
#    substring those three rows' messages also carry, so this row proves
#    --reset-vector's gate fired and not one of theirs (this line also sets
#    --stack-top=, which on its own would trip stacktop_requires_image's
#    identical-looking rule if --reset-vector's check were not ordered and
#    worded to win first).
img_refuses reset_vector_requires_emit_image "reset-vector is only meaningful" \
    --target=none --arch=x86_64 --emit=elf --reset-vector --stack-top=0x90000

# 4. --stack-top= absent: refused. No default stack, ever -- D4's rule,
#    restated verbatim in src/main.kr's own stack_top declaration -- and this
#    form sets rsp from the flag's value with nothing to fall back to.
img_refuses reset_vector_requires_stack_top "requires --stack-top=" \
    --target=none --arch=x86_64 --emit=image --reset-vector

# 5. --load-addr= given: refused. Measured meaningless (design spec S8 Q2):
#    a plain --emit=image x86_64 payload is byte-identical at
#    --load-addr=0x100000 and --load-addr=0x20000000, because this form's
#    payload always lands at the fixed physical address 0x100000 -- there is
#    no address left for the flag to choose.
img_refuses reset_vector_conflicts_load_addr "conflicts with --load-addr=" \
    --target=none --arch=x86_64 --emit=image --reset-vector --stack-top=0x90000 --load-addr=0x100000

# 6. --stack-top= landing inside the page tables: refused. The reset-vector
#    stage builds its OWN identity page tables at 0x1000-0x7000 (PDPT[0..3],
#    four page directories, the full 4 GiB -- wider than the self-boot
#    trampoline's single-PD 0x1000-0x4000 B2 already refuses on), and the
#    stack grows down, so the first push must clear that band. 0x2000 is the
#    band's INTERIOR, deliberately, not an edge -- mirroring
#    stacktop_x86_range_collision's own caution a few sections up: an edge
#    alone would read green under an off-by-eight rule too, which is exactly
#    the defect class B2's edge rows (6c-6e there) exist to catch.
img_refuses reset_vector_stack_top_in_page_tables "0x1000-0x7000" \
    --target=none --arch=x86_64 --emit=image --reset-vector --stack-top=0x2000

# 6b-6e. BOTH EDGES OF THAT BAND (review r1 Minor 3). Row 6 alone is the
#    interior-only probe B2's own review found insufficient (6c-6e there
#    exist for exactly this reason: an off-by-eight reads green against an
#    interior value and only an edge row catches it). [stack_top-8,
#    stack_top) overlaps [0x1000, 0x7000) exactly when stack_top > 0x1000 and
#    stack_top < 0x7008, so 0x1000 and 0x7008 are the nearest ACCEPTED values
#    on either side and 0x1001 / 0x7007 the nearest REFUSED ones.
stk_accepts reset_vector_page_table_low_edge_accepted \
    --target=none --arch=x86_64 --emit=image --reset-vector --stack-top=0x1000
img_refuses reset_vector_page_table_low_edge_refused "0x1000-0x7000" \
    --target=none --arch=x86_64 --emit=image --reset-vector --stack-top=0x1001
img_refuses reset_vector_page_table_high_edge_refused "0x1000-0x7000" \
    --target=none --arch=x86_64 --emit=image --reset-vector --stack-top=0x7007
stk_accepts reset_vector_page_table_high_edge_accepted \
    --target=none --arch=x86_64 --emit=image --reset-vector --stack-top=0x7008

# 8. --stack-top= at or above the reset-vector stage's own 4 GiB identity
#    map ceiling: refused (review r1 Important 1). Excluding B2's whole x86
#    range arm under --reset-vector (Task 1 Step 5's guard on it, a few
#    sections up: `arch == 0 && reset_vector_set == 0`) also excluded that
#    arm's "stack must fit inside the identity map" bound -- and unlike the
#    page-table band and the --load-addr pair, that bound is NOT
#    B2-specific: it re-derives here to a DIFFERENT map size (the
#    reset-vector stage's PDPT[0..3] covers the full 4 GiB, not B2's single
#    GiB), not to nothing. Left unchecked, --stack-top= had NO ceiling at
#    all under --reset-vector -- 0x100000000 and even
#    0xFFFFFFFFFFFFFFF0 both exited 0 before this fix. `>=`, not B2's `>`:
#    the reset-vector stage this bound is about has not been built yet
#    (Task 1 emits no stage bytes), so the refusal is conservative at the
#    exact boundary rather than asserting an inclusive edge nobody has
#    measured for it.
img_refuses reset_vector_above_4gib_map_refused "below 0x100000000" \
    --target=none --arch=x86_64 --emit=image --reset-vector --stack-top=0x100000000
stk_accepts reset_vector_at_4gib_map_edge_accepted \
    --target=none --arch=x86_64 --emit=image --reset-vector --stack-top=0xFFFFFFFF

# 9. Payload too large for the fixed 65536-byte image: THE REFUSAL THAT
#    MATTERS MOST, and the one Task 1 does NOT implement. Its absence is not
#    "a wrong command line accepted" the way rows 1-8 are -- it is a
#    SILENTLY TRUNCATED BOOTABLE IMAGE, the only failure mode in this list
#    that produces a working-looking artifact that is WRONG rather than an
#    artifact that is simply absent. The check belongs at finalize, because
#    PAYLEN -- the copied payload's length -- does not exist until codegen
#    has produced it; every refusal above runs entirely at flag-parse time,
#    before compilation, and has no PAYLEN to check against.
#
# THIS ROW IS DELIBERATELY LEFT RED. Task 1 owns writing it, running it for
# real, and reporting what it actually does -- not skipping it, not loosening
# its assertion until it passes, not marking it a false PASS/SKIP. It is a
# genuine FAIL in this suite's count until sub-project E's Task 2 implements
# the finalize-time fit check; that task is what turns this row green.
#
# TASK 2 LANDED AND THIS ROW IS NOW GREEN, with its assertion UNCHANGED --
# that was the point of writing it before the check existed. The refusal it
# now catches names both sizes, and the bound it fires against
# (65536 - payoff - 16) is pinned from BOTH SIDES by
# resetvec_fit_edge_accepted / resetvec_fit_edge_refused in the section
# below; this row's 100000-byte array proves the check exists, those two
# prove where it is.
#
# big.kr is GENERATED here, not committed: a 100000-byte static array is
# enough to exceed any plausible "65536 - PAYOFF - 16" bound (PAYOFF is the
# ~294-byte reset-vector stage's own size, not yet implemented and therefore
# not knowable to this row) by a wide margin, regardless of what PAYOFF turns
# out to be once Task 2 lands.
RV_BIG_SRC="$DIR/../test_tmp_rvbig_$$.kr"
printf 'static uint8[100000] rv_big_pad\nfn main() -> uint64 { unsafe { *((rv_big_pad + 99999) as uint8) = 7 }\n return 0 }\n' > "$RV_BIG_SRC"
TOTAL=$((TOTAL + 1))
rm -f /tmp/krc_rvbig_$$
rvbig_out=$($KRC $KRC_FLAGS "$RV_BIG_SRC" -o /tmp/krc_rvbig_$$ --target=none --arch=x86_64 --emit=image --reset-vector --stack-top=0x90000 2>&1); rvbig_st=$?
if [ $rvbig_st -ne 0 ] && echo "$rvbig_out" | grep -qi 'too large\|does not fit\|65536' && [ ! -f /tmp/krc_rvbig_$$ ]; then
    PASS=$((PASS + 1)); echo "  reset_vector_payload_too_large: PASS (Task 2's finalize check already landed)"
else
    # E TASK 4: this text used to say "EXPECTED RED at Task 1 ... Task 2 must
    # turn this row green". Task 2 turned it green, so the same words would now
    # tell a reader that a live regression is expected. A red here is a red.
    echo "FAIL: reset_vector_payload_too_large (a 100000-byte payload was NOT refused by the finalize-time fit check Task 2 landed; exit=$rvbig_st, artifact=$([ -f /tmp/krc_rvbig_$$ ] && echo yes || echo no). This is a regression, not a known gap.)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_rvbig_$$ "$RV_BIG_SRC"

rm -f "$STK_SRC" "$IMG_SRC"

# --- --reset-vector: the emitted stage (sub-project E, Task 2) --------------
#
# WHAT CHANGED UNDER THIS SECTION'S FEET. Everything above is flag-parse
# behaviour and holds with no stage bytes at all; Task 2 emits the stage, so
# `--reset-vector` now produces a 65536-byte artifact that boots under
# `qemu-system-x86_64 -bios` and nothing else. The row directly above
# (reset_vector_payload_too_large) went green as a side effect and is
# unchanged -- its assertion was written for this moment.
#
# EVERY ROW HERE IS STATIC, AND STATIC IS NOT ENOUGH ON ITS OWN. A stage can
# satisfy all of them and still triple-fault: the boot itself is boot-gate leg
# L9's (Task 3). What these rows are FOR is the class of defect a boot cannot
# localise -- a far jump to a stale offset, a GDT whose 0x08 is the wrong
# width, a `rep movsl` count that is short by three bytes -- each of which
# shows up on the wire as an indistinguishable silent reboot.
#
# NOTHING HERE IS ASSERTED AGAINST A WRITTEN-DOWN OFFSET. The checker below
# starts at byte 0 and WALKS: `cli;cld`, then the `lgdtl` disp to the GDTR, the
# GDTR's base to the GDT, the 16-bit far jump to start32, the 32-bit far jump
# to lm64, the `movabs` to the stack top, the `mov $imm32,%rax` to the entry.
# Every hop is read out of the artifact, so a patch site that was captured and
# then never written reads back as its own placeholder and fails at the hop
# that consumes it, naming that hop. A table of expected offsets would instead
# go stale silently the first time an instruction changed length -- which has
# already happened once in this file's history, to B2's stub, WITHOUT changing
# the total size (the .align-16 pad absorbed it).
echo ""
echo "--- --reset-vector: the emitted stage (E, Task 2) ---"

# A program with a static, a called helper and a non-trivial main, so the
# payload is more than a `ret` and `kentoff` is not trivially 0. Deliberately
# NOT the boot gate's sentinel_x86.kr: that one imports ../std/uart_16550.kr,
# whose resolution depends on where the source is placed, and these rows are
# about bytes rather than about output.
RVS_SRC="$DIR/../test_tmp_rvs_$$.kr"
printf 'static uint64 rvs_acc = 0\nfn rvs_fib(uint64 n) -> uint64 { if n < 2 { return n }\n return rvs_fib(n - 1) + rvs_fib(n - 2) }\nfn main() -> uint64 { rvs_acc = rvs_fib(7)\n return rvs_acc }\n' > "$RVS_SRC"
RVS_A=/tmp/krc_rvs_a_$$        # --reset-vector, --stack-top=0x90000
RVS_B=/tmp/krc_rvs_b_$$        # --reset-vector, --stack-top=0x80000
RVS_P=/tmp/krc_rvs_p_$$        # the SAME program with NO --reset-vector

rvs_build() {   # $1 src, $2 out, $3 stack-top -- stdout = the two report lines
    rm -f "$2"
    $KRC $KRC_FLAGS "$1" -o "$2" --target=none --arch=x86_64 --emit=image \
        --reset-vector --stack-top="$3" 2>&1
}
rvs_field() {   # $1 report text, $2 field name -> its value
    echo "$1" | grep -oE "$2=[0-9]+" | head -1 | cut -d= -f2
}

rvs_a=$(rvs_build "$RVS_SRC" "$RVS_A" 0x90000); rvs_a_st=$?
rvs_b=$(rvs_build "$RVS_SRC" "$RVS_B" 0x80000); rvs_b_st=$?
rm -f "$RVS_P"
rvs_p=$($KRC $KRC_FLAGS "$RVS_SRC" -o "$RVS_P" --target=none --arch=x86_64 \
        --emit=image --load-addr=0x100000 2>&1); rvs_p_st=$?

rvs_payoff=$(rvs_field "$rvs_a" payoff)
rvs_paylen=$(rvs_field "$rvs_a" paylen)
rvs_kentoff=$(rvs_field "$rvs_a" kentoff)

# The walker. Prints one facts line on success; on failure prints every
# complaint it found (not just the first -- a wrong GDT and a wrong far jump
# are two separate defects and finding them one boot at a time is what this
# sub-project is trying to stop doing).
rvs_check() {   # $1 image, $2 stack-top, $3 payoff, $4 paylen, $5 kentoff
    python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import sys, struct
d       = open(sys.argv[1], "rb").read()
sp      = int(sys.argv[2], 0)
payoff  = int(sys.argv[3]); paylen = int(sys.argv[4]); kentoff = int(sys.argv[5])
BIOS    = 0xFFFF0000
bad     = []
def u16(o): return struct.unpack_from("<H", d, o)[0]
def u32(o): return struct.unpack_from("<I", d, o)[0]
def u64(o): return struct.unpack_from("<Q", d, o)[0]
def find1(pat, what, lo, hi):
    hits, i = [], lo
    while True:
        j = d.find(pat, i, hi)
        if j < 0: break
        hits.append(j); i = j + 1
    if len(hits) != 1:
        bad.append("%s: %d matches for %s in [%d,%d), want exactly 1"
                   % (what, len(hits), pat.hex(), lo, hi))
        return None
    return hits[0]

# --- the fixed geometry ---------------------------------------------------
if len(d) != 65536:
    bad.append("file is %d bytes, not 65536 -- `-bios` was MEASURED to refuse "
               "32768 and 66000" % len(d))
    print("; ".join(bad)); sys.exit(1)
if d[0:2] != bytes.fromhex("fafc"):
    bad.append("the stage does not begin cli;cld (fa fc) but %s -- file offset "
               "0 is where the reset jmp lands" % d[0:2].hex())
if d[0xFFF0:0xFFF3] != bytes.fromhex("e90d00"):
    bad.append("bytes at 0xFFF0 are %s, not the 3-byte near `jmp` e9 0d 00. "
               "The CPU resets to CS=f000:IP=fff0, so this is the first "
               "instruction executed" % d[0xFFF0:0xFFF3].hex())
if d[0xFFF3:0x10000] != b"\x00" * 13:
    bad.append("the 13 bytes after the reset jmp are not zero")
if any(u32(i) == 0x1BADB002 for i in range(0, payoff - 3, 4)):
    bad.append("a multiboot magic appears inside the stage -- B2's "
               "--stack-top stub fired on the reset-vector path, and two "
               "file-offset-0 constructs cannot share a file")

# --- 16-bit real: cli/cld -> lgdt -> CR0.PE -> ljmp $0x08 -----------------
lgdt = find1(bytes.fromhex("2e660f0116"), "lgdtl %cs:disp16", 0, payoff)
gdt_off = None
if lgdt is not None:
    gdtr_off = u16(lgdt + 5)
    # A BARE FILE OFFSET, not a linear address: the disp is read through CS,
    # whose base is already 0xFFFF0000.
    if gdtr_off + 6 > payoff:
        bad.append("the lgdtl disp16 is %d, which is not inside the stage "
                   "[0,%d)" % (gdtr_off, payoff))
    else:
        lim = u16(gdtr_off)
        gdt_off = u32(gdtr_off + 2) - BIOS
        if lim != 31:
            bad.append("gdtr limit %d != 31 (4 quads - 1)" % lim)
        if gdt_off < 0 or gdt_off + 32 != gdtr_off:
            bad.append("gdtr base %08x -> file offset %d; +32 != gdtr at %d"
                       % (u32(gdtr_off + 2), gdt_off, gdtr_off))
        else:
            want = [0, 0x00CF9A000000FFFF, 0x00CF92000000FFFF, 0x00AF9A000000FFFF]
            for i, w in enumerate(want):
                if u64(gdt_off + i * 8) != w:
                    bad.append("gdt[%d] = %016x != %016x"
                               % (i, u64(gdt_off + i * 8), w))
            # The width bits, decoded rather than pattern-matched: byte 6 of a
            # descriptor carries L (0x20) and D/B (0x40). THIS is the check
            # that separates this stage from emit_x86_image_stub's, whose 0x08
            # is 64-bit code -- a 16-bit stage ljmp'ing $0x08 into THAT lands
            # in long mode with paging off.
            f08, f18 = d[gdt_off + 8 + 6], d[gdt_off + 24 + 6]
            if (f08 & 0x20) != 0 or (f08 & 0x40) == 0:
                bad.append("GDT 0x08 flags %02x: L=%d D/B=%d -- it must be "
                           "32-BIT code (L=0, D/B=1)"
                           % (f08, (f08 >> 5) & 1, (f08 >> 6) & 1))
            if (f18 & 0x20) == 0 or (f18 & 0x40) != 0:
                bad.append("GDT 0x18 flags %02x: L=%d D/B=%d -- it must be "
                           "64-BIT code (L=1, D/B=0)"
                           % (f18, (f18 >> 5) & 1, (f18 >> 6) & 1))

start32 = None
lj16 = find1(bytes.fromhex("66ea"), "16-bit ljmpl", 0, payoff)
if lj16 is not None:
    if u16(lj16 + 6) != 0x0008:
        bad.append("16-bit ljmpl selector %04x != 0x08 (the 32-bit code CS)"
                   % u16(lj16 + 6))
    start32 = u32(lj16 + 2) - BIOS
    if start32 < 0 or start32 + 9 > payoff:
        bad.append("16-bit ljmpl targets %08x, outside the stage"
                   % u32(lj16 + 2))
        start32 = None
    elif d[start32:start32 + 4] != bytes.fromhex("66b81000"):
        bad.append("16-bit ljmpl lands on %s, not `mov $0x10,%%ax` (66b81000)"
                   % d[start32:start32 + 4].hex())

# --- 32-bit protected: the copy, the 4 GiB map, ljmp $0x18 ---------------
lm64 = None
if start32 is not None:
    m = find1(bytes.fromhex("f3a5"), "rep movsl", start32, payoff)
    if m is not None:
        if d[m - 15] != 0xBE or d[m - 10] != 0xBF or d[m - 5] != 0xB9:
            bad.append("the 15 bytes before `rep movsl` are not "
                       "mov $imm32,%%esi / %%edi / %%ecx: %s"
                       % d[m - 15:m].hex())
        else:
            if u32(m - 14) != BIOS + payoff:
                bad.append("the copy source is %08x, i.e. file offset %d, not "
                           "the reported payoff %d"
                           % (u32(m - 14), u32(m - 14) - BIOS, payoff))
            if u32(m - 9) != 0x100000:
                bad.append("the copy destination is %08x, not 0x100000"
                           % u32(m - 9))
            want_dw = (paylen + 3) // 4
            if u32(m - 4) != want_dw:
                bad.append("`rep movsl` count is %d dwords, not ceil(%d/4)=%d "
                           "-- a truncating divide leaves the payload's last "
                           "1-3 bytes uncopied"
                           % (u32(m - 4), paylen, want_dw))
    z = find1(bytes.fromhex("f3ab"), "rep stosl", start32, payoff)
    if z is not None:
        if d[z - 5] != 0xB9 or u32(z - 4) != 0x1800:
            bad.append("the page-table zeroing count is not 0x1800 dwords "
                       "(0x1000..0x7000, six pages)")
    for addr, val in ((0x1000, 0x2003), (0x2000, 0x3003), (0x2008, 0x4003),
                      (0x2010, 0x5003), (0x2018, 0x6003)):
        find1(b"\xc7\x05" + struct.pack("<II", addr, val),
              "movl $%04x,%04x" % (val, addr), start32, payoff)
    pd = find1(bytes.fromhex("b883000000") + b"\xb9", "mov $0x83,%eax; mov "
               "$imm32,%ecx", start32, payoff)
    if pd is not None:
        n = u32(pd + 6)
        if n != 2048:
            # THE SYMPTOM IS REPETITION, NOT CESSATION, and Task 3's control
            # derives its expectation from this line. Measured by cutting an
            # emitted artifact's loop count to 512 and booting it:
            # `RPRPRPRP...` forever, because the triple fault resets the CPU
            # back into the stage. A control that greps for a serial capture
            # ENDING in `RP` would pass on the correct compiler too; the
            # discriminator is that `L` never appears.
            bad.append("the page directory loop runs %d times = %d MiB "
                       "identity-mapped, not 2048 = 4 GiB. This stage RUNS at "
                       "0xFFFF0000; a short map triple-faults on the far jump, "
                       "resets, and re-runs -- measured `RPRPRP...` repeating "
                       "with `L` never printed" % (n, n * 2))
    lj32 = find1(bytes.fromhex("0f22c0ea"), "mov %eax,%cr0; ljmp",
                 start32, payoff)
    if lj32 is not None:
        if u16(lj32 + 8) != 0x0018:
            bad.append("32-bit ljmp selector %04x != 0x18 (the 64-bit code CS)"
                       % u16(lj32 + 8))
        lm64 = u32(lj32 + 4) - BIOS
        if lm64 < 0 or lm64 + 32 > payoff:
            bad.append("32-bit ljmp targets %08x, outside the stage"
                       % u32(lj32 + 4))
            lm64 = None

# --- 64-bit long mode: rsp, the entry, the landing pad -------------------
if lm64 is not None:
    if d[lm64:lm64 + 10] != bytes.fromhex("66b810008ed88ec08ed0"):
        bad.append("lm64 does not begin with the data-segment reloads: %s"
                   % d[lm64:lm64 + 10].hex())
    mv = lm64 + 10
    if d[mv:mv + 2] != bytes.fromhex("48bc"):
        bad.append("no `movabs $imm64,%%rsp` (48 bc) at lm64+10, found %s. The "
                   "7-byte `mov $imm32,%%rsp` SIGN-EXTENDS and --reset-vector "
                   "accepts --stack-top up to 0xFFFFFFFF"
                   % d[mv:mv + 2].hex())
    elif u64(mv + 2) != sp:
        bad.append("movabs carries %016x, not --stack-top %08x -- the flag was "
                   "validated and reported and then IGNORED" % (u64(mv + 2), sp))
    ent = mv + 10 + 7
    if d[mv + 10:ent] != bytes.fromhex("66baf803b04cee"):
        bad.append("the 'L' sentinel (mov $0x3F8,%%dx; mov $'L',%%al; out) is "
                   "missing after the rsp load: %s. Without R/P/L a triple "
                   "fault is an indistinguishable silent reboot"
                   % d[mv + 10:ent].hex())
    if d[ent:ent + 3] != bytes.fromhex("48c7c0"):
        bad.append("no `mov $imm32,%%rax` at the entry site, found %s"
                   % d[ent:ent + 3].hex())
    else:
        want = 0x100000 + kentoff
        if u32(ent + 3) == 0:
            bad.append("the entry immediate is 0 -- the UNPATCHED placeholder. "
                       "`call *%rax` to 0 is a triple fault, not a diagnostic")
        elif u32(ent + 3) != want:
            bad.append("the entry immediate is %08x, not 0x100000 + kentoff "
                       "%d = %08x" % (u32(ent + 3), kentoff, want))
    if d[ent + 7:ent + 12] != bytes.fromhex("ffd0f4ebfd"):
        bad.append("bytes after the entry load are %s, not `call *%%rax; hlt; "
                   "jmp .` (ffd0f4ebfd) -- a returning payload would run into "
                   "the GDT" % d[ent + 7:ent + 12].hex())

# --- the payload's own bounds --------------------------------------------
if payoff + paylen > 0xFFF0:
    bad.append("payoff %d + paylen %d = %d runs into the reset vector at "
               "0xFFF0" % (payoff, paylen, payoff + paylen))
elif d[payoff + paylen:0xFFF0] != b"\x00" * (0xFFF0 - payoff - paylen):
    bad.append("the fill between the payload and the reset vector is not zero")
if gdt_off is not None and not (gdt_off + 38 <= payoff < gdt_off + 38 + 16):
    bad.append("payoff %d is not the 16-byte-aligned end of the stage "
               "(gdtr ends at %d)" % (payoff, gdt_off + 38))

if bad:
    print("; ".join(bad)); sys.exit(1)
print("stage=%d payload=%d..%d entry=0x%x fill=%d"
      % (payoff, payoff, payoff + paylen, 0x100000 + kentoff,
         0xFFF0 - payoff - paylen))
PY
}

# 1. The report line, and the artifact agreeing with it. `entry=0` is the
#    DECISION Task 2 makes (design spec S7 left it open): under --reset-vector
#    the reported entry is the stage's own first byte, because the reset jmp
#    transfers to CS:0 and nothing else in the artifact is entered from
#    outside. The `image:` line's SHAPE is unchanged -- the three numbers a
#    consumer needs get their own `reset-vector:` line rather than being
#    squeezed into a field that means a file offset everywhere else.
TOTAL=$((TOTAL + 1))
rvs_why=""
rvs_disk=$(stat -c%s "$RVS_A" 2>/dev/null)
if [ $rvs_a_st -ne 0 ]; then
    rvs_why="the build failed (exit=$rvs_a_st): $(echo "$rvs_a" | head -1)"
elif ! echo "$rvs_a" | grep -q 'image: arch=x86_64 entry=0 filesz=65536 memsz=65536 load=0'; then
    rvs_why="image line is '$(echo "$rvs_a" | grep '^image:')', want 'image: arch=x86_64 entry=0 filesz=65536 memsz=65536 load=0'"
elif ! echo "$rvs_a" | grep -qE '^reset-vector: payoff=[0-9]+ paylen=[0-9]+ kentoff=[0-9]+ stack=589824$'; then
    rvs_why="no well-formed 'reset-vector:' line: '$(echo "$rvs_a" | grep '^reset-vector:')'"
elif [ "$rvs_disk" != "65536" ]; then
    rvs_why="the report claims filesz=65536 and the file on disk is ${rvs_disk:-absent} bytes"
fi
if [ -z "$rvs_why" ]; then
    PASS=$((PASS + 1)); echo "  resetvec_report_line: PASS (entry=0, 65536 B on disk, payoff=$rvs_payoff paylen=$rvs_paylen kentoff=$rvs_kentoff)"
else
    echo "FAIL: resetvec_report_line ($rvs_why)"; FAIL=$((FAIL + 1))
fi

# 2. The stage decodes, hop by hop, from byte 0. See the section header for
#    why nothing here is compared against a written-down offset.
TOTAL=$((TOTAL + 1))
if [ $rvs_a_st -ne 0 ] || [ -z "$rvs_payoff" ]; then
    echo "FAIL: resetvec_stage_decodes (no artifact to decode: exit=$rvs_a_st)"
    FAIL=$((FAIL + 1))
else
    rvs_facts=$(rvs_check "$RVS_A" 0x90000 "$rvs_payoff" "$rvs_paylen" "$rvs_kentoff"); rvs_rc=$?
    if [ $rvs_rc -eq 0 ]; then
        PASS=$((PASS + 1)); echo "  resetvec_stage_decodes: PASS ($rvs_facts)"
    else
        echo "FAIL: resetvec_stage_decodes (${rvs_facts:-the checker produced no output and exited $rvs_rc})"
        FAIL=$((FAIL + 1))
    fi
fi

# 3. THE PAYLOAD IS THE ORDINARY --emit=image ARTIFACT, UNSHIFTED AND
#    UNMODIFIED, and payoff/paylen/kentoff say exactly where it is. This is
#    the row that gives the three fields an INDEPENDENT source: the same
#    program built without --reset-vector is the payload, byte for byte, its
#    size is paylen and its reported entry is kentoff. Nothing in this row
#    reads a number out of the reset-vector build to check the reset-vector
#    build against itself.
TOTAL=$((TOTAL + 1))
rvs_pe=$(rvs_field "$rvs_p" entry)
rvs_pz=$(stat -c%s "$RVS_P" 2>/dev/null)
rvs_why=""
if [ $rvs_p_st -ne 0 ]; then
    rvs_why="the plain --emit=image build failed (exit=$rvs_p_st)"
elif [ "$rvs_paylen" != "$rvs_pz" ]; then
    rvs_why="paylen=$rvs_paylen but the same program without --reset-vector is $rvs_pz bytes"
elif [ "$rvs_kentoff" != "$rvs_pe" ]; then
    rvs_why="kentoff=$rvs_kentoff but the same program without --reset-vector reports entry=$rvs_pe"
elif ! python3 -c "
import sys
a=open(sys.argv[1],'rb').read(); b=open(sys.argv[2],'rb').read(); o=int(sys.argv[3])
sys.exit(0 if a[o:o+len(b)]==b else 1)" "$RVS_A" "$RVS_P" "$rvs_payoff"; then
    rvs_why="the $rvs_pz bytes at offset $rvs_payoff are not the plain --emit=image artifact"
fi
if [ -z "$rvs_why" ]; then
    PASS=$((PASS + 1)); echo "  resetvec_payload_is_the_plain_image: PASS ($rvs_pz B at offset $rvs_payoff, entry $rvs_pe == kentoff)"
else
    echo "FAIL: resetvec_payload_is_the_plain_image ($rvs_why)"; FAIL=$((FAIL + 1))
fi

# 4. --stack-top REACHES THE GUEST, and reaches it at BOTH sites. B2's own
#    review (C4) found a stub that validated and reported the flag and then
#    emitted the reference .S's hardcoded 0x90000, and a single-value row
#    cannot see that -- 0x90000 IS the reference's constant. So: two values,
#    each image decoded against its OWN value by the walker above (which
#    reads the `movabs` and compares), plus a differential that pins the
#    SECOND site, the 32-bit `mov $imm32,%esp` the walker does not check.
#
#    THE EXPECTED DIFF COUNT IS DERIVED, NOT WRITTEN DOWN. Two stack tops
#    that differ in one byte produce a two-byte diff, not a twelve-byte one
#    -- 0x00090000 and 0x00080000 differ only in their third byte. So the
#    expectation is 2 x (bytes that differ in the low four), which is what
#    "the value reaches exactly two immediates" means for ANY pair. Writing
#    12 here would have been an assertion about the encoding's width rather
#    than about the value, and it read RED against a correct compiler.
TOTAL=$((TOTAL + 1))
rvs_why=""
if [ $rvs_b_st -ne 0 ]; then
    rvs_why="the 0x80000 build failed (exit=$rvs_b_st)"
else
    rvs_facts=$(rvs_check "$RVS_B" 0x80000 "$(rvs_field "$rvs_b" payoff)" \
                "$(rvs_field "$rvs_b" paylen)" "$(rvs_field "$rvs_b" kentoff)"); rvs_rc=$?
    if [ $rvs_rc -ne 0 ]; then
        rvs_why="the 0x80000 image does not decode: $rvs_facts"
    else
        rvs_diff=$(python3 -c "
import sys
a = open(sys.argv[1], 'rb').read(); b = open(sys.argv[2], 'rb').read()
payoff = int(sys.argv[3])
sa, sb = int(sys.argv[4], 0), int(sys.argv[5], 0)
if len(a) != len(b):
    print('sizes differ: %d vs %d' % (len(a), len(b))); raise SystemExit
off = [i for i in range(len(a)) if a[i] != b[i]]
want = 2 * sum(1 for k in range(4) if ((sa >> (8 * k)) & 0xFF) != ((sb >> (8 * k)) & 0xFF))
if len(off) != want:
    print('%d bytes differ, want %d = 2 x the differing bytes of the two '
          'stack tops -- one site is a constant, or something else tracks '
          'the flag' % (len(off), want))
elif off and max(off) >= payoff:
    print('a differing byte at offset %d lies in the PAYLOAD (payoff=%d): '
          '--stack-top must change the stage only' % (max(off), payoff))
else:
    print('ok %d' % len(off))" "$RVS_A" "$RVS_B" "$rvs_payoff" 0x90000 0x80000)
        case "$rvs_diff" in
            "ok "*) ;;
            *) rvs_why="$rvs_diff" ;;
        esac
    fi
fi
if [ -z "$rvs_why" ]; then
    PASS=$((PASS + 1)); echo "  resetvec_stack_top_reaches_the_guest: PASS (0x90000 vs 0x80000: $rvs_diff differing bytes, all inside the stage)"
else
    echo "FAIL: resetvec_stack_top_reaches_the_guest ($rvs_why)"; FAIL=$((FAIL + 1))
fi

# 5. THE FIT REFUSAL'S EDGE, both sides. The row above
#    (reset_vector_payload_too_large) uses a 100000-byte array -- an order of
#    magnitude past the bound, which proves the check exists and says nothing
#    about where it is. The bound is 65536 - payoff - 16, and it is the LAST
#    accepted payload that a truncating image would silently produce, so both
#    sides of it are pinned. The array sizes are DERIVED from the reported
#    payoff, not written down: payoff is an emission detail and hardcoding it
#    here would turn a stage-length change into a mysterious red.
rvs_avail=$(( 65536 - rvs_payoff - 16 ))
RVS_FIT="$DIR/../test_tmp_rvfit_$$.kr"
rvs_fit_try() {   # $1 array size -> exit status; leaves the artifact or not
    printf 'static uint8[%d] rvf_p\nfn main() -> uint64 { unsafe { *((rvf_p + %d) as uint8) = 7 }\n return 0 }\n' "$1" $(( $1 - 1 )) > "$RVS_FIT"
    rm -f /tmp/krc_rvfit_$$
    $KRC $KRC_FLAGS "$RVS_FIT" -o /tmp/krc_rvfit_$$ --target=none --arch=x86_64 \
        --emit=image --reset-vector --stack-top=0x90000 2>&1
}
# THE EDGE IS FOUND, NOT ASSUMED. The array size that produces the largest
# fitting payload is not `rvs_avail`: the program carries code of its own and
# a static is aligned, so the array-size-to-payload-size map has a step. Walk
# DOWN from the bound to the first accepted size -- that is the accept/refuse
# boundary by construction, whatever the step turns out to be -- and pin both
# sides of it. Asserting "paylen == rvs_avail exactly" would have been an
# assumption about that alignment, which is precisely the class of claim this
# sub-project keeps getting wrong.
rvs_max=""
rvs_n=$rvs_avail
while [ $rvs_n -ge $(( rvs_avail - 128 )) ]; do
    if rvs_fit_try $rvs_n >/dev/null 2>&1; then rvs_max=$rvs_n; break; fi
    rvs_n=$(( rvs_n - 1 ))
done
TOTAL=$((TOTAL + 1))
rvs_maxlen=""
if [ -z "$rvs_max" ]; then
    echo "FAIL: resetvec_fit_edge_accepted (no array size within 128 bytes of the $rvs_avail-byte bound was accepted)"
    FAIL=$((FAIL + 1))
else
    rvs_out=$(rvs_fit_try $rvs_max)
    rvs_maxlen=$(rvs_field "$rvs_out" paylen)
    if [ -n "$rvs_maxlen" ] && [ "$rvs_maxlen" -le "$rvs_avail" ] \
       && [ "$rvs_maxlen" -gt $(( rvs_avail - 16 )) ] \
       && [ "$(stat -c%s /tmp/krc_rvfit_$$ 2>/dev/null)" = "65536" ]; then
        PASS=$((PASS + 1)); echo "  resetvec_fit_edge_accepted: PASS (paylen=$rvs_maxlen fits under 65536 - $rvs_payoff - 16 = $rvs_avail, still a 65536-byte image)"
    else
        echo "FAIL: resetvec_fit_edge_accepted (largest accepted array $rvs_max gives paylen=${rvs_maxlen:-?}, want <= $rvs_avail and within 16 of it)"
        FAIL=$((FAIL + 1))
    fi
fi
TOTAL=$((TOTAL + 1))
rvs_out=$(rvs_fit_try $(( ${rvs_max:-$rvs_avail} + 1 ))); rvs_st=$?
if [ $rvs_st -ne 0 ] && [ ! -f /tmp/krc_rvfit_$$ ] \
   && echo "$rvs_out" | grep -q "does not fit" \
   && echo "$rvs_out" | grep -q "only $rvs_avail are available"; then
    PASS=$((PASS + 1)); echo "  resetvec_fit_edge_refused: PASS (one array byte past the last fitting build is refused, naming both sizes)"
else
    echo "FAIL: resetvec_fit_edge_refused (exit=$rvs_st, artifact=$([ -f /tmp/krc_rvfit_$$ ] && echo yes || echo no), out=$(echo "$rvs_out" | head -1))"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_rvfit_$$ "$RVS_FIT"

# 7-10. THE PAYLOAD-OVERLAP BAND, interior plus both edges (whole-branch
#    review, Important 1). The design spec's stack rule has two disjuncts --
#    "--stack-top overlaps 0x1000-0x7000 OR 0x100000..+PAYLEN" -- and only
#    the first shipped, while two comments in src/main.kr asserted the second
#    had merely been deferred to finalize. It had been deferred there and
#    then not written.
#
#    WHY NO OTHER ROW OR DOCUMENTED LIMIT COVERS IT. 0x100008 is inside the
#    4 GiB map, inside installed RAM, and clear of 0x1000-0x7000, so the
#    ceiling row, the documented (unrefusable) RAM bound and the page-table
#    band rows all pass it. Forced red against the shipped compiler by
#    BOOTING it: `--stack-top=0x100008` exited 0, wrote a 65536-byte
#    artifact, put `RPL` on the wire and then wedged with no further output
#    -- `call *%rax` pushes its return address over the first eight bytes of
#    the payload it is about to enter. The same source at 0x90000 prints
#    `RPL2000000016`.
#
#    THE EDGES ARE DERIVED FROM THE REPORTED paylen, not written down: the
#    band is [stack_top-8, stack_top) against [0x100000, 0x100000+paylen),
#    which overlaps exactly when stack_top > 0x100000 and
#    stack_top < 0x100000 + paylen + 8. Same +8 convention as the page-table
#    band and as B2's stack-vs-image check, and the same documented limit:
#    it catches what is corrupt from the FIRST push. Measured and not
#    refused: 0x100400 (eight bytes past a 1016-byte payload) still boots to
#    `RPL` and dies once the payload's own frames walk down into it, exactly
#    as B2's equivalent comment already says of its own bound.
rvs_ovl_try() {   # $1 stack-top -> compiler output; exit status in $?
    rm -f /tmp/krc_rvovl_$$
    $KRC $KRC_FLAGS "$RVS_SRC" -o /tmp/krc_rvovl_$$ --target=none --arch=x86_64 \
        --emit=image --reset-vector --stack-top="$1" 2>&1
}
rvs_ovl_row() {   # $1 name, $2 stack-top, $3 "R" refused / "A" accepted
    TOTAL=$((TOTAL + 1))
    local out st; out=$(rvs_ovl_try "$2"); st=$?
    local art=no; [ -f /tmp/krc_rvovl_$$ ] && art=yes
    local why=""
    if [ "$3" = "R" ]; then
        [ $st -ne 0 ] || why="exit=0"
        [ "$art" = "no" ] || why="$why artifact-left-on-disk"
        echo "$out" | grep -q "would land inside the reset-vector payload" \
            || why="$why wrong-or-missing-message"
    else
        [ $st -eq 0 ] || why="exit=$st"
        [ "$art" = "yes" ] || why="$why no-artifact"
    fi
    rm -f /tmp/krc_rvovl_$$
    if [ -z "$why" ]; then
        PASS=$((PASS + 1)); echo "  $1: PASS"
    else
        echo "FAIL: $1 (--stack-top=$2 want $3:$why; out=$(echo "$out" | head -1 | cut -c1-100))"
        FAIL=$((FAIL + 1))
    fi
}
rvs_pl=$rvs_paylen
if [ -z "$rvs_pl" ]; then
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo "FAIL: resetvec_stack_top_in_payload (no paylen was reported, so the band's edges cannot be derived)"
else
    # 0x100000 = 1048576. Low edge ACCEPTED: the push lands below the payload.
    rvs_ovl_row resetvec_stack_top_payload_low_edge_accepted 1048576 A
    # Interior: the whole first push lands inside the payload's first bytes.
    rvs_ovl_row resetvec_stack_top_in_payload_refused 1048584 R
    # High edge: one byte of the push still inside, then fully clear.
    rvs_ovl_row resetvec_stack_top_payload_high_edge_refused $(( 1048576 + rvs_pl + 7 )) R
    rvs_ovl_row resetvec_stack_top_payload_high_edge_accepted $(( 1048576 + rvs_pl + 8 )) A
fi
rm -f "$RVS_SRC" "$RVS_A" "$RVS_B" "$RVS_P"

# --- --emit=uefi flag surface, payload geometry, PE header (D, Tasks 1-2) ----
#
# WHAT MAKES THIS MODE DANGEROUS, AND WHY EVERY ROW BELOW IS SHAPED THE WAY IT
# IS. A new --emit= value inherits four separate defaults, and all four fail
# IDENTICALLY: exit 0, no diagnostic, an artifact on disk, and every static
# assertion about the flag surface still green. They are, with the evidence
# that each is real rather than theoretical (all measured at BASE = 2b63051,
# with the mode's arms deliberately absent):
#
#   1. THE HEADER DISPATCH (src/main.kr, the `if emit_mode == 0 ... else if`
#      chain) has no terminal `else`. A mode that reaches it unnamed emits no
#      container bytes at all and header_size keeps its 120-byte default.
#   2. THE FINALIZE DISPATCH has no terminal `else` either. A fall-through
#      there gets no entry patch and no size patch, and still reaches
#      codegen_write_output.
#   3. img_raw was `emit_mode == 8` ALONE, and it gates BOTH the `_start` DCE
#      seeding AND the entry-resolver fork. Falsified by construction at BASE:
#      `fn _start() -> uint64 { return 7 }` compiles under --emit=image
#      (`image: ... entry=0`, 32 bytes) and dies "no 'main' function found"
#      under --emit=pe -- and the second branch is what a new mode inherits.
#   4. target_os SILENTLY BECOMES LINUX. The auto-set block keys on emit_mode
#      1/2/4 only, so a new mode leaves target_os at its 0 = linux default and
#      every else-POSIX fall-through in the tree answers "Linux" for it. Row
#      `uefi_target_none_is_bare_metal` is the positive control for that.
#
# THE PAYLOAD ROW IS THE ONE THAT SEES SITES 1-3. Exit 0 plus "a file exists"
# would pass with all three arms missing. `uefi_payload_is_the_image_payload`
# reads the artifact instead: the bytes after the reserved header region must
# be the SAME BYTES --emit=image emits for the same source and arch. That
# fails if the payload is truncated, if fixups went unresolved, if statics
# were dropped -- and, on arm64, if the reserved region is not a whole number
# of 4 KiB pages, because adrp bakes page(target) - page(pc) from the file
# offset and only a page-congruent shift leaves those bytes alone.
#
# THE 4 KiB IS TASK 2's CONSTRAINT, HONOURED HERE. a64_compute_va maps file
# offset -> 0x400000 + offset, so the payload's baked page arithmetic is
# congruent to its FILE offset mod 4096. A PE loader maps it at
# SectionRVA + (offset - PointerToRawData). Those agree only when
# (SectionRVA - PointerToRawData) == 0 mod 4096. This tree reserves 0x1000
# and places the section at RVA 0x1000, i.e. delta 0 -- the strongest
# form, where file offset == RVA everywhere in the file. The 0xE00 delta a
# 0x200 file alignment would produce is exactly the value that loads, runs
# and faults with no diagnostic.
#
# TASK 2 FILLED THE REGION and added the header rows below the payload rows.
# The delta-0 geometry Task 1 fixed did NOT move -- FileAlignment is 0x1000
# (== SectionAlignment), so PointerToRawData 0x1000 is a legal aligned value
# and no field has to lie to reach delta 0. Two consequences the rows below
# pin, both of which a reader would otherwise have to guess at:
#   * `entry=4096` in the report is UNCHANGED from Task 1, because the header
#     region is the same 4096 bytes it always was. The row that pins it kept
#     its value AND its report-line grep (see its comment).
#   * SizeOfRawData must be a multiple of FileAlignment, so the artifact is
#     now zero-padded to 4096 + roundup(payload, 4096). The payload rows
#     below compare the payload PREFIX byte-for-byte and assert the pad is
#     zero, which is strictly more than the old exact-length compare checked.
echo ""
echo "--- --emit=uefi flag surface + payload geometry (D, Tasks 1-2) ---"
UEFI_SRC="$DIR/../test_tmp_uefi_$$.kr"
printf 'static uint64 uefi_magic = 305419896\nfn helper(uint64 x) -> uint64 { return x + uefi_magic }\nfn main() -> uint64 { return helper(3) }\n' > "$UEFI_SRC"
# Three clauses per refusal, exactly as img_refuses(): nonzero exit, the
# diagnostic, and NO ARTIFACT. A diagnostic that still writes a file is half a
# refusal, and for this mode the half that ships is the dangerous one.
uefi_refuses() {  # $1 name, $2 grep pattern, rest = flags
    local name="$1" pat="$2"; shift 2
    TOTAL=$((TOTAL + 1))
    rm -f /tmp/krc_uefi_$$
    local out; out=$($KRC $KRC_FLAGS "$UEFI_SRC" -o /tmp/krc_uefi_$$ "$@" 2>&1); local st=$?
    if [ $st -ne 0 ] && echo "$out" | grep -q -- "$pat" && [ ! -f /tmp/krc_uefi_$$ ]; then
        PASS=$((PASS + 1)); echo "  $name: PASS"
    else
        echo "FAIL: $name (exit=$st, artifact=$([ -f /tmp/krc_uefi_$$ ] && echo yes || echo no), out=$(echo "$out" | head -1))"
        FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_uefi_$$
}

# 1-2. --target=none is REQUIRED, both by absence and against a hosted value.
#      Row 1 is the one that closes the else-POSIX door: with no --target= on
#      the line at all the resolved OS is linux, and a UEFI application full
#      of Linux syscalls is exactly the silent artifact this mode must never
#      produce.
uefi_refuses uefi_requires_target_none "requires --target=none" --arch=x86_64 --emit=uefi
uefi_refuses uefi_hosted_target_refused "requires --target=none" --arch=arm64 --target=macos --emit=uefi

# 3-4. riscv32 / xtensa: refused. There is no third Machine value to write
#      into a PE header for either, and both already own a raw path. The
#      patterns are substrings UNIQUE to each message -- "x86_64/arm64 only"
#      appears in both, so grepping it would let a defect that routes xtensa
#      to the riscv32 refusal pass (the same trap the --emit=image rows note).
uefi_refuses uefi_refuses_riscv32 "no PE Machine value for riscv32" --arch=riscv32 --target=none --emit=uefi
uefi_refuses uefi_refuses_xtensa "no PE Machine value for xtensa" --arch=xtensa --target=none --emit=uefi

# 5. NO --arch AT ALL: refused. There is no arch_set == 0 refusal for a new
#    emit mode -- --emit= sets emit_set, which skips the fat path AND its
#    "pass --arch" refusal, so the arch would silently default to x86_64 and
#    the PE Machine field would name a CPU nobody asked for. Uses the RAW
#    build/krc2 because the make-test wrapper injects --arch=x86_64, which is
#    the exact condition under test.
TOTAL=$((TOTAL + 1))
if [ -f "$DIR/../build/krc2" ]; then UEFI_RAW_KRC=$(cd "$DIR/../build" && pwd)/krc2; else UEFI_RAW_KRC=""; fi
rm -f /tmp/krc_uefina_$$
uefina_out=$("$UEFI_RAW_KRC" "$UEFI_SRC" -o /tmp/krc_uefina_$$ --target=none --emit=uefi 2>&1); uefina_st=$?
if [ -n "$UEFI_RAW_KRC" ] && [ $uefina_st -ne 0 ] \
   && echo "$uefina_out" | grep -q "requires an explicit --arch" && [ ! -f /tmp/krc_uefina_$$ ]; then
    PASS=$((PASS + 1)); echo "  uefi_requires_explicit_arch: PASS"
else
    echo "FAIL: uefi_requires_explicit_arch (exit=$uefina_st, out=$(echo "$uefina_out" | head -1))"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_uefina_$$

# 6-7. --target=android, BOTH ORDERS, because the two orders fail through
#      different doors and only one of them is covered by row 1.
#
#      MEASURED: `--target=android` does not merely set target_os, it ASSIGNS
#      emit_mode = 4 in the middle of the argument loop. So with --emit=uefi
#      FIRST the mode is silently overwritten, the emit_mode-9 refusals never
#      run, and the build emits an Android PIE ELF at exit 0 -- --emit=image
#      survives the same line only by the accident of ALSO requiring
#      --load-addr=, whose "only meaningful with --emit=image" check then
#      fires. A new mode has no such backstop, so it gets an explicit one.
#      In the other order --emit=uefi comes last, wins the chain, and is
#      caught by row 1's target_os rule instead -- a different door, hence a
#      different expected diagnostic, hence two rows and not one.
uefi_refuses uefi_refuses_target_android "overridden by --target=android" --arch=x86_64 --emit=uefi --target=android
uefi_refuses uefi_target_android_first "requires --target=none" --arch=x86_64 --target=android --emit=uefi

# 8. -g: refused. At BASE the -g refusal lives INSIDE `if emit_mode == 8`, so
#    a new mode inherits acceptance, not refusal -- and acceptance is silent:
#    measured at BASE, `--emit=pe -g` is BYTE-IDENTICAL to `--emit=pe` (2048
#    bytes both), so -g on a container that ignores it is not even visible in
#    the artifact.
uefi_refuses uefi_rejects_g "conflicts with --emit=uefi" --arch=arm64 --target=none --emit=uefi -g

# 9-11. The three --emit=image-only flags stay --emit=image-only. A UEFI
#       application is loaded and relocated by firmware: it has no load
#       address to pin, its stack is set up before entry so there is no stub
#       to emit, and the arm64 Linux Image header is a different container.
uefi_refuses uefi_load_addr_refused "only meaningful with --emit=image" --arch=x86_64 --target=none --emit=uefi --load-addr=0x400000
uefi_refuses uefi_stack_top_refused "only meaningful with --emit=image" --arch=x86_64 --target=none --emit=uefi --stack-top=0x90000
uefi_refuses uefi_image_header_refused "only meaningful with --emit=image" --arch=arm64 --target=none --emit=uefi --image-header

# 12-13. --targets= forces the fat path even with --emit= present, so both
#        spellings are pinned exactly as the --emit=image rows pin them: check
#        ORDER is the only thing keeping a fat build from swallowing this mode.
uefi_refuses uefi_targets_no_none "requires --target=none" --arch=x86_64 --emit=uefi --targets=linux-x64
uefi_refuses uefi_targets_with_none "cannot build a fat binary" --arch=x86_64 --target=none --emit=uefi --targets=linux-x64

# 14. --emit= LAST-WINS still works in the uefi -> other direction. This is
#     the row that keeps the android-override refusal narrow: it must fire on
#     an emit_mode clobbered by --target=android and NOT on one a later
#     --emit= legitimately replaced. `--emit=uefi --emit=elfexe --target=none`
#     is a plain accepted bare-metal ELF build.
TOTAL=$((TOTAL + 1))
rm -f /tmp/krc_uefilw_$$
if $KRC $KRC_FLAGS "$UEFI_SRC" -o /tmp/krc_uefilw_$$ --arch=x86_64 --target=none --emit=uefi --emit=elfexe >/dev/null 2>&1 \
   && [ -f /tmp/krc_uefilw_$$ ] && head -c 4 /tmp/krc_uefilw_$$ | grep -q ELF; then
    PASS=$((PASS + 1)); echo "  uefi_emit_last_wins_away: PASS (--emit=uefi --emit=elfexe builds an ELF)"
else
    echo "FAIL: uefi_emit_last_wins_away (the override refusal is too wide: a later --emit= is last-wins, not a clobber)"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_uefilw_$$
# ...and the other direction refuses on the resolved mode, not the spelling.
uefi_refuses uefi_emit_last_wins_to "requires --target=none" --arch=x86_64 --emit=elfexe --emit=uefi

# 15. THE target_os POSITIVE CONTROL (Task 1, Step 4). Everything above is a
#     refusal, and refusals cannot show what the ACCEPTED path resolved to.
#     This one can: `print` is refused under --target=none with a message no
#     hosted target ever produces, and compiles clean on every hosted one. So
#     an --emit=uefi build that answers "not available on bare metal" is a
#     build whose target_os is 4 and not 0.
#
#     CONSTRUCTED, NOT ASSUMED. With the --target=none refusal disabled in a
#     scratch build of the compiler, `--arch=x86_64 --emit=uefi` on this exact
#     program COMPILED CLEAN: exit 0, a 4312-byte artifact (216-byte payload),
#     and `objdump -D -b binary -m i386:x86-64` counts FOUR x86_64 `syscall`
#     instructions in it -- Linux syscalls inside a UEFI application. The
#     default really is linux; this row is what witnesses it staying gone.
TOTAL=$((TOTAL + 1))
UEFI_PR="$DIR/../test_tmp_uefipr_$$.kr"
printf 'fn main() -> uint64 { print(1) return 0 }\n' > "$UEFI_PR"
rm -f /tmp/krc_uefipr_$$
uefipr_out=$($KRC $KRC_FLAGS "$UEFI_PR" -o /tmp/krc_uefipr_$$ --arch=x86_64 --target=none --emit=uefi 2>&1); uefipr_st=$?
if [ $uefipr_st -ne 0 ] && echo "$uefipr_out" | grep -q "not available on bare metal" && [ ! -f /tmp/krc_uefipr_$$ ]; then
    PASS=$((PASS + 1)); echo "  uefi_target_none_is_bare_metal: PASS (accepted uefi path resolves target_os=none, not linux)"
else
    echo "FAIL: uefi_target_none_is_bare_metal (exit=$uefipr_st, out=$(echo "$uefipr_out" | head -1) -- an --emit=uefi build that accepts print() resolved target_os to a hosted OS)"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_uefipr_$$ "$UEFI_PR"

# 16. A `_start`-only program builds -- site 3, img_raw. At BASE this program
#     dies "no 'main' function found" on every mode but 8, because img_raw
#     gates both the DCE seeding that keeps `_start` alive and the
#     find_entry_node-vs-find_main_offset fork. Asserted through the REPORT
#     line, not just exit 0: an image whose entry never resolved reports the
#     0xFFFFFFFF sentinel (4294967295) while exiting 0.
#
#     DO NOT DROP THE REPORT-LINE GREP. This row is named for the img_raw site,
#     but it is ALSO THE SOLE WITNESS FOR THE FINALIZE ARM -- measured: delete
#     that arm and 20 of 21 uefi rows stay green, because the artifact comes out
#     BYTE-IDENTICAL and only the report line disappears. A rewrite that keeps
#     the entry VALUE but drops the grep silently retires the only coverage of
#     the most dangerous silent site in this sub-project.
#     Task 2 must change the expected entry (4096 pins today's geometry); it
#     must NOT change how the entry is observed.
#
#     TASK 2 REPORT: the VALUE did not have to move and the grep is untouched.
#     Task 2 filled the reserved region rather than resizing it -- the header
#     is 0x170 bytes inside the same 4096-byte region, PointerToRawData is
#     still 0x1000, and a `_start`-only payload still begins at file offset
#     4096. So 4096 is re-derived here, not inherited: it is asserted against
#     the same artifact whose AddressOfEntryPoint row 21 reads back and
#     compares to this very report line.
#
#     THE FINALIZE ARM NOW HAS MORE THAN ONE WITNESS, which is the point of
#     saying so. Re-measured at Task 2 with the arm deleted from a scratch
#     compiler: this row reds as before, AND rows 21-22 red on entry_point,
#     size_of_code, size_of_image, virtual_size and size_of_raw_data (all
#     left at 0), and rows 17-18 red on the missing file-alignment padding.
#     The grep stays anyway -- it is the only one of those that survives a
#     future header rewrite.
TOTAL=$((TOTAL + 1))
UEFI_ST="$DIR/../test_tmp_uefist_$$.kr"
printf 'fn _start() -> uint64 { return 7 }\n' > "$UEFI_ST"
rm -f /tmp/krc_uefist_$$
uefist_out=$($KRC $KRC_FLAGS "$UEFI_ST" -o /tmp/krc_uefist_$$ --arch=x86_64 --target=none --emit=uefi 2>&1); uefist_st=$?
uefist_ent=$(echo "$uefist_out" | grep -o 'entry=[0-9]*' | head -1)
if [ $uefist_st -eq 0 ] && [ -f /tmp/krc_uefist_$$ ] && [ "$uefist_ent" = "entry=4096" ]; then
    PASS=$((PASS + 1)); echo "  uefi_start_only_program: PASS ($uefist_ent, no 'main' in the source)"
else
    echo "FAIL: uefi_start_only_program (exit=$uefist_st, entry='$uefist_ent' want entry=4096 -- if Task 2 moved the geometry, update the VALUE and keep the report-line grep, out=$(echo "$uefist_out" | head -1))"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_uefist_$$ "$UEFI_ST"

# 17-18. THE PAYLOAD ROW (see this section's header). Per arch: the uefi
#        artifact's bytes from 4096 on begin with the --emit=image artifact
#        for the same source, BYTE FOR BYTE, and everything after that is
#        zero file-alignment padding.
#
#        WHY THIS IS NO LONGER AN EXACT-LENGTH COMPARE (Task 2). At Task 1 the
#        artifact was exactly 4096 + payload, because nothing constrained its
#        tail. Task 2's header declares FileAlignment 0x1000, and a PE section's
#        SizeOfRawData must be a multiple of FileAlignment -- so the choice is
#        between padding the file and writing a SizeOfRawData that runs past
#        EOF, which the derivation reference lists as a REJECTION. The file is
#        padded. All three clauses below are asserted, so the row still fails
#        on a truncated payload, on unresolved fixups, on dropped statics and
#        -- on arm64 -- on a non-page-congruent header region; it additionally
#        now fails if the padding is not zero or not the exact amount the
#        declared alignment requires.
#
#        WHY BYTE-FOR-BYTE IS AVAILABLE AT ALL, and it is not a coincidence:
#        --load-addr is echoed and never embedded, x86_64 image output is
#        RIP-relative throughout, and arm64's adrp/add pairs survive a shift
#        that is a whole number of pages.
#
#        THE ARM64 ARM IS THE CONGRUENCE CHECK; THE x86_64 ARM IS NOT, and
#        the difference was measured rather than assumed. Rebuilding the
#        compiler with the reserved region set to 0x200 instead of 0x1000 and
#        re-running both arms:
#          * arm64  -> payload DIFFERS. Two independent mechanisms, and the
#            weaker source only needs the first: the `add` half of each
#            adrp/add pair carries `target & 0xFFF`, which any non-4096
#            multiple moves (measured on this 3-line source, 56-byte payload);
#            and on a payload that spans pages the `adrp` page difference
#            itself moves (measured separately on a 4544-byte payload).
#          * x86_64 -> payload still IDENTICAL, at 0x200 and at 0x1000 alike.
#            It is RIP-relative throughout and genuinely immune, so its arm
#            here proves payload COMPLETENESS and nothing about geometry.
#        So do not read the x86_64 row as covering C1. Only arm64 does.
#
#        The source carries a static AND a cross-function call on purpose:
#        a leaf that returns a constant has no fixups to resolve, so it would
#        pass this row with the static-fixup and call-fixup passes skipped
#        entirely -- and with no static there is no adrp/add pair, which is
#        the only thing the arm64 arm can see a bad geometry through.
for UA in x86_64 arm64; do
    ULOAD=0x400000
    if [ "$UA" = "arm64" ]; then ULOAD=0x40400000; fi
    TOTAL=$((TOTAL + 1))
    rm -f /tmp/krc_ue_$$ /tmp/krc_ui_$$ /tmp/krc_ut_$$
    $KRC $KRC_FLAGS "$UEFI_SRC" -o /tmp/krc_ue_$$ --arch=$UA --target=none --emit=uefi >/dev/null 2>&1
    $KRC $KRC_FLAGS "$UEFI_SRC" -o /tmp/krc_ui_$$ --arch=$UA --target=none --emit=image --load-addr=$ULOAD >/dev/null 2>&1
    if [ -f /tmp/krc_ue_$$ ] && [ -f /tmp/krc_ui_$$ ]; then
        ue_n=$(wc -c < /tmp/krc_ue_$$); ui_n=$(wc -c < /tmp/krc_ui_$$)
        ui_pad=$(( (ui_n + 4095) / 4096 * 4096 ))
        tail -c +4097 /tmp/krc_ue_$$ | head -c "$ui_n" > /tmp/krc_ut_$$
        ue_tailnz=$(tail -c +$((4097 + ui_n)) /tmp/krc_ue_$$ | tr -d '\000' | wc -c)
        if [ "$ue_n" -eq "$((ui_pad + 4096))" ] && cmp -s /tmp/krc_ut_$$ /tmp/krc_ui_$$ && [ "$ue_tailnz" = "0" ]; then
            PASS=$((PASS + 1)); echo "  uefi_payload_is_the_image_payload_$UA: PASS ($ue_n = 4096 + $ui_n payload + $((ui_pad - ui_n)) zero pad, payload byte-identical)"
        else
            echo "FAIL: uefi_payload_is_the_image_payload_$UA (uefi=$ue_n want $((ui_pad + 4096)); image=$ui_n; payload $(cmp -s /tmp/krc_ut_$$ /tmp/krc_ui_$$ && echo matches || echo DIFFERS); $ue_tailnz non-zero bytes in the pad)"; FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL: uefi_payload_is_the_image_payload_$UA (one of the two builds produced no artifact)"; FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_ue_$$ /tmp/krc_ui_$$ /tmp/krc_ut_$$
done

# 19. The reserved header region is now FILLED (Task 2). At Task 1 this row
#     asserted 4096 zero bytes and carried a note telling Task 2 to come here
#     and say what it wrote; this is that. The region is still exactly 4096
#     bytes -- the geometry did not move -- but it is no longer empty, and the
#     tail of it (past the one section header, 0x170) is still zero, so a
#     header that grew past its region would red this rather than silently
#     overwrite the first instruction of the payload.
TOTAL=$((TOTAL + 1))
rm -f /tmp/krc_uez_$$
$KRC $KRC_FLAGS "$UEFI_SRC" -o /tmp/krc_uez_$$ --arch=x86_64 --target=none --emit=uefi >/dev/null 2>&1
uez_nz=$(head -c 4096 /tmp/krc_uez_$$ 2>/dev/null | tr -d '\000' | wc -c)
uez_tail=$(head -c 4096 /tmp/krc_uez_$$ 2>/dev/null | tail -c +369 | tr -d '\000' | wc -c)
if [ -f /tmp/krc_uez_$$ ] && [ "$uez_nz" -gt 0 ] && [ "$uez_tail" = "0" ]; then
    PASS=$((PASS + 1)); echo "  uefi_header_region_filled: PASS ($uez_nz non-zero bytes in 0x0-0x170, 0 after)"
else
    echo "FAIL: uefi_header_region_filled (artifact=$([ -f /tmp/krc_uez_$$ ] && echo yes || echo no), $uez_nz non-zero bytes in the region want >0, $uez_tail non-zero past 0x170 want 0)"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_uez_$$

# 21-22. EVERY LOAD-BEARING PE FIELD, READ FROM THE ARTIFACT AT ITS OFFSET.
#        One row per arch, because Machine is the only field that differs and
#        an arch-blind row would let one arch's header be emitted for the
#        other. Offsets are absolute file offsets, which under the delta-0
#        geometry are also RVAs: DOS 0x00, PE signature 0x40, COFF 0x44,
#        optional header 0x58 (240 bytes, so it ends at 0x148), the single
#        section header 0x148 (40 bytes, ending 0x170).
#
#        THE THREE FIELDS THAT ARE NOT SELF-EVIDENT, and why each is asserted
#        against a DERIVED value rather than a literal:
#          * AddressOfEntryPoint is compared to the `entry=` the compiler
#            REPORTS, not to a constant -- and this clause used to claim a
#            discrimination the comparison CANNOT make. It cannot see a wrong
#            entry VALUE: main.kr hands `entry_off` to patch_uefi_headers and
#            prints THAT SAME VARIABLE a few lines later with no reassignment
#            in between, so one bad entry_off moves both sides together and
#            this row stays green. A literal would be no better -- every
#            source in this block puts its entry at payload offset 0, so the
#            reported 4096 is also the value the "entry at section start"
#            defect produces.
#            What the comparison DOES prove is that the patch landed at the
#            right OFFSET among patch_uefi_headers' five patch_u32 targets,
#            and that the report line still describes the artifact on disk.
#            THE ENTRY VALUE IS COVERED, JUST NOT HERE: boot-gate L7 boots an
#            application whose entry is 4772, and
#            L7_control_entry_at_section_start_silent boots 4096 and shows it
#            loads, runs and says nothing.
#          * VirtualSize is compared to the size of the --emit=image artifact
#            for the same source -- i.e. the true payload length. The
#            derivation reference re-classified "VirtualSize too small" from
#            IGNORED to a LOADED_FAULTED #PF, so this is a boot-oracle.
#          * SizeOfRawData is compared to (file size - 4096). "Raw data past
#            EOF" is also a rejection, and a SizeOfRawData that merely looks
#            plausible is exactly how that ships.
#        SizeOfOptionalHeader is checked for the CONSISTENCY rule OVMF
#        actually enforces -- SizeOfOptionalHeader - 112 == NumberOfRvaAndSizes
#        * 8 -- and not merely for the value 240.
ue_u16() { od -An -tu2 -j "$2" -N2 -v "$1" 2>/dev/null | tr -d ' '; }
ue_u32() { od -An -tu4 -j "$2" -N4 -v "$1" 2>/dev/null | tr -d ' '; }
ue_u64() { od -An -tu8 -j "$2" -N8 -v "$1" 2>/dev/null | tr -d ' '; }
ue_hex() { od -An -tx1 -j "$2" -N"$3" -v "$1" 2>/dev/null | tr -d ' \n'; }
uh_bad=""
uh_chk() { [ "$2" = "$3" ] || uh_bad="$uh_bad $1(want=$2 got=$3)"; }
for UA in x86_64 arm64; do
    UMACH=34404                                     # 0x8664 IMAGE_FILE_MACHINE_AMD64
    if [ "$UA" = "arm64" ]; then UMACH=43620; fi    # 0xAA64 IMAGE_FILE_MACHINE_ARM64
    ULOAD=0x400000
    if [ "$UA" = "arm64" ]; then ULOAD=0x40400000; fi
    TOTAL=$((TOTAL + 1))
    rm -f /tmp/krc_uh_$$ /tmp/krc_uhi_$$
    uh_out=$($KRC $KRC_FLAGS "$UEFI_SRC" -o /tmp/krc_uh_$$ --arch=$UA --target=none --emit=uefi 2>&1)
    $KRC $KRC_FLAGS "$UEFI_SRC" -o /tmp/krc_uhi_$$ --arch=$UA --target=none --emit=image --load-addr=$ULOAD >/dev/null 2>&1
    uh_bad=""
    if [ -f /tmp/krc_uh_$$ ] && [ -f /tmp/krc_uhi_$$ ]; then
        uh_ent=$(echo "$uh_out" | grep -o 'entry=[0-9]*' | head -1 | cut -d= -f2)
        uh_fsz=$(wc -c < /tmp/krc_uh_$$)
        uh_pay=$(wc -c < /tmp/krc_uhi_$$)
        uh_raw=$((uh_fsz - 4096))
        # DOS + PE signature
        uh_chk dos_mz            4d5a       "$(ue_hex /tmp/krc_uh_$$ 0 2)"
        uh_chk e_lfanew          64         "$(ue_u32 /tmp/krc_uh_$$ 60)"
        uh_chk pe_signature      50450000   "$(ue_hex /tmp/krc_uh_$$ 64 4)"
        # COFF header
        uh_chk machine           "$UMACH"   "$(ue_u16 /tmp/krc_uh_$$ 68)"
        uh_chk number_of_sections 1         "$(ue_u16 /tmp/krc_uh_$$ 70)"
        uh_soh=$(ue_u16 /tmp/krc_uh_$$ 84)
        uh_nrs=$(ue_u32 /tmp/krc_uh_$$ 196)
        uh_chk size_of_opt_header_consistency "$((uh_nrs * 8))" "$((uh_soh - 112))"
        uh_char=$(ue_u16 /tmp/krc_uh_$$ 86)
        uh_chk relocs_stripped_clear   0    "$((uh_char & 1))"
        uh_chk executable_image_set    2    "$((uh_char & 2))"
        # Optional header (PE32+)
        uh_chk magic_pe32plus    523        "$(ue_u16 /tmp/krc_uh_$$ 88)"   # 0x20b
        uh_chk size_of_code      "$uh_raw"  "$(ue_u32 /tmp/krc_uh_$$ 92)"
        uh_chk entry_point       "$uh_ent"  "$(ue_u32 /tmp/krc_uh_$$ 104)"
        uh_chk base_of_code      4096       "$(ue_u32 /tmp/krc_uh_$$ 108)"
        uh_chk image_base        0          "$(ue_u64 /tmp/krc_uh_$$ 112)"
        uh_chk section_alignment 4096       "$(ue_u32 /tmp/krc_uh_$$ 120)"
        uh_chk file_alignment    4096       "$(ue_u32 /tmp/krc_uh_$$ 124)"
        uh_chk size_of_image     "$((4096 + uh_raw))" "$(ue_u32 /tmp/krc_uh_$$ 144)"
        uh_chk size_of_headers   4096       "$(ue_u32 /tmp/krc_uh_$$ 148)"
        uh_chk subsystem         10         "$(ue_u16 /tmp/krc_uh_$$ 156)"
        uh_chk number_of_rva_and_sizes 16   "$uh_nrs"
        # All 16 data directories zero -- in particular index 1, the import
        # table, which is what a header copied from format_pe.kr would carry.
        uh_chk data_directories_all_zero 0 \
            "$(ue_hex /tmp/krc_uh_$$ 200 128 | tr -d '0' | wc -c)"
        uh_chk no_kernel32 0 "$(grep -c kernel32 /tmp/krc_uh_$$ 2>/dev/null)"
        # The one section header
        uh_chk section_name      2e74657874000000 "$(ue_hex /tmp/krc_uh_$$ 328 8)"
        uh_chk virtual_size      "$uh_pay"  "$(ue_u32 /tmp/krc_uh_$$ 336)"
        uh_chk virtual_address   4096       "$(ue_u32 /tmp/krc_uh_$$ 340)"
        uh_chk size_of_raw_data  "$uh_raw"  "$(ue_u32 /tmp/krc_uh_$$ 344)"
        uh_chk pointer_to_raw_data 4096     "$(ue_u32 /tmp/krc_uh_$$ 348)"
        uh_chk pointer_to_relocations 0     "$(ue_u32 /tmp/krc_uh_$$ 352)"
        uh_chk pointer_to_linenumbers 0     "$(ue_u32 /tmp/krc_uh_$$ 356)"
        uh_chk number_of_relocations  0     "$(ue_u16 /tmp/krc_uh_$$ 360)"
        uh_chk number_of_linenumbers  0     "$(ue_u16 /tmp/krc_uh_$$ 362)"
        # 0xE0000020 = CODE|EXECUTE|READ|WRITE. The WRITE bit is arm64's, and
        # it is not cosmetic -- but the way it fails is narrower than "arm64
        # needs a writable .text", and the difference decides whether a test
        # can see it at all. Measured under AAVMF 2024.02 with 0x60000020:
        # a payload that only READS its statics RAN; a payload that WRITES one
        # printed its first line and then took `Synchronous Exception`, i.e.
        # the abort is on the STORE, not at load. x86_64 ran in every case.
        # One layout for both arches, so both carry the bit.
        uh_chk section_characteristics 3758096416 "$(ue_u32 /tmp/krc_uh_$$ 364)"
    else
        uh_bad=" no artifact (uefi=$([ -f /tmp/krc_uh_$$ ] && echo yes || echo no) image=$([ -f /tmp/krc_uhi_$$ ] && echo yes || echo no))"
    fi
    if [ -z "$uh_bad" ]; then
        PASS=$((PASS + 1)); echo "  uefi_pe_header_fields_$UA: PASS (machine=$UMACH subsystem=10 entry=$uh_ent)"
    else
        echo "FAIL: uefi_pe_header_fields_$UA:$uh_bad"; FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_uh_$$ /tmp/krc_uhi_$$
done

# 23-24. C1, PAGE CONGRUENCE, ASSERTED FROM THE ARTIFACT'S OWN FIELDS. Row 21's
#        two literals (VirtualAddress 4096, PointerToRawData 4096) already pin
#        today's values; this row states the RULE those values satisfy, so that
#        a future geometry change is forced to satisfy it rather than to edit
#        two unrelated-looking constants. The failure it guards is the one with
#        no local symptom at all: the arm64 payload's baked adrp page arithmetic
#        is congruent to its FILE offset mod 4096, the loader maps it at
#        SectionRVA + (offset - PointerToRawData), and a non-page delta makes
#        every page computation wrong -- measured as LOADED_FAULTED, at exit 0,
#        with file(1) still calling the artifact an EFI application.
for UA in x86_64 arm64; do
    TOTAL=$((TOTAL + 1))
    rm -f /tmp/krc_uc_$$
    $KRC $KRC_FLAGS "$UEFI_SRC" -o /tmp/krc_uc_$$ --arch=$UA --target=none --emit=uefi >/dev/null 2>&1
    if [ -f /tmp/krc_uc_$$ ]; then
        uc_rva=$(ue_u32 /tmp/krc_uc_$$ 340); uc_ptr=$(ue_u32 /tmp/krc_uc_$$ 348)
        uc_delta=$((uc_rva - uc_ptr))
        # `-gt 0` is not decoration: without it this row passes on an artifact
        # with NO HEADER AT ALL, where both fields read 0 and 0 - 0 is trivially
        # congruent. Measured -- it passed exactly that way against the Task 1
        # binary before the header existed.
        if [ "$uc_ptr" -gt 0 ] && [ "$uc_rva" -gt 0 ] && [ $((uc_delta % 4096)) -eq 0 ]; then
            PASS=$((PASS + 1)); echo "  uefi_page_congruence_$UA: PASS (RVA $uc_rva - PointerToRawData $uc_ptr = $uc_delta, 0 mod 4096)"
        else
            echo "FAIL: uefi_page_congruence_$UA (RVA $uc_rva, PointerToRawData $uc_ptr, delta $uc_delta -- both must be non-zero and the delta 0 mod 4096, or every baked arm64 adrp page delta in the payload is wrong and the image loads and faults with no diagnostic)"; FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL: uefi_page_congruence_$UA (no artifact)"; FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_uc_$$
done

# 25. file(1) MUST SAY "PE32+ executable (EFI application)". A second oracle,
#     independent of this suite's own idea of the layout.
#
# 26-28. ...AND THE MUTATION CONTROLS, because "file says EFI application" is
#     worth nothing without knowing what makes it stop saying it. All three
#     were measured; two of them do NOT do what the obvious guess says:
#       * Subsystem 10 -> 3 : "PE32+ executable (console)". THIS is the field
#         the "EFI application" phrase keys on, and it is also the field OVMF
#         rejects. It is therefore the only one of the three that is a
#         discriminating oracle for this mode.
#       * Magic 0x20b -> 0x10b : "PE32 executable (EFI application)" -- still
#         an EFI application to file(1), just a 32-bit one. A revision of the
#         spec claimed this gives `data`; it does not.
#       * DOS 'MZ' -> 'XX' : "data". Only destroying the DOS magic does that,
#         which is why `file` reporting `data` is a test of the FIRST TWO BYTES
#         and of nothing else.
ue_poke() {  # $1 file, $2 decimal offset, rest = decimal byte values
    local f="$1" off="$2" b; shift 2
    for b in "$@"; do
        printf "$(printf '\\x%02x' "$b")" | dd of="$f" bs=1 seek="$off" conv=notrunc status=none
        off=$((off + 1))
    done
}
TOTAL=$((TOTAL + 1))
rm -f /tmp/krc_uf_$$
$KRC $KRC_FLAGS "$UEFI_SRC" -o /tmp/krc_uf_$$ --arch=x86_64 --target=none --emit=uefi >/dev/null 2>&1
uf_says=$(file -b /tmp/krc_uf_$$ 2>/dev/null)
if echo "$uf_says" | grep -q "PE32+ executable" && echo "$uf_says" | grep -q "EFI application"; then
    PASS=$((PASS + 1)); echo "  uefi_file_says_efi_application: PASS ($uf_says)"
else
    echo "FAIL: uefi_file_says_efi_application (file(1) says '$uf_says')"; FAIL=$((FAIL + 1))
fi
# 26: Subsystem 10 -> 3 must LOSE the "EFI application" phrase while REMAINING
#     a PE32+ executable. Both halves are needed. Measured against the Task 1
#     binary, whose header region was all zeros: `file` said `data`, which
#     satisfies "does not say EFI application" and made this row green on an
#     artifact with no header at all. A control that cannot fail on a missing
#     header is not a control.
TOTAL=$((TOTAL + 1))
cp /tmp/krc_uf_$$ /tmp/krc_ufs_$$; ue_poke /tmp/krc_ufs_$$ 156 3 0
ufs_says=$(file -b /tmp/krc_ufs_$$ 2>/dev/null)
if echo "$ufs_says" | grep -q "PE32+ executable" && ! echo "$ufs_says" | grep -q "EFI application"; then
    PASS=$((PASS + 1)); echo "  uefi_file_control_subsystem: PASS (subsystem 3 -> '$ufs_says')"
else
    echo "FAIL: uefi_file_control_subsystem (subsystem patched to 3 and file(1) still says '$ufs_says' -- the phrase is not keyed on the subsystem, so row 25 is not the oracle it is documented as)"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_ufs_$$
# 27: Magic 0x20b -> 0x10b drops the '+' and KEEPS the phrase. Stated so the
#     control above cannot be mistaken for "any header damage loses it".
TOTAL=$((TOTAL + 1))
cp /tmp/krc_uf_$$ /tmp/krc_ufm_$$; ue_poke /tmp/krc_ufm_$$ 88 11 1
ufm_says=$(file -b /tmp/krc_ufm_$$ 2>/dev/null)
if echo "$ufm_says" | grep -q "PE32 executable" && echo "$ufm_says" | grep -q "EFI application"; then
    PASS=$((PASS + 1)); echo "  uefi_file_control_magic: PASS (magic 0x10b -> '$ufm_says')"
else
    echo "FAIL: uefi_file_control_magic (magic patched to 0x10b and file(1) says '$ufm_says', expected a PE32 (not PE32+) EFI application)"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_ufm_$$
# 28: only the DOS magic gives `data` -- asserted as a CHANGE from the pristine
#     artifact's answer, for the reason row 26 records: "`file` says data" is
#     also what a header-less artifact produces.
TOTAL=$((TOTAL + 1))
cp /tmp/krc_uf_$$ /tmp/krc_ufd_$$; ue_poke /tmp/krc_ufd_$$ 0 88 88
ufd_says=$(file -b /tmp/krc_ufd_$$ 2>/dev/null)
if [ "$ufd_says" = "data" ] && [ "$uf_says" != "data" ]; then
    PASS=$((PASS + 1)); echo "  uefi_file_control_dos_magic: PASS (MZ -> XX gives 'data')"
else
    echo "FAIL: uefi_file_control_dos_magic (DOS magic destroyed and file(1) says '$ufd_says', expected 'data')"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_ufd_$$ /tmp/krc_uf_$$

# 20. THE `--emit=pe` REFUSAL'S REASONING (Task 1, Step 6). The check stays --
#     a Windows PE genuinely cannot run without the loader to bind its
#     imports; measured, its entry is `call *0xf6e(%rip)` into an unresolved
#     IAT slot. Only the STATED REASON was false: "a subsystem field" and
#     "nothing on bare metal loads one" are both things UEFI firmware does
#     every boot. The message must now point at --emit=uefi, and must not
#     claim that a PE is unloadable on bare metal as such.
TOTAL=$((TOTAL + 1))
rm -f /tmp/krc_uepe_$$
uepe_out=$($KRC $KRC_FLAGS "$UEFI_SRC" -o /tmp/krc_uepe_$$ --arch=x86_64 --target=none --emit=pe 2>&1); uepe_st=$?
if [ $uepe_st -ne 0 ] && [ ! -f /tmp/krc_uepe_$$ ] \
   && echo "$uepe_out" | grep -q -- "--emit=uefi" \
   && ! echo "$uepe_out" | grep -q "nothing on bare metal loads one"; then
    PASS=$((PASS + 1)); echo "  pe_tnone_refusal_points_at_uefi: PASS"
else
    echo "FAIL: pe_tnone_refusal_points_at_uefi (exit=$uepe_st, out=$(echo "$uepe_out" | head -1))"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_uepe_$$

rm -f "$UEFI_SRC"

# --- `--help` vs docs/LANGUAGE.md vs the compiler (sub-project B2, M5) -------
#
# WHY THIS SECTION EXISTS. Sub-project B2's final review found TWO separate
# documentation defects inside a single branch: `--help` and docs/LANGUAGE.md
# both stated an x86_64 `--stack-top` range the compiler refuses (I1), and
# three "a later task will do this / this emits nothing" comments survived the
# task that was supposed to retire them (I2). Both were found by a human
# reading the two texts against the code. Nothing in the suite could have
# found either, because nothing in the suite reads those texts at all.
#
# A DOC IS A CLAIM ABOUT BEHAVIOUR, so it can be tested like one. Two
# mechanisms, deliberately different in kind:
#
#   * COVERAGE (rows 1-2) is mechanical and total: every flag one text names,
#     the other must name too. It catches the flag that gets added to the
#     parser and to --help and never reaches the manual, and the flag the
#     manual still describes after it was removed.
#   * AGREEMENT (row 3) is behavioural: the numbers both texts print for the
#     x86_64 --stack-top bounds are probed against the compiler itself. This
#     is the half that would have caught I1 -- the texts were self-consistent
#     and both wrong, so no amount of text-vs-text checking could see it.
#
# NEITHER HALF ALONE IS ENOUGH and that is the point: move a bound in the code
# and row 3 reds; edit a bound in one text and rows 1-3 red; edit it in both
# texts without touching the code and row 3 reds. There is no single-file edit
# that leaves all three green and the tree inconsistent.
echo ""
echo "--- --help vs docs/LANGUAGE.md consistency (B2) ---"
HD_DOC="$DIR/../docs/LANGUAGE.md"
HD_HELP=/tmp/krc_hd_help_$$
$KRC $KRC_FLAGS --help > "$HD_HELP" 2>&1
# Flag tokens, from either text. The trailing filter drops markdown anchors
# like `#embedded-targets-riscv32--xtensa--esp32`, which are not flags: a real
# long option never contains a second `--`.
hd_flags() { grep -o -- '--[A-Za-z0-9][A-Za-z0-9-]*' "$1" | grep -v -- '.--' | sort -u; }

# 1. Every flag --help lists is named in the manual.
TOTAL=$((TOTAL + 1))
hd_missing=""
for hd_f in $(hd_flags "$HD_HELP"); do
    grep -qF -- "$hd_f" "$HD_DOC" || hd_missing="$hd_missing $hd_f"
done
if [ -z "$hd_missing" ]; then
    PASS=$((PASS + 1)); echo "  help_flags_are_documented: PASS ($(hd_flags "$HD_HELP" | wc -l) flags)"
else
    echo "FAIL: help_flags_are_documented (--help lists these and docs/LANGUAGE.md never mentions them:$hd_missing)"
    FAIL=$((FAIL + 1))
fi

# 2. ...and the reverse: no flag survives in the manual after --help drops it.
#    A separate row because the two directions want opposite fixes -- one says
#    "document this", the other says "the manual describes a flag that is gone".
TOTAL=$((TOTAL + 1))
hd_stale=""
for hd_f in $(hd_flags "$HD_DOC"); do
    grep -qF -- "$hd_f" "$HD_HELP" || hd_stale="$hd_stale $hd_f"
done
if [ -z "$hd_stale" ]; then
    PASS=$((PASS + 1)); echo "  docs_flags_are_in_help: PASS ($(hd_flags "$HD_DOC" | wc -l) flags)"
else
    echo "FAIL: docs_flags_are_in_help (docs/LANGUAGE.md names these and --help does not:$hd_stale)"
    FAIL=$((FAIL + 1))
fi

# 3. The x86_64 --stack-top bounds: stated in both texts, enforced by the
#    compiler, one row per claim.
#
#    THE DOCS GREP IS SCOPED to the "Self-booting images" section, from its
#    heading to the next heading. Unscoped, `0x1000` is satisfied by the
#    integer-literal example in section 4 and the claim would be vacuous --
#    which is the check-that-cannot-fail shape this branch has already shipped
#    once. The help grep is scoped to the --stack-top line for the same reason.
HD_SEC=/tmp/krc_hd_sec_$$
awk '/^#### Self-booting images/{s=1;print;next} s&&/^#/{exit} s{print}' "$HD_DOC" > "$HD_SEC"
HD_LINE=/tmp/krc_hd_line_$$
grep -- '--stack-top=<addr>' "$HD_HELP" > "$HD_LINE"
HD_SRC="$DIR/../test_tmp_hd_$$.kr"
printf 'fn main() -> uint64 { return 0 }\n' > "$HD_SRC"
# $1 label, $2 the number both texts must state, $3 stack top, $4 A|R, $5 why
hd_bound() {
    local label="$1" num="$2" st="$3" want="$4" why="$5"
    TOTAL=$((TOTAL + 1))
    local art=/tmp/krc_hd_art_$$ got
    rm -f "$art"
    if $KRC $KRC_FLAGS "$HD_SRC" -o "$art" --arch=x86_64 --target=none --emit=image \
           --load-addr=0x400000 --stack-top=$st >/dev/null 2>&1 && [ -f "$art" ]; then
        got=A
    else
        got=R
    fi
    rm -f "$art"
    if ! grep -qF -- "$num" "$HD_LINE"; then
        echo "FAIL: $label (--help's --stack-top line does not state $num -- $why)"; FAIL=$((FAIL + 1))
    elif ! grep -qF -- "$num" "$HD_SEC"; then
        echo "FAIL: $label (docs/LANGUAGE.md's self-booting section does not state $num -- $why)"; FAIL=$((FAIL + 1))
    elif [ "$got" != "$want" ]; then
        echo "FAIL: $label (both texts state $num, but the compiler ${got:+$([ "$got" = A ] && echo ACCEPTS || echo REFUSES)} --stack-top=$st -- $why)"; FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1)); echo "  $label: PASS ($num stated in both texts; --stack-top=$st $([ "$want" = A ] && echo accepted || echo refused))"
    fi
}
hd_bound help_docs_stacktop_ceiling      0x40000000 0x40000000 A "the identity map covers exactly the first 1 GiB, and the bound is inclusive: the first push from 0x40000000 lands at 0x3FFFFFF8, inside the map"
hd_bound help_docs_stacktop_above_ceiling 0x40000000 0x40000010 R "one step past the stated ceiling must be refused, or the ceiling is decorative"
hd_bound help_docs_stacktop_pt_low        0x1000     0x1000     A "0x1000 is the highest stack top whose first push clears the page tables (it lands at 0xFF8)"
hd_bound help_docs_stacktop_pt_high       0x4008     0x4008     A "0x4008 is the lowest stack top whose first push clears the page tables (it lands at 0x4000)"
hd_bound help_docs_stacktop_pt_inside     0x4008     0x4007     R "one below the stated low bound pushes into the page directory's last entry"

# 4. THE --image-header HONESTY TEXT IS A DELIVERABLE, SO IT IS GUARDED
#    (sub-project C, final review, I7).
#
#    PROVED NECESSARY BY CONSTRUCTION. Before these two rows existed, both of
#    the following mutations left `make test` FULLY GREEN at 1109/1109:
#      * MUTANT B — delete the entire `#### arm64 boot header` docs section,
#        INCLUDING the whole "What this is verified against — and what it is
#        not" block. Three incidental mentions of the flag survive elsewhere in
#        the manual, which is all rows 1 and 2 need.
#      * MUTANT A — delete the dedicated `--image-header` line from `--help`.
#        The flag is ALSO named inside the `--emit=image` line's description,
#        so its TOKEN survives and rows 1-2 are again satisfied.
#    Row 3's numbers do not occur in this section either. So the single
#    highest-value artifact this sub-project produced — a written, measured
#    statement of what the header is NOT backed by — was protected by nothing.
#
#    BOTH MUTANTS WERE RE-RUN AGAINST THESE ROWS AND EACH REDS EXACTLY ONE:
#    mutant B (docs section removed) reds `imghdr_docs_limits_block_intact`
#    alone, and mutant A (src/main.kr's h_ih line removed, compiler rebuilt)
#    reds `imghdr_help_has_own_line` alone. In both runs rows 1 and 2 still
#    reported 26 flags and PASSED, which is the whole point: these two rows see
#    what token coverage cannot.
#
#    THESE TWO ROWS ARE STRUCTURAL, not behavioural, and they do not pretend
#    otherwise: they assert the section exists, that its limits subsection is
#    still nested inside it, and that the three bounds a reader most needs are
#    still stated. Scoped with the same awk as row 3 and for the same reason —
#    unscoped, "No real boot chain" is satisfied from anywhere in a 2400-line
#    file and the check is decorative. The scope differs from row 3's in one
#    way: `##### ` subheadings do NOT terminate it, because the block being
#    protected IS a `#####` subsection and row 3's awk would cut it off.
#
#    PHRASES, NOT FLAG TOKENS, because these limits are prose — which is
#    precisely why no token grep can protect them. The cost is real and
#    accepted: rewording one of these three sentences reds a row. That is the
#    intended trade. This text has now twice been "corrected" into a new
#    falsehood, so a deliberate reword SHOULD have to come here in the same
#    commit and say so.
IHDR_SEC=/tmp/krc_ihdr_sec_$$
awk '/^#### arm64 boot header/{s=1;print;next} s&&/^#/&&!/^##### /{exit} s{print}' "$HD_DOC" > "$IHDR_SEC"
TOTAL=$((TOTAL + 1))
ihdr_doc_miss=""
[ -s "$IHDR_SEC" ] || ihdr_doc_miss=" the-section-itself"
grep -qF -- '##### What this is verified against' "$IHDR_SEC" || ihdr_doc_miss="$ihdr_doc_miss the-limits-subsection"
grep -qF -- 'No real boot chain' "$IHDR_SEC" || ihdr_doc_miss="$ihdr_doc_miss no-real-boot-chain"
grep -qF -- "not the specification's" "$IHDR_SEC" || ihdr_doc_miss="$ihdr_doc_miss qemu-not-the-spec"
grep -qF -- 'does not reject a bad magic' "$IHDR_SEC" || ihdr_doc_miss="$ihdr_doc_miss bad-magic-not-refused"
if [ -z "$ihdr_doc_miss" ]; then
    PASS=$((PASS + 1)); echo "  imghdr_docs_limits_block_intact: PASS (section present, $(wc -l < "$IHDR_SEC" | tr -d ' ') lines, all 3 bounds stated)"
else
    echo "FAIL: imghdr_docs_limits_block_intact (docs/LANGUAGE.md's '#### arm64 boot header' section is missing:$ihdr_doc_miss -- this text is what the sub-project delivered; if it was reworded on purpose, update this row in the same commit, do not delete it)"
    FAIL=$((FAIL + 1))
fi

# 4b. ...and --help still carries a line ABOUT the flag, not merely a mention
#     of its name inside another flag's description. Anchored to the flag
#     column: `^  --image-header ` matches only the dedicated row, so mutant A
#     (delete that row, leave the `--emit=image` mention) reds here and nowhere
#     else in the suite.
TOTAL=$((TOTAL + 1))
ihdr_help_n=$(grep -c '^  --image-header ' "$HD_HELP")
if [ "$ihdr_help_n" = "1" ]; then
    PASS=$((PASS + 1)); echo "  imghdr_help_has_own_line: PASS (exactly 1 dedicated --help row)"
else
    echo "FAIL: imghdr_help_has_own_line (found $ihdr_help_n lines starting '  --image-header ' in --help, want exactly 1; the flag being NAMED in --emit=image's description is not a description of the flag)"
    FAIL=$((FAIL + 1))
fi

# 5. --emit=uefi IS STRUCTURALLY INVISIBLE TO ROWS 1-2, so it gets its own
#    pair (sub-project D, Task 1, Step 5).
#
#    hd_flags()'s regex is `--[A-Za-z0-9][A-Za-z0-9-]*` and `=` is in neither
#    class, so from `--emit=uefi` it extracts `--emit` -- a token that has been
#    in both texts since long before this mode existed. Rows 1 and 2 are
#    therefore satisfied by an --emit= mode that neither text mentions, and by
#    one the manual describes after the compiler dropped it. That is not a
#    defect in rows 1-2 (they are about FLAGS) -- it is why an --emit= VALUE
#    needs a check of its own, in both directions, the same way --image-header
#    needed rows 4/4b for its prose.
#
#    VERIFIED BY DELETION, one text at a time, against the built compiler:
#      * delete the `  --emit=uefi ...` line from src/main.kr's --help block
#        and rebuild -> `uefi_help_has_own_line` reds, ALONE.
#      * delete the `#### UEFI applications` section from docs/LANGUAGE.md ->
#        `uefi_docs_section_intact` reds, ALONE.
#    Rows 1-2 stayed green through both, reporting the same flag count.
TOTAL=$((TOTAL + 1))
uefi_help_n=$(grep -c '^  --emit=uefi ' "$HD_HELP")
if [ "$uefi_help_n" = "1" ]; then
    PASS=$((PASS + 1)); echo "  uefi_help_has_own_line: PASS (exactly 1 dedicated --help row)"
else
    echo "FAIL: uefi_help_has_own_line (found $uefi_help_n lines starting '  --emit=uefi ' in --help, want exactly 1; hd_flags cannot see an --emit= VALUE, so nothing else in this suite would notice its absence)"
    FAIL=$((FAIL + 1))
fi

#    The docs half. Scoped to the section with the same awk row 3 uses, for
#    the same reason: unscoped, every phrase below is satisfiable from
#    somewhere else in a 2400-line file and the check is decorative.
UEFI_SEC=/tmp/krc_uefi_sec_$$
awk '/^#### UEFI applications/{s=1;print;next} s&&/^#/&&!/^##### /{exit} s{print}' "$HD_DOC" > "$UEFI_SEC"
TOTAL=$((TOTAL + 1))
uefi_doc_miss=""
[ -s "$UEFI_SEC" ] || uefi_doc_miss=" the-section-itself"
# PROSE ONLY for the three tokens below. As shipped they were each satisfied
# FIRST by the section's own example command and sample report line -- which
# are fenced code, not documentation of the requirement -- so deleting every
# explanatory paragraph left them green. Stripping the fences makes each one
# assert that the requirement is actually WRITTEN DOWN somewhere.
UEFI_PROSE=/tmp/krc_uefi_prose_$$
awk '/^```/{f=!f;next} !f' "$UEFI_SEC" > "$UEFI_PROSE"
grep -qF -- '--target=none' "$UEFI_PROSE" || uefi_doc_miss="$uefi_doc_miss target-none-requirement"
grep -qF -- '--arch=' "$UEFI_PROSE" || uefi_doc_miss="$uefi_doc_miss explicit-arch-requirement"
grep -qF -- '4096' "$UEFI_PROSE" || uefi_doc_miss="$uefi_doc_miss page-congruence"
# Task 2 added the header. Subsystem 10 is the one field with no runner-up --
# 11 and 12 are valid EFI subsystems and BDS still refuses them -- so the
# manual has to name it, and the WRITE bit is the one that separates an arm64
# application that runs from one that aborts on its first store.
grep -qF -- 'Subsystem' "$UEFI_SEC" || uefi_doc_miss="$uefi_doc_miss subsystem-10"
grep -qF -- 'WRITE'     "$UEFI_SEC" || uefi_doc_miss="$uefi_doc_miss writable-text-section"
# The Status heading survives Task 2 with its meaning inverted -- it said what
# was NOT emitted yet, and now says what has booted. Either way this mode's
# section must carry an explicit statement of how far the evidence goes,
# because every other paragraph in it reads like a completed feature.
grep -qF -- 'Status' "$UEFI_SEC" || uefi_doc_miss="$uefi_doc_miss status-statement"
# ...AND THE QUALIFICATION ON IT, WHICH NOTHING GUARDED UNTIL NOW. The row
# above asserts that a Status statement EXISTS; it said nothing about what the
# statement claims. Measured by the whole-branch review: reverting "QEMU's
# OVMF ... emulated, not real hardware" back to "run under real firmware" --
# the EXACT drift Task 2's review already had to catch by hand once in this
# sub-project -- left this row GREEN. The honesty bound is the sentence the
# whole sub-project answers to, so it gets a check and not a convention.
grep -qF -- 'emulated'    "$UEFI_PROSE" || uefi_doc_miss="$uefi_doc_miss emulation-qualifier"
grep -qF -- 'QEMU'        "$UEFI_PROSE" || uefi_doc_miss="$uefi_doc_miss names-the-emulator"
grep -qF -- 'Secure Boot' "$UEFI_PROSE" || uefi_doc_miss="$uefi_doc_miss secure-boot-limit"
# The negative half. "real firmware" is allowed ONLY inside a negation, so
# "does not claim real firmware" passes and "runs under real firmware" reds.
# Written as "some matching line carries no negation" rather than a blanket
# ban, because the honest sentence and the dishonest one share the phrase.
# `grep -qv` ON THE TAIL OF A PIPE IS NOT SAFE ON THIS HOST -- see the long
# note on rvec_unqualified below: ugrep 7.5.0 measured a FALSE negative for
# exactly this shape. It is not live here today (the UEFI prose has zero
# `real firmware` matches, and `-qv` is correct on a single line), but it
# would break SILENTLY the moment an honest sentence is added -- and this is
# the guard for the claim sub-project D had to correct by hand twice. Use the
# same capture-and-test form, which is POSIX `-E`/`-v` only.
uefi_unqualified=$(grep -- 'real firmware' "$UEFI_PROSE" | grep -vE 'not |no |never ')
if [ -n "$uefi_unqualified" ]; then
    uefi_doc_miss="$uefi_doc_miss unqualified-real-firmware-claim"
fi
if [ -z "$uefi_doc_miss" ]; then
    PASS=$((PASS + 1)); echo "  uefi_docs_section_intact: PASS (section present, $(wc -l < "$UEFI_SEC" | tr -d ' ') lines)"
else
    echo "FAIL: uefi_docs_section_intact (docs/LANGUAGE.md's '#### UEFI applications' section is missing:$uefi_doc_miss)"
    FAIL=$((FAIL + 1))
fi

# 6. --reset-vector's own honesty section (review r1, Important 2). Rows 1-2
#    above are STRUCTURALLY BLIND to this: `--reset-vector` survives in the
#    `--emit=` one-liner (LANGUAGE.md's format list) regardless of whether
#    the dedicated section below it exists, so hd_flags() alone cannot tell
#    the two apart -- proven by MUTANT B, run against this exact tree: delete
#    the entire `#### The reset-vector form` section (80+ lines, including
#    the Step 7 "never real firmware" paragraph) and BOTH
#    help_flags_are_documented and docs_flags_are_in_help stayed green,
#    because the one-liner alone satisfies them. (MUTANT A -- drop the
#    dedicated --help line -- IS already caught, by docs_flags_are_in_help;
#    only the docs half needed a row of its own, same asymmetry D found for
#    --emit=uefi.)
#
#    Grep for the HONESTY WORDING ITSELF, not for tokens a sample invocation
#    already satisfies (D's own review found its first version of this row
#    weak for exactly that reason: `--target=none` etc. are satisfied by the
#    section's fenced example command before a word of prose runs). Scoped
#    to prose only, code fences stripped, same as the UEFI row above.
RVEC_SEC=/tmp/krc_rvec_sec_$$
# `##### ` DOES NOT TERMINATE THIS SCOPE, same exemption row 4 already needed
# and for the same reason: E Task 4 nests a `##### What this is verified
# against` limits block inside this section, and row 3's plain `/^#/{exit}`
# would cut the section off AT that heading, putting the whole block out of
# scope. MEASURED rather than reasoned, both ways, against this exact tree:
# with the plain awk the row FAILS with "the-limits-subsection ram-not-map-bound
# size-rule-labelled-inference ci-status-stated", and with this awk it passes at
# 191 lines. Note what that measurement does NOT say: the older greps
# ('one machine', 'real hardware', 'real firmware') keep passing either way,
# because they are satisfied by the "What a green result claims" paragraph that
# sits ABOVE the new heading. So this is a scope fix the new greps require, not
# a rescue of the old ones -- and the plain awk fails CLOSED, it does not go
# quietly green.
awk '/^#### The reset-vector form/{s=1;print;next} s&&/^#/&&!/^##### /{exit} s{print}' "$HD_DOC" > "$RVEC_SEC"
TOTAL=$((TOTAL + 1))
rvec_doc_miss=""
[ -s "$RVEC_SEC" ] || rvec_doc_miss=" the-section-itself"
RVEC_PROSE=/tmp/krc_rvec_prose_$$
awk '/^```/{f=!f;next} !f' "$RVEC_SEC" > "$RVEC_PROSE"
grep -qF -- 'Status'         "$RVEC_SEC"   || rvec_doc_miss="$rvec_doc_miss status-statement"
# WAS `grep -qF 'flag surface'`, AND THAT MARKER INVERTED UNDER THIS ROW
# (whole-branch review, Minor 3). It was written when the section said "the
# flag surface only"; Task 2's r1 rewrote that sentence to "no longer the
# flag surface only", so the row went on passing while guarding a phrase that
# now asserts the opposite of what the row is named for. Not vacuous -- it
# still failed if the words vanished -- but it guarded nothing it claimed to.
# Replaced with the disclosure that is actually load-bearing NOW: the section
# has to keep saying that the unrefusable stack hazards are a silent reboot
# loop with no diagnostic. That sentence is the one a tidy-up would delete
# and the one whose absence would make the section dishonest.
grep -qF -- 'silent reboot loop' "$RVEC_PROSE" || rvec_doc_miss="$rvec_doc_miss unchecked-hazard-disclosure"
grep -qF -- 'QEMU'           "$RVEC_PROSE" || rvec_doc_miss="$rvec_doc_miss names-the-emulator"
grep -qF -- '-bios'          "$RVEC_PROSE" || rvec_doc_miss="$rvec_doc_miss names-the-bios-flag"
grep -qF -- 'one machine'    "$RVEC_PROSE" || rvec_doc_miss="$rvec_doc_miss one-machine-scope"
grep -qF -- 'real hardware'  "$RVEC_PROSE" || rvec_doc_miss="$rvec_doc_miss real-hardware-mentioned"
grep -qF -- 'real firmware'  "$RVEC_PROSE" || rvec_doc_miss="$rvec_doc_miss real-firmware-mentioned"
# E TASK 4's LIMITS BLOCK, guarded the way sub-project C's is (row 4). Same
# argument, same cost: these are PHRASES, not flag tokens, so rewording one
# reds a row and a deliberate reword has to come here in the same commit.
# Four claims, each of which was wrong or absent somewhere in this sub-project
# before it was measured: that the stack's real bound is RAM and not the map,
# that busting it is silent, that the 64 KiB rule is an INFERENCE from measured
# points rather than a quoted requirement, and that L9 is not in CI. The last
# is the one most likely to rot: it becomes false on the first push, and it
# must be edited then rather than left standing.
grep -qF -- '##### What this is verified against' "$RVEC_SEC" || rvec_doc_miss="$rvec_doc_miss the-limits-subsection"
grep -qF -- 'installed guest RAM' "$RVEC_SEC" || rvec_doc_miss="$rvec_doc_miss ram-not-map-bound"
# NOT `no diagnostic` -- that phrase ALSO occurs in the RAM-table paragraph
# ABOVE this block's heading, so deleting the whole limits subsection left this
# name GREEN while the other four reddened. Measured. Grep a phrase that exists
# only inside the block.
grep -qF -- 'no message, no exit code' "$RVEC_SEC" || rvec_doc_miss="$rvec_doc_miss silent-failure-stated"
grep -qF -- 'inference'           "$RVEC_SEC" || rvec_doc_miss="$rvec_doc_miss size-rule-labelled-inference"
# WAS `never run in CI`, which stopped being true at 4390d48 -- run 31024409854
# ran all nine L9 legs on the Linux x86_64 job. The row's job is to keep the CI
# STATUS stated, not to pin one particular status, so it now greps the phrase
# that survives either way. Rewriting the bullet without this phrase reds it.
grep -qF -- 'run in CI'           "$RVEC_SEC" || rvec_doc_miss="$rvec_doc_miss ci-status-stated"
# THE NEGATIVE HALF, both ways. "real hardware"/"real firmware" is allowed
# ONLY inside a negation on the SAME line -- "will not claim real hardware,
# real firmware" passes, a bare "runs under real firmware" (added anywhere in
# the section, even alongside the honest sentence -- MUTANT B's second form)
# reds. "some matching line carries no negation nearby", not a blanket ban,
# because the honest sentence and an unqualified one share the same words.
#
# Captured to a variable and tested with `-n`, NOT `grep -q` on the tail of
# the pipe: this host's `grep` is ugrep 7.5.0, and `grep -E ... | grep -qvE
# 'not |no |never '` on this exact two-line input (one negated, one not)
# measured a FALSE "no unqualified line" here -- `grep -qv` exited 1 even
# though the un-quieted `grep -v` on the identical input correctly printed
# the offending line and exited 0. Whatever the cause, `-q`'s early-exit
# path and `-v`'s must-see-every-line-to-decide semantics don't agree on
# this grep. Capturing full output and checking non-emptiness sidesteps it
# and was verified to catch MUTANT B where the `-qv` form silently didn't.
rvec_unqualified=$(grep -E 'real hardware|real firmware' "$RVEC_PROSE" | grep -vE 'not |no |never ')
if [ -n "$rvec_unqualified" ]; then
    rvec_doc_miss="$rvec_doc_miss unqualified-real-hardware-or-firmware-claim"
fi
if [ -z "$rvec_doc_miss" ]; then
    PASS=$((PASS + 1)); echo "  resetvec_docs_honesty_block_intact: PASS (section present, $(wc -l < "$RVEC_SEC" | tr -d ' ') lines)"
else
    echo "FAIL: resetvec_docs_honesty_block_intact (docs/LANGUAGE.md's '#### The reset-vector form' section is missing:$rvec_doc_miss)"
    FAIL=$((FAIL + 1))
fi
rm -f "$RVEC_SEC" "$RVEC_PROSE"

rm -f "$HD_HELP" "$HD_SEC" "$HD_LINE" "$HD_SRC" "$IHDR_SEC" "$UEFI_SEC" "$UEFI_PROSE"

# --- --emit=image EMISSION + the `image:` report line (sub-project B1, T5) ---
#
# WHICH ROWS WERE RED BEFORE THE IMPLEMENTATION, AND WHY THAT MATTERS.
# A fully-valid `--emit=image` invocation ALREADY exited 0 at BASE and already
# wrote a headerless blob -- WITH its static data and WITH its fixups resolved
# in image coordinates. Two circulated descriptions of that blob are false and
# were checked against the BASE binary: it does NOT fall through to the ELF
# path (no ELF magic, 176 B vs the ELF's 296 B), and it is NOT "bare code with
# no statics and no fixups" (the magic initialiser was present and both arm64
# ADRP pairs already resolved to it). So a pin spelled "the output is not an
# ELF" passes at BASE and proves nothing.
# Red at BASE (7): image_report_format_*, image_entry_matches_elf_*,
# image_statics_present_* (on filesz -- their count/offset half was already
# green) and image_no_truncation. Every one of them needs the report line.
# Green at BASE (6): the rest. Those are regression pins, not evidence, so each
# was individually OBSERVED FAILING against a deliberately broken compiler
# before being trusted -- six injections, listed in this task's report:
# fixups resolved in ELF coordinates, BSS truncation, static data not emitted,
# load_addr embedded, entry reported as 0, sizes taken pre-truncation.
echo ""
echo "--- --emit=image emission + report ---"

# Statics + recursion + a call: exercises the static-fixup class and keeps
# `main` OFF file offset 0 (a straight-line callee gets inlined and main lands
# at 0, which would make the entry pin unfalsifiable). The initialiser is a
# magic so the data blob can be LOCATED in the artifact by value instead of
# assumed present.
IMG5_SRC="$DIR/../test_tmp_img5_$$.kr"
IMG5_MAGIC=4b52494d41474521
printf 'static uint64 g = 0x4B52494D41474521\nfn f(uint64 x) -> uint64 { if x < 2 { return x + g }\n return f(x - 1) + f(x - 2) }\nfn main() -> uint64 { g = 2\n return f(6) }\n' > "$IMG5_SRC"
# Elf64_Ehdr(64) + one Elf64_Phdr(56). Not spelled as a magic number anywhere a
# comparison depends on it alone: image_x86_tail_identity below compares whole
# files, so a wrong value here fails on length, not silently.
IMG5_EHDR=120

# Byte offset of the first 8-byte-aligned qword equal to $2, or -1.
img_qword_off() {
    local idx
    idx=$(od -An -tx8 -v "$1" 2>/dev/null | tr -s ' ' '\n' | grep -v '^$' | grep -n "^$2\$" | head -1 | cut -d: -f1)
    if [ -n "$idx" ]; then echo $(( (idx - 1) * 8 )); else echo -1; fi
}
img_qword_count() {
    od -An -tx8 -v "$1" 2>/dev/null | tr -s ' ' '\n' | grep -c "^$2\$"
}
# e_entry of an Elf64 file, as an offset from the --target=none load base.
img_elf_entry_off() {
    local lo hi
    lo=$(od -An -tx4 -j24 -N4 -v "$1" | tr -d ' \n')
    hi=$(od -An -tx4 -j28 -N4 -v "$1" | tr -d ' \n')
    echo $(( (((16#$hi) << 32) | (16#$lo)) - 0x400000 ))
}
# Decode every "ADRP x16 + LDR/STR/ADD via x16" pair in an arm64 FLAT image and
# print the file offset each pair resolves to, one per line. The arithmetic is
# done in IMAGE coordinates (file offset 0 == the load address, which is
# 4096-aligned by validation), which is precisely the coordinate system a
# header-stripped ELF gets wrong: stripping 0x78 shifts every offset by a
# non-page amount, so the baked page_off is 0x78 too large. That is the defect
# that boots to silence, and image_a64_strip_is_rejected below is its live
# negative control.
img_a64_adrp_targets() {
    local -a w=()
    local x
    while read -r x; do w+=( $((16#$x)) ); done < <(od -An -tx4 -v "$1" | tr -s ' ' '\n' | grep -v '^$')
    local i n=${#w[@]} v v2 immlo immhi d po
    for (( i = 0; i < n - 1; i++ )); do
        v=${w[i]}
        (( (v & 0x9F00001F) == 0x90000010 )) || continue   # ADRP x16
        immlo=$(( (v >> 29) & 3 )); immhi=$(( (v >> 5) & 0x7FFFF ))
        d=$(( (immhi << 2) | immlo ))
        (( d >= 0x100000 )) && d=$(( d - 0x200000 ))       # sign-extend imm21
        v2=${w[i+1]}
        if (( ((v2 >> 24) & 0xFF) == 0x91 )); then
            po=$(( (v2 >> 10) & 0xFFF ))                   # ADD: unscaled
        else
            po=$(( ((v2 >> 10) & 0xFFF) << 3 ))            # LDR/STR X: scaled by 8
        fi
        echo $(( (((i * 4) >> 12) + d) * 4096 + po ))
    done
}

# Reference ELFs for the same program, built once and reused by several rows.
$KRC $KRC_FLAGS "$IMG5_SRC" -o /tmp/krc_i5e_x_$$ --arch=x86_64 --target=none >/dev/null 2>&1
$KRC $KRC_FLAGS "$IMG5_SRC" -o /tmp/krc_i5e_a_$$ --arch=arm64  --target=none >/dev/null 2>&1

# 1. The artifact is raw (no ELF magic) and the report line is EXACTLY the
#    contract Task 6's gate parses: `image: arch=<name> entry= filesz= memsz=
#    load=`, all decimal. arch= is in the line because --target=none --emit=
#    without --arch silently defaulted to x86_64 before Task 4 refused it, and
#    a report that omitted the arch could not have shown that.
for IA in x86_64 arm64; do
    TOTAL=$((TOTAL + 1))
    ILOAD=0x400000; [ "$IA" = arm64 ] && ILOAD=0x40400000
    rm -f /tmp/krc_i5_$$
    i1out=$($KRC $KRC_FLAGS "$IMG5_SRC" -o /tmp/krc_i5_$$ --arch=$IA --target=none --emit=image --load-addr=$ILOAD 2>&1); i1st=$?
    i1magic=$(head -c4 /tmp/krc_i5_$$ 2>/dev/null | od -An -tx1 | tr -d ' \n')
    if [ $i1st -eq 0 ] && [ -f /tmp/krc_i5_$$ ] && [ "$i1magic" != "7f454c46" ] \
       && echo "$i1out" | grep -qE "^image: arch=$IA entry=[0-9]+ filesz=[0-9]+ memsz=[0-9]+ load=$(( ILOAD ))$"; then
        PASS=$((PASS + 1)); echo "  image_report_format_$IA: PASS"
    else
        echo "FAIL: image_report_format_$IA (exit=$i1st, magic=$i1magic, line=$(echo "$i1out" | grep '^image:' || echo NONE))"
        FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_i5_$$
done

# 2. The reported entry is the file offset of `main` IN THE IMAGE. Cross-checked
#    against the same program's ELF e_entry, which is the only other place that
#    offset is recorded -- a flat image has no e_entry, which is why the report
#    is a required output rather than a convenience. Also asserts entry != 0:
#    offset 0 is NOT main on x86_64/arm64 (only riscv32 hoists the entry), and
#    a pin that tolerated 0 would accept `entry=0` hardcoded.
for IA in x86_64 arm64; do
    TOTAL=$((TOTAL + 1))
    ILOAD=0x400000; IREF=/tmp/krc_i5e_x_$$; [ "$IA" = arm64 ] && { ILOAD=0x40400000; IREF=/tmp/krc_i5e_a_$$; }
    i2out=$($KRC $KRC_FLAGS "$IMG5_SRC" -o /tmp/krc_i5_$$ --arch=$IA --target=none --emit=image --load-addr=$ILOAD 2>&1)
    i2got=$(echo "$i2out" | sed -n 's/^image: .* entry=\([0-9]*\) .*/\1/p')
    i2want=$(( $(img_elf_entry_off "$IREF") - IMG5_EHDR ))
    if [ -n "$i2got" ] && [ "$i2got" = "$i2want" ] && [ "$i2want" -gt 0 ]; then
        PASS=$((PASS + 1)); echo "  image_entry_matches_elf_$IA: PASS (entry=$i2got)"
    else
        echo "FAIL: image_entry_matches_elf_$IA (reported '$i2got', ELF says $i2want)"; FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_i5_$$
done

# 3. The static data blob is IN the image, exactly once, and inside the
#    reported filesz. Locating it by its initialiser value is what makes the
#    fixup row below able to name the offset the ADRP pairs must reach.
for IA in x86_64 arm64; do
    TOTAL=$((TOTAL + 1))
    ILOAD=0x400000; [ "$IA" = arm64 ] && ILOAD=0x40400000
    i3out=$($KRC $KRC_FLAGS "$IMG5_SRC" -o /tmp/krc_i5_$$ --arch=$IA --target=none --emit=image --load-addr=$ILOAD 2>&1)
    i3fs=$(echo "$i3out" | sed -n 's/^image: .*filesz=\([0-9]*\).*/\1/p')
    i3off=$(img_qword_off /tmp/krc_i5_$$ $IMG5_MAGIC)
    i3cnt=$(img_qword_count /tmp/krc_i5_$$ $IMG5_MAGIC)
    if [ "$i3cnt" = "1" ] && [ "$i3off" -ge 0 ] && [ -n "$i3fs" ] \
       && [ "$i3fs" = "$(stat -c%s /tmp/krc_i5_$$)" ] && [ $(( i3off + 8 )) -le "$i3fs" ]; then
        PASS=$((PASS + 1)); echo "  image_statics_present_$IA: PASS (initialiser at +$i3off of $i3fs)"
    else
        echo "FAIL: image_statics_present_$IA (count=$i3cnt off=$i3off filesz=$i3fs size=$(stat -c%s /tmp/krc_i5_$$ 2>/dev/null))"
        FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_i5_$$
done

# 4. arm64 static fixups RESOLVE, in the image's own coordinates: every ADRP
#    x16 pair must land on the initialiser's actual offset. This is the row
#    that distinguishes a real image from a header-stripped ELF; x86_64 needs
#    no equivalent because it is fully RIP-relative, which row 5 pins by whole-
#    file identity with the ELF tail.
TOTAL=$((TOTAL + 1))
$KRC $KRC_FLAGS "$IMG5_SRC" -o /tmp/krc_i5_$$ --arch=arm64 --target=none --emit=image --load-addr=0x40400000 >/dev/null 2>&1
i4want=$(img_qword_off /tmp/krc_i5_$$ $IMG5_MAGIC)
i4t=$(img_a64_adrp_targets /tmp/krc_i5_$$)
i4n=$(echo "$i4t" | grep -c '^[0-9]')
i4bad=$(echo "$i4t" | grep -vc "^$i4want\$")
if [ "$i4n" = "2" ] && [ "$i4bad" = "0" ] && [ "$i4want" -ge 0 ]; then
    PASS=$((PASS + 1)); echo "  image_a64_fixups_resolve: PASS (2/2 ADRP pairs -> +$i4want)"
else
    echo "FAIL: image_a64_fixups_resolve ($i4n pairs, $i4bad missing +$i4want; got: $(echo $i4t))"; FAIL=$((FAIL + 1))
fi
# 4b. LIVE NEGATIVE CONTROL for row 4: run the identical decoder over the ELF
#     with its 120-byte header chopped off -- the artifact a post-hoc
#     truncation would produce. It must NOT resolve to the initialiser. Without
#     this row, row 4 is a check that has only ever been seen passing.
TOTAL=$((TOTAL + 1))
tail -c +$(( IMG5_EHDR + 1 )) /tmp/krc_i5e_a_$$ > /tmp/krc_i5strip_$$
i4swant=$(img_qword_off /tmp/krc_i5strip_$$ $IMG5_MAGIC)
i4st=$(img_a64_adrp_targets /tmp/krc_i5strip_$$)
i4sn=$(echo "$i4st" | grep -c '^[0-9]')
i4sbad=$(echo "$i4st" | grep -vc "^$i4swant\$")
if [ "$i4sn" = "2" ] && [ "$i4sbad" = "2" ]; then
    PASS=$((PASS + 1)); echo "  image_a64_strip_is_rejected: PASS (2/2 stripped ADRP pairs miss +$i4swant: $(echo $i4st))"
else
    echo "FAIL: image_a64_strip_is_rejected (decoder cannot tell a strip from an image: $i4sn pairs, $i4sbad wrong)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_i5_$$ /tmp/krc_i5strip_$$

# 5. x86_64 tail identity: the image must equal the ELF build's bytes past the
#    120-byte header. x86_64 codegen is RIP-relative throughout, so raw
#    emission may not change one byte of code or data -- the cheapest oracle
#    that emit_mode 8 changed LAYOUT, not CODE.
TOTAL=$((TOTAL + 1))
$KRC $KRC_FLAGS "$IMG5_SRC" -o /tmp/krc_i5i_$$ --arch=x86_64 --target=none --emit=image --load-addr=0x400000 >/dev/null 2>&1
i5why=$(cmp <(tail -c +$(( IMG5_EHDR + 1 )) /tmp/krc_i5e_x_$$) /tmp/krc_i5i_$$ 2>&1)
if [ -f /tmp/krc_i5e_x_$$ ] && [ -f /tmp/krc_i5i_$$ ] && [ -z "$i5why" ]; then
    PASS=$((PASS + 1)); echo "  image_x86_tail_identity: PASS"
else
    # Name the cause. "image != elf[120:]" on its own does not say whether the
    # code changed or the file merely got longer, and those want opposite fixes.
    echo "FAIL: image_x86_tail_identity (elf=$(stat -c%s /tmp/krc_i5e_x_$$ 2>/dev/null) img=$(stat -c%s /tmp/krc_i5i_$$ 2>/dev/null); ${i5why:-both files missing})"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_i5i_$$

# 6. arm64 must NOT equal the ELF tail, at the same length: same code, same
#    size, different ADRP immediates because the page arithmetic was redone at
#    header_size = 0. An arm64 image byte-equal to the stripped ELF IS the
#    silent-boot defect, from the other side of the decoder in row 4b.
TOTAL=$((TOTAL + 1))
$KRC $KRC_FLAGS "$IMG5_SRC" -o /tmp/krc_i5i_$$ --arch=arm64 --target=none --emit=image --load-addr=0x40400000 >/dev/null 2>&1
i6want=$(( $(stat -c%s /tmp/krc_i5e_a_$$ 2>/dev/null || echo 0) - IMG5_EHDR ))
i6got=$(stat -c%s /tmp/krc_i5i_$$ 2>/dev/null || echo 0)
i6same=no; cmp -s <(tail -c +$(( IMG5_EHDR + 1 )) /tmp/krc_i5e_a_$$) /tmp/krc_i5i_$$ && i6same=yes
if [ -f /tmp/krc_i5e_a_$$ ] && [ -f /tmp/krc_i5i_$$ ] && [ "$i6want" = "$i6got" ] && [ "$i6same" = no ]; then
    PASS=$((PASS + 1)); echo "  image_a64_not_a_strip: PASS"
elif [ "$i6want" != "$i6got" ]; then
    # Separated from the byte-equality arm on purpose: a length change and a
    # byte-for-byte match are opposite defects (something got appended vs the
    # page arithmetic was never redone) and one message for both misdirects.
    echo "FAIL: image_a64_not_a_strip (length: elf[$IMG5_EHDR:]=$i6want but image=$i6got — the image gained or lost bytes)"
    FAIL=$((FAIL + 1))
else
    echo "FAIL: image_a64_not_a_strip (image is byte-equal to the header-stripped ELF — the ADRP page arithmetic was not redone at header_size=0, which boots to silence)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_i5i_$$

# 7. --load-addr is validated and reported, never embedded: two different
#    aligned addresses, one byte-identical artifact, per arch. Asserting the
#    opposite ("different addr => different bytes") would be satisfiable only
#    by a gratuitous absolute reference.
for IA in x86_64 arm64; do
    TOTAL=$((TOTAL + 1))
    L1=0x400000; L2=0x800000; [ "$IA" = arm64 ] && { L1=0x40400000; L2=0x40800000; }
    $KRC $KRC_FLAGS "$IMG5_SRC" -o /tmp/krc_i5a_$$ --arch=$IA --target=none --emit=image --load-addr=$L1 >/dev/null 2>&1
    $KRC $KRC_FLAGS "$IMG5_SRC" -o /tmp/krc_i5b_$$ --arch=$IA --target=none --emit=image --load-addr=$L2 >/dev/null 2>&1
    if [ -f /tmp/krc_i5a_$$ ] && cmp -s /tmp/krc_i5a_$$ /tmp/krc_i5b_$$; then
        PASS=$((PASS + 1)); echo "  image_load_addr_not_embedded_$IA: PASS"
    else
        echo "FAIL: image_load_addr_not_embedded_$IA"; FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_i5a_$$ /tmp/krc_i5b_$$
done

# 8. No truncation: a 64 KiB static tail stays in the file, memsz == filesz,
#    and both exceed 64 KiB. The ELF path truncates this same program to 180
#    bytes (measured) and lets p_memsz carry the rest; nothing on bare metal
#    zeroes a BSS tail in B1, and QEMU zero-fills RAM, so a truncated image
#    would pass the boot gate VACUOUSLY and read garbage statics on silicon.
TOTAL=$((TOTAL + 1))
IMG6_SRC="$DIR/../test_tmp_img6_$$.kr"
printf 'static uint8[65536] blob\nfn main() -> uint64 { unsafe { *((blob + 65535) as uint8) = 7 }\n return 0 }\n' > "$IMG6_SRC"
i8out=$($KRC $KRC_FLAGS "$IMG6_SRC" -o /tmp/krc_i6_$$ --arch=arm64 --target=none --emit=image --load-addr=0x40400000 2>&1)
i8fs=$(echo "$i8out" | sed -n 's/^image: .*filesz=\([0-9]*\).*/\1/p')
i8ms=$(echo "$i8out" | sed -n 's/^image: .*memsz=\([0-9]*\).*/\1/p')
if [ -f /tmp/krc_i6_$$ ] && [ -n "$i8fs" ] && [ "$(stat -c%s /tmp/krc_i6_$$)" = "$i8fs" ] \
   && [ "$i8fs" = "$i8ms" ] && [ "$i8fs" -gt 65536 ]; then
    PASS=$((PASS + 1)); echo "  image_no_truncation: PASS (filesz=memsz=$i8fs on disk)"
else
    echo "FAIL: image_no_truncation (filesz=$i8fs memsz=$i8ms size=$(stat -c%s /tmp/krc_i6_$$ 2>/dev/null))"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_i6_$$ "$IMG6_SRC" "$IMG5_SRC" /tmp/krc_i5e_x_$$ /tmp/krc_i5e_a_$$

# --- --image-header: the 64 emitted bytes (C, Task 2) ------------------------
#
# WHY THIS IS HERE AND NOT WITH THE OTHER imghdr_* ROWS. The flag-surface
# section above (`--image-header flag surface`) holds the refusals and
# imghdr_pure_prefix; these rows are its other half and would read better next
# to it. They are here because imghdr_page_refs_rebaked calls
# `img_a64_adrp_targets`, defined a few dozen lines above this line, and bash
# resolves a function at CALL time -- placed in the section above, that row
# would not fail, it would print "command not found" to stderr, compare two
# empty strings and PASS. The alternative was to hoist the decoder away from
# the coordinate-system comment that explains it. Splitting the rows was the
# cheaper of the two.
#
# EVERY FIELD IS READ BACK OFF THE ARTIFACT, at its spec offset, never from a
# variable the emitter also wrote. The format is the arm64 Linux `Image`
# header (spec D5 / Documentation/arch/arm64/booting.rst):
#
#   0  code0       b <stub>          16  image_size  u64, file size incl. hdr
#   4  code1       0                 24  flags       u64, 0xA
#   8  text_offset u64, 0            32  res2..res4  u64 x3, 0
#                                    56  magic       u32, 0x644d5241 ("ARM\x64")
#                                    60  res5        u32, 0
#
# TWO FIELDS ARE PATCHED BACK, not written at emit time, and both are patched
# for the same reason: the value does not exist yet when the bytes are laid
# down. `code0` needs the stub's offset (no function has been emitted), and
# `image_size` needs the final file size. BOTH PLACEHOLDERS ARE ZERO
# (src/main.kr: emit_a64(0) and emit_u64_le(0)), and the two miss cases are not
# alike:
#   * a missed `code0` patch leaves 0x00000000, which is `udf #0` -- an
#     undefined instruction on the image's FIRST word. That is loud at runtime,
#     and it is loud on purpose: src/main.kr spends eight lines rejecting the
#     tempting 0x14000000 (`b .`) placeholder precisely because THAT one would
#     hang quietly. Do not "fix" the placeholder to a well-formed branch.
#   * a missed `image_size` patch leaves 0, which really is silent -- a loader
#     reads it as "reserve nothing" and carries on.
# Rows 6 and 7 make both statically detectable, so neither has to reach a boot
# to be caught.
IHDR_SRC="$DIR/../test_tmp_ihdr_$$.kr"
# A program WITH page-relative references (a static the code reads through an
# ADRP pair), unlike $STK_SRC above. Row 9 needs them: they are the only
# observable that the VA map was recomputed around the header rather than the
# header merely being glued on.
printf 'static uint64 s = 0x1234\nfn main() -> uint64 { return s + 1 }\n' > "$IHDR_SRC"
IHDR_IMG=/tmp/krc_ihdr_img_$$
IHDR_NOF=/tmp/krc_ihdr_nof_$$
rm -f "$IHDR_IMG" "$IHDR_NOF"
$KRC $KRC_FLAGS "$IHDR_SRC" -o "$IHDR_IMG" --arch=arm64 --target=none --emit=image \
     --load-addr=0x40400000 --stack-top=0x40800000 --image-header >/dev/null 2>&1
$KRC $KRC_FLAGS "$IHDR_SRC" -o "$IHDR_NOF" --arch=arm64 --target=none --emit=image \
     --load-addr=0x40400000 --stack-top=0x40800000 >/dev/null 2>&1

# Little-endian u32/u64 at file offset $2 of $1, in decimal. `od -j` skips, and
# the value is assembled in shell arithmetic rather than by trusting od's own
# multi-byte types, which are host-endian.
ihdr_u32() {
    local b; b=$(od -An -tx1 -j"$2" -N4 -v "$1" 2>/dev/null | tr -d ' \n')
    [ ${#b} = 8 ] || { echo SHORT; return 1; }
    echo $(( 16#${b:6:2}${b:4:2}${b:2:2}${b:0:2} ))
}
ihdr_u64() {
    local b; b=$(od -An -tx1 -j"$2" -N8 -v "$1" 2>/dev/null | tr -d ' \n')
    [ ${#b} = 16 ] || { echo SHORT; return 1; }
    echo $(( 16#${b:14:2}${b:12:2}${b:10:2}${b:8:2}${b:6:2}${b:4:2}${b:2:2}${b:0:2} ))
}

# 5. magic and flags -- the two fields a loader keys on. magic is what makes
#    the artifact recognisable AT ALL (row 10's file(1) oracle reads exactly
#    these four bytes); flags 0xA is bit 1 (4 KB pages) | bit 3 (load anywhere)
#    with bit 0 clear (little-endian).
TOTAL=$((TOTAL + 1))
i9magic=$(ihdr_u32 "$IHDR_IMG" 56); i9flags=$(ihdr_u64 "$IHDR_IMG" 24)
if [ "$i9magic" = "$(( 0x644d5241 ))" ] && [ "$i9flags" = "10" ]; then
    PASS=$((PASS + 1)); echo "  imghdr_magic_and_flags: PASS (magic=0x644d5241 @56, flags=0xA @24)"
else
    echo "FAIL: imghdr_magic_and_flags (magic=$i9magic want $(( 0x644d5241 )); flags=$i9flags want 10)"; FAIL=$((FAIL + 1))
fi

# 6. code0 is a REAL branch to the stub. The word is decoded rather than
#    pattern-matched, and the two guards catch different faults:
#    * op == 5 (top 6 bits 0b000101, B) with the sign-extended imm26 * 4
#      landing exactly on the reported entry -- which, with a stub, IS the stub
#      offset. THE SHIPPED PLACEHOLDER IS 0x00000000, `udf #0`, whose op is 0,
#      so a dropped patch-back reds here. (It is also loud at runtime: an
#      undefined instruction on the image's first word, not a hang.)
#    * code0 != 0x14000000. That word is `b .` and it is NOT the placeholder --
#      src/main.kr deliberately REJECTED it as one, because it would hang
#      silently instead of faulting AND would put a SECOND 0x14000000 in the
#      image, breaking the boot gate's `loop_offset_a64` uniqueness scan (five
#      checks read a PC through it). This clause is the standing guard against
#      that decision being quietly revisited. Note it is REDUNDANT today and
#      kept deliberately: `b .` satisfies op == 5, and is already caught by the
#      offset clause, since its target is +0 and --image-header always places
#      the stub past the 64-byte header, so the reported entry is never 0. The
#      named clause is what makes the rejection legible at the point of test.
TOTAL=$((TOTAL + 1))
i9rep=$($KRC $KRC_FLAGS "$IHDR_SRC" -o "$IHDR_IMG" --arch=arm64 --target=none --emit=image \
        --load-addr=0x40400000 --stack-top=0x40800000 --image-header 2>&1)
i9entry=$(echo "$i9rep" | sed -n 's/^image: .* entry=\([0-9][0-9]*\) .*$/\1/p')
i9c0=$(ihdr_u32 "$IHDR_IMG" 0)
i9op=$(( (i9c0 >> 26) & 0x3F ))
i9imm=$(( i9c0 & 0x3FFFFFF ))
[ "$i9imm" -ge $(( 0x2000000 )) ] && i9imm=$(( i9imm - 0x4000000 ))
i9tgt=$(( i9imm * 4 ))
if [ "$i9op" = "5" ] && [ "$i9c0" != "$(( 0x14000000 ))" ] && [ -n "$i9entry" ] && [ "$i9tgt" = "$i9entry" ]; then
    PASS=$((PASS + 1)); echo "  imghdr_code0_branches_to_stub: PASS (code0=$(printf 0x%08x "$i9c0") = b +$i9tgt = reported entry $i9entry)"
else
    echo "FAIL: imghdr_code0_branches_to_stub (code0=$(printf 0x%08x "$i9c0" 2>/dev/null) op=$i9op target=+$i9tgt reported entry=${i9entry:-UNPARSED}; 0x00000000 (udf) means the code0 patch-back never ran, 0x14000000 means the rejected 'b .' placeholder was reinstated)"; FAIL=$((FAIL + 1))
fi

# 6b. AND THE HALT IS STILL UNIQUE. Row 6 pins code0 != 0x14000000 by decoding
#     one word; this pins the CONSEQUENCE the boot gate depends on, on the
#     whole file. `loop_offset_a64` locates the stub's `b .` by being the only
#     0x14000000 word in the image and five gate checks read a PC through it,
#     so a duplicate would not fail here-and-now -- it would silently stop
#     those five from discriminating. Asserted on the HEADERED artifact
#     because that is the one that gained a candidate word.
TOTAL=$((TOTAL + 1))
i9halt=$(od -An -tx4 -v "$IHDR_IMG" | tr -s ' ' '\n' | grep -c '^14000000$')
if [ "$i9halt" = "1" ]; then
    PASS=$((PASS + 1)); echo "  imghdr_halt_still_unique: PASS (exactly one 0x14000000 in the headered image)"
else
    echo "FAIL: imghdr_halt_still_unique ($i9halt words equal 0x14000000; loop_offset_a64 needs exactly 1 or the boot gate's PC checks stop discriminating)"; FAIL=$((FAIL + 1))
fi

# 7. image_size == the size of the file ON DISK, and nonzero. The second
#    clause is not implied by the first (a zero-byte artifact would satisfy
#    equality), and it is the one that is a PROTOCOL obligation rather than an
#    observable: image_size = 1 and image_size = 64 BOTH boot under QEMU, which
#    substitutes its own 2 MiB text_offset and never reads this field for
#    placement. A real loader reads it as "how much memory to reserve", so
#    "the whole file, header included" rests on this static assertion and on
#    nothing the boot gate can see.
TOTAL=$((TOTAL + 1))
i9sz=$(ihdr_u64 "$IHDR_IMG" 16); i9disk=$(stat -c%s "$IHDR_IMG" 2>/dev/null || echo 0)
if [ "$i9sz" = "$i9disk" ] && [ "$i9sz" -gt 0 ]; then
    PASS=$((PASS + 1)); echo "  imghdr_image_size_is_file_size: PASS (image_size=$i9sz == on-disk $i9disk, header included)"
else
    echo "FAIL: imghdr_image_size_is_file_size (image_size=$i9sz on-disk=$i9disk; 0 tells a loader to reserve nothing, and a stale value means the patch-back never ran)"; FAIL=$((FAIL + 1))
fi

# 8. Every reserved field is zero: code1 @4, text_offset @8, res2-res4 @32/40/48
#    and res5 @60. text_offset is in this list rather than beside flags because
#    0 IS its required value here ("load anywhere", flags bit 3), not a
#    placeholder -- but the check is the same check, and splitting it would
#    leave the three res words as the only unasserted bytes in the header.
TOTAL=$((TOTAL + 1))
i9z=""
# Widths matter: code1 @4 and res5 @60 are u32, the rest are u64. Reading a
# u64 field as a u32 would leave its high half unasserted, which is the half a
# stray write is most likely to land in.
for i9o in 4 60; do
    i9v=$(ihdr_u32 "$IHDR_IMG" "$i9o")
    [ "$i9v" = 0 ] || i9z="$i9z u32@$i9o=$i9v"
done
for i9o in 8 32 40 48; do
    i9v=$(ihdr_u64 "$IHDR_IMG" "$i9o")
    [ "$i9v" = 0 ] || i9z="$i9z u64@$i9o=$i9v"
done
if [ -z "$i9z" ]; then
    PASS=$((PASS + 1)); echo "  imghdr_reserved_are_zero: PASS (code1, text_offset, res2-res5 all 0)"
else
    echo "FAIL: imghdr_reserved_are_zero (nonzero:$i9z)"; FAIL=$((FAIL + 1))
fi

# 9. THE MECHANISM, NOT THE OUTPUT. The header is emitted BEFORE the function
#    emit loop, so `a64_compute_va` lays every function out 64 bytes further
#    along and re-bakes each ADRP page computation around it. The observable is
#    that every page-relative reference in the flagged image resolves to
#    EXACTLY its unflagged target + 64 -- the payload moved and the arithmetic
#    followed it. Glue the header on afterwards instead and these targets stay
#    put while the data they point at moves, which boots to SILENCE.
#
#    A BYTE COUNT IS DELIBERATELY NOT ASSERTED, and an unchanged payload is
#    deliberately NOT treated as failure. The number of re-baked BYTES is
#    program-specific -- 24 for the boot gate's sentinel_a64.kr (18 ADRP
#    pairs), 2 for the suite's IMG5_SRC, and legitimately 0 for a program with
#    no page-relative references at all, whose image is perfectly correct
#    ($STK_SRC in row 4 is exactly that program). What is asserted is the
#    RELATION, which holds for every program including the zero-pair one --
#    vacuously there, and that is why $IHDR_SRC has a static: a vacuous row is
#    not a check, so this row's own precondition (at least one pair) is
#    asserted first.
TOTAL=$((TOTAL + 1))
i9a=$(img_a64_adrp_targets "$IHDR_NOF" | tr '\n' ' ')
i9b=$(img_a64_adrp_targets "$IHDR_IMG" | tr '\n' ' ')
i9want=""
for i9t in $i9a; do i9want="$i9want $(( i9t + 64 ))"; done
i9want=$(echo $i9want); i9b=$(echo $i9b)
i9n=$(echo "$i9a" | wc -w)
if [ "$i9n" -ge 1 ] && [ "$i9want" = "$i9b" ]; then
    PASS=$((PASS + 1)); echo "  imghdr_page_refs_rebaked: PASS ($i9n ADRP pair(s), every target +64: [$i9a] -> [$i9b])"
elif [ "$i9n" -lt 1 ]; then
    echo "FAIL: imghdr_page_refs_rebaked (the test program has NO ADRP pairs, so this row proves nothing -- \$IHDR_SRC lost its static)"; FAIL=$((FAIL + 1))
else
    echo "FAIL: imghdr_page_refs_rebaked (unflagged targets [$i9a] want [$i9want] got [$i9b] -- the VA map was not recomputed around the header)"; FAIL=$((FAIL + 1))
fi

# 10. THE INDEPENDENT ORACLE: file(1), which has its own Image magic rule and
#     no knowledge of this compiler. Positive AND negative in one row -- the
#     negative is the artifact with its four magic bytes overwritten, which
#     must fall back to "data". Without the negative half the positive is a
#     check that has only ever been seen passing, and file(1) reporting "data"
#     for BOTH would be indistinguishable from success on a grep that only
#     looked at the positive.
TOTAL=$((TOTAL + 1))
if ! command -v file >/dev/null 2>&1; then
    # Not a skip: a skip here is indistinguishable from a pass (the suite's
    # TOTAL is already incremented) and this is the only check in the section
    # that does not trust the compiler's own view of its output.
    echo "FAIL: imghdr_file_recognises_image (file(1) is not installed -- the independent oracle cannot run)"; FAIL=$((FAIL + 1))
else
    i9corrupt=/tmp/krc_ihdr_bad_$$
    cp "$IHDR_IMG" "$i9corrupt"
    printf '\xde\xad\xbe\xef' | dd of="$i9corrupt" bs=1 seek=56 conv=notrunc status=none
    i9good=$(file -b "$IHDR_IMG" 2>/dev/null)
    i9bad=$(file -b "$i9corrupt" 2>/dev/null)
    if echo "$i9good" | grep -q "Linux kernel ARM64 boot executable Image" && [ "$i9bad" = "data" ]; then
        PASS=$((PASS + 1)); echo "  imghdr_file_recognises_image: PASS (file(1): '$i9good'; magic corrupted -> '$i9bad')"
    else
        echo "FAIL: imghdr_file_recognises_image (good='$i9good' want 'Linux kernel ARM64 boot executable Image'; corrupted='$i9bad' want 'data')"; FAIL=$((FAIL + 1))
    fi
    rm -f "$i9corrupt"
fi

rm -f "$IHDR_IMG" "$IHDR_NOF" "$IHDR_SRC"

# --- entry selection: `_start` preferred over `main` (sub-project B2, T2) ---
#
# WHAT THIS SECTION PINS. `--emit=image` used to resolve its entry through
# find_main_offset() alone, so a bare-metal program whose entry is named
# `_start` -- the name riscv32 and xtensa raw emission have accepted since
# sub-project A -- was refused outright with "no 'main' function found". T2
# gives x86_64/arm64 the same rule the other two arches already had: the entry
# is a live `_start` if one exists, else `main`.
#
# THE TRAP THESE ROWS ARE SHAPED AROUND. Entry selection returns an AST NODE;
# the report line needs a CODE OFFSET. Widening the refusal so `_start`-only
# programs compile, without also converting node -> offset, leaves entry_off at
# its 0xFFFFFFFF sentinel and the artifact reports entry=4294967295. A row that
# asserted only "exit 0 and a file appeared" is GREEN on that defect, which is
# why every row below reads `entry` out of the report line and bounds it:
# 0 < entry < filesz. Observed: with the refusal widened and nothing else, the
# entry_start_only rows fail on `entry=4294967295 >= filesz`.
#
# WHY THE PREFERENCE ROWS COMPARE TWO BUILDS INSTEAD OF LOOKING FOR A SENTINEL
# IN THE BYTES. Nothing in `make test` can EXECUTE one of these images -- the
# stack-init stub is Tasks 3/4, and the arm64 artifact is not native here
# either -- so "the `_start` sentinel is printed and main's is not" has no
# harness. A sentinel searched for in the FILE cannot stand in for it: both
# functions are live (main is a DCE root, `_start` is seeded), so both bodies
# are emitted and BOTH sentinels appear whichever one was chosen. And a 64-bit
# immediate is contiguous bytes on x86_64 but four movz/movk words on arm64, so
# a byte search is not even portable across the two rows.
#
# What IS falsifiable without execution is the offset. The two sources differ
# by exactly one appended function, so `f` and `main` occupy identical offsets
# in both; main_only's reported entry IS main's offset. If selection picked
# main, `both` reports that same number. It must instead report a LARGER one --
# `_start` is emitted after main -- and still inside the file. That
# distinguishes all four outcomes: chose main (equal), chose `_start`
# (greater), unresolved sentinel (>= filesz), hardcoded zero (0).
echo ""
echo "--- entry selection: _start preferred over main (B2 T2) ---"
ENT_A="$DIR/../test_tmp_ent_a_$$.kr"   # f + main            (no _start)
ENT_B="$DIR/../test_tmp_ent_b_$$.kr"   # f + main + _start   (identical prefix)
ENT_S="$DIR/../test_tmp_ent_s_$$.kr"   # f + _start          (no main at all)
ENT_N="$DIR/../test_tmp_ent_n_$$.kr"   # neither
# `f` is recursive so the inliner cannot fold it away; that keeps main off file
# offset 0, without which "entry > 0" would be unfalsifiable. The two bodies
# compute different sentinels into the same static -- different code, no new
# static or string literal, so appending `_start` cannot shift `f` or `main`.
ENT_PREFIX='static uint64 g = 0x4B52535441525421
fn f(uint64 x) -> uint64 { if x < 2 { return x + g }
 return f(x - 1) + f(x - 2) }
'
ENT_MAIN='fn main() -> uint64 { g = f(6) + 0x1111
 return 0 }
'
ENT_START='fn _start() { g = f(7) + 0x2222
 loop { } }
'
printf '%s%s'   "$ENT_PREFIX" "$ENT_MAIN"                 > "$ENT_A"
printf '%s%s%s' "$ENT_PREFIX" "$ENT_MAIN" "$ENT_START"    > "$ENT_B"
printf '%s%s'   "$ENT_PREFIX" "$ENT_START"                > "$ENT_S"
printf '%s'     "$ENT_PREFIX"                             > "$ENT_N"

# Compile one image; echo "<entry> <filesz>" on success, nothing on failure.
ent_build() {  # $1 src, $2 arch, $3 out
    local ld=0x400000; [ "$2" = arm64 ] && ld=0x40400000
    local o st
    o=$($KRC $KRC_FLAGS "$1" -o "$3" --arch=$2 --target=none --emit=image --load-addr=$ld 2>&1)
    st=$?
    [ $st -eq 0 ] || return 1
    echo "$o" | sed -n 's/^image: .* entry=\([0-9]*\) filesz=\([0-9]*\) .*/\1 \2/p'
}

# 1. A program whose only function is `_start` compiles, writes an image, and
#    reports an entry that is a real offset inside it. At BASE both arches
#    print "error: no 'main' function found" and write nothing.
for IA in x86_64 arm64; do
    TOTAL=$((TOTAL + 1))
    rm -f /tmp/krc_ent_$$
    ent_r=$(ent_build "$ENT_S" $IA /tmp/krc_ent_$$); ent_st=$?
    ent_e=${ent_r% *}; ent_f=${ent_r#* }
    if [ $ent_st -eq 0 ] && [ -f /tmp/krc_ent_$$ ] && [ -n "$ent_r" ] \
       && [ "$ent_e" -gt 0 ] && [ "$ent_e" -lt "$ent_f" ] \
       && [ "$ent_f" = "$(stat -c%s /tmp/krc_ent_$$)" ]; then
        PASS=$((PASS + 1)); echo "  entry_start_only_$IA: PASS (entry=$ent_e of $ent_f)"
    else
        echo "FAIL: entry_start_only_$IA (exit=$ent_st report='$ent_r' size=$(stat -c%s /tmp/krc_ent_$$ 2>/dev/null))"
        FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_ent_$$
done

# 2. With BOTH present, `_start` wins. See the section header for why this is
#    an offset comparison and not a sentinel search.
for IA in x86_64 arm64; do
    TOTAL=$((TOTAL + 1))
    rm -f /tmp/krc_enta_$$ /tmp/krc_entb_$$
    ent_ra=$(ent_build "$ENT_A" $IA /tmp/krc_enta_$$); ent_sta=$?
    ent_rb=$(ent_build "$ENT_B" $IA /tmp/krc_entb_$$); ent_stb=$?
    ent_ea=${ent_ra% *}
    ent_eb=${ent_rb% *}; ent_fb=${ent_rb#* }
    if [ $ent_sta -eq 0 ] && [ $ent_stb -eq 0 ] && [ -n "$ent_ra" ] && [ -n "$ent_rb" ] \
       && [ "$ent_ea" -gt 0 ] && [ "$ent_eb" -gt "$ent_ea" ] && [ "$ent_eb" -lt "$ent_fb" ]; then
        PASS=$((PASS + 1)); echo "  entry_start_preferred_$IA: PASS (main at $ent_ea, _start at $ent_eb of $ent_fb)"
    elif [ -n "$ent_ra" ] && [ "$ent_eb" = "$ent_ea" ] && [ "$ent_eb" -lt "$ent_fb" ]; then
        # Named apart from the bounds failure: "still points at main" and
        # "points nowhere" are different defects and want opposite fixes.
        echo "FAIL: entry_start_preferred_$IA (entry=$ent_eb is main's own offset — _start was not preferred)"
        FAIL=$((FAIL + 1))
    else
        echo "FAIL: entry_start_preferred_$IA (main_only='$ent_ra' exit=$ent_sta, both='$ent_rb' exit=$ent_stb)"
        FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_enta_$$ /tmp/krc_entb_$$
done

# 3. Neither function present: refused, three clauses (nonzero exit, the
#    diagnostic, no artifact). The message must name BOTH acceptable names --
#    "no 'main' function found" is now a half-truth on this path.
for IA in x86_64 arm64; do
    TOTAL=$((TOTAL + 1))
    ILOAD=0x400000; [ "$IA" = arm64 ] && ILOAD=0x40400000
    rm -f /tmp/krc_entn_$$
    entn_out=$($KRC $KRC_FLAGS "$ENT_N" -o /tmp/krc_entn_$$ --arch=$IA --target=none --emit=image --load-addr=$ILOAD 2>&1)
    entn_st=$?
    if [ $entn_st -ne 0 ] && [ ! -f /tmp/krc_entn_$$ ] \
       && echo "$entn_out" | grep -q "needs an entry function ('_start' or 'main')"; then
        PASS=$((PASS + 1)); echo "  entry_neither_refused_$IA: PASS"
    else
        echo "FAIL: entry_neither_refused_$IA (exit=$entn_st, artifact=$([ -f /tmp/krc_entn_$$ ] && echo yes || echo no), out=$(echo "$entn_out" | head -1))"
        FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_entn_$$
done

# 3b. THE SAME REFUSAL, WITH --stack-top=, WHICH IS A DIFFERENT ARM OF THE
#     COMPILER. find_entry_node returning 0 is refused at THREE points on the
#     image path, and which one fires depends on the flag:
#
#       --stack-top absent  -> the finalize block  (what row 3 above reaches)
#       --stack-top + x86_64 -> the trampoline's PART 2, before finalize
#       --stack-top + arm64  -> the stub arm, before finalize
#
#     Row 3 only ever reaches the first, so the two stub arms shipped with no
#     coverage at all. Confirmed by instrumenting all three arms with distinct
#     markers and rebuilding: with the flag the stub arms fire and the finalize
#     arm is never reached; without it, only the finalize arm is.
#
#     They are worth their own rows even though the diagnostic is now shared
#     through entry_missing_die(): the stub arms run BEFORE any stub bytes are
#     emitted and before the entry token is read out of the node, so a missing
#     guard there is not a wrong message, it is ast_data1(0) followed by a
#     fixup recorded against a garbage token. Three clauses, as everywhere.
for IA in x86_64 arm64; do
    TOTAL=$((TOTAL + 1))
    ILOAD=0x400000; ISTK=0x90000
    [ "$IA" = arm64 ] && { ILOAD=0x40400000; ISTK=0x40800000; }
    rm -f /tmp/krc_entns_$$
    entns_out=$($KRC $KRC_FLAGS "$ENT_N" -o /tmp/krc_entns_$$ --arch=$IA --target=none --emit=image --load-addr=$ILOAD --stack-top=$ISTK 2>&1)
    entns_st=$?
    if [ $entns_st -ne 0 ] && [ ! -f /tmp/krc_entns_$$ ] \
       && echo "$entns_out" | grep -q "needs an entry function ('_start' or 'main')"; then
        PASS=$((PASS + 1)); echo "  entry_neither_refused_with_stub_$IA: PASS"
    else
        echo "FAIL: entry_neither_refused_with_stub_$IA (exit=$entns_st, artifact=$([ -f /tmp/krc_entns_$$ ] && echo yes || echo no), out=$(echo "$entns_out" | head -1))"
        FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_entns_$$
done

# 4. The HOSTED refusal must not widen. A program with `_start` and no `main`
#    compiled for Linux still needs a `main` -- `_start` there is an ordinary
#    function name and libc/the kernel owns the real entry. This is the
#    else-POSIX inheritance guard in reverse: a bare-metal rule that leaked
#    into the hosted path would show up here.
#
#    THREE clauses and BOTH arches, like every other refusal in this branch.
#    It shipped as a two-clause x86_64-only row, which is the exact shape B1
#    Task 6's hole wore: a refusal that prints the right message, writes
#    nothing and exits 0 passes a two-clause check. The bare-metal widening
#    landed in shared code (find_entry_node), so an arch-specific leak into
#    the hosted path is possible and only the arm64 twin would see it.
for IA in x86_64 arm64; do
    TOTAL=$((TOTAL + 1))
    rm -f /tmp/krc_enth_$$
    enth_out=$($KRC $KRC_FLAGS "$ENT_S" -o /tmp/krc_enth_$$ --arch=$IA 2>&1); enth_st=$?
    if [ $enth_st -ne 0 ] && [ ! -f /tmp/krc_enth_$$ ] \
       && echo "$enth_out" | grep -q "no 'main' function found"; then
        PASS=$((PASS + 1)); echo "  entry_start_not_entry_when_hosted_$IA: PASS"
    else
        echo "FAIL: entry_start_not_entry_when_hosted_$IA (exit=$enth_st, artifact=$([ -f /tmp/krc_enth_$$ ] && echo yes || echo no), out=$(echo "$enth_out" | head -1))"
        FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_enth_$$
done
rm -f "$ENT_A" "$ENT_B" "$ENT_S" "$ENT_N"

# --- the arm64 entry stub: set SP, `bl <entry>`, halt (sub-project B2, T3) ---
#
# WHAT THIS SECTION PINS. With `--stack-top=` present, an arm64 `--emit=image`
# artifact carries a five-word stub the compiler emitted, and the REPORTED
# `entry` points at that stub rather than at the entry function. Without the
# flag nothing is emitted -- that half is asserted here as a byte-level fact
# (zero `mov sp, x0` words in the artifact), not merely as "the flag was
# accepted".
#
# WHY THE BL IS DECODED AND NOT JUST SHAPE-CHECKED. `BL #0` -- the placeholder
# `emit_a64(0x94000000)` writes before the fixup runs -- IS a well-formed BL
# instruction, and it is a BRANCH TO ITSELF. A stub emitted after
# `resolve_fixups_a64()` therefore assembles, disassembles and reports
# perfectly while hanging the machine on the first instruction of the entry
# sequence, with no diagnostic anywhere. So the rows below reject imm26 == 0
# explicitly AND resolve the displacement to a file offset, which must equal
# the entry function's own offset.
#
# WHERE THAT EXPECTED OFFSET COMES FROM. The stub is emitted after every
# function is laid out, so adding it cannot move a function: the entry
# function's offset in the with-stub image is exactly the entry the SAME
# program reports with the flag absent. (Its BYTES can differ -- the string
# and static areas moved by the stub's length, so ADRP/ADD immediates inside
# the functions are patched differently -- but no function's OFFSET does.)
echo ""
echo "--- arm64 entry stub: SP + bl + halt (B2 T3) ---"
STB_SRC="$DIR/../test_tmp_stb_$$.kr"     # f + main            (entry == main)
STB_SRC2="$DIR/../test_tmp_stb2_$$.kr"   # f + main + _start   (entry == _start)
# Same shape as T2's programs: `f` is recursive so the inliner cannot fold it,
# which keeps the entry function off file offset 0 and leaves "the stub's entry
# differs from the function's entry" falsifiable.
STB_PREFIX='static uint64 g = 0x4B52535441525421
fn f(uint64 x) -> uint64 { if x < 2 { return x + g }
 return f(x - 1) + f(x - 2) }
fn main() -> uint64 { g = f(6) + 0x1111
 return 0 }
'
STB_START='fn _start() { g = f(7) + 0x2222
 loop { } }
'
printf '%s'   "$STB_PREFIX"               > "$STB_SRC"
printf '%s%s' "$STB_PREFIX" "$STB_START"  > "$STB_SRC2"
STB_SP=0x40800000     # low half zero  -- rows 1-3
STB_SP2=0x40801230    # low half NONZERO -- row 4 (review M4); movk = f2824600

# Compile one arm64 image; echo "<entry> <filesz>" on success, nothing on
# failure. $1 src, $2 out, $3 load-addr, $4... extra flags.
stb_build() {
    local src="$1" out="$2" ld="$3"; shift 3
    local o st
    rm -f "$out"
    o=$($KRC $KRC_FLAGS "$src" -o "$out" --arch=arm64 --target=none --emit=image --load-addr=$ld "$@" 2>&1)
    st=$?
    [ $st -eq 0 ] || return 1
    echo "$o" | sed -n 's/^image: .* entry=\([0-9]*\) filesz=\([0-9]*\) .*/\1 \2/p'
}

# Decode the five words at <off> and check them against the spec-D2 encodings.
# $1 image, $2 stub offset, $3 stack top, $4 expected BL target offset.
# Prints every mismatch it finds (not just the first) and exits nonzero.
#
# A HARNESS FAILURE MUST NEVER READ AS A PASS (review I1). Callers consume this
# through `reason=$(stb_check …)` and treat an EMPTY reason as green, so any
# path that exits nonzero while printing nothing to stdout -- a missing
# artifact, a python traceback, no python3 at all -- would paint the row green
# with the check never having run. Observed: deleting only row 4's artifact
# produced a fully green 4/4 section with that row's subject not existing.
# Two guards, deliberately overlapping:
#   * an explicit artifact precondition here, which is the likely cause and
#     deserves its own message rather than "python exited 1";
#   * a catch-all that converts "nonzero exit, empty stdout" into a loud
#     reason, so a failure mode nobody predicted still reds the row.
# Callers add a THIRD, independent layer by checking the exit status too.
stb_check() {
    if [ ! -f "$1" ]; then
        echo "no artifact at $1 -- the check's SUBJECT does not exist, so nothing was verified"
        return 1
    fi
    local sc_out sc_rc
    sc_out=$(stb_check_py "$1" "$2" "$3" "$4"); sc_rc=$?
    if [ $sc_rc -ne 0 ] && [ -z "$sc_out" ]; then
        echo "stb_check harness failed (python3 exit=$sc_rc) with no reason on stdout -- the check never ran"
        return 1
    fi
    [ -n "$sc_out" ] && echo "$sc_out"
    return $sc_rc
}
stb_check_py() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import struct, sys
img, off, sp, want = sys.argv[1], int(sys.argv[2]), int(sys.argv[3], 0), int(sys.argv[4])
d = open(img, "rb").read()
if off + 20 > len(d):
    print("stub at %d does not fit in a %d-byte image" % (off, len(d))); sys.exit(1)
w = list(struct.unpack("<5I", d[off:off + 20]))
e0 = 0xd2a00000 | (((sp >> 16) & 0xffff) << 5)      # movz x0, #sp[31:16], lsl 16
e1 = 0xf2800000 | ((sp & 0xffff) << 5)              # movk x0, #sp[15:0]
bad = []
if w[0] != e0: bad.append("word0 %08x != movz %08x" % (w[0], e0))
if w[1] != e1: bad.append("word1 %08x != movk %08x" % (w[1], e1))
if w[2] != 0x9100001f: bad.append("word2 %08x != mov sp,x0 9100001f" % w[2])
if (w[3] >> 26) != 0x25:
    bad.append("word3 %08x is not a BL (opcode %02x != 25)" % (w[3], w[3] >> 26))
else:
    imm = w[3] & 0x3ffffff
    if imm >= (1 << 25): imm -= (1 << 26)
    if imm == 0:
        bad.append("word3 %08x is BL #0 -- the UNRESOLVED placeholder, i.e. a "
                   "branch to itself; the stub was emitted past "
                   "resolve_fixups_a64()" % w[3])
    else:
        tgt = off + 12 + imm * 4
        if tgt != want:
            bad.append("BL targets offset %d, entry function is at %d" % (tgt, want))
if w[4] != 0x14000000: bad.append("word4 %08x != halt (b .) 14000000" % w[4])
if bad:
    print("; ".join(bad)); sys.exit(1)
PY
}

# Count 0x9100001f (`mov sp, x0`) words in an image. The stub is the only
# thing that emits one -- ir_a64/codegen_a64 move the stack pointer with
# SUB/ADD sp,sp,#imm, never through x0 -- so this is the byte-level test for
# "the stub is present" / "the stub is absent".
stb_movsp_count() {
    python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
print(sum(1 for i in range(0, len(d) - 3, 4)
          if d[i:i+4] == bytes.fromhex("1f000091")))   # 0x9100001f little-endian
PY
}

# 1. The five words are at the reported entry, and the BL resolves to the
#    entry function's own offset (taken from the SAME program built with the
#    flag absent).
TOTAL=$((TOTAL + 1))
stb_ra=$(stb_build "$STB_SRC" /tmp/krc_stb_a_$$ 0x40400000); stb_sta=$?
stb_rb=$(stb_build "$STB_SRC" /tmp/krc_stb_b_$$ 0x40400000 --stack-top=$STB_SP); stb_stb=$?
stb_fn=${stb_ra% *}
stb_e=${stb_rb% *}; stb_f=${stb_rb#* }
stb_why=""
if [ $stb_sta -ne 0 ] || [ $stb_stb -ne 0 ] || [ -z "$stb_ra" ] || [ -z "$stb_rb" ]; then
    stb_why="build failed (no-flag exit=$stb_sta report='$stb_ra'; stub exit=$stb_stb report='$stb_rb')"
elif [ "$stb_f" != "$(stat -c%s /tmp/krc_stb_b_$$ 2>/dev/null)" ]; then
    stb_why="report claims filesz=$stb_f, on disk $(stat -c%s /tmp/krc_stb_b_$$ 2>/dev/null)"
elif [ "$stb_e" = "$stb_fn" ]; then
    stb_why="entry=$stb_e is the entry FUNCTION's offset -- no stub was emitted"
else
    # Status AND stdout. `$(…) || true` alone discards the status, which is
    # exactly how a silent harness failure becomes a PASS (review I1).
    stb_why=$(stb_check /tmp/krc_stb_b_$$ "$stb_e" "$STB_SP" "$stb_fn"); stb_crc=$?
    if [ -z "$stb_why" ] && [ $stb_crc -ne 0 ]; then
        stb_why="stb_check exited $stb_crc with no reason -- the check never ran"
    fi
fi
if [ -z "$stb_why" ]; then
    PASS=$((PASS + 1)); echo "  stub_arm64_words: PASS (stub at $stb_e, bl -> main at $stb_fn, of $stb_f)"
else
    echo "FAIL: stub_arm64_words ($stb_why)"; FAIL=$((FAIL + 1))
fi

# 2. No --stack-top => no stub. Asserted as a byte fact on the artifact, not
#    as "the compiler exited 0": the no-flag image must contain ZERO
#    `mov sp, x0` words and the flag'd one exactly ONE.
TOTAL=$((TOTAL + 1))
stb_na=$(stb_movsp_count /tmp/krc_stb_a_$$ 2>/dev/null)
stb_nb=$(stb_movsp_count /tmp/krc_stb_b_$$ 2>/dev/null)
if [ "$stb_na" = "0" ] && [ "$stb_nb" = "1" ]; then
    PASS=$((PASS + 1)); echo "  stub_arm64_absent_without_flag: PASS (0 vs 1 mov sp,x0)"
else
    echo "FAIL: stub_arm64_absent_without_flag (no-flag image has ${stb_na:-?} mov sp,x0 words, flag'd image ${stb_nb:-?}; want 0 and 1)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_stb_a_$$

# 3. The stub is FULLY PC-RELATIVE: the same source, same --stack-top, two
#    different --load-addr values must produce byte-identical images. A stub
#    that materialised the load address anywhere would differ here (and would
#    also red B1's image_load_addr_not_embedded_arm64, which covers only the
#    no-stub form).
TOTAL=$((TOTAL + 1))
stb_rc=$(stb_build "$STB_SRC" /tmp/krc_stb_c_$$ 0x40500000 --stack-top=$STB_SP); stb_stc=$?
if [ $stb_stc -eq 0 ] && [ -f /tmp/krc_stb_b_$$ ] && [ -f /tmp/krc_stb_c_$$ ] \
   && cmp -s /tmp/krc_stb_b_$$ /tmp/krc_stb_c_$$; then
    PASS=$((PASS + 1)); echo "  stub_arm64_load_addr_not_embedded: PASS (0x40400000 == 0x40500000, byte for byte)"
else
    echo "FAIL: stub_arm64_load_addr_not_embedded (exit=$stb_stc; the stub depends on --load-addr)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_stb_b_$$ /tmp/krc_stb_c_$$

# 4. The stub calls the ENTRY, which is T2's rule and not "main": with both
#    `_start` and `main` live, the BL must resolve to `_start`. This is the
#    only row that would catch a stub wired to find_main_offset() -- rows 1-3
#    all use a program whose entry IS main.
#
#    AND IT CARRIES THE NONZERO-LOW-HALF STACK TOP (review M4). Rows 1-3 use
#    0x40800000, whose low 16 bits are zero -- so the expected `movk x0, #0`
#    is byte-identical to what a compiler that DROPPED the low half entirely
#    would emit, leaving that whole defect class unpinned. 0x40801230 is
#    16-byte aligned, below 2^32, and encodes movk as f2824600, so a dropped
#    or truncated low half shows up here as a mismatch.
#
#    Its preconditions mirror row 1's rather than jumping straight to the
#    word check (review M1): reported-vs-on-disk size, and "entry is still
#    the entry FUNCTION's offset", so a red run says WHICH thing broke.
TOTAL=$((TOTAL + 1))
stb_rd=$(stb_build "$STB_SRC2" /tmp/krc_stb_d_$$ 0x40400000); stb_std=$?
stb_re=$(stb_build "$STB_SRC2" /tmp/krc_stb_e_$$ 0x40400000 --stack-top=$STB_SP2); stb_ste=$?
stb_sfn=${stb_rd% *}
stb_se=${stb_re% *}; stb_sf=${stb_re#* }
if [ $stb_std -ne 0 ] || [ $stb_ste -ne 0 ] || [ -z "$stb_rd" ] || [ -z "$stb_re" ]; then
    stb_why2="build failed (no-flag exit=$stb_std report='$stb_rd'; stub exit=$stb_ste report='$stb_re')"
elif [ "$stb_sf" != "$(stat -c%s /tmp/krc_stb_e_$$ 2>/dev/null)" ]; then
    stb_why2="report claims filesz=$stb_sf, on disk $(stat -c%s /tmp/krc_stb_e_$$ 2>/dev/null)"
elif [ "$stb_se" = "$stb_sfn" ]; then
    stb_why2="entry=$stb_se is the entry FUNCTION's offset -- no stub was emitted"
else
    stb_why2=$(stb_check /tmp/krc_stb_e_$$ "$stb_se" "$STB_SP2" "$stb_sfn"); stb_crc2=$?
    if [ -z "$stb_why2" ] && [ $stb_crc2 -ne 0 ]; then
        stb_why2="stb_check exited $stb_crc2 with no reason -- the check never ran"
    fi
fi
if [ -z "$stb_why2" ]; then
    PASS=$((PASS + 1)); echo "  stub_arm64_bl_targets_start: PASS (stub at $stb_se, bl -> _start at $stb_sfn, sp=$STB_SP2)"
else
    echo "FAIL: stub_arm64_bl_targets_start ($stb_why2)"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_stb_d_$$ /tmp/krc_stb_e_$$ "$STB_SRC" "$STB_SRC2"

# --- x86_64 entry stub: multiboot header + long-mode trampoline (B2 T4) -----
#
# X86_64 CANNOT USE ARM64'S SHAPE. KernRift emits only 64-bit code, and no x86
# entry path hands over a 64-bit CPU: `-device loader` leaves the CPU in 16-bit
# real mode (CR0.PE=0), `-kernel` on our ELF is refused, and multiboot enters
# 32-BIT protected mode. So the x86 stub is a multiboot header plus a 32-bit
# trampoline that builds page tables, enables PAE + EFER.LME + paging, loads a
# 64-bit GDT, far-jumps to long mode and calls the entry.
#
# THE STUB SITS AT FILE OFFSET 0, unlike arm64's, which is appended. A
# multiboot header must lie within the first 8192 bytes of the file, so
# appending it after the code would work only for images under 8 KiB and would
# then fail SILENTLY (qemu simply does not find a header) on the first program
# that grew past that. Consequence: on x86 the payload SHIFTS by the stub's
# length, which is why row 4 derives that shift from the artifact instead of
# comparing offsets directly the way the arm64 rows do.
#
# NOTHING BELOW HARDCODES A PATCH-SITE OFFSET. Adding `cld` to the trampoline
# once moved every site above 32 by one byte WHILE THE TOTAL STAYED 226 (the
# .align 16 padding absorbed it), so a size check cannot notice and a table of
# offsets is wrong by the next edit -- with a triple fault, not a diagnostic,
# as the symptom. The checker instead LOCATES each site by its opcode and
# requires the occurrence to be unique.
echo ""
echo "--- x86_64 entry stub: multiboot + long-mode trampoline (B2 T4) ---"
XSB_SRC="$DIR/../test_tmp_xsb_$$.kr"     # f + main          (entry == main)
XSB_SRC2="$DIR/../test_tmp_xsb2_$$.kr"   # f + main + _start (entry == _start)
# Deliberately NO statics and NO string literals, unlike the arm64 rows'
# program: row 4 asserts the payload is byte-identical after the shift, and
# the stub's length (226) is 2 mod 8, so a data area would sit behind a
# different amount of 8-byte alignment padding in the two builds and every
# RIP-relative displacement into it would legitimately differ. `f` is
# recursive so the inliner cannot fold it away and the entry function stays
# off file offset 0.
XSB_PREFIX='fn f(uint64 x) -> uint64 { if x < 2 { return x + 7 }
 return f(x - 1) + f(x - 2) }
fn main() -> uint64 { return f(6) + 0x1111 }
'
XSB_START='fn _start() { loop { } }
'
printf '%s'   "$XSB_PREFIX"               > "$XSB_SRC"
printf '%s%s' "$XSB_PREFIX" "$XSB_START"  > "$XSB_SRC2"
XSB_LOAD=0x400000
XSB_LOAD2=0x800000
XSB_SP=0x90000        # the classic below-1-MiB kernel stack
XSB_SP2=0x300ff0      # a DIFFERENT one, and not a round number: row 3 is the
                      # only thing standing between --stack-top and the C4 bug
                      # (validated, reported, then silently ignored)

# Compile one x86_64 image; echo "<entry> <filesz>" on success, nothing on
# failure. $1 src, $2 out, $3 load-addr, $4... extra flags.
xsb_build() {
    local src="$1" out="$2" ld="$3"; shift 3
    local o st
    rm -f "$out"
    o=$($KRC $KRC_FLAGS "$src" -o "$out" --arch=x86_64 --target=none --emit=image --load-addr=$ld "$@" 2>&1)
    st=$?
    [ $st -eq 0 ] || return 1
    echo "$o" | sed -n 's/^image: .* entry=\([0-9]*\) filesz=\([0-9]*\) .*/\1 \2/p'
}

# Structural check of the whole stub. $1 image, $2 load addr, $3 stack top.
# On success prints EXACTLY ONE line "stub_size=<n> entry_off=<n>" and exits 0;
# on failure prints every reason it found and exits 1.
#
# A HARNESS FAILURE MUST NOT READ AS A PASS (T3 review I1). Callers require the
# stub_size= prefix rather than treating empty output as green, so a missing
# artifact, a python traceback or no python3 at all fails closed.
xsb_check() {
    if [ ! -f "$1" ]; then
        echo "no artifact at $1 -- the check's SUBJECT does not exist, so nothing was verified"
        return 1
    fi
    local xo xc
    xo=$(xsb_check_py "$1" "$2" "$3"); xc=$?
    if [ $xc -ne 0 ] && [ -z "$xo" ]; then
        echo "xsb_check harness failed (python3 exit=$xc) with no reason on stdout -- the check never ran"
        return 1
    fi
    [ -n "$xo" ] && echo "$xo"
    return $xc
}
xsb_check_py() {
    python3 - "$1" "$2" "$3" <<'PY'
import struct, sys
img, load, sp = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0)
d = open(img, "rb").read()
bad = []
def u32(o): return struct.unpack_from("<I", d, o)[0]
def u64(o): return struct.unpack_from("<Q", d, o)[0]

# Locate each patch site BY OPCODE, and require the occurrence to be unique --
# no offset in this file is hardcoded, because every one of them has moved.
def find1(pat, what, lo=0, hi=None):
    hi = len(d) if hi is None else hi
    hits, i = [], lo
    while True:
        j = d.find(pat, i, hi)
        if j < 0: break
        hits.append(j); i = j + 1
    if len(hits) != 1:
        bad.append("%s: found %d occurrences of %s, want exactly 1"
                   % (what, len(hits), pat.hex()))
        return None
    return hits[0]

if len(d) < 226:
    print("image is %d bytes -- too short to hold the 226-byte stub" % len(d))
    sys.exit(1)

# --- multiboot header, offset 0 -------------------------------------------
MAGIC, FLAGS = 0x1BADB002, 0x00010000
if u32(0) != MAGIC:
    bad.append("offset 0 is %08x, not the multiboot magic %08x -- qemu -kernel "
               "will not even load this file" % (u32(0), MAGIC))
if u32(4) != FLAGS:
    bad.append("flags %08x != %08x (bit 16 is the AOUT KLUDGE, which is what "
               "lets a RAW non-ELF file boot at all)" % (u32(4), FLAGS))
ck = (-(MAGIC + FLAGS)) & 0xFFFFFFFF
if u32(8) != ck:
    bad.append("checksum %08x != -(magic+flags) %08x" % (u32(8), ck))
if u32(12) != load:
    bad.append("header_addr %08x != --load-addr %08x" % (u32(12), load))
if u32(16) != load:
    bad.append("load_addr %08x != --load-addr %08x" % (u32(16), load))
if u32(20) != 0:
    bad.append("load_end_addr %08x != 0 (0 means 'the whole file')" % u32(20))
if u32(24) != 0:
    bad.append("bss_end_addr %08x != 0" % u32(24))
if u32(28) != load + 32:
    bad.append("entry_addr %08x != load+32 %08x" % (u32(28), load + 32))

# --- 32-bit code ----------------------------------------------------------
# cli;cld. THE cld IS LOAD-BEARING AND UNTESTABLE BY BOOTING: multiboot 0.6.96
# 3.2 fixes only EFLAGS.VM and EFLAGS.IF and leaves DF UNDEFINED, while the
# trampoline runs rep stosl/movsl. QEMU happens to enter with DF=0, so this
# byte check is the ONLY thing that holds it.
if d[32:34] != b"\xfa\xfc":
    bad.append("bytes 32..34 are %s, not cli;cld (fafc) -- a missing cld leaves "
               "DF UNDEFINED across the rep stosl that builds the page tables"
               % d[32:34].hex())

# EVERY SEARCH WINDOW IS ANCHORED TO AN ALREADY-LOCATED SITE, never to a
# written-down offset, and every window is deliberately far wider than the
# thing inside it so the bound is not a layout claim. The chain starts at the
# header's own entry_addr and walks: lgdtl -> the ljmp that must follow it ->
# the 64-bit block the ljmp targets -> the two immediates inside that block.
# Searching the WHOLE FILE for `48 c7 c4` or `48 b8` would be wrong for a
# different reason than fragility: a real payload can legitimately contain
# either byte sequence, and the row would then fail on a correct compiler.
start32 = u32(28) - load
lgdt = find1(b"\x0f\x01\x15", "lgdtl", start32, start32 + 256)
ljmp = None
if lgdt is not None:
    if d[lgdt + 7] != 0xEA:
        bad.append("byte after lgdtl is %02x, not the ljmp (ea) that must "
                   "immediately follow it" % d[lgdt + 7])
    else:
        ljmp = lgdt + 7
movsp = None
movabs = None
if ljmp is not None:
    lm = u32(ljmp + 1) - load
    if 0 <= lm and lm + 64 <= len(d):
        movsp = find1(b"\x48\xc7\xc4", "mov $imm32,%rsp", lm, lm + 64)
        movabs = find1(b"\x48\xb8", "movabs $imm64,%rax", lm, lm + 64)

if lgdt is not None:
    gdtr_off = u32(lgdt + 3) - load
    if gdtr_off < 0 or gdtr_off + 10 > len(d):
        bad.append("lgdtl points at %08x, i.e. file offset %d, outside the image"
                   % (u32(lgdt + 3), gdtr_off))
    else:
        lim = struct.unpack_from("<H", d, gdtr_off)[0]
        gdt_off = u32(gdtr_off + 2) - load
        if gdt_off < 0 or gdt_off + 24 > len(d):
            bad.append("gdtr base %08x is outside the image" % u32(gdtr_off + 2))
        else:
            if lim != 23:
                bad.append("gdtr limit %d != 23 (3 quads - 1)" % lim)
            if gdt_off + 24 != gdtr_off:
                bad.append("gdt at %d + 24 != gdtr at %d" % (gdt_off, gdtr_off))
            want = [0, 0x00AF9A000000FFFF, 0x00CF92000000FFFF]
            for i, w in enumerate(want):
                got = u64(gdt_off + i * 8)
                if got != w:
                    bad.append("gdt[%d] = %016x != %016x" % (i, got, w))
            if u32(gdtr_off + 6) != 0:
                bad.append("gdtr tail .long is %08x, not 0" % u32(gdtr_off + 6))
        stub_size = gdtr_off + 10
else:
    stub_size = None

if ljmp is not None:
    if u32(ljmp + 5) & 0xFFFF != 0x0008:
        bad.append("ljmp selector %04x != 0x08 (the 64-bit code segment)"
                   % (u32(ljmp + 5) & 0xFFFF))
    lm_off = u32(ljmp + 1) - load
    if lm_off < 0 or lm_off + 10 > len(d):
        bad.append("ljmp targets %08x, outside the image" % u32(ljmp + 1))
    elif d[lm_off:lm_off + 10] != bytes.fromhex("66b810008ed88ec08ed0"):
        bad.append("ljmp lands on %s, not the 64-bit segment reloads "
                   "(66b810008ed88ec08ed0)" % d[lm_off:lm_off + 10].hex())

# --- 64-bit code ----------------------------------------------------------
if movsp is not None and u32(movsp + 3) != sp:
    bad.append("mov $imm32,%%rsp carries %08x, not --stack-top %08x -- the "
               "flag was validated and reported and then IGNORED (review C4)"
               % (u32(movsp + 3), sp))

entry_off = None
if movabs is not None:
    ev = u64(movabs + 2)
    if ev == 0:
        bad.append("movabs carries 0 -- the UNPATCHED placeholder. `call *%rax` "
                   "to 0 is a triple fault, not a diagnostic: the entry address "
                   "is written after the emit loop and that write did not happen")
    else:
        entry_off = ev - load
        if entry_off < 0 or entry_off >= len(d):
            bad.append("movabs carries %016x, i.e. file offset %d, outside the "
                       "%d-byte image" % (ev, entry_off, len(d)))
        elif stub_size is not None and entry_off < stub_size:
            bad.append("movabs targets offset %d, which is INSIDE the %d-byte "
                       "stub -- it must point into the payload" % (entry_off, stub_size))
    if d[movabs + 10:movabs + 15] != bytes.fromhex("ffd0f4ebfd"):
        bad.append("bytes after the movabs are %s, not call *%%rax; hlt; jmp . "
                   "(ffd0f4ebfd)" % d[movabs + 10:movabs + 15].hex())

if bad:
    print("; ".join(bad)); sys.exit(1)
print("stub_size=%d entry_off=%d" % (stub_size, entry_off))
PY
}

# Count multiboot magics on a 4-byte grid. The stub is the only thing that can
# emit one, so this is the byte-level "the stub is present" / "absent" test.
xsb_magic_count() {
    python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
print(sum(1 for i in range(0, len(d) - 3, 4)
          if d[i:i+4] == bytes.fromhex("02b0ad1b")))   # 0x1BADB002 little-endian
PY
}

# 1. The multiboot header is at offset 0, its three address fields agree with
#    --load-addr, and the whole trampoline decodes: cld present, GDT/GDTR
#    self-consistent, far jump landing on the 64-bit segment reloads, the
#    call/hlt tail intact. The reported entry is the trampoline (load+32), NOT
#    the entry function.
TOTAL=$((TOTAL + 1))
xsb_ra=$(xsb_build "$XSB_SRC" /tmp/krc_xsb_a_$$ $XSB_LOAD); xsb_sta=$?
xsb_rb=$(xsb_build "$XSB_SRC" /tmp/krc_xsb_b_$$ $XSB_LOAD --stack-top=$XSB_SP); xsb_stb=$?
xsb_fn=${xsb_ra% *}
xsb_e=${xsb_rb% *}; xsb_f=${xsb_rb#* }
xsb_why=""; xsb_facts=""
if [ $xsb_sta -ne 0 ] || [ $xsb_stb -ne 0 ] || [ -z "$xsb_ra" ] || [ -z "$xsb_rb" ]; then
    xsb_why="build failed (no-flag exit=$xsb_sta report='$xsb_ra'; stub exit=$xsb_stb report='$xsb_rb')"
elif [ "$xsb_f" != "$(stat -c%s /tmp/krc_xsb_b_$$ 2>/dev/null)" ]; then
    xsb_why="report claims filesz=$xsb_f, on disk $(stat -c%s /tmp/krc_xsb_b_$$ 2>/dev/null)"
elif [ "$xsb_e" != "32" ]; then
    xsb_why="report says entry=$xsb_e; the multiboot entry_addr is load+32, so the reported entry must be 32 (it is $xsb_fn without the flag)"
else
    xsb_facts=$(xsb_check /tmp/krc_xsb_b_$$ "$XSB_LOAD" "$XSB_SP"); xsb_crc=$?
    case "$xsb_facts" in
        stub_size=*) [ $xsb_crc -eq 0 ] || xsb_why="xsb_check exited $xsb_crc: $xsb_facts" ;;
        *)           xsb_why="${xsb_facts:-xsb_check produced no facts and exited $xsb_crc -- the check never ran}" ;;
    esac
fi
if [ -z "$xsb_why" ]; then
    PASS=$((PASS + 1)); echo "  stub_x86_multiboot_header: PASS ($xsb_facts, of $xsb_f B)"
else
    echo "FAIL: stub_x86_multiboot_header ($xsb_why)"; FAIL=$((FAIL + 1))
fi

# 2. No --stack-top => no stub. A byte fact on the artifact, not "the compiler
#    exited 0": zero multiboot magics without the flag, exactly one with it.
TOTAL=$((TOTAL + 1))
xsb_na=$(xsb_magic_count /tmp/krc_xsb_a_$$ 2>/dev/null)
xsb_nb=$(xsb_magic_count /tmp/krc_xsb_b_$$ 2>/dev/null)
if [ "$xsb_na" = "0" ] && [ "$xsb_nb" = "1" ]; then
    PASS=$((PASS + 1)); echo "  stub_x86_absent_without_flag: PASS (0 vs 1 multiboot magic)"
else
    echo "FAIL: stub_x86_absent_without_flag (no-flag image has ${xsb_na:-?} magics, flag'd image ${xsb_nb:-?}; want 0 and 1)"
    FAIL=$((FAIL + 1))
fi

# 3. --stack-top REACHES THE GUEST. The reference .S hardcoded 0x90000 and the
#    bug survived a full review round because the differential build only ever
#    varied the load address (review C4). Two different values, each of which
#    must appear in its own image's `mov $imm32,%rsp` -- and the two images
#    must therefore differ.
TOTAL=$((TOTAL + 1))
xsb_rc=$(xsb_build "$XSB_SRC" /tmp/krc_xsb_c_$$ $XSB_LOAD --stack-top=$XSB_SP2); xsb_stc=$?
xsb_fc=$(xsb_check /tmp/krc_xsb_c_$$ "$XSB_LOAD" "$XSB_SP2"); xsb_crc3=$?
if [ $xsb_stc -ne 0 ]; then
    xsb_why3="build at --stack-top=$XSB_SP2 exited $xsb_stc"
elif [ $xsb_crc3 -ne 0 ] || [ "${xsb_fc#stub_size=}" = "$xsb_fc" ]; then
    xsb_why3="${xsb_fc:-xsb_check produced no facts and exited $xsb_crc3 -- the check never ran}"
elif cmp -s /tmp/krc_xsb_b_$$ /tmp/krc_xsb_c_$$; then
    xsb_why3="the $XSB_SP and $XSB_SP2 images are BYTE-IDENTICAL -- --stack-top is being ignored"
else
    xsb_why3=""
fi
if [ -z "$xsb_why3" ]; then
    PASS=$((PASS + 1)); echo "  stub_x86_stack_top_reaches_the_image: PASS ($XSB_SP != $XSB_SP2, each in its own rsp load)"
else
    echo "FAIL: stub_x86_stack_top_reaches_the_image ($xsb_why3)"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_xsb_c_$$

# 4. The movabs targets the ENTRY FUNCTION, and the payload is otherwise
#    untouched. Unlike arm64 the stub is PREPENDED, so the entry function moves
#    -- by exactly the stub's length, which is DERIVED FROM THE ARTIFACT (the
#    gdtr's own end) rather than written down here. Both halves matter: the
#    offset arithmetic AND a byte-for-byte comparison of the shifted payload,
#    so a movabs that happened to land on the right number for the wrong reason
#    still reds.
TOTAL=$((TOTAL + 1))
xsb_ss=${xsb_facts#stub_size=}; xsb_ss=${xsb_ss%% *}
xsb_eo=${xsb_facts##*entry_off=}
if [ -z "$xsb_facts" ] || [ -z "$xsb_ss" ] || [ -z "$xsb_eo" ]; then
    xsb_why4="row 1 produced no facts, so there is nothing to check here"
elif [ "$xsb_eo" != "$((xsb_fn + xsb_ss))" ]; then
    xsb_why4="movabs targets offset $xsb_eo; the entry function is at $xsb_fn without the flag and the stub is $xsb_ss B, so it must be $((xsb_fn + xsb_ss))"
else
    xsb_why4=$(python3 - /tmp/krc_xsb_a_$$ /tmp/krc_xsb_b_$$ "$xsb_ss" <<'PY'
import sys
a = open(sys.argv[1], "rb").read(); b = open(sys.argv[2], "rb").read()
ss = int(sys.argv[3])
# Trailing 8-byte alignment padding legitimately differs (the stub is 2 mod 8),
# so compare everything up to the last 8 bytes of the shorter payload.
n = min(len(a), len(b) - ss) - 8
if n <= 0:
    print("no payload to compare (a=%d b=%d stub=%d)" % (len(a), len(b), ss))
elif a[:n] != b[ss:ss + n]:
    i = next(k for k in range(n) if a[k] != b[ss + k])
    print("payload differs at byte %d of %d (%02x vs %02x) -- prepending the "
          "stub changed the code, it must only move it" % (i, n, a[i], b[ss + i]))
PY
)
fi
if [ -z "$xsb_why4" ]; then
    PASS=$((PASS + 1)); echo "  stub_x86_entry_movabs_targets_entry: PASS (entry $xsb_fn + stub $xsb_ss = $xsb_eo, payload identical)"
else
    echo "FAIL: stub_x86_entry_movabs_targets_entry ($xsb_why4)"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_xsb_a_$$ /tmp/krc_xsb_b_$$

# 5. The stub calls the ENTRY, which is T2's rule and not "main": with both
#    `_start` and `main` live, the movabs must resolve to `_start`. Rows 1-4
#    all use a program whose entry IS main, so this is the only row that would
#    catch a stub wired to find_main_offset().
TOTAL=$((TOTAL + 1))
xsb_rd=$(xsb_build "$XSB_SRC2" /tmp/krc_xsb_d_$$ $XSB_LOAD); xsb_std=$?
xsb_re=$(xsb_build "$XSB_SRC2" /tmp/krc_xsb_e_$$ $XSB_LOAD --stack-top=$XSB_SP); xsb_ste=$?
xsb_sfn=${xsb_rd% *}
xsb_fe=$(xsb_check /tmp/krc_xsb_e_$$ "$XSB_LOAD" "$XSB_SP"); xsb_crc5=$?
if [ $xsb_std -ne 0 ] || [ $xsb_ste -ne 0 ] || [ -z "$xsb_rd" ] || [ -z "$xsb_re" ]; then
    xsb_why5="build failed (no-flag exit=$xsb_std report='$xsb_rd'; stub exit=$xsb_ste report='$xsb_re')"
elif [ $xsb_crc5 -ne 0 ] || [ "${xsb_fe#stub_size=}" = "$xsb_fe" ]; then
    xsb_why5="${xsb_fe:-xsb_check produced no facts and exited $xsb_crc5 -- the check never ran}"
else
    xsb_ss5=${xsb_fe#stub_size=}; xsb_ss5=${xsb_ss5%% *}
    xsb_eo5=${xsb_fe##*entry_off=}
    if [ "$xsb_eo5" != "$((xsb_sfn + xsb_ss5))" ]; then
        xsb_why5="movabs targets $xsb_eo5, but _start is at $xsb_sfn + stub $xsb_ss5 = $((xsb_sfn + xsb_ss5))"
    else
        xsb_why5=""
    fi
fi
if [ -z "$xsb_why5" ]; then
    PASS=$((PASS + 1)); echo "  stub_x86_movabs_targets_start: PASS (movabs -> _start at $xsb_sfn + $xsb_ss5)"
else
    echo "FAIL: stub_x86_movabs_targets_start ($xsb_why5)"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_xsb_d_$$ /tmp/krc_xsb_e_$$

# 6. --load-addr REACHES THE GUEST, which is the opposite of the arm64 rule.
#    An arm64 image is fully PC-relative and must be byte-identical at two
#    addresses; the x86 trampoline necessarily materialises absolute addresses
#    (the multiboot header's three, lgdtl's operand, the far jump's target, the
#    gdtr base and the entry), so the two builds must DIFFER and each must
#    validate against its own address.
TOTAL=$((TOTAL + 1))
xsb_rf=$(xsb_build "$XSB_SRC" /tmp/krc_xsb_f_$$ $XSB_LOAD  --stack-top=$XSB_SP); xsb_stf=$?
xsb_rg=$(xsb_build "$XSB_SRC" /tmp/krc_xsb_g_$$ $XSB_LOAD2 --stack-top=$XSB_SP); xsb_stg=$?
xsb_ff=$(xsb_check /tmp/krc_xsb_f_$$ "$XSB_LOAD"  "$XSB_SP"); xsb_crcf=$?
xsb_fg=$(xsb_check /tmp/krc_xsb_g_$$ "$XSB_LOAD2" "$XSB_SP"); xsb_crcg=$?
if [ $xsb_stf -ne 0 ] || [ $xsb_stg -ne 0 ]; then
    xsb_why6="build failed ($XSB_LOAD exit=$xsb_stf, $XSB_LOAD2 exit=$xsb_stg)"
elif [ $xsb_crcf -ne 0 ] || [ "${xsb_ff#stub_size=}" = "$xsb_ff" ]; then
    xsb_why6="at $XSB_LOAD: ${xsb_ff:-no facts, exit=$xsb_crcf -- the check never ran}"
elif [ $xsb_crcg -ne 0 ] || [ "${xsb_fg#stub_size=}" = "$xsb_fg" ]; then
    xsb_why6="at $XSB_LOAD2: ${xsb_fg:-no facts, exit=$xsb_crcg -- the check never ran}"
elif [ "$xsb_ff" != "$xsb_fg" ]; then
    xsb_why6="the two builds disagree on layout ('$xsb_ff' vs '$xsb_fg'); only the ADDRESSES should change"
elif cmp -s /tmp/krc_xsb_f_$$ /tmp/krc_xsb_g_$$; then
    xsb_why6="the $XSB_LOAD and $XSB_LOAD2 images are BYTE-IDENTICAL -- --load-addr never reached the stub"
else
    xsb_why6=""
fi
if [ -z "$xsb_why6" ]; then
    PASS=$((PASS + 1)); echo "  stub_x86_load_addr_reaches_the_image: PASS ($XSB_LOAD and $XSB_LOAD2 each validate against their own address)"
else
    echo "FAIL: stub_x86_load_addr_reaches_the_image ($xsb_why6)"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_xsb_f_$$ /tmp/krc_xsb_g_$$

# 7-9. THE TRAMPOLINE'S PRECONDITIONS ARE HARD AND WERE UNCHECKED (review I3).
#      Page tables occupy physical 0x1000-0x4000; the identity map is a single
#      512-entry PD of 2 MiB pages, i.e. EXACTLY the first 1 GiB. Measured at
#      HEAD: --load-addr=0x2000 (the page-table build overwrites the image) and
#      --load-addr=0x50000000 (beyond the map) BOTH compiled clean and booted
#      silent. Each refusal is asserted with the three-clause pattern -- nonzero
#      exit, a diagnostic naming WHICH precondition failed, and NO artifact --
#      because any one of the three alone can hold while the build is broken.
xsb_refuse() {   # $1 label, $2 expected substring, $3... krc args
    local label="$1" want="$2"; shift 2
    TOTAL=$((TOTAL + 1))
    local out st art=/tmp/krc_xsb_r_$$
    rm -f "$art"
    out=$($KRC $KRC_FLAGS "$XSB_SRC" -o "$art" --arch=x86_64 --target=none \
             --emit=image "$@" 2>&1); st=$?
    if [ $st -eq 0 ]; then
        echo "FAIL: $label (exited 0 -- accepted, and a silent boot is the symptom)"; FAIL=$((FAIL + 1))
    elif ! echo "$out" | grep -qF -- "$want"; then   # -F -- : the wanted text
                                                     # STARTS WITH "--" and grep
                                                     # would read it as an option
        echo "FAIL: $label (refused, but the diagnostic does not name the precondition: '$(echo "$out" | head -c 160)')"; FAIL=$((FAIL + 1))
    elif [ -f "$art" ]; then
        echo "FAIL: $label (refused and diagnosed, but WROTE $art anyway)"; FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1)); echo "  $label: PASS (exit=$st, named the precondition, no artifact)"
    fi
    rm -f "$art"
}
xsb_refuse stub_x86_load_addr_refused_page_tables "identity-map page tables" \
    --load-addr=0x2000 --stack-top=$XSB_SP
# The two "1 GiB" refusals need DISCRIMINATING substrings: both messages say
# "1 GiB" (they are the same precondition seen from two flags), so grepping
# that alone would let the load-addr rule fire for a bad --stack-top, or vice
# versa, and both rows would still be green.
xsb_refuse stub_x86_load_addr_refused_above_map "--load-addr= must be below 0x40000000" \
    --load-addr=0x50000000 --stack-top=$XSB_SP
xsb_refuse stub_x86_stack_top_refused_above_map "--stack-top= must be at most 0x40000000" \
    --load-addr=$XSB_LOAD --stack-top=0x50000000

# 10. The stack must not start INSIDE the image. That check needs the file
#     size, so it runs at finalize -- and finalize is also where the `image:`
#     report is printed, so it has to run BEFORE the report or a refused build
#     still announces an artifact it never wrote.
xsb_refuse stub_x86_stack_top_refused_inside_image "inside the image" \
    --load-addr=$XSB_LOAD --stack-top=$((XSB_LOAD + 64))

# 11. The image's END must fit under the identity map too. This was the only
#     refusal in the branch with no row: --load-addr alone is bounded below
#     0x40000000, but a load address that fits can still carry an image that
#     runs past 1 GiB, and everything past it is unmapped the instant paging
#     comes on. Like row 10 this needs the FILE SIZE, so it fires at finalize
#     and ahead of the report.
#
#     0x3FFFFFF0 is sixteen bytes below the map's end and passes the argument-
#     time --load-addr bound, so this row cannot be that bound firing early;
#     any image at all overflows from there (the x86 trampoline alone is 226
#     bytes), which is what keeps the row from depending on XSB_SRC's size.
#     The stack top is below the load address, so row 10's rule is not what
#     refuses it either. The substring is the message's own opening -- the two
#     other "1 GiB" messages name a FLAG, this one names the IMAGE.
xsb_refuse stub_x86_image_end_refused_above_map "the image does not fit under the x86_64 self-boot trampoline's identity map" \
    --load-addr=0x3FFFFFF0 --stack-top=$XSB_SP

rm -f "$XSB_SRC" "$XSB_SRC2"

# --- syscall choke points under --target=none ------------------------------
# The per-OS dispatch in this codebase is "special-case Windows/macOS, else
# fall through to POSIX", so target_os == 4 (--target=none) silently inherits
# the LINUX path at ~60 branch sites. Rather than audit those by inspection --
# which is how a Linux syscall ends up inside a kernel image -- every arch
# routes its trap instruction through a single emitter that refuses there:
#   x86_64  SYSCALL 0F 05     -> emit_x86_syscall_insn  (src/codegen.kr)
#   arm64   SVC               -> emit_a64_svc_word      (src/codegen_aarch64.kr)
#   riscv32 ECALL 0x00000073  -> rv_ecall               (src/ir_riscv.kr)
#   xtensa  SIMCALL           -> xt_simcall             (src/ir_xtensa.kr)
# Guarding the emitter is strictly stronger than scanning the artifact: a
# freestanding image has NO ELF SECTIONS at all to scan ("There are no
# sections in this file"), the guard covers paths no corpus reaches, and it
# cannot be fooled by data that happens to encode a trap instruction.
echo ""
echo "--- syscall choke points under --target=none ---"
CP_SRC="/tmp/krc_choke_$$.kr"
printf 'fn main() { exit(0) }\n' > "$CP_SRC"
# Use the RAW compiler binary, not $KRC: under `make test` $KRC is a wrapper
# (Makefile:96) that unconditionally injects --arch=x86_64 ahead of every
# test's own arguments. --arch is last-wins today so the wrapper does not
# actually mask these cases, but relying on that is exactly the accident
# Task 1 hit; the raw binary keeps the invocation honest. Same build/krc2
# then build/krc3 fallback as the governance test above.
if [ -f "$DIR/../build/krc2" ]; then
    CP_KRC=$(cd "$DIR/../build" && pwd)/krc2
elif [ -f "$DIR/../build/krc3" ]; then
    CP_KRC=$(cd "$DIR/../build" && pwd)/krc3
else
    CP_KRC=""
fi
for A in x86_64 arm64; do
    TOTAL=$((TOTAL + 1))
    CP_ERR=$("$CP_KRC" --arch=$A --target=none "$CP_SRC" -o /tmp/krc_choke_bin_$$ 2>&1); CP_ST=$?
    if [ -n "$CP_KRC" ] && [ "$CP_ST" != "0" ] && echo "$CP_ERR" | grep -q "no operating system"; then
        PASS=$((PASS + 1)); echo "  choke_point_$A: PASS"
    else
        echo "FAIL: choke_point_$A (exit $CP_ST: '$CP_ERR')"; FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_choke_bin_$$
done

# x86_64 has TWO backends and both emit 0F 05: the IR backend (src/ir.kr,
# default) and the legacy direct codegen (src/codegen.kr), which --legacy,
# --emit=obj and --emit=lkm all route through. Before the shared choke point
# existed, `--legacy --target=none` and `--emit=obj --target=none` both
# compiled cleanly and put `mov eax,231; syscall` in a bare-metal artifact.
#
# --legacy is no longer in this list because Task 6 refuses it at flag
# validation under --target=none (asserted by t6_legacy_tnone_* above).
# --emit=obj is: it reaches the SAME src/codegen.kr and
# src/codegen_aarch64.kr dispatch on both arches -- x86_64 through the
# `emit_mode != 3` guard at src/main.kr:2611 and arm64 through the one at
# :2621 -- so retargeting these assertions onto it keeps every legacy
# bare-metal guard live and tested rather than turning them into unreachable
# code with no coverage. That is also why --emit=obj is ALLOWED on bare metal
# and --legacy is not: dropping both would have deleted this block.
for CP_FLAG in --emit=obj; do
    TOTAL=$((TOTAL + 1))
    CP_ERR=$("$CP_KRC" $CP_FLAG --arch=x86_64 --target=none "$CP_SRC" -o /tmp/krc_choke_bin_$$ 2>&1); CP_ST=$?
    CP_NAME=$(echo "$CP_FLAG" | tr -d '-' | tr '=' '_')
    if [ -n "$CP_KRC" ] && [ "$CP_ST" != "0" ] && echo "$CP_ERR" | grep -q "no operating system"; then
        PASS=$((PASS + 1)); echo "  choke_point_x86_$CP_NAME: PASS"
    else
        echo "FAIL: choke_point_x86_$CP_NAME (exit $CP_ST: '$CP_ERR')"; FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_choke_bin_$$
done

# The IR backend's builtins now refuse at their LOWERING (Task 3), so on that
# path they never reach the trap emitter and the emitter's name-plumbing is no
# longer what a user sees. It still has to WORK, though -- the legacy backend
# reaches it for real, and the IR emitter guard remains the backstop for any
# lowering that gets added without a --target=none arm. Assert it through
# --emit=obj, which has its own builtin dispatch in src/codegen.kr and does
# not go through ir_lower_expr at all.
#
# This block asserted through --legacy until Task 6 refused that flag under
# --target=none. --emit=obj reaches the identical src/codegen.kr dispatch and
# the identical emitter, so the assertion is unchanged in substance -- it is
# the same bytes, requested by a different flag. Keeping --emit=obj legal on
# bare metal is what makes that true; had both flags been refused, this whole
# block would have become unreachable and the emitter's name plumbing would
# have no coverage on any path at all.
#
# This is not free: IR_SYSCALL carries the canonical Linux syscall NUMBER, and
# that number is many-to-one with builtins (nr 1 is
# write/print/println/print_str/println_str/file_write; nr 0 is read and
# file_read; nr 8 is file_size twice), so a regression to the coarse "syscall"
# label -- or a cross-wired name, which is worse -- must fail here.
# println_str and time_ns are deliberately absent. The legacy backend shares
# ONE lowering for print_str/println_str (src/codegen.kr:6405) and names it
# "print_str" for both, and its time_ns() body reaches the emitter through the
# surrounding exit() first -- so asserting either name here would be asserting
# something untrue. Both builtins ARE covered, on both arches, by the
# target_none_audit_* block below, which tests the IR lowering.
#
# Task 6 revisited the "legacy backend naming" question left open here and
# left the case list as it stands: print_str/println_str share one legacy
# lowering (so one name for two builtins is the truth, not a defect), and the
# print family never reaches this emitter at all any more -- Task 5's legacy
# refusal fires first, asserted by provider_legacy_* below.
CP_CASE_NAMES="exit write print_str file_open file_close file_write file_read file_size"
for CP_B in $CP_CASE_NAMES; do
    case $CP_B in
        exit)        CP_BODY='exit(0)';;
        write)       CP_BODY='write(1, "x", 1)';;
        print_str)   CP_BODY='print_str("x")';;
        file_open)   CP_BODY='uint64 f = file_open("x", 0) exit(f)';;
        file_close)  CP_BODY='file_close(3)';;
        file_write)  CP_BODY='file_write(3, "x", 1)';;
        file_read)   CP_BODY='uint64 n = file_read(3, 4096, 1) exit(n)';;
        file_size)   CP_BODY='uint64 s = file_size(3) exit(s)';;
    esac
    printf 'fn main() { %s }\n' "$CP_BODY" > "$CP_SRC"
    TOTAL=$((TOTAL + 1))
    CP_ERR=$("$CP_KRC" --emit=obj --arch=x86_64 --target=none "$CP_SRC" -o /tmp/krc_choke_bin_$$ 2>&1)
    if echo "$CP_ERR" | grep -q "reached the emitter from '$CP_B'"; then
        PASS=$((PASS + 1)); echo "  choke_point_names_${CP_B}_obj: PASS"
    else
        echo "FAIL: choke_point_names_${CP_B}_obj (got '$CP_ERR')"; FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_choke_bin_$$
done
printf 'fn main() { exit(0) }\n' > "$CP_SRC"

# The diagnostic must not be TRUNCATED. Every write() in the refusal path
# derives its length with str_len() rather than a hand-counted literal,
# because a wrong count truncates the one message that explains a silent
# syscall -- and a tree-wide scan finds 30 pre-existing write(fd,"lit",N)
# sites whose N does not match the literal. Assert on the wire: the last
# characters of the message must survive to stderr. Via --emit=obj for the
# same reason as the block above: the IR path refuses earlier now, and
# --legacy is refused at flag validation.
TOTAL=$((TOTAL + 1))
CP_ERR=$("$CP_KRC" --emit=obj --arch=arm64 --target=none "$CP_SRC" -o /tmp/krc_choke_bin_$$ 2>&1)
if echo "$CP_ERR" | grep -q "before it can be used in a freestanding image\.$"; then
    PASS=$((PASS + 1)); echo "  choke_point_diag_not_truncated: PASS"
else
    echo "FAIL: choke_point_diag_not_truncated (message ends early: '$CP_ERR')"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_choke_bin_$$

# The enumeration itself, made permanent. Sites were enumerated by EMITTED
# BYTES, not by source pattern: an earlier draft of this work said "the 5
# 0F 05 emitters in ir.kr" when the real tree-wide count was 73 (61 in
# codegen.kr, 12 in ir.kr) plus 7 raw arm64 SVC words that bypassed
# emit_a64_svc entirely. A plan that names N sites is wrong the moment N is
# wrong and the miss is a silent syscall, so assert instead that the raw
# encodings appear ONLY in their choke-point helper. Any future patch that
# open-codes a trap instruction fails here.
TOTAL=$((TOTAL + 1))
CP_BAD=$(SRCDIR="$DIR/../src" python3 - <<'CPPY'
import re, os, glob
src = os.environ["SRCDIR"]
bad = []

# x86_64 SYSCALL: build the stream of emit_byte(<literal>) calls per file in
# source order and report every ADJACENT (0x0F, 0x05) pair. This is the
# emitted-bytes enumeration, not a source-pattern grep: it sees the one-line
# `emit_byte(0x0F); emit_byte(0x05)` form and the two-line form alike, and it
# does not false-positive on 0x0F followed by an unrelated byte.
BYTE = re.compile(r"emit_byte\(\s*(0x[0-9A-Fa-f]+|\d+)\s*\)")
val = lambda s: int(s, 16) if s.lower().startswith("0x") else int(s)
x86 = []
for path in sorted(glob.glob(os.path.join(src, "*.kr"))):
    stream = []
    for ln, line in enumerate(open(path), 1):
        for m in BYTE.finditer(line.split("//")[0]):
            stream.append((ln, val(m.group(1))))
    for i in range(len(stream) - 1):
        if stream[i][1] == 0x0F and stream[i + 1][1] == 0x05:
            x86.append("%s:%d" % (os.path.basename(path), stream[i][0]))
# Exactly one: emit_x86_syscall_insn's own body in codegen.kr.
if len(x86) != 1 or not x86[0].startswith("codegen.kr:"):
    bad.append("x86 SYSCALL emitted at %s (want exactly 1, inside emit_x86_syscall_insn)" % x86)

# arm64 SVC words. Every occurrence must be an argument to emit_a64_svc_word,
# the inline-asm assembler (which builds the word from a parsed immediate), or
# the disassembler's lookup table -- never a bare emit_a64(<svc word>).
a64 = []
for path in sorted(glob.glob(os.path.join(src, "*.kr"))):
    for ln, line in enumerate(open(path), 1):
        if re.search(r"0xD400[01]001", line) and re.search(r"emit_a64\(\s*0xD400[01]001", line):
            a64.append("%s:%d" % (os.path.basename(path), ln))
# codegen.kr's `asm { "svc #N" }` assembler is the one permitted bare emit_a64.
a64 = [h for h in a64 if not h.startswith("codegen.kr:")]
if a64:
    bad.append("arm64 SVC emitted outside emit_a64_svc_word at %s" % a64)

# riscv32 ECALL and xtensa SIMCALL: exactly one emission of each word.
def count(pat):
    n = 0
    for path in sorted(glob.glob(os.path.join(src, "*.kr"))):
        n += len(re.findall(pat, open(path).read()))
    return n
n = count(r"emit_u32_le\(0x00000073\)")
if n != 1:
    bad.append("riscv32 ECALL emitted %d times (want 1, inside rv_ecall)" % n)
n = count(r"xt_rrr\(0, 0, 1, 5, 0, 0\)")
if n != 1:
    bad.append("xtensa SIMCALL emitted %d times (want 1, inside xt_simcall)" % n)

print("; ".join(bad))
CPPY
)
if [ -z "$CP_BAD" ]; then
    PASS=$((PASS + 1)); echo "  choke_point_single_emitter: PASS"
else
    echo "FAIL: choke_point_single_emitter (raw trap encodings outside the helper:$CP_BAD)"
    FAIL=$((FAIL + 1))
fi

# The xtensa guard must NOT fire for exit(). ir_xtensa.kr ships a working
# bare-metal exit() through qemu lx60 semihosting (SIMCALL) and the spec
# preserves it deliberately, so the gate is on the reaching builtin, not on
# the instruction. A blanket SIMCALL refusal would break this by design.
# riscv32 likewise lowers a freestanding exit() to the sifive_test MMIO
# device, emitting no ECALL at all -- so neither arch may refuse here.
for A in riscv32 xtensa; do
    TOTAL=$((TOTAL + 1))
    CP_ERR=$("$CP_KRC" --arch=$A --target=none "$CP_SRC" -o /tmp/krc_choke_bin_$$ 2>&1); CP_ST=$?
    if [ "$CP_ST" = "0" ] && [ -f /tmp/krc_choke_bin_$$ ]; then
        PASS=$((PASS + 1)); echo "  choke_point_${A}_exit_still_allowed: PASS"
    else
        echo "FAIL: choke_point_${A}_exit_still_allowed (exit $CP_ST: '$CP_ERR')"; FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_choke_bin_$$
done
rm -f "$CP_SRC"

# --- --target=none refusals are builtin-specific (the fall-through audit) ---
#
# The per-OS dispatch across the IR backends is "special-case Windows/macOS,
# else fall through to POSIX", so target_os == 4 silently INHERITED the Linux
# path at ~60 branch sites. Task 2's emitter guards catch every one of those
# that emits a trap instruction. This block is the audit's own gate, and it
# asserts three things the emitter guards cannot:
#
#   1. NON-ZERO EXIT and NO ARTIFACT. Named first because the obvious way to
#      write this test is vacuous: a PASS condition of "the generic
#      choke-point message is absent" is also satisfied by a syntax error, a
#      missing file, or an unrecognised flag.
#   2. The diagnostic NAMES THE BUILTIN THE PROGRAMMER WROTE. print/println
#      allocate a formatting buffer before writing, so the emitter guard named
#      `alloc` for a program containing no alloc().
#   3. The generic choke-point message is ABSENT -- reaching it means a
#      lowering has no --target=none arm and only the backstop caught it.
#
# Every program stores its result to a static so the call is unambiguously
# live. That is belt-and-braces, NOT a workaround for a known pruning bug:
# verified at 563b0f3 that `uint64 p = alloc(64)  loop { }` refuses correctly
# with `p` unused, on both arches. An earlier draft of this block claimed dead-
# code elimination was deleting such calls; that was wrong, and the way it was
# wrong is worth keeping. The claim came from a scratch harness that piped the
# compiler through `head -4`. Warnings print a four-line block (message, source
# line, caret, blank) and the refusal lands on line 6, so the harness silently
# cut off the very diagnostic it was testing for and the programs looked clean.
# If you are ever about to conclude "the compiler did not diagnose this", print
# the WHOLE output first.
echo ""
echo "--- --target=none refusals are builtin-specific ---"
AU_D=$(mktemp -d)
au_gen() { printf 'static uint64 sink = 0\nfn main() {\n    %s\n    loop { }\n}\n' "$2" > "$AU_D/a_$1.kr"; }
au_gen exit             'exit(0)'
au_gen write            'sink = write(1, "x", 1)'
au_gen read             'sink = read(0, sink, 1)'
au_gen print            'print(1)'
au_gen println          'println(1)'
au_gen print_str        'print_str("x")'
au_gen println_str      'println_str("x")'
au_gen alloc            'sink = alloc(64)'
au_gen dealloc          'dealloc(sink)'
au_gen time_ns          'sink = time_ns()'
au_gen file_open        'sink = file_open("x", 0)'
au_gen file_close       'sink = file_close(3)'
au_gen file_read        'sink = file_read(3, sink, 1)'
au_gen file_write       'sink = file_write(3, "x", 1)'
au_gen file_size        'sink = file_size(3)'
au_gen set_executable   'sink = set_executable("x")'
au_gen exec_process     'sink = exec_process("x")'
au_gen exec_process_argv 'sink = exec_process_argv("x", sink)'
au_gen syscall_raw      'sink = syscall_raw(60, 0, 0, 0, 0, 0, 0)'
for A in x86_64 arm64; do
    for AU_F in "$AU_D"/a_*.kr; do
        AU_B=$(basename "$AU_F" .kr); AU_B=${AU_B#a_}
        AU_OUT="/tmp/krc_au_$$"
        TOTAL=$((TOTAL + 1))
        rm -f "$AU_OUT"
        AU_ERR=$("$CP_KRC" --arch=$A --target=none "$AU_F" -o "$AU_OUT" 2>&1); AU_ST=$?
        if [ "$AU_ST" = "0" ]; then
            echo "FAIL: audit_${AU_B}_$A (compiled CLEAN under --target=none -- a fall-through site was missed)"
            FAIL=$((FAIL + 1))
        elif echo "$AU_ERR" | grep -q "reached the emitter"; then
            echo "FAIL: audit_${AU_B}_$A (generic choke-point message -- the lowering has no --target=none arm)"
            FAIL=$((FAIL + 1))
        elif ! echo "$AU_ERR" | grep -q "error: --target=none: '$AU_B' is not available on bare metal"; then
            echo "FAIL: audit_${AU_B}_$A (refusal does not name '$AU_B': '$AU_ERR')"
            FAIL=$((FAIL + 1))
        elif [ -f "$AU_OUT" ]; then
            echo "FAIL: audit_${AU_B}_$A (refused but still wrote an artifact)"
            FAIL=$((FAIL + 1))
        else
            PASS=$((PASS + 1)); echo "  audit_${AU_B}_$A: PASS"
        fi
        rm -f "$AU_OUT"
    done
done

# The refusal must be ACTIONABLE, not just specific: it names what to do
# instead. exit() is the case with a concrete replacement, and the message is
# checked to its final character so a hand-counted write() length (the defect
# 563b0f3 fixed 30 of) cannot truncate the advice off the end.
TOTAL=$((TOTAL + 1))
AU_ERR=$("$CP_KRC" --arch=x86_64 --target=none "$AU_D/a_exit.kr" -o /tmp/krc_au_$$ 2>&1)
if echo "$AU_ERR" | grep -q "end main with \`loop { }\` instead -- there is no parent process to return a status to$"; then
    PASS=$((PASS + 1)); echo "  audit_refusal_is_actionable: PASS"
else
    echo "FAIL: audit_refusal_is_actionable (got '$AU_ERR')"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_au_$$

# @builtin_override must WIN over the refusal. Every check above sits inside
# an `if skip_builtin == 0 && tok_matches(...)` arm, i.e. after
# builtin_override_lookup, so a program that supplies its own println never
# reaches the refusal. This is the mechanism Task 5's bare-metal driver
# modules are built on: if this test fails, --target=none has no escape and
# the whole target is unusable rather than merely restricted.
TOTAL=$((TOTAL + 1))
cat > "$AU_D/ov.kr" <<'AUEOF'
static uint64 uart = 0x10000000
@builtin_override
fn println(uint64 v) -> uint64 {
    unsafe { *(uart as uint8) = 65 }
    return 0
}
fn main() { println(7)  loop { } }
AUEOF
rm -f /tmp/krc_au_ov_$$
AU_ERR=$("$CP_KRC" --arch=x86_64 --target=none "$AU_D/ov.kr" -o /tmp/krc_au_ov_$$ 2>&1); AU_ST=$?
if [ "$AU_ST" = "0" ] && [ -f /tmp/krc_au_ov_$$ ]; then
    PASS=$((PASS + 1)); echo "  audit_builtin_override_beats_refusal: PASS"
else
    echo "FAIL: audit_builtin_override_beats_refusal (exit $AU_ST: '$AU_ERR')"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_au_ov_$$

# A program that touches no OS builtin must still COMPILE under --target=none,
# and the artifact must contain no trap instruction. Without this the whole
# block above is satisfiable by refusing everything.
TOTAL=$((TOTAL + 1))
cat > "$AU_D/pos.kr" <<'AUEOF'
static uint64 counter = 0
fn add(uint64 a, uint64 b) -> uint64 { return a + b }
fn main() {
    uint64 i = 0
    while i < 10 { counter = add(counter, i)  i = i + 1 }
    loop { }
}
AUEOF
AU_POS_OK=1
for A in x86_64 arm64; do
    rm -f /tmp/krc_au_pos_$$
    "$CP_KRC" --arch=$A --target=none "$AU_D/pos.kr" -o /tmp/krc_au_pos_$$ >/dev/null 2>&1 \
        || AU_POS_OK=0
    [ -f /tmp/krc_au_pos_$$ ] || AU_POS_OK=0
done
if [ "$AU_POS_OK" = "1" ]; then
    PASS=$((PASS + 1)); echo "  audit_builtin_free_program_compiles: PASS"
else
    echo "FAIL: audit_builtin_free_program_compiles (a program using no OS builtin was rejected)"; FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_au_pos_$$

# THE LEGACY BACKEND IS NOT COVERED BY THE BLOCK ABOVE. --legacy and
# --emit=obj have their own builtin dispatch in src/codegen.kr /
# src/codegen_aarch64.kr and never call ir_lower_expr, so every refusal added
# to the IR lowering misses them entirely.
#
# time_ns is the case that proves it and the reason this block exists: its
# legacy chain ended in `else { mov rax/x0, 0 }`, so all four of
# {--legacy, --emit=obj} x {x86_64, arm64} compiled clean at exit 0 and WROTE
# AN ARTIFACT containing a constant zero where a timestamp belongs. No trap
# instruction, so the emitter guard could not see it; no ir_lower_expr, so the
# lowering refusal did not run. A silent wrong answer that ships.
#
# --legacy left this list in Task 6, which refuses it at flag validation under
# --target=none (t6_legacy_tnone_*). --emit=obj reaches the SAME
# src/codegen.kr / src/codegen_aarch64.kr dispatch on both arches, so the
# `else { mov rax/x0, 0 }` regression this test exists to catch is still
# caught on the identical code path -- nothing about the legacy time_ns
# coverage is lost by the refusal.
for AU_FLAG in --emit=obj; do
    for A in x86_64 arm64; do
        TOTAL=$((TOTAL + 1))
        AU_OUT="/tmp/krc_au_lg_$$"
        rm -f "$AU_OUT"
        AU_ERR=$("$CP_KRC" $AU_FLAG --arch=$A --target=none "$AU_D/a_time_ns.kr" -o "$AU_OUT" 2>&1); AU_ST=$?
        AU_TAG=$(echo "$AU_FLAG" | tr -d '-' | tr '=' '_')
        if [ "$AU_ST" != "0" ] && [ ! -f "$AU_OUT" ] \
           && echo "$AU_ERR" | grep -q "error: --target=none: 'time_ns' is not available on bare metal"; then
            PASS=$((PASS + 1)); echo "  audit_time_ns_${AU_TAG}_$A: PASS"
        else
            echo "FAIL: audit_time_ns_${AU_TAG}_$A (exit $AU_ST, artifact=$([ -f "$AU_OUT" ] && echo yes || echo no): '$AU_ERR')"
            FAIL=$((FAIL + 1))
        fi
        rm -f "$AU_OUT"
    done
done

# The refusals are keyed on target_os == 4 ONLY. Plain --freestanding on
# riscv32/xtensa keeps its pre-existing "IR op N not yet implemented" refusal
# unchanged -- that is a byte-identity constraint from the plan ("write/alloc
# stay refused on riscv32/xtensa"), and it is the check that the new arms did
# not leak into a target that was already working.
for A in riscv32 xtensa; do
    TOTAL=$((TOTAL + 1))
    printf 'static uint32 sink = 0\nfn main() {\n    sink = write(1, "x", 1)\n    loop { }\n}\n' > "$AU_D/fs.kr"
    AU_ERR=$("$CP_KRC" --arch=$A --freestanding "$AU_D/fs.kr" -o /tmp/krc_au_fs_$$ 2>&1)
    if echo "$AU_ERR" | grep -q "$A: IR op 52 not yet implemented"; then
        PASS=$((PASS + 1)); echo "  audit_${A}_freestanding_unchanged: PASS"
    else
        echo "FAIL: audit_${A}_freestanding_unchanged (got '$AU_ERR')"; FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/krc_au_fs_$$
done
rm -rf "$AU_D"

# --- --target=none @builtin_override providers ------------------------------
#
# Everything above this point REFUSES. This block is where bare-metal code
# first gets to do something: std/uart_16550.kr and std/uart_pl011.kr supply
# `write`, std/heap_bump.kr supplies `alloc`/`dealloc`, and importing one is
# the whole of the user-visible change.
#
# `println` is ITS OWN BUILTIN (src/ir.kr) emitting IR_ALLOC + IR_SYSCALL
# directly -- it does not call the `write` builtin. So an `@builtin_override
# fn write` does not reroute it on its own, and a stdlib-only version of this
# work would ship permanently red. The routing lives in the compiler: under
# target_os == 4 the print/println/print_str/println_str lowerings resolve
# their output through the same override lookup `write` uses, so one provider
# serves all four plus `write` itself.
#
# THE ASSERTIONS ARE ON THE ARTIFACT AND ON THE IR, NEVER ON EXIT CODE ALONE.
# A bare-metal image cannot be run here, and "krc exited 0" is satisfied by a
# compiler that quietly emitted nothing at all. Three independent legs:
#   * --emit=ir: `main` must contain a `call` and NO `syscall` and NO `alloc`.
#     Arch-neutral and decisive -- it names the mechanism, not a side effect.
#   * objdump (x86_64): the bytes must contain `out %al,(%dx)`, i.e. the UART
#     store itself, absent from the same program built without the print.
#   * size: the import-only build must be SMALLER, i.e. DCE really did prune
#     the provider when nothing reached it, so its presence above is caused by
#     the print and is not the seed keeping it alive unconditionally.
echo ""
echo "--- --target=none @builtin_override providers ---"
#
# The test programs live in a directory INSIDE the repo and import
# "../std/...": imports resolve relative to the importing file's own
# directory, then against the INSTALLED stdlib. A program in /tmp importing
# "std/uart_16550.kr" would therefore either fail to resolve or silently pick
# up whatever ~/.local/share/kernrift/std happens to contain, which is not the
# tree under test.
PV_D=$(mktemp -d "$DIR/../krc_pv_XXXXXX")
# Raw compiler binary, not $KRC: under `make test` $KRC is a wrapper that
# injects --arch=x86_64 ahead of every argument (Makefile), and the --arch and
# --target combinations below have to be exactly what is written here.
if [ -f "$DIR/../build/krc2" ]; then
    PV_KRC=$(cd "$DIR/../build" && pwd)/krc2
elif [ -f "$DIR/../build/krc3" ]; then
    PV_KRC=$(cd "$DIR/../build" && pwd)/krc3
else
    PV_KRC=""
fi

pv_mod() {
    if [ "$1" = "x86_64" ]; then echo "../std/uart_16550.kr"; else echo "../std/uart_pl011.kr"; fi
}

# Each of the four print builtins, plus write() itself, must reach the
# provider. They are separate lowerings with separate syscall sites; covering
# only println would leave three of them refusing.
for A in x86_64 arm64; do
    PV_M=$(pv_mod "$A")
    pv_i=0
    for PV_CALL in 'println("hi", 7)' 'print("hi", 7)' 'println_str("hi")' 'print_str("hi")' 'write(1, "hi", 2)'; do
        pv_i=$((pv_i + 1))
        TOTAL=$((TOTAL + 1))
        printf 'import "%s"\nfn main() {\n    %s\n    loop { }\n}\n' "$PV_M" "$PV_CALL" > "$PV_D/r.kr"
        rm -f "$PV_D/r.out"
        PV_ERR=$("$PV_KRC" --arch=$A --target=none "$PV_D/r.kr" -o "$PV_D/r.out" 2>&1); PV_ST=$?
        PV_IR=$("$PV_KRC" --arch=$A --target=none --emit=ir "$PV_D/r.kr" 2>&1)
        if [ "$PV_ST" != "0" ] || [ ! -f "$PV_D/r.out" ]; then
            echo "FAIL: provider_route_${pv_i}_$A (exit $PV_ST, no artifact: '$PV_ERR')"; FAIL=$((FAIL + 1))
        elif echo "$PV_IR" | grep -q "syscall"; then
            echo "FAIL: provider_route_${pv_i}_$A (IR still contains a syscall -- the lowering was not rerouted)"; FAIL=$((FAIL + 1))
        elif echo "$PV_IR" | grep -q "= alloc"; then
            echo "FAIL: provider_route_${pv_i}_$A (IR still contains IR_ALLOC -- the formatting buffer is still a heap call)"; FAIL=$((FAIL + 1))
        elif ! echo "$PV_IR" | grep -q "call @"; then
            echo "FAIL: provider_route_${pv_i}_$A (IR contains no call -- nothing reaches the provider)"; FAIL=$((FAIL + 1))
        else
            PASS=$((PASS + 1)); echo "  provider_route_${pv_i}_$A: PASS"
        fi
        rm -f "$PV_D/r.out"
    done
done

# DCE (R3). The provider is reached ONLY through override resolution during IR
# lowering; dce_scan runs on the AST and cannot see that edge, so without an
# explicit seed the body is pruned and the call resolves to nothing. Proven
# both ways: present when a print reaches it, ABSENT when nothing does. The
# second half is what stops the first being satisfied by a seed that keeps
# every override alive regardless.
for A in x86_64 arm64; do
    PV_M=$(pv_mod "$A")
    TOTAL=$((TOTAL + 1))
    printf 'import "%s"\nfn main() {\n    loop { }\n}\n' "$PV_M" > "$PV_D/n.kr"
    printf 'import "%s"\nfn main() {\n    println("hi")\n    loop { }\n}\n' "$PV_M" > "$PV_D/y.kr"
    rm -f "$PV_D/n.out" "$PV_D/y.out"
    "$PV_KRC" --arch=$A --target=none "$PV_D/n.kr" -o "$PV_D/n.out" >/dev/null 2>&1
    "$PV_KRC" --arch=$A --target=none "$PV_D/y.kr" -o "$PV_D/y.out" >/dev/null 2>&1
    if [ ! -f "$PV_D/n.out" ] || [ ! -f "$PV_D/y.out" ]; then
        echo "FAIL: provider_dce_$A (one of the two builds produced no artifact)"; FAIL=$((FAIL + 1))
    else
        PV_NS=$(wc -c < "$PV_D/n.out"); PV_YS=$(wc -c < "$PV_D/y.out")
        if [ "$PV_YS" -gt "$PV_NS" ]; then
            PASS=$((PASS + 1)); echo "  provider_dce_$A: PASS (import-only $PV_NS B, with println $PV_YS B)"
        else
            echo "FAIL: provider_dce_$A (println pulled in no provider body: $PV_NS B vs $PV_YS B)"; FAIL=$((FAIL + 1))
        fi
    fi
done

# The bytes themselves: the leg that proves the artifact contains the actual
# UART store rather than merely "some call". Asserted in BOTH directions so a
# disassembler that silently prints nothing cannot pass it.
#
# `command -v objdump` proves one is INSTALLED, not that it can decode x86.
# Ubuntu's binutils is built one target set per host arch: on an arm64 host
# /usr/bin/objdump knows aarch64 and nothing else, so `-m i386:x86-64` writes
# "can't use supplied machine i386:x86-64" to stderr (swallowed by 2>/dev/null),
# prints no instructions, and BOTH counts come back 0 -- which this assertion
# correctly reads as "the UART store is missing". That is the exact shape of
# the Linux ARM64 CI failure. So probe by DOING the disassembly on a lone 0xee
# byte and requiring the very pattern grepped for below; a tool that decodes
# x86 but spells the operand differently is rejected here rather than silently
# scoring 0 there. CI installs binutils-x86-64-linux-gnu on the arm64 runner so
# a capable one is always found; finding none is a FAILURE, never a skip.
TOTAL=$((TOTAL + 1))
# Whitespace-tolerant: objdump pads the mnemonic column and the width is not a
# stable interface. A literal "out    %al,(%dx)" with the exact run of spaces
# this binutils happens to emit would turn a formatting change in a future
# objdump into a silent 0 here, i.e. a check that reports the UART store is
# missing when it is present.
PV_PAT='out[[:space:]]+%al,\(%dx\)'
printf '\356' > "$PV_D/probe.bin"   # 0xee, the one-byte `out %al,(%dx)`
PV_OD=""
for PV_C in objdump x86_64-linux-gnu-objdump gobjdump x86_64-elf-objdump; do
    command -v "$PV_C" >/dev/null 2>&1 || continue
    if [ "$("$PV_C" -D -b binary -m i386:x86-64 "$PV_D/probe.bin" 2>/dev/null \
            | grep -cE "$PV_PAT")" -ge 1 ]; then
        PV_OD="$PV_C"; break
    fi
done
if [ -n "$PV_OD" ]; then
    printf 'import "../std/uart_16550.kr"\nfn main() {\n    loop { }\n}\n' > "$PV_D/n86.kr"
    printf 'import "../std/uart_16550.kr"\nfn main() {\n    println("hi")\n    loop { }\n}\n' > "$PV_D/y86.kr"
    rm -f "$PV_D/n86.out" "$PV_D/y86.out"
    "$PV_KRC" --arch=x86_64 --target=none "$PV_D/n86.kr" -o "$PV_D/n86.out" >/dev/null 2>&1
    "$PV_KRC" --arch=x86_64 --target=none "$PV_D/y86.kr" -o "$PV_D/y86.out" >/dev/null 2>&1
    PV_HAS=$("$PV_OD" -D -b binary -m i386:x86-64 "$PV_D/y86.out" 2>/dev/null | grep -cE "$PV_PAT")
    PV_NOT=$("$PV_OD" -D -b binary -m i386:x86-64 "$PV_D/n86.out" 2>/dev/null | grep -cE "$PV_PAT")
    if [ "$PV_HAS" -ge 1 ] && [ "$PV_NOT" = "0" ]; then
        PASS=$((PASS + 1)); echo "  provider_uart_store_in_bytes: PASS ($PV_HAS out instructions via $PV_OD, 0 without the println)"
    else
        echo "FAIL: provider_uart_store_in_bytes (with println: $PV_HAS, without: $PV_NOT, via $PV_OD)"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: provider_uart_store_in_bytes (no objdump on PATH can disassemble x86-64 -- install binutils-x86-64-linux-gnu; this leg is the artifact proof, not an optional extra)"
    FAIL=$((FAIL + 1))
fi

# Omitting the import must still refuse, and the refusal must NAME WHAT TO
# IMPORT. Checked to the final character: a hand-counted write() length would
# truncate the module names off the end, which is precisely the half of the
# message that makes it actionable.
for PV_B in println print println_str print_str write; do
    TOTAL=$((TOTAL + 1))
    case "$PV_B" in
        write) PV_C='sink = write(1, "x", 1)' ;;
        print_str|println_str) PV_C="$PV_B(\"x\")" ;;
        *) PV_C="$PV_B(1)" ;;
    esac
    printf 'static uint64 sink = 0\nfn main() {\n    %s\n    loop { }\n}\n' "$PV_C" > "$PV_D/no.kr"
    rm -f "$PV_D/no.out"
    PV_ERR=$("$PV_KRC" --arch=x86_64 --target=none "$PV_D/no.kr" -o "$PV_D/no.out" 2>&1); PV_ST=$?
    if [ "$PV_ST" = "0" ] || [ -f "$PV_D/no.out" ]; then
        echo "FAIL: provider_missing_refuses_$PV_B (compiled with no provider)"; FAIL=$((FAIL + 1))
    elif ! echo "$PV_ERR" | grep -q "error: --target=none: '$PV_B' is not available on bare metal"; then
        echo "FAIL: provider_missing_refuses_$PV_B (refusal does not name '$PV_B': '$PV_ERR')"; FAIL=$((FAIL + 1))
    elif ! echo "$PV_ERR" | grep -q 'import "std/uart_16550.kr" (x86_64 COM1) or "std/uart_pl011.kr" (arm64 PL011), or drop the call$'; then
        echo "FAIL: provider_missing_refuses_$PV_B (refusal does not name what to import: '$PV_ERR')"; FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1)); echo "  provider_missing_refuses_$PV_B: PASS"
    fi
    rm -f "$PV_D/no.out"
done

# heap_bump: alloc/dealloc through the same mechanism. The IR must show a call
# and no IR_ALLOC/IR_DEALLOC -- an alloc that stayed an IR_ALLOC is an mmap
# that the emitter guard would then refuse.
for A in x86_64 arm64; do
    TOTAL=$((TOTAL + 1))
    cat > "$PV_D/hb.kr" <<'PVEOF'
import "../std/heap_bump.kr"
fn main() {
    heap_bump_init(0x200000, 0x100000)
    uint64 p = alloc(64)
    store64(p, 7)
    dealloc(p)
    loop { }
}
PVEOF
    rm -f "$PV_D/hb.out"
    PV_ERR=$("$PV_KRC" --arch=$A --target=none "$PV_D/hb.kr" -o "$PV_D/hb.out" 2>&1); PV_ST=$?
    PV_IR=$("$PV_KRC" --arch=$A --target=none --emit=ir "$PV_D/hb.kr" 2>&1)
    if [ "$PV_ST" != "0" ] || [ ! -f "$PV_D/hb.out" ]; then
        echo "FAIL: provider_heap_bump_$A (exit $PV_ST: '$PV_ERR')"; FAIL=$((FAIL + 1))
    elif echo "$PV_IR" | grep -qE "= alloc|dealloc v"; then
        echo "FAIL: provider_heap_bump_$A (IR still contains IR_ALLOC/IR_DEALLOC)"; FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1)); echo "  provider_heap_bump_$A: PASS"
    fi
    rm -f "$PV_D/hb.out"
done

# Both providers in one program: a UART for output and a bump heap for
# storage is the shape a real bare-metal program has, and nothing about
# registering two overrides may interfere with either.
for A in x86_64 arm64; do
    PV_M=$(pv_mod "$A")
    TOTAL=$((TOTAL + 1))
    printf 'import "%s"\nimport "../std/heap_bump.kr"\nfn main() {\n    heap_bump_init(0x200000, 0x100000)\n    uint64 p = alloc(32)\n    store64(p, 5)\n    println("v=", load64(p))\n    dealloc(p)\n    loop { }\n}\n' "$PV_M" > "$PV_D/both.kr"
    rm -f "$PV_D/both.out"
    PV_ERR=$("$PV_KRC" --arch=$A --target=none "$PV_D/both.kr" -o "$PV_D/both.out" 2>&1); PV_ST=$?
    if [ "$PV_ST" = "0" ] && [ -f "$PV_D/both.out" ]; then
        PASS=$((PASS + 1)); echo "  provider_uart_plus_heap_$A: PASS"
    else
        echo "FAIL: provider_uart_plus_heap_$A (exit $PV_ST: '$PV_ERR')"; FAIL=$((FAIL + 1))
    fi
    rm -f "$PV_D/both.out"
done

# A provider is resolved BY NAME; its SHAPE has to be checked separately.
#
# The lowerings synthesise calls -- write(fd, buf, len), alloc(n) -- and a
# synthesised call is invisible to the AST-walking arity check in
# src/analysis.kr, because it does not exist in the AST. Measured before the
# check existed: a one-argument `@builtin_override fn write` compiled CLEAN on
# both arches at exit 0 with an artifact, while the compiler passed it three
# arguments. That is a silent ABI mismatch, and it is a check the override path
# SKIPS rather than one the language lacks -- a hand-written three-argument
# call against that same override is rejected today.
for A in x86_64 arm64; do
    TOTAL=$((TOTAL + 1))
    printf 'static uint64 sink = 0\n@builtin_override\nfn write(uint64 only_one) -> uint64 { sink = only_one  return 0 }\nfn main() {\n    println("hi")\n    loop { }\n}\n' > "$PV_D/ar.kr"
    rm -f "$PV_D/ar.out"
    PV_ERR=$("$PV_KRC" --arch=$A --target=none "$PV_D/ar.kr" -o "$PV_D/ar.out" 2>&1); PV_ST=$?
    if [ "$PV_ST" = "0" ] || [ -f "$PV_D/ar.out" ]; then
        echo "FAIL: provider_arity_write_$A (a 1-argument write provider took 3 synthesised arguments and compiled clean)"; FAIL=$((FAIL + 1))
    elif ! echo "$PV_ERR" | grep -q "provider declares 1 parameter(s), but print/println/print_str/println_str under --target=none lowers to 3-argument calls of it"; then
        echo "FAIL: provider_arity_write_$A (diagnostic does not state both counts: '$PV_ERR')"; FAIL=$((FAIL + 1))
    elif ! echo "$PV_ERR" | grep -q 'Declare it as `fn write(uint64 fd, uint64 buf, uint64 len) -> uint64`\.$'; then
        echo "FAIL: provider_arity_write_$A (diagnostic does not name the expected signature: '$PV_ERR')"; FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1)); echo "  provider_arity_write_$A: PASS"
    fi
    rm -f "$PV_D/ar.out"

    # Same blind spot on the allocator, and one step worse: the f-string
    # CONSUMES the result, so a VOID provider hands it whatever is in the
    # return register. Both the arity and the return type are checked.
    PV_M=$(pv_mod "$A")
    TOTAL=$((TOTAL + 1))
    printf 'import "%s"\n@builtin_override\nfn alloc(uint64 a, uint64 b) -> uint64 { return a + b }\nfn main() {\n    uint64 y = 5\n    println(f"x {y}")\n    loop { }\n}\n' "$PV_M" > "$PV_D/ar2.kr"
    rm -f "$PV_D/ar2.out"
    PV_ERR=$("$PV_KRC" --arch=$A --target=none "$PV_D/ar2.kr" -o "$PV_D/ar2.out" 2>&1); PV_ST=$?
    if [ "$PV_ST" = "0" ] || [ -f "$PV_D/ar2.out" ]; then
        echo "FAIL: provider_arity_alloc_$A (a 2-argument alloc provider took 1 synthesised argument and compiled clean)"; FAIL=$((FAIL + 1))
    elif ! echo "$PV_ERR" | grep -q "provider declares 2 parameter(s), but an f-string under --target=none lowers to 1-argument calls of it"; then
        echo "FAIL: provider_arity_alloc_$A (diagnostic does not state both counts: '$PV_ERR')"; FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1)); echo "  provider_arity_alloc_$A: PASS"
    fi
    rm -f "$PV_D/ar2.out"

    TOTAL=$((TOTAL + 1))
    printf 'import "%s"\nstatic uint64 hp = 0x200000\n@builtin_override\nfn alloc(uint64 n) { hp = hp + n }\nfn main() {\n    uint64 y = 5\n    println(f"x {y}")\n    loop { }\n}\n' "$PV_M" > "$PV_D/ar3.kr"
    rm -f "$PV_D/ar3.out"
    PV_ERR=$("$PV_KRC" --arch=$A --target=none "$PV_D/ar3.kr" -o "$PV_D/ar3.out" 2>&1); PV_ST=$?
    if [ "$PV_ST" = "0" ] || [ -f "$PV_D/ar3.out" ]; then
        echo "FAIL: provider_void_alloc_$A (a void alloc provider supplied the f-string's buffer address and compiled clean)"; FAIL=$((FAIL + 1))
    elif ! echo "$PV_ERR" | grep -q "provider returns nothing, but an f-string under --target=none uses its result"; then
        echo "FAIL: provider_void_alloc_$A (diagnostic does not say the result is consumed: '$PV_ERR')"; FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1)); echo "  provider_void_alloc_$A: PASS"
    fi
    rm -f "$PV_D/ar3.out"

    # A CORRECTLY shaped provider must still compile, or the three checks above
    # are satisfied by a compiler that refuses every override.
    TOTAL=$((TOTAL + 1))
    printf 'import "%s"\nimport "../std/heap_bump.kr"\nfn main() {\n    heap_bump_init(0x200000, 0x100000)\n    uint64 y = 5\n    println(f"x {y}")\n    loop { }\n}\n' "$PV_M" > "$PV_D/ar4.kr"
    rm -f "$PV_D/ar4.out"
    PV_ERR=$("$PV_KRC" --arch=$A --target=none "$PV_D/ar4.kr" -o "$PV_D/ar4.out" 2>&1); PV_ST=$?
    if [ "$PV_ST" = "0" ] && [ -f "$PV_D/ar4.out" ]; then
        PASS=$((PASS + 1)); echo "  provider_correct_shape_accepted_$A: PASS"
    else
        echo "FAIL: provider_correct_shape_accepted_$A (exit $PV_ST: '$PV_ERR')"; FAIL=$((FAIL + 1))
    fi
    rm -f "$PV_D/ar4.out"
done

# f-strings need the OTHER provider. An f-string's value is a pointer that may
# outlive the frame, so its buffer cannot become a stack slot the way print's
# formatting scratch does -- it stays a heap allocation and therefore needs
# std/heap_bump.kr as well as a UART. Asserted in both directions: refused with
# the UART alone, and NAMING 'f-string' rather than the 'alloc' the emitter
# backstop used to report for a program containing no alloc() at all.
for A in x86_64 arm64; do
    PV_M=$(pv_mod "$A")
    TOTAL=$((TOTAL + 1))
    printf 'import "%s"\nfn main() {\n    uint64 y = 5\n    println(f"x {y}")\n    loop { }\n}\n' "$PV_M" > "$PV_D/fs1.kr"
    rm -f "$PV_D/fs1.out"
    PV_ERR=$("$PV_KRC" --arch=$A --target=none "$PV_D/fs1.kr" -o "$PV_D/fs1.out" 2>&1); PV_ST=$?
    if [ "$PV_ST" = "0" ] || [ -f "$PV_D/fs1.out" ]; then
        echo "FAIL: provider_fstring_needs_alloc_$A (compiled with no allocator)"; FAIL=$((FAIL + 1))
    elif echo "$PV_ERR" | grep -q "reached the emitter"; then
        echo "FAIL: provider_fstring_needs_alloc_$A (generic choke-point message, and it names 'alloc' for a program with no alloc())"; FAIL=$((FAIL + 1))
    elif ! echo "$PV_ERR" | grep -q "error: --target=none: 'f-string' is not available on bare metal"; then
        echo "FAIL: provider_fstring_needs_alloc_$A (refusal does not name 'f-string': '$PV_ERR')"; FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1)); echo "  provider_fstring_needs_alloc_$A: PASS"
    fi
    rm -f "$PV_D/fs1.out"

    TOTAL=$((TOTAL + 1))
    printf 'import "%s"\nimport "../std/heap_bump.kr"\nfn main() {\n    heap_bump_init(0x200000, 0x100000)\n    uint64 y = 5\n    println(f"x {y}")\n    loop { }\n}\n' "$PV_M" > "$PV_D/fs2.kr"
    rm -f "$PV_D/fs2.out"
    PV_ERR=$("$PV_KRC" --arch=$A --target=none "$PV_D/fs2.kr" -o "$PV_D/fs2.out" 2>&1); PV_ST=$?
    PV_IR=$("$PV_KRC" --arch=$A --target=none --emit=ir "$PV_D/fs2.kr" 2>&1)
    if [ "$PV_ST" != "0" ] || [ ! -f "$PV_D/fs2.out" ]; then
        echo "FAIL: provider_fstring_with_alloc_$A (exit $PV_ST: '$PV_ERR')"; FAIL=$((FAIL + 1))
    elif echo "$PV_IR" | grep -qE "syscall|= alloc"; then
        echo "FAIL: provider_fstring_with_alloc_$A (IR still contains a syscall or IR_ALLOC)"; FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1)); echo "  provider_fstring_with_alloc_$A: PASS"
    fi
    rm -f "$PV_D/fs2.out"
done

# Import order must not matter. The risk is real and specific: a module that
# calls println and is PARSED BEFORE the provider module would see no
# registration yet if the routing decision were made during parsing. It is
# made during lowering, after every file is parsed, and this pins that.
cat > "$PV_D/user_mod.kr" <<'PVEOF'
fn greet_twice() {
    println("from the other module")
    print_str("and again\n")
}
PVEOF
for A in x86_64 arm64; do
    PV_M=$(pv_mod "$A")
    for PV_ORDER in first last; do
        TOTAL=$((TOTAL + 1))
        if [ "$PV_ORDER" = "first" ]; then
            printf 'import "%s"\nimport "user_mod.kr"\nfn main() {\n    greet_twice()\n    loop { }\n}\n' "$PV_M" > "$PV_D/ord.kr"
        else
            printf 'import "user_mod.kr"\nimport "%s"\nfn main() {\n    greet_twice()\n    loop { }\n}\n' "$PV_M" > "$PV_D/ord.kr"
        fi
        rm -f "$PV_D/ord.out"
        PV_ERR=$("$PV_KRC" --arch=$A --target=none "$PV_D/ord.kr" -o "$PV_D/ord.out" 2>&1); PV_ST=$?
        if [ "$PV_ST" = "0" ] && [ -f "$PV_D/ord.out" ]; then
            PASS=$((PASS + 1)); echo "  provider_import_order_${PV_ORDER}_$A: PASS"
        else
            echo "FAIL: provider_import_order_${PV_ORDER}_$A (exit $PV_ST: '$PV_ERR')"; FAIL=$((FAIL + 1))
        fi
        rm -f "$PV_D/ord.out"
    done
done

# std/heap_bump.kr's refusals, EXECUTED.
#
# Everything else in this block is static, and this block has no emulator: a
# bare-metal image cannot REPORT here. (The reason used to be "no entry point,
# no stack setup, a hardcoded load address"; sub-project B2 closed all three —
# --emit=image takes --load-addr= and --stack-top= emits an entry stub — and
# the boot gate further down this file DOES run heap_bump under QEMU. But L3
# reads a HALT, discriminated by a parked PC over QMP; a halted guest cannot
# print the request that was refused, which is what these cases assert.) So
# the allocator's overrun paths would otherwise ship reviewed but never once
# executed -- and a reviewed-not-executed bound is exactly what was wrong with
# the first version of this allocator. It rounded the request up BEFORE
# checking it, so `n + 15` wrapped for n near 2^64, `& ~15` floored it to 0,
# and alloc(2^64-1) on a 4096-byte region returned a pointer, reserved nothing
# and refused nothing.
#
# The module is transformed mechanically into something runnable: the
# @builtin_override annotations are stripped and alloc/dealloc renamed (they
# would otherwise shadow the builtins the harness itself needs), and
# heap_bump_halt is made to report and exit instead of `loop { }`. THE
# ARITHMETIC UNDER TEST IS NOT TOUCHED. The transformation is asserted to have
# applied, so a sed that silently matches nothing fails here rather than
# hanging forever on the module's real halt loop.
HB_D=$(mktemp -d "$DIR/../krc_pv_XXXXXX")
sed -e 's/^@builtin_override$//' \
    -e 's/^fn alloc(/fn hb_alloc(/' \
    -e 's/^fn dealloc(/fn hb_dealloc(/' \
    -e 's|^fn heap_bump_halt(uint64 reason, uint64 request) {|fn heap_bump_halt(uint64 reason, uint64 request) {\n    println("HALT", reason, request)\n    exit(9)|' \
    "$DIR/../std/heap_bump.kr" > "$HB_D/hb.kr"
TOTAL=$((TOTAL + 1))
if grep -q '^fn hb_alloc(' "$HB_D/hb.kr" \
   && grep -q 'println("HALT", reason, request)' "$HB_D/hb.kr" \
   && ! grep -q '^@builtin_override$' "$HB_D/hb.kr"; then
    PASS=$((PASS + 1)); echo "  heap_bump_harness_applied: PASS"
else
    echo "FAIL: heap_bump_harness_applied (the transformation did not apply -- every heap_bump check below is vacuous)"
    FAIL=$((FAIL + 1))
fi

hb_case() {
    local name="$1" body="$2" want="$3"
    TOTAL=$((TOTAL + 1))
    printf 'import "hb.kr"\nfn main() {\n%s\n    exit(0)\n}\n' "$body" > "$HB_D/c.kr"
    rm -f "$HB_D/c.out"
    local err got
    err=$("$PV_KRC" --arch=$ARCH "$HB_D/c.kr" -o "$HB_D/c.out" 2>&1)
    if [ ! -f "$HB_D/c.out" ]; then
        echo "FAIL: heap_bump_$name (build failed: '$err')"; FAIL=$((FAIL + 1)); return
    fi
    chmod +x "$HB_D/c.out"
    got=$(timeout 10 "$HB_D/c.out" 2>&1)
    if [ "$got" = "$want" ]; then
        PASS=$((PASS + 1)); echo "  heap_bump_$name: PASS"
    else
        echo "FAIL: heap_bump_$name (wanted '$want', got '$got')"; FAIL=$((FAIL + 1))
    fi
}

# The defect, pinned. A request that wraps the round-up must refuse, not
# return a pointer to a block 2^64 bytes short of what was asked for.
hb_case wrap_roundup \
    '    heap_bump_init(0x1000, 0x1000)
    uint64 huge = 0xFFFFFFFFFFFFFFFF
    uint64 p = hb_alloc(huge)
    println("NO REFUSAL", p)' \
    'HALT 2 18446744073709551615'
# One byte past the region, the ordinary exhaustion path.
hb_case exhausted \
    '    heap_bump_init(0x1000, 0x1000)
    uint64 p = hb_alloc(4097)
    println("NO REFUSAL", p)' \
    'HALT 2 4097'
# Using it before heap_bump_init.
hb_case uninitialised \
    '    uint64 p = hb_alloc(8)
    println("NO REFUSAL", p)' \
    'HALT 1 8'
# A region that wraps the address space: every downstream "is there room" test
# compares against limit, so a limit below base makes all of them nonsense.
hb_case init_wraps \
    '    heap_bump_init(0xFFFFFFFFFFFF0000, 0x20000)
    println("NO REFUSAL")' \
    'HALT 1 131072'
# Exactly the region must fit -- the refusals above must not be off by one.
hb_case exact_fit \
    '    heap_bump_init(0x1000, 0x1000)
    uint64 p = hb_alloc(4096)
    println("ok", p, heap_bump_used(), heap_bump_remaining())' \
    'ok 4096 4096 0'
# alloc(0) must not alias. Returning the cursor unchanged makes two zero-size
# allocations the same pointer AND makes either alias the next real block, so a
# sentinel written through a zero-length block corrupts a block it does not own.
hb_case zero_size_distinct \
    '    heap_bump_init(0x1000, 0x1000)
    uint64 a = hb_alloc(0)
    uint64 b = hb_alloc(0)
    uint64 c = hb_alloc(8)
    println(b - a, c - b)' \
    '16 16'
# Alignment holds for an awkward size, and dealloc stays a no-op.
hb_case align_and_dealloc \
    '    heap_bump_init(0x1000, 0x1000)
    uint64 a = hb_alloc(1)
    uint64 b = hb_alloc(17)
    hb_dealloc(b)
    uint64 c = hb_alloc(1)
    println(b - a, c - b, heap_bump_used())' \
    '16 32 64'
rm -rf "$HB_D"

# HOSTED BUILDS MUST NOT MOVE. The routing is keyed on target_os == 4, so a
# hosted program that defines `@builtin_override fn write` must keep println
# on the syscall path (otherwise every hosted program that overrides write
# silently loses its output) while `write()` itself still resolves to the
# override. This one CAN be run, so it is: the assertion is on observed
# stdout and on the override's return value, not on the artifact.
TOTAL=$((TOTAL + 1))
cat > "$PV_D/hosted.kr" <<'PVEOF'
@builtin_override
fn write(uint64 fd, uint64 buf, uint64 len) -> uint64 {
    return 99
}
fn main() {
    println("HOSTEDOK")
    uint64 r = write(1, "zz", 2)
    if r != 99 { exit(1) }
    exit(0)
}
PVEOF
rm -f "$PV_D/hosted.out"
if "$PV_KRC" --arch=$ARCH "$PV_D/hosted.kr" -o "$PV_D/hosted.out" >/dev/null 2>&1 \
   && chmod +x "$PV_D/hosted.out" \
   && [ "$("$PV_D/hosted.out" 2>/dev/null)" = "HOSTEDOK" ]; then
    PASS=$((PASS + 1)); echo "  provider_hosted_undisturbed: PASS"
else
    echo "FAIL: provider_hosted_undisturbed (hosted println lost its output, or the override was not called)"
    FAIL=$((FAIL + 1))
fi
rm -f "$PV_D/hosted.out"

# --legacy and --emit=obj never call ir_lower_expr: they have their own
# builtin dispatch in src/codegen.kr / src/codegen_aarch64.kr, so the routing
# added to the IR lowering misses them BY CONSTRUCTION. That is the failure
# shape this sub-project has already shipped twice. It must therefore refuse
# in a way that says so, rather than falling through to the generic
# "SYSCALL reached the emitter" backstop, which names the wrong builtin
# (println reported 'print') and gives no remedy.
#
# --legacy left this list in Task 6, which refuses it outright under
# --target=none -- for exactly the reason this block documents: the legacy
# dispatch has no @builtin_override routing, so the print family can never
# work there. --emit=obj reaches that identical dispatch and stays legal
# (a relocatable object is the normal bare-metal deliverable), so every
# assertion below still runs against the real legacy lowering on both arches.
for PV_FLAG in --emit=obj; do
    for A in x86_64 arm64; do
        for PV_B in println print println_str print_str; do
            TOTAL=$((TOTAL + 1))
            PV_M=$(pv_mod "$A")
            case "$PV_B" in
                print_str|println_str) PV_C="$PV_B(\"x\")" ;;
                *) PV_C="$PV_B(1)" ;;
            esac
            printf 'import "%s"\nfn main() {\n    %s\n    loop { }\n}\n' "$PV_M" "$PV_C" > "$PV_D/lg.kr"
            rm -f "$PV_D/lg.out"
            PV_ERR=$("$PV_KRC" $PV_FLAG --arch=$A --target=none "$PV_D/lg.kr" -o "$PV_D/lg.out" 2>&1); PV_ST=$?
            PV_TAG=$(echo "$PV_FLAG" | tr -d '-' | tr '=' '_')
            if [ "$PV_ST" = "0" ] || [ -f "$PV_D/lg.out" ]; then
                echo "FAIL: provider_legacy_${PV_B}_${PV_TAG}_$A (compiled -- the legacy backend does not route to the provider, so it must refuse)"
                FAIL=$((FAIL + 1))
            elif echo "$PV_ERR" | grep -q "reached the emitter"; then
                echo "FAIL: provider_legacy_${PV_B}_${PV_TAG}_$A (generic choke-point message -- the legacy lowering has no --target=none arm)"
                FAIL=$((FAIL + 1))
            elif ! echo "$PV_ERR" | grep -q "error: --target=none: '$PV_B' is not available on bare metal"; then
                echo "FAIL: provider_legacy_${PV_B}_${PV_TAG}_$A (refusal does not name '$PV_B': '$PV_ERR')"
                FAIL=$((FAIL + 1))
            elif ! echo "$PV_ERR" | grep -q "drop --legacy / --emit=obj"; then
                echo "FAIL: provider_legacy_${PV_B}_${PV_TAG}_$A (refusal does not say the IR backend supports it: '$PV_ERR')"
                FAIL=$((FAIL + 1))
            else
                PASS=$((PASS + 1)); echo "  provider_legacy_${PV_B}_${PV_TAG}_$A: PASS"
            fi
            rm -f "$PV_D/lg.out"
        done
        # write/alloc/dealloc DO work on the legacy backends: their override
        # gate predates this task (is_extern_call in the legacy dispatch), and
        # this pins it so the refusal added above cannot be widened by
        # accident into "no bare-metal legacy build works at all".
        TOTAL=$((TOTAL + 1))
        PV_M=$(pv_mod "$A")
        printf 'import "%s"\nimport "../std/heap_bump.kr"\nstatic uint64 sink = 0\nfn main() {\n    heap_bump_init(0x200000, 0x100000)\n    sink = write(1, "x", 1)\n    uint64 p = alloc(16)\n    dealloc(p)\n    loop { }\n}\n' "$PV_M" > "$PV_D/lgw.kr"
        rm -f "$PV_D/lgw.out"
        PV_ERR=$("$PV_KRC" $PV_FLAG --arch=$A --target=none "$PV_D/lgw.kr" -o "$PV_D/lgw.out" 2>&1); PV_ST=$?
        PV_TAG=$(echo "$PV_FLAG" | tr -d '-' | tr '=' '_')
        if [ "$PV_ST" = "0" ] && [ -f "$PV_D/lgw.out" ]; then
            PASS=$((PASS + 1)); echo "  provider_legacy_write_alloc_${PV_TAG}_$A: PASS"
        else
            echo "FAIL: provider_legacy_write_alloc_${PV_TAG}_$A (exit $PV_ST: '$PV_ERR')"; FAIL=$((FAIL + 1))
        fi
        rm -f "$PV_D/lgw.out"
    done
done
rm -rf "$PV_D"

# --- compile-time constants must not report Linux under --target=none ------
#
# THESE TESTS INSPECT THE ARTIFACT. THEY NEVER RUN IT. Under --target=none
# there is no way to observe a value the usual way: exit() is refused on
# x86_64/arm64, there is no output provider, and --emit=ir has no defined
# outcome yet. Everything below compiles, then reads the bytes back.
#
# get_arch_id/get_target_os/get_module_path fold to a COMPILE-TIME CONSTANT
# and emit no trap instruction, so Task 2's emitter guards and Task 3's
# refusal audit both structurally miss them: the builtin does not fail, it
# answers wrongly. At 563b0f3 get_arch_id initialised arch_id to the Linux
# value and only overrode for Windows/macOS/Android, so --target=none
# silently reported "Linux x86_64" / "Linux arm64".
#
# The oracle is exact and needs no disassembler, so it works on riscv32 and
# xtensa too: compile `sink = <builtin>()` and `sink = <expected literal>`
# from otherwise byte-identical sources and require the two ARTIFACTS to be
# byte-identical. Both lower to IR_CONST, so equality holds iff the folded
# constant is exactly the expected one. Asserting the SPECIFIC value is the
# whole point -- the defect is a plausible WRONG value, so "non-zero", "not
# the default" or "differs from hosted" would all pass while broken.
# Verified to fail before the fix: at 563b0f3 `sink = get_arch_id()` was
# byte-identical to `sink = 1` on x86_64 and to `sink = 2` on arm64.
echo ""
echo "--- --target=none compile-time constants ---"
TN_D=$(mktemp -d)

# Compile `sink = $2` and `sink = $3` under the flags in $4, require the two
# artifacts to be byte-identical. $1 is the check name.
tn_const_is() {
    local name="$1" expr="$2" want="$3"; shift 3
    TOTAL=$((TOTAL + 1))
    printf 'static uint32 sink = 0\nstatic uint32 buf = 0\nfn main() {\n    sink = %s\n    loop { }\n}\n' "$expr" > "$TN_D/e.kr"
    printf 'static uint32 sink = 0\nstatic uint32 buf = 0\nfn main() {\n    sink = %s\n    loop { }\n}\n' "$want" > "$TN_D/w.kr"
    rm -f "$TN_D/e.out" "$TN_D/w.out"
    local eerr werr
    eerr=$("$CP_KRC" "$@" "$TN_D/e.kr" -o "$TN_D/e.out" 2>&1)
    werr=$("$CP_KRC" "$@" "$TN_D/w.kr" -o "$TN_D/w.out" 2>&1)
    if [ ! -f "$TN_D/e.out" ]; then
        echo "FAIL: $name (expression build failed: '$eerr')"; FAIL=$((FAIL + 1))
    elif [ ! -f "$TN_D/w.out" ]; then
        echo "FAIL: $name (literal build failed: '$werr')"; FAIL=$((FAIL + 1))
    elif cmp -s "$TN_D/e.out" "$TN_D/w.out"; then
        PASS=$((PASS + 1)); echo "  $name: PASS"
    else
        echo "FAIL: $name (folded constant is NOT $want)"; FAIL=$((FAIL + 1))
    fi
}

# get_target_os() == 4. It folds target_os verbatim so it is already right --
# pinned here precisely BECAUSE it needs no code change, so a future edit to
# that lowering cannot quietly regress it to a per-OS chain like its
# neighbours have.
tn_const_is tn_target_os_x86_64  'get_target_os()' 4 --arch=x86_64 --target=none
tn_const_is tn_target_os_arm64   'get_target_os()' 4 --arch=arm64   --target=none
tn_const_is tn_target_os_riscv32 'get_target_os()' 4 --arch=riscv32 --target=none
tn_const_is tn_target_os_xtensa  'get_target_os()' 4 --arch=xtensa  --target=none
# The --legacy rows that stood here were removed by Task 6, which refuses
# --legacy under --target=none. They are not dropped coverage: --emit=obj
# routes through the SAME src/codegen.kr / src/codegen_aarch64.kr lowering of
# this builtin on the same two arches, so the rows below exercise the identical
# code. --legacy's own refusal is asserted by t6_legacy_tnone_* above.
tn_const_is tn_target_os_obj_x86_64 'get_target_os()' 4 --emit=obj --arch=x86_64 --target=none
tn_const_is tn_target_os_obj_arm64  'get_target_os()' 4 --emit=obj --arch=arm64  --target=none

# get_arch_id() must report a BARE-METAL id, never a Linux one.
#   9 = bare-metal x86_64   10 = bare-metal arm64
#  11 = bare-metal riscv32  12 = bare-metal xtensa
# The hosted ids 1..8 stay exactly as they were: they are the KrboFat slice
# selectors and a fat binary cannot contain a bare-metal slice.
tn_const_is tn_arch_id_x86_64  'get_arch_id()'  9 --arch=x86_64 --target=none
tn_const_is tn_arch_id_arm64   'get_arch_id()' 10 --arch=arm64   --target=none
tn_const_is tn_arch_id_riscv32 'get_arch_id()' 11 --arch=riscv32 --target=none
tn_const_is tn_arch_id_xtensa  'get_arch_id()' 12 --arch=xtensa  --target=none
# --legacy and --emit=obj never call ir_lower_expr: they have their own
# builtin dispatch in src/codegen.kr / src/codegen_aarch64.kr. A fix that
# lives only in ir.kr leaves them reporting Linux, which is exactly how the
# legacy time_ns constant zero shipped in an artifact at 563b0f3.
# Same as above: the --legacy rows are gone with the flag, and --emit=obj
# covers the identical legacy lowering on both arches.
tn_const_is tn_arch_id_obj_x86_64 'get_arch_id()'  9 --emit=obj --arch=x86_64 --target=none
tn_const_is tn_arch_id_obj_arm64  'get_arch_id()' 10 --emit=obj --arch=arm64  --target=none

# get_module_path() answers 0 on bare metal, and that is a DECISION, not a
# fall-through. 0 is what this builtin already returns on Linux, macOS and
# Android -- it means "no path is available", which is exactly true of an
# image with no filesystem, no loader and no argv[0]. Unlike time_ns or
# set_executable it is not a wrong answer standing in for an action that
# silently did not happen, and every caller in this tree already gates on
# `> 0` (src/main.kr's import_init_search_paths). So this is the one member
# of the class whose correct behaviour was ALREADY correct: these checks pass
# both before and after the fix by design, and they exist to pin the decision
# so it cannot drift back into being an accident.
#
# tn_const_is cannot be used here: get_module_path takes two arguments, and
# although the argument evaluation is folded away the argument vregs still
# reserve stack slots, so `sink = get_module_path(buf, 64)` has a larger frame
# than `sink = 0` and the artifacts differ for a reason that has nothing to do
# with the constant. The chain asserted instead is exact in two links:
#   1. hosted Linux really does answer 0 -- observed by RUNNING it, the one
#      place in this block where running is possible;
#   2. the --target=none artifact is byte-identical to the Linux one.
# A Windows build of the same source is the third leg, and it is what stops
# link 2 being vacuous -- Windows is the only target that lowers to a real
# GetModuleFileNameA call, so it proves the target_os dispatch in this
# lowering is live rather than the whole thing having been folded away. On
# x86_64/arm64 that shows up as a DIFFERENT artifact.
#
# On riscv32/xtensa the Windows leg USED to be `--target=windows` failing on
# `IR op 146 not yet implemented` (146 = IR_MODULE_PATH). Task 6's arch x OS
# validation makes that pair unrequestable -- `--arch=riscv32
# --target=windows` used to exit 0 and write a RISC-V ELF, so refusing it is
# the point of that task -- and the leg is asserted as the PAIR REFUSAL
# instead. That would be a vacuous leg on its own, so it is paired with a
# source assertion (tn_module_path_dispatch_single_sited, below) that the
# `target_os == 2` branch of this builtin exists exactly once, in
# ir_lower_expr, ahead of any backend selection. One site means the x86_64 and
# arm64 legs execute literally the same `if` that riscv32 and xtensa would:
# proving it live there proves it live for all four. The leg is asserted
# rather than skipped, because a skipped leg is a finding you decided not to
# have.
if [ "$ARCH" = "x86_64" ]; then
    TOTAL=$((TOTAL + 1))
    printf 'static uint64 mbuf = 0\nfn main() {\n    mbuf = alloc(512)\n    println(get_module_path(mbuf, 512))\n    exit(0)\n}\n' > "$TN_D/mprun.kr"
    rm -f "$TN_D/mprun"
    "$CP_KRC" --arch=x86_64 --target=linux "$TN_D/mprun.kr" -o "$TN_D/mprun" >/dev/null 2>&1
    chmod +x "$TN_D/mprun" 2>/dev/null
    TN_MPOUT=$("$TN_D/mprun" 2>&1)
    if [ "$TN_MPOUT" = "0" ]; then
        PASS=$((PASS + 1)); echo "  tn_module_path_linux_is_zero: PASS"
    else
        echo "FAIL: tn_module_path_linux_is_zero (got '$TN_MPOUT')"; FAIL=$((FAIL + 1))
    fi
else
    echo "  tn_module_path_linux_is_zero: SKIP (non-x86_64 host)"
fi
printf 'static uint32 sink = 0\nstatic uint32 buf = 0\nfn main() {\n    sink = get_module_path(buf, 64)\n    loop { }\n}\n' > "$TN_D/mp.kr"
tn_mp_same_as_linux() { # name, win-mode(artifact|nyi), flags...
    local name="$1" winmode="$2"; shift 2
    TOTAL=$((TOTAL + 1))
    rm -f "$TN_D/mp_n" "$TN_D/mp_l" "$TN_D/mp_w"
    "$CP_KRC" "$@" --target=none "$TN_D/mp.kr" -o "$TN_D/mp_n" >/dev/null 2>&1
    "$CP_KRC" "$@" --freestanding "$TN_D/mp.kr" -o "$TN_D/mp_l" >/dev/null 2>&1
    local werr
    werr=$("$CP_KRC" "$@" --freestanding --target=windows "$TN_D/mp.kr" -o "$TN_D/mp_w" 2>&1)
    local winok=0
    if [ "$winmode" = "artifact" ]; then
        [ -f "$TN_D/mp_w" ] && ! cmp -s "$TN_D/mp_n" "$TN_D/mp_w" && winok=1
    else
        # riscv32/xtensa: the pair is refused up front, by name.
        [ ! -f "$TN_D/mp_w" ] && echo "$werr" | grep -q "not a supported target pair" && winok=1
    fi
    if [ ! -f "$TN_D/mp_n" ] || [ ! -f "$TN_D/mp_l" ]; then
        echo "FAIL: $name (the bare-metal or Linux build produced no artifact)"; FAIL=$((FAIL + 1))
    elif ! cmp -s "$TN_D/mp_n" "$TN_D/mp_l"; then
        echo "FAIL: $name (bare metal does not fold to the Linux answer)"; FAIL=$((FAIL + 1))
    elif [ "$winok" != "1" ]; then
        echo "FAIL: $name (the Windows leg did not distinguish itself: '$werr')"; FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1)); echo "  $name: PASS"
    fi
}
tn_mp_same_as_linux tn_module_path_x86_64  artifact --arch=x86_64
tn_mp_same_as_linux tn_module_path_arm64   artifact --arch=arm64
tn_mp_same_as_linux tn_module_path_riscv32 pair     --arch=riscv32
tn_mp_same_as_linux tn_module_path_xtensa  pair     --arch=xtensa

# ir_opt_is_side_effect did not list opcode 146 (IR_MODULE_PATH), so a
# get_module_path call whose length result goes unused was deleted by DCE --
# but the call WRITES the path through its buffer argument, so deleting it
# silently drops that write. Windows is the only target that emits
# IR_MODULE_PATH (target_os==2 gated), so build the same buffer-alloc
# skeleton with and without the call and compare PE sizes: with the bug, an
# unused-result call adds zero bytes over no call at all (fully erased).
# Size, not cmp -s: the PE COFF header carries a build timestamp, so two
# builds of even identical code differ in a couple of header bytes -- the
# artifact SIZE is the part DCE actually changes.
TOTAL=$((TOTAL + 1))
printf 'fn main() {\n    uint64 buf = alloc(300)\n    exit(0)\n}\n' > "$TN_D/mp_nocall.kr"
printf 'fn main() {\n    uint64 buf = alloc(300)\n    get_module_path(buf, 300)\n    exit(0)\n}\n' > "$TN_D/mp_unused.kr"
rm -f "$TN_D/mp_nocall_w" "$TN_D/mp_unused_w"
"$CP_KRC" --arch=x86_64 --target=windows "$TN_D/mp_nocall.kr" -o "$TN_D/mp_nocall_w" >/dev/null 2>&1
"$CP_KRC" --arch=x86_64 --target=windows "$TN_D/mp_unused.kr" -o "$TN_D/mp_unused_w" >/dev/null 2>&1
if [ -f "$TN_D/mp_nocall_w" ] && [ -f "$TN_D/mp_unused_w" ]; then
    MP_NC_SZ=$(wc -c < "$TN_D/mp_nocall_w")
    MP_UN_SZ=$(wc -c < "$TN_D/mp_unused_w")
    if [ "$MP_NC_SZ" != "$MP_UN_SZ" ]; then
        PASS=$((PASS + 1))
        echo "  tn_module_path_unused_result_not_dce: PASS ($MP_NC_SZ vs $MP_UN_SZ bytes)"
    else
        echo "FAIL: tn_module_path_unused_result_not_dce (no-call and unused-result artifacts are the same size ($MP_NC_SZ) -- get_module_path was DCE'd)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: tn_module_path_unused_result_not_dce (one of the artifacts failed to build)"
    FAIL=$((FAIL + 1))
fi

# The claim the two `pair` legs above lean on, made an assertion: the Windows
# branch of get_module_path exists exactly ONCE, in the shared IR lowering,
# so it is arch-independent by construction. If a backend ever grows its own
# copy, this fails and the two legs above stop being sufficient.
TOTAL=$((TOTAL + 1))
TN_MPSITES=$(SRCDIR="$DIR/../src" python3 - <<'MPPY'
import os, re, glob
src = os.environ["SRCDIR"]
hits = []
for path in sorted(glob.glob(os.path.join(src, "*.kr"))):
    lines = open(path).read().splitlines()
    for i, l in enumerate(lines):
        if "ir_emit(IR_MODULE_PATH" in l.split("//")[0]:
            hits.append("%s:%d" % (os.path.basename(path), i + 1))
print(" ".join(hits))
MPPY
)
if [ "$(echo "$TN_MPSITES" | wc -w)" = "1" ] && echo "$TN_MPSITES" | grep -q "^ir\.kr:"; then
    PASS=$((PASS + 1)); echo "  tn_module_path_dispatch_single_sited: PASS ($TN_MPSITES)"
else
    echo "FAIL: tn_module_path_dispatch_single_sited (want exactly 1 site in ir.kr, got '$TN_MPSITES')"
    FAIL=$((FAIL + 1))
fi
tn_mp_same_as_linux tn_module_path_obj_x86_64 artifact --emit=obj --arch=x86_64
tn_mp_same_as_linux tn_module_path_obj_arm64  artifact --emit=obj --arch=arm64

# The hosted ids must not move. --target=none is an ADDITION to the arch_id
# ABI, not a renumbering, and these are the values docs/LANGUAGE.md and the
# KrboFat slice table are written against.
tn_const_is tn_arch_id_hosted_linux_x86_64   'get_arch_id()' 1 --arch=x86_64 --target=linux
tn_const_is tn_arch_id_hosted_linux_arm64    'get_arch_id()' 2 --arch=arm64  --target=linux
tn_const_is tn_arch_id_hosted_windows_x86_64 'get_arch_id()' 3 --arch=x86_64 --target=windows
tn_const_is tn_arch_id_hosted_windows_arm64  'get_arch_id()' 4 --arch=arm64  --target=windows
tn_const_is tn_arch_id_hosted_macos_x86_64   'get_arch_id()' 5 --arch=x86_64 --target=macos
tn_const_is tn_arch_id_hosted_macos_arm64    'get_arch_id()' 6 --arch=arm64  --target=macos
tn_const_is tn_arch_id_hosted_android_arm64  'get_arch_id()' 7 --arch=arm64  --target=android
tn_const_is tn_arch_id_hosted_android_x86_64 'get_arch_id()' 8 --arch=x86_64 --target=android

# Second, independent reading of the SAME fact: find the immediate in the
# emitted machine code. The equality oracle above proves the constant is 9 by
# construction; this proves it by disassembling what actually shipped, so a
# hypothetical bug that made the literal path wrong in the same direction
# cannot hide. Both encodings materialise the value into whichever register
# the allocator picked, so the register field is a wildcard and the immediate
# is not:
#   x86_64  MOV r32, imm32   B8+r imm32(LE)      -> b[89a-f] <imm32 LE>
#   arm64   MOVZ Xd, #imm16  D2800000|imm16<<5|d, little-endian. Only the
#           LOW byte carries the register (0..31) alongside the bottom bits
#           of imm16<<5, so for imm 10 (0x140) it is 0x40..0x5F and the rest
#           of the word is fixed at 0180d2; for the Linux imm 2 (0x40) the
#           same low-byte range appears but the word is 0080d2.
# Wrong-value guards are asserted too: the Linux immediates must be ABSENT.
tn_imm() { # name, file, present-regex, absent-regex
    TOTAL=$((TOTAL + 1))
    local hex
    hex=$(xxd -p "$2" | tr -d '\n')
    if ! echo "$hex" | grep -qE "$3"; then
        echo "FAIL: $1 (expected immediate not materialised in the artifact)"; FAIL=$((FAIL + 1))
    elif echo "$hex" | grep -qE "$4"; then
        echo "FAIL: $1 (the Linux immediate is still in the artifact)"; FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1)); echo "  $1: PASS"
    fi
}
printf 'static uint32 sink = 0\nfn main() {\n    sink = get_arch_id()\n    loop { }\n}\n' > "$TN_D/aid.kr"
rm -f "$TN_D/aid_x86" "$TN_D/aid_a64"
"$CP_KRC" --arch=x86_64 --target=none "$TN_D/aid.kr" -o "$TN_D/aid_x86" >/dev/null 2>&1
"$CP_KRC" --arch=arm64  --target=none "$TN_D/aid.kr" -o "$TN_D/aid_a64" >/dev/null 2>&1
# mov r32, 9  vs  mov r32, 1
tn_imm tn_arch_id_immediate_x86_64 "$TN_D/aid_x86" 'b[89a-f]09000000' 'b[89a-f]01000000'
# movz xd, #10 (imm<<5 = 0x140) vs movz xd, #2 (imm<<5 = 0x40)
tn_imm tn_arch_id_immediate_arm64  "$TN_D/aid_a64" '[45][0-9a-f]0180d2' '[45][0-9a-f]0080d2'
rm -rf "$TN_D"

# --- the --target=none acceptance gate, gate 2 ------------------------------
#
# tests/target_none/prove_no_syscalls.sh is the two-gate acceptance gate for
# --target=none. Only GATE 2 runs here, and the split is deliberate:
#
#   Gate 2 (the corpus) needs nothing but the compiler in build/ -- every
#   builtin, all four architectures, refusals and providers -- and it is the
#   leg that can see else-POSIX inheritance, which byte-identity structurally
#   cannot. It costs about half a second, so it belongs in every `make test`.
#
#   Gate 1 (byte-identity) has to build the compiler AS OF THE BRANCH POINT,
#   which needs a git checkout and about 80 seconds. It is a branch/release
#   gate, run on demand:  tests/target_none/prove_no_syscalls.sh
#   Run the script with no arguments to get both.
#
# The script is invoked WITHOUT KRC set, so it uses build/krc2 directly rather
# than $KRC, which under `make test` is a wrapper that injects --arch=x86_64
# ahead of every argument -- and the arch is the variable under test here.
#
# READ THE SCRIPT'S HEADER BEFORE CITING A GREEN RUN. Nothing in this
# sub-project has ever produced output on bare metal; the gate asserts what the
# compiler emits, never what a board did with it.
TOTAL=$((TOTAL + 1))
TN_GATE="$DIR/target_none/prove_no_syscalls.sh"
if [ ! -x "$TN_GATE" ]; then
    echo "FAIL: target_none_acceptance_gate (missing or not executable: $TN_GATE)"; FAIL=$((FAIL + 1))
else
    TN_GATE_OUT=$(env -u KRC bash "$TN_GATE" --gate2 2>&1); TN_GATE_ST=$?
    TN_GATE_SUM=$(echo "$TN_GATE_OUT" | grep -E "^=== prove_no_syscalls:")
    # A pass count is asserted, not just the exit status: a script that silently
    # stopped generating rows exits 0 having proved nothing. 104 checks today.
    TN_GATE_N=$(echo "$TN_GATE_OUT" | grep -cE "^  [a-z0-9_]+: PASS")
    if [ "$TN_GATE_ST" != "0" ]; then
        echo "FAIL: target_none_acceptance_gate ($TN_GATE_SUM)"
        echo "$TN_GATE_OUT" | grep "^FAIL:" | sed 's/^/    /'
        FAIL=$((FAIL + 1))
    elif [ "$TN_GATE_N" -lt 104 ]; then
        echo "FAIL: target_none_acceptance_gate (only $TN_GATE_N checks ran, expected at least 104 -- the gate went quiet)"
        FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1)); echo "  target_none_acceptance_gate: PASS ($TN_GATE_N gate-2 checks; gate 1 is on demand)"
    fi
fi

# --- hand-counted write() lengths ------------------------------------------
# Every write(fd, "<literal>", N) must have N equal to the literal's real byte
# length. Getting this wrong is the single most repeated defect in this tree:
# 30 sites were wrong at once, 22 over-reading (emitting stray NULs and, at
# living.kr's worst case, five bytes of the NEXT string literal) and 8
# truncating (dropping the trailing newline, or the closing quote from
# "unrecognized asm instruction '"). All 30 now derive their length with
# str_len(); this check keeps the count at zero.
#
# THE FD IS A WILDCARD, and it has to be. This scanner shipped matching only
# `write(1, ...)` and `write(2, ...)` -- a LITERAL fd -- while its own comment
# claimed every site. Three live wrong lengths sat behind that blind spot the
# whole time, all in the --emit=asm listing writer, which writes to an opened
# file rather than to stdout/stderr:
#   main.kr:903   "; KernRift assembly listing\n" declared 27, real 28 -- the
#                 listing header lost its newline and ran straight into
#                 "; Architecture: x86_64". Observed on the wire.
#   main.kr:1461  "           mfence"            declared 18, real 17 -- a NUL
#                 byte after every disassembled mfence.
#   main.kr:1535  "...          lock ..."        declared 20, real 21 -- the
#                 lock-prefix line lost its last ".".
# A guard whose scope is narrower than its comment is worse than no guard: it
# reads as coverage. Two lessons are wired in below rather than written down.
#
# The length is derived two independent ways and both must agree, because a
# scanner that is wrong in one direction is wrong in the other too:
#   A) decode the literal to bytes and take len()
#   B) count raw SOURCE bytes between the quotes, minus one per 2-char escape
# They differ only if an escape is not a 2-char-to-1-byte mapping. (B) is what
# makes multi-byte characters safe: " -> stable\n" with a 3-byte arrow is 12
# bytes and must NOT be flagged -- an earlier scan using Python's
# unicode_escape reported it as a 3-byte truncation and was wrong.
#
# Two guards against the scanner itself going quiet, because that is exactly
# how the fd blind spot survived:
#   * COVERAGE. A loose pattern finds every `write(... "literal" ..., <digits>)`
#     on a line; the strict pattern must match all of them. A site the strict
#     pattern cannot parse is REPORTED, not skipped, so the next unanticipated
#     fd shape fails here instead of hiding.
#   * FLOOR. The scan must see at least 800 sites (825 in src/ + std/ at the
#     time of writing). A regex that stops matching finds zero wrong lengths
#     and would otherwise pass green.
TOTAL=$((TOTAL + 1))
WL_BAD=$(SRCDIR="$DIR/../src" STDDIR="$DIR/../std" python3 - <<'WLPY'
import re, os, glob
# fd is any expression that contains no comma and no quote -- `1`, `2`, `fd`,
# `out_fd`, `h + 1`. A fd containing a comma (a nested call) would be missed by
# this and CAUGHT BY THE COVERAGE LEG below rather than silently dropped.
LIT = re.compile(rb'write\(\s*([^,"()]{1,64}?)\s*,\s*"((?:[^"\\]|\\.)*)"\s*,\s*(\d+)\s*\)')
# Deliberately sloppy: any write( ... "literal" ... , digits ) on one line.
LOOSE = re.compile(rb'write\([^;]{0,120}?"(?:[^"\\]|\\.)*"\s*,\s*\d+\s*\)')
ESC = {ord('n'): b'\n', ord('t'): b'\t', ord('r'): b'\r', ord('0'): b'\0',
       ord('\\'): b'\\', ord('"'): b'"', ord("'"): b"'"}
bad, disagree, unparsed = [], [], []
seen = 0
files = sorted(glob.glob(os.path.join(os.environ["SRCDIR"], "*.kr")))
files += sorted(glob.glob(os.path.join(os.environ["STDDIR"], "*.kr")))
for path in files:
    for ln, line in enumerate(open(path, "rb").read().split(b"\n"), 1):
        where = "%s:%d" % (os.path.basename(path), ln)
        strict = list(LIT.finditer(line))
        if len(strict) < len(list(LOOSE.finditer(line))):
            unparsed.append(where)
        for m in strict:
            seen += 1
            body, decl = m.group(2), int(m.group(3))
            out, i, nesc = b"", 0, 0
            while i < len(body):
                if body[i] == 0x5C and i + 1 < len(body):
                    out += ESC.get(body[i + 1], bytes([body[i + 1]])); i += 2; nesc += 1
                else:
                    out += bytes([body[i]]); i += 1
            a, b = len(out), len(body) - nesc
            if a != b:
                disagree.append("%s (A=%d B=%d)" % (where, a, b))
            elif a != decl:
                bad.append("%s declared %d, real %d" % (where, decl, a))
out = []
if disagree: out.append("length methods disagree: " + "; ".join(disagree))
if bad: out.append("%d wrong length(s): %s" % (len(bad), "; ".join(bad[:6])))
if unparsed: out.append("%d site(s) the fd pattern could not parse: %s"
                        % (len(unparsed), "; ".join(unparsed[:6])))
if seen < 800: out.append("only %d sites scanned (expected >= 800) -- the scanner went quiet" % seen)
print(" | ".join(out))
WLPY
)
if [ -z "$WL_BAD" ]; then
    PASS=$((PASS + 1)); echo "  write_literal_lengths: PASS (all hand-counted write() lengths match)"
else
    echo "FAIL: write_literal_lengths ($WL_BAD)"; FAIL=$((FAIL + 1))
fi

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
# with no output. Asserts on the DISASSEMBLY of the IRAM code
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
# used by hand (`image-info`), never a build/test dependency.
#
# Container asserts (independent of the code):
#   magic/mode/size bytes e9 02 02 20, EXACTLY 2 segments, entry in IRAM,
#   (len - 32) % 16 == 0  — the payload is 16-padded and a 32-byte SHA-256
#   appended, so total-minus-hash must be a multiple of 16 (the ROM reads it
#   that way), and the checksum byte at len-33 equals the 0xEF-seeded XOR of
#   every segment payload byte, RECOMPUTED here rather than trusted.
#
# Code asserts (errata CPU-3.3) — the important ones:
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

# --- Growable-buffer regression tests ---
# Each input exceeds an OLD fixed capacity that the compiler used to refuse
# loudly. The discriminating mutations (verified against the pre-fix
# compiler):
#   imports100:  "error: import_seen overflow (max 64)"
#   strbuf_grow: "error: str_buf overflow (max 65536)"
#   fixup_grow:  "error: fixup_table overflow (max 32768)"  (via --legacy;
#                the IR path hits the separate ir_insn cap first)
# With growable buffers all three must compile AND the binaries must run
# correctly (growth that corrupts data would show up as a wrong exit code).
echo "--- growable buffer tests ---"
GROW_DIR=$(mktemp -d /tmp/krc_grow_XXXXXX)

# 1) import_seen: 100 imported modules (old cap: 64 files)
TOTAL=$((TOTAL + 1))
for gi in $(seq 0 99); do
    printf 'fn m%d() -> uint64 { return %d }\n' "$gi" "$gi" > "$GROW_DIR/m$gi.kr"
done
{ for gi in $(seq 0 99); do printf 'import "m%d.kr"\n' "$gi"; done
  printf 'fn main() {\n    exit(m0() + m99() - 99)\n}\n'
} > "$GROW_DIR/imports100.kr"
if $KRC $KRC_FLAGS "$GROW_DIR/imports100.kr" -o "$GROW_DIR/imports100" >/dev/null 2>&1 \
   && chmod +x "$GROW_DIR/imports100" && "$GROW_DIR/imports100" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "  grow_import_seen_100: PASS (100 imports, old cap 64)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: grow_import_seen_100 (100 imports must compile and exit 0)"
fi

# 2) str_buf: 300 string literals x 256 bytes = ~77 KB (old cap: 65536)
TOTAL=$((TOTAL + 1))
GROW_LONG=$(printf 'a%.0s' $(seq 1 256))
{ printf 'fn main() {\n'
  for gi in $(seq 0 299); do printf '    uint64 s%d = "%s"\n' "$gi" "$GROW_LONG"; done
  printf '    write(1, s299, 3)\n    exit(0)\n}\n'
} > "$GROW_DIR/strbuf_grow.kr"
GROW_OUT=""
if $KRC $KRC_FLAGS "$GROW_DIR/strbuf_grow.kr" -o "$GROW_DIR/strbuf_grow" >/dev/null 2>&1; then
    chmod +x "$GROW_DIR/strbuf_grow"
    GROW_OUT=$("$GROW_DIR/strbuf_grow" 2>/dev/null)
fi
if [ "$GROW_OUT" = "aaa" ]; then
    PASS=$((PASS + 1))
    echo "  grow_str_buf_77k: PASS (77 KB of literals, old cap 64 KB)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: grow_str_buf_77k (expected output 'aaa', got '$GROW_OUT')"
fi

# 3) fixup_table: 33000 call sites through the legacy x86 emitter
#    (old cap: 32768). Exit code 232 == 33000 - 32768 proves every call
#    executed against the grown table.
TOTAL=$((TOTAL + 1))
{ printf 'fn f(uint64 x) -> uint64 {\n    uint64 y = x + 1\n    return y\n}\nfn main() {\n    uint64 t = 0\n'
  for gi in $(seq 1 33000); do printf '    t = f(t)\n'; done
  printf '    exit(t - 32768)\n}\n'
} > "$GROW_DIR/fixup_grow.kr"
GROW_EC=1
if $KRC $KRC_FLAGS --legacy "$GROW_DIR/fixup_grow.kr" -o "$GROW_DIR/fixup_grow" >/dev/null 2>&1; then
    chmod +x "$GROW_DIR/fixup_grow"
    "$GROW_DIR/fixup_grow" >/dev/null 2>&1
    GROW_EC=$?
fi
if [ "$GROW_EC" = 232 ]; then
    PASS=$((PASS + 1))
    echo "  grow_fixup_table_33k: PASS (33000 calls, old cap 32768)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: grow_fixup_table_33k (expected exit 232, got $GROW_EC)"
fi

# 4) ir_insn arena + BB-list growth: one function with >65536 IR instructions
#    on the DEFAULT IR path. 33000 calls == ~66k insns, just past the old
#    65536 cap. Exit 1 proves every call executed and the tail arithmetic
#    survived register allocation.
#
#    This single case guards TWO defects that only appear past 65536 insns:
#      (a) the instruction arena used to be a hard cap -> "IR instruction
#          overflow" and no binary at all;
#      (b) ir_build_bb_lists() silently truncated its instruction list at
#          65536. Liveness and the interference graph both read that list, so
#          the tail's values looked DEAD and the allocator handed a live
#          value's register to a later constant. On arm64 that emitted
#          `mov x19, x0` followed immediately by `movz x19, #255`, so the
#          result was silently wrong; on x86_64 the same truncation showed up
#          as a segfault once print() was involved. (b) was UNREACHABLE while
#          (a) existed, which is why fixing the arena alone made things worse.
#
#    Must run on every arch the suite covers: x86_64 was CORRECT for the
#    exit-code form while arm64 was wrong, so a single-arch check would have
#    missed it — CI's native arm64 job is what caught it.
TOTAL=$((TOTAL + 1))
{ printf 'fn f(uint64 x) -> uint64 {\n    uint64 y = x + 1\n    return y\n}\nfn main() {\n    uint64 t = 0\n'
  for gi in $(seq 1 33000); do printf '    t = f(t)\n'; done
  printf '    exit(t - 33000 + 1)\n}\n'
} > "$GROW_DIR/insn_grow.kr"
GROW_EC2=0
if $KRC $KRC_FLAGS "$GROW_DIR/insn_grow.kr" -o "$GROW_DIR/insn_grow" >/dev/null 2>&1; then
    chmod +x "$GROW_DIR/insn_grow"
    "$GROW_DIR/insn_grow" >/dev/null 2>&1
    GROW_EC2=$?
else
    GROW_EC2="compile-failed"
fi
if [ "$GROW_EC2" = 1 ]; then
    PASS=$((PASS + 1))
    echo "  grow_ir_insn_66k: PASS (33000 calls, ~66k insns, arena + bb-list growth)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: grow_ir_insn_66k (expected exit 1, got $GROW_EC2)"
fi


rm -rf "$GROW_DIR"

# --- Import path length tests ---
# import_mark_seen used to copy paths into fixed 256-byte entries,
# silently truncating at 255 chars. Two distinct consequences, one test
# each (both verified failing on the pre-fix compiler):
#   1) dedup broke for ANY >255-char resolved path — is_seen compares the
#      full path against the truncated entry and never matches, so a
#      module imported from two files was appended twice:
#      "error: redefinition of function".
#   2) a 255-char path equal to a longer path's truncated entry was
#      falsely "already seen" and its import silently skipped:
#      "error: undefined function".
# Entries are now u64 pointers to exact-size heap copies (no length
# cliff at any size).
echo "--- import path length tests ---"
LP_DIR=$(mktemp -d /tmp/krc_lp_XXXXXX)
LP_D1=$(printf 'd%.0s' $(seq 1 80))
LP_D2=$(printf 'e%.0s' $(seq 1 200))
mkdir -p "$LP_DIR/$LP_D1/$LP_D2"
printf 'fn deep_mod() -> uint64 { return 41 }\n' > "$LP_DIR/$LP_D1/$LP_D2/deepmod.kr"

# 1) Diamond import through a >255-char resolved path must dedup.
TOTAL=$((TOTAL + 1))
printf 'import "%s/%s/deepmod.kr"\nfn use_a() -> uint64 { return deep_mod() }\n' "$LP_D1" "$LP_D2" > "$LP_DIR/a.kr"
printf 'import "%s/%s/deepmod.kr"\nfn use_b() -> uint64 { return deep_mod() + 1 }\n' "$LP_D1" "$LP_D2" > "$LP_DIR/b.kr"
printf 'import "a.kr"\nimport "b.kr"\nfn main() { exit(use_a() + use_b() - 41) }\n' > "$LP_DIR/main.kr"
LP_EC=1
if $KRC $KRC_FLAGS "$LP_DIR/main.kr" -o "$LP_DIR/dedup" >/dev/null 2>&1; then
    chmod +x "$LP_DIR/dedup"
    "$LP_DIR/dedup" >/dev/null 2>&1
    LP_EC=$?
fi
if [ "$LP_EC" = 42 ]; then
    PASS=$((PASS + 1))
    echo "  import_longpath_dedup: PASS (>255-char path imported once from two files)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: import_longpath_dedup (expected exit 42, got $LP_EC)"
fi

# 2) A distinct 255-char path sharing the long path's 255-char prefix
#    must still be imported (pre-fix: silently skipped as already-seen).
#    The 80/200 directory lengths guarantee char 255 of the full path
#    lands inside the second directory-name run for any sane tmpdir.
TOTAL=$((TOTAL + 1))
LP_FULL="$LP_DIR/$LP_D1/$LP_D2/deepmod.kr"
LP_P255=$(printf '%s' "$LP_FULL" | cut -c1-255)
LP_REL2=${LP_P255#"$LP_DIR/"}
printf 'fn prefix_mod() -> uint64 { return 7 }\n' > "$LP_DIR/$LP_REL2"
printf 'import "%s/%s/deepmod.kr"\nimport "%s"\nfn main() { exit(deep_mod() + prefix_mod()) }\n' "$LP_D1" "$LP_D2" "$LP_REL2" > "$LP_DIR/main2.kr"
LP_EC2=1
if $KRC $KRC_FLAGS "$LP_DIR/main2.kr" -o "$LP_DIR/collide" >/dev/null 2>&1; then
    chmod +x "$LP_DIR/collide"
    "$LP_DIR/collide" >/dev/null 2>&1
    LP_EC2=$?
fi
if [ "$LP_EC2" = 48 ]; then
    PASS=$((PASS + 1))
    echo "  import_longpath_prefix_collision: PASS (255-char prefix twin not skipped)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: import_longpath_prefix_collision (expected exit 48, got $LP_EC2)"
fi
rm -rf "$LP_DIR"

# --- builtin shadowing tests ---
# A user fn whose name matches a recognized built-in used to shadow it
# SILENTLY — and inconsistently: the user body won only when the inliner
# picked it up (tiny bodies), otherwise builtin dispatch won. That silence
# let a stub time_ns() { return 0 } disable the compiler's own "(X.XX ms)"
# timer for 20+ releases. Now: unannotated shadowing is a hard sema error;
# @builtin_override makes the user body win at EVERY call site on every
# backend (IR + legacy).
echo ""
echo "--- builtin shadowing tests ---"

# 1. Unannotated definition matching a built-in name must be REJECTED.
#    Discriminating mutation: remove the is_builtin check in
#    sema_collect_signatures (analysis.kr) — this compiles again and the
#    test fails with "should not compile" (that is the pre-fix behavior).
TOTAL=$((TOTAL + 1))
printf 'fn time_ns() -> uint64 { return 0 }\nfn main() { exit(0) }\n' > /tmp/krc_shadow_$$.kr
if $KRC $KRC_FLAGS /tmp/krc_shadow_$$.kr -o /tmp/krc_shadow_$$ 2>/tmp/krc_shadow_err_$$ ; then
    echo "FAIL: builtin_shadow_rejected (should not compile)"
    FAIL=$((FAIL + 1))
else
    if grep -q "shadows a built-in" /tmp/krc_shadow_err_$$ && grep -q "builtin_override" /tmp/krc_shadow_err_$$; then
        PASS=$((PASS + 1))
        echo "  builtin_shadow_rejected: PASS (error names the fix)"
    else
        echo "FAIL: builtin_shadow_rejected (wrong error)"
        head -2 /tmp/krc_shadow_err_$$
        FAIL=$((FAIL + 1))
    fi
fi
rm -f /tmp/krc_shadow_$$.kr /tmp/krc_shadow_$$ /tmp/krc_shadow_err_$$

# 2. Same program WITH @builtin_override must compile and the USER body must
#    win at the call site. Deterministic: the monotonic clock is never 0, so
#    exit(42) proves the user body (computes 0 via a loop) ran, not the
#    built-in. The loop matters: it makes the body NON-inlineable, so this
#    cannot pass by the pre-fix inlining accident — it isolates the
#    dispatch gate itself. Discriminating mutation: drop the
#    builtin_override_lookup gate at the top of ir.kr's call lowering —
#    the built-in then wins and this exits 1 (verified: also fails on the
#    pre-fix compiler for the same reason).
TOTAL=$((TOTAL + 1))
printf '@builtin_override\nfn time_ns() -> uint64 {\n    uint64 acc = 0\n    uint64 i = 0\n    while i < 3 { acc = acc + 1 i = i + 1 }\n    return acc - 3\n}\nfn main() { uint64 t = time_ns() if t == 0 { exit(42) } exit(1) }\n' > /tmp/krc_shadow_$$.kr
if $KRC $KRC_FLAGS /tmp/krc_shadow_$$.kr -o /tmp/krc_shadow_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_shadow_$$
    /tmp/krc_shadow_$$ ; got=$?
    if [ "$got" = "42" ]; then
        PASS=$((PASS + 1))
        echo "  builtin_override_user_wins_ir: PASS (user body won)"
    else
        echo "FAIL: builtin_override_user_wins_ir (exit $got — built-in won over annotated user fn)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: builtin_override_user_wins_ir (compilation failed)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_shadow_$$.kr /tmp/krc_shadow_$$

# 3. Same, legacy backend (separate dispatch chain in codegen.kr).
TOTAL=$((TOTAL + 1))
printf '@builtin_override\nfn time_ns() -> uint64 {\n    uint64 acc = 0\n    uint64 i = 0\n    while i < 3 { acc = acc + 1 i = i + 1 }\n    return acc - 3\n}\nfn main() { uint64 t = time_ns() if t == 0 { exit(42) } exit(1) }\n' > /tmp/krc_shadow_$$.kr
if $KRC $KRC_FLAGS --legacy /tmp/krc_shadow_$$.kr -o /tmp/krc_shadow_$$ > /dev/null 2>&1; then
    chmod +x /tmp/krc_shadow_$$
    /tmp/krc_shadow_$$ ; got=$?
    if [ "$got" = "42" ]; then
        PASS=$((PASS + 1))
        echo "  builtin_override_user_wins_legacy: PASS (user body won)"
    else
        echo "FAIL: builtin_override_user_wins_legacy (exit $got — built-in won over annotated user fn)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: builtin_override_user_wins_legacy (compilation failed)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_shadow_$$.kr /tmp/krc_shadow_$$

# 4. The compile-timer tail must be present on a successful compile. This
#    feature shipped dead for 20+ releases precisely because nothing
#    asserted it — the shadowing stub pinned t_start to 0 and the tail was
#    skipped. Assert the "  (X.XX ms)" shape on normal compiler stdout.
#    Discriminating mutation: restore the old `fn time_ns() { return 0 }`
#    stub in src/main.kr (annotated, to get past the sema error) and
#    rebuild — the tail disappears and this fails.
TOTAL=$((TOTAL + 1))
printf 'fn main() { exit(0) }\n' > /tmp/krc_shadow_$$.kr
timer_out=$($KRC $KRC_FLAGS /tmp/krc_shadow_$$.kr -o /tmp/krc_shadow_$$ 2>/dev/null)
if printf '%s\n' "$timer_out" | grep -qE ' \([0-9]+\.[0-9]{2} ms\)$'; then
    PASS=$((PASS + 1))
    echo "  compile_timer_tail: PASS ($(printf '%s' "$timer_out" | grep -oE '\([0-9]+\.[0-9]{2} ms\)'))"
else
    echo "FAIL: compile_timer_tail (no '(X.XX ms)' tail in: $timer_out)"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/krc_shadow_$$.kr /tmp/krc_shadow_$$

# --- import failure must abort, not emit a binary ---
# A failed import used to print "cannot open import" and then CONTINUE, so a
# file whose missing module happened not to break the parse (e.g. it only used
# built-ins) compiled "successfully", exited 0, and produced a wrong binary.
# Discriminating mutation: drop the `import_failed` check in
# codegen_write_output -> krc exits 0 and the binary appears.
echo "--- import failure aborts ---"
TOTAL=$((TOTAL + 1))
IMP_DIR=$(mktemp -d /tmp/krc_imp_XXXXXX)
# uses ONLY built-ins, so the missing import does not break the parse
printf 'import "no/such/module.kr"\nfn main() {\n    print_str("x")\n    exit(0)\n}\n' > "$IMP_DIR/badimp.kr"
$KRC $KRC_FLAGS "$IMP_DIR/badimp.kr" -o "$IMP_DIR/badimp" >/dev/null 2>&1
IMP_EC=$?
if [ "$IMP_EC" -ne 0 ] && [ ! -f "$IMP_DIR/badimp" ]; then
    PASS=$((PASS + 1))
    echo "  import_failure_aborts: PASS (exit $IMP_EC, no binary emitted)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: import_failure_aborts (exit=$IMP_EC, binary present=$([ -f "$IMP_DIR/badimp" ] && echo yes || echo no))"
fi
# control: a VALID stdlib import must still resolve and run
TOTAL=$((TOTAL + 1))
if $KRC $KRC_FLAGS examples/sha256_test.kr -o "$IMP_DIR/shaok" >/dev/null 2>&1 \
   && "$IMP_DIR/shaok" 2>/dev/null | head -1 | grep -q "^e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855$"; then
    PASS=$((PASS + 1))
    echo "  import_success_control: PASS (std import resolves, FIPS vector correct)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: import_success_control (valid std import must still work)"
fi
rm -rf "$IMP_DIR"

# --- tests/smoke/*.kr ---
# These files existed for a long time but NOTHING RAN THEM: only div_mod.kr was
# referenced anywhere, and only as a convenient source file for the esp32
# --target= validation test, so its own assertions were never checked either.
# tests/smoke/time_ns.kr in particular was written to catch "Windows PE
# time_ns() returns 0" and had never once executed.
#
# Contract: each file declares its expected exit code in a header comment
# (`expected: N`). This loop discovers files automatically, so a new smoke test
# is picked up by dropping it in the directory — no wiring step to forget.
#
# NOTE ON COVERAGE: this runs them for the HOST arch only. Every historical
# time_ns bug was on a cross-target (Windows PE, macOS arm64, Windows ARM64),
# none of which execute here, so this protects the host path and nothing more.
echo ""
echo "--- tests/smoke/*.kr ---"
for SMOKE_SRC in "$DIR"/smoke/*.kr; do
    [ -f "$SMOKE_SRC" ] || continue
    SMOKE_NAME=$(basename "$SMOKE_SRC" .kr)
    SMOKE_EXP=$(head -3 "$SMOKE_SRC" | grep -o 'expected: *[0-9]*' | head -1 | grep -o '[0-9]*')
    TOTAL=$((TOTAL + 1))
    if [ -z "$SMOKE_EXP" ]; then
        FAIL=$((FAIL + 1))
        echo "FAIL: smoke_$SMOKE_NAME (no 'expected: N' header — cannot assert)"
        continue
    fi
    SMOKE_BIN="/tmp/krc_smoke_${SMOKE_NAME}_$$"
    if ! $KRC $KRC_FLAGS "$SMOKE_SRC" -o "$SMOKE_BIN" >/dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        echo "FAIL: smoke_$SMOKE_NAME (compile failed)"
        continue
    fi
    chmod +x "$SMOKE_BIN" 2>/dev/null
    "$SMOKE_BIN" >/dev/null 2>&1
    SMOKE_EC=$?
    if [ "$SMOKE_EC" -eq "$SMOKE_EXP" ]; then
        PASS=$((PASS + 1))
        echo "  smoke_$SMOKE_NAME: PASS (exit $SMOKE_EC)"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: smoke_$SMOKE_NAME (exit $SMOKE_EC, expected $SMOKE_EXP)"
    fi
    rm -f "$SMOKE_BIN"
done

# --- struct table growth (old caps: 64 structs, 16 fields) ---
# Both were size-scaling caps missed when the other buffers were converted.
# The field cap was nearly exhausted in-tree already (an example struct used
# 14 of 16). Discriminating mutation: restore either hard cap -> the matching
# case fails to compile with "struct_table overflow" / "struct fields overflow".
# NOTE the third case: it registers 100 structs BEFORE declaring a wide one, so
# widening the field count has to RE-BASE a populated table (the entry stride
# changes, so entries cannot be block-copied). A fix that only reallocated
# would pass the first two cases and corrupt this one.
# Field names avoid f16/f32/f64 — those are TYPE KEYWORDS, not usable as names.
echo ""
echo "--- struct table growth ---"
ST_DIR=$(mktemp -d /tmp/krc_struct_XXXXXX)

TOTAL=$((TOTAL + 1))
{ for si in $(seq 0 199); do printf 'struct S%d { u64 a  u64 b }\n' "$si"; done
  printf 'fn main() {\n    S0 x\n    S199 y\n    x.a = 20\n    y.b = 22\n    exit(x.a + y.b)\n}\n'
} > "$ST_DIR/many.kr"
if $KRC $KRC_FLAGS "$ST_DIR/many.kr" -o "$ST_DIR/many" >/dev/null 2>&1; then
    chmod +x "$ST_DIR/many"; "$ST_DIR/many" >/dev/null 2>&1; ST_EC=$?
else ST_EC="compile-failed"; fi
if [ "$ST_EC" = 42 ]; then PASS=$((PASS + 1)); echo "  struct_count_200: PASS (old cap 64)"
else FAIL=$((FAIL + 1)); echo "FAIL: struct_count_200 (expected 42, got $ST_EC)"; fi

TOTAL=$((TOTAL + 1))
{ printf 'struct Huge {\n'; for si in $(seq 0 99); do printf '    u64 q%d\n' "$si"; done; printf '}\n'
  printf 'fn main() {\n    Huge h\n    h.q0 = 11\n    h.q99 = 31\n    exit(h.q0 + h.q99)\n}\n'
} > "$ST_DIR/wide.kr"
if $KRC $KRC_FLAGS "$ST_DIR/wide.kr" -o "$ST_DIR/wide" >/dev/null 2>&1; then
    chmod +x "$ST_DIR/wide"; "$ST_DIR/wide" >/dev/null 2>&1; ST_EC2=$?
else ST_EC2="compile-failed"; fi
if [ "$ST_EC2" = 42 ]; then PASS=$((PASS + 1)); echo "  struct_fields_100: PASS (old cap 16)"
else FAIL=$((FAIL + 1)); echo "FAIL: struct_fields_100 (expected 42, got $ST_EC2)"; fi

TOTAL=$((TOTAL + 1))
{ for si in $(seq 0 99); do printf 'struct T%d { u64 a  u64 b }\n' "$si"; done
  printf 'struct Big {\n'; for si in $(seq 0 39); do printf '    u64 q%d\n' "$si"; done; printf '}\n'
  printf 'fn main() {\n    T0 t\n    Big b\n    t.a = 20\n    b.q39 = 22\n    exit(t.a + b.q39)\n}\n'
} > "$ST_DIR/restride.kr"
if $KRC $KRC_FLAGS "$ST_DIR/restride.kr" -o "$ST_DIR/restride" >/dev/null 2>&1; then
    chmod +x "$ST_DIR/restride"; "$ST_DIR/restride" >/dev/null 2>&1; ST_EC3=$?
else ST_EC3="compile-failed"; fi
if [ "$ST_EC3" = 42 ]; then PASS=$((PASS + 1)); echo "  struct_restride_populated: PASS (re-base 100 entries to a wider stride)"
else FAIL=$((FAIL + 1)); echo "FAIL: struct_restride_populated (expected 42, got $ST_EC3)"; fi
rm -rf "$ST_DIR"

# --- LKM (--emit=lkm) ---
# The suite had NO coverage of LKM emission at all, despite it being a shipped
# feature that lays out kernel ABI structs by hand. That gap surfaced when a
# struct-table change had to be hand-verified against the 272-byte
# struct file_operations, because codegen.kr uses 272 for BOTH that and the
# struct-table entry stride. tests/helpers/lkm_check.py asserts the fops size
# directly, so the two can never be silently conflated again.
#
# Checks are pure-python ELF parsing rather than readelf/objdump: gating on an
# external toolchain would SKIP silently on a bare runner, which is how the
# ESP32 disassembly checks lost their coverage.
#
# Discriminating mutation: --emit=obj output (no .modinfo, no init_module)
# is rejected by the same checker.
echo ""
echo "--- LKM emission ---"
LKM_DIR=$(mktemp -d /tmp/krc_lkm_XXXXXX)

TOTAL=$((TOTAL + 1))
if $KRC --arch=x86_64 --emit=lkm "$DIR/../examples/hello_lkm.kr" -o "$LKM_DIR/hello.ko" >/dev/null 2>&1 \
   && python3 "$DIR/helpers/lkm_check.py" "$LKM_DIR/hello.ko" basic >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "  lkm_hello_structure: PASS (ET_REL, .modinfo license, init_module/cleanup_module/__this_module GLOBAL)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: lkm_hello_structure ($(python3 "$DIR/helpers/lkm_check.py" "$LKM_DIR/hello.ko" basic 2>&1 | tail -1))"
fi

TOTAL=$((TOTAL + 1))
if $KRC --arch=x86_64 --emit=lkm "$DIR/../examples/lkm_mmap_test.kr" -o "$LKM_DIR/misc.ko" >/dev/null 2>&1 \
   && python3 "$DIR/helpers/lkm_check.py" "$LKM_DIR/misc.ko" misc >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "  lkm_misc_device_abi: PASS (file_operations 272 B, miscdevice 80 B, misc_register undefined)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: lkm_misc_device_abi ($(python3 "$DIR/helpers/lkm_check.py" "$LKM_DIR/misc.ko" misc 2>&1 | tail -1))"
fi

# The checker must REJECT a plain relocatable object, else it proves nothing.
TOTAL=$((TOTAL + 1))
$KRC --arch=x86_64 --emit=obj "$DIR/../examples/hello.kr" -o "$LKM_DIR/plain.o" >/dev/null 2>&1
if python3 "$DIR/helpers/lkm_check.py" "$LKM_DIR/plain.o" basic >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    echo "FAIL: lkm_checker_discriminates (accepted a non-LKM object)"
else
    PASS=$((PASS + 1))
    echo "  lkm_checker_discriminates: PASS (plain .o correctly rejected)"
fi

# Real-world LKM drivers. These are work-in-progress PCI substrate modules for
# MLRift (BAR mmap, IOMMU map at a caller-chosen IOVA, MSI-X/eventfd, PCI
# probe), ~800 lines each, importing 31 kernel symbols. They are the strongest
# evidence the LKM backend handles more than a hello-world: struct pci_driver
# (280 B), file_operations (272 B) and miscdevice (80 B) are all laid out by
# hand and pinned here, so a codegen change cannot drift a kernel ABI size
# without CI saying so.
#
# NOT loaded or executed — that needs matching kernel headers and real
# hardware. This asserts the module is structurally well-formed, nothing more.
for LKM_DRV in mlrift_pci_warm mlrift_pci_cold; do
    TOTAL=$((TOTAL + 1))
    if [ ! -f "$DIR/../examples/$LKM_DRV.kr" ]; then
        echo "  lkm_driver_$LKM_DRV: SKIP (example not present)"
        TOTAL=$((TOTAL - 1))
        continue
    fi
    if $KRC --arch=x86_64 --emit=lkm "$DIR/../examples/$LKM_DRV.kr" -o "$LKM_DIR/$LKM_DRV.ko" >/dev/null 2>&1 \
       && python3 "$DIR/helpers/lkm_check.py" "$LKM_DIR/$LKM_DRV.ko" pci >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo "  lkm_driver_$LKM_DRV: PASS (pci_driver 280 B, fops 272 B, miscdev 80 B, kernel syms undefined)"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: lkm_driver_$LKM_DRV ($(python3 "$DIR/helpers/lkm_check.py" "$LKM_DIR/$LKM_DRV.ko" pci 2>&1 | tail -1))"
    fi
done

rm -rf "$LKM_DIR"

# --- version consistency ---
# v2.8.28 shipped with BOTH binaries self-reporting 2.8.27. Nothing tied the
# hardcoded strings to the tag, and the release was cut without touching them.
# krc and kr are built from separate source sets (runner.kr + bcj.kr has no
# main.kr), so they cannot share a constant -- the only thing that can keep
# them aligned is a check.
#
# Asserts the BUILT BINARY's output, not just the source text. Grepping the
# source is precisely what missed it: the runner's string had been bumped
# earlier the same day and was stale again by the time the tag was cut.
#
# Discriminating mutation: change any one of the four strings, or add a
# CHANGELOG heading without bumping them, and this fails.
echo ""
echo "--- version consistency ---"
VER_CHANGELOG=$(grep -m1 -oE "^## v[0-9]+\.[0-9]+\.[0-9]+" "$DIR/../CHANGELOG.md" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+")

TOTAL=$((TOTAL + 1))
VER_KRC=$($KRC --version 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
if [ -n "$VER_CHANGELOG" ] && [ "$VER_KRC" = "$VER_CHANGELOG" ]; then
    PASS=$((PASS + 1))
    echo "  version_krc_matches_changelog: PASS (krc reports $VER_KRC)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: version_krc_matches_changelog (krc says '$VER_KRC', CHANGELOG says '$VER_CHANGELOG')"
fi

# All three runner strings must agree with each other AND with the changelog.
TOTAL=$((TOTAL + 1))
VER_RUNNER_SET=$(grep -oE "kr [0-9]+\.[0-9]+\.[0-9]+ \(KernRift fat binary runner\)" "$DIR/../src/runner.kr" \
                 | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | sort -u)
VER_RUNNER_COUNT=$(printf '%s\n' "$VER_RUNNER_SET" | grep -c .)
if [ "$VER_RUNNER_COUNT" = "1" ] && [ "$VER_RUNNER_SET" = "$VER_CHANGELOG" ]; then
    PASS=$((PASS + 1))
    echo "  version_runner_matches_changelog: PASS (all 3 kr strings say $VER_RUNNER_SET)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: version_runner_matches_changelog (kr strings: $(printf '%s' "$VER_RUNNER_SET" | tr '\n' ' '); CHANGELOG: $VER_CHANGELOG)"
fi

# --- packaging/aur/.SRCINFO must be in sync with its PKGBUILD ---------------
# The AUR job in CI regenerates .SRCINFO and diffs it, but CI only runs AFTER a
# tag is pushed — which is exactly too late. v2.8.32 was tagged with a PKGBUILD
# at 2.8.32 and a .SRCINFO still at 2.8.31, and that tag now carries a
# permanently red job, because a tag is a fixed pointer and moving a published
# one is worse than the badge it would fix. So the same check runs here, where
# it fails before anything is tagged.
#
# .SRCINFO is regenerated the way makepkg does it (source the PKGBUILD, emit the
# fields in order) rather than by calling makepkg, which does not exist off Arch.
# That equivalence is not assumed: the file this generator produced is the one
# CI's makepkg-based job accepted.
TOTAL=$((TOTAL + 1))
SRCINFO_PKGBUILD="$DIR/../packaging/aur/PKGBUILD"
SRCINFO_FILE="$DIR/../packaging/aur/.SRCINFO"
if [ ! -f "$SRCINFO_PKGBUILD" ] || [ ! -f "$SRCINFO_FILE" ]; then
    PASS=$((PASS + 1))
    echo "  aur_srcinfo_in_sync: SKIP (no packaging/aur/ in this checkout)"
else
    SRCINFO_GEN=$(bash -c '
        set -e
        source "'"$SRCINFO_PKGBUILD"'"
        printf "pkgbase = %s\n" "$pkgname"
        printf "\tpkgdesc = %s\n" "$pkgdesc"
        printf "\tpkgver = %s\n" "$pkgver"
        printf "\tpkgrel = %s\n" "$pkgrel"
        printf "\turl = %s\n" "$url"
        for a in "${arch[@]}"; do printf "\tarch = %s\n" "$a"; done
        for l in "${license[@]}"; do printf "\tlicense = %s\n" "$l"; done
        for pr in "${provides[@]}"; do printf "\tprovides = %s\n" "$pr"; done
        for o in "${options[@]}"; do printf "\toptions = %s\n" "$o"; done
        for x in "${source_x86_64[@]}"; do printf "\tsource_x86_64 = %s\n" "$x"; done
        for x in "${sha256sums_x86_64[@]}"; do printf "\tsha256sums_x86_64 = %s\n" "$x"; done
        for x in "${source_aarch64[@]}"; do printf "\tsource_aarch64 = %s\n" "$x"; done
        for x in "${sha256sums_aarch64[@]}"; do printf "\tsha256sums_aarch64 = %s\n" "$x"; done
        printf "\npkgname = %s\n" "$pkgname"
    ' 2>/dev/null)
    if [ "$SRCINFO_GEN" = "$(cat "$SRCINFO_FILE")" ]; then
        PASS=$((PASS + 1))
        echo "  aur_srcinfo_in_sync: PASS (.SRCINFO matches PKGBUILD at $(grep -m1 '^pkgver=' "$SRCINFO_PKGBUILD" | cut -d= -f2))"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: aur_srcinfo_in_sync (.SRCINFO is stale -- regenerate it; PKGBUILD says $(grep -m1 '^pkgver=' "$SRCINFO_PKGBUILD" | cut -d= -f2), .SRCINFO says $(grep -m1 'pkgver = ' "$SRCINFO_FILE" | sed 's/.*= //'))"
        diff <(printf '%s\n' "$SRCINFO_GEN") "$SRCINFO_FILE" | head -6
    fi
fi

# The built runner binary, when present, must agree too. Built by `make kr-runner`.
TOTAL=$((TOTAL + 1))
if [ -x "$DIR/../build/kr-bin" ]; then
    VER_KRBIN=$("$DIR/../build/kr-bin" --version 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
    if [ "$VER_KRBIN" = "$VER_CHANGELOG" ]; then
        PASS=$((PASS + 1))
        echo "  version_kr_binary_matches: PASS (kr binary reports $VER_KRBIN)"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: version_kr_binary_matches (kr binary says '$VER_KRBIN', CHANGELOG says '$VER_CHANGELOG')"
    fi
else
    FAIL=$((FAIL + 1))
    echo "FAIL: version_kr_binary_matches (build/kr-bin missing — run 'make kr-runner'; not skipping, the point is to check the built artifact)"
fi

# --- esp32 TWAI loopback example ---
# Build guard for examples/esp32/twai_loopback.kr, which is hardware-validated
# (sends ID 0x123 DLC 2 data AB CD through the GPIO matrix and receives all six
# fields back on an ESP32-D0WD-V3). The full CAN sniffer lives in its own repo;
# this stays in-tree so the ESP32 backend keeps a demanding consumer under CI.
#
# It exercises, in one program: MMIO device blocks at four different peripheral
# bases, peripheral clock gating via DPORT, GPIO matrix signal routing, the
# bit-timing arithmetic, and the esp-image writer.
#
# Not executed — that needs the chip. Asserts the image is structurally sound,
# plus a SOURCE-level check that the derived 40 MHz bit-timing constants have
# not been edited: BTIM0=0x81, BTIM1=0x3E. Published ESP32 timing tables assume
# an 80 MHz APB and are off by 2x here, so a "helpful" correction to a table
# value would silently produce a 250 kbit/s bus.
#
# The timing check is deliberately on the SOURCE, not the emitted bytes. An
# earlier version scanned the code segment for the byte 0x81 — which passes
# whatever the source says, because 0x81 occurs incidentally in Xtensa
# encodings. Verified by mutating BTIM0 to 0x83: the byte scan still passed.
# Proving the constants reach the binary needs a disassembler, and gating on
# one would make this SKIP on a bare runner.
echo ""
echo "--- esp32 TWAI loopback ---"
TWAI_DIR=$(mktemp -d /tmp/krc_twai_XXXXXX)
TOTAL=$((TOTAL + 1))
if $KRC --arch=xtensa --freestanding --target=esp32 "$DIR/../examples/esp32/twai_loopback.kr" \
     -o "$TWAI_DIR/twai.bin" >/dev/null 2>&1 \
   && python3 - "$TWAI_DIR/twai.bin" <<'PYEOF'
import sys
d = open(sys.argv[1], 'rb').read()
assert d[0] == 0xE9, "bad esp-image magic"
assert d[1] == 2, "expected 2 segments, got %d" % d[1]
entry = int.from_bytes(d[4:8], 'little')
assert 0x40080400 <= entry < 0x400A0000, "entry 0x%08x not in IRAM" % entry
off, segs = 24, []
for _ in range(d[1]):
    la = int.from_bytes(d[off:off+4], 'little')
    ln = int.from_bytes(d[off+4:off+8], 'little')
    segs.append((la, ln, d[off+8:off+8+ln]))
    off += 8 + ln
assert segs[0][0] == 0x3FFB0000, "seg0 not DRAM"
assert segs[1][0] == 0x40080400, "seg1 not IRAM"
PYEOF
then
    if grep -q 'Twai.btim0 = 0x81' "$DIR/../examples/esp32/twai_loopback.kr" \
       && grep -q 'Twai.btim1 = 0x3E' "$DIR/../examples/esp32/twai_loopback.kr"; then
        TWAI_TIMING_OK=1
    else
        TWAI_TIMING_OK=0
    fi
else
    TWAI_TIMING_OK=-1
fi
if [ "$TWAI_TIMING_OK" = "1" ]; then
    PASS=$((PASS + 1))
    echo "  esp32_twai_loopback: PASS (2 segments, entry in IRAM, 40MHz timing 0x81/0x3E in source)"
elif [ "$TWAI_TIMING_OK" = "0" ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: esp32_twai_loopback (bit-timing constants changed — 40MHz needs BTIM0=0x81 BTIM1=0x3E)"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: esp32_twai_loopback (build or structural check failed)"
fi
rm -rf "$TWAI_DIR"

# --- esp32 import failure must abort with exit 1, not exit 0 + a written image ---
# Regression for the import_failed bypass (parity with MLRift): codegen_write_output
# checked import_failed, but the esp32 freestanding image path (and the
# asm-listing path) call open_output_or_die directly and never went through
# codegen_write_output, so a build with an unresolvable import printed
# "error: cannot open import: ..." to stderr, wrote an image anyway, and
# exited 0 -- a build script watching $? saw success. Assert the compiler's
# own exit code and that no file was written, not the error text: the error
# text already printed before the fix, so a text-only check would pass
# against the broken compiler and prove nothing.
echo ""
echo "--- esp32 import failure aborts (exit code, not just error text) ---"
ESP_IMP_SRC="/tmp/krc_esp32_import_fail_src_$$.kr"
ESP_IMP_BIN="/tmp/krc_esp32_import_fail_bin_$$.bin"
printf 'import "std/__import_failure_regression_nonexistent.kr"\nfn main() { loop { } }\n' > "$ESP_IMP_SRC"
rm -f "$ESP_IMP_BIN"
$KRC --arch=xtensa --freestanding --target=esp32 "$ESP_IMP_SRC" -o "$ESP_IMP_BIN" >/dev/null 2>&1
ESP_IMP_EXIT=$?
TOTAL=$((TOTAL + 1))
if [ "$ESP_IMP_EXIT" = 1 ] && [ ! -e "$ESP_IMP_BIN" ]; then
    PASS=$((PASS + 1))
    echo "  esp32_import_failure_aborts: PASS (exit=$ESP_IMP_EXIT, no output file written)"
else
    ESP_IMP_HAVE_FILE="no"
    [ -e "$ESP_IMP_BIN" ] && ESP_IMP_HAVE_FILE="yes"
    echo "FAIL: esp32_import_failure_aborts (expected exit 1 and no output file, got exit=$ESP_IMP_EXIT, file written=$ESP_IMP_HAVE_FILE)"
    FAIL=$((FAIL + 1))
fi
rm -f "$ESP_IMP_SRC" "$ESP_IMP_BIN"

# --- esp32 import-free build: positive control for the test above ---
# Minor finding 7 (final review): esp32_import_failure_aborts above asserts
# exit 1 + no file, but never proves the esp32 path can exit 0 + write a file
# AT ALL. If the esp32 build path ever starts exiting 1 for some unrelated
# reason (e.g. a bug in a completely different check), the test above would
# keep passing vacuously -- even with the import_failed guard deleted
# entirely. Pair it with the same-shape build MINUS the bad import, asserting
# the opposite: exit 0 and a file present.
echo ""
echo "--- esp32 import-free build succeeds (positive control) ---"
ESP_IMP_OK_SRC="/tmp/krc_esp32_import_ok_src_$$.kr"
ESP_IMP_OK_BIN="/tmp/krc_esp32_import_ok_bin_$$.bin"
printf 'fn main() { loop { } }\n' > "$ESP_IMP_OK_SRC"
rm -f "$ESP_IMP_OK_BIN"
$KRC --arch=xtensa --freestanding --target=esp32 "$ESP_IMP_OK_SRC" -o "$ESP_IMP_OK_BIN" >/dev/null 2>&1
ESP_IMP_OK_EXIT=$?
TOTAL=$((TOTAL + 1))
if [ "$ESP_IMP_OK_EXIT" = 0 ] && [ -e "$ESP_IMP_OK_BIN" ] && [ -s "$ESP_IMP_OK_BIN" ]; then
    PASS=$((PASS + 1))
    echo "  esp32_import_free_build_ok: PASS (exit=0, $(wc -c < "$ESP_IMP_OK_BIN" | tr -d ' ')B image written)"
else
    ESP_IMP_OK_HAVE_FILE="no"
    [ -e "$ESP_IMP_OK_BIN" ] && ESP_IMP_OK_HAVE_FILE="yes"
    echo "FAIL: esp32_import_free_build_ok (expected exit 0 and an output file, got exit=$ESP_IMP_OK_EXIT, file written=$ESP_IMP_OK_HAVE_FILE)"
    FAIL=$((FAIL + 1))
fi
rm -f "$ESP_IMP_OK_SRC" "$ESP_IMP_OK_BIN"

echo ""
echo "--- --arch value validation ---"
ARCHV_SRC="/tmp/krc_archv_$$.kr"
ARCHV_BIN="/tmp/krc_archv_$$.bin"
printf 'fn main() { uint32 x = 3\n exit(x) }\n' > "$ARCHV_SRC"
for BAD in riscv64 riscv riscvBANANA arm64BANANA x86_64BANANA; do
    TOTAL=$((TOTAL + 1))
    $KRC --arch=$BAD "$ARCHV_SRC" -o "$ARCHV_BIN" >/dev/null 2>&1; AV_ST=$?
    if [ "$AV_ST" != "0" ]; then
        PASS=$((PASS + 1)); echo "  arch_reject_$BAD: PASS (exit $AV_ST)"
    else
        echo "FAIL: arch_reject_$BAD (expected non-zero exit, got 0)"; FAIL=$((FAIL + 1))
    fi
done
# NOTE (final review, item 5): xtensaBANANA is deliberately NOT in the loop
# above. `--arch=xtensa` alone already exits 1 ("xtensa ELF image emission
# not yet implemented") for a reason unrelated to flag parsing -- the
# xtensa ELF emitter is simply unfinished. That means a
# arch_reject_xtensaBANANA test would pass whether or not str_eq_full
# actually rejects the misspelling; it cannot distinguish correct parsing
# from a backend that hard-fails on every xtensa value. It was vacuous and
# has been removed rather than kept as false evidence. If the xtensa
# emitter is ever finished, re-add xtensaBANANA to the BAD list above --
# at that point it will actually test something.
TOTAL=$((TOTAL + 1))
if $KRC --arch=riscv64 "$ARCHV_SRC" -o /dev/null 2>&1 | grep -q "riscv32"; then
    PASS=$((PASS + 1)); echo "  arch_riscv64_names_riscv32: PASS"
else
    echo "FAIL: arch_riscv64_names_riscv32 (message should name riscv32)"; FAIL=$((FAIL + 1))
fi
for GOOD in x86_64 x86-64 amd64 x64 arm64 aarch64 riscv32; do
    TOTAL=$((TOTAL + 1))
    rm -f "$ARCHV_BIN"
    if $KRC --arch=$GOOD "$ARCHV_SRC" -o "$ARCHV_BIN" >/dev/null 2>&1 && [ -s "$ARCHV_BIN" ]; then
        PASS=$((PASS + 1)); echo "  arch_accept_$GOOD: PASS"
    else
        echo "FAIL: arch_accept_$GOOD (should compile and produce a non-empty artifact)"; FAIL=$((FAIL + 1))
    fi
done
rm -f "$ARCHV_SRC" "$ARCHV_BIN"

echo ""
echo "--- std/alloc.kr + std/io.kr regression tests ---"
# Five allocator bugs + one I/O bug, all verified against a pre-fix copy of
# std/alloc.kr / std/io.kr (each test genuinely FAILED before its fix and
# PASSES after — see the task notes for the paste of the pre-fix failures).

# Bug 1: guard pages never guard anything. arena_new's guard_addr was
# base+40+capacity, page-aligned (so mprotect succeeds) only when capacity
# happens to leave the right residue mod 4096 -- true for almost no
# requested capacity. mprotect's return value was never checked, so the
# EINVAL failure was silent and the "guard" was a no-op. capacity=100 is
# deliberately NOT the coincidentally-aligned case.
#
# The guard page, once correctly placed, starts at round_up(raw_end, page)
# -- somewhere in [raw_end, raw_end+page-1] -- and is one page wide. Probing
# at offsets 0 and page from raw_end is enough to guarantee landing inside
# that window regardless of the exact rounding remainder: if the remainder
# is 0 the window is [raw_end, raw_end+page) and offset 0 hits it; if the
# remainder is d>0 the window is [raw_end+d, raw_end+d+page) and offset
# page always falls inside it (d <= page-1 < page < d+page). Both offsets
# stay well inside the slab's actual mmap'd pages either way (mmap always
# rounds the reservation up to whole pages, so even the smaller pre-fix
# reservation covers this), so a fault here is unambiguously the guard
# page firing, not an unrelated out-of-bounds access past the mapping.
# Pre-fix, mprotect silently no-ops and both stores succeed, reaching
# exit(0); post-fix, one of them must SIGSEGV (rc=139).
#
# The offsets are the RUNTIME page size, not a hardcoded 4096. Hardcoding
# it is how the ARM64 breakage below hid for as long as it did.
run_test "alloc_guard_page_protects_unaligned_capacity" 'import "std/alloc.kr"
fn main() {
    uint64 page = alloc_page_size()
    uint64 a = arena_new(100)
    uint64 cap = load64(a)
    uint64 raw_end = a + 40 + cap
    store8(raw_end, 1)
    store8(raw_end + page, 1)
    exit(0)
}' 139

# Bug 1b: the guard was installed with a hardcoded `syscall_raw(10, addr,
# 4096, ...)`. BOTH constants were host assumptions:
#
#   * 10 is mprotect on Linux x86_64 only. aarch64 Linux uses the
#     asm-generic table where 10 is fgetxattr and mprotect is 226. So on
#     Linux ARM64 the guard call was fgetxattr(guard_addr, 4096, NULL, 0)
#     -> -EFAULT, and once bug 1 made the return value honest, all nine
#     arena/pool/heap tests became exit(1). tests/smoke/alloc_guard.kr
#     covers that half, because the smoke corpus is what the x86_64 CI job
#     runs against the ARM64 target under qemu.
#
#   * 4096 is not the page size everywhere. Linux ARM64 is routinely built
#     with 16 KiB or 64 KiB pages, where a merely 4096-aligned addr is
#     rejected with EINVAL.
#
# The two tests below pin each half down on any host. The first checks the
# page size the allocators use really is the granularity mprotect enforces
# -- if it were not, every guard would sit at an address the kernel had
# quietly rounded somewhere else. The second drives the whole 64 KiB code
# path on a 4 KiB host by pre-seeding the measured-page-size cache: 65536
# is a multiple of 4096, so a 4 KiB kernel accepts the larger alignment and
# the placement arithmetic gets exercised for real. Against the pre-fix
# std/alloc.kr, whose slab reserved a flat 8192 of slack and whose guard
# was pinned to a 4096 grid, a 64 KiB page cannot be accommodated at all.
run_test "alloc_page_size_matches_mprotect_alignment" 'import "std/alloc.kr"
fn main() {
    uint64 ps = alloc_page_size()
    uint64 nr = alloc_mprotect_nr()
    if nr == 0 { exit(0) }
    uint64 scratch = alloc(262144)
    uint64 base = (scratch + 65535) & 0xFFFFFFFFFFFF0000
    if syscall_raw(nr, base + ps, ps, 0, 0, 0, 0) != 0 { exit(1) }
    if ps > 4096 {
        if syscall_raw(nr, base + ps + ps / 2, ps, 0, 0, 0, 0) == 0 { exit(2) }
    }
    if syscall_raw(nr, base + ps + 17, ps, 0, 0, 0, 0) == 0 { exit(3) }
    exit(0)
}' 0

# Windows has no syscall mprotect at all -- a guard there would have to go
# through VirtualProtect -- so alloc_mprotect_nr() returns 0 for it. That
# must mean "constructs unguarded, and says so in the header", NOT "every
# arena/pool/heap aborts on a supported platform". The two events are
# different: a platform with no guard mechanism is not a guard mechanism
# that failed, and only the second is a reason to exit(1).
#
# Forcing alloc_guard_state to 2 drives exactly the branch Windows takes,
# on a host that can actually execute it. It is the Windows logic, not the
# Windows ABI -- no Windows machine ran this -- but it is the half that was
# broken, and the PE binaries are additionally exercised by
# tests/smoke/alloc_guard.kr under the cross-platform workflow.
run_test "alloc_unguarded_platform_still_allocates" 'import "std/alloc.kr"
fn main() {
    alloc_guard_state = 2
    uint64 a = arena_new(4096)
    uint64 p1 = arena_alloc(a, 64)
    store64(p1, 7)
    if load64(p1) != 7 { exit(1) }
    if load64(a + 32) != 0 { exit(2) }
    uint64 p = pool_new(64, 8)
    uint64 s = pool_alloc(p)
    if s == 0 { exit(3) }
    if load64(p + 48) != 0 { exit(4) }
    uint64 h = heap_new(4096)
    uint64 hp = heap_alloc(h, 64)
    if hp == 0 { exit(5) }
    if load64(h + 48) != 0 { exit(6) }
    // Nothing was protected, so the slack past capacity is plain memory.
    store8(a + 40 + 4096, 1)
    exit(0)
}' 0

# macOS ARM64 runs 16 KiB pages, so it takes the probe branch between the
# 4 KiB and 64 KiB cases. A 4 KiB host cannot make mprotect reject a
# 4096-aligned address, so the *probe* branch is unreachable here, but the
# placement and sizing arithmetic downstream of it is exactly what a 16 KiB
# page exercises -- and that is what this drives.
run_test "alloc_guard_page_at_16k_page_size" 'import "std/alloc.kr"
fn main() {
    alloc_page_size_cache = 16384
    uint64 a = arena_new(100)
    uint64 p = arena_alloc(a, 96)
    store8(p, 1)
    store8(p + 95, 1)
    store8(a + 40 + 99, 1)
    uint64 cap = load64(a)
    uint64 raw_end = a + 40 + cap
    store8(raw_end, 1)
    store8(raw_end + 16384, 1)
    exit(0)
}' 139

run_test "alloc_guard_page_at_64k_page_size" 'import "std/alloc.kr"
fn main() {
    alloc_page_size_cache = 65536
    uint64 a = arena_new(100)
    // Every byte of the requested capacity must still be writable: a
    // guard rounded the wrong way, or a slab sized for 4 KiB slack while
    // aligning to 64 KiB, would swallow part of it.
    uint64 p = arena_alloc(a, 96)
    store8(p, 1)
    store8(p + 95, 1)
    store8(a + 40 + 99, 1)
    uint64 cap = load64(a)
    uint64 raw_end = a + 40 + cap
    store8(raw_end, 1)
    store8(raw_end + 65536, 1)
    exit(0)
}' 139

# Bug 2: heap_new(capacity < 40) underflows `capacity - 40` on u64,
# producing a phantom ~2^64-byte free block instead of rejecting the
# nonsensical request. Pre-fix this "succeeds" (exit 0); post-fix it must
# be rejected up front.
run_test "alloc_heap_new_rejects_underflow_capacity" 'import "std/alloc.kr"
fn main() {
    uint64 h = heap_new(10)
    exit(0)
}' 1

# Bug 3: pool_new(size, 0) sets free_head to a slot address unconditionally,
# even when count == 0 (so there are no real slots) -- pool_alloc then
# hands out that phantom slot instead of correctly reporting "out of
# slots". Pre-fix, pool_alloc succeeds and the program reaches exit(0).
run_test "alloc_pool_new_zero_count_no_phantom_slot" 'import "std/alloc.kr"
fn main() {
    uint64 p = pool_new(16, 0)
    uint64 s = pool_alloc(p)
    exit(0)
}' 1

# Bug 4: heap_free only coalesces forward (into the next physical block),
# never backward (into the preceding one). Allocate 40/40/80 out of a
# 280-byte heap (exactly filling it, no leftover tail block), then free
# the middle block, then the first (forward-merges into one 120-byte free
# block), then the last (the only adjacent free block is BEHIND it, which
# forward coalescing cannot see). Without backward merging the free list
# ends up with two blocks (120 and 80) neither large enough for a 150-byte
# request, even though 200+ contiguous bytes are free -- heap_alloc aborts
# "out of memory" (exit 1). With backward merging the whole heap reunites
# into one free block and the allocation succeeds (exit 0).
run_test "alloc_heap_free_backward_coalesce" 'import "std/alloc.kr"
fn main() {
    uint64 h = heap_new(280)
    uint64 a = heap_alloc(h, 40)
    uint64 b = heap_alloc(h, 40)
    uint64 c = heap_alloc(h, 80)
    heap_free(h, b)
    heap_free(h, a)
    heap_free(h, c)
    uint64 d = heap_alloc(h, 150)
    exit(0)
}' 0

# Bug 5: read_file returned 0 both when `path` could not be opened AND
# when it opened fine but was zero-length -- the two were indistinguishable.
# Create a genuinely empty (but existing) file, then check read_file
# returns non-zero for it while still returning 0 for a path that does not
# exist at all. Pre-fix, the empty-file case incorrectly returns 0 too
# (exit 1 below); post-fix both checks pass (exit 0).
run_test "io_read_file_empty_vs_missing" 'import "std/io.kr"
fn main() {
    uint64 empty_path = "/tmp/krc_test_read_file_bug5_empty.txt"
    uint64 missing_path = "/tmp/krc_test_read_file_bug5_does_not_exist_xyz.txt"
    uint64 fd = file_open(empty_path, 1)
    file_close(fd)
    uint64 empty_buf = read_file(empty_path)
    uint64 missing_buf = read_file(missing_path)
    if empty_buf == 0 {
        exit(1)
    }
    if missing_buf != 0 {
        exit(2)
    }
    exit(0)
}' 0

echo ""
echo "--- call-argument capacity ---"
# call_arg_vregs holds 32 slots. The arg-collection loop stops at 32; without
# the post-loop guard the extra arguments are silently DROPPED and the callee
# reads garbage — a 33-arg call returned sum(1..32) with no diagnostic.
# MLRift had drifted without this guard while KernRift always had it.
# `many` is self-recursive ON PURPOSE: a non-recursive version gets erased by
# the AST inliner, the IR_CALL path never runs, and the test passes vacuously
# against an unguarded compiler. Do not "simplify" the recursion away.
CA_SRC="/tmp/krc_callargs_$$.kr"
CA_BIN="/tmp/krc_callargs_$$.bin"
gen_call_args() {   # $1 = arg count -> writes CA_SRC
    { printf 'fn many('
      i=1; while [ $i -le $1 ]; do [ $i -gt 1 ] && printf ', '; printf 'uint64 p%s' $i; i=$((i+1)); done
      printf ') -> uint64 {\n    if p1 > 1000000 {\n        return many('
      i=1; while [ $i -le $1 ]; do [ $i -gt 1 ] && printf ', '; printf 'p%s - 1' $i; i=$((i+1)); done
      printf ')\n    }\n    return p1 + p%s\n}\n' $1
      printf 'fn main() {\n    uint64 r = many('
      i=1; while [ $i -le $1 ]; do [ $i -gt 1 ] && printf ', '; printf '%s' $i; i=$((i+1)); done
      printf ')\n    exit(r)\n}\n'
    } > "$CA_SRC"
}
TOTAL=$((TOTAL + 1))
gen_call_args 33
CA_ERR=$($KRC --arch=$RUN_ARCH "$CA_SRC" -o "$CA_BIN" 2>&1); CA_ST=$?
if [ "$CA_ST" != "0" ] && echo "$CA_ERR" | grep -q "too many call arguments (max 32)"; then
    PASS=$((PASS + 1)); echo "  call_args_33_rejected: PASS (exit $CA_ST, clean diagnostic)"
else
    echo "FAIL: call_args_33_rejected (expected non-zero + 'too many call arguments', got exit $CA_ST: '$CA_ERR')"
    FAIL=$((FAIL + 1))
fi
# Positive control: 32 must still compile AND run correctly. Without this, a
# parser that rejected every call would pass the test above.
TOTAL=$((TOTAL + 1))
gen_call_args 32
rm -f "$CA_BIN"
if $KRC --arch=$RUN_ARCH "$CA_SRC" -o "$CA_BIN" >/dev/null 2>&1 && [ -s "$CA_BIN" ]; then
    chmod +x "$CA_BIN"; "$CA_BIN"; CA_RUN=$?
    if [ "$CA_RUN" = "33" ]; then    # p1 + p32 = 1 + 32
        PASS=$((PASS + 1)); echo "  call_args_32_accepted: PASS (compiles and returns 33)"
    else
        echo "FAIL: call_args_32_accepted (ran but returned $CA_RUN, want 33)"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: call_args_32_accepted (should compile to a non-empty artifact)"; FAIL=$((FAIL + 1))
fi
# The same 32-arg call, cross-compiled to arm64. AAPCS64 passes 8 in x0-x7, so
# 32 args need 24 outgoing stack slots; the arm64 IR_ARG lowering capped them
# at 16 (24 args) and aborted with "a64 overflow args overflow (max 16)" while
# the front end advertised "max 32". The cap is now 24 so the advertised limit
# is true on both arches -- it cannot be made arch-specific, because one .kr
# compiles to all 8 fat-binary slices at once and a 25-arg call would build
# the x86 slices and then abort the build on the arm64 one.
# Compile-only is already discriminating (the old compiler exited 1 here);
# the qemu run additionally proves the stack args land where the callee looks.
TOTAL=$((TOTAL + 1))
rm -f "$CA_BIN"
CA_A64_ERR=$($KRC --arch=arm64 "$CA_SRC" -o "$CA_BIN" 2>&1); CA_A64_ST=$?
if [ "$CA_A64_ST" = "0" ] && [ -s "$CA_BIN" ]; then
    PASS=$((PASS + 1)); echo "  call_args_32_accepted_arm64: PASS (cross-compiles)"
else
    echo "FAIL: call_args_32_accepted_arm64 (exit $CA_A64_ST: '$CA_A64_ERR')"; FAIL=$((FAIL + 1))
fi
CA_QEMU="$(command -v qemu-aarch64-static || true)"
if [ -n "$CA_QEMU" ] && [ -s "$CA_BIN" ]; then
    TOTAL=$((TOTAL + 1))
    chmod +x "$CA_BIN"; "$CA_QEMU" "$CA_BIN" >/dev/null 2>&1; CA_RUN=$?
    if [ "$CA_RUN" = "33" ]; then
        PASS=$((PASS + 1)); echo "  call_args_32_runs_arm64: PASS (returns 33 under qemu)"
    else
        echo "FAIL: call_args_32_runs_arm64 (returned $CA_RUN, want 33)"; FAIL=$((FAIL + 1))
    fi
fi
# Boundary: 25 args = the first count that needs a 17th stack slot, i.e. the
# exact case the old cap rejected. 24 always worked, so a test at 24 proves
# nothing.
TOTAL=$((TOTAL + 1))
gen_call_args 25
rm -f "$CA_BIN"
CA_A64_ERR=$($KRC --arch=arm64 "$CA_SRC" -o "$CA_BIN" 2>&1); CA_A64_ST=$?
if [ "$CA_A64_ST" = "0" ] && [ -s "$CA_BIN" ]; then
    if [ -n "$CA_QEMU" ]; then
        chmod +x "$CA_BIN"; "$CA_QEMU" "$CA_BIN" >/dev/null 2>&1; CA_RUN=$?
        if [ "$CA_RUN" = "26" ]; then
            PASS=$((PASS + 1)); echo "  call_args_25_arm64: PASS (17th stack slot, returns 26)"
        else
            echo "FAIL: call_args_25_arm64 (returned $CA_RUN, want 26)"; FAIL=$((FAIL + 1))
        fi
    else
        PASS=$((PASS + 1)); echo "  call_args_25_arm64: PASS (cross-compiles; no qemu to run it)"
    fi
else
    echo "FAIL: call_args_25_arm64 (exit $CA_A64_ST: '$CA_A64_ERR')"; FAIL=$((FAIL + 1))
fi
rm -f "$CA_SRC" "$CA_BIN"

# call_ptr has its own, separate 6-arg cap (cp_arg_vregs holds 6 slots).
# Unlike the direct-call loop above, the call_ptr collection loop
# (`while wca != 0 && cp_count < 6`) had NO post-loop guard: a 7th argument's
# ir_lower_expr was simply never collected, so the argument was not merely
# unpassed -- its side effects vanished. `bump` proves the side effect
# happened or didn't via a static global, since call_ptr's own return value
# is not enough to distinguish "argument dropped" from "argument garbage".
#
# The guard above lives in the shared IR lowering only, which is the
# DEFAULT backend but not the only one: `--legacy` has its own call_ptr
# codegen (src/codegen.kr) with the identical shape of bug -- it evaluates
# every argument (so the 7th's side effects DO happen there, unlike the IR
# backend) but its register-loading loops only assign int/float args 0-5 to
# a GPR/xmm register, so a 7th argument is silently never loaded into
# anything the callee reads. Measured before the legacy-path fix: a 7-arg
# call_ptr compiled at exit 0 and returned 21 instead of 28. The row below
# exercises `--legacy` explicitly so a fix to only one backend cannot pass
# this suite.
CP_SRC="/tmp/krc_callptrargs_$$.kr"
CP_BIN="/tmp/krc_callptrargs_$$.bin"
cat > "$CP_SRC" <<'KREOF'
static uint64 side = 0
fn bump(uint64 x) -> uint64 { side = x; return x }
fn f7(uint64 a, uint64 b, uint64 c, uint64 d, uint64 e, uint64 g, uint64 h) -> uint64 {
    return a + b + c + d + e + g + h
}
fn main() {
    uint64 p = fn_addr("f7")
    uint64 r = call_ptr(p, 1, 2, 3, 4, 5, 6, bump(77))
    exit(r)
}
KREOF
TOTAL=$((TOTAL + 1))
CP_ERR=$($KRC --arch=$RUN_ARCH "$CP_SRC" -o "$CP_BIN" 2>&1); CP_ST=$?
if [ "$CP_ST" != "0" ] && echo "$CP_ERR" | grep -q "too many call_ptr arguments (max 6)"; then
    PASS=$((PASS + 1)); echo "  call_ptr_args_7_rejected: PASS (exit $CP_ST, clean diagnostic)"
else
    echo "FAIL: call_ptr_args_7_rejected (expected non-zero + 'too many call_ptr arguments', got exit $CP_ST: '$CP_ERR')"
    FAIL=$((FAIL + 1))
fi
# Positive control: exactly 6 args must still compile and run correctly.
CP6_SRC="/tmp/krc_callptrargs6_$$.kr"
cat > "$CP6_SRC" <<'KREOF'
fn f6(uint64 a, uint64 b, uint64 c, uint64 d, uint64 e, uint64 g) -> uint64 {
    return a + b + c + d + e + g
}
fn main() {
    uint64 p = fn_addr("f6")
    uint64 r = call_ptr(p, 1, 2, 3, 4, 5, 6)
    exit(r)
}
KREOF
TOTAL=$((TOTAL + 1))
rm -f "$CP_BIN"
if $KRC --arch=$RUN_ARCH "$CP6_SRC" -o "$CP_BIN" >/dev/null 2>&1 && [ -s "$CP_BIN" ]; then
    chmod +x "$CP_BIN"; "$CP_BIN"; CP6_RUN=$?
    if [ "$CP6_RUN" = "21" ]; then
        PASS=$((PASS + 1)); echo "  call_ptr_args_6_accepted: PASS (compiles and returns 21)"
    else
        echo "FAIL: call_ptr_args_6_accepted (ran but returned $CP6_RUN, want 21)"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: call_ptr_args_6_accepted (should compile to a non-empty artifact)"; FAIL=$((FAIL + 1))
fi
# `--legacy` twin of call_ptr_args_7_rejected: same 7-arg source, the other
# backend. Positive control (6 args) is call_ptr_args_6_accepted above,
# rerun implicitly since a `--legacy` cap that rejected everything would
# still need catching -- so also assert the 6-arg legacy build runs.
#
# PINNED TO x86_64, AND NOT BECAUSE OF THE HOST. The 6-argument cap is a
# property of the x86 lowering ONLY. codegen_aarch64.kr's own call_ptr
# lowering loads x0-x7 and spills the rest to the stack, so arm64 legacy has
# NO 6-arg defect -- measured under qemu-aarch64-static: 7 args -> 28, 8 -> 36,
# both correct. Running this row at $RUN_ARCH would therefore FAIL on an
# aarch64 host (RUN_ARCH becomes arm64, the build succeeds at rc 0, the row
# expects a refusal) -- and this project has a native ARM64 CI job, so that is
# a red CI, not a hypothetical. DO NOT "fix" it by adding a cap to
# codegen_aarch64.kr: that would DELETE working 7- and 8-argument support.
TOTAL=$((TOTAL + 1))
CP_LG_ERR=$($KRC --arch=x86_64 --legacy "$CP_SRC" -o "$CP_BIN" 2>&1); CP_LG_ST=$?
if [ "$CP_LG_ST" != "0" ] && echo "$CP_LG_ERR" | grep -q "too many call_ptr arguments (max 6)"; then
    PASS=$((PASS + 1)); echo "  call_ptr_args_7_rejected_legacy: PASS (exit $CP_LG_ST, clean diagnostic)"
else
    echo "FAIL: call_ptr_args_7_rejected_legacy (expected non-zero + 'too many call_ptr arguments', got exit $CP_LG_ST: '$CP_LG_ERR')"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
rm -f "$CP_BIN"
# TWO ASSERTIONS, TWO ARCHES, AND THE SPLIT IS THE WHOLE POINT.
#
# The x86_64 half is COMPILE-ONLY and credits the refusal row above: it proves
# the new cap does not over-fire at six on the same arch that refuses at seven.
# It must NOT be run -- pinning the RUN to x86_64 is what reddened CI on the
# native ARM64 job (run 31047947720): the build succeeded, the artifact was
# x86_64, and executing it on aarch64 gave exit 126, "cannot execute".
#
# The native half RUNS, at $RUN_ARCH, because a positive control that never
# executes cannot show the six-argument path still produces the right ANSWER.
# On aarch64 that exercises codegen_aarch64.kr's own call_ptr lowering, which
# has no cap at all (measured 7->28, 8->36) -- six returning 21 there is still
# the correct expectation.
TOTAL=$((TOTAL + 1))
if $KRC --arch=x86_64 --legacy "$CP6_SRC" -o "$CP_BIN" >/dev/null 2>&1 && [ -s "$CP_BIN" ]; then
    PASS=$((PASS + 1)); echo "  call_ptr_args_6_accepted_legacy_x86: PASS (compiles; not run -- may be a foreign arch here)"
else
    echo "FAIL: call_ptr_args_6_accepted_legacy_x86 (six args must still compile on the arch that refuses seven)"; FAIL=$((FAIL + 1))
fi
rm -f "$CP_BIN"
if $KRC --arch=$RUN_ARCH --legacy "$CP6_SRC" -o "$CP_BIN" >/dev/null 2>&1 && [ -s "$CP_BIN" ]; then
    chmod +x "$CP_BIN"; "$CP_BIN"; CP6_LG_RUN=$?
    if [ "$CP6_LG_RUN" = "21" ]; then
        PASS=$((PASS + 1)); echo "  call_ptr_args_6_accepted_legacy: PASS (native $RUN_ARCH, runs and returns 21)"
    else
        echo "FAIL: call_ptr_args_6_accepted_legacy (native $RUN_ARCH ran but returned $CP6_LG_RUN, want 21)"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: call_ptr_args_6_accepted_legacy (should compile to a non-empty artifact on $RUN_ARCH)"; FAIL=$((FAIL + 1))
fi
rm -f "$CP_SRC" "$CP6_SRC" "$CP_BIN"

echo ""
echo "--- float literal return kinds ---"
# tc_expr_kind reported EVERY FloatLit as f64, ignoring the `f` suffix, so the
# C7 return-kind check rejected `fn f() -> f32 { return 1.5f }` while the very
# same literal bound to an `f32` local first sailed through. std/gguf.kr routes
# every f32 return through a local for exactly this reason, and because sema
# checks every function in an imported file whether or not it is called, one
# un-worked-around `return 0.0f` made every importer fail to build.
#
# The functions below are self-recursive ON PURPOSE: a straight-line version
# gets erased by the AST inliner (which runs even at -O0), the IR_CALL/IR_RET
# path never executes, and the returned bits are never actually tested. Do not
# "simplify" the recursion away.
#
# This asserts VALUES, not just "it compiles": a fix that silenced the
# diagnostic while leaving f64 bits in xmm0 would still fail here.
FR_SRC="/tmp/krc_fret_$$.kr"
FR_BIN="/tmp/krc_fret_$$.bin"
cat > "$FR_SRC" <<'KREOF'
fn f32_lit_pos(uint64 n) -> f32 {
    if n > 1000000 { return f32_lit_pos(n - 1) }
    return 42.5f
}
fn f32_var_pos(uint64 n) -> f32 {
    if n > 1000000 { return f32_var_pos(n - 1) }
    f32 z = 42.5f
    return z
}
fn f32_lit_neg(uint64 n) -> f32 {
    if n > 1000000 { return f32_lit_neg(n - 1) }
    return -7.25f
}
fn f32_var_neg(uint64 n) -> f32 {
    if n > 1000000 { return f32_var_neg(n - 1) }
    f32 z = -7.25f
    return z
}
fn f32_lit_zero(uint64 n) -> f32 {
    if n > 1000000 { return f32_lit_zero(n - 1) }
    return 0.0f
}
fn f32_lit_sci(uint64 n) -> f32 {
    if n > 1000000 { return f32_lit_sci(n - 1) }
    return 1.25e2f
}
fn f64_lit_pos(uint64 n) -> f64 {
    if n > 1000000 { return f64_lit_pos(n - 1) }
    return 42.5
}
fn f64_var_pos(uint64 n) -> f64 {
    if n > 1000000 { return f64_var_pos(n - 1) }
    f64 z = 42.5
    return z
}
fn f64_lit_neg(uint64 n) -> f64 {
    if n > 1000000 { return f64_lit_neg(n - 1) }
    return -7.25
}
fn f64_var_neg(uint64 n) -> f64 {
    if n > 1000000 { return f64_var_neg(n - 1) }
    f64 z = -7.25
    return z
}
fn f64_lit_zero(uint64 n) -> f64 {
    if n > 1000000 { return f64_lit_zero(n - 1) }
    return 0.0
}
fn fret_fail(uint64 rc, uint64 id) -> uint64 {
    if rc != 0 { return rc }
    return id
}
fn main() {
    uint64 rc = 0
    f32 s4 = 4.0f
    f64 d4 = 4.0
    if f32_to_int(f32_lit_pos(1) * s4) != 170 { rc = fret_fail(rc, 1) }
    if f32_to_int(f32_var_pos(1) * s4) != 170 { rc = fret_fail(rc, 2) }
    if f32_to_int(f32_lit_neg(1) * s4) != -29 { rc = fret_fail(rc, 3) }
    if f32_to_int(f32_var_neg(1) * s4) != -29 { rc = fret_fail(rc, 4) }
    f32 zf = f32_lit_zero(1)
    if f32_to_int(zf) != 0 { rc = fret_fail(rc, 5) }
    if zf > 0.0f { rc = fret_fail(rc, 6) }
    if zf < 0.0f { rc = fret_fail(rc, 7) }
    if f32_to_int(f32_lit_sci(1)) != 125 { rc = fret_fail(rc, 8) }
    if f64_to_int(f64_lit_pos(1) * d4) != 170 { rc = fret_fail(rc, 9) }
    if f64_to_int(f64_var_pos(1) * d4) != 170 { rc = fret_fail(rc, 10) }
    if f64_to_int(f64_lit_neg(1) * d4) != -29 { rc = fret_fail(rc, 11) }
    if f64_to_int(f64_var_neg(1) * d4) != -29 { rc = fret_fail(rc, 12) }
    f64 zd = f64_lit_zero(1)
    if f64_to_int(zd) != 0 { rc = fret_fail(rc, 13) }
    if zd > 0.0 { rc = fret_fail(rc, 14) }
    if zd < 0.0 { rc = fret_fail(rc, 15) }
    exit(rc)
}
KREOF
TOTAL=$((TOTAL + 1))
FR_ERR=$($KRC --arch=$RUN_ARCH "$FR_SRC" -o "$FR_BIN" 2>&1); FR_ST=$?
if [ "$FR_ST" = "0" ] && [ -s "$FR_BIN" ]; then
    chmod +x "$FR_BIN"; "$FR_BIN"; FR_RUN=$?
    if [ "$FR_RUN" = "0" ]; then
        PASS=$((PASS + 1)); echo "  float_literal_return_values: PASS (15 checks)"
    else
        echo "FAIL: float_literal_return_values (check #$FR_RUN returned the wrong value)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: float_literal_return_values (should compile: '$FR_ERR')"; FAIL=$((FAIL + 1))
fi
# Negative controls: the C7 check must still FIRE on a genuine kind mismatch.
# Both directions were silent miscompiles, not harmless: a non-inlined
# `-> f64 { return 1.5f }` put f32 bits in xmm0 and the caller read 0.0.
TOTAL=$((TOTAL + 1))
printf 'fn g(uint64 n) -> f64 {\n if n > 1000000 { return g(n - 1) }\n return 1.5f\n}\nfn main() { exit(f64_to_int(g(1))) }\n' > "$FR_SRC"
FR_ERR=$($KRC --arch=$RUN_ARCH "$FR_SRC" -o "$FR_BIN" 2>&1); FR_ST=$?
if [ "$FR_ST" != "0" ] && echo "$FR_ERR" | grep -q "return value float kind does not match"; then
    PASS=$((PASS + 1)); echo "  f32_literal_in_f64_fn_rejected: PASS (exit $FR_ST)"
else
    echo "FAIL: f32_literal_in_f64_fn_rejected (expected the C7 diagnostic, got exit $FR_ST: '$FR_ERR')"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
printf 'fn g(uint64 n) -> f32 {\n if n > 1000000 { return g(n - 1) }\n return 1.5\n}\nfn main() { exit(f32_to_int(g(1))) }\n' > "$FR_SRC"
FR_ERR=$($KRC --arch=$RUN_ARCH "$FR_SRC" -o "$FR_BIN" 2>&1); FR_ST=$?
if [ "$FR_ST" != "0" ] && echo "$FR_ERR" | grep -q "return value float kind does not match"; then
    PASS=$((PASS + 1)); echo "  f64_literal_in_f32_fn_rejected: PASS (exit $FR_ST)"
else
    echo "FAIL: f64_literal_in_f32_fn_rejected (expected the C7 diagnostic, got exit $FR_ST: '$FR_ERR')"
    FAIL=$((FAIL + 1))
fi
rm -f "$FR_SRC" "$FR_BIN"

# --- float call result in the LEFT operand position (arm64 regression) ---
# arm64 lowered `f32_fn() * s` to an INTEGER mul of two float bit patterns and
# printed 0 instead of 170, while `s * f32_fn()` was correct. The BinOp
# lowering only consults the LEFT operand's float kind, and the call result's
# fkind comes from the fn_ret_float table -- which ir_emit_arm64_function
# never populated (only ir_emit_x86_function did). Every slice after the
# first also started from an empty table because the per-slice reset cleared
# it, and the per-function registration only ever caught callees defined
# EARLIER in the file, so a forward reference miscompiled on x86 too.
# The table is now seeded once at parse time, like fn_ret_signed.
#
# The callees are self-recursive ON PURPOSE: a non-recursive one is erased by
# the AST inliner (which runs even at -O0), the IR_CALL path never executes,
# and the test passes against a broken compiler. Do not simplify them away.
#
# Both operand positions and both float widths are covered, because only the
# left-operand form was wrong -- a test that checked `s * f32_fn()` alone
# would have been green throughout.
echo ""
echo "--- float call result operand position ---"
FCO_SRC="/tmp/krc_fcall_$$.kr"
FCO_BIN="/tmp/krc_fcall_$$.bin"
FCO_WANT="170
170
46
170
170
170"
cat > "$FCO_SRC" <<'KREOF'
fn g32(uint64 n) -> f32 { if n > 1000000 { return g32(n - 1) }  return 42.5f }
fn g64(uint64 n) -> f64 { if n > 1000000 { return g64(n - 1) }  return 42.5 }
fn main() {
    f32 s = 4.0f
    f64 d = 4.0
    println(f32_to_int(g32(1) * s))     // call LEFT, f32 var  -> 170
    println(f32_to_int(s * g32(1)))     // call RIGHT, f32 var -> 170
    println(f32_to_int(g32(1) + s))     // call LEFT, '+'      -> 46
    println(f64_to_int(g64(1) * d))     // call LEFT, f64 var  -> 170
    println(f64_to_int(d * g64(1)))     // call RIGHT, f64 var -> 170
    println(f32_to_int(g32(1) * 4.0f))  // call LEFT, literal  -> 170
    exit(0)
}
KREOF
TOTAL=$((TOTAL + 1))
if $KRC --arch=$RUN_ARCH "$FCO_SRC" -o "$FCO_BIN" >/dev/null 2>&1 && [ -s "$FCO_BIN" ]; then
    chmod +x "$FCO_BIN"; FCO_GOT=$("$FCO_BIN" 2>&1)
    if [ "$FCO_GOT" = "$FCO_WANT" ]; then
        PASS=$((PASS + 1)); echo "  float_call_operand_position_host: PASS (6 forms, $RUN_ARCH)"
    else
        echo "FAIL: float_call_operand_position_host (want '$(echo $FCO_WANT)', got '$(echo $FCO_GOT)')"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: float_call_operand_position_host (should compile)"; FAIL=$((FAIL + 1))
fi
# Cross-compile the same program to arm64 and run it under qemu. Without this
# the whole defect is invisible to an x86_64 runner -- the host check above
# only ever exercises one backend.
FCO_QEMU="$(command -v qemu-aarch64-static || true)"
if [ -n "$FCO_QEMU" ]; then
    TOTAL=$((TOTAL + 1))
    rm -f "$FCO_BIN"
    if $KRC --arch=arm64 "$FCO_SRC" -o "$FCO_BIN" >/dev/null 2>&1 && [ -s "$FCO_BIN" ]; then
        chmod +x "$FCO_BIN"; FCO_GOT=$("$FCO_QEMU" "$FCO_BIN" 2>&1)
        if [ "$FCO_GOT" = "$FCO_WANT" ]; then
            PASS=$((PASS + 1)); echo "  float_call_operand_position_arm64: PASS (6 forms under qemu)"
        else
            echo "FAIL: float_call_operand_position_arm64 (want '$(echo $FCO_WANT)', got '$(echo $FCO_GOT)')"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL: float_call_operand_position_arm64 (should cross-compile)"; FAIL=$((FAIL + 1))
    fi
fi
# Forward reference: the callee is defined AFTER main. Registering the return
# kind during lowering only caught callees defined earlier, so this form was
# wrong on BOTH arches (exit 0 instead of 170).
cat > "$FCO_SRC" <<'KREOF'
fn main() {
    f32 s = 4.0f
    f64 d = 4.0
    if f32_to_int(fwd32(1) * s) != 170 { exit(1) }
    if f64_to_int(fwd64(1) * d) != 170 { exit(2) }
    exit(0)
}
fn fwd32(uint64 n) -> f32 { if n > 1000000 { return fwd32(n - 1) }  return 42.5f }
fn fwd64(uint64 n) -> f64 { if n > 1000000 { return fwd64(n - 1) }  return 42.5 }
KREOF
TOTAL=$((TOTAL + 1))
rm -f "$FCO_BIN"
if $KRC --arch=$RUN_ARCH "$FCO_SRC" -o "$FCO_BIN" >/dev/null 2>&1 && [ -s "$FCO_BIN" ]; then
    chmod +x "$FCO_BIN"; "$FCO_BIN"; FCO_RUN=$?
    if [ "$FCO_RUN" = "0" ]; then
        PASS=$((PASS + 1)); echo "  float_call_forward_declared: PASS"
    else
        echo "FAIL: float_call_forward_declared (check #$FCO_RUN wrong; f32=1 f64=2)"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: float_call_forward_declared (should compile)"; FAIL=$((FAIL + 1))
fi
rm -f "$FCO_SRC" "$FCO_BIN"

echo "--- --emit / --target value validation ---"
EV_SRC="/tmp/krc_ev_$$.kr"
EV_BIN="/tmp/krc_ev_$$.bin"
printf 'fn main() { uint32 x = 3\n exit(x) }\n' > "$EV_SRC"
for BAD in elfBANANA winBANANA asmBANANA macBANANA; do
    TOTAL=$((TOTAL + 1))
    $KRC --emit=$BAD "$EV_SRC" -o "$EV_BIN" >/dev/null 2>&1; EV_ST=$?
    if [ "$EV_ST" != "0" ]; then
        PASS=$((PASS + 1)); echo "  emit_reject_$BAD: PASS (exit $EV_ST)"
    else
        echo "FAIL: emit_reject_$BAD (expected non-zero exit, got 0)"; FAIL=$((FAIL + 1))
    fi
done
for BAD in macosBANANA windowsBANANA; do
    TOTAL=$((TOTAL + 1))
    $KRC --target=$BAD "$EV_SRC" -o "$EV_BIN" >/dev/null 2>&1; TV_ST=$?
    if [ "$TV_ST" != "0" ]; then
        PASS=$((PASS + 1)); echo "  target_reject_$BAD: PASS (exit $TV_ST)"
    else
        echo "FAIL: target_reject_$BAD (expected non-zero exit, got 0)"; FAIL=$((FAIL + 1))
    fi
done
# ALIAS PRESERVATION — the contract. Every spelling that works today must still work,
# AND must produce the format its name promises, not merely "some non-empty file"
# (a compiler that collapsed every alias to one format would still pass an [ -s ]
# only check). Assert the container magic bytes: ELF 7f454c46, Mach-O cffaedfe,
# PE 4d5a0000, asm is text (no fixed magic, so just check for '; ' comment lead-in).
#
# THE SPELLING LIST IS NOW DERIVED FROM THE COMPILER'S OWN ARMS, and that is
# the point of this rewrite rather than a tidy-up. It used to be 24 names typed
# out by hand under the sentence "Every spelling that works today must still
# work" — and by the time D Task 4 read it, `ir`, `lkm`, `image` and `uefi`
# all worked and none of them was in it. A hand-list cannot notice a spelling
# nobody added to it, so the sentence was false the moment a mode shipped, and
# each new mode made it falser. src/main.kr's `str_eq_full(emit_str, "...")`
# chain is the only thing that decides what --emit= accepts, so it is what this
# reads. Three guard rows below make the derivation itself falsifiable: an
# empty or short derivation reds rather than silently testing nothing, and a
# spelling with no recipe reds instead of being skipped.
EV_BM="/tmp/krc_ev_bm_$$.kr"
printf 'fn main() { loop { } }\n' > "$EV_BM"
EV_LKM="/tmp/krc_ev_lkm_$$.kr"
printf '@module_init\nfn kr_init() -> uint64 { return 0 }\n@module_exit\nfn kr_exit() { }\n' > "$EV_LKM"

# spelling -> "<expectation>|<extra krc flags>|<source>". Four expectation
# kinds beyond a container magic: TEXT (asm listing), STDOUT (--emit=ir writes
# no file at all), and RAW (--emit=image is a headerless blob, so its promise
# is the ABSENCE of every container magic — "some non-empty file" would be a
# vacuous check for exactly the one mode that has no magic to check).
# ---------------------------------------------------------------------------
# --emit=arx: the ARX container (ApexRift's own executable format).
#
# The format is specified in ANOTHER repository (ApexRift docs/ARX_FORMAT.md)
# and consumed by a loader there, so these rows are the only thing on this side
# that can catch a drift. They assert the fields the LOADER keys its
# run-or-refuse decisions on, not merely the ones that are easy to read: a
# golden test that checks magic and sizes while missing the segment's X bit
# produces a green suite and an artifact the loader rejects.
# ---------------------------------------------------------------------------
ax_bad=""
ax_chk() { [ "$2" = "$3" ] || ax_bad="$ax_bad $1(want=$2 got=$3)"; }
ARX_SRC=$(mktemp /tmp/krc_arxsrc_XXXX.kr)
printf 'fn main() -> uint64 {\n    return 0\n}\n' > "$ARX_SRC"
ARX_BIN=/tmp/krc_arx_$$
rm -f "$ARX_BIN"
$KRC $KRC_FLAGS "$ARX_SRC" -o "$ARX_BIN" --arch=x86_64 --target=none --emit=arx >/dev/null 2>&1

TOTAL=$((TOTAL + 1))
if [ ! -f "$ARX_BIN" ]; then
    echo "FAIL: arx_header_fields (no artifact produced)"; FAIL=$((FAIL + 1))
else
    ax_sz=$(wc -c < "$ARX_BIN")
    ax_chk magic        "7f415258" "$(ue_hex "$ARX_BIN" 0 4)"
    ax_chk version      1     "$(ue_u16 "$ARX_BIN" 4)"
    ax_chk header_size  64    "$(ue_u16 "$ARX_BIN" 6)"
    ax_chk arch         1     "$(ue_u16 "$ARX_BIN" 8)"
    ax_chk pic_flag     1     "$(ue_u16 "$ARX_BIN" 10)"
    ax_chk table_count  1     "$(ue_u32 "$ARX_BIN" 12)"
    ax_chk table_off    64    "$(ue_u64 "$ARX_BIN" 16)"
    # reserved must be 0: the loader refuses nonzero so the field stays usable
    # by a later version instead of being silently occupied.
    ax_chk reserved     0     "$(ue_u64 "$ARX_BIN" 56)"
    # align is NOT cosmetic. arm64 correctness needs base % 4096 == 0 as well as
    # a page-congruent file offset, and this field is the ONLY thing that
    # delivers the first half -- the loader would accept 16. Lower it and x86_64
    # keeps working while arm64 breaks at run time with no diagnostic.
    ax_chk align        4096  "$(ue_u64 "$ARX_BIN" 40)"
    ax_chk table_kind   1     "$(ue_u32 "$ARX_BIN" 64)"
    # MANDATORY is a PRODUCER OBLIGATION in the format: later stages add table
    # kinds without bumping `version`, so this flag is the only thing stopping
    # an older loader from silently mis-loading a newer file. Nothing else
    # checks it.
    ax_chk table_flags  1     "$(ue_u32 "$ARX_BIN" 68)"
    ax_chk seg_off      88    "$(ue_u64 "$ARX_BIN" 72)"
    ax_chk seg_size     40    "$(ue_u64 "$ARX_BIN" 80)"
    ax_chk seg_file_off 4096  "$(ue_u64 "$ARX_BIN" 88)"
    ax_chk seg_mem_off  0     "$(ue_u64 "$ARX_BIN" 96)"
    # R|X. The X bit is load-bearing: the loader requires the entry to land in
    # an executable segment's file-backed bytes and refuses otherwise, so
    # clearing it yields an artifact that builds clean and never runs.
    ax_chk seg_flags    5     "$(ue_u32 "$ARX_BIN" 120)"
    # Per-segment align is RESERVED and must be 0 -- a nonzero value is refused,
    # because honouring it is not implemented and accepting it would imply an
    # effect that does not exist.
    ax_chk seg_align    0     "$(ue_u32 "$ARX_BIN" 124)"
    ax_fsz=$(ue_u64 "$ARX_BIN" 104); ax_msz=$(ue_u64 "$ARX_BIN" 112)
    ax_img=$(ue_u64 "$ARX_BIN" 32);  ax_ent=$(ue_u64 "$ARX_BIN" 24)
    ax_chk filesz_eq_memsz  "$ax_fsz" "$ax_msz"
    ax_chk image_size_eq_filesz "$ax_fsz" "$ax_img"
    # No padding: the file is exactly the header region plus the payload. Stray
    # trailing bytes would desynchronise image_size from what was written.
    ax_chk file_len "$((4096 + ax_fsz))" "$ax_sz"
    # The entry must be inside the segment's FILE-BACKED bytes, which is what
    # the loader enforces; "inside the image" is not enough, since zeroed bss is
    # inside the image and is garbage to execute.
    [ "$ax_ent" -lt "$ax_fsz" ] || ax_bad="$ax_bad entry_in_filebacked(entry=$ax_ent filesz=$ax_fsz)"
    if [ -z "$ax_bad" ]; then
        PASS=$((PASS + 1)); echo "  arx_header_fields: PASS (entry=$ax_ent filesz=$ax_fsz hdr=4096 total=$ax_sz)"
    else
        echo "FAIL: arx_header_fields:$ax_bad"; FAIL=$((FAIL + 1))
    fi
fi

# Page congruence, stated as the RULE rather than as two literals, so a future
# geometry change has to satisfy it instead of editing constants that look
# unrelated. Same guard the uefi row uses: both fields must be real, or an
# artifact with no header at all passes on 0 - 0.
TOTAL=$((TOTAL + 1))
if [ -f "$ARX_BIN" ]; then
    ax_fo=$(ue_u64 "$ARX_BIN" 88); ax_mo=$(ue_u64 "$ARX_BIN" 96)
    ax_delta=$((ax_fo - ax_mo))
    if [ "$ax_fo" -gt 0 ] && [ $((ax_delta % 4096)) -eq 0 ]; then
        PASS=$((PASS + 1)); echo "  arx_page_congruence: PASS (file_off $ax_fo - mem_off $ax_mo = $ax_delta, 0 mod 4096)"
    else
        echo "FAIL: arx_page_congruence (file_off=$ax_fo mem_off=$ax_mo delta=$ax_delta not 0 mod 4096)"; FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: arx_page_congruence (no artifact)"; FAIL=$((FAIL + 1))
fi

# The checksum, recomputed by an INDEPENDENT implementation.
#
# Deliberately NOT by calling the compiler: recomputing with the emitter's own
# routine is tautological -- a typo'd FNV basis or prime would agree with itself
# and pass here, then surface as a load-time refusal in another repository after
# a version bump. The constants below come from ARX_FORMAT.md, not from src/.
TOTAL=$((TOTAL + 1))
if [ -f "$ARX_BIN" ] && command -v python3 >/dev/null 2>&1; then
    ax_ck=$(python3 - "$ARX_BIN" <<'AXPY'
import sys, struct
d = open(sys.argv[1], 'rb').read()
h = 0xcbf29ce484222325
for i, b in enumerate(d):
    if 48 <= i < 56:      # the checksum field hashes as zero
        b = 0
    h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
print("ok" if h == struct.unpack_from('<Q', d, 48)[0] else "mismatch")
AXPY
)
    if [ "$ax_ck" = "ok" ]; then
        PASS=$((PASS + 1)); echo "  arx_checksum_independent: PASS (FNV-1a recomputed from the spec constants)"
    else
        echo "FAIL: arx_checksum_independent ($ax_ck)"; FAIL=$((FAIL + 1))
    fi
else
    PASS=$((PASS + 1)); echo "  arx_checksum_independent: SKIP (no python3)"
fi

# Refusals. Each message carries a substring unique to it, so a defect that
# routed one refusal to another's arm cannot pass by matching a shared half.
ax_refuse() {   # <name> <unique-substring> <flags...>
    TOTAL=$((TOTAL + 1))
    local nm="$1"; local want="$2"; shift 2
    local out; out=$($KRC $KRC_FLAGS "$ARX_SRC" -o /tmp/krc_axr_$$ "$@" 2>&1 >/dev/null)
    rm -f /tmp/krc_axr_$$
    case "$out" in
        *"$want"*) PASS=$((PASS + 1)); echo "  $nm: PASS" ;;
        *) echo "FAIL: $nm (wanted substring '$want', got: $(printf '%s' "$out" | head -1))"; FAIL=$((FAIL + 1)) ;;
    esac
}
ax_refuse arx_refuses_hosted_target "requires --target=none" --arch=x86_64 --emit=arx
# NOT via ax_refuse, and NOT via $KRC. Two layers inject an arch: KRC_FLAGS
# defaults to --arch=$ARCH, and the make-test wrapper is literally
# `exec ./build/krc2 --arch=x86_64 "$@"`. Either one makes the condition under
# test unreachable, so this uses the RAW build/krc2 -- the same dodge, for the
# same reason, as uefi_requires_explicit_arch above.
TOTAL=$((TOTAL + 1))
if [ -f "$DIR/../build/krc2" ]; then ARX_RAW_KRC=$(cd "$DIR/../build" && pwd)/krc2; else ARX_RAW_KRC=""; fi
rm -f /tmp/krc_axna_$$
ax_na=$("$ARX_RAW_KRC" "$ARX_SRC" -o /tmp/krc_axna_$$ --target=none --emit=arx 2>&1); ax_na_st=$?
rm -f /tmp/krc_axna_$$
if [ -z "$ARX_RAW_KRC" ] || [ $ax_na_st -eq 0 ]; then
    echo "FAIL: arx_refuses_default_arch (exit=$ax_na_st, out=$(printf '%s' "$ax_na" | head -1))"; FAIL=$((FAIL + 1))
else
case "$ax_na" in
    *"requires an explicit --arch=x86_64"*)
        PASS=$((PASS + 1)); echo "  arx_refuses_default_arch: PASS" ;;
    *)
        echo "FAIL: arx_refuses_default_arch (wanted the explicit-arch refusal, got: $(printf '%s' "$ax_na" | head -1))"; FAIL=$((FAIL + 1)) ;;
esac
fi
# arm64 is in scope and deliberately not enabled: the container reserves the
# arch value and the layout already keeps ADRP arithmetic valid, but no arm64
# loader exists, so emitting it would ship an untested invariant as if it worked.
ax_refuse arx_refuses_arm64_queued  "x86_64 only today" --arch=arm64 --target=none --emit=arx
ax_refuse arx_refuses_riscv32       "no riscv32 form" --arch=riscv32 --target=none --emit=arx
ax_refuse arx_refuses_xtensa        "no xtensa form" --arch=xtensa --target=none --emit=arx
ax_refuse arx_refuses_debug_info    "-g conflicts with --emit=arx" --arch=x86_64 --target=none --emit=arx -g
# These two are refused by the GENERIC rows, not by mode 10's block. Pinned here
# because mode 10 depends on them: re-implementing either inside the block would
# change which message fires without adding protection.
ax_refuse arx_refuses_stack_top     "only meaningful with --emit=image" --arch=x86_64 --target=none --emit=arx --stack-top=0x90000
ax_refuse arx_refuses_load_addr     "only meaningful with --emit=image" --arch=x86_64 --target=none --emit=arx --load-addr=0x400000
rm -f "$ARX_SRC" "$ARX_BIN"

# ---------------------------------------------------------------------------
# Inline asm: `call <reg>` and `jmp <reg>` (FF /2 and FF /4).
#
# Added because a stack-switching trampoline is unwritable without them: it has
# to change rsp and then enter a function, and call_ptr cannot help -- the
# compiler frames that call normally and a managed frame does not survive rsp
# moving underneath it. ApexRift's program launcher hit exactly that wall.
#
# The encodings are asserted as BYTES, not merely "it compiled": a wrong ModRM
# extension silently assembles to a different instruction (FF /2 is call,
# FF /4 is jmp, FF /6 is push), so anything short of the bytes would pass while
# emitting the wrong one. r10/r15 cover the REX.B path.
# ---------------------------------------------------------------------------
# GUARDED ON $RUN_ARCH, and not because the emitted bytes differ: the row
# COMPILES x86_64 inline asm, and KRC_FLAGS defaults to --arch=$ARCH, so on the
# native ARM64 job it asked an arm64 build to assemble `call rax` and produced
# no artifact. Measured there, not predicted. Forcing --arch=x86_64 would also
# build, but the point of the row is the byte encoding, which is meaningless to
# assert from a host that cannot run it -- and a silent skip would read as
# coverage, so it says so.
if [ "$RUN_ARCH" != "x86_64" ]; then
    PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1))
    echo "  asm_call_jmp_reg: SKIP (x86_64 encodings; host is $RUN_ARCH)"
else
TOTAL=$((TOTAL + 1))
CR_SRC=$(mktemp /tmp/krc_callreg_XXXX.kr)
CR_BIN=/tmp/krc_callreg_$$
cat > "$CR_SRC" <<'CREOF'
@naked
fn t() {
    asm { "call rax" }
    asm { "call r10" }
    asm { "jmp rdx" }
    asm { "jmp r15" }
    asm { "ret" }
}
fn main() -> uint64 { t(); return 0 }
CREOF
rm -f "$CR_BIN"
$KRC $KRC_FLAGS "$CR_SRC" -o "$CR_BIN" --target=none --emit=image \
     --stack-top=0x90000 --load-addr=0x400000 >/dev/null 2>&1
if [ ! -f "$CR_BIN" ]; then
    echo "FAIL: asm_call_jmp_reg (no artifact)"; FAIL=$((FAIL + 1))
else
    # ffd0 = call rax, 41ffd2 = call r10, ffe2 = jmp rdx, 41ffe7 = jmp r15
    cr_hex=$(od -An -tx1 -v "$CR_BIN" | tr -d ' \n')
    cr_bad=""
    case "$cr_hex" in *ffd041ffd2ffe241ffe7*) ;; *) cr_bad="sequence not found" ;; esac
    if [ -z "$cr_bad" ]; then
        PASS=$((PASS + 1)); echo "  asm_call_jmp_reg: PASS (ff d0 / 41 ff d2 / ff e2 / 41 ff e7)"
    else
        echo "FAIL: asm_call_jmp_reg ($cr_bad)"; FAIL=$((FAIL + 1))
    fi
fi
rm -f "$CR_SRC" "$CR_BIN"
fi

# --- int 0xNN encodes CD ib, and the vector is PARSED not assumed -------------
#
# Two different vectors, deliberately. A form that emitted a hardcoded 0xCD 0x80
# would pass a single-vector check, so 0x2f is the one that proves the operand
# reaches the encoder. Same RUN_ARCH guard and reasoning as asm_call_jmp_reg
# above: the assertion is a byte encoding, meaningless from a host that cannot
# assemble it, and a silent skip would read as coverage.
if [ "$RUN_ARCH" != "x86_64" ]; then
    PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1))
    echo "  asm_int_imm8: SKIP (x86_64 encodings; host is $RUN_ARCH)"
else
TOTAL=$((TOTAL + 1))
II_SRC=$(mktemp /tmp/krc_intimm_XXXX.kr)
II_BIN=/tmp/krc_intimm_$$
cat > "$II_SRC" <<'IIEOF'
@naked
fn t() {
    asm { "int 0x80" }
    asm { "int 0x2f" }
    asm { "int3" }
    asm { "ret" }
}
fn main() -> uint64 { t(); return 0 }
IIEOF
rm -f "$II_BIN"
$KRC $KRC_FLAGS "$II_SRC" -o "$II_BIN" --target=none --emit=image \
     --stack-top=0x90000 --load-addr=0x400000 >/dev/null 2>&1
if [ ! -f "$II_BIN" ]; then
    echo "FAIL: asm_int_imm8 (no artifact)"; FAIL=$((FAIL + 1))
else
    # cd80 = int 0x80, cd2f = int 0x2f, cc = int3 (still its own one-byte form)
    ii_hex=$(od -An -tx1 -v "$II_BIN" | tr -d ' \n')
    ii_bad=""
    case "$ii_hex" in *cd80cd2fcc*) ;; *) ii_bad="sequence not found" ;; esac
    if [ -z "$ii_bad" ]; then
        PASS=$((PASS + 1)); echo "  asm_int_imm8: PASS (cd 80 / cd 2f / cc)"
    else
        echo "FAIL: asm_int_imm8 ($ii_bad)"; FAIL=$((FAIL + 1))
    fi
fi
rm -f "$II_SRC" "$II_BIN"
fi

emit_recipe() {
    case "$1" in
        elf|elf-arm64|elf-x86_64|elfexe|linux|linux-x86_64|linux-arm64|linux-x86-64|obj|android)
            echo "7f454c46||$EV_SRC" ;;
        macho|mac|macos|mac-x64|mac-arm64|darwin)
            echo "cffaedfe||$EV_SRC" ;;
        windows|windows-x64|windows-arm64|win|win-x64|win-arm64|pe)
            echo "4d5a0000||$EV_SRC" ;;
        # An .ko is a relocatable ELF, but it needs a @module_init to be
        # emitted at all, so it cannot share the default source.
        #
        # --arch=x86_64 IS REQUIRED, NOT DECORATION: lkm is the one spelling in
        # this list that refuses a host arch. `--emit=lkm` without it takes the
        # NATIVE arch, so this row passed on x86_64 and failed on the Linux
        # ARM64 runner with "krc: --emit=lkm currently supports x86_64 only"
        # (exit 1) -- measured, run 30959429718. The pre-existing LKM section
        # below pins the same flag for the same reason; this arm was written
        # without it and only CI could see the difference.
        lkm)   echo "7f454c46|--arch=x86_64|$EV_LKM" ;;
        # Both bare-metal modes REQUIRE --target=none and refuse `exit`, hence
        # the loop{} source. uefi promises the same MZ magic as pe and a very
        # different container; the magic alone does not separate them, which is
        # what uefi_pe_header_fields_* and the boot gate's L7/L8 are for.
        uefi)  echo "4d5a0000|--target=none|$EV_BM" ;;
        image) echo "RAW|--target=none --load-addr=0x400000|$EV_BM" ;;
        # ARX is bare-metal too, but it is HOSTED: ApexRift loads it, so it
        # takes neither --load-addr= nor --stack-top= (both refused outside
        # --emit=image) and needs an explicit --arch. Its magic is its own.
        arx)   echo "7f415258|--target=none --arch=x86_64|$EV_BM" ;;
        asm)   echo "TEXT||$EV_SRC" ;;
        ir)    echo "STDOUT||$EV_SRC" ;;
    esac
}

EV_ALL=$(grep -o 'str_eq_full(emit_str, "[^"]*")' "$DIR/../src/main.kr" \
         | sed 's/.*"\(.*\)".*/\1/' | sort -u)
EV_NALL=$(echo "$EV_ALL" | grep -c .)

# Guard 1: the derivation produced something plausible. If src/main.kr is
# reformatted so the pattern stops matching, this reds instead of turning the
# whole block into a zero-iteration loop that reports nothing.
TOTAL=$((TOTAL + 1))
if [ "$EV_NALL" -ge 24 ]; then
    PASS=$((PASS + 1)); echo "  emit_alias_set_derived: PASS ($EV_NALL spellings read out of src/main.kr)"
else
    echo "FAIL: emit_alias_set_derived (derived only $EV_NALL spellings from src/main.kr's str_eq_full(emit_str, ...) arms; 24 shipped in v2.8.4 and none has ever been removed, so a smaller number means the derivation broke, not that the compiler shrank)"
    FAIL=$((FAIL + 1))
fi

# Guard 2: the compiler's own "valid: ..." diagnostic lists exactly those
# spellings, BOTH WAYS. This is the enumeration D Task 4 was sent to find: it
# shipped as a 16-name sample of a 27-name set, so a user who mistyped
# `--emit=macos` was told `macos` was not valid. One-way would not do — a list
# that merely contains every arm could still invent names that do not work.
TOTAL=$((TOTAL + 1))
EV_VALID=$($KRC --emit=__no_such_format__ "$EV_SRC" -o "$EV_BIN" 2>&1 \
           | sed -n 's/^valid: //p' | tr ',' '\n' | tr -d ' \r' | grep -v '^$' | sort -u)
EV_ONLY_ARM=$(comm -23 <(echo "$EV_ALL") <(echo "$EV_VALID") | tr '\n' ' ')
EV_ONLY_MSG=$(comm -13 <(echo "$EV_ALL") <(echo "$EV_VALID") | tr '\n' ' ')
if [ -z "$EV_VALID" ]; then
    echo "FAIL: emit_valid_list_is_complete (the compiler printed no 'valid: ' line for an unknown --emit= value)"; FAIL=$((FAIL + 1))
elif [ -n "$EV_ONLY_ARM" ] || [ -n "$EV_ONLY_MSG" ]; then
    echo "FAIL: emit_valid_list_is_complete (accepted but not listed: [$EV_ONLY_ARM]; listed but not accepted: [$EV_ONLY_MSG])"; FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1)); echo "  emit_valid_list_is_complete: PASS ($EV_NALL spellings, arms and diagnostic agree both ways)"
fi

# Guard 3: every derived spelling has a recipe. Without this a new --emit=
# value would simply not be exercised by the loop below — the silent-skip
# failure mode, which is the one this whole task exists to close.
TOTAL=$((TOTAL + 1))
EV_NORECIPE=""
for GOOD in $EV_ALL; do
    [ -n "$(emit_recipe "$GOOD")" ] || EV_NORECIPE="$EV_NORECIPE $GOOD"
done
if [ -z "$EV_NORECIPE" ]; then
    PASS=$((PASS + 1)); echo "  emit_recipe_covers_every_alias: PASS (all $EV_NALL spellings have an expectation)"
else
    echo "FAIL: emit_recipe_covers_every_alias (no expectation for:$EV_NORECIPE -- add an arm to emit_recipe() so the alias is checked instead of skipped)"
    FAIL=$((FAIL + 1))
fi

for GOOD in $EV_ALL; do
    TOTAL=$((TOTAL + 1))
    rm -f "$EV_BIN"
    EV_R=$(emit_recipe "$GOOD")
    EXP_MAGIC="${EV_R%%|*}"; EV_REST="${EV_R#*|}"
    EV_FLAGS="${EV_REST%%|*}"; EV_IN="${EV_REST#*|}"
    if [ -z "$EV_R" ]; then
        echo "FAIL: emit_accept_$GOOD (no recipe; see emit_recipe_covers_every_alias)"; FAIL=$((FAIL + 1))
    elif [ "$EXP_MAGIC" = "STDOUT" ]; then
        if $KRC --emit=$GOOD $EV_FLAGS "$EV_IN" 2>/dev/null | grep -q '^function main:'; then
            PASS=$((PASS + 1)); echo "  emit_accept_$GOOD: PASS (IR dump on stdout)"
        else
            echo "FAIL: emit_accept_$GOOD (expected an IR dump naming main on stdout)"; FAIL=$((FAIL + 1))
        fi
    elif $KRC --emit=$GOOD $EV_FLAGS "$EV_IN" -o "$EV_BIN" >/dev/null 2>&1 && [ -s "$EV_BIN" ]; then
        GOT_MAGIC=$(xxd -p -l4 "$EV_BIN")
        if [ "$EXP_MAGIC" = "TEXT" ]; then
            if head -c2 "$EV_BIN" | grep -q '; '; then
                PASS=$((PASS + 1)); echo "  emit_accept_$GOOD: PASS (text asm)"
            else
                echo "FAIL: emit_accept_$GOOD (expected text asm output)"; FAIL=$((FAIL + 1))
            fi
        elif [ "$EXP_MAGIC" = "RAW" ]; then
            case "$GOT_MAGIC" in
                7f454c46|cffaedfe|4d5a0000)
                    echo "FAIL: emit_accept_$GOOD (a flat image must carry no container magic, got $GOT_MAGIC)"; FAIL=$((FAIL + 1)) ;;
                *)
                    PASS=$((PASS + 1)); echo "  emit_accept_$GOOD: PASS (headerless, first bytes $GOT_MAGIC)" ;;
            esac
        elif [ "$GOT_MAGIC" = "$EXP_MAGIC" ]; then
            PASS=$((PASS + 1)); echo "  emit_accept_$GOOD: PASS (magic $GOT_MAGIC)"
        else
            echo "FAIL: emit_accept_$GOOD (expected magic $EXP_MAGIC, got $GOT_MAGIC)"; FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL: emit_accept_$GOOD (alias must keep working)"; FAIL=$((FAIL + 1))
    fi
done
rm -f "$EV_SRC" "$EV_BIN" "$EV_BM" "$EV_LKM"

# --- syscall_raw number register per ARM64 ABI (artifact inspection) ---
# aarch64 takes the syscall number in x8 on Linux/Android and in x16 on
# Darwin. Both facts already lived in emit_a64_syscall_nr(), but the IR
# backend's IR_SYSCALL_RAW handler hardcoded x8, so every syscall_raw() in
# a macOS arm64 binary executed `svc #0x80` with a stale x16 and the kernel
# answered EINVAL(22) to all of them — getpid, write and mprotect alike.
# std/alloc.kr's guard probe then correctly concluded nothing behaved like
# mprotect and declined guard pages, which is how it surfaced (macOS ARM64
# smoke.alloc_guard exit 4). Nothing that runs on this host can see that:
# the check has to be made against the emitted bytes.
#
# Decode: `svc #0x80` is 0xD4001001 and `svc #0` is 0xD4000001; the word
# before each one is the instruction that loads the number register, whose
# Rd is its low 5 bits. Asserting "no svc is preceded by a write to the
# WRONG register" (rather than pattern-matching one encoding) survives
# register allocation and MOVZ-vs-MOV differences.
echo ""
echo "--- ARM64 syscall_raw number register ---"
SR_SRC=/tmp/krc_sysreg_$$.kr
SR_BIN=/tmp/krc_sysreg_bin_$$
cat > "$SR_SRC" <<'SREOF'
fn main() {
    u64 msg = "x\n"
    syscall_raw(4, 1, msg, 2, 0, 0, 0)
    exit(0)
}
SREOF
# $1 = binary, $2 = svc word (big-endian hex), $3 = required Rd,
# $4 = forbidden Rd. Prints "<good> <bad> <total>".
sysreg_scan() {
    xxd -p -c 4 "$1" | awk -v svc="$2" -v want="$3" -v bad="$4" '
        BEGIN { for (i = 0; i < 16; i++) h[sprintf("%x", i)] = i }
        {
            # xxd -p -c 4 emits file order; ARM64 is little-endian.
            w = substr($0,7,2) substr($0,5,2) substr($0,3,2) substr($0,1,2)
            if (w == svc && NR > 1) {
                rd = (h[substr(prev,7,1)] * 16 + h[substr(prev,8,1)]) % 32
                total++
                if (rd == want) good++
                if (rd == bad) badcnt++
            }
            prev = w
        }
        END { printf "%d %d %d\n", good+0, badcnt+0, total+0 }'
}
# macOS arm64: number in x16, `svc #0x80`.
TOTAL=$((TOTAL + 1))
if $KRC --arch=arm64 --emit=macho "$SR_SRC" -o "$SR_BIN" >/dev/null 2>&1; then
    read -r SR_GOOD SR_BAD SR_TOT <<EOF
$(sysreg_scan "$SR_BIN" d4001001 16 8)
EOF
    if [ "$SR_BAD" = "0" ] && [ "${SR_GOOD:-0}" -ge 1 ]; then
        PASS=$((PASS + 1))
        echo "  arm64_syscall_nr_macos_x16: PASS ($SR_GOOD/$SR_TOT svc sites load x16, 0 load x8)"
    else
        echo "FAIL: arm64_syscall_nr_macos_x16 ($SR_BAD of $SR_TOT svc #0x80 sites take the number from x8; Darwin reads x16)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: arm64_syscall_nr_macos_x16 (compile failed)"; FAIL=$((FAIL + 1))
fi
# Linux arm64: number in x8, `svc #0`. The same check the other way round,
# so a fix aimed at Darwin cannot quietly break the Linux table.
TOTAL=$((TOTAL + 1))
if $KRC --arch=arm64 "$SR_SRC" -o "$SR_BIN" >/dev/null 2>&1; then
    read -r SR_GOOD SR_BAD SR_TOT <<EOF
$(sysreg_scan "$SR_BIN" d4000001 8 16)
EOF
    if [ "$SR_BAD" = "0" ] && [ "${SR_GOOD:-0}" -ge 1 ]; then
        PASS=$((PASS + 1))
        echo "  arm64_syscall_nr_linux_x8: PASS ($SR_GOOD/$SR_TOT svc sites load x8, 0 load x16)"
    else
        echo "FAIL: arm64_syscall_nr_linux_x8 ($SR_BAD of $SR_TOT svc #0 sites take the number from x16; Linux reads x8)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: arm64_syscall_nr_linux_x8 (compile failed)"; FAIL=$((FAIL + 1))
fi
rm -f "$SR_SRC" "$SR_BIN"

# --- float pointer dereference moves the VALUE, not junk -------------------
# `unsafe { *(p as f64) = 2.5 }` stored ZERO on BOTH legacy backends and
# `unsafe { *(p as f64) -> z }` handed z to every later reader in the wrong
# register class, so a bit-exact 2.5 sitting in memory printed as 0.000000.
# Both IR backends were correct, so this was a genuine IR-vs-legacy split.
#
# Two causes, both in the legacy backends:
#   - PtrStore dispatched on the cast WIDTH alone and moved the value through
#     rax/x0. A float expression leaves its result in xmm0/d0, so the store
#     wrote whatever junk the integer register happened to hold.
#   - PtrLoad put the right BITS in the destination slot but never recorded
#     that the destination is a float, so every later read of it came out of
#     the integer class -- fmt_f64(z) passed z in a GP register to a callee
#     reading xmm0.
# A third, adjacent one: the float arithmetic paths only ever tested the plain
# operator kinds, so `*(p as f64) += 1.5` emitted NO arithmetic instruction and
# wrote the unchanged left operand back (the float twin of the `/=` discard
# already pinned in diff_ir_legacy.sh).
#
# EVERY row POISONS the target first and then asserts the FULL 64-bit pattern.
# That is the whole point: without the poison "stored zero" and "never stored"
# are the same reading, and a row that only checks the value "looks like 2.5"
# passes against this bug, because the value it saw never came from memory.
#
# These rows EXECUTE, so they follow $RUN_ARCH rather than naming an arch.
TOTAL=$((TOTAL + 1))
PDRF_OK=1
PDRF_OTHER="arm64"
if [ "$RUN_ARCH" = "arm64" ]; then PDRF_OTHER="x86_64"; fi
PDRF_QEMU=""
if [ "$PDRF_OTHER" = "arm64" ]; then
    PDRF_QEMU="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
fi

# 1. Store: the poison must be replaced by the EXACT bits of 2.5, all 64 of
#    them. Byte-level: 0xAA anywhere means the store missed; all-zero means it
#    stored the empty integer register, which is what it used to do.
cat > "$DIR/../pdrf_store_$$.kr" <<'PDRF_STORE'
fn main() {
    u64 b = alloc(64)
    store64(b, 0xAAAAAAAAAAAAAAAA)
    unsafe { *(b as f64) = 2.5 }
    if load64(b) != 0x4004000000000000 { exit(1) }
    exit(7)
}
PDRF_STORE

# 2. Load: correct bits are written by an INTEGER store, so the only thing
#    under test is whether the f64 read hands them to a float consumer.
#    f64_to_int(z * 100.0) is 250 only if z really is 2.5 in the float class.
cat > "$DIR/../pdrf_load_$$.kr" <<'PDRF_LOAD'
fn main() {
    u64 b = alloc(64)
    store64(b, 0x4004000000000000)
    unsafe { *(b as f64) -> z }
    if f64_to_int(z) != 2 { exit(1) }
    if f64_to_int(z * 100.0) != 250 { exit(2) }
    exit(7)
}
PDRF_LOAD

# 3. Full round trip, and the raw-bit check is what keeps it honest: a value
#    that never left a register would satisfy the float check alone.
cat > "$DIR/../pdrf_round_$$.kr" <<'PDRF_ROUND'
fn main() {
    u64 b = alloc(64)
    store64(b, 0xAAAAAAAAAAAAAAAA)
    unsafe { *(b as f64) = 1.25 }
    if load64(b) != 0x3FF4000000000000 { exit(1) }
    unsafe { *(b as f64) -> z }
    if f64_to_int(z * 4.0) != 5 { exit(2) }
    exit(7)
}
PDRF_ROUND

# 4. Arithmetic on a dereferenced f64. The defect returned the LITERAL operand
#    instead of the product -- f64_to_int(2.0) is 2, not 5 -- so this row fails
#    with a number that names the symptom.
cat > "$DIR/../pdrf_arith_$$.kr" <<'PDRF_ARITH'
fn main() {
    u64 b = alloc(64)
    store64(b, 0x4004000000000000)
    unsafe { *(b as f64) -> z }
    f64 w = z * 2.0
    if f64_to_int(w) != 5 { exit(1) }
    f64 s = z + 0.5
    if f64_to_int(s) != 3 { exit(2) }
    f64 d = z - 0.5
    if f64_to_int(d) != 2 { exit(3) }
    exit(7)
}
PDRF_ARITH

# 5. f32 is the same dispatch and was broken identically. The surviving 0xAAAA
#    halves also pin the store WIDTH: 4 bytes, not 8.
cat > "$DIR/../pdrf_f32_$$.kr" <<'PDRF_F32'
fn main() {
    u64 b = alloc(64)
    store64(b, 0xAAAAAAAAAAAAAAAA)
    unsafe { *(b as f32) = 2.5f }
    if load64(b) != 0xAAAAAAAA40200000 { exit(1) }
    unsafe { *(b as f32) -> y }
    if f32_to_int(y * 4.0f) != 10 { exit(2) }
    exit(7)
}
PDRF_F32

# 6. Read-modify-write. 2.5+1.5=4, 4*2=8, 8-4=4, 4/4=1 -- each asserted as raw
#    bits, so an op that silently emitted nothing (leaving the accumulator on
#    the left operand) is caught at the first step.
cat > "$DIR/../pdrf_rmw_$$.kr" <<'PDRF_RMW'
fn main() {
    u64 b = alloc(64)
    store64(b, 0x4004000000000000)
    unsafe { *(b as f64) += 1.5 }
    if load64(b) != 0x4010000000000000 { exit(1) }
    unsafe { *(b as f64) *= 2.0 }
    if load64(b) != 0x4020000000000000 { exit(2) }
    unsafe { *(b as f64) -= 4.0 }
    if load64(b) != 0x4010000000000000 { exit(3) }
    unsafe { *(b as f64) /= 4.0 }
    if load64(b) != 0x3FF0000000000000 { exit(4) }
    exit(7)
}
PDRF_RMW

# 7. `volatile` builds the SAME AST nodes with data3 bit 4 set, so it has to
#    move floats too -- and the non-float volatile load must stay integer. That
#    last check is not decoration: reading the whole data3 word as the float
#    kind is precisely how every `volatile { *(p as TYPE) -> v }` once came out
#    f64.
cat > "$DIR/../pdrf_vol_$$.kr" <<'PDRF_VOL'
fn main() {
    u64 b = alloc(64)
    store64(b, 0xAAAAAAAAAAAAAAAA)
    volatile { *(b as f64) = 2.5 }
    if load64(b) != 0x4004000000000000 { exit(1) }
    volatile { *(b as f64) -> z }
    if f64_to_int(z * 2.0) != 5 { exit(2) }
    u64 hi = b + 4
    volatile { *(hi as uint32) -> w }
    if w != 0x40040000 { exit(3) }
    if w / 2 != 0x20020000 { exit(4) }
    exit(7)
}
PDRF_VOL

PDRF_RAN=0
pdrf_run() { # <arch> <flags> <src> <runner-or-empty>
    local _bin="/tmp/krc_pdrf_$$"
    if ! $KRC --arch="$1" $2 "$3" -o "$_bin" >/dev/null 2>&1; then
        PDRF_OK=0; echo "  $(basename $3) $1 ${2:-IR}: COMPILE FAILED"
        return
    fi
    if [ -n "$4" ]; then $4 "$_bin" >/dev/null 2>&1; else "$_bin" >/dev/null 2>&1; fi
    local _rc=$?
    PDRF_RAN=$((PDRF_RAN + 1))
    # 7 = every check inside the program passed. 1..4 name which one failed;
    # 0 is the defect's signature (it stored/loaded zero and fell off a check).
    [ "$_rc" = "7" ] || { PDRF_OK=0; echo "  $(basename $3) $1 ${2:-IR}: got $_rc, want 7"; }
    rm -f "$_bin"
}
for _src in "$DIR/../pdrf_store_$$.kr" "$DIR/../pdrf_load_$$.kr" \
            "$DIR/../pdrf_round_$$.kr" "$DIR/../pdrf_arith_$$.kr" \
            "$DIR/../pdrf_f32_$$.kr" "$DIR/../pdrf_rmw_$$.kr" \
            "$DIR/../pdrf_vol_$$.kr"; do
    pdrf_run "$RUN_ARCH" ""          "$_src" ""
    pdrf_run "$RUN_ARCH" "--legacy"  "$_src" ""
    if [ -n "$PDRF_QEMU" ]; then
        pdrf_run "$PDRF_OTHER" ""         "$_src" "$PDRF_QEMU"
        pdrf_run "$PDRF_OTHER" "--legacy" "$_src" "$PDRF_QEMU"
    fi
done
# Guard against the loop silently doing nothing. 7 sources x 2 host configs
# always; x2 more per source when the other arch is runnable.
PDRF_WANT=14
if [ -n "$PDRF_QEMU" ]; then PDRF_WANT=28; fi
[ "$PDRF_RAN" = "$PDRF_WANT" ] || { PDRF_OK=0; echo "  only $PDRF_RAN/$PDRF_WANT config-runs executed"; }
if [ "$PDRF_OK" = "1" ]; then
    echo "  float_pointer_deref_moves_the_value: PASS ($PDRF_RAN config-runs)"
    PASS=$((PASS + 1))
else
    echo "FAIL: float_pointer_deref_moves_the_value"
    FAIL=$((FAIL + 1))
fi
rm -f "$DIR/../pdrf_store_$$.kr" "$DIR/../pdrf_load_$$.kr" \
      "$DIR/../pdrf_round_$$.kr" "$DIR/../pdrf_arith_$$.kr" \
      "$DIR/../pdrf_f32_$$.kr" "$DIR/../pdrf_rmw_$$.kr" \
      "$DIR/../pdrf_vol_$$.kr"

# --- Bare-metal boot gate (sub-project B1) ---
# One counted test wrapping tests/target_none/boot_gate.sh. DELIBERATELY NOT
# behind `command -v qemu-system-*`: the gate itself fails loudly when a
# dependency is missing, and TOTAL is incremented unconditionally — a skip
# indistinguishable from a pass is how three of four legs of this gate's
# first design went vacuous (see the gate's header).
echo ""
echo "--- bare-metal boot gate ---"
TOTAL=$((TOTAL + 1))
# The RAW compiler binary, not the --arch=x86_64 wrapper: the gate passes
# --arch= itself and must not depend on wrapper injection. krc2-then-krc3
# mirrors the governance test at :3319 — the fallback is not decorative, the
# arm64 CI job self-compiles to krc3 and a job that produced only krc3 would
# otherwise report "no compiler" on a tree that has one.
if [ -f "$DIR/../build/krc2" ]; then
    BOOT_KRC=$(cd "$DIR/../build" && pwd)/krc2
elif [ -f "$DIR/../build/krc3" ]; then
    BOOT_KRC=$(cd "$DIR/../build" && pwd)/krc3
else
    BOOT_KRC=""
fi
if [ -z "$BOOT_KRC" ]; then
    # Name the cause. The previous message said "see leg output above" in this
    # branch too, pointing at output that cannot exist: the gate never started.
    echo "FAIL: boot_gate (no compiler under test: neither build/krc2 nor build/krc3 exists, so the gate never ran)"
    FAIL=$((FAIL + 1))
elif KRC="$BOOT_KRC" bash "$DIR/target_none/boot_gate.sh"; then
    PASS=$((PASS + 1))
else
    echo "FAIL: boot_gate (gate ran with $BOOT_KRC and one or more legs failed — see the leg output above)"
    FAIL=$((FAIL + 1))
fi

# --- Summary ---
echo ""
# THERE IS NO KNOWN DELIBERATE RED IN THIS SUITE, so nothing is annotated here.
# Review r1 Minor 4 added a NOTE naming reset_vector_payload_too_large as a
# DELIBERATE red, because sub-project E Task 1 wrote that row before the check
# it asserts existed. TASK 2 LANDED THE CHECK AND THE ROW HAS BEEN GREEN SINCE,
# which made the NOTE's own guard (`rvbig_st -eq 0`) permanently false -- dead
# code whose text, if it ever did print again, would tell a reader that a live
# regression was "expected, not a regression". Removed at E Task 4 rather than
# left standing. If a future task deliberately lands a red row again, add the
# annotation back here, for that row, with that task's name on it.
# --- Documentation pin 5, PART B (see Part A above) --------------------------
# README.md advertises this suite's test count. Compare it against the total
# only now, when $TOTAL is final and already includes this row (Part A did the
# TOTAL++). Placing this comparison next to Part A would have compared README
# against a partial count and been permanently, uselessly red.
if [ "$README_N" = "0" ] || [ -z "$README_COUNTS" ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: readme_test_count_matches_suite (found NO '**N tests**' in README.md)"
    echo "  the count must be stated -- an unparseable README is a failure, not a pass"
elif [ "$README_N" != "2" ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: readme_test_count_matches_suite (README states the count $README_N times, want 2)"
    echo "  README.md carries the number in the CI paragraph and in the stats paragraph"
elif [ "$README_UNIQ" != "$TOTAL" ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: readme_test_count_matches_suite (README says '$README_UNIQ', suite ran $TOTAL)"
    echo "  if the two README numbers differ from each other they are both shown above;"
    echo "  update BOTH '**N tests**' occurrences in README.md to $TOTAL"
else
    PASS=$((PASS + 1))
    echo "  readme_test_count_matches_suite: PASS (README and suite both say $TOTAL)"
fi

echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit $FAIL
