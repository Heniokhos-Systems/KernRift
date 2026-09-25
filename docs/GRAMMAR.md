# KernRift Formal Grammar

EBNF grammar for the KernRift language as implemented by `src/parser.kr` and
`src/lexer.kr`. The parser is a hand-written recursive-descent parser with
Pratt precedence for expressions. Anywhere this document and the parser
disagree, the parser is authoritative — file an issue.

Notation:
- `A = B C` — sequence
- `A | B`    — alternation
- `A*`       — zero or more
- `A+`       — one or more
- `A?`       — optional
- `"lit"`    — literal keyword or punctuation
- UPPER      — lexer token class
- lower      — grammar non-terminal

## Lexical tokens

```
IDENT       = [A-Za-z_] [A-Za-z0-9_]*
INT_LIT     = DEC_LIT | HEX_LIT | BIN_LIT
DEC_LIT     = [0-9] [0-9_]*
HEX_LIT     = ("0x" | "0X") ( [0-9A-Fa-f] | "_" )*    (* at least one hex digit *)
BIN_LIT     = ("0b" | "0B") ( [01] | "_" )*           (* at least one binary digit *)
FLOAT_LIT   = [0-9] [0-9_]* "." [0-9] [0-9_]* ([eE] [+-]? [0-9]+)? "f"?
            | [0-9] [0-9_]* [eE] [+-]? [0-9]+ "f"?
STR_LIT     = '"' (char_escape | [^"\\])* '"'
CHAR_LIT    = "'" (char_escape | [^'\\]) "'"
FSTR        = f"..." with embedded { expr } holes  (see Expressions)
char_escape = "\\" ( "n" | "t" | "r" | "\\" | "'" | '"' | "0"
                   | "a" | "b" | "f" | "v" | "e"
                   | "x" HEX HEX )
COMMENT     = "//" [^\n]*                     (discarded)
```

**There are no block comments.** `/* ... */` is not a comment — the lexer
(`skip_whitespace_and_comments` in `src/lexer.kr`) recognises `//` and nothing
else, so `/*` lexes as a `/` followed by a `*` and the parser reports
`error: unexpected '/' in expression`. Use `//` on each line.

Whitespace (spaces, tabs, CR, LF) is a token separator; no significant
indentation. `TokenKind` in `src/lexer.kr` has 96 members (counting `Eof` and `Error`); only the subset relevant to
grammar is referenced below.

**Binary literals and `_` digit separators are implemented.** `0b101` is 5,
`0B1010` is 10, and `1_000` is 1000; the separator is allowed in decimal, hex
and binary literals and runs through floats as well, so `1_0.5` is 10.5 and not
10.05. `0x` accepts a capital `X` too. A *prefix with no digits* — `0x`, `0X`,
`0b`, `0B`, `0x_` — is an **error token**, not a number: `static u64 X = 0x`
once compiled and stored 72, because the decimal fallback read the text `0x` as
the digit `'x' - '0'`. A decimal digit immediately after a binary literal
(`0b1012`) is an error too, rather than `0b101` followed by a stray `2`.

**Octal (`0o...`) literals and `\u{...}` escapes are still not implemented.**
`0o17` is `0` followed by the identifier `o17` — an undeclared-identifier error
at the point of use — and `'\u{41}'` silently evaluates to `'u'` (117), not
`'A'`, because the lexer's escape set has no `u` case and the backslash simply
escapes the next byte.

## Keywords

All **51** of them, as `match_keyword` in `src/lexer.kr` spells them:

```
asm at break const continue defer device else enum extern false fn for if
import in let loop match return sizeof static struct true type unsafe volatile
while

bool char double float f16 f32 f64
i8 i16 i32 i64            int8 int16 int32 int64
u8 u16 u32 u64            uint8 uint16 uint32 uint64
```

The three type rows are 23 of the 51. `float` is an alias for `f32` and
`double` for `f64`; `uint8`..`uint64` and `int8`..`int64` are the long spellings
of `u8`..`u64` and `i8`..`i64`, and the two forms are interchangeable — a
function declared to take a `u64` accepts a `uint64` argument, and the type
checker never sees a difference.

**`defer`, `device`, `at` and `loop` are keywords**, which is the part of this
list worth reading: they are the four most likely to be reached for as ordinary
variable names, and using one is a parse error rather than a shadowing warning.

## Module

```
module      = import_decl* top_item*
import_decl = "import" STR_LIT
top_item    = annotation* fn_decl
            | extern_decl
            | const_decl
            | static_decl
            | struct_decl
            | enum_decl
            | type_alias
            | device_decl
```

