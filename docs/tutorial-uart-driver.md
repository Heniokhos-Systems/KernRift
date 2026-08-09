# Tutorial — Freestanding UART driver with IRQ handling

This tutorial builds a small, fully freestanding serial driver in KernRift.
It walks through:

1. What `--freestanding` gives you (and what it takes away).
2. Mapping a device's register layout with a `device` block.
3. Writing a polling TX path and a polling RX path.
4. Installing an ARMv8 exception vector.
5. Handling the UART RX interrupt with a lock-free ring buffer.
6. Validating the whole thing under QEMU.

Target: **QEMU `-machine virt -cpu cortex-a72`**, which emulates a PL011
UART at `0x0900_0000`. The same code runs on a real Raspberry Pi 4 (UART0 at
`0xFE20_1000`) if you change the base address.

The source files in this tutorial live under `examples/tutorial-uart/`:

```
examples/tutorial-uart/
├── Makefile
├── boot.s           # 32-byte trampoline that sets up SP and calls kmain
├── link.ld
├── vectors.s        # 2 KiB exception vector (ARMv8 VBAR_EL1)
├── uart.kr          # the driver — the interesting file
└── main.kr          # kmain — installs the ISR, then echoes forever
```

If you're on aarch64 Linux with `qemu-system-aarch64` installed:

```
cd examples/tutorial-uart
make run
```

This tutorial tells you why each piece exists. If you just want working
code, the example directory has the finished version.

---

## 1. What `--freestanding` does

Normal KernRift programs start at the runtime's `_start`, which sets up
argv/envp, calls `main`, then invokes `exit`. Freestanding programs have
none of that:

- No stdin/stdout/stderr. Syscalls are meaningless — there's no kernel.
- No `exit()`. Falling off `main` returns to whatever called you (usually
  a reset vector or hang loop).
- No `alloc()`. No dynamic memory unless you bring your own allocator.
- No stack. You set one up in a tiny assembly trampoline.

The compiler flag:

```
krc --freestanding --arch=arm64 main.kr -o kernel.elf
```

produces a flat binary with only the code you wrote plus stdlib functions
you actually called. No `_start`, no CRT, no syscall numbers.

You're responsible for:

- A linker script that places text at the right load address.
- A boot trampoline that sets SP and jumps to your entry point.
- Exception vectors.
- Every hardware register you poke.

---

## 2. Modeling the PL011 UART

The ARM PL011 (see the TRM, section 3.2) exposes these registers:

```
Offset  Name    Width   Access   Description
0x000   DR      32      rw       Data register (read = RX byte, write = TX byte)
0x018   FR      32      ro       Flag register (TXFF, RXFE, busy bits)
0x024   IBRD    32      rw       Integer baud rate divisor
0x028   FBRD    32      rw       Fractional baud rate divisor
0x02C   LCR_H   32      rw       Line control (word length, FIFOs)
0x030   CR      32      rw       Control (UART enable, TX enable, RX enable)
0x038   IMSC    32      rw       Interrupt mask
0x044   MIS     32      ro       Masked interrupt status
0x044   ICR     32      wo       Interrupt clear (write 1 to clear; same offset, different semantics)
```

In KernRift, a `device` block captures this:

```kernrift
device PL011 at 0x09000000 {
    DR    at 0x000 : u32
    FR    at 0x018 : u32 ro
    IBRD  at 0x024 : u32
    FBRD  at 0x028 : u32
    LCR_H at 0x02C : u32
    CR    at 0x030 : u32
    IMSC  at 0x038 : u32
    MIS   at 0x044 : u32 ro
    ICR   at 0x044 : u32 wo
}
```

Every access to `PL011.DR` compiles to a `vloadN` / `vstoreN` — the
volatile load/store ops. The optimizer never reorders them, never fuses
them with neighbors, never DCEs them even if the read's result is unused.
That's the invariant you need for MMIO.

The `rw`, `ro`, `wo` specifiers are informational today — the compiler
accepts all three and does not prevent writes to `ro` fields. Treat them
as documentation.

---

## 3. Polling TX and RX

The FR register has two bits we care about:

- Bit 5 (TXFF) — TX FIFO full. If set, don't write DR.
- Bit 4 (RXFE) — RX FIFO empty. If set, don't read DR.

A polling TX loop:

