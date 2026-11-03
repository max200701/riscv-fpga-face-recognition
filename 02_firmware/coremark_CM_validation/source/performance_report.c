#include "coremark.h"
extern ee_u32 measured_retired;
void performance_report(void){
 ee_printf("CPU PERF | CPU Hz: %u | Iterations: %u | ticks: %u | retired: %u\n",COREMARK_CLOCK_HZ,ITERATIONS,get_time(),measured_retired);
 ee_printf("CPU PERF WINDOW >=10s: %s\n",get_time()>=COREMARK_CLOCK_HZ*10u?"PASS":"SHORT");
}