The `import_decl*` prefix is a real restriction, not a stylistic one: **imports
must precede every `top_item`.** The scanner in `import_process`
(`src/main.kr`) reads a leading run of import lines and stops at the first line
that is not one, so an import after a declaration is never opened. `parse_module`
rejects one with an error rather than discarding it — the silence used to
surface as `undefined function` at the *use* site, pointing away from the
import. Comments and blank lines before the first import are skipped and do not
end the run. `import` with no `STR_LIT` is an error at any position, because a
pathless `import` also terminates the leading run.

## Annotations

```
annotation  = "@" IDENT ( "(" anno_args ")" )?
anno_args   = (IDENT | STR_LIT | INT_LIT) ("," (IDENT | STR_LIT | INT_LIT))*
```

Recognised names (the parser sets flags for these, others are ignored but
consumed): `noreturn`, `naked`, `packed`, `export`, `section`.

## Declarations

```
fn_decl     = "fn" IDENT generics? ("." IDENT)? param_list return_type? block
generics    = "<" IDENT ("," IDENT)* ">"         (* purely syntactic *)
param_list  = "(" (param ("," param)*)? ")"
param       = type IDENT
            | "[" type "]" IDENT                 (* slice / fat pointer *)
return_type = "->" type

extern_decl = "extern" "fn" IDENT param_list return_type? ";"?

const_decl  = "const" type IDENT ("=" const_init)?
static_decl = "static" type IDENT ("=" const_init)?
            | "static" type "[" const_expr "]" IDENT ("=" const_init)?
const_init  = INT_LIT | CHAR_LIT | "true" | "false"   (* only literals honoured *)
const_expr  = (* a compile-time constant expression -- see "Constant
                 expressions" below. NOT merely INT_LIT: an array size may be
                 any const-folded expression, including a const or static
                 NAME declared earlier. *)

struct_decl = "struct" IDENT "{" field* "}"
field       = type IDENT ";"?  ","?

enum_decl   = "enum" IDENT "{" enum_field ("," enum_field)* ","? "}"
enum_field  = IDENT ("=" INT_LIT)?

type_alias  = "type" IDENT "=" type

device_decl = "device" IDENT "at" INT_LIT "{" dev_field* "}"
dev_field   = IDENT "at" INT_LIT ":" type access? ";"?  ","?
access      = "rw" | "ro" | "wo"
```

## Types

```
type        = primitive | IDENT                  (* struct / type-alias name *)
primitive   = "u8" | "u16" | "u32" | "u64"
            | "i8" | "i16" | "i32" | "i64"
            | "f32" | "f64" | "float" | "double"
            | "bool" | "char"
```

## Statements

```
block       = "{" stmt* "}"
stmt        = var_decl
            | struct_var_decl
            | tuple_destruct
            | return_stmt
            | if_stmt
            | while_stmt
            | loop_stmt
            | for_stmt
            | match_stmt
            | break_stmt
            | continue_stmt
            | defer_stmt
            | unsafe_block
            | volatile_block
            | asm_stmt
            | assign_stmt
            | compound_assign
            | expr_stmt
            | ";"                                (* empty *)

defer_stmt  = "defer" block
            (* Body runs in LIFO order at every function exit — every
               `return`, the 2-tuple and 3-tuple return forms, and the
               implicit fall-through at the end of the body. `exit(n)`
               syscalls bypass defer (they're calls, not `return`s).
               Requires the IR backend — `--legacy` rejects it. *)

var_decl        = type IDENT ("=" expr)?
                | type "[" const_expr "]" IDENT (* stack array *)
                | "let" IDENT "=" expr          (* type inferred from RHS;
                                                   the initializer is required *)
struct_var_decl = IDENT IDENT ("=" expr)?       (* IDENT is known struct *)
                | IDENT "[" const_expr "]" IDENT (* struct array *)
tuple_destruct  = "(" type IDENT "," type IDENT ("," type IDENT)? ")" "=" expr

return_stmt = "return" expr?
            | "return" "(" expr "," expr ("," expr)? ")"   (* 2- or 3-tuple *)

if_stmt     = "if" expr block ("else" (if_stmt | block))?
while_stmt  = "while" expr block
loop_stmt   = "loop" block                                  (* desugars to while 1 == 1 *)
for_stmt    = "for" IDENT "in"? expr (".." | "..=") expr block
            (* `in` is optional — both `for i 0..10` and `for i in 0..10` parse.
               `..=` is the inclusive form: the loop visits `end` as well.
               Desugared to a VarDecl + While with `<` or `<=` as the guard. *)
break_stmt  = "break"
continue_stmt = "continue"

match_stmt  = "match" expr "{" match_arm* "}"
match_arm   = pattern ("," pattern)* "=>" (block | stmt)
            (* Multiple comma-separated patterns fire the body if *any*
               matches. The arm body is a brace block or a single bare
               statement (`1 => exit(1)`). Range patterns require the IR
               backend (the default); --legacy rejects them. *)
pattern     = expr
            | "_"                                  (* wildcard *)
            | expr ".." expr                       (* exclusive range *)
            | expr "..=" expr                      (* inclusive range *)

unsafe_block   = "unsafe" "{" ptr_op "}"
volatile_block = "volatile" "{" ptr_op "}"
ptr_op     = "*" "(" expr "as" type ")" "->" IDENT          (* load  *)
           | "*" "(" expr "as" type ")" "=" expr            (* store *)

asm_stmt   = "asm" "(" STR_LIT ")" asm_clause*
           | "asm" "{" (STR_LIT ";"?)* "}" asm_clause*
asm_clause = "in"       "(" (IDENT "->" IDENT ("," IDENT "->" IDENT)*)? ")"
           | "out"      "(" (IDENT "->" IDENT ("," IDENT "->" IDENT)*)? ")"
           | "clobbers" "(" (IDENT ("," IDENT)*)? ")"

assign_stmt     = lvalue "=" expr
compound_assign = lvalue ("+=" | "-=" | "*=" | "/=" | "%="
                        | "&=" | "|=" | "^=" | "<<=" | ">>=") expr
lvalue      = IDENT | IDENT "[" expr "]" | IDENT ("." IDENT)+

expr_stmt   = expr
```

