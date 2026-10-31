// Fixed-model release memory operations. Graph interpretation is build-time.
// Full package/program/assets CRCs still cover every deployed byte on cold load.
#include "package_fixture.h"
#include "retina_post.h"
#define IO ((volatile uint32_t *)0x10010800u)
static uint32_t line[8],published;
static struct {struct retina_workspace post;} scratch;
static int transaction(uint32_t addr,uint32_t bytes,uint32_t expected,uint32_t crc) {
    uint32_t n=0;
    while(!(IO[1]&1))if(++n>40000000u)return 10;
    IO[2]=addr;IO[3]=bytes;IO[4]=expected;
    __asm__ volatile("fence iorw,iorw" ::: "memory");IO[0]=crc;
    n=0;while(!(IO[1]&2))if(++n>40000000u)return 10;
    uint32_t error=IO[5];
    if(crc!=1)for(uint32_t i=0;i<8;i++)line[i]=IO[8+i];
    IO[5]=1;return error?11:0;
}
static const uint32_t whole_package_crc[2]={1275924772u,1703788225u};
