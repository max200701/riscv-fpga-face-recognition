/* Independently written fixed-Q16/VGA experimental structured fit.
   Binary32 input conversion, binary64 arithmetic, no libm/APM. No fast-math/FMA.
   Conditioning guard is a conservative experimental confidence policy, not a
   proof of universal NumPy/OpenBLAS coefficient or crop-bit equivalence. */
#include "fit.h"
static int finite_d(double d){union{double d;uint64_t u;}v={d};return ((v.u>>52)&2047)!=2047;}
static int rne(double d,int32_t *v){
 if(!finite_d(d)||d < -1000000000.0||d>1000000000.0)return 0;
 int32_t i=(int32_t)d;double f=d-i;
 if(f>0.5||(f==0.5&&(i&1)))i++;
 if(f< -0.5||(f== -0.5&&(i&1)))i--;
 *v=i;return 1;
}
/* table fast path, bit-identical to rne(x*1024).
   scale1024: x*1024 is an exact power-of-two scaling for normal x (exponent field +10); zero and
   subnormal inputs use the real multiply; overflow gives +-inf exactly as the multiply would.
   rne_bits: the same round-half-even and the same finite/|d|<=1e9 range test as rne(), computed
   on the binary64 bits instead of trunc/subtract/compare soft-float calls. */
static double scale1024(double x){
 union{double d;uint64_t u;}v={x};unsigned e=(unsigned)(v.u>>52)&2047;
 if(e==0||e==2047)return x*1024.0;
 if(e+10>=2047){v.u=(v.u&0x8000000000000000ULL)|0x7ff0000000000000ULL;return v.d;}
 v.u+=10ULL<<52;return v.d;
}
static int rne_bits(double d,int32_t *out){
 union{double d;uint64_t u;}v={d};unsigned e=(unsigned)(v.u>>52)&2047;
 if(e==2047)return 0;
 if((v.u&0x7fffffffffffffffULL)>0x41cdcd6500000000ULL)return 0;   /* |d| > 1e9 */
 if(e<1022){*out=0;return 1;}                                      /* |d| < 0.5 */
 uint64_t m=(v.u&0xfffffffffffffULL)|(1ULL<<52);unsigned sh=1075-e;  /* |d| = m*2^-sh, 1<=sh<=53 */
 uint64_t ip=m>>sh,fr=m&((1ULL<<sh)-1),half=1ULL<<(sh-1);
 if(fr>half||(fr==half&&(ip&1)))ip++;
 int32_t r=(int32_t)ip;*out=(v.u>>63)?-r:r;return 1;
}
int fit_typed_vga(const int32_t *q,unsigned words,unsigned width,unsigned height,double *matrix,int32_t *tables){
 if(!q||!matrix||!tables||words!=10||width!=640||height!=480)return FIT_BAD_ARGUMENT;
 static const double t[10]={38.2946,51.6963,73.5318,51.5014,56.0252,71.7366,41.5493,92.3655,70.7299,92.2041};
 double p[10],mx=0,my=0,mu=0,mv=0,S=0,pairs=0;
 int same=1;
 for(int i=0;i<10;i++){
  float f=(float)q[i];f=f*0x1p-16f;p[i]=(double)f;
  if(!finite_d(p[i])||p[i]<-32768.0||p[i]>32768.0)return FIT_BAD_ARGUMENT;
  if(i>=2&&p[i]!=p[i&1])same=0;
 }
 if(same)return FIT_REJECT_IDENTICAL;
 for(int i=0;i<5;i++){
  mx+=p[2*i];my+=p[2*i+1];mu+=t[2*i];mv+=t[2*i+1];S+=p[2*i]*p[2*i]+p[2*i+1]*p[2*i+1];
  for(int j=0;j<i;j++){double dx=p[2*i]-p[2*j],dy=p[2*i+1]-p[2*j+1];pairs+=dx*dx+dy*dy;}
 }
 /* 5D=sum_pair squared distances exactly. Each subtraction is exact for this
    dyadic32-bit domain; 64eps cushions positive products/summation and bounds.
    lambda+ <= S+5. Compare squared singular-ratio lower bound, no sqrt. */
 const double eps=0x1p-52;
 double low=pairs*(1.0-64.0*eps),upper=(S+5.0)*(1.0+64.0*eps),guard=1024.0*eps*upper;
 if(!(low>guard*guard*(1.0+16.0*eps)))return FIT_FALLBACK_CONDITION;
 mx/=5;my/=5;mu/=5;mv/=5;
 double den=0,aa=0,bb=0;
 for(int i=0;i<5;i++){double dx=p[2*i]-mx,dy=p[2*i+1]-my,du=t[2*i]-mu,dv=t[2*i+1]-mv;den+=dx*dx+dy*dy;aa+=dx*du+dy*dv;bb+=dx*dv-dy*du;}
 if(!(den>0)||!finite_d(den))return FIT_FALLBACK_CONDITION;
 double a=aa/den,b=bb/den,scale=a*a+b*b;
 /* A low or near-threshold scale is unresolved, never silently face-rejected. */
 if(!finite_d(scale)||!(scale>1e-12*(1.0+0x1p-20)))return FIT_FALLBACK_SCALE;
 double m[6]={a,-b,mu-a*mx+b*my,b,a,mv-b*mx-a*my};
 double determinant=m[0]*m[4]-m[1]*m[3];
 if(!(determinant>0)||!finite_d(determinant))return FIT_FALLBACK_SCALE;
 double inv=1.0/determinant,ia=m[4]*inv,ib=m[1]*(-inv),id=m[3]*(-inv),ie=m[0]*inv;
 double ic=-ia*m[2]-ib*m[5],iff=-id*m[2]-ie*m[5];int32_t temp[448];
 for(int i=0;i<112;i++){double di=(double)i;
  if(!rne_bits(scale1024(ia*di),&temp[i])||!rne_bits(scale1024(id*di),&temp[112+i])||!rne_bits(scale1024(ib*di+ic),&temp[224+i])||!rne_bits(scale1024(ie*di+iff),&temp[336+i]))return FIT_FALLBACK_TABLE_RANGE;}
 for(int i=0;i<6;i++){if(!finite_d(m[i]))return FIT_FALLBACK_TABLE_RANGE;}
 for(int i=0;i<6;i++)matrix[i]=m[i];for(int i=0;i<448;i++)tables[i]=temp[i];return FIT_OK;
}
