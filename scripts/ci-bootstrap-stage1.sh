#!/bin/bash
# Produce an intermediate compiler capable of building the CURRENT source.
#
# WHY THIS EXISTS
#
# The pinned bootstrap binary (v2.8.26) has four fixed-size compiler tables
# compiled into it. `dce_fn_map`, at 1024 entries, is the binding one. The
# current source registers more functions than that, so the old seed aborts
# with "error: dce_fn_map overflow (max 1024)" and simply cannot build it.
#
# v2.8.33 makes those tables grow on demand -- but a *released binary*
# containing that fix does not exist yet, and the cap lives in the compiler
# doing the compiling, not in the source being compiled. Hence a middle step:
#
#   stage 1 (this script)  seed(v2.8.26) + bootstrap-base tree -> krc-inter
#   stage 2 (the caller)   krc-inter     + current source      -> krc2
#
# The bootstrap-base-v2.8.33 tag is the growable-table fix on a tree small
# enough (1018 registrations against the 1024 cap) for the old seed to compile.
#
# THIS IS TEMPORARY. Once v2.8.33 is published, repin the workflows' download
# to v2.8.33 and call the seed directly again -- then delete this script.
set -euo pipefail

SEED=${SEED:-build/krc-bootstrap}
OUT=${OUT:-build/krc-inter}
TAG=${TAG:-bootstrap-base-v2.8.33}
WORK=${WORK:-/tmp/kr-bootstrap-base}

if [ ! -x "$SEED" ]; then
    echo "FAIL: seed compiler '$SEED' is missing or not executable"
    exit 1
fi

# Shallow checkouts carry no tags; fetch just this one.
if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    git fetch --no-tags --depth=1 origin "refs/tags/$TAG:refs/tags/$TAG"
fi

rm -rf "$WORK"
mkdir -p "$WORK"
git archive "$TAG" | tar -x -C "$WORK"
make -C "$WORK" build/krc.kr >/dev/null

rm -f "$OUT"
# --legacy for speed: this compiler is a throwaway used only to build the real
# one, and stage 2 re-compiles everything through the IR backend anyway.
"$SEED" --legacy --arch=x86_64 "$WORK/build/krc.kr" -o "$OUT"
chmod +x "$OUT"

if [ ! -s "$OUT" ]; then
    echo "FAIL: stage-1 compiler '$OUT' was not produced"
    exit 1
fi
echo "OK: stage-1 compiler at $OUT ($(wc -c < "$OUT") bytes), built from $TAG"
