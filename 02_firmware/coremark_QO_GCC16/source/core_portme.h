/* CoreMark v1.0 port for the project RV32I SoC. */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <stddef.h>

#define HAS_FLOAT 0
#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 0
#define HAS_PRINTF 0

#define COMPILER_VERSION "GCC " __VERSION__
#ifndef FLAGS_STR
#define FLAGS_STR "-O2 -march=rv32i -mabi=ilp32"
#endif
#define COMPILER_FLAGS FLAGS_STR
#define MEM_LOCATION "Code/const ROM, data/stack on-chip RAM, memory:core 1:1"

typedef signed short ee_s16;
typedef unsigned short ee_u16;
typedef signed int ee_s32;
typedef unsigned int ee_u32;
typedef unsigned char ee_u8;
typedef ee_u32 ee_ptr_int;
typedef size_t ee_size_t;
typedef unsigned long long CORE_TICKS;
#define CORETIMETYPE unsigned long long

#ifndef NULL
#define NULL ((void *)0)
#endif
#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x) - 1) & ~3))

#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD MEM_STATIC
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK 0
#define USE_SOCKET 0
#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0

#ifndef COREMARK_CLOCK_HZ
#define COREMARK_CLOCK_HZ 31250000u
#endif

#ifndef COREMARK_UART_GAP_TICKS
#define COREMARK_UART_GAP_TICKS 540000u /* 20 ms at board clock 27 MHz */
#endif

extern ee_u32 default_num_contexts;
typedef struct CORE_PORTABLE_S {
    ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);
int ee_printf(const char *fmt, ...);
void coremark_output_end(void);

#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#if (TOTAL_DATA_SIZE == 1200)
#define PROFILE_RUN 1
#elif (TOTAL_DATA_SIZE == 2000)
#define PERFORMANCE_RUN 1
#else
#define VALIDATION_RUN 1
#endif
#endif

#endif
