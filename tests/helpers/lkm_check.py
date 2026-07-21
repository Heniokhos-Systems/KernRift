#!/usr/bin/env python3
"""Structural checks on an --emit=lkm .ko. Pure-python ELF parsing on purpose:
gating on readelf/objdump would make this SKIP silently on a bare CI runner,
which is exactly how the ESP32 disasm checks lost coverage."""
import sys, struct

path, mode = sys.argv[1], sys.argv[2]
f = open(path, 'rb').read()

def die(msg):
    print("FAIL: %s" % msg)
    sys.exit(1)

if f[:4] != b'\x7fELF':      die("not an ELF")
if f[4] != 2:                die("not ELF64")
e_type    = struct.unpack_from('<H', f, 16)[0]
e_machine = struct.unpack_from('<H', f, 18)[0]
if e_type != 1:              die("e_type=%d, expected 1 (ET_REL) — a .ko must be relocatable" % e_type)
if e_machine != 0x3e:        die("e_machine=0x%x, expected 0x3e (x86-64)" % e_machine)

e_shoff     = struct.unpack_from('<Q', f, 0x28)[0]
e_shentsize = struct.unpack_from('<H', f, 0x3a)[0]
e_shnum     = struct.unpack_from('<H', f, 0x3c)[0]
e_shstrndx  = struct.unpack_from('<H', f, 0x3e)[0]

def sh(i):
    o = e_shoff + i * e_shentsize
    name, typ, flags, addr, off, size, link, info, align, entsize = \
        struct.unpack_from('<IIQQQQIIQQ', f, o)
    return dict(name=name, off=off, size=size, link=link, entsize=entsize)

shstr = sh(e_shstrndx)
def sname(off):
    base = shstr['off'] + off
    return f[base:f.index(b'\0', base)].decode()

sections = {}
for i in range(e_shnum):
    s = sh(i)
    sections[sname(s['name'])] = s

# Sections the kernel module loader actually requires.
for req in ('.text', '.modinfo', '.gnu.linkonce.this_module', '.symtab', '.strtab'):
    if req not in sections:
        die("missing section %s (have: %s)" % (req, ' '.join(sorted(sections))))

modinfo = f[sections['.modinfo']['off']:sections['.modinfo']['off'] + sections['.modinfo']['size']]
if b'license=' not in modinfo:
    die(".modinfo carries no license= key — the kernel taints/refuses without it")

# Symbols
symtab = sections['.symtab']
strtab = sh(symtab['link'])
syms = {}
for i in range(symtab['size'] // 24):
    o = symtab['off'] + i * 24
    st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from('<IBBHQQ', f, o)
    base = strtab['off'] + st_name
    nm = f[base:f.index(b'\0', base)].decode()
    if nm:
        syms[nm] = dict(size=st_size, bind=(st_info >> 4), shndx=st_shndx)

for req in ('init_module', 'cleanup_module', '__this_module'):
    if req not in syms:
        die("missing symbol %s — insmod resolves these by name" % req)
    if syms[req]['bind'] != 1:
        die("%s must be GLOBAL (bind=1), got bind=%d" % (req, syms[req]['bind']))

if mode == 'misc':
    # Kernel ABI struct sizes. struct file_operations is 272 bytes; note that
    # codegen.kr ALSO uses 272 as the struct-table entry stride for an unrelated
    # reason, so this assertion is what stops those two being conflated.
    if '_lkm_fops' not in syms:
        die("misc-device module has no _lkm_fops object")
    if syms['_lkm_fops']['size'] != 272:
        die("_lkm_fops is %d bytes, kernel struct file_operations is 272"
            % syms['_lkm_fops']['size'])
    if '_lkm_miscdev' not in syms:
        die("misc-device module has no _lkm_miscdev object")
    if syms['_lkm_miscdev']['size'] != 80:
        die("_lkm_miscdev is %d bytes, kernel struct miscdevice is 80"
            % syms['_lkm_miscdev']['size'])
    for ext in ('misc_register', 'misc_deregister'):
        if ext not in syms:
            die("missing extern %s" % ext)
        if syms[ext]['shndx'] != 0:
            die("%s must be UNDEFINED (resolved by the kernel at load)" % ext)

print("OK")
