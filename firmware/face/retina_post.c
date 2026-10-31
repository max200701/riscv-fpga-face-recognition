#include "retina_post.h"
#include "fit.h"
static float maximum(float a,float b){return a>b?a:b;}
static float minimum(float a,float b){return a<b?a:b;}
static void box(const int32_t*r,float*b){
 float x=(float)r[0]*0x1p-16f,y=(float)r[1]*0x1p-16f;
 float w=(float)r[2]*0x1p-16f,h=(float)r[3]*0x1p-16f;
 b[0]=x-w*.5f;b[1]=y-h*.5f;b[2]=x+w*.5f;b[3]=y+h*.5f;
}
static int suppressed(const int32_t*a,const int32_t*b){
 float x[4],y[4];box(a,x);box(b,y);
 /* Pinned Retina reference uses inclusive pixel coordinates (+1), unlike
    the old YOLO Rect2d NMS. Preserve binary32 operation boundaries. */
 float w=maximum(0.f,minimum(x[2],y[2])-maximum(x[0],y[0])+1.f);
 float h=maximum(0.f,minimum(x[3],y[3])-maximum(x[1],y[1])+1.f);
 float ia=(x[2]-x[0]+1.f)*(x[3]-x[1]+1.f);
 float ib=(y[2]-y[0]+1.f)*(y[3]-y[1]+1.f);
 float intersection=w*h;float overlap=intersection/(ia+ib-intersection);
 return overlap>0.4f;
}
/* claude_c02 fw8: per-candidate box and area computed once; same binary32 operations and
   order as suppressed(), so the overlap decisions are bit-identical. */
static int suppressed_cached(const float*x,float ia,const float*y,float ib){
 float w=maximum(0.f,minimum(x[2],y[2])-maximum(x[0],y[0])+1.f);
 float h=maximum(0.f,minimum(x[3],y[3])-maximum(x[1],y[1])+1.f);
 float intersection=w*h;float overlap=intersection/(ia+ib-intersection);
 return overlap>0.4f;
}
static float clipped_area(const int32_t*r){
 float b[4];box(r,b);
 float w=minimum(640.f,maximum(0.f,b[2]))-minimum(640.f,maximum(0.f,b[0]));
 float h=minimum(480.f,maximum(0.f,b[3]))-minimum(480.f,maximum(0.f,b[1]));
 return w>0.f&&h>0.f?w*h:0.f;
}
int retina_postprocess(const struct retina_reader*io,struct retina_workspace*w,struct retina_result*out){
 if(!io||!w||!out||!io->read_anchor||!io->check_owner)return -1;
 out->valid=0;out->has_face=0;out->candidates=0;out->kept=0;out->selected=0xffffffffu;out->fit_status=0xffffffffu;
 if(io->check_owner(io->context))return -2;
 uint32_t count=0,total=0,listed=RETINA_ANCHORS;
 if(io->scan_candidates){
  /* Same retained set and ascending order as the full scan; only anchors the
     hardware reports are read. Disagreement with decode is a transport fault. */
  if(io->check_owner(io->context)||io->scan_candidates(io->context,&total,w->listed))return -2;
  listed=total<RETINA_DEMO_CANDIDATES?total:RETINA_DEMO_CANDIDATES;
 }
 for(uint32_t i=0;i<listed;i++){
  uint32_t a=io->scan_candidates?w->listed[i]:i;
  int32_t raw[16],row[16];
  if(a>=RETINA_ANCHORS||(io->scan_candidates&&i&&a<=w->listed[i-1]))return -2;
  if(io->check_owner(io->context)||io->read_anchor(io->context,a,raw))return -2;
  int rc=retina_decode_q16(a,raw,row);if(rc<0)return -3;
  if(!rc){if(io->scan_candidates)return -2;continue;}
  if(count==RETINA_DEMO_CANDIDATES)return -4;
  struct retina_candidate*c=&w->candidate[count];
  for(unsigned k=0;k<16;k++)c->row[k]=row[k];
  c->anchor=a;c->logit_difference=(int64_t)raw[5]-raw[4];w->order[count]=count;count++;
 }
 if(io->scan_candidates&&total>RETINA_DEMO_CANDIDATES)return -4;
 /* Sort by unrounded sigmoid input, avoiding Q16-score ties/saturation.
    Equal logits use ascending original anchor: explicit deterministic tie ABI. */
 for(uint32_t i=1;i<count;i++){
  uint32_t id=w->order[i],j=i;
  while(j&&w->candidate[w->order[j-1]].logit_difference<w->candidate[id].logit_difference){w->order[j]=w->order[j-1];j--;}
  w->order[j]=id;
 }
 uint32_t kept=0,selected=0xffffffffu;float area=0.f;
 static float bx[RETINA_DEMO_CANDIDATES][4],ba[RETINA_DEMO_CANDIDATES];
 for(uint32_t i=0;i<count;i++){box(w->candidate[i].row,bx[i]);ba[i]=(bx[i][2]-bx[i][0]+1.f)*(bx[i][3]-bx[i][1]+1.f);}
 for(uint32_t i=0;i<count;i++){
  uint32_t id=w->order[i];int keep=1;
  for(uint32_t k=0;k<kept&&keep;k++){uint32_t o=w->order[k];keep=!suppressed_cached(bx[id],ba[id],bx[o],ba[o]);}
  if(!keep)continue;
  w->order[kept++]=id;
 }
 uint32_t visible=0;
 for(uint32_t k=0;k<kept;k++){
  uint32_t id=w->order[k];float v=clipped_area(w->candidate[id].row);if(v<=0.f)continue;
  w->order[visible++]=id;if(v>area){area=v;selected=id;}
 }
 kept=visible;
 if(io->check_owner(io->context))return -2;
 if(kept){
  struct retina_candidate*c=&w->candidate[selected];
  int rc=fit_typed_vga(c->row+5,10,640,480,out->matrix,out->terms);out->fit_status=(uint32_t)rc;
  if(rc!=FIT_OK)return -5;
  for(unsigned k=0;k<16;k++)out->selected_row[k]=c->row[k];
  out->selected=c->anchor;out->has_face=1;
 }
 for(uint32_t k=0;k<kept;k++)out->anchors[k]=w->candidate[w->order[k]].anchor;
 out->candidates=count;out->kept=kept;
 if(io->check_owner(io->context))return -2;
#ifdef __riscv
 __asm__ volatile("fence rw,rw":::"memory");
#else
 __asm__ volatile("":::"memory");
#endif
 out->valid=1;return 0;
}
