/* Independent positive binary64 square-add and square-root, ties-to-even.
   Specialized to sum-of-squares: no cancellation, preserving exact guard/sticky.
   No hostlibm dependence; finite x and nonnegative c (including+inf). */
#include <stdint.h>
struct U128{uint64_t hi,lo;};
static unsigned width(uint64_t x){return x?64u-(unsigned)__builtin_clzll(x):0;}
static struct U128 mul(uint64_t a,uint64_t b){uint64_t a0=(uint32_t)a,a1=a>>32,b0=(uint32_t)b,b1=b>>32,p0=a0*b0,p1=a0*b1,p2=a1*b0,p3=a1*b1,mid=(p0>>32)+(uint32_t)p1+(uint32_t)p2;struct U128 r={p3+(p1>>32)+(p2>>32)+(mid>>32),(mid<<32)|(uint32_t)p0};return r;}
static struct U128 left(struct U128 a,unsigned n){if(!n)return a;if(n>=64){a.hi=a.lo<<(n-64);a.lo=0;}else{a.hi=(a.hi<<n)|(a.lo>>(64-n));a.lo<<=n;}return a;}
static struct U128 jam(struct U128 a,unsigned n){if(!n)return a;struct U128 r={0,0};if(n>=128){r.lo=(a.hi|a.lo)!=0;return r;}if(n>=64){unsigned k=n-64;r.lo=k?a.hi>>k:a.hi;uint64_t mask=k?((1ULL<<k)-1):0;r.lo|=a.lo!=0||(a.hi&mask)!=0;return r;}r.hi=a.hi>>n;r.lo=(a.lo>>n)|(a.hi<<(64-n));r.lo|=(a.lo<<(64-n))!=0;return r;}
static struct U128 add(struct U128 a,struct U128 b){struct U128 r;r.lo=a.lo+b.lo;r.hi=a.hi+b.hi+(r.lo<a.lo);return r;}
static unsigned at(struct U128 a,int p){if(p<0||p>=128)return 0;return p>=64?(a.hi>>(p-64))&1:(a.lo>>p)&1;}
static uint64_t encode64(uint64_t m,int unit){if(!m)return 0;unsigned w=width(m);int e=unit+(int)w-1;if(e>1023)return 0x7ff0000000000000ULL;if(e< -1022)return m;if(w>53)m>>=w-53;else m<<=53-w;return((uint64_t)(e+1023)<<52)|(m&0xfffffffffffffULL);}
static unsigned below(struct U128 a,int n){if(n<=0)return 0;if(n>=128)return(a.hi|a.lo)!=0;if(n==64)return a.lo!=0;if(n<64)return(a.lo&((1ULL<<n)-1))!=0;return a.lo!=0||(a.hi&((1ULL<<(n-64))-1))!=0;}
static uint64_t rounded(struct U128 a,int unit){int h=a.hi?63+(int)width(a.hi):(int)width(a.lo)-1;if(h<0)return 0;int target=unit+h-52;if(target< -1074)target=-1074;int shift=target-unit;uint64_t q=0;
 if(shift==0)q=a.lo;else if(shift<0)q=a.lo<<(-shift);else if(shift<64)q=(a.lo>>shift)|(a.hi<<(64-shift));else if(shift==64)q=a.hi;else if(shift<128)q=a.hi>>(shift-64);
 if(at(a,shift-1)&&(below(a,shift-1)||(q&1)))q++;return encode64(q,target);}

uint64_t square_add64_bits(uint64_t xb,uint64_t cb){
 unsigned ex=(unsigned)(xb>>52)&2047,ec=(unsigned)(cb>>52)&2047;if(ex==2047)return 0x7ff8000000000000ULL;if(ec==2047)return cb;
 uint64_t mx=(xb&0xfffffffffffffULL)|(ex?0x10000000000000ULL:0),mc=(cb&0xfffffffffffffULL)|(ec?0x10000000000000ULL:0);if(!mx)return (cb&0x7fffffffffffffffULL)?cb:0;
 int ep=2*(ex?(int)ex-1075:-1074),ce=ec?(int)ec-1075:-1074;struct U128 p=mul(mx,mx);int hp=p.hi?63+(int)width(p.hi):(int)width(p.lo)-1;
 if(!mc)return rounded(p,ep);
 int hc=(int)width(mc)-1,topP=ep+hp,topC=ce+hc,top=topP>topC?topP:topC;struct U128 c={0,mc};p=left(p,(unsigned)(126-hp));c=left(c,(unsigned)(126-hc));p=jam(p,(unsigned)(top-topP));c=jam(c,(unsigned)(top-topC));return rounded(add(p,c),top-126);
}
double square_add64(double x,double c){union{double d;uint64_t u;}a={x},b={c};b.u=square_add64_bits(a.u,b.u);return b.d;}
uint64_t sqrt64_positive_bits(uint64_t x){
 unsigned ex=(unsigned)(x>>52)&2047;if(!(x&0x7fffffffffffffffULL)||ex==2047)return x;
 uint64_t m=(x&0xfffffffffffffULL)|(ex?0x10000000000000ULL:0);int e=ex?(int)ex-1075:-1074;
 if(e&1){m<<=1;e--;}
 int h=(int)width(m)-1,s=53-h/2;struct U128 n={0,m};n=left(n,(unsigned)(2*s));uint64_t rem=0,q=0;
 for(int i=53;i>=0;i--){rem=(rem<<2)|((uint64_t)at(n,2*i+1)<<1)|at(n,2*i);uint64_t trial=(q<<2)|1;if(rem>=trial){rem-=trial;q=(q<<1)|1;}else q<<=1;}
 uint64_t r=q>>1;if((q&1)&&(rem||(r&1)))r++;return encode64(r,e/2-s+1);
}
double sqrt64_positive(double x){union{double d;uint64_t u;}v={x};v.u=sqrt64_positive_bits(v.u);return v.d;}
