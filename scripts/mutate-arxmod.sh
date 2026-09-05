#!/bin/bash
# Mutation gate for --emit=arxmod (src/format_arx.kr).
#
# The four suite rows that check a module container assert on FOUR SMALL
# INTEGERS read at fixed offsets, and small integers at fixed offsets are the
# easiest kind of assertion to write vacuously: a 1 or a 6 is somewhere in every
# container. Each mutant below breaks exactly one of the four properties, and
# the named row must fail.
#
# M3 is the one that already happened. The emitter's pad cursor was the literal
# 168 -- correct for the one-table layout and 24 bytes short for a module's two
# -- so every MODINFO field landed 24 bytes past the offset its own directory
# entry declared, and the loader read three zeros and a one-byte name.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR" || exit 1
F=src/format_arx.kr
BK=/tmp/format_arx.orig
cp "$F" "$BK"
restore() { cp "$BK" "$F"; }
trap 'restore; rm -rf "$D"' EXIT
D=$(mktemp -d)
printf 'static u64 d = 32\nfn main(u64 svc) -> u64 { return d }\n' > "$D/m.kr"
printf 'fn main() -> u64 { return 0 }\n' > "$D/p.kr"
KILLED=0; SURVIVED=0

check() {   # check <expect-broken-row>
    local want="$1"
    # DELETE LAST ROUND'S ARTIFACTS FIRST. Without this a mutant that makes krc
    # REFUSE to emit leaves the previous round's good container in place, the
    # inspector reads it, and the mutant is recorded as having survived -- which
    # is what M4 did on the first run: it breaks the plain path so hard that
    # "entry offset lies inside the header region" is all krc produces, and that
    # read as "still passing".
    rm -f "$D/m.arxm" "$D/p.arx"
    # A BUILD FAILURE IS A WEAK KILL and must say why. "the compiler no longer
    # builds" is indistinguishable from a flaky tree, and it hid a real result
    # once already in this project's history -- so the first error line is
    # printed rather than swallowed.
    if ! make >/tmp/mut-arxmod-build.txt 2>&1; then
        echo "  $want: killed (build failed: $(grep -m1 -E 'error|Error' /tmp/mut-arxmod-build.txt | head -c 120))"
        KILLED=$((KILLED+1)); return
    fi
    ./build/krc2 --arch=x86_64 --target=none --emit=arxmod --mod-name=gatemod --mod-abi=3 \
        --mod-version=9 "$D/m.kr" -o "$D/m.arxm" >/dev/null 2>&1
    ./build/krc2 --arch=x86_64 --target=none --emit=arx "$D/p.kr" -o "$D/p.arx" >/dev/null 2>&1
    local broke
    broke=$(python3 - "$D/m.arxm" "$D/p.arx" <<'PY'
import struct, sys
bad=[]
try:
    m=open(sys.argv[1],'rb').read(); p=open(sys.argv[2],'rb').read()
except Exception:
    print("arxmod_sets_module_flag arxmod_modinfo_is_mandatory arxmod_modinfo_fields arx_is_not_a_module arxmod_header_region_is_4096"); raise SystemExit
if struct.unpack_from('<H',m,10)[0] != 7: bad.append("arxmod_sets_module_flag")
if (struct.unpack_from('<I',m,12)[0], struct.unpack_from('<I',m,88)[0],
    struct.unpack_from('<I',m,92)[0]) != (2,6,1): bad.append("arxmod_modinfo_is_mandatory")
name = m[216:m.index(b'\0',216)] if b'\0' in m[216:260] else b''
if struct.unpack_from('<QQQ',m,192) != (3,9,0) or name != b'gatemod':
    bad.append("arxmod_modinfo_fields")
if struct.unpack_from('<I',p,12)[0] != 1 or struct.unpack_from('<Q',p,72)[0] != 88 \
   or (struct.unpack_from('<H',p,10)[0] & 4): bad.append("arx_is_not_a_module")
if struct.unpack_from('<Q',m,112)[0] != 4096 or len(m) != 4096 + struct.unpack_from('<Q',m,32)[0]:
    bad.append("arxmod_header_region_is_4096")
print(" ".join(bad))
PY
)
    case " $broke " in
        *" $want "*) echo "  $want: killed (row fails: $broke)"; KILLED=$((KILLED+1)) ;;
        *) echo "  $want: SURVIVED -- rows still passing (broken: '${broke:-none}')"; SURVIVED=$((SURVIVED+1)) ;;
    esac
}

