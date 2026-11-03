/* bit-exact fast paths for the recognition post-processing.
 *
 * add_square_bits(c, x): RNE(c + x*x) for a nonnegative binary64 c (zero, normal or +inf) and a finite
 *   binary32 x. Identical to square_add64_bits((double)x, c) of positive64_exact.c: x*x is an exact
 *   48-bit product, both terms are nonnegative (no cancellation), one rounding. 64-bit integers with
 *   a jammed (sticky) alignment; >= 9 guard bits below the rounding position.
 * unit_div: (float)((double)x / n) for finite binary32 x and a normal positive binary64 n with
 *   |x| <= n (unit_f32: n = norm >= |x|). Per-vector reciprocal R = floor((2^116-1)/N), quotient
 *   Q = floor(X*2^84/N) from X*R with an exact remainder correction (at most two steps), RNE to the
 *   53-bit double, then RNE of that double to binary32 (subnormal outputs included).
 * Verified against the original functions on the host (tests/cpu_float/fast_exact_host.c) and by
 * the full single-photo VALUES_EQUAL_MR simulation. */
#include <stdint.h>

static inline unsigned clz64(uint64_t x){return (unsigned)__builtin_clzll(x);}
static inline uint64_t jam(uint64_t x,unsigned d){if(!d)return x;if(d>=64)return x!=0;return (x>>d)|((x&((1ULL<<d)-1))!=0);}

uint64_t add_square_bits(uint64_t cb,uint32_t xb){
 unsigned ec=(unsigned)(cb>>52)&2047;
 if(ec==2047)return cb;                                   /* +inf stays */
 unsigned ex=(xb>>23)&255;uint32_t mx=(xb&0x7fffff)|(ex?0x800000u:0);
 uint64_t mc=(cb&0xfffffffffffffULL)|(ec?0x10000000000000ULL:0);
 if(!mx)return mc?cb:0;                                   /* as square_add64: x==0 keeps c, c==+-0 gives +0 */
 int xe=ex?(int)ex-150:-149;uint64_t p=(uint64_t)mx*mx;int pe=2*xe;   /* x*x = p*2^pe exactly */
 unsigned hp=63-clz64(p);
 if(!mc){                                                  /* round p alone (exact: <= 48 bits) */
  int e=pe+(int)hp;                                       /* exponent of the top bit; always normal */
  uint64_t m=p<<(52-hp);
  return ((uint64_t)(e+1023)<<52)|(m&0xfffffffffffffULL);
 }
 int ce=ec?(int)ec-1075:-1074;unsigned hc=63-clz64(mc);
 int tp=pe+(int)hp,tc=ce+(int)hc;                         /* exponents of the top bits */
 uint64_t sp=p<<(62-hp),sc=mc<<(62-hc);int top;
 if(tp>=tc){sc=jam(sc,(unsigned)(tp-tc));top=tp;}else{sp=jam(sp,(unsigned)(tc-tp));top=tc;}
 uint64_t s=sp+sc;                                         /* < 2^64: both < 2^63 */
 unsigned sh;if(s>>63){sh=11;top++;}else sh=10;          /* keep 53 bits */
 uint64_t q=s>>sh,rem=s&((1ULL<<sh)-1),half=1ULL<<(sh-1);
 if(rem>half||(rem==half&&(q&1)))q++;
 if(q>>53){q>>=1;top++;}
 if(top>1023)return 0x7ff0000000000000ULL;
 return ((uint64_t)(top+1023)<<52)|(q&0xfffffffffffffULL);
}

/* 64x64 -> low 64 and 32x64 -> high bits helpers (RV32: a few mul/mulhu) */
static inline uint64_t mul_lo64(uint64_t a,uint64_t b){return a*b;}
static inline uint64_t mul32x64_shr32(uint32_t x,uint64_t r){    /* floor(x*r / 2^32), x*r < 2^96 */
 uint64_t lo=(uint64_t)x*(uint32_t)r,hi=(uint64_t)x*(uint32_t)(r>>32);
 return hi+(lo>>32);
}

