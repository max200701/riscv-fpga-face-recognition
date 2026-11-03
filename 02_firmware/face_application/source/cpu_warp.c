#include "cpu_warp.h"
#define WARP_IO ((volatile uint32_t*)0x10010800u)
/* Same CPU FIT terms and ownership API; execution uses the shared hardware channel. */
int cpu_warp112(const struct warp_io*io,const int32_t t[448],uint32_t source,uint32_t dest){
 if(!io||!t||!io->write_line||!io->owns||source!=0x01800000u||dest!=0x01c00000u)return -1;
 if(io->owns(io->context))return -2;
 for(unsigned i=0;i<448;i+=8)if(io->write_line(io->context,0x0b100000u+4*i,t+i))return -2;
 int32_t desc[32]={0x31505257,3,640,480,(int32_t)source,0x0b100000,(int32_t)dest,0,1};
 for(unsigned i=0;i<32;i+=8)if(io->write_line(io->context,0x0b100800u+4*i,desc+i))return -2;
 if(io->owns(io->context))return -2;
 unsigned count=0;while(!(WARP_IO[1]&1))if(++count>40000000u)return -2;
 WARP_IO[2]=0x0b100800u;WARP_IO[3]=128;WARP_IO[4]=0;
 __asm__ volatile("fence iorw,iorw":::"memory");WARP_IO[0]=3;
 count=0;while(!(WARP_IO[1]&2))if(++count>40000000u)return -2;
 uint32_t error=WARP_IO[5];WARP_IO[5]=1;
 if(error)return -3;return io->owns(io->context)?-2:0;
}