Statement terminators are optional — a newline or the start of the next
statement terminates the previous one. A bare `;` is allowed as a separator.

## Expressions

Precedence (low → high), all left-associative except as noted:

| Prec | Operators                         | Kind       |
|------|-----------------------------------|------------|
|   0  | `?:`                              | ternary (right-assoc) |
|   1  | `\|\|`                            | logical    |
|   2  | `&&`                              | logical    |
|   3  | `==` `!=`                         | equality   |
|   4  | `<` `<=` `>` `>=`                 | compare    |
|   5  | `+` `-`                           | additive   |
|   6  | `*` `/` `%`                       | multiplicative |
|   7  | `<<` `>>`                         | shift      |
|   8  | `&` `\|` `^`                      | bitwise    |
|  —   | prefix `!` `-` `~`                | unary (right-assoc) |

```
expr        = ternary
ternary     = binary_expr ("?" expr ":" expr)?    (* right-assoc; both arms
                                                     are full exprs, so a
                                                     ternary nests in either *)
binary_expr = unary (binop unary)*                (* Pratt, see table *)
unary       = ("!" | "-" | "~")* primary
primary     = INT_LIT | FLOAT_LIT | STR_LIT | CHAR_LIT
            | "true" | "false"
            | fstring
            | "(" expr ")"
            | "sizeof" "(" type ")"
            | match_expr
            | postfix

match_expr  = "match" expr "{" match_expr_arm* "}"   (* match in value position *)
match_expr_arm = pattern ("," pattern)* "=>" expr    (* arm body is one expr;
                                                        the match yields its
                                                        value, or 0 if no arm
                                                        matches and no `_` *)

postfix     = IDENT call_suffix?
            | IDENT generics? "(" arg_list? ")"
            | IDENT "[" expr "]" ("." IDENT)?
            | IDENT ("." IDENT)+ ("(" arg_list? ")")?   (* chained / method call *)
            | IDENT "{" struct_init "}"                 (* struct literal *)

call_suffix = "(" arg_list? ")"
arg_list    = expr ("," expr)*
struct_init = named_fields | positional_fields
named_fields      = (IDENT ":" expr) ("," IDENT ":" expr)* ","?
positional_fields = expr ("," expr)* ","?

fstring     = FSTR_BEGIN (STR_PART | expr)* FSTR_END
```

`sizeof` accepts a type keyword or struct name. Method-call form
`obj.method(args)` is sugar for `method(obj, args)`.

## Operator list (tokens)

```
+  -  *  /  %        &  |  ^  ~  <<  >>
==  !=  <  <=  >  >=
&&  ||  !
=   +=  -=  *=  /=  %=  &=  |=  ^=  <<=  >>=
->  =>  ..  .  ,  ;  :
(  )  [  ]  {  }
```

## Reserved / built-in identifiers

