OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS { . = 0; .text : { *(.text*) } /DISCARD/ : { *(.riscv.attributes) *(.comment) } }