```kernrift
fn uart_putc(u8 c) {
    // Spin while TXFF (bit 5) is set.
    while (PL011.FR & 0x20) != 0 {
        // busy wait
    }
    PL011.DR = c
}

fn uart_puts(u64 s) {
    u64 p = s
    while 1 == 1 {
        u8 ch = 0
        unsafe { *(p as uint8) -> ch }
        if ch == 0 { return }
        uart_putc(ch)
        p = p + 1
    }
}
```

And a non-blocking RX that returns `0xFFFFFFFFFFFFFFFF` when the FIFO is
empty (the Pattern-1 "no value" sentinel from `docs/ERROR_HANDLING.md`):

```kernrift
fn uart_try_getc() -> u64 {
    if (PL011.FR & 0x10) != 0 {
        return 0xFFFFFFFFFFFFFFFF
    }
    u32 b = PL011.DR
    return b & 0xFF
}
```

A blocking version on top:

```kernrift
fn uart_getc() -> u8 {
    u64 b = 0xFFFFFFFFFFFFFFFF
    while b == 0xFFFFFFFFFFFFFFFF {
        b = uart_try_getc()
    }
    return b
}
```

At this point you can already echo characters in a polling loop. The
next sections make it interrupt-driven.

---

## 4. The ARMv8 exception vector

ARMv8 has 16 exception entries, each 128 bytes apart, grouped into four
tables of four entries:

```
VBAR + 0x000   Sync  from current EL with SP_EL0
VBAR + 0x080   IRQ   from current EL with SP_EL0
VBAR + 0x100   FIQ   from current EL with SP_EL0
VBAR + 0x180   SError from current EL with SP_EL0
VBAR + 0x200   Sync  from current EL with SP_ELx
VBAR + 0x280   IRQ   from current EL with SP_ELx   ← the one we care about
...
```

`vectors.s` fills only the IRQ slot at `VBAR + 0x280`; everything else
is a trap loop for easier debugging.

```asm
.align 11                     // 2 KiB alignment required by the spec
.global vectors_el1
vectors_el1:
    .rept 5                   // entries 0..4 all trap
        b  trap_handler
        .align 7
    .endr
    b  irq_handler            // entry 5: IRQ from current EL, SP_ELx
    .align 7
    .rept 10
        b  trap_handler
        .align 7
    .endr

trap_handler:
1:  wfi
    b   1b

irq_handler:
    stp  x0,  x1,  [sp, #-16]!
    stp  x2,  x3,  [sp, #-16]!
    ...                         // save X0..X18, LR
    bl   kr_irq_handler          // call into KernRift
    ...                         // restore
    eret
```

In `kmain`, install the vector:

```kernrift
fn install_vectors(u64 vbar_addr) {
    asm("msr VBAR_EL1, x0") in(vbar_addr -> x0)
    asm("isb")                // make the write visible before IRQs
}
```

`isb()` (the v2.8.14 builtin) also works, and is clearer. For
cache-maintenance (e.g. after DMA or when writing new code into
RAM), use `dcache_flush(addr)` and `icache_invalidate(addr)` — both
emit the ARM64 `DC CIVAC` / `IC IVAU` instructions plus the required
`DSB ISH` + `ISB` fences, and are no-ops on x86 where the hardware
keeps I- and D-cache coherent.

---

## 5. The RX ring buffer

The ISR runs asynchronously and produces bytes; `main` consumes them.
We need a lock-free ring buffer indexed by atomic 64-bit counters.

```kernrift
static u8[256]  rx_buf
static u64      rx_head_off   // index of next byte to read
static u64      rx_tail_off   // index where next byte will be written

fn ring_push(u8 b) -> u64 {
    u64 tail = atomic_load(&rx_tail_off)
    u64 head = atomic_load(&rx_head_off)
    u64 next = (tail + 1) & 0xFF
    if next == (head & 0xFF) {
        return 0                  // full — drop the byte
    }
    u64 p = &rx_buf[0] + (tail & 0xFF)
    unsafe { *(p as uint8) = b }
    atomic_store(&rx_tail_off, tail + 1)
    return 1
}

fn ring_pop() -> u64 {
    u64 head = atomic_load(&rx_head_off)
    u64 tail = atomic_load(&rx_tail_off)
    if head == tail {
        return 0xFFFFFFFFFFFFFFFF  // empty — Pattern-1 "none"
    }
    u64 p = &rx_buf[0] + (head & 0xFF)
    u8 b = 0
    unsafe { *(p as uint8) -> b }
    atomic_store(&rx_head_off, head + 1)
    return b
}
```

The SPSC (single-producer, single-consumer) invariant is what makes this
correct: only the ISR writes to `rx_tail_off` and only `main` writes to
`rx_head_off`. Both sides only *read* the other's counter.

