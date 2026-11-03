#include <stdint.h>
#define REG(a) (*(volatile uint32_t *)(a))
#define D ((volatile uint32_t*)0x10010200u)
volatile uint32_t traps[6],error,loops,sink;
volatile uint32_t data[768] __attribute__((aligned(1024)));
extern uint32_t cache_reads(volatile uint32_t*);
extern uint32_t ic_a(uint32_t),ic_b(uint32_t),ic_c(uint32_t),branch_work(uint32_t);
static inline uint32_t cycle(void){uint32_t v;__asm__ volatile("rdcycle %0":"=r"(v));return v;}
void __attribute__((interrupt("machine"),aligned(4))) trap_handler(void){
 uint32_t c,p;__asm__ volatile("csrr %0,mcause":"=r"(c));__asm__ volatile("csrr %0,mepc":"=r"(p));
 if(c==11){traps[0]++;p+=4;__asm__ volatile("csrw mepc,%0"::"r"(p));}
 else if(c==2){traps[1]++;p+=4;__asm__ volatile("csrw mepc,%0"::"r"(p));}
 else if(c==0x80000003u){traps[2]++;REG(0x10000310)=0;}
 else if(c==0x80000007u){traps[3]++;REG(0x1000030c)=0xffffffffu;REG(0x10000308)=0xffffffffu;}
 else {error++;traps[4]=c;__asm__ volatile("csrwi mie,0");if(!(c>>31)){p+=4;__asm__ volatile("csrw mepc,%0"::"r"(p));}}
}
static void mark(uint32_t a,uint32_t b){D[1]=a;D[2]=b;D[3]=0;__asm__ volatile("fence iorw,iorw":::"memory");D[4]=0x201;}
int main(void){
 uint32_t test=D[9],begin=cycle(),gpioerr=0,timerdelta=0;
 data[0]=0x111;data[256]=0x222;data[512]=0x333;
 __asm__ volatile("csrw mtvec,%0"::"r"(trap_handler));
 if(test==2){__asm__ volatile("csrw mie,%0"::"r"(0x88));__asm__ volatile("csrsi mstatus,8");}
 do{
  if(test==1){uint32_t v=cache_reads(data);if(v!=0xccc)error++;sink=v;uint32_t x=ic_a(1);x=ic_b(x);x=ic_a(x);x=ic_b(x);x=ic_c(x);if(x!=10)error++;}
  else if(test==2){
   __asm__ volatile("ecall\n.word 0":::"memory");uint32_t n=traps[2];REG(0x10000310)=1;uint32_t t=cycle();while(traps[2]==n&&cycle()-t<100000u){}if(traps[2]!=n+1){error++;break;}
   n=traps[3];REG(0x1000030c)=0xffffffffu;REG(0x10000308)=REG(0x10000300)+256;REG(0x1000030c)=REG(0x10000304);t=cycle();while(traps[3]==n&&cycle()-t<100000u){}if(traps[3]!=n+1){error++;break;}
  }
  else if(test==3){sink=branch_work(64);if(sink!=32)error++;}
  else if(test==4){uint32_t v=loops&15;REG(0x10000200)=v;if(REG(0x10000200)!=v)gpioerr++;uint32_t a=REG(0x10000300),b=REG(0x10000300);timerdelta=b-a;if(!timerdelta)error++;REG(0x10000100)=0x55;REG(0x10000100)=0xaa;}
  else {error++;break;}
  loops++;
 }while(cycle()-begin<250000000u);
 uint32_t elapsed=cycle()-begin;__asm__ volatile("csrci mstatus,8\ncsrwi mie,0");REG(0x10000310)=0;REG(0x1000030c)=0xffffffffu;REG(0x10000308)=0xffffffffu;REG(0x10000200)=0;
 /* Existing application mode requires CMK1 transport and has_face bit zero.
    This is a directed diagnostic, never a CoreMark result. word2 is test ID. */
 uint32_t r[16]={0x314b4d43,1,test,(error+gpioerr)<<1,elapsed,loops,sink,traps[0],traps[1],traps[2],traps[3],traps[4],traps[5],gpioerr,timerdelta,1};
 for(unsigned i=0;i<16;i++)mark(0xa0000000u+i,r[i]);mark(0xfffffff7u,1);return 0;
}
