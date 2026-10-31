/* CoreMark platform port: local CPU cycle counter and compact result transport.
 * Upstream core_main/list/matrix/state/util sources remain byte-identical. */
#include "coremark.h"
#include <stdint.h>
#include <stdarg.h>
#define DIAG ((volatile uint32_t*)0x10010200u)
volatile ee_s32 seed1_volatile,seed2_volatile,seed3_volatile;
volatile ee_s32 seed4_volatile,seed5_volatile;
ee_u32 default_num_contexts=1;
static uint64_t begin,end;
static uint32_t errors,seen,seedcrc,crclist,crcmatrix,crcstate,crcfinal,iterations;
static uint64_t cycles(void){
 uint32_t h,l,h2;do{__asm__ volatile("rdcycleh %0":"=r"(h));__asm__ volatile("rdcycle %0":"=r"(l));__asm__ volatile("rdcycleh %0":"=r"(h2));}while(h!=h2);
 return ((uint64_t)h<<32)|l;
}
void start_time(void){begin=cycles();}
void stop_time(void){end=cycles();}
CORE_TICKS get_time(void){return end-begin;}
secs_ret time_in_secs(CORE_TICKS t){return (secs_ret)(t/COREMARK_CLOCK_HZ);}
static int starts(const char*s,const char*p){while(*p)if(*s++!=*p++)return 0;return 1;}
static int contains(const char*s,const char*p){for(;*s;s++)if(starts(s,p))return 1;return 0;}
/* Preserve upstream validation and capture its actual reported values; no
 * UART traffic in the timed interval and no fabricated benchmark result. */
int ee_printf(const char*fmt,...){
 va_list a;va_start(a,fmt);
 if(starts(fmt,"Iterations       :")){iterations=va_arg(a,ee_u32);seen|=1;}
 else if(starts(fmt,"seedcrc")){seedcrc=(unsigned)va_arg(a,int);seen|=2;}
 else if(starts(fmt,"[%d]crclist")){(void)va_arg(a,int);crclist=(unsigned)va_arg(a,int);seen|=4;}
 else if(starts(fmt,"[%d]crcmatrix")){(void)va_arg(a,int);crcmatrix=(unsigned)va_arg(a,int);seen|=8;}
 else if(starts(fmt,"[%d]crcstate")){(void)va_arg(a,int);crcstate=(unsigned)va_arg(a,int);seen|=16;}
 else if(starts(fmt,"[%d]crcfinal")){(void)va_arg(a,int);crcfinal=(unsigned)va_arg(a,int);seen|=32;}
 if(contains(fmt,"ERROR!")&&!contains(fmt,"at least 10 secs"))errors++;
 if(starts(fmt,"Cannot validate")||contains(fmt,"too big")||contains(fmt,"ERROR: "))errors++;
 va_end(a);return 0;
}
void portable_init(core_portable*p,int*argc,char*argv[]){
 (void)argc;(void)argv;errors=seen=0;
 uint32_t mode=DIAG[8],n=DIAG[9];
 if(mode<1||mode>2||!n||n>10000||sizeof(ee_u32)!=4||sizeof(ee_ptr_int)!=sizeof(void*))errors++;
 seed1_volatile=seed2_volatile=mode==2?0x3415:0;
 seed3_volatile=0x66;seed4_volatile=n;seed5_volatile=0;p->portable_id=1;
}
static void marker(uint32_t a,uint32_t b){
 DIAG[1]=a;DIAG[2]=b;DIAG[3]=0;__asm__ volatile("fence iorw,iorw":::"memory");DIAG[4]=0x201;
}
void portable_fini(core_portable*p){
 uint32_t mode=DIAG[8];uint64_t t=get_time();
 if(seen!=63||iterations!=(uint32_t)seed4_volatile||!t)errors++;
 /* Independent check of all three official 2K CRCs, in addition to core_main. */
 if(seedcrc!=(mode==2?0x18f2u:0xe9f5u)||crclist!=(mode==2?0xe3c1u:0xe714u)||
    crcmatrix!=(mode==2?0x0747u:0x1fd7u)||crcstate!=(mode==2?0x8d84u:0x8e3au))errors++;
 uint32_t flags=(!errors?2u:0u)|(t>=10ull*COREMARK_CLOCK_HZ?4u:0u)|(mode==2?8u:0u);
 uint32_t result[16]={0x314b4d43u,1,0x26102601u,flags,COREMARK_CLOCK_HZ,iterations,
  (uint32_t)t,(uint32_t)(t>>32),seedcrc,crclist,crcmatrix,crcstate,crcfinal,TOTAL_DATA_SIZE,errors,1};
 for(unsigned i=0;i<16;i++)marker(0xa0000000u+i,result[i]);
 marker(0xfffffff7u,1);p->portable_id=0;
}
void coremark_output_end(void){}