echo "=== baseline ==="
restore
make >/dev/null 2>&1 || { echo "  baseline: BUILD FAILED"; exit 1; }
./build/krc2 --arch=x86_64 --target=none --emit=arxmod --mod-name=gatemod --mod-abi=3 \
    --mod-version=9 "$D/m.kr" -o "$D/m.arxm" >/dev/null 2>&1
./build/krc2 --arch=x86_64 --target=none --emit=arx "$D/p.kr" -o "$D/p.arx" >/dev/null 2>&1
base=$(python3 -c "
import struct
m=open('$D/m.arxm','rb').read(); p=open('$D/p.arx','rb').read()
ok = (struct.unpack_from('<H',m,10)[0]==7 and
      (struct.unpack_from('<I',m,12)[0],struct.unpack_from('<I',m,88)[0],struct.unpack_from('<I',m,92)[0])==(2,6,1) and
      struct.unpack_from('<QQQ',m,192)==(3,9,0) and m[216:223]==b'gatemod' and
      struct.unpack_from('<I',p,12)[0]==1 and struct.unpack_from('<Q',p,72)[0]==88)
print('OK' if ok else 'BROKEN')")
[ "$base" = "OK" ] || { echo "  baseline: FAIL -- a clean tree already breaks a row"; exit 1; }
echo "  baseline: PASS"
[ -n "${MUTATE_BASELINE_ONLY:-}" ] && exit 0

echo "=== M1: the MODULE flag bit is never set ==="
restore
sed -i 's|    if arx_is_module != 0 { fl = fl \| 4 }|    if arx_is_module != 0 { fl = fl \| 0 }|' "$F"
grep -q 'fl = fl | 0' "$F" || { echo "  M1 did not apply"; exit 2; }
check arxmod_sets_module_flag

echo "=== M2: MODINFO is emitted as a SEGMENT table instead ==="
restore
sed -i 's|        emit_u32_le(ARX_KIND_MODINFO)|        emit_u32_le(1)|' "$F"
grep -q 'ARX_KIND_MODINFO' "$F" && grep -q 'emit_u32_le(1)$' "$F" || true
check arxmod_modinfo_is_mandatory

# M3 IS THE BUG THAT ALREADY HAPPENED, and getting it right took two attempts
# worth recording. The first version moved the pad CURSOR back to its old
# literal 168 -- and produced a BYTE-IDENTICAL container, because main.kr
# page-aligns the payload for --emit=arx anyway and absorbs the 24-byte
# difference in its own padding. That was an EQUIVALENT MUTANT, not a surviving
# one, and reporting it as "survived" would have been a false accusation
# against a row that is fine. The cursor turns out not to be load-bearing.
#
# The real defect was 24 zero bytes emitted BEFORE the MODINFO fields, which
# moved the fields themselves past the offset their own directory entry
# declares -- the loader then read three zeros and a one-byte name. That is
# what this reinstates, and row three is what catches it.
echo "=== M3: 24 zero bytes emitted ahead of the MODINFO fields ==="
restore
python3 scripts/_mut_arxmod_m3.py || exit 2
grep -q 'while mz < 24' "$F" || { echo "  M3 did not apply"; exit 2; }
check arxmod_modinfo_fields

echo "=== M4: a plain container gets the module's segment-table offset ==="
restore
sed -i 's|    if arx_is_module != 0 { arx_seg_tab = 112 } else { arx_seg_tab = 88 }|    arx_seg_tab = 112|' "$F"
grep -q '^    arx_seg_tab = 112$' "$F" || { echo "  M4 did not apply"; exit 2; }
check arx_is_not_a_module

restore
make >/dev/null 2>&1
echo "=== $KILLED killed / $SURVIVED survived ==="
[ "$SURVIVED" -eq 0 ]
