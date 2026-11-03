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

/* Command6 fills at most512B. Read-only local bank remains reserved until POP.
   No repeated DDR request/response mailbox for each 32B. */
static int bulk_words(uint32_t addr, unsigned words, uint32_t *out) {
    if(!words||words>128||(words&7)||(addr&31))return 12;
    uint32_t n=0;while(!(IO[1]&1))if(++n>40000000u)return 10;
    IO[2]=addr;IO[3]=words*4;IO[4]=0;
    __asm__ volatile("fence iorw,iorw" ::: "memory");IO[0]=6;
    n=0;while(!(IO[1]&2))if(++n>40000000u)return 10;
    uint32_t error=IO[5];
    if(!error) {
        volatile uint32_t *bank=(volatile uint32_t *)0x10010a00u;
        for(unsigned i=0;i<words;i++)out[i]=bank[i];
    }
    __asm__ volatile("fence iorw,iorw" ::: "memory");IO[5]=1;
    return error?11:0;
}
