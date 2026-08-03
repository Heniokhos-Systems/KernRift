/* tests/target_none/boot/boot.S — x86_64 multiboot long-mode loader.
 *
 * WHAT / WHY: a QEMU x86 machine resets in 16-bit real mode and `-kernel`
 * rejects ELF64 ("Cannot load x86-64 image", observed at QEMU 8.2.2), so a
 * KernRift bare-metal image cannot be entered directly. This loader is
 * loaded by QEMU's multiboot path at 1 MiB, builds identity-mapped page
 * tables for the first 1 GiB, enables PAE + EFER.LME + paging, loads a
 * 64-bit GDT, prints its own liveness sentinel "KR-LDR|" to COM1, and
 * calls the KernRift image's entry (absolute VA baked in at assembly time
 * via --defsym KR_ENTRY_VA=...). The image itself is loaded separately
 * with `-device loader,file=...,addr=...,force-raw=on`.
 *
 * Every alternative was verified closed during review: PVH still enters
 * 32-bit protected mode, `-device loader` alone leaves real mode, the
 * gdbstub cannot write EFER. Sub-project D (UEFI) may replace this file;
 * until then it is owned by the boot gate and built by build_loader.sh.
 *
 * The sentinel is deliberately distinct from every program sentinel so a
 * failed leg attributes to loader vs image, and so the no-image control
 * can prove the harness was alive (a silent run proves nothing — review 2
 * observed leg 4 passing with no image loaded at all).
 */
.set MB_MAGIC, 0x1BADB002
.set MB_FLAGS, 0x0
.section .mbhdr, "a"
.align 4
.long MB_MAGIC
.long MB_FLAGS
.long -(MB_MAGIC + MB_FLAGS)

.section .text
.code32
.global _mbstart
_mbstart:
    cli
    /* zero page tables at 0x1000..0x4000 */
    mov $0x1000, %edi
    mov %edi, %cr3
    xor %eax, %eax
    mov $0xC00, %ecx
    rep stosl
    mov $0x1000, %edi
    movl $0x2003, (%edi)        /* PML4[0] -> 0x2000 */
    movl $0x3003, 0x1000(%edi)  /* PDPT[0] -> 0x3000 */
    mov $0x3000, %edi           /* PD: 512 x 2MiB identity = 1 GiB */
    mov $0x83, %eax             /* present|rw|PS */
    mov $512, %ecx
1:  mov %eax, (%edi)
    add $0x200000, %eax
    add $8, %edi
    loop 1b
    mov %cr4, %eax              /* PAE */
    or $(1<<5), %eax
    mov %eax, %cr4
    mov $0xC0000080, %ecx       /* EFER.LME */
    rdmsr
    or $(1<<8), %eax
    wrmsr
    mov %cr0, %eax              /* paging + PE */
    or $0x80000001, %eax
    mov %eax, %cr0
    lgdt gdtr
    ljmp $0x08, $long_mode
.code64
long_mode:
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov $0x00090000, %rsp
    /* liveness sentinel: 8N1 on COM1, then "KR-LDR|" */
    mov $0x3FB, %dx
    mov $0x03, %al
    outb %al, %dx
    mov $0x3F8, %dx
    lea ldr_msg(%rip), %rsi
1:  lodsb
    test %al, %al
    jz 2f
    outb %al, %dx
    jmp 1b
2:  movabs $KR_ENTRY_VA, %rax
    call *%rax
3:  hlt
    jmp 3b

ldr_msg: .asciz "KR-LDR|"

.align 16
gdt:
    .quad 0
    .quad 0x00AF9A000000FFFF   /* 64-bit code */
    .quad 0x00CF92000000FFFF   /* data */
gdtr:
    .word . - gdt - 1
    .long gdt
    .long 0
