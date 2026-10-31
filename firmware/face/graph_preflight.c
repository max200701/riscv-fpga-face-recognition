/* Fixed-model preflight of the actual DDR-resident SNPUPKG1 bytes.
 * Metadata is decoded by the unchanged RV32IM CPU; bulk CRC uses DMA hardware.
 * No NPU job is visible before all checks pass. The caller must keep the
 * package read-only/exclusive between preflight and later graph execution.
 * The frozen CRC manifest is accidental-corruption integrity, not security.
 */
#include <stdint.h>
#include "package_fixture.h"
#define IO ((volatile uint32_t *)0x10010800u)
#define U 0xffffffffu
static uint32_t line[8],line_address,line_valid,io_error;
#include "retina_post.h"
static uint32_t header[64],section[7][6];
static union {uint32_t tensors[600][16];struct retina_workspace post;} scratch;
#define tensor (scratch.tensors)
volatile uint32_t package_metrics[12],published,phase;

static int transaction(uint32_t addr,uint32_t bytes,uint32_t expected,uint32_t crc) {
    uint32_t n=0;
    while(!(IO[1]&1))if(++n>40000000u)return 10;
    IO[2]=addr;IO[3]=bytes;IO[4]=expected;
    __asm__ volatile("fence iorw,iorw" ::: "memory");IO[0]=crc;
    n=0;while(!(IO[1]&2))if(++n>40000000u)return 10;
    uint32_t error=IO[5];
    if(crc!=1)for(uint32_t i=0;i<8;i++)line[i]=IO[8+i];
    else package_metrics[7]++;
    IO[5]=1;return error?11:0;
}
static uint32_t word(uint32_t offset) {
    uint32_t a=PACKAGE_BASE+offset,base=a&~31u;
    if(!line_valid||base!=line_address) {
        if(transaction(base,32,0,0))io_error=1;
        line_address=base;line_valid=1;package_metrics[6]++;
    }
    return line[(a>>2)&7];
}
static int bounds(uint32_t off,uint32_t size,uint32_t cap,uint32_t align) {
    return (off&(align-1))==0&&size<=cap&&off<=cap-size;
}
static int product(uint32_t a,uint32_t b,uint32_t *out) {
    if(a&&b>0x3fffffffu/a)return 0;
    *out=a*b;return 1;
}
static uint32_t crc_header(void) {
    uint32_t c=U;
    for(uint32_t i=0;i<256;i++) {
        uint32_t b=(i>=56&&i<60)?0:(header[i>>2]>>((i&3)*8))&255;
        c^=b;for(uint32_t j=0;j<8;j++)c=(c>>1)^((c&1)?0xedb88320u:0);
    }
    return ~c;
}
/* Exact floor(2^56 / scale), with 2^24 < scale < 2^40. Do not link the
 * toolchain's default RV32IMAC libgcc into an RV32IM-only application.
 */
