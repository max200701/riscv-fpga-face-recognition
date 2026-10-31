#include "retina_decode.h"
#include <limits.h>
#include "retina_exp_table.h"

static inline __attribute__((always_inline)) uint64_t divide_even(uint64_t a,uint64_t d){
 uint64_t q=a/d,r=a%d;
 return q+(r>d-r||(r==d-r&&(q&1u)));
}
/* Anchor sizes are powers of two >=16. Cancel factor two first,
 * then use 32-bit divide by five. The remaining denominator is odd, so
 * there are no half ties. This equals original signed nearest-even /10.
 */
static inline int64_t scale_anchor_exact(int32_t v,uint32_t size){
 int32_t q=v/5,r=v-q*5,u=r*(int32_t)(size/2);
 int32_t correction=u>=0?(u+2)/5:-((-u+2)/5);
 return (int64_t)q*(size/2)+correction;
}
static inline int32_t divide5_exact(int32_t v){
 int32_t q=v/5,r=v-q*5;
 return q+(r>=3)-(r<=-3);
}
/* LUT nodes rounded once to Q24. Interpolation and integer exponent product
 * use explicit nearest-even, never compiler floating point. Valid -16..6.
 */
static int exponential_q24(int32_t x,uint64_t *out){
 if(x<-(16*65536)||x>6*65536)return -2;
 int32_t whole=x/65536,frac=x%65536;
 if(frac<0){whole--;frac+=65536;}
 uint32_t i=(uint32_t)frac>>8,f=(uint32_t)frac&255u;
 uint64_t v=exp_fraction_q24[i]+divide_even((uint64_t)(exp_fraction_q24[i+1]-exp_fraction_q24[i])*f,256);
 *out=divide_even(v*exp_integer_q24[whole+16],1u<<24);
 return 0;
}
static int narrow(int64_t x,int32_t *p){
 if(x<INT32_MIN||x>INT32_MAX)return -3;
 *p=(int32_t)x;return 0;
}
int retina_decode_q16(uint32_t anchor,const int32_t raw[16],int32_t decoded[16]){
 if(anchor>=RETINA_ANCHORS||!raw||!decoded)return -1;
 int64_t diff=(int64_t)raw[5]-raw[4];
 /* ceil(log(.6/.4)*65536): compare on unrounded logit difference first. */
 if(diff<RETINA_LOGIT_DIFF_MIN)return 0;
 uint64_t expneg;int32_t score;
 if(diff>=16*65536)score=65536;
 else{
  if(exponential_q24((int32_t)-diff,&expneg))return -2;
  score=(int32_t)divide_even(UINT64_C(1)<<40,(UINT64_C(1)<<24)+expneg);
 }
 uint32_t stride,width,base,size;
 if(anchor<9600){stride=8;width=80;base=0;size=(anchor&1u)?32:16;}
 else if(anchor<12000){stride=16;width=40;base=9600;size=(anchor&1u)?128:64;}
 else{stride=32;width=20;base=12000;size=(anchor&1u)?512:256;}
 uint32_t cell=(anchor-base)/2,x=cell%width,y=cell/width;
 int64_t cx=(int64_t)(x*stride+stride/2)*65536,cy=(int64_t)(y*stride+stride/2)*65536;
 int32_t tmp[16];
 if(narrow(cx+scale_anchor_exact(raw[0],size),tmp)||
    narrow(cy+scale_anchor_exact(raw[1],size),tmp+1))return -3;
 for(uint32_t j=0;j<2;j++){
  int64_t z=divide5_exact(raw[2+j]);uint64_t e;
  if(z<INT32_MIN||z>INT32_MAX||exponential_q24((int32_t)z,&e))return -2;
  uint64_t wh=divide_even(e*size,256);
  if(wh>INT32_MAX)return -3;tmp[2+j]=(int32_t)wh;
 }
 tmp[4]=score;tmp[15]=65536;
 for(uint32_t j=0;j<10;j++)
  if(narrow((j&1u?cy:cx)+scale_anchor_exact(raw[6+j],size),tmp+5+j))return -3;
 /* No partially modified published record on a rejected or faulting input. */
 for(uint32_t j=0;j<16;j++)decoded[j]=tmp[j];
 return 1;
}
