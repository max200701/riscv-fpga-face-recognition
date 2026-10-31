/* Independent pinnedSDOT/DDOT reference using exact integer fused arithmetic; no INT8 substitution and no gallery cap. */
#include <stdint.h>
#include <stddef.h>
extern float dot512_skylakex(const float*,const float*);
static int finite_d(double d){union{double d;uint64_t u;}v={d};return ((v.u>>52)&2047)!=2047;}
extern double norm512_f64(const double*);
extern double norm512_f32(const float*);
/* -1 ABI, -2 nonfinite input, -3 zero embedding. Output unchanged on error. */
int unit_f64(const double*in,unsigned n,float*out){
 if(!in||!out||n!=512)return -1;for(unsigned i=0;i<512;i++)if(!finite_d((double)in[i]))return -2;
 /* Original NumPy accepts finite inputs whose squared norm overflows toinf,
    producing signedzero normalized coordinates rather than a new error. */
 double norm=norm512_f64(in);if(norm<1e-12)return -3;
 for(unsigned i=0;i<512;i++)out[i]=(float)(in[i]/norm);return 0;
}
/* claude_c02 fw9: same values as the fw8 unit_f32 (norm512_f32 + (float)((double)in[i]/norm)), computed with
   the bit-exact integer paths of fast_exact.c (tests/cpu_float/fast_exact_host.c: 10^8 square-adds,
   1.25*10^8 divisions incl. float-midpoint cases, 5*10^4 whole vectors; plus the full-photo simulation). */
#include "fast_exact.c"
extern double sqrt64_positive(double);
static double norm512_f32_fast(const float*x){
 union{double d;uint64_t u;}a[4][8];for(unsigned j=0;j<4;j++)for(unsigned l=0;l<8;l++)a[j][l].u=0;
 for(unsigned k=0;k<16;k++)for(unsigned j=0;j<4;j++)for(unsigned l=0;l<8;l++){
  unsigned i=32*k+8*j+l;union{float f;uint32_t u;}v={x[i]};a[j][l].u=add_square_bits(a[j][l].u,v.u);}
 double c[4];for(unsigned l=0;l<4;l++){double z=a[0][l].d+a[0][l+4].d;for(unsigned j=1;j<4;j++){double b=a[j][l].d+a[j][l+4].d;z=z+b;}c[l]=z;}   /* norm512_skylakex.c finish() */
 double lo=c[0]+c[2],hi=c[1]+c[3];return sqrt64_positive(lo+hi);
}
int unit_f32(const float*in,unsigned n,float*out){
 if(!in||!out||n!=512)return -1;
 for(unsigned i=0;i<512;i++){union{float f;uint32_t u;}v={in[i]};if(((v.u>>23)&255)==255)return -2;}   /* == !finite_d((double)in[i]) */
 double norm=norm512_f32_fast(in);if(norm<1e-12)return -3;
 struct unit_div d;unit_div_init(&d,norm);
 for(unsigned i=0;i<512;i++){union{float f;uint32_t u;}v={in[i]};union{uint32_t u;float f;}q={unit_div_bits(&d,v.u)};out[i]=q.f;}
 return 0;
}
struct gallery_result {uint32_t best_index,accepted,has_match;float cosine;};
struct gallery_cache {float *values;uint32_t count;uint64_t revision;uint32_t valid;};
/* Caller owns private destination storage. Invalidates before any cache update;
   partial arrays on failure never receive a valid published revision. */
int gallery_build(const double*raw,uint32_t count,float*dst,size_t capacity_floats,uint64_t revision,struct gallery_cache*cache){
 if(!cache)return -1;cache->valid=0;
 if(count>SIZE_MAX/(512*sizeof(double))||(size_t)count*512>capacity_floats||(count&&(!raw||!dst)))return -1;
 for(uint32_t i=0;i<count;i++){int r=unit_f64(raw+(size_t)i*512,512,dst+(size_t)i*512);if(r)return r;}
 cache->values=dst;cache->count=count;cache->revision=revision;cache->valid=1;return 0;
}
int gallery_search(const float*embedding,unsigned n,const struct gallery_cache*cache,uint64_t expected_revision,double threshold,struct gallery_result*out){
 if(!out||!cache||!cache->valid||cache->revision!=expected_revision||!finite_d(threshold)||threshold< -1||threshold>1)return -1;
 float q[512];int r=unit_f32(embedding,n,q);if(r)return r;
 struct gallery_result result={0xffffffffU,0,0,0};
 for(uint32_t j=0;j<cache->count;j++){
  const float*g=cache->values+(size_t)j*512;float dot=dot512_skylakex(q,g);
  if(dot>1)dot=1;if(dot< -1)dot=-1;
  if(!result.has_match||dot>result.cosine){result.best_index=j;result.cosine=dot;result.has_match=1;}
 }
 if(result.has_match)result.accepted=(double)result.cosine>=threshold;
 *out=result;return 0;
}