These bind to compiler-provided intrinsics, not user functions. All **82**,
as `is_builtin` in `src/analysis.kr` lists them — that function is the
canonical set, and defining a function with one of these names is an error
(`@builtin_override` shadows one deliberately):

```
alloc dealloc memcpy memset            exit read write
print println print_str println_str    fmt_uint
file_open file_read file_write file_close file_size
str_len str_eq
load8 load16 load32 load64             store8 store16 store32 store64
vload8 vload16 vload32 vload64         vstore8 vstore16 vstore32 vstore64
atomic_load atomic_store atomic_cas
atomic_add atomic_sub atomic_and atomic_or atomic_xor
bit_get bit_set bit_clear bit_toggle bit_range bit_insert
signed_lt signed_gt signed_le signed_ge
sqrt sqrt_f32 sqrt_f64 fma_f64
int_to_f32 int_to_f64  f32_to_int f64_to_int
f32_to_f64 f64_to_f32  f16_to_f32 f32_to_f16
call_ptr call_ptr_f64 fn_addr
dmb dsb isb  dcache_flush icache_invalidate
asm syscall_raw time_ns
exec_process exec_process_argv set_executable
get_target_os get_arch_id get_module_path
```

**Names that are *not* builtins, though they read like they should be.**
`mmap`, `munmap`, `open`, `close` and `syscall` do not exist at all — calling
one is `error: undefined function`. `memcmp` and `memzero` are **stdlib**
functions in `std/mem.kr`, not intrinsics, so they need the import like any
other library call. `sizeof` is a *keyword*, listed with the keywords above,
not an identifier that could be shadowed. `cpuid` and `rdrand` are inline-`asm`
mnemonics only.

The stdlib (`std/*.kr`) layers additional helpers (`str_index_of`, `opt_some`,
`realloc`, `alloc_aligned`, …) on top of these — see
[STDLIB.md](STDLIB.md).

## Grammar notes and foot-guns

1. **Struct-vs-variable ambiguity.** `Foo x` parses as a variable declaration
   only if `Foo` is already registered as a struct. Forward references are
   not supported — declare the struct first.
2. **Type aliases are name-only.** `type Age = u32` makes `Age x` work, but
   the alias has no compile-time distinct identity; `Age` and `u32` are
   interchangeable in all expressions.
3. **Generics are purely syntactic.** `fn foo<T>(T x)` parses and erases to
   `fn foo(uint64 x)` — there is no monomorphization and no type parameter
   lookup.
4. **Static initializers accept literals only.** A non-literal RHS (including
   `alloc(...)`) is silently discarded — the slot keeps a leading literal if
   the expression starts with one (`= 5 + 3` stores 5) and is zero otherwise.
   Tracked as roadmap item #53.
5. **Assignment is a statement, not an expression.** You cannot write
   `while (x = next()) != 0`; extract the assignment first.
6. **`for` is desugared.** `for i in 0..n { ... }` becomes a `while` with an
   incrementing `u64` induction variable. No iterator protocol. The `in`
   keyword is optional (`for i 0..n` also parses), and the range can be
   inclusive (`..=`) or exclusive (`..`). Identifier endpoints work:
   `for i a..b` and `for i 0..=n` both parse correctly.
7. **`match` arms don't fall through.** An arm body is a brace block, a
   single bare statement (`1 => exit(1)`), or — in value position — a
   single expression (see `match_expr` above). Exactly one arm runs.
8. **`unsafe` / `volatile` blocks wrap exactly one pointer op.** They are
   statement forms, not expression wrappers.

## Constant expressions

An **array size** is a compile-time constant expression, not merely an `INT_LIT`.
This document said `"[" INT_LIT "]"` in all three array productions until
2026-09-21; that was stale, and it cost a downstream project real work — a gap
was reported against the compiler that does not exist, and a gate row plus two
mutants were written to police two literals that could simply have been one.

```
const_expr    = const_tern
const_tern    = const_lor ("?" const_tern ":" const_tern)?   (* right-assoc *)
const_lor     = const_land ("||" const_land)*
const_land    = const_eq (("&&") const_eq)*
const_eq      = const_cmp (("==" | "!=") const_cmp)*
const_cmp     = const_add (("<" | "<=" | ">" | ">=") const_add)*   (* UNSIGNED *)
const_add     = const_mul (("+" | "-") const_mul)*
const_mul     = const_shift (("*" | "/" | "%") const_shift)*
const_shift   = const_bit (("<<" | ">>") const_bit)*
const_bit     = const_prim (("&" | "|" | "^") const_prim)*
const_prim    = INT_LIT                     (* decimal, 0x hex or 0b binary *)
              | CHAR_LIT
              | "true" | "false"            (* 1 and 0 *)
              | IDENT                       (* a const or static declared EARLIER *)
              | "sizeof" "(" type_or_struct_name ")"
              | "-" const_prim | "~" const_prim | "!" const_prim
              | "(" const_expr ")"
```