`atomic_load` / `atomic_store` give sequential consistency on both x86
and ARMv8. On ARM, that lowers to `LDAR` / `STLR`, which issue the right
barriers. You do not need explicit `dmb` here.

---

## 6. The ISR

```kernrift
@export
fn kr_irq_handler() {
    // Check the UART masked interrupt status. Bit 4 = RXMIS.
    u32 mis = PL011.MIS
    if (mis & 0x10) != 0 {
        // Drain the FIFO while RX not empty.
        while (PL011.FR & 0x10) == 0 {
            u32 ch = PL011.DR
            ring_push(ch & 0xFF)
        }
        // Clear the RX interrupt.
        PL011.ICR = 0x10
    }
    // Also handle TX, errors, etc — omitted for brevity.
}
```

Three things to notice:

1. The function is `@export` so the assembly trampoline can call it by
   name.
2. Every access to `PL011.*` is volatile — the optimizer can't merge
   the two loop iterations of `PL011.DR`.
3. The ICR write at the end is what dismisses the interrupt. Forgetting
   it is the classic "my ISR runs in a tight loop" bug.

---

## 7. Putting it together

`main.kr`:

```kernrift
import "uart.kr"

fn uart_init() {
    // Disable before re-config.
    PL011.CR = 0
    // 115200 baud from UARTCLK = 24 MHz:
    //   divisor = 24e6 / (16 * 115200) = 13.02
    PL011.IBRD = 13
    PL011.FBRD = 1
    // 8N1, enable FIFOs.
    PL011.LCR_H = 0x70
    // Enable RX interrupt only.
    PL011.IMSC = 0x10
    // UART + RX + TX enable.
    PL011.CR = 0x301
}

fn main() {
    // Extern 'vectors_el1' is defined in vectors.s
    u64 vbar = 0                    // filled by the linker / asm symbol
    asm("adrp x0, vectors_el1; add x0, x0, :lo12:vectors_el1") out(x0 -> vbar)
    install_vectors(vbar)

    uart_init()

    // Unmask IRQs (DAIF.I = 0).
    asm("msr DAIFClr, #0xF")

    uart_puts("kr-uart echo ready\n\0")

    while 1 == 1 {
        u64 b = ring_pop()
        if b != 0xFFFFFFFFFFFFFFFF {
            uart_putc(b)
        } else {
            asm("wfi")              // sleep until next IRQ
        }
    }
}
```

---

## 8. Running it

```
make run
```

runs:

```
qemu-system-aarch64 -machine virt -cpu cortex-a72 -nographic \
    -kernel kernel.elf
```

Anything you type appears back, one character at a time, echoed by the
ISR → ring buffer → main-loop pipeline. `Ctrl-A, x` exits QEMU.

You can verify the ISR actually fires by replacing the echo with a
counter printed every `N` bytes — a plain polling driver would miss
bytes if you hold a key down, the interrupt-driven one won't.

---

## Caveats

- **GIC not configured.** On the `virt` machine, the UART IRQ is wired
  as SPI 1. A complete driver would program the GICD / GICR to route it
  to CPU 0. QEMU's `virt` machine is lenient enough that masking it in
  the UART's IMSC and unmasking DAIF.I is enough to receive the IRQ
  *if* you're running at EL1 with no GIC in between. On real hardware
  you need GIC programming — see `docs/roadmap-next.md` for an
  "examples/gic-setup" placeholder.
- **Two UART FIFO levels.** If you're echoing at >1 MBaud, the 32-byte
  FIFO can overflow between ISRs. Set `LCR_H.FEN = 1` (we do) and enable
  the level-triggered FIFO watermark interrupt (IMSC bit 6) instead of
  the single-byte RX interrupt.
- **Baud rate assumes UARTCLK = 24 MHz.** On Raspberry Pi 4 the UARTCLK
  is 48 MHz (configurable via `core_freq` in `config.txt`).
- **No exit path.** `exit(0)` doesn't work in freestanding mode. Hit
  QEMU's monitor or halt the CPU with `wfi` in a tight loop.

---

## Further reading

- ARM PL011 Technical Reference Manual, r2p0.
- ARMv8-A Architecture Reference Manual, sections on VBAR_EL1 / DAIF.
- `docs/ERROR_HANDLING.md` for the sentinel / out-param patterns used
  above.
- `docs/IR_REFERENCE.md` — opcodes `vloadN` / `vstoreN` and their
  barrier semantics.
