#include <stddef.h>
#include <stdint.h>
typedef uint32_t alias_word __attribute__((__may_alias__));
/* Standard non-overlapping memcpy semantics. No read/write crosses [p,p+n).
 * Use aligned RV32 words only when both pointers have matching alignment. */
void *memcpy(void *destination,const void *source,size_t n){
 unsigned char *d=destination;const unsigned char *s=source;
 if((((uintptr_t)d^(uintptr_t)s)&3u)==0){
  while(n&&((uintptr_t)d&3u)){*d++=*s++;--n;}
  while(n>=4){*(alias_word*)d=*(const alias_word*)s;d+=4;s+=4;n-=4;}
 }
 while(n){*d++=*s++;--n;}return destination;
}
void *memset(void *destination,int value,size_t n){
 unsigned char *d=destination;unsigned char c=(unsigned char)value;
 while(n&&((uintptr_t)d&3u)){*d++=c;--n;}
 uint32_t word=(uint32_t)c*0x01010101u;
 while(n>=4){*(alias_word*)d=word;d+=4;n-=4;}
 while(n){*d++=c;--n;}return destination;
}
