.option norvc
.option norelax
.section .text.init
.global _start
_start:
    la sp, __stack_top
    la t0, __bss_start
    la t1, __bss_end
1:  bgeu t0,t1,2f
    sw zero,0(t0)
    addi t0,t0,4
    j 1b
2:  call main
    # main returns 0 on success, otherwise a nonzero diagnostic value.
    beqz a0,3f
    addi a0,a0,1
    j 4f
3:  li a0,1
4:  li t0,0x10000000
    sw a0,0(t0)
5:  j 5b
