.option norvc
.option norelax
.text
.global cache_reads,branch_work
cache_reads:
 .global cache_a0,cache_b0,cache_a_hit,cache_b_hit,cache_c,cache_a_reload,cache_b_reload
cache_a0: lw t0,0(a0)
cache_b0: lw t1,1024(a0)
cache_a_hit: lw t2,0(a0)
cache_b_hit: lw t3,1024(a0)
cache_c: addi a1,a0,1024
 lw t4,1024(a1)
cache_a_reload: lw t5,0(a0)
cache_b_reload: lw t6,1024(a0)
 add t0,t0,t1
 add t0,t0,t2
 add t0,t0,t3
 add t0,t0,t4
 add t0,t0,t5
 add a0,t0,t6
 ret
branch_work:
 li t0,0
1: andi t1,a0,1
 .global conditional_branch
conditional_branch: beq t1,zero,2f
 addi t0,t0,1
2: addi a0,a0,-1
 bne a0,zero,1b
 mv a0,t0
 ret
.section .probe_a,"ax"
.global ic_a
ic_a: addi a0,a0,1
 ret
.section .probe_b,"ax"
.global ic_b
ic_b: addi a0,a0,2
 ret
.section .probe_c,"ax"
.global ic_c
ic_c: addi a0,a0,3
 ret
