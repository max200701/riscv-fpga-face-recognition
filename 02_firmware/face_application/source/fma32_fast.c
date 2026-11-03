/* bit-exact replacement for demo_fma32 (exact_sdot.c) using 64-bit integers.
 * Same results for every input: any exponent-255 input -> 0x7fc00000; otherwise the correctly
 * rounded (ties-to-even) binary32 a*b+c with subnormals and overflow to +-inf; zero results follow
 * demo_fma32 (both terms zero: sign = cs if signs agree else +0; exact cancellation -> +0).
 * Method: product (<=48 bits) and addend normalised to bit 61, the smaller one shifted right with
 * a sticky "jam" bit, exact add/subtract, one rounding. Verified against an exact rational oracle
 * (tests/cpu_float/fma_model.py) and against demo_fma32 itself on the CPU (tests/cpu_float/fma_test.c). */
#include <stdint.h>
static uint64_t jam64(uint64_t x,unsigned d){if(!d)return x;if(d>=64)return x!=0;return (x>>d)|((x&((1ULL<<d)-1))!=0);}
static uint32_t enc32(uint32_t sign,uint32_t q,int qexp){
 if(!q)return sign<<31;
 if(q>=0x800000u){int biased=qexp+150;if(biased>=255)return (sign<<31)|0x7f800000u;return (sign<<31)|((uint32_t)biased<<23)|(q-0x800000u);}
 return (sign<<31)|q;
}
static uint32_t round32(uint32_t sign,uint64_t s,int e0){
 int t=63-__builtin_clzll(s),e=e0+t,qexp=e-23;if(qexp< -149)qexp=-149;
 int shift=qexp-e0;uint32_t q;
 if(shift<=0)q=(uint32_t)(s<<(unsigned)(-shift));
 else if(shift>=64)q=0;
 else{q=(uint32_t)(s>>shift);uint64_t rem=s&((1ULL<<shift)-1),half=1ULL<<(shift-1);if(rem>half||(rem==half&&(q&1)))q++;}
 if(q==0x1000000u){q>>=1;qexp++;}
 return enc32(sign,q,qexp);
}
uint32_t fma32_fast(uint32_t a,uint32_t b,uint32_t c){
 unsigned ea=(a>>23)&255,eb=(b>>23)&255,ec=(c>>23)&255;
 if(ea==255||eb==255||ec==255)return 0x7fc00000u;
 uint32_t ma=(a&0x7fffff)|(ea?0x800000:0),mb=(b&0x7fffff)|(eb?0x800000:0),mc=(c&0x7fffff)|(ec?0x800000:0);
 int xa=ea?(int)ea-150:-149,xb=eb?(int)eb-150:-149,xc=ec?(int)ec-150:-149;
 uint32_t ps=(a^b)>>31,cs=c>>31;
 uint64_t p=(uint64_t)ma*mb;
 if(!p&&!mc)return (ps==cs?cs:0)<<31;
 if(!p)return c;
 int tp=63-__builtin_clzll(p);uint64_t sp=p<<(61-tp);int xp=xa+xb+tp;
 uint64_t s;int x;uint32_t sign;
 if(!mc){s=sp;x=xp;sign=ps;}
 else{
  int tc=31-__builtin_clz(mc);uint64_t sc=(uint64_t)mc<<(61-tc);int xq=xc+tc;
  if(xp>=xq){sc=jam64(sc,(unsigned)(xp-xq));x=xp;}else{sp=jam64(sp,(unsigned)(xq-xp));x=xq;}
  if(ps==cs){s=sp+sc;sign=ps;}
  else if(sp>sc){s=sp-sc;sign=ps;}
  else if(sc>sp){s=sc-sp;sign=cs;}
  else return 0;
 }
 return round32(sign,s,x-61);
}
