/* Executed from face ROM. Locals remain in the upper 8 KiB of CPU RAM while
 * the lower RAM is overwritten. No face global is used after the copy starts. */
#include <stdint.h>
#define IO ((volatile uint32_t*)0x10010800u)
#define STAGING 0x0c000000u
static int read_line(uint32_t address,uint32_t out[8]){
 uint32_t n=0;
 while(!(IO[1]&1))if(++n>4000000u)return 701;
 IO[2]=address;IO[3]=32;IO[4]=0;
 __asm__ volatile("fence iorw,iorw":::"memory");IO[0]=0;
 n=0;while(!(IO[1]&2))if(++n>4000000u)return 702;
 uint32_t error=IO[5];
 if(!error)for(unsigned i=0;i<8;i++)out[i]=IO[8+i];
 IO[5]=1;return error?703:0;
}
static uint32_t crc_byte(uint32_t c,uint8_t b){
 c^=b;for(unsigned j=0;j<8;j++)c=(c>>1)^((0u-(c&1))&0xedb88320u);return c;
}
int coremark_load(void){
 uint32_t h[8],v[8];int e=read_line(STAGING,h);if(e)return e;
 uint32_t hc=~0u;for(unsigned i=0;i<28;i++)hc=crc_byte(hc,((uint8_t*)h)[i]);
 if(h[0]!=0x31494d43u||h[1]!=1||h[2]!=0x10000u||h[3]==0||h[3]>0xe000u||
    (h[3]&3)||h[4]<h[2]||h[4]>=h[2]+h[3]||(h[4]&3)||
    h[5]<h[2]+h[3]||h[5]>0x1e000u||~hc!=h[7])return 704;
 uint32_t c=~0u;
 for(uint32_t offset=0;offset<h[3];offset+=32){
  e=read_line(STAGING+32+offset,v);if(e)return e;
  unsigned bytes=h[3]-offset;if(bytes>32)bytes=32;
  for(unsigned i=0;i<bytes;i++)c=crc_byte(c,((uint8_t*)v)[i]);
  for(unsigned i=0;i<bytes/4;i++)((volatile uint32_t*)(h[2]+offset))[i]=v[i];
 }
 if(~c!=h[6])return 705;
 /* Separate instruction cache may contain a previous RAM benchmark. */
 __asm__ volatile("fence rw,rw\n\tfence.i":::"memory");
 ((void(*)(void))h[4])();
 return 706; /* The benchmark start stub must complete via the status/COMMIT ABI. */
}
