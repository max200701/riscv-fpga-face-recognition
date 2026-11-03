#ifndef RETINA_CPU_WARP_H
#define RETINA_CPU_WARP_H
#include <stdint.h>
struct warp_io {
 void *context;
 int (*read_line)(void*,uint32_t,int32_t[8]);
 int (*write_line)(void*,uint32_t,const int32_t[8]);
 int (*owns)(void*);
};
/* Integrated candidate: original CPU supplies the exact FIT terms; a fixed Q16
 * hardware warp uses the existing package/DMA transport and final readback fence.
 * Input is the detector's unchanged NCHW BGR-minus-mean Q16 source frame.
 * Output is RGB normalized Q16 for the original MBF model.
 * Input/output must remain exclusively owned through the function and MBF use.
 */
int cpu_warp112(const struct warp_io*,const int32_t terms[448],uint32_t source,uint32_t dest);
#endif
