/*
 * Fast paths for interleaved bitplanes (2, 4 and 8 planes)
 *
 * The generic routines in blit.c and fill.c go through a software
 * blitter that handles one plane and one word at a time.  On a Falcon in
 * 256 colours that made fVDI several times slower than the TOS VDI.
 * The common cases are done here instead, two planes per long:
 *  - expanding a monochrome bitmap (all text, icons) in the four VDI
 *    writing modes,
 * Anything else returns 0 and the caller falls back to blit.c.
 *
 * This software is licensed under the GNU General Public License.
 * Please, see LICENSE.TXT for further information.
 */

#include "fvdi.h"
#include "driver.h"
#include "bitplane.h"
#include "fast.h"

/* unroll the loops over plane pairs (at most 4) */
#define UNROLL _Pragma("GCC unroll 4")

/* the bits of colour c for planes 2k and 2k+1, as a long */
static void
colour_longs(unsigned long c, short npairs, unsigned long *out)
{
    short k;

    UNROLL

    for (k = 0; k < npairs; k++)
    {
        unsigned long v = 0;

        if (c & (1UL << (2 * k)))
            v |= 0xffff0000UL;
        if (c & (1UL << (2 * k + 1)))
            v |= 0x0000ffffUL;
        out[k] = v;
    }
}

/* the destination: screen or an interleaved MFDB with the screen's
 * number of planes; returns the address of the form, 0 when not
 * handled here */
static unsigned short *
dest_form(Workstation *wk, MFDB *dst, short *planes, long *nxln)
{
    if (dst && dst->address && dst->address != wk->screen.mfdb.address)
    {
        *planes = dst->bitplanes;
        *nxln = (long) dst->wdwidth * dst->bitplanes * 2;
        return (unsigned short *) dst->address;
    }
    *planes = wk->screen.mfdb.bitplanes;
    *nxln = wk->screen.wrap;
    return (unsigned short *) wk->screen.mfdb.address;
}

/*
 * One group of 16 pixels: npairs longs at d, bits = the monochrome
 * source for those pixels, e = the pixels that may change
 */
static inline void
put_group(unsigned long *d, unsigned short bits, unsigned short e, long mode,
          const unsigned long *F, const unsigned long *B, const unsigned long *X,
          short npairs)
{
    unsigned long m, e32;
    short k;

    switch (mode)
    {
    case 1:
        m = bits * 0x10001UL;
        if (e == 0xffff)
        {
            UNROLL
            for (k = 0; k < npairs; k++)
                d[k] = B[k] ^ (m & X[k]);
        } else
        {
            e32 = e * 0x10001UL;
            UNROLL
            for (k = 0; k < npairs; k++)
                d[k] = (d[k] & ~e32) | ((B[k] ^ (m & X[k])) & e32);
        }
        break;
    case 2:
        m = (unsigned short) (bits & e) * 0x10001UL;
        if (m)
            UNROLL
            for (k = 0; k < npairs; k++)
                d[k] = (d[k] & ~m) | (F[k] & m);
        break;
    case 3:
        m = (unsigned short) (bits & e) * 0x10001UL;
        if (m)
            UNROLL
            for (k = 0; k < npairs; k++)
                d[k] ^= m;
        break;
    default:
        m = (unsigned short) (~bits & e) * 0x10001UL;
        if (m)
            UNROLL
            for (k = 0; k < npairs; k++)
                d[k] = (d[k] & ~m) | (B[k] & m);
        break;
    }
}

/*
 * One line of groups: the first and last ones masked, the ones in
 * between with a loop per writing mode and number of planes, so that
 * the plane loop is unrolled by the compiler.
 */
