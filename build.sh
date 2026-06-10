#!/bin/bash
set -euo pipefail

KERNRIFTC="${KERNRIFTC:-kernriftc}"
DIR="$(cd "$(dirname "$0")" && pwd)"

# Combine all source files into a single compilation unit.
# This list MUST match the Makefile SRCS order exactly (single source of
# truth). It was previously missing ir.kr, ir_aarch64.kr, bcj.kr,
# type_check.kr and formatter.kr, so this Rust-bootstrap path failed to
# build (e.g. on resolve_inferred_types / the IR backend). M16.
cat \
    "$DIR/src/lexer.kr" \
    "$DIR/src/ast.kr" \
    "$DIR/src/parser.kr" \
    "$DIR/src/codegen.kr" \
    "$DIR/src/codegen_aarch64.kr" \
    "$DIR/src/ir.kr" \
    "$DIR/src/ir_aarch64.kr" \
    "$DIR/src/format_macho.kr" \
    "$DIR/src/format_pe.kr" \
    "$DIR/src/format_archive.kr" \
    "$DIR/src/format_android.kr" \
    "$DIR/src/bcj.kr" \
    "$DIR/src/analysis.kr" \
    "$DIR/src/type_check.kr" \
    "$DIR/src/inliner.kr" \
    "$DIR/src/living.kr" \
    "$DIR/src/runtime.kr" \
    "$DIR/src/formatter.kr" \
    "$DIR/src/main.kr" \
    > "$DIR/build/krc.kr"

# Compile to native hostexe
"$KERNRIFTC" --emit=hostexe "$DIR/build/krc.kr" -o "$DIR/build/krc"
chmod +x "$DIR/build/krc"

echo "Built: $DIR/build/krc"
