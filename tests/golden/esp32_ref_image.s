/* esp32_ref_image.s — source of the esp-image golden reference
 *
 * This tiny program exists ONLY as input to esptool's elf2image; the bytes
 * it assembles to are the segment payloads of tests/golden/esp32_ref_image.bin,
 * the oracle the esp32_image_format test compares src/format_espimage.kr
 * against byte-for-byte. It is never executed anywhere.
 *
 * Section sizes are deliberately NOT multiples of 4 (7 bytes each: the
 * assembler picks density encodings, so .text = movi.n(2) + nop.n(2) +
 * memw(3) = 7 bytes -> 2C A2 3D F0 C0 20 00) so the golden image exercises
 * esptool's zero-pad-to-4 of each segment payload — the padding rule
 * format_espimage.kr must reproduce exactly.
 *
 * Reproduce the golden (desktop has xtensa binutils; Pi has esptool v5.3.1):
 *
 *   xtensa-lx106-elf-as  -o /tmp/ref.o  tests/golden/esp32_ref_image.s
 *   xtensa-lx106-elf-ld  -e _start -Ttext=0x40080400 -Tdata=0x3FFB0000 \
 *                        -o /tmp/ref.elf /tmp/ref.o
 *   scp /tmp/ref.elf pantelis@192.168.2.5:/tmp/ref.elf
 *   ssh pantelis@192.168.2.5 'esptool --chip esp32 elf2image \
 *       --flash-mode dio --flash-freq 40m --flash-size 4MB \
 *       -o /tmp/ref.bin /tmp/ref.elf'
 *   scp pantelis@192.168.2.5:/tmp/ref.bin tests/golden/esp32_ref_image.bin
 *
 * The three flash flags are REQUIRED: esptool's defaults (QIO / 40m / 1MB)
 * would put 0x00/0x00 in header bytes 0x02-0x03 instead of the
 * hardware-confirmed 0x02 (DIO) / 0x20 (4MB @ 40MHz) this board needs.
 */

    .section .text
    .global _start
_start:
    movi    a2, 42          /* assembles as movi.n — 2 bytes */
    nop                     /* assembles as nop.n  — 2 bytes */
    memw                    /* 3 bytes; .text total = 7 bytes */

    .section .data
    .byte   0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77   /* 7 bytes */