**This ladder is the same one as the expression grammar above** — `& | ^`
tightest at 8, then `<< >>`, `* / %`, `+ -`, comparison, equality, `&&`, `||`,
`?:` — and that is newer than it looks. Until this revision the folder nested
C's way, with `|` loosest and `&` below `<<`, so a constant expression *silently*
meant something different from the same text in a function body:
`static uint64 S = 2 + 3 & 4` folded to 4 where the body evaluates 2, and
`1 << 2 * 3` folded to 64 where the body evaluates 12. The chain also stopped at
`|`, so everything looser was left on the cursor rather than refused — `A > 2`
folded to `A` and dropped the `> 2`.

Two consequences worth knowing:

* **Comparisons fold unsigned.** There is no type beside a value in the folder,
  and a folded initializer is stored as a bare `u64` bit pattern, so `<` `<=`
  `>` `>=` are unsigned there. A signed comparison belongs in a body.
* **`&&` and `||` do not short-circuit when folded.** Both sides are evaluated.
  Nothing in a constant expression can have an effect, and stopping early would
  leave the right-hand tokens on the cursor.

An operator this ladder cannot take is now an **error** rather than a silent
truncation: `static uint64 X = A += 1` is refused, where it used to store `A`.

Implemented by `parse_const_expr()` / `parse_const_array_size()` in
`src/parser.kr`; the `pce_*` chain above it is this precedence ladder, and
`pce_trailing_guard` is the refusal.

**The one real restriction is ordering.** An `IDENT` must name a `const` or
`static` declared *earlier* in the file. A forward reference, or any runtime
variable, is rejected:

```
static u8[LATER] BUF        (* error: not a const or static declared earlier, *)
const uint64 LATER = 8      (*        so it has no compile-time value         *)
```

**A `static`'s initializer folds too, and this document said for a long time
that it did not.** `static uint64 X = 16 * 1024` **is** 16384; so are
`static uint64 B = A + 1` (referring to an earlier `static`), `1 << 12`,
`sizeof(uint64)` and `A > 2 ? 10 : 20`. The claim that initializers were
"genuinely literal-only" was wrong, and it was believed downstream — it is the
kind of stale sentence that makes people write out `4096` by hand and add a
comment explaining why they had to.

What is true is that the *initializer* position has a narrower **entry**
condition than the folder: the declaration parser only routes an initializer
into `parse_const_expr` when it starts with one of a listed set of tokens. A
string literal deliberately stays out (it has its own later fixup), and a float
literal keeps its own branch. Anything else that fails to match used to fall
through to a skip path and leave the static at `0` — which is how
`static uint64 S = sizeof(uint64)` came to be `0` while `sizeof(uint64)` in a
body was `8`. `sizeof` and `!` are on that list now.

Verified against `build/krc2` at 7d23940 on 2026-09-21 — and verified to the
emitted code, not just to "the parser accepted it":

1. **Identical codegen.** One program, compiled twice, differing *only* in how
   the three array sizes are spelled (`[CAP]`/`[NP]` versus `[64]`/`[8]`, with
   the consts still declared in both so only the spelling varies) produces
   **byte-identical** executables. The constant is folded and codegen is handed
   the same number.
2. **Correct at run time.** A harness fills two `const`-sized statics, a
   `const`-sized stack array, a `const`-sized struct array and a 100,000-byte
   static, then verifies every element *after* all the writes, so any overlap
   or short allocation shows up. It exits 0.
3. **The harness can fail.** Three mutants, each caught with its own exit code:
   a wrong expected fill value, a wrong byte at index 99,999, and — the one that
   matters — shrinking a static to 8 bytes so its neighbour's fill overruns it,
   which the harness detects. A green run therefore means something.
4. The reported image size tracks the constant exactly (`N + fixed overhead` at
   1 KiB, 64 KiB, 1 MiB and 4 MiB). Note the *on-disk* file shrinks for large
   `N` as the array moves to `.bss`; the compiler's reported size is the honest
   witness, not `stat`.

The forms verified:

```
const uint64 CAP = 64
static u8[CAP] BUF                  fn main() -> uint64 { u8[CAP] b  ... }
static u8[CAP*2] BUF2               struct P { uint64 x }
static u8[32*2] BUF3                fn main() -> uint64 { P[CAP] ps  ... }
static u8[0x100] BUF4
```
