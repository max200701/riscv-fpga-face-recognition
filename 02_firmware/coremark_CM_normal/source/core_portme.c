/* Only this platform layer accesses the project-specific MMIO map. */
#include "coremark.h"
#include "core_portme.h"

#define MMIO32(address) (*(volatile ee_u32 *)(address))
#define TIMER_LOW_ADDR 0x10000300u

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#elif PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
volatile ee_s32 seed3_volatile = 0x66;
#else
volatile ee_s32 seed1_volatile = 8;
volatile ee_s32 seed2_volatile = 8;
volatile ee_s32 seed3_volatile = 8;
#endif

volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
ee_u32 default_num_contexts = 1;

ee_u32 measured_retired;
static ee_u32 start_retired;
extern void performance_report(void);
static CORETIMETYPE start_time_val;
static CORETIMETYPE stop_time_val;

static CORETIMETYPE pango_clock(void)
{
    return MMIO32(TIMER_LOW_ADDR);
}

__attribute__((noinline,noclone)) void start_time(void)
{
    start_time_val = pango_clock();
    __asm__ volatile("csrr %0,instret":"=r"(start_retired));
}

__attribute__((noinline,noclone)) void stop_time(void)
{
    stop_time_val = pango_clock();
    ee_u32 end_retired; __asm__ volatile("csrr %0,instret":"=r"(end_retired));
    measured_retired=end_retired-start_retired;
}

CORE_TICKS get_time(void)
{
    return (CORE_TICKS)(stop_time_val - start_time_val);
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    return (secs_ret)(ticks / (CORE_TICKS)COREMARK_CLOCK_HZ);
}

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *) || sizeof(ee_u32) != 4)
        MMIO32(0x10000000u) = 2;
    else
        MMIO32(0x10000000u) = 0;
    ee_printf("COREMARK START\r\n");
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    performance_report();
    coremark_output_end();
    p->portable_id = 0;
}