#define ROW_FUNC(NAME, NP)                                                    \
static void                                                                   \
NAME(unsigned long *__restrict d, const unsigned short *__restrict ab,       \
     long ngroups, unsigned short lmask, unsigned short rmask, long mode,     \
     const unsigned long *Fp, const unsigned long *Bp, const unsigned long *Xp) \
{                                                                             \
    unsigned long F[NP], B[NP], X[NP];                                        \
    long g;                                                                   \
    short k;                                                                  \
                                                                              \
    UNROLL                                                                    \
    for (k = 0; k < NP; k++)                                                  \
    {                                                                         \
        F[k] = Fp[k];                                                         \
        B[k] = Bp[k];                                                         \
        X[k] = Xp[k];                                                         \
    }                                                                         \
                                                                              \
    put_group(d, *ab++, lmask, mode, F, B, X, NP);                            \
    d += NP;                                                                  \
    if (ngroups == 1)                                                         \
        return;                                                               \
    g = ngroups - 2;                                                          \
    switch (mode)                                                             \
    {                                                                         \
    case 1:                                                                   \
        for (; g > 0; g--)                                                    \
        {                                                                     \
            unsigned long m = *ab++ * 0x10001UL;                              \
            UNROLL                                                            \
            for (k = 0; k < NP; k++)                                          \
                d[k] = B[k] ^ (m & X[k]);                                     \
            d += NP;                                                          \
        }                                                                     \
        break;                                                                \
    case 2:                                                                   \
        for (; g > 0; g--)                                                    \
        {                                                                     \
            unsigned long m = *ab++;                                          \
            if (m)                                                            \
            {                                                                 \
                m *= 0x10001UL;                                               \
                UNROLL                                                        \
                for (k = 0; k < NP; k++)                                      \
                    d[k] = (d[k] & ~m) | (F[k] & m);                          \
            }                                                                 \
            d += NP;                                                          \
        }                                                                     \
        break;                                                                \
    case 3:                                                                   \
        for (; g > 0; g--)                                                    \
        {                                                                     \
            unsigned long m = *ab++;                                          \
            if (m)                                                            \
            {                                                                 \
                m *= 0x10001UL;                                               \
                UNROLL                                                        \
                for (k = 0; k < NP; k++)                                      \
                    d[k] ^= m;                                                \
            }                                                                 \
            d += NP;                                                          \
        }                                                                     \
        break;                                                                \
    default:                                                                  \
        for (; g > 0; g--)                                                    \
        {                                                                     \
            unsigned long m = (unsigned short) ~*ab++;                        \
            if (m)                                                            \
            {                                                                 \
                m *= 0x10001UL;                                               \
                UNROLL                                                        \
                for (k = 0; k < NP; k++)                                      \
                    d[k] = (d[k] & ~m) | (B[k] & m);                          \
            }                                                                 \
            d += NP;                                                          \
        }                                                                     \
        break;                                                                \
    }                                                                         \
    put_group(d, *ab, rmask, mode, F, B, X, NP);                              \
}

ROW_FUNC(row_2, 1)
ROW_FUNC(row_4, 2)
ROW_FUNC(row_8, 4)

/* the widest line handled here, in groups of 16 pixels */
#define MAX_GROUPS 128

/*
 * Monochrome to colour expansion, the VDI modes:
 *   1 replace          1 bits -> fg, 0 bits -> bg
 *   2 transparent      1 bits -> fg, 0 bits unchanged
 *   3 xor              1 bits invert all planes
 *   4 reverse transp.  0 bits -> bg, 1 bits unchanged
 */
