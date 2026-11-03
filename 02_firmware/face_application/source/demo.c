
#include <stdint.h>
#include "release_memory.h"
#include "cpu_warp.h"
#define DIAG ((volatile uint32_t *)0x10010200u)
extern int unit_f32(const float*,unsigned,float*);
static struct retina_result face_result;
static float query[512],gallery_vector[512];
static uint32_t bulk_buffer[128];
extern float dot512_skylakex(const float*,const float*);
static uint32_t gallery_count,gallery_revision,gallery_ids[16],gallery_cached;
#define GALLERY_CACHE 0x0a010000u
static uint32_t best_id,accepted,has_match;
static float best_cosine;
static int gallery_preflight(void){
 gallery_cached=DIAG[7]==0x50474c31u;
 if(transaction(0x0a000000u,32,0,0))return 601;
 if(line[0]!=0x31424447u||line[1]!=1||line[2]>16||!line[3]||line[5]!=2080||line[6]||line[7])return 602;
 gallery_count=line[2];gallery_revision=line[3];uint32_t crc=line[4];
 if(!gallery_cached&&gallery_count&&transaction(0x0a000020u,gallery_count*2080u,crc,1))return 603;
 for(unsigned i=0;i<gallery_count;i++){
  if(transaction(0x0a000020u+i*2080u,32,0,0))return 604;
  if(!line[0])return 605;for(unsigned k=1;k<8;k++)if(line[k])return 605;
  gallery_ids[i]=line[0];for(unsigned k=0;k<i;k++)if(gallery_ids[k]==gallery_ids[i])return 606;
 }return 0;
}
static int gallery_query(void){
 for(unsigned i=0;i<gallery_count;i++){
  for(unsigned j=0;j<512;j+=128){
   if(bulk_words(GALLERY_CACHE+i*2048u+4*j,128,bulk_buffer))return 607;
   for(unsigned k=0;k<128;k++){union{uint32_t u;float f;}v={bulk_buffer[k]};gallery_vector[j+k]=v.f;}
  }
  float dot=dot512_skylakex(query,gallery_vector);if(dot>1)dot=1;if(dot< -1)dot=-1;
  union{float f;uint32_t u;}v={dot};if((v.u&0x7f800000u)==0x7f800000u)return 609;
  if(!has_match||dot>best_cosine){best_cosine=dot;best_id=gallery_ids[i];has_match=1;}
 }
 accepted=has_match&&(double)best_cosine>=0.40;return 0;
}
static uint32_t owned;
static void marker(uint32_t id,uint32_t value){DIAG[1]=id;DIAG[2]=value;DIAG[3]=0;__asm__ volatile("fence iorw,iorw":::"memory");DIAG[4]=0x201;}
static int owner(void*c){(void)c;return !owned||published!=1;}
static int anchor(void*c,uint32_t a,int32_t raw[16]){
 (void)c;if(a>=12600||owner(0))return -1;
 if(transaction(0x05800000u+64*a,32,0,0))return -1;for(unsigned k=0;k<8;k++)raw[k]=(int32_t)line[k];
 /* Below the unchanged decode threshold only logits 4/5 are consumed: skip the second line. */
 if((int64_t)raw[5]-raw[4]<RETINA_LOGIT_DIFF_MIN){for(unsigned k=8;k<16;k++)raw[k]=0;return 0;}
 if(transaction(0x05800000u+64*a+32,32,0,0))return -1;for(unsigned k=0;k<8;k++)raw[8+k]=(int32_t)line[k];return 0;
}
/* Bridge commands 4/5: hardware anchor-table scan, then 8 indices per fetch. */
static int scan(void*c,uint32_t*total,uint32_t list[RETINA_DEMO_CANDIDATES]){
 (void)c;if(owner(0)||transaction(0x05800000u,64u*RETINA_ANCHORS,0,4))return -1;
 if(line[1]!=RETINA_ANCHORS)return -1;*total=line[0];
 uint32_t n=*total<RETINA_DEMO_CANDIDATES?*total:RETINA_DEMO_CANDIDATES;
 for(uint32_t b=0;8*b<n;b++){
  if(owner(0)||transaction(b,32,0,5))return -1;
  for(unsigned k=0;k<8&&8*b+k<n;k++)list[8*b+k]=line[k];
 }
 return 0;
}
static int rd(void*c,uint32_t a,int32_t v[8]){(void)c;if(owner(0)||transaction(a,32,0,0))return -1;for(unsigned k=0;k<8;k++)v[k]=(int32_t)line[k];return 0;}
static int wr(void*c,uint32_t a,const int32_t v[8]){
 (void)c;if(owner(0))return -1;uint32_t count=0;
 while(!(IO[1]&1))if(++count>40000000u)return -1;
 for(unsigned k=0;k<8;k++)IO[8+k]=(uint32_t)v[k];IO[2]=a;IO[3]=32;IO[4]=0;
 __asm__ volatile("fence iorw,iorw":::"memory");IO[0]=2;count=0;
 while(!(IO[1]&2))if(++count>40000000u)return -1;
 uint32_t error=IO[5];IO[5]=1;return error?-1:0;
}
// Executed only after a raw gallery/cache write or a cold/fault reset.
// Exact original normalization; CPU still performs it, never the host.
static int gallery_prepare_cache(void){
 if(gallery_cached)return 0;
 for(unsigned i=0;i<gallery_count;i++){
  for(unsigned j=0;j<512;j+=128){
   if(bulk_words(0x0a000040u+i*2080u+4*j,128,bulk_buffer))return 607;
   for(unsigned k=0;k<128;k++){union{uint32_t u;float f;}v={bulk_buffer[k]};gallery_vector[j+k]=v.f;}
  }
  if(unit_f32(gallery_vector,512,gallery_vector))return 608;
  for(unsigned j=0;j<512;j+=8){
   int32_t bits[8];for(unsigned k=0;k<8;k++){union{float f;uint32_t u;}v={gallery_vector[j+k]};bits[k]=(int32_t)v.u;}
   if(wr(0,GALLERY_CACHE+i*2048u+4*j,bits))return 611;
  }
 }
 marker(0xfffffff4u,0x50474c31u);
 unsigned n=0;while(DIAG[7]!=0x50474c31u)if(++n>1024)return 612;
 return 0;
}
static int run_graph(void){
 volatile uint32_t*d=(volatile uint32_t*)0x10010300u;const model_contract*m=&models[current_model];
 d[2]=m->program;d[3]=m->commands;__asm__ volatile("fence iorw,iorw":::"memory");d[0]=1;
 uint32_t count=0;while(!(d[1]&2))if(++count>40000000u)return 200;
 uint32_t error=d[4],completed=d[5];d[4]=1;if(error)return 201+error;if(completed+1!=m->commands)return 250;
 return 0;
}
static void publish_result(void){
 union{float f;uint32_t u;}cosine={best_cosine},threshold={0.40f};
 uint32_t words[16]={0x31445246u,1,0x261007a1u,
  face_result.has_face|(accepted<<1)|(has_match<<2)|(face_result.has_face<<3),
  face_result.selected,face_result.candidates,face_result.kept,best_id,cosine.u,gallery_count,threshold.u,gallery_revision,
  (uint32_t)face_result.selected_row[0],(uint32_t)face_result.selected_row[1],
  (uint32_t)face_result.selected_row[2],(uint32_t)face_result.selected_row[3]};
 for(unsigned k=0;k<16;k++)marker(0xa0000000u+k,words[k]);
 __asm__ volatile("fence iorw,iorw":::"memory");owned=0;marker(0xfffffff7u,1);
}
extern int coremark_load(void);
int main(void){
 if(DIAG[8])return coremark_load();
 best_id=0xffffffffu;DIAG[5]=1;
 // The retained hardware receipt is invalidated by cold reset, DDR loss,
 // any fault, or an accepted write to a model/program/assets allocation.
 // Gallery cache has its own physical-write-invalidated retained receipt.
 if(DIAG[6]!=0x50454d31u){
  
 published=0;
 for(current_model=0;current_model<2;current_model++){
  const model_contract*m=&models[current_model];
  if(transaction(m->package_base,m->package_bytes,whole_package_crc[current_model],1))return 22;
  if(transaction(m->program,m->program_bytes,m->program_crc,1))return 23;
  if(transaction(m->assets,m->asset_bytes,m->asset_crc,1))return 24;
 }
 published=1;
  marker(0xfffffff6u,0x50454d31u);
  unsigned receipt_wait=0;
  while(DIAG[6]!=0x50454d31u)if(++receipt_wait>1024)return 610;
 }else{
  
  published=1;
 }
 owned=1;int ge=gallery_preflight();if(ge)return ge;
 ge=gallery_prepare_cache();if(ge)return ge;
 current_model=0;owned=1;DIAG[5]=8;int e=run_graph();if(e)return e;
 struct retina_reader reader={0,owner,anchor,scan};e=retina_postprocess(&reader,&scratch.post,&face_result);
 if(e||!face_result.valid)return 300-e;
 if(!face_result.has_face){publish_result();DIAG[5]=9;return 0;}
 struct warp_io io={0,rd,wr,owner};e=cpu_warp112(&io,face_result.terms,0x01800000u,0x01c00000u);if(e)return 400-e;
 current_model=1;e=run_graph();if(e)return e;
 for(unsigned i=0;i<512;i+=128){if(bulk_words(0x05a00000u+4*i,128,bulk_buffer))return 501;for(unsigned k=0;k<128;k++)query[i+k]=(float)(int32_t)bulk_buffer[k]*0x1p-16f;   /* == (float)((double)v/65536.0) for every int32 v (tests/scale16_exhaustive.py) */}
 if(unit_f32(query,512,query)||unit_f32(query,512,query))return 502;
 for(unsigned i=0;i<512;i++){union{float f;uint32_t u;}v={query[i]};marker(0x90000000u+i,v.u);}
 e=gallery_query();if(e)return e;publish_result();DIAG[5]=9;return 0;
}
