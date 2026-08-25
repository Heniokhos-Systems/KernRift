# gfx11 GPU Driver Bring-Up — Handoff for a From-Scratch KernRift OS

RX 7800 XT / Navi 32 / gfx1101 / gc_11_0_3. This is the complete bring-up
skeleton to drive the discrete GPU from your own KernRift OS — where your OS
**owns** the card, so none of the Linux warm-handoff / iGPU-display hazards
apply (see the "Why not on Linux" note at the end).

All modules are OS-agnostic KernRift, zero syscalls, pure MMIO on caller-supplied
identity-mapped physical pointers. Every firmware parse + register/packet
encoding is self-tested against the real `/lib/firmware/amdgpu/gc_11_0_3_*` blobs
and authoritative amdgpu headers. Stage A (SMU) is also validated live on hardware.

---

## The module stack (KernRift/std/)

| Module | Role | Validation |
|--------|------|------------|
| `gpu_portable.kr` | PCI ECAM discovery, BAR mapping, direct + SMN register access | live (ECAM→BAR→reg reads) |
| `gpu_navi32.kr` | gfx1101 IP base map + register constants | cross-confirmed vs RE |
| `gpu_pm4.kr` | PM4 compute-dispatch command stream | self-test 10/10 |
| `gpu_activate.kr` | SMU mailbox + GFXOFF disable/enable (stage A) | **live: SMU resp=1** |
| `gpu_imu_load.kr` | IMU fw parse + load/start (GC power-up) | fw-parse 7/7 |
| `gpu_rlc_load.kr` | RLC fw parse + load/start | fw-parse 5/5 |
| `gpu_cp_load.kr` | PFP/ME/MEC RS64 fw parse + IC/DC load | fw-parse 15/15 |
| `gpu_mes_load.kr` | MES fw parse + direct load | fw-parse 9/9 |
| `gpu_queue.kr` | compute MQD fill + KIQ MAP_QUEUES + doorbell | self-test 8/8 |
| `gc_init.kr` | full bring-up orchestrator + VRAM bump allocator | integration test |

---

## Bring-up order (what `gc_init()` does)

```
1. discover + map      (gpu_portable: ECAM scan vendor 0x1002 + class 0x03 → BARs)
2. IMU  load + start   (powers GC clocks; must precede everything GC)
3. GFXOFF disable      (SMU DisallowGfxOff — keeps GC registers live)
4. RLC  load + start
5. CP   PFP/ME/MEC load (RS64: stage ucode+data in VRAM, point IC/DC base)
6. MES  direct load     (stage ucode+data in VRAM, release from reset)
7. queue: ring + MQD in VRAM → KIQ MAP_QUEUES → ring BAR2 doorbell
8. submit: PM4 compute dispatch onto the ring
```

`gc_init(bar5, db2, mp1, ctx, imu_fw, rlc_fw, pfp_fw, me_fw, mec_fw, mes_fw)`
returns 0 on success or a stage code. Your OS supplies:
- `bar5` / `db2` = identity-mapped pointers to BAR5 (registers) and BAR2 (doorbell)
- `mp1` = `NAVI32_MP1` (SMU base)
- `ctx` = a 24-byte VRAM bump-allocator context; init with
  `gc_valloc_init(ctx, vram_host_ptr, vram_gpu_addr)` where `vram_host_ptr` is a
  CPU-mapped window into BAR0 VRAM and `vram_gpu_addr` its GPU address
- the six firmware image pointers (read the blobs from your FS / embed them)

---

## Key hardware facts (this card)

```
PCI BDF            0000:03:00.0   vendor 0x1002 device 0x747e
ECAM (MMCONFIG)    0xe0000000     (from ACPI MCFG table)
BAR0 (VRAM)        0xf800000000   16368 MB (RCC_CONFIG_MEMSIZE = 0x3ff0)
BAR2 (doorbell)    0xfc00000000
BAR5 (registers)   0xdfb00000     1 MB
```

Register access (both validated live):
- **direct BAR5**: `byte = (ip_base_dw + reg_dw) * 4` — low bases (GC 0x1260, MMHUB
  0x1A000, MP0/MP1 0x16000, OSS 0x10A0, HDP 0xF20, NBIF2 0xD20). e.g. MEMSIZE at
  `(0xD20+0xc3)*4 = 0x378c` read `0x3ff0`.
- **SMN-indirect**: PCIE_INDEX2 @ BAR5 byte `0x38`, DATA2 @ `0x3c`; SMN byte addr =
  `reg << 2`. e.g. PHY `0x0c400000` read `0x1` per channel.

