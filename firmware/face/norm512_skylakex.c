/* Pinned OpenBLAS0.3.29 SkylakeX512-element DDOT self-dot tree. */
extern double square_add64(double,double);
extern double sqrt64_positive(double);
static double finish(double a[4][8]){double c[4];for(unsigned l=0;l<4;l++){double z=a[0][l]+a[0][l+4];for(unsigned j=1;j<4;j++){double b=a[j][l]+a[j][l+4];z=z+b;}c[l]=z;}double lo=c[0]+c[2],hi=c[1]+c[3];return sqrt64_positive(lo+hi);}
double norm512_f64(const double*x){double a[4][8];for(unsigned j=0;j<4;j++)for(unsigned l=0;l<8;l++)a[j][l]=0;for(unsigned k=0;k<16;k++)for(unsigned j=0;j<4;j++)for(unsigned l=0;l<8;l++){unsigned i=32*k+8*j+l;a[j][l]=square_add64(x[i],a[j][l]);}return finish(a);}
double norm512_f32(const float*x){double a[4][8];for(unsigned j=0;j<4;j++)for(unsigned l=0;l<8;l++)a[j][l]=0;for(unsigned k=0;k<16;k++)for(unsigned j=0;j<4;j++)for(unsigned l=0;l<8;l++){unsigned i=32*k+8*j+l;a[j][l]=square_add64((double)x[i],a[j][l]);}return finish(a);}
