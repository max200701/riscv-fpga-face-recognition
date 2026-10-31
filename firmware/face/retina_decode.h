#ifndef RETINA_DECODE_H
#define RETINA_DECODE_H
#include <stdint.h>
#define RETINA_ANCHORS 12600u
/* ceil(log(.6/.4)*65536): retained iff logit[5]-logit[4] >= this (unrounded). */
#define RETINA_LOGIT_DIFF_MIN 26573
/* raw: loc4, background/face logits2, five landmarks10; signed Q16.
 * decoded: center x/y, width/height, score, landmarks10, Q16 one.
 * 1: retained by unchanged .60 detector threshold; 0: below threshold;
 * negative: malformed index/numerical range. Caller must propagate faults.
 * Separate fresh Retina NMS must use inclusive coordinates and IoU .40.
 * This function does not authorize buffers, publish records, or retire jobs.
 */
int retina_decode_q16(uint32_t anchor,const int32_t raw[16],int32_t decoded[16]);
#endif