long
fast_expand(Workstation *wk, MFDB *src, long src_x, long src_y,
            MFDB *dst, long dst_x, long dst_y, long w, long h,
            long mode, unsigned long fg, unsigned long bg)
{
    unsigned long F[4], B[4], X[4];
    unsigned short *dform, *srow;
    unsigned short lmask, rmask;
    long dnxln, snxwd;
    long g0, g1, ngroups, y;
    long s0, wfirst, wlast, wbase;
    short planes, npairs, sh, k;

    if (!src || !src->address || src->bitplanes != 1 || w <= 0 || h <= 0)
        return 0;
    if (((dst_x + w - 1) >> 4) - (dst_x >> 4) + 1 > MAX_GROUPS)
        return 0;
    dform = dest_form(wk, dst, &planes, &dnxln);
    if (planes != 2 && planes != 4 && planes != 8)
        return 0;
    npairs = planes / 2;

    colour_longs(fg, npairs, F);
    colour_longs(bg, npairs, B);
    UNROLL
    for (k = 0; k < npairs; k++)
        X[k] = F[k] ^ B[k];

    g0 = dst_x >> 4;
    g1 = (dst_x + w - 1) >> 4;
    ngroups = g1 - g0 + 1;
    lmask = 0xffff >> (dst_x & 15);
    rmask = 0xffff << (15 - ((dst_x + w - 1) & 15));
    if (ngroups == 1)
        lmask &= rmask;

    /* source bit that lands on the first pixel of the first group;
     * it can be left of the source start: those bits are masked */
    s0 = src_x - (dst_x & 15);
    sh = (short) (s0 & 15);
    wbase = (s0 - sh) / 16;             /* exact: s0 - sh is a multiple of 16 */
    wfirst = src_x >> 4;                /* source words that may be read */
    wlast = (src_x + w - 1) >> 4;
    snxwd = src->wdwidth;

    srow = (unsigned short *) src->address + src_y * snxwd;
    dform = (unsigned short *) ((char *) dform + dst_y * dnxln) + g0 * planes;

    for (y = 0; y < h; y++)
    {
        unsigned short ab[MAX_GROUPS];
        long g, wi = wbase;
        unsigned long acc;

        /* the source bits of each group, aligned on the destination;
         * words outside the source rectangle read as 0 */
        acc = (wi >= wfirst && wi <= wlast) ? srow[wi] : 0;
        for (g = 0; g < ngroups; g++)
        {
            wi++;
            acc = (acc << 16) | ((wi >= wfirst && wi <= wlast) ? srow[wi] : 0);
            ab[g] = (unsigned short) ((acc << sh) >> 16);
        }

        switch (npairs)
        {
        case 4:
            row_8((unsigned long *) dform, ab, ngroups, lmask, rmask, mode, F, B, X);
            break;
        case 2:
            row_4((unsigned long *) dform, ab, ngroups, lmask, rmask, mode, F, B, X);
            break;
        default:
            row_2((unsigned long *) dform, ab, ngroups, lmask, rmask, mode, F, B, X);
            break;
        }

        srow += snxwd;
        dform = (unsigned short *) ((char *) dform + dnxln);
    }

    return 1;
}

/*
 * Pattern fill of a rectangle (already clipped), the modes of fill.c:
 * replace (0 bits -> colour 0), transparent, xor, and reverse
 * transparent (0 bits -> the colour).  The 16 line pattern is aligned
 * on the screen.
 */
long
fast_fill(Workstation *wk, long x, long y, long w, long h,
          const short *pattern, unsigned long colour, long mode)
{
    unsigned long F[4], B[4], X[4];
    unsigned short *row;
    unsigned short lmask, rmask;
    long nxln, g0, g1, ngroups, yy;
    short planes, npairs, k;

    if (w <= 0 || h <= 0)
        return 1;
    if (((x + w - 1) >> 4) - (x >> 4) + 1 > MAX_GROUPS)
        return 0;
    planes = wk->screen.mfdb.bitplanes;
    if (planes != 2 && planes != 4 && planes != 8)
        return 0;
    npairs = planes / 2;
    nxln = wk->screen.wrap;

    colour_longs(colour, npairs, F);
    UNROLL
    for (k = 0; k < npairs; k++)
    {
        B[k] = mode == 4 ? F[k] : 0;
        X[k] = F[k] ^ B[k];
    }

    g0 = x >> 4;
    g1 = (x + w - 1) >> 4;
    ngroups = g1 - g0 + 1;
    lmask = 0xffff >> (x & 15);
    rmask = 0xffff << (15 - ((x + w - 1) & 15));
    if (ngroups == 1)
        lmask &= rmask;

    row = (unsigned short *) ((char *) wk->screen.mfdb.address + y * nxln) + g0 * planes;

    for (yy = y; yy < y + h; yy++)
    {
        unsigned short ab[MAX_GROUPS];
        unsigned short bits = (unsigned short) pattern[yy & 15];
        long g;

        if (ngroups > 2 && (mode == 1 || (mode == 2 && bits == 0xffff)))
        {
            /* the same 16 pixels all along the line: compute them once */
            unsigned long m = bits * 0x10001UL, v0, v1, v2, v3;
            unsigned long *d = (unsigned long *) row;

            v0 = B[0] ^ (m & X[0]);
            v1 = npairs > 1 ? B[1] ^ (m & X[1]) : 0;
            v2 = npairs > 2 ? B[2] ^ (m & X[2]) : 0;
            v3 = npairs > 2 ? B[3] ^ (m & X[3]) : 0;
            put_group(d, bits, lmask, mode, F, B, X, npairs);
            d += npairs;
            g = ngroups - 2;
            switch (npairs)
            {
            case 4:
                for (; g > 0; g--)
                {
                    d[0] = v0;
                    d[1] = v1;
                    d[2] = v2;
                    d[3] = v3;
                    d += 4;
                }
                break;
            case 2:
                for (; g > 0; g--)
                {
                    d[0] = v0;
                    d[1] = v1;
                    d += 2;
                }
                break;
            default:
                for (; g > 0; g--)
                    *d++ = v0;
                break;
            }
            put_group(d, bits, rmask, mode, F, B, X, npairs);
            row = (unsigned short *) ((char *) row + nxln);
            continue;
        }

        for (g = 0; g < ngroups; g++)
            ab[g] = bits;

        switch (npairs)
        {
        case 4:
            row_8((unsigned long *) row, ab, ngroups, lmask, rmask, mode, F, B, X);
            break;
        case 2:
            row_4((unsigned long *) row, ab, ngroups, lmask, rmask, mode, F, B, X);
            break;
        default:
            row_2((unsigned long *) row, ab, ngroups, lmask, rmask, mode, F, B, X);
            break;
        }
        row = (unsigned short *) ((char *) row + nxln);
    }

    return 1;
}