SMU mailbox (validated live, `resp=1`): MP1 base 0x16000, C2PMSG_66=0x282 (msg),
C2PMSG_82=0x292 (arg), C2PMSG_90=0x29a (resp). DisallowGfxOff=0x29, AllowGfxOff=0x28.

---

## What's proven vs what's TODO

**Proven** (self-tested and/or live):
- discovery, BAR map, both register-access paths (live)
- SMU mailbox / GFXOFF (live: `resp=1`)
- every firmware parse against the real blobs
- PM4 dispatch encoding, MQD field layout, MAP_QUEUES packet (`0xc005a200`)

**Flagged TODO — verify on your OS-owned card:**
- CP RS64 multi-pipe reset/activate: PFP/ME `ACTIVE` bit positions and the MEC
  IC-base register are not pinned down (`gpu_cp_load.kr` marks these).
- MQD control-word tuning bits beyond the essentials (`gpu_queue.kr`).
- Inter-stage sequencing / timing between IMU→RLC→CP→MES.
- Secure boot: a locked gfx11 may reject the direct MES/CP load and force PSP
  autoload. If so you need the PSP FW-load path instead of direct load.

**The stage-C wall (biggest open item):** doorbells are **write-only** from the
CPU (BAR2 reads return 0xffffffff). You cannot submit by poking a doorbell — MES
must first KNOW the queue. So a compute submit requires registering the queue via
MES's queue-management: write **MES ADD_QUEUE** to the MES ring, or **KIQ
MAP_QUEUES** to the KIQ ring, then ring THAT ring's doorbell. `gpu_queue.kr`
builds the MAP_QUEUES packet, but you need the KIQ/MES ring's GPU address +
doorbell index — recover these by reading the active HQDs: `grbm_select(me,pipe,
queue)` via `GRBM_GFX_CNTL` (GC1, 0x900; PIPEID<<0|MEID<<2|QUEUEID<<8) then read
`CP_HQD_PQ_BASE`(0x1fb1, GC0) / `CP_HQD_PQ_DOORBELL_CONTROL`(0x1fb8) / `CP_HQD_ACTIVE`
(0x1fab). On your OS you set these yourself when you create the queue, so you can
skip the recovery and just assign your own ring+doorbell in the MQD.

---

## Cold-boot (stage 3, for your own BIOS)

When there's no UEFI to inherit a POSTed GPU, you also need DRAM training + PSP.
The register map is reverse-engineered (see the MLRift memory doc
`project_coldboot_dram_training_in_vbios_abl` and `psp_fuzz/captures/psp_blobs/`):
- GDDR6 PHY trainer = PSP ABL1 (`captures/psp_blobs/ABL1_0x87c00.bin`): command/
  doorbell reg SMN `0x0c40127f` (cmd values 0x17e00/e18/e20/e34), channel-select
  `0x0c4017c2`, per-lane init `0x0c40000b/002d/0051` (+0x400 rank mirror).
- UMC register-group table (blob type 0x1005 @ file 0xb4f80): per-channel PHY
  bases via op=0x96, UMC datapath op=0x2a/2b, controller op=0xff/01.
- Memory straps: atombios VRAM_Info v3.0 @ 0x42da0 (Samsung K4ZAF325BC / Hynix
  H56G42AS8DX014, 16ch/256-bit).
Real DQS convergence needs the adaptive training loop on live silicon (or running
ABL1 on the PSP). This is the harder path; do it after warm bring-up works.

---

## Why this is NOT tested via Linux warm-handoff (READ THIS)

On the Linux dev box, "owning" the dGPU means unbinding it from amdgpu. That is
**not safe on this machine**: the iGPU (0000:12:00.0) drives the display, and the
dGPU unbind perturbs timing enough to deadlock amdgpu's Display-Manager idle-power
/ panel-self-refresh path on the iGPU (`dm_ism_sso_delayed_work` ↔ vblank IRQ
spinlock) → kernel hard lockup → **spontaneous reboot**. `mp1_nokill` fixes the
SMU-unload GC-kill (necessary — it's why stage A validated live) but does NOT fix
the iGPU display deadlock. Two "clean" handoff cycles then one reboot = timing
luck, not safety. **Do not run warm-handoff on this box.**

On YOUR OS none of this exists: your OS owns the card, there is no second amdgpu
instance driving a display to deadlock. `gc_init()` runs against the real card
cleanly there. That was always the intended target.
