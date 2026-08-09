# Tutorial — Persistent B-tree in KernRift

This tutorial builds a durable on-disk B-tree index, like the ones
sqlite and lmdb use. The goal is a small, readable implementation — not
a production database — but one that survives crashes, supports range
scans, and lets you reason about every byte on disk.

By the end you'll have:

1. A page manager that mmaps a single file.
2. An 8 KiB B-tree node layout and a search/insert/split algorithm.
3. A one-phase durability strategy: write ahead a new root, fsync, swap.
4. A CLI that `put` / `get` / `list` / `delete`s `u64 → u64` mappings.

`examples/tutorial-btree/` ships the **page manager** from §2 — the
mmap-backed persistence layer everything else stands on — with a smoke test
(`make check`) that writes, `msync`s, re-opens and verifies. The B-tree
itself is what this document walks you through building on top of it; it is
deliberately not shipped pre-written.

---

## 1. Why a B-tree and not a B+-tree?

- **B-tree**: keys live in every node.
- **B+-tree**: keys live only in leaves; internal nodes have separator
  keys only.

B+-trees are better for range scans (leaves form a linked list). B-trees
are simpler to reason about for a first implementation. We'll start with
a plain B-tree and revisit the choice in the "extending" section.

---

## 2. Page manager

A *page* is 8 KiB. The file is a growing array of pages. Page 0 is
the header; pages 1..N are tree nodes.

```kernrift
const u64 PAGE_SIZE = 8192
const u64 MAGIC = 0x4B52425445455231   // "KRBTEER1" read big-endian
// Stored with store64 this lands in memory as the bytes "1REETBRK" -- the
// ASCII reads left-to-right only in the big-endian view. That is fine for a
// magic number, which is just a bit pattern, but do not expect `xxd` to show
// you "KRBTEER1".

struct Header {
    u64 magic        // sanity check
    u64 root_pageno  // current root
    u64 next_free    // first page after the last one in use
    u64 version      // bumps on every commit
}
```

Opening the file:

**There is no `open`, `ftruncate`, `mmap` or `msync` in the standard
library** — `std/io.kr` gives you whole-file `read_file`/`write_file` and
nothing memory-mapped. For a page manager you go through `syscall_raw`
directly, and you supply the syscall numbers yourself because they differ per
architecture:

```kernrift
// get_arch_id(): 1 = linux-x86_64, 2 = linux-arm64.
// arm64 has no plain `open`; it only has `openat`.
fn nr_openat()    -> u64 { u64 a = get_arch_id()  if a == 2 { return 56 }   return 257 }
fn nr_ftruncate() -> u64 { u64 a = get_arch_id()  if a == 2 { return 46 }   return 77 }
fn nr_mmap()      -> u64 { u64 a = get_arch_id()  if a == 2 { return 222 }  return 9 }
fn nr_msync()     -> u64 { u64 a = get_arch_id()  if a == 2 { return 227 }  return 26 }
fn nr_close()     -> u64 { u64 a = get_arch_id()  if a == 2 { return 57 }   return 3 }

fn db_open(u64 path, u64 size) -> u64 {
    // openat(AT_FDCWD, path, O_RDWR|O_CREAT, 0644). AT_FDCWD is -100.
    u64 fd = syscall_raw(nr_openat(), 0xFFFFFFFFFFFFFF9C, path, 0x42, 420, 0, 0)
    if fd > 0xFFFFFFFFFFFFF000 { return 0 }          // -errno
    if syscall_raw(nr_ftruncate(), fd, size, 0, 0, 0, 0) > 0xFFFFFFFFFFFFF000 { return 0 }
    // mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0)
    u64 base = syscall_raw(nr_mmap(), 0, size, 3, 1, fd, 0)
    if base > 0xFFFFFFFFFFFFF000 { return 0 }
    return base
}

fn db_sync(u64 base, u64 size) -> u64 {
    // msync(base, size, MS_SYNC)
    return syscall_raw(nr_msync(), base, size, 4, 0, 0, 0)
}
```

A raw syscall returns `-errno` in the range `[-4095, -1]`, which as an
unsigned value is `> 0xFFFFFFFFFFFFF000` — that is the error test above, and
it is the same threshold `std/io.kr`'s `is_errno` uses. `is_errno` itself is
fine to use here instead.

The mmap gives us byte pointers directly; no buffer-pool machinery. It only
works up to the mapped region size, and extending it in place is a re-mmap
away.

**This code is verified**: opening a file, truncating to 8 KiB, mapping it,
writing the magic, `msync`ing and reading it back returns the written value on
both x86_64 and arm64. Everything after this section assumes `db_open` hands
you a base pointer.

---

## 3. Node layout

Each 8 KiB node:

