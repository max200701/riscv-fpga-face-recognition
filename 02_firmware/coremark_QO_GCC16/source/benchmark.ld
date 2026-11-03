OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x00010000, LENGTH = 56K }
SECTIONS {
 .text : { KEEP(*(.text.init)) *(.text .text.*) *(.rodata .rodata.*) } > RAM
 .data : { *(.data .data.*) *(.sdata .sdata.*) } > RAM
 .bss (NOLOAD) : { . = ALIGN(4); __bss_start = .; *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON) . = ALIGN(4); __bss_end = .; } > RAM
 __stack_top = 0x00020000;
 ASSERT(__bss_end <= 0x0001e000, "Keep independent 8KiB stack above loaded image")
 /DISCARD/ : { *(.comment) *(.eh_frame*) }
}