/* a source or destination form: the screen when the MFDB is 0 or has
 * no address */
static unsigned short *
form_of(Workstation *wk, MFDB *mfdb, short *planes, long *nxln)
{
    return dest_form(wk, mfdb, planes, nxln);
}

/* copy n longs, forwards or backwards (overlapping areas) */
static void
copy_longs(unsigned long *d, const unsigned long *s, long n, short backwards)
{
    if (!backwards)
    {
        for (; n >= 4; n -= 4)
        {
            d[0] = s[0];
            d[1] = s[1];
            d[2] = s[2];
            d[3] = s[3];
            d += 4;
            s += 4;
        }
        while (--n >= 0)
            *d++ = *s++;
    } else
    {
        d += n;
        s += n;
        for (; n >= 4; n -= 4)
        {
            d -= 4;
            s -= 4;
            d[3] = s[3];
            d[2] = s[2];
            d[1] = s[1];
            d[0] = s[0];
        }
        while (--n >= 0)
            *--d = *--s;
    }
}

/*
 * Copy of a rectangle (already clipped) in replace mode (S_ONLY)
 * between two interleaved forms with the same number of planes, the
 * screen included.  Overlaps are handled: lines go up when the copy
 * goes down, groups go right to left when it goes right on the same
 * lines.
 *  - aligned (same position inside 16 pixels): the groups between the
 *    edges are one contiguous block per line, copied as longs;
 *  - otherwise each destination group is built from two source groups,
 *    the source group just read being kept for the next one.
 */
