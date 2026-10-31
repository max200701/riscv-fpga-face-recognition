#ifndef RETINA_POST_H
#define RETINA_POST_H
#include <stdint.h>
#include "retina_decode.h"
/* Experimental demo capacity. Overflow is a fault, never top-K truncation. */
#define RETINA_DEMO_CANDIDATES 256u
struct retina_candidate {int32_t row[16];int64_t logit_difference;uint32_t anchor;};
struct retina_workspace {struct retina_candidate candidate[RETINA_DEMO_CANDIDATES];uint32_t order[RETINA_DEMO_CANDIDATES];uint32_t listed[RETINA_DEMO_CANDIDATES];};
struct retina_result {
 uint32_t valid,candidates,kept,selected,has_face,fit_status;
 uint32_t anchors[RETINA_DEMO_CANDIDATES];
 int32_t selected_row[16];double matrix[6];int32_t terms[448];
};
struct retina_reader {
 void *context;
 int (*check_owner)(void*);
 int (*read_anchor)(void*,uint32_t,int32_t[16]);
 /* Optional hardware pre-filter: total anchors with logit[5]-logit[4] >=
  * RETINA_LOGIT_DIFF_MIN and the first RETINA_DEMO_CANDIDATES of them in
  * ascending anchor order. NULL keeps the full CPU scan. */
 int (*scan_candidates)(void*,uint32_t*,uint32_t[RETINA_DEMO_CANDIDATES]);
};
/* 0 success (including no face); -1 arguments; -2 transport/ownership;
 * -3 malformed numerical data; -4 capacity; -5 unresolved FIT.
 * Caller must retain input and output ownership until result consumption.
 * Single owner, no concurrent calls with the same workspace. */
int retina_postprocess(const struct retina_reader*,struct retina_workspace*,struct retina_result*);
#endif
