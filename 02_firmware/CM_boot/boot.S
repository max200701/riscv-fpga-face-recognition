 .section .text,"ax"
 .globl _start
_start:
 li sp,0x1f000
 li s7,0
banner:
 li a0,67
 jal ra,putc
 li a0,68
 jal ra,putc
 li a0,76
 jal ra,putc
 li a0,49
 jal ra,putc
 li a0,10
 jal ra,putc
menu:
 jal ra,getc
 li t3,73
 beq a0,t3,banner
 li t3,76
 beq a0,t3,load
 li t3,71
 bne a0,t3,menu
 beqz s7,err
 li sp,0x1f000
 li t3,0x10000
 fence.i
 jalr ra,t3,0
 j banner
load:
 li s7,0
 li s0,0
 li s1,0
len_loop:
 jal ra,getc
 sll t3,a0,s1
 or s0,s0,t3
 addi s1,s1,8
 li t3,32
 bne s1,t3,len_loop
 beqz s0,err
 li t3,0xd000
 bgtu s0,t3,err
 li a0,82
 jal ra,putc
 li s1,0x10000
 li s2,0x811c9dc5
 li s3,0x01000193
bytes:
 jal ra,getc
 sb a0,0(s1)
 lbu t3,0(s1)
 bne a0,t3,err
 xor s2,s2,t3
 mul s2,s2,s3
 addi s1,s1,1
 addi s0,s0,-1
 bnez s0,bytes
 li s0,4
hash_loop:
 andi a0,s2,255
 jal ra,putc
 srli s2,s2,8
 addi s0,s0,-1
 bnez s0,hash_loop
 li s7,1
 j menu
err:
 li a0,69
 jal ra,putc
 j menu
getc:
 li t0,0x1000010c
1: lw t1,0(t0)
 andi t1,t1,1
 beqz t1,1b
 lw a0,-4(t0)
 ret
putc:
 li t0,0x10000104
2: lw t1,0(t0)
 andi t1,t1,1
 bnez t1,2b
 sw a0,-4(t0)
 ret