long
fast_blit(Workstation *wk, MFDB *src, long src_x, long src_y,
          MFDB *dst, long dst_x, long dst_y, long w, long h)
{
    unsigned short *sform, *dform;
    long snxln, dnxln, g0, g1, ngroups, delta, q, sfirst, slast;
    long y, ystep;
    unsigned short lmask, rmask;
    short planes, dplanes, sh, p, rtl;

    if (w <= 0 || h <= 0)
        return 1;
    sform = form_of(wk, src, &planes, &snxln);
    dform = form_of(wk, dst, &dplanes, &dnxln);
    if (planes != dplanes || (planes != 2 && planes != 4 && planes != 8))
        return 0;

    g0 = dst_x >> 4;
    g1 = (dst_x + w - 1) >> 4;
    ngroups = g1 - g0 + 1;
    lmask = 0xffff >> (dst_x & 15);
    rmask = 0xffff << (15 - ((dst_x + w - 1) & 15));
    if (ngroups == 1)
        lmask &= rmask;

    /* destination group g takes its pixels from source pixel
     * 16 g + delta: source group g + q, shifted left by sh, and the
     * start of group g + q + 1 */
    delta = src_x - dst_x;
    sh = (short) (delta & 15);
    q = (delta - sh) / 16;
    sfirst = src_x >> 4;                /* source groups that may be read */
    slast = (src_x + w - 1) >> 4;

    y = 0;
    ystep = 1;
    if (sform == dform && dst_y > src_y)
    {
        y = h - 1;
        ystep = -1;
    }
    rtl = sform == dform && dst_y == src_y && dst_x > src_x;

    for (; y >= 0 && y < h; y += ystep)
    {
        unsigned short *srow = (unsigned short *) ((char *) sform + (src_y + y) * snxln);
        unsigned short *drow = (unsigned short *) ((char *) dform + (dst_y + y) * dnxln);

        if (sh == 0)
        {
            unsigned short *s = srow + (g0 + q) * planes;
            unsigned short *d = drow + g0 * planes;
            unsigned short *se = s + (ngroups - 1) * planes;
            unsigned short *de = d + (ngroups - 1) * planes;
            unsigned short sl[8], sr[8];

            /* read both edges before anything is written */
            for (p = 0; p < planes; p++)
            {
                sl[p] = s[p];
                sr[p] = se[p];
            }
            if (ngroups > 2)
                copy_longs((unsigned long *) (d + planes), (unsigned long *) (s + planes),
                           (ngroups - 2) * planes / 2, rtl);
            for (p = 0; p < planes; p++)
                d[p] = (d[p] & ~lmask) | (sl[p] & lmask);
            if (ngroups > 1)
                for (p = 0; p < planes; p++)
                    de[p] = (de[p] & ~rmask) | (sr[p] & rmask);
        } else
        {
            unsigned short a[8], b[8];
            long g, sg;
            short rsh = 16 - sh;

            if (!rtl)
            {
                unsigned short *d = drow + g0 * planes;

                sg = g0 + q;
                for (p = 0; p < planes; p++)
                    a[p] = (sg >= sfirst && sg <= slast) ? srow[sg * planes + p] : 0;
                for (g = 0; g < ngroups; g++, sg++)
                {
                    unsigned short e = g == 0 ? lmask : (g == ngroups - 1 ? rmask : 0xffff);

                    if (sg + 1 >= sfirst && sg + 1 <= slast)
                    {
                        unsigned short *sp = srow + (sg + 1) * planes;

                        for (p = 0; p < planes; p++)
                            b[p] = sp[p];
                    } else
                        for (p = 0; p < planes; p++)
                            b[p] = 0;
                    if (e == 0xffff)
                        for (p = 0; p < planes; p++)
                            d[p] = (unsigned short) ((a[p] << sh) | (b[p] >> rsh));
                    else
                        for (p = 0; p < planes; p++)
                            d[p] = (d[p] & ~e) | ((unsigned short) ((a[p] << sh) | (b[p] >> rsh)) & e);
                    for (p = 0; p < planes; p++)
                        a[p] = b[p];
                    d += planes;
                }
            } else
            {
                /* right to left: group g needs source groups g + q and
                 * g + q + 1, the latter read by the previous step */
                unsigned short *d = drow + g1 * planes;

                sg = g1 + q;
                for (p = 0; p < planes; p++)
                    b[p] = (sg + 1 >= sfirst && sg + 1 <= slast) ? srow[(sg + 1) * planes + p] : 0;
                for (g = ngroups - 1; g >= 0; g--, sg--)
                {
                    unsigned short e = g == 0 ? lmask : (g == ngroups - 1 ? rmask : 0xffff);

                    if (sg >= sfirst && sg <= slast)
                    {
                        unsigned short *sp = srow + sg * planes;

                        for (p = 0; p < planes; p++)
                            a[p] = sp[p];
                    } else
                        for (p = 0; p < planes; p++)
                            a[p] = 0;
                    for (p = 0; p < planes; p++)
                        d[p] = (d[p] & ~e) | ((unsigned short) ((a[p] << sh) | (b[p] >> rsh)) & e);
                    for (p = 0; p < planes; p++)
                        b[p] = a[p];
                    d -= planes;
                }
            }
        }
    }

    return 1;
}