static uint32_t reciprocal(uint64_t scale) {
    uint64_t remainder=0;uint32_t quotient=0;
    for(int32_t bit=56;bit>=0;bit--) {
        remainder=(remainder<<1)|(bit==56);
        if(remainder>=scale) {
            remainder-=scale;
            if(bit>=32)return 0;
            quotient|=1u<<bit;
        }
    }
    return quotient;
}
static int decode(void) {
    phase=1;
    for(uint32_t i=0;i<64;i++)header[i]=word(i*4);
    if(io_error)return 11;
    if(header[0]!=0x55504e53u||header[1]!=0x31474b50u||header[2]!=1||header[3]!=0x01020304u||
       header[4]!=PACKAGE_BYTES||header[6]!=6||header[8]!=1||header[9]!=1||header[15]!=0||header[7]>=0x40000000u||
       header[12]>512||header[13]>600||!header[12]||!header[13]||crc_header()!=header[14])return 1;
    for(uint32_t i=0;i<6;i++) {
        const uint32_t *s=header+16+i*6;uint32_t sid=s[0],size;
        if(sid==0||sid>6||section[sid][0]||!s[4]||!product(s[3],s[4],&size)||size!=s[2]||
           s[1]<256||!bounds(s[1],s[2],header[4],64))return 2;
        uint32_t stride=sid==1?64:sid==2?160:sid==5?4:1;
        if(s[4]!=stride)return 2;
        for(uint32_t j=1;j<7;j++)if(section[j][0]&&s[1]<section[j][1]+section[j][2]&&section[j][1]<s[1]+s[2])return 2;
        for(uint32_t j=0;j<6;j++)section[sid][j]=s[j];
    }
    if(section[1][3]!=header[13]||section[2][3]!=header[12]||section[5][3]!=8193||
       header[10]>=header[13]||header[11]>=header[13])return 2;
    phase=2;
    for(uint32_t i=0;i<header[13];i++) {
        uint32_t *t=tensor[i],size;
        for(uint32_t j=0;j<16;j++)t[j]=word(section[1][1]+i*64+j*4);
        if(t[0]!=i||(t[1]&~7u)||t[2]<1||t[2]>2||t[3]>8)return 3;
        size=t[2]==1?4:8;
        for(uint32_t j=0;j<t[3];j++)if(!t[8+j]||!product(size,t[8+j],&size))return 3;
        if(size!=t[4]||!bounds(t[5],size,(t[1]&1)?section[4][2]:header[7],64))return 3;
        if((int32_t)t[6]<-1||(int32_t)t[6]>=(int32_t)header[12]||(int32_t)t[7]<(int32_t)t[6]||(int32_t)t[7]>(int32_t)header[12])return 3;
        if((t[1]&3)&&t[6]!=U)return 3;
        if(!(t[1]&3)&&t[6]==U)return 3;
    }
    if(!(tensor[header[10]][1]&2)||!(tensor[header[11]][1]&4))return 3;
    phase=3;
    for(uint32_t i=0;i<header[13];i++)if(!(tensor[i][1]&1)) {
        const uint32_t *a=tensor[i];
        for(uint32_t j=i+1;j<header[13];j++)if(!(tensor[j][1]&1)) {
            const uint32_t *b=tensor[j];
            int live=(int32_t)a[6]<=(int32_t)b[7]&&(int32_t)b[6]<=(int32_t)a[7];
            if(live&&a[5]<b[5]+b[4]&&b[5]<a[5]+a[4])return 4;
        }
    }
    phase=4;uint32_t macs=0,digest=2166136261u;
    for(uint32_t i=0;i<header[12];i++) {
        uint32_t op[40];
        for(uint32_t j=0;j<40;j++) {op[j]=word(section[2][1]+i*160+j*4);digest=(digest^op[j])*16777619u;}
        if(!op[0]||op[0]>16||op[1]!=i||op[2]>=header[13]||!op[3]||op[3]>16||op[22]||op[23]||
           !bounds(op[20],op[21],section[3][2],64)||tensor[op[2]][6]!=i)return 5;
        for(uint32_t j=0;j<16;j++) {
            uint32_t id=op[4+j];if(j>=op[3]){if(id!=U)return 5;continue;}
            if(id==U)continue;
            if(id>=header[13]||(int32_t)tensor[id][6]>=(int32_t)i||(int32_t)tensor[id][7]<(int32_t)i)return 5;
        }
        if(op[0]<=2) {
            uint32_t p[32],size=1;macs++;
            if(op[21]!=128||op[3]!=1||op[4]==U)return 6;
            for(uint32_t j=0;j<32;j++)p[j]=word(section[3][1]+op[20]+4*j);
            uint64_t scale=((uint64_t)p[1]<<32)|p[0];
            if(scale<=0x1000000u||scale>=(1ull<<40)||!p[2]||p[2]!=reciprocal(scale)||
               (p[4]!=8&&p[4]!=12)||(int32_t)p[3]<-(1<<(p[4]-1))||(int32_t)p[3]>=(1<<(p[4]-1))||
               !p[5]||!p[6]||!p[7]||p[7]>p[5]||p[5]%p[7]||p[13]>=0x80000000u||(p[14]!=2&&p[14]!=4)||p[15])return 6;
            for(uint32_t j=0;j<p[14];j++)if(!p[16+j]||!product(size,p[16+j],&size))return 6;
            if(size!=p[9]||p[16]!=p[5]||p[9]/p[5]!=p[6]||!bounds(p[8],p[9],section[4][2],64))return 6;
            if(!product(p[5],4,&size))return 6;
            for(uint32_t j=10;j<=12;j++)if(!bounds(p[j],size,section[4][2],64))return 6;
            const uint32_t *input=tensor[op[4]],*output=tensor[op[2]];
            if(input[9]%p[7]||output[9]!=p[5])return 6;
            if(op[0]==1&&(p[14]!=4||input[3]!=4||output[3]!=4||op[24]!=p[7]||!op[25]||!op[26]||op[31]!=1||op[32]!=1))return 6;
            if(op[0]==2&&(p[14]!=2||input[3]!=2||output[3]!=2||op[24]!=0||op[25]!=1))return 6;
        } else if(op[0]==9) {
            uint32_t p[4],size;
            if(op[21]!=64)return 6;
            for(uint32_t j=0;j<4;j++)p[j]=word(section[3][1]+op[20]+4*j);
            if(p[3]!=24||!p[0]||!product(p[0],4,&size)||!bounds(p[1],size,section[4][2],64)||!bounds(p[2],size,section[4][2],64))return 6;
        } else if(op[21])return 6;
    }
    if(io_error)return 11;
    phase=5;
    for(uint32_t i=1;i<=6;i++)if(transaction(PACKAGE_BASE+section[i][1],section[i][2],section[i][5],1))return 7;
    if(transaction(PACKAGE_BASE+256,PACKAGE_BYTES-256,header[5],1))return 7;
    /* Specialization pins all sections, including weights and quantization.
     * This is intentional: a changed model needs a separately reviewed manifest.
     */
    if(header[5]!=EXPECTED_PAYLOAD_CRC||header[7]!=EXPECTED_ARENA||macs!=EXPECTED_MACS||digest!=EXPECTED_OP_HASH)return 8;
    for(uint32_t i=1;i<=6;i++)if(section[i][5]!=expected_section_crc[i-1])return 8;
    package_metrics[1]=header[12];package_metrics[2]=header[13];package_metrics[3]=macs;package_metrics[4]=digest;package_metrics[5]=header[7];
    __asm__ volatile("fence iorw,iorw" ::: "memory");published=1;phase=6;return 0;
}
