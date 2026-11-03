OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { APP (rwx) : ORIGIN = 0x10000, LENGTH = 60K }
SECTIONS {
 .text : { KEEP(*(.text.start)) *(.text*) *(.rodata*) . = ALIGN(4); } > APP
 .data : { __global_pointer$ = . + 0x800; *(.sdata*) *(.data*) . = ALIGN(4); } > APP
 .bss (NOLOAD) : { __bss_start = .; *(.sbss*) *(.bss*) *(COMMON) . = ALIGN(4); __bss_end = .; } > APP
 __stack_top = 0x1f000;
 ASSERT(__bss_end <= __stack_top - 8192, "Application needs 8KiB stack reserve")
 /DISCARD/ : { *(.comment) *(.eh_frame*) }
}
