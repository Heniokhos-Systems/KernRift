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
INT_LIT     = DEC_LIT | HEX_LIT | BIN_LIT | OCT_LIT
DEC_LIT     = [0-9] ([0-9_]* [0-9])?
HEX_LIT     = "0x" [0-9A-Fa-f] ([0-9A-Fa-f_]* [0-9A-Fa-f])?
BIN_LIT     = "0b" [01] ([01_]* [01])?
OCT_LIT     = "0o" [0-7] ([0-7_]* [0-7])?
FLOAT_LIT   = [0-9]+ "." [0-9]+ ([eE] [+-]? [0-9]+)?
STR_LIT     = '"' (char_escape | [^"\\])* '"'
CHAR_LIT    = "'" (char_escape | [^'\\]) "'"
FSTR        = f"..." with embedded { expr } holes  (see Expressions)
char_escape = "\\" ( "n" | "t" | "r" | "\\" | "'" | '"' | "0"
                   | "a" | "b" | "f" | "v" | "x" HEX HEX
                   | "u{" HEX+ "}" )
COMMENT     = "//" [^\n]*  |  "/*" ... "*/"   (discarded)
```

Whitespace (spaces, tabs, CR, LF) is a token separator; no significant
indentation. The lexer emits ~112 token kinds; only the subset relevant to
grammar is referenced below.

## Keywords

```
fn return if else while for in break continue match let unsafe volatile asm
static const struct enum type true false sizeof extern device at
u8 u16 u32 u64 i8 i16 i32 i64 f32 f64 bool char float double
```

`float` is an alias for `f32`; `double` for `f64`.

## Module

```
module      = top_item*
top_item    = annotation* fn_decl
            | extern_decl
            | const_decl
            | static_decl
            | struct_decl
            | enum_decl
            | type_alias
            | device_decl
```

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
            | "static" type "[" INT_LIT "]" IDENT ("=" const_init)?
const_init  = INT_LIT | CHAR_LIT | "true" | "false"   (* only literals honoured *)

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
                | type "[" INT_LIT "]" IDENT    (* stack array *)
                | "let" IDENT "=" expr          (* type inferred from RHS;
                                                   the initializer is required *)
struct_var_decl = IDENT IDENT ("=" expr)?       (* IDENT is known struct *)
                | IDENT "[" INT_LIT "]" IDENT   (* struct array *)
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

These bind to compiler-provided intrinsics, not user functions:

```
alloc  dealloc  memcpy  memset  memcmp  memzero
read  write  open  close  mmap  munmap  exit
load8 load16 load32 load64  store8 store16 store32 store64
vload8 vload16 vload32 vload64  vstore8 vstore16 vstore32 vstore64
atomic_load atomic_store atomic_cas atomic_add atomic_sub atomic_and atomic_or atomic_xor
dmb dsb isb  dcache_flush icache_invalidate
time_ns  rdrand  cpuid
```

The stdlib (`std/*.kr`) layers additional helpers (`str_len`, `opt_some`,
`realloc`, `alloc_aligned`, …) on top of these.

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
   `alloc(...)`) is silently discarded, leaving the slot zero-initialized.
   Tracked as roadmap item #53.
5. **Assignment is a statement, not an expression.** You cannot write
   `while (x = next()) != 0`; extract the assignment first.
6. **`for` is desugared.** `for i in 0..n { ... }` becomes a `while` with an
   incrementing `u64` induction variable. No iterator protocol. The `in`
   keyword is optional (`for i 0..n` also parses), and the range can be
   inclusive (`..=`) or exclusive (`..`). Identifier endpoints work:
   `for i a..b` and `for i 0..=n` both parse correctly.
7. **`match` requires `=>` and blocks.** `match x { 1 => { ... } 2 => { ... } }`
   — no bare-expression arms. Arms do not fall through.
8. **`unsafe` / `volatile` blocks wrap exactly one pointer op.** They are
   statement forms, not expression wrappers.