struct unit_div{uint64_t n,r;int en;};
void unit_div_init(struct unit_div*d,double norm){
 union{double f;uint64_t u;}v={norm};unsigned e=(unsigned)(v.u>>52)&2047;
 d->n=(v.u&0xfffffffffffffULL)|0x10000000000000ULL;d->en=(int)e-1075;   /* norm = n*2^en, n in [2^52,2^53) */
 /* r = floor((2^116-1)/n) by restoring division (once per vector) */
 uint64_t rem=0,q=0;
 for(int i=115;i>=0;i--){
  uint64_t top=rem>>63;rem=(rem<<1)|1;                    /* numerator bits are all ones */
  q<<=1;if(top||rem>=d->n){rem-=d->n;q|=1;}
 }
 d->r=q;
}
/* Stage 1: the RNE binary64 quotient |x|/n as q53*2^e2 (q53 in [2^52,2^53)); returns 0 for x == +-0. */
static int div_q53(const struct unit_div*d,uint32_t xb,uint64_t*q53o,int*e2o){
 unsigned ex=(xb>>23)&255;uint32_t X=xb&0x7fffff;int xe;
 if(ex){X|=0x800000u;xe=(int)ex-150;}else{if(!X)return 0;unsigned lz=(unsigned)__builtin_clz(X)-8;X<<=lz;xe=-149-(int)lz;}
 /* X in [2^23,2^24): Q = floor(X*2^84/N) in [2^54,2^56) */
 uint64_t Q=mul32x64_shr32(X,d->r);
 uint64_t rem=0-mul_lo64(Q,d->n);                         /* X*2^84 - Q*N, exact mod 2^64 (true value in [0,3N)) */
 while(rem>=d->n){rem-=d->n;Q++;}
 /* double: RNE(Q) to 53 bits; value = Q*2^(xe-en-84) */
 unsigned L=64-clz64(Q),s=L-53;uint64_t q53=Q>>s,low=Q&((1ULL<<s)-1),half=1ULL<<(s-1);
 int e2=xe-d->en-84+(int)s;                               /* double value = q53*2^e2 */
 if(low>half||(low==half&&(rem!=0||(q53&1))))q53++;      /* guard + sticky (low bits, remainder) */
 if(q53>>53){q53>>=1;e2++;}
 *q53o=q53;*e2o=e2;return 1;
}
/* Test hook: binary64 bits of x/n (always a normal double here). */
uint64_t unit_div_dbits(const struct unit_div*d,uint32_t xb){
 uint64_t q53;int e2;uint64_t sign=(uint64_t)(xb>>31)<<63;
 if(!div_q53(d,xb,&q53,&e2))return sign;
 return sign|((uint64_t)(e2+52+1023)<<52)|(q53&0xfffffffffffffULL);
}
uint32_t unit_div_bits(const struct unit_div*d,uint32_t xb){
 uint32_t sign=xb&0x80000000u;uint64_t q53;int e2;
 if(!div_q53(d,xb,&q53,&e2))return sign;
 /* float: RNE of the exact double q53*2^e2 (q53 in [2^52,2^53)) */
 int top=e2+52;                                           /* exponent of the top bit */
 int fs=top>=-126?29:29+(-126-top);                       /* bits dropped: 29 for normal, more for subnormal */
 if(fs>=64)return sign;                                    /* far below the smallest subnormal */
 uint64_t f=fs?q53>>fs:q53,flow=q53&((1ULL<<fs)-1),fhalf=1ULL<<(fs-1);
 if(flow>fhalf||(flow==fhalf&&(f&1)))f++;
 if(top>=-126){
  if(f>>24){f>>=1;top++;}
  return sign|((uint32_t)(top+127)<<23)|((uint32_t)f&0x7fffff);
 }
 return sign|(uint32_t)f;                                  /* subnormal (f==2^23 is the smallest normal, encoded the same way) */
}
