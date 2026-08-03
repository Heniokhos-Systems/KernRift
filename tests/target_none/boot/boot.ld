ENTRY(_mbstart)
SECTIONS {
  . = 0x100000;
  .mbhdr : { *(.mbhdr) }
  .text : { *(.text) }
  .data : { *(.data) *(.rodata*) }
}
