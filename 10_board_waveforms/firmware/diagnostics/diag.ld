OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x10000, LENGTH = 56K }
SECTIONS {
 .text : { KEEP(*(.text.init)) *(.text .text.*) *(.rodata .rodata.*) } > RAM
 .probe_a 0x12240 : { KEEP(*(.probe_a)) } > RAM
 .probe_b 0x13240 : { KEEP(*(.probe_b)) } > RAM
 .probe_c 0x14240 : { KEEP(*(.probe_c)) } > RAM
 .data : { *(.data .data.*) *(.sdata .sdata.*) } > RAM
 .bss (NOLOAD) : { . = ALIGN(1024); __bss_start = .; *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON) . = ALIGN(4); __bss_end = .; } > RAM
 __stack_top = 0x20000;
 ASSERT(__bss_end <= 0x1e000,"stack overlap")
 /DISCARD/ : { *(.comment) *(.eh_frame*) }
}