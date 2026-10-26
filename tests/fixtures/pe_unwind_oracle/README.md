# pe_unwind_oracle — committed oracle images for #143 (Windows PE unwind tables)

These files let the `pe_unwind_*` suite rows check the checker against images whose
history is known, without reading anything outside the tree (plan rev 4, §0.x M2,
Mi3–Mi5). Nothing here is rebuilt by the suite; every row reads them as they are.

Compilers named below:

| name | what it is | sha256 |
|---|---|---|
| **base** | KernRift `d8f2a56` built to its fixed point (`make build/krc2` twice from a scratch `git clone --no-hardlinks`, stage 2 == stage 3) | `65d092cdd2cb6491ea4dd151ac3bc4bfbff0afbfc55450d005756c52093f1d9c` |
| **seed** | the `build/krc2` that built the spec's original evidence: one self-compile generation behind the `d8f2a56` fixed point (same sources; its Windows output differs from **base** in 1162 bytes of `nest8.exe`, its non-Windows output does not differ on the identity corpus) | `4d02cd239fb8db4a13f10aa25c52a4a8910c100f65220a0678158df9d159ddf8` |
| **proto** | branch `proto-fp` (`ab881bd`, "PROTOTYPE ONLY: reserve rbp + mov rbp,rsp on PE"), a 4-line change to `src/ir.kr` on `d8f2a56`, built to `krc_proto` | `48676d57f2d75cf6f8dce9c5c00987b72c62b1a53467c275b91d29fecaa8954d` |

`add_unwind_x64.py` is the spec's prototype post-processor (spec §1.3): it appends a
`.pdata` section describing each function's prologue as decoded by capstone, with
`.xdata` in the same section (sha256
`fa031c33e8dc5734a60ba09425631613399ecd6d8ca86087a66fb05520216198`; not in the tree).

| file | source | how it was made | sha256 |
|---|---|---|---|
| `nest.kr` | spec evidence fixture: 4 frames, the deepest faults | — | `b168668802631d82185743bcaa5594272cbacf814400a19f3d55fdd7c7906cac` |
| `nest.exe` | `nest.kr` | **base** `--arch=x86_64 --target=windows --emit=pe nest.kr -o nest.exe` — a table-less image (no DataDirectory[3]) | `88db77c31ca24ebc20c61a5cdb781139a9d3f955c4b5ef6c7f9045607a491155` |
| `nest.asm` | `nest.kr` | **base** `--arch=x86_64 --target=windows --emit=asm nest.kr -o nest.asm` | `19c96e8b27ac01f268b09b4e6a1e5f1b1f370ba632f7448181b3d6d1f8424644` |
| `nest8.kr` | spec evidence fixture: an 8-argument callee faults while its caller has `sub rsp,0x10` live | — | `5e93afce48f06858f11e157ef375b878d01d7bc9b5d7368e140cdd7efe426442` |
| `nest8_uw.exe` | `nest8.kr` | **seed** `--arch=x86_64 --target=windows --emit=pe nest8.kr -o nest8.exe`, then `add_unwind_x64.py nest8.exe nest8_uw.exe` — the "static RSP, no frame pointer" description the spec measured WRONG (§2.4: native cdb `+0x11a9 → RetAddr 0x10`, Wine livelock) | `63d79a27e1934e055aa5e74aad3f6bb66dbe91236b0e0e7650de17f3399ac094` |
| `nest8_uw.asm` | `nest8.kr` | **seed** `--arch=x86_64 --target=windows --emit=asm nest8.kr -o nest8_uw.asm` | `c80bfb9f04d7ed30e370e09d2845239a1ba303b7aa7fde3edab34c6019f78b3c` |
| `nest8_fp.exe` | `nest8.kr` | **proto** `--arch=x86_64 --target=windows --emit=pe nest8.kr -o nest8_fp0.exe`, then `add_unwind_x64.py nest8_fp0.exe nest8_fp.exe` — the frame-pointer prototype the spec measured CORRECT (§1.3: full cdb chain natively, rc 5 under Wine) | `96586ce376b76c0be58ac11a16cff1b3a0ecd48f9a0015650408a798bbf032b0` |
| `nest8_fp.asm` | `nest8.kr` | **proto** `--arch=x86_64 --target=windows --emit=asm nest8.kr -o nest8_fp.asm` | `5e67193ac22a845b71fea41d475b361c1f3e027038647545ef4f4523eae52327` |

The listings predate the `; uw-code-end` annotation, so a row that runs C2 or later
rules on these images passes the end of code with the checker's `--code-end`.

Reproduce: each image above was rebuilt from its compiler and compared byte for byte
before it was committed (the `*_fp.exe` and `nest8_uw.exe` are identical to the files
in the spec's evidence directory `~/.cache/pe_unwind/t/`).