```
offset  size    field
0       2       flags              bit 0: leaf
2       2       n_keys             0..N_MAX
4       4       — padding —
8       k*8     keys[]             u64
8+N*8   k*8     values[]           u64 (only valid if leaf)
8+2N*8  (k+1)*8 children[]         u64 pageno (only valid if internal)
```

The offsets above are fixed, so **every** node reserves `keys[]`,
`values[]` and `children[]` whether or not it uses them. With
`PAGE_SIZE = 8192` that gives `8 + 8N + 8N + 8(N+1) = 8192`, i.e. **N = 340
for internal nodes and leaves alike** — a leaf does not get fewer entries for
"also carrying values", because the space for children it never uses is
reserved regardless.

If you instead gave leaves their own layout with no `children[]`, they would
fit `8 + 8N + 8N = 8192` → **511** keys, i.e. *more* than an internal node,
not fewer. Doing that costs you a single uniform node accessor, which is why
this tutorial keeps one layout.

We'll cap at `N_MAX = 255` to leave slack.

```kernrift
const u64 N_MAX  = 255
const u64 N_MIN  = 85       // floor(N_MAX / 3) — chosen so splits always fit

fn node_is_leaf(u64 page) -> u64 {
    u64 v = 0
    unsafe { *(page as uint16) -> v }
    return v & 1
}

fn node_nkeys(u64 page) -> u64 {
    u64 v = 0
    u64 p = page + 2
    unsafe { *(p as uint16) -> v }
    return v
}

fn node_key(u64 page, u64 i) -> u64 {
    u64 p = page + 8 + i * 8
    u64 k = 0
    unsafe { *(p as uint64) -> k }
    return k
}
```

Define the value/child accessors similarly. Keep every offset in one
place (a few named constants) so the layout is easy to audit.

---

## 4. Search

Inside a node, binary-search the key array:

```kernrift
fn node_find(u64 page, u64 key) -> u64 {
    u64 n = node_nkeys(page)
    u64 lo = 0
    u64 hi = n
    while lo < hi {
        u64 mid = (lo + hi) / 2
        u64 mk = node_key(page, mid)
        if mk < key { lo = mid + 1 }
        else { hi = mid }
    }
    return lo    // insertion point
}

fn db_get(u64 base, u64 key) -> u64 {
    u64 hdr = base
    u64 root_no = load64(hdr + 8)
    u64 page = base + root_no * PAGE_SIZE
    while node_is_leaf(page) == 0 {
        u64 i = node_find(page, key)
        u64 child = node_child(page, i)
        page = base + child * PAGE_SIZE
    }
    u64 i = node_find(page, key)
    if i < node_nkeys(page) && node_key(page, i) == key {
        return opt_some(node_value(page, i))
    }
    return opt_none()        // Pattern-1 "not found"
}
```

`opt_some` / `opt_none` come from `std/string.kr` — see
`docs/ERROR_HANDLING.md`.

---

## 5. Insert and split

Insertion walks down to a leaf and inserts. If the leaf is full, split:
the middle key is promoted to the parent, and the parent may split, and
so on up to the root.

The trick is to do *all* splits before descending — "proactive splitting"
— so you never have to walk back up the tree:

```
insert(root, key, value):
    if root is full:
        new_root = allocate_page()
        make new_root a 1-child internal node pointing at root
        split_child(new_root, 0)
        header.root = new_root
    insert_nonfull(new_root, key, value)

insert_nonfull(page, key, value):
    if page is leaf:
        shift keys[i..] and values[i..] right by one
        write key, value at position i
        n_keys += 1
    else:
        i = node_find(page, key)
        child = children[i]
        if child is full:
            split_child(page, i)
            if key > keys[i]: i += 1
        insert_nonfull(children[i], key, value)
```

`split_child(parent, i)`:

1. Allocate a new page `right`.
2. Copy the upper half of `children[i]` into `right`.
3. Shift `parent`'s keys and children to make room.
4. Insert the median of `children[i]` at parent position `i`,
   pointing `parent.children[i+1]` at `right`.

All memory touches are to the mmap region, so they go straight to the
page cache. They are not yet durable — that happens at commit time.

---

## 6. Durability

Option A: fsync after every insert. Correct, slow.

Option B: *copy-on-write* the whole path. For each mutation:

1. Allocate a fresh page for every node on the path from root to leaf.
2. Write the new versions to those new pages.
3. When you reach the top, the new root has a new pageno. Fsync.
4. Write the new root pageno into the header.
5. Fsync the header.

If the machine crashes between 3 and 4, the old tree is still intact —
the new pages are leaked (see "garbage collection") but correctness
holds. If it crashes between 4 and 5, the header's `root_pageno` still
points at the old root, and the header write is a single 8-byte aligned
store — always atomic on x86 and ARMv8.

