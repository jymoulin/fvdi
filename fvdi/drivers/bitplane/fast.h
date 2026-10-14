/*
 * Fast paths for interleaved bitplanes (fast.c)
 */
#ifndef FAST_H
#define FAST_H

long fast_expand(Workstation *wk, MFDB *src, long src_x, long src_y,
                 MFDB *dst, long dst_x, long dst_y, long w, long h,
                 long mode, unsigned long fg, unsigned long bg);

long fast_fill(Workstation *wk, long x, long y, long w, long h,
               const short *pattern, unsigned long colour, long mode);

long fast_blit(Workstation *wk, MFDB *src, long src_x, long src_y,
               MFDB *dst, long dst_x, long dst_y, long w, long h);

#endif
