OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
 ROM (rx) : ORIGIN = 0x00000000, LENGTH = 64K
 RAM (rw) : ORIGIN = 0x00010000, LENGTH = 64K
}
SECTIONS {
 .text : { KEEP(*(.text.init)) *(.text .text.*) *(.rodata .rodata.*) } > ROM
 .data : { *(.data .data.*) *(.sdata .sdata.*) } > RAM
 .bss (NOLOAD) : {
  . = ALIGN(4); __bss_start = .;
  *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON)
  . = ALIGN(4); __bss_end = .;
 } > RAM
 __stack_top = ORIGIN(RAM)+LENGTH(RAM);
 ASSERT(SIZEOF(.data)==0, "Self-starting test may not need an initialized RAM image")
 ASSERT(__bss_end <= __stack_top-4096, "Reserve stack")
 /DISCARD/ : { *(.comment) *(.eh_frame*) }
}
