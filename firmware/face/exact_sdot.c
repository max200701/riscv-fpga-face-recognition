/* Finite binary32 fused RNE and the retained 64-lane SDOT reduction tree.
 * Functional CPU implementation of ki_query_catalog01/rtl/fma32_stream.sv
 * and sdot512_stream.sv. No new FPGA multiply array; slower software path.
 */
#include <stdint.h>
#include "fma32_fast.c"   /* claude_c02 fw9: bit-exact fast FMA (tests/cpu_float/fma_host.c, fma_test.c) */
static void place(uint32_t a[18],uint64_t v,unsigned bit){
 unsigned word=bit/32,shift=bit%32;
 a[word]|=(uint32_t)(v<<shift);
 if(word+1<18)a[word+1]|=shift?(uint32_t)(v>>(32-shift)):(uint32_t)(v>>32);
 if(shift&&word+2<18)a[word+2]|=(uint32_t)(v>>(64-shift));
}
uint32_t demo_fma32(uint32_t a,uint32_t b,uint32_t c){
 unsigned ea=(a>>23)&255,eb=(b>>23)&255,ec=(c>>23)&255;
 if(ea==255||eb==255||ec==255)return 0x7fc00000u;
 uint32_t ma=(a&0x7fffff)|(ea?0x800000:0),mb=(b&0x7fffff)|(eb?0x800000:0),mc=(c&0x7fffff)|(ec?0x800000:0);
 uint64_t product=(uint64_t)ma*mb;unsigned ps=(a^b)>>31,cs=c>>31,sign=ps;
 if(!product&&!mc)return (ps==cs?cs:0)<<31;
 uint32_t pm[18]={0},cm[18]={0},r[18];
 place(pm,product,(unsigned)((ea?(int)ea-150:-149)+(eb?(int)eb-150:-149)+298));
 place(cm,mc,(unsigned)((ec?(int)ec-150:-149)+298));
 const uint32_t *lhs=pm,*rhs=cm;
 if(ps!=cs){
  int k=17;while(k>=0&&pm[k]==cm[k])k--;
  if(k<0)return 0;
  if(pm[k]<cm[k]){lhs=cm;rhs=pm;sign=cs;}
 }
 uint64_t carry=0;
 for(unsigned k=0;k<18;k++){
  if(ps==cs){uint64_t t=(uint64_t)lhs[k]+rhs[k]+carry;r[k]=(uint32_t)t;carry=t>>32;}
  else{uint64_t sub=(uint64_t)rhs[k]+carry;r[k]=lhs[k]-(uint32_t)sub;carry=(uint64_t)lhs[k]<sub;}
 }
 int k=17;while(k>=0&&!r[k])k--;if(k<0)return 0;
 int high=k*32+31-__builtin_clz(r[k]),cut=high-23;if(cut<149)cut=149;
 unsigned word=(unsigned)cut/32,shift=(unsigned)cut%32;
 uint32_t q=r[word]>>shift;if(shift&&word+1<18)q|=r[word+1]<<(32-shift);
 unsigned guard=(r[(cut-1)/32]>>((cut-1)%32))&1,sticky=0;
 for(int j=0;j<(cut-1)/32;j++)sticky|=r[j];
 unsigned low=(cut-1)%32;if(low)sticky|=r[(cut-1)/32]&((1u<<low)-1);
 if(guard&&(sticky||(q&1)))q++;
 if(!q)return sign<<31;
 int exponent=cut-298+23;
 if(q&0x1000000){q>>=1;exponent++;}
 if(exponent>127)return(sign<<31)|0x7f800000u;
 if(!(q&0x800000))return(sign<<31)|(q&0x7fffff);
 return(sign<<31)|((uint32_t)(exponent+127)<<23)|(q&0x7fffff);
}
float dot512_skylakex(const float*x,const float*y){
 uint32_t w[127]={0};
 for(unsigned i=0;i<512;i++){union{float f;uint32_t u;}a={x[i]},b={y[i]};w[i&63]=fma32_fast(a.u,b.u,w[i&63]);}
 for(unsigned k=0;k<63;k++){
  unsigned a,b,d,j,l;
  if(k<32){j=k/8;l=k%8;a=16*j+l;b=a+8;d=64+8*j+l;}
  else if(k<40){l=k-32;a=64+l;b=72+l;d=96+l;}
  else if(k<48){l=k-40;a=96+l;b=80+l;d=104+l;}
  else if(k<56){l=k-48;a=104+l;b=88+l;d=112+l;}
  else if(k<60){l=k-56;a=112+l;b=116+l;d=120+l;}
  else if(k==60){a=120;b=121;d=124;}
  else if(k==61){a=122;b=123;d=125;}
  else{a=124;b=125;d=126;}
  w[d]=fma32_fast(w[a],0x3f800000,w[b]);
 }
 union{float f;uint32_t u;}result;result.u=(w[126]&0x7fffffff)?w[126]:0;return result.f;
}