This is the design lmdb uses. Implementation:

```kernrift
fn db_put(u64 base, u64 key, u64 val) {
    u64 hdr = base
    u64 old_root = load64(hdr + 8)
    u64 new_root = cow_insert(base, old_root, key, val)

    // Two fsyncs:
    dsb()                             // make all node writes visible
    db_sync(base, size)               // msync the tree pages

    // Now commit the root switch.
    u64 rp = hdr + 8
    unsafe { *(rp as uint64) = new_root }
    db_sync(base, size)               // msync the header
}
```

`cow_insert` returns the pageno of the new root of the modified path.
Every ancestor of the inserted leaf got a fresh page; siblings were
not touched.

---

## 7. Range scans

Because keys are sorted within each node, a range scan is a stack-based
traversal:

```kernrift
fn db_range(u64 base, u64 lo, u64 hi, u64 cb) {
    // cb is a function pointer: fn_addr("name") takes the address and
    // call_ptr(p, args...) invokes it. Both work today.
    // Instead, inline the callback or use a polling "iterator":
    u64[16] stack
    u64 depth = 0
    // push root
    // while stack not empty:
    //   pop (page, index)
    //   if leaf: emit any keys in [lo, hi]
    //   else:    find entry range, push children
}
```

KernRift supports function pointers via the `fn_addr("name")` +
`call_ptr(fn, args...)` pair. A callback-style version looks like:

```kernrift
fn _cb_print(u64 key, u64 val) -> u64 {
    println(key); println(val); return 0
}

fn db_range(u64 base, u64 lo, u64 hi, u64 cb) {
    // ... walk the tree; at each qualifying (k, v):
    call_ptr(cb, k, v)
}

fn main() {
    u64 cb = fn_addr("_cb_print")
    db_range(base, 100, 200, cb)
}
```

`fn_addr` requires the function name as a string literal — it resolves
at link time, not at run time. For a true iterator that returns values,
use a state-machine with `iter_next()` / `iter_end()` that returns a
sentinel when done. (Neither is shipped — the example directory carries the
§2 page manager only.)

---

## 8. Command-line interface

```
./btree open mydb.idx
./btree put mydb.idx 42 123
./btree get mydb.idx 42      # → 123
./btree list mydb.idx
./btree del mydb.idx 42
```

The CLI is ~60 lines of plain `argv` handling plus calls into the
functions above.

---

## 9. Benchmark

**No numbers are quoted here, deliberately.** Earlier revisions of this
document gave throughput figures for a Raspberry Pi 4 and a comparison
against sqlite. Those numbers could not be reproduced: the artifact they were
measured on is not in this repository, and the primitives the tutorial
described at the time (`open`, `mmap`, `msync_full`) do not exist, so nothing
that could have produced them can be reconstructed.

If you build the tree and measure it, the figures worth reporting are inserts
per second at a stated fsync batch size, random gets per second, and the
storage device — sync latency dominates, so an insert rate without the fsync
policy beside it means nothing.

---

## 10. Extending the example

Ideas, in roughly increasing difficulty:

1. **Variable-length keys.** Add a 2-byte length prefix and store keys
   in a heap area at the bottom of the page, with a slot directory at
   the top (the sqlite approach).
2. **B+-tree.** Move values out of internal nodes. Add a `next_leaf`
   field so leaves form a linked list — range scans become O(log N + k).
3. **Freelist.** Track reclaimed pages after a CoW commit in a freelist
   node; allocate from it before growing the file.
4. **Transactions.** One writer, many concurrent readers — readers
   observe the root pageno once and are immune to later commits.
5. **Compression.** LZ-Rift (KernRift's built-in codec) on each page;
   the page cache sees compressed pages, decompression happens on the
   read path.

---

## Caveats

- **u64 keys only.** A real DB needs byte-string keys. The extension
  in step 1 above is a prerequisite for almost any real use.
- **No WAL.** CoW is a journal of sorts, but adding a WAL unlocks
  group commit and better tail latency.
- **Single-threaded.** The CoW approach supports MVCC naturally; the
  tutorial doesn't take advantage.
- **Endian-sensitive.** We store raw little-endian u64s. Opening a file
  produced on x86 / ARM on a big-endian host would corrupt it. Add a
  byte-swap step in `db_open` if you care.

---

## Further reading

- LMDB paper: Howard Chu, "MDB: A Memory-Mapped Database and Backend
  for OpenLDAP" (2011).
- SQLite page format:
  https://sqlite.org/fileformat2.html#b_tree_pages
- `docs/ERROR_HANDLING.md` — for the `opt_*` / `is_errno` patterns used
  in the example's API surface.
- `examples/tutorial-btree/Makefile` — builds the §2 page manager and runs
  its smoke test (`make check`).
