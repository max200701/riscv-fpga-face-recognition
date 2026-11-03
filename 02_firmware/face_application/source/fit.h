#ifndef TYPED_SIMILARITY_H
#define TYPED_SIMILARITY_H
#include <stdint.h>
/* No result publication except FIT_OK. Fallback statuses are NOT face rejection. */
enum {FIT_OK=0,FIT_REJECT_IDENTICAL=1,FIT_FALLBACK_CONDITION=2,FIT_FALLBACK_SCALE=3,FIT_FALLBACK_TABLE_RANGE=4,FIT_BAD_ARGUMENT=5};
int fit_typed_vga(const int32_t *q,unsigned words,unsigned width,unsigned height,double *matrix,int32_t *tables);
#endif
