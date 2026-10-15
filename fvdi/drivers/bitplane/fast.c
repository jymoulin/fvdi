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

#if defined(__mc68020__) || defined(__mc68030__) || defined(__mc68040__) || defined(__mc68060__)
#define FAST_ASM 1

/* fastexp.S */
typedef void rows_func(unsigned long *d, const unsigned short *s, long h, long n,
                       long dnxln, long snxln, const unsigned long *c, long mode,
                       unsigned long lmask, unsigned long rmask);
rows_func fast4_rows, fast8_rows;
void fast4s_rows(unsigned long *d, const unsigned short *s, long h, long n,
                 long dnxln, long snxln, const unsigned long *c, long mode,
                 unsigned long lmask, unsigned long rmask, long shf);
void CDECL bp_expand(Virtual *vwk, MFDB *src, long src_x, long src_y, MFDB *dst, long dst_x,
                     long dst_y, long w, long h, long operation, long colour); /* registers */
void shift_rows(unsigned short *q, const unsigned short *s, long h, long n,
                long snxln, long sh, long flags);

/* fastfill.S */
typedef void fill_func(unsigned long *d, long h, long nmid, long nxln,
                       const unsigned long *c, const short *pat, long py,
                       unsigned long lmask, unsigned long rmask);
fill_func fill_solid4, fill_solid8, fill_pat4, fill_pat8;

/* fastblit.S */
void blit_copy(unsigned long *d, const unsigned long *s, long h, long nmid,
               long dnxln, long snxln, long np,
               unsigned long lmask, unsigned long rmask);
typedef void shift_func(unsigned long *d, const unsigned long *s, long h, long nmid,
                        long dnxln, long snxln, long sh, long flags,
                        unsigned long lmask, unsigned long rmask);
shift_func blit_shift4, blit_shift8;

/* fastline.S */
typedef void line_func(void *adr, unsigned long bit, long n, long eps, long e1, long e2,
                       long xinc, long yinc, const unsigned long *c, long flags);
line_func line_draw4, line_draw8;
long CDECL bp_line(Virtual *vwk, DrvLine *pars);   /* register interface */

/* the members bp_line reads */
#define OFF(t, m) __builtin_offsetof(t, m)
_Static_assert(OFF(Virtual, real_address) == 0 && OFF(Virtual, clip.rectangle.x1) == 92 &&
               OFF(Virtual, clip.rectangle.y1) == 94 && OFF(Virtual, clip.rectangle.x2) == 96 &&
               OFF(Virtual, clip.rectangle.y2) == 98, "bp_line: Virtual layout");
_Static_assert(OFF(Workstation, screen.mfdb.address) == 24 && OFF(Workstation, screen.mfdb.bitplanes) == 36 &&
               OFF(Workstation, screen.wrap) == 44, "bp_line: Workstation layout");

/* a pattern with every bit set (the patterns are word aligned, and
 * the 68020+ reads longs at any even address) */
typedef unsigned long __attribute__((may_alias)) alias_long;

static int
solid_pattern(const short *pattern)
{
    const alias_long *p = (const alias_long *) pattern;

    return (p[0] & p[1] & p[2] & p[3] & p[4] & p[5] & p[6] & p[7]) == 0xffffffffUL;
}
#endif
#ifndef FAST_ASM
#define FAST_ASM 0
#endif

/* the pen of each VDI colour index (x_get_colour), for the assembler */
unsigned char bp_pen[256];

/*
 * Once the screen is known: the pen table, and the entries that take
 * the engine's registers directly instead of going through the C glue
 * of drivers/common (only where that glue was chosen, A_LINE on).
 */
void
fast_setup(Workstation *wk)
{
    short i;

    for (i = 0; i < 256; i++)
        bp_pen[i] = (unsigned char) x_get_colour(wk, i);
#if FAST_ASM
    if (wk->r.line == c_line)
        wk->r.line = bp_line;
    if (wk->r.expand == c_expand)
        wk->r.expand = bp_expand;
#endif
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

#if FAST_ASM
/*
 * 4 or 8 planes, replace or transparent mode, source words aligned on
 * the destination groups.  Everything that does not change from one
 * line to the next is set up once; the lines are done by the assembler
 * loops, edges included.
 */
static void
expand_rows(unsigned long *d, const unsigned short *s, long h, long ngroups,
            long dnxln, long snxln, unsigned short lmask, unsigned short rmask,
            long mode, short npairs,
            const unsigned long *F, const unsigned long *B, const unsigned long *X)
{
    unsigned long c[8], xall = 0xffffffffUL, ball = 0, fall = 0xffffffffUL, fany = 0;
    long m = mode;
    short k;

    for (k = 0; k < 4; k++)
    {
        c[k] = k < npairs ? (mode == 1 ? X[k] : F[k]) : 0;
        c[k + 4] = k < npairs ? B[k] : 0;
    }
    for (k = 0; k < npairs; k++)
    {
        xall &= X[k];
        ball |= B[k];
        fall &= F[k];
        fany |= F[k];
    }
    /* the common colours need less work per group */
    if (mode == 1 && xall == 0xffffffffUL && ball == 0)
        m = 5;
    else if (mode == 2 && fall == 0xffffffffUL)
        m = 6;
    else if (mode == 2 && fany == 0)
        m = 7;
    (npairs == 4 ? fast8_rows : fast4_rows)(d, s, h, ngroups, dnxln, snxln, c, m,
                                            lmask * 0x10001UL, rmask * 0x10001UL);
}

/* a shifted source is aligned in here first, a band of lines at a time */
#define ABUF_WORDS 2048
#endif

#if FAST_ASM
/* the colour long of two planes from their two pen bits */
static const unsigned long pair_long[4] = { 0, 0xffff0000UL, 0x0000ffffUL, 0xffffffffUL };

/*
 * 4 planes, replace or transparent mode, a source at any position: the
 * whole rectangle (clipped, w and h > 0) in one assembler call, with
 * the set-up kept short since icons are small.  drow and srow are the
 * first destination and source lines, fg and bg pens.  bold (the text
 * buffer of c_text_area only) also sets each pixel's right neighbour:
 * the word before the source rectangle and the one after it are read.
 */
static void
expand4(unsigned short *drow, long dnxln, const unsigned short *srow, long snxwd,
        long src_x, long dst_x, long w, long h, long mode, short fg, short bg, short bold)
{
    unsigned long c[8], f0, f1, b0, b1, lm, rm;
    unsigned long *d = (unsigned long *) drow + (dst_x >> 4) * 2;
    long n = ((dst_x + w - 1) >> 4) - (dst_x >> 4) + 1;
    long s0 = src_x - (dst_x & 15);
    long sh = s0 & 15, wbase = s0 >> 4, m = mode;

    lm = 0xffffU >> (dst_x & 15);
    rm = (unsigned short) (0xffffU << (15 - ((dst_x + w - 1) & 15)));
    if (n == 1)
        lm &= rm;
    f0 = pair_long[fg & 3];
    f1 = pair_long[(fg >> 2) & 3];
    b0 = pair_long[bg & 3];
    b1 = pair_long[(bg >> 2) & 3];

    /* the layouts: fast4_rows X0 X1 . . B0 B1 (or F0 F1), fast4s_rows
     * X0 B0 X1 B1 (or F0 F1) */
    if (mode == 1)
    {
        c[0] = f0 ^ b0;
        c[1] = f1 ^ b1;
        c[4] = b0;
        c[5] = b1;
        if ((c[0] & c[1]) == 0xffffffffUL && (b0 | b1) == 0)
            m = 5;
    } else
    {
        c[0] = f0;
        c[1] = f1;
        if ((f0 & f1) == 0xffffffffUL)
            m = 6;
        else if ((f0 | f1) == 0)
            m = 7;
    }
    lm *= 0x10001UL;
    rm *= 0x10001UL;

    /* aligned: every source word is inside the rectangle */
    if (sh == 0 && !bold)
    {
        fast4_rows(d, srow + wbase, h, n, dnxln, snxwd * 2, c, m, lm, rm);
        return;
    }
    if (mode == 1)
    {
        c[2] = c[1];
        c[1] = c[4];
        c[3] = c[5];
    }
    if (bold)
    {
        /* the pixel left of each group comes out of the shift */
        if (sh == 0)
        {
            sh = 16;
            wbase--;
        }
        sh |= 0x700;
    } else
    {
        sh |= wbase == (src_x >> 4) ? 0x100 : 0;
        sh |= wbase + n <= (src_x + w - 1) >> 4 ? 0x200 : 0;
    }
    fast4s_rows(d, srow + wbase, h, n, dnxln, snxwd * 2, c, m, lm, rm, sh);
}

/*
 * vrt_cpyfm from the engine, through bp_expand (fastexp.S) which has
 * the engine's registers: a = VDI struct, destination MFDB, VDI struct,
 * source MFDB; the destination rectangle is clipped.  4 planes, replace
 * and transparent modes; returns 0 for everything else (c_expand).
 */
long CDECL bp_expand_c(void **a, long colours, short sx, short sy, short x1, short y1,
                       short x2, short y2, short mode);

long CDECL
bp_expand_c(void **a, long colours, short sx, short sy, short x1, short y1,
            short x2, short y2, short mode)
{
    Virtual *vwk = (Virtual *) ((long) a[0] & ~1L);
    MFDB *src = (MFDB *) a[3];
    unsigned short *dform;
    long dnxln, w = x2 - x1 + 1, h = y2 - y1 + 1;
    short planes;

    mode = ((mode - 1) & 3) + 1;
    if (mode > 2 || !src || !src->address || src->bitplanes != 1 || w <= 0 || h <= 0)
        return 0;
    dform = dest_form(vwk->real_address, (MFDB *) a[1], &planes, &dnxln);
    if (planes != 4)
        return 0;
    expand4((unsigned short *) ((char *) dform + y1 * dnxln), dnxln,
            (unsigned short *) src->address + sy * src->wdwidth, src->wdwidth,
            sx, x1, w, h, mode, bp_pen[colours & 0xff], bp_pen[(colours >> 16) & 0xff], 0);
    return 1;
}
#endif

static long expand_general(Workstation *wk, MFDB *src, long src_x, long src_y,
                           MFDB *dst, long dst_x, long dst_y, long w, long h,
                           long mode, unsigned long fg, unsigned long bg) __attribute__((noinline));

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
#if FAST_ASM
    if ((mode == 1 || mode == 2) && src && src->address && src->bitplanes == 1 && w > 0 && h > 0)
    {
        unsigned short *dform;
        long dnxln;
        short planes;

        dform = dest_form(wk, dst, &planes, &dnxln);
        if (planes == 4)
        {
            expand4((unsigned short *) ((char *) dform + dst_y * dnxln), dnxln,
                    (unsigned short *) src->address + src_y * src->wdwidth, src->wdwidth,
                    src_x, dst_x, w, h, mode, (short) fg, (short) bg, 0);
            return 1;
        }
    }
#endif
    return expand_general(wk, src, src_x, src_y, dst, dst_x, dst_y, w, h, mode, fg, bg);
}

static long
expand_general(Workstation *wk, MFDB *src, long src_x, long src_y,
               MFDB *dst, long dst_x, long dst_y, long w, long h,
               long mode, unsigned long fg, unsigned long bg)
{
    unsigned long F[4], B[4], X[4];
    unsigned short *dform, *srow;
    unsigned short lmask, rmask;
    long dnxln, snxwd;
    long g0, g1, ngroups, y;
    long s0, wfirst, wlast, wbase;
    short planes, npairs, sh, k, direct;

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

    /* no shift and every word inside the source (text rendered at the
     * destination's position): the source line is used as it is */
    direct = sh == 0 && wbase >= wfirst && wbase + ngroups - 1 <= wlast;

#if FAST_ASM
    if ((planes == 4 || planes == 8) && (mode == 1 || mode == 2))
    {
        static unsigned short abuf[ABUF_WORDS];
        long lines, y0;

        if (direct)
        {
            expand_rows((unsigned long *) dform, srow + wbase, h, ngroups, dnxln, snxwd * 2,
                        lmask, rmask, mode, npairs, F, B, X);
            return 1;
        }
        lines = ABUF_WORDS / ngroups;
        for (y0 = 0; y0 < h; y0 += lines)
        {
            long n = h - y0 < lines ? h - y0 : lines, flags = 0;

            /* the words in between are always inside the source */
            if (wbase >= wfirst && wbase <= wlast)
                flags |= 1;
            if (wbase + ngroups >= wfirst && wbase + ngroups <= wlast)
                flags |= 2;
            shift_rows(abuf, srow + y0 * snxwd + wbase, n, ngroups, snxwd * 2, sh, flags);
            expand_rows((unsigned long *) ((char *) dform + y0 * dnxln), abuf, n, ngroups,
                        dnxln, ngroups * 2, lmask, rmask, mode, npairs, F, B, X);
        }
        return 1;
    }
#endif

    for (y = 0; y < h; y++)
    {
        unsigned short abuf[MAX_GROUPS];
        const unsigned short *ab = abuf;
        long g, wi = wbase;
        unsigned long acc;

        if (direct)
            ab = srow + wbase;
        else
        {
            /* the source bits of each group, aligned on the destination;
             * words outside the source rectangle read as 0 */
            acc = (wi >= wfirst && wi <= wlast) ? srow[wi] : 0;
            for (g = 0; g < ngroups; g++)
            {
                wi++;
                acc = (acc << 16) | ((wi >= wfirst && wi <= wlast) ? srow[wi] : 0);
                abuf[g] = (unsigned short) ((acc << sh) >> 16);
            }
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

#if FAST_ASM
    /* replace mode, or a solid transparent one (the same thing): the
     * whole rectangle in assembler */
    if ((planes == 4 || planes == 8) && (mode == 1 || mode == 2))
    {
        short solid = solid_pattern(pattern);

        if (solid || mode == 1)
        {
            unsigned long c[4] = { 0, 0, 0, 0 };
            unsigned short lm, rm;

            g0 = x >> 4;
            ngroups = ((x + w - 1) >> 4) - g0 + 1;
            lm = 0xffff >> (x & 15);
            rm = 0xffff << (15 - ((x + w - 1) & 15));
            if (ngroups == 1)
                lm &= rm;
            colour_longs(colour, npairs, c);
            (planes == 4 ? (solid ? fill_solid4 : fill_pat4) : (solid ? fill_solid8 : fill_pat8))
                ((unsigned long *) ((char *) wk->screen.mfdb.address + y * nxln) + g0 * npairs,
                 h, ngroups - 2, nxln, c, pattern, y, lm * 0x10001UL, rm * 0x10001UL);
            return 1;
        }
    }
#endif

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

#if FAST_ASM
    /* left to right on each line: the whole rectangle in assembler */
    if (!rtl && (planes == 4 || planes == 8))
    {
        unsigned short *s = (unsigned short *) ((char *) sform + (src_y + y) * snxln) + (g0 + q) * planes;
        unsigned short *d = (unsigned short *) ((char *) dform + (dst_y + y) * dnxln) + g0 * planes;
        long sn = ystep * snxln, dn = ystep * dnxln;

        if (sh == 0)
            blit_copy((unsigned long *) d, (const unsigned long *) s, h, ngroups - 2,
                      dn, sn, planes / 2, lmask * 0x10001UL, rmask * 0x10001UL);
        else
        {
            long flags = 0;

            if (g0 + q >= sfirst && g0 + q <= slast)
                flags |= 1;
            if (g1 + q + 1 >= sfirst && g1 + q + 1 <= slast)
                flags |= 2;
            (planes == 4 ? blit_shift4 : blit_shift8)((unsigned long *) d, (const unsigned long *) s,
                h, ngroups - 2, dn, sn, sh, flags, lmask * 0x10001UL, rmask * 0x10001UL);
        }
        return 1;
    }
#endif

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

/*
 * Text straight from the font to the screen, for the unpacked 8 pixel
 * wide fonts (the system fonts): the words of 16 pixels are put
 * together from the glyph bytes, already aligned on the destination,
 * and expanded by fast_expand.  This skips the engine's rendering
 * buffer (allocation, clearing, a second pass over the bits).
 * Effects, offset tables and other fonts are left to the engine
 * (return 0).
 */
#define TEXT_MAX_ROWS 16
#define TPITCH 260                      /* bytes per line of the text buffer */

#if FAST_ASM
/*
 * n (> 0) characters of a 16 line font, unpacked (16 bytes per
 * glyph, from data), into a column of bytes each of the buffer at q.
 * Returns 0, or -1 for a code outside the font.
 */
static long
glyphs16(unsigned char *q, const short *t, long n, const unsigned char *data,
         short low, short range)
{
    const unsigned char *p;
    long c;

    __asm__ volatile(
        "1:\n\t"
        "move.w  (%[t])+,%[c]\n\t"
        "sub.w   %[low],%[c]\n\t"
        "cmp.w   %[range],%[c]\n\t"
        "bhi.s   9f\n\t"
        "lsl.w   #4,%[c]\n\t"
        "lea     0(%[g],%[c].w),%[p]\n\t"
            "move.b  (%[p])+,0(%[q])\n\t"
            "move.b  (%[p])+,260(%[q])\n\t"
            "move.b  (%[p])+,520(%[q])\n\t"
            "move.b  (%[p])+,780(%[q])\n\t"
            "move.b  (%[p])+,1040(%[q])\n\t"
            "move.b  (%[p])+,1300(%[q])\n\t"
            "move.b  (%[p])+,1560(%[q])\n\t"
            "move.b  (%[p])+,1820(%[q])\n\t"
            "move.b  (%[p])+,2080(%[q])\n\t"
            "move.b  (%[p])+,2340(%[q])\n\t"
            "move.b  (%[p])+,2600(%[q])\n\t"
            "move.b  (%[p])+,2860(%[q])\n\t"
            "move.b  (%[p])+,3120(%[q])\n\t"
            "move.b  (%[p])+,3380(%[q])\n\t"
            "move.b  (%[p])+,3640(%[q])\n\t"
            "move.b  (%[p])+,3900(%[q])\n\t"
            "addq.l  #1,%[q]\n\t"
        "subq.l  #1,%[n]\n\t"
        "bne.s   1b\n\t"
        "moveq   #0,%[c]\n\t"
        "bra.s   8f\n"
        "9:\n\t"
        "moveq   #-1,%[c]\n"
        "8:"
        : [q] "+a" (q), [t] "+a" (t), [n] "+d" (n), [c] "=&d" (c), [p] "=&a" (p)
        : [g] "a" (data), [low] "d" (low), [range] "d" (range)
        : "cc", "memory");
    return c;
}
#endif

long CDECL c_text_area(Virtual *vwk, short *text, long length, long dst_x, long dst_y, short *offsets)
{
    static unsigned short buf[TEXT_MAX_ROWS * TPITCH / 2];
    Workstation *wk;
    Fontheader *font;
    const unsigned char *data;
    unsigned long fg, bg;
    long h, cx1, cy1, cx2, cy2, vx1, vx2, vy1, vy2;
    long g0, g1, ngroups, mode, sx;
    short low, high;
    MFDB src;
    short bold;

    vwk = (Virtual *) ((long) vwk & ~1);
    wk = vwk->real_address;
    font = vwk->text.current_font;
    /* bold alone, as the engine does it (one pixel), on 4 planes */
    bold = FAST_ASM && vwk->text.effects == 1;
    if ((vwk->text.effects && !bold) || offsets || !font)
        return 0;
    if (bold && (font->thickening != 1 || wk->screen.mfdb.bitplanes != 4 ||
                 (vwk->mode != 1 && vwk->mode != 2)))
        return 0;
    data = (const unsigned char *) font->extra.unpacked.data;
    if (!data || font->widest.cell != 8 || font->height > TEXT_MAX_ROWS)
        return 0;
    if (wk->screen.mfdb.bitplanes != 8 && wk->screen.mfdb.bitplanes != 4 &&
        wk->screen.mfdb.bitplanes != 2)
        return 0;
    if (length <= 0)
        return 1;

    dst_y += (&font->extra.distance.base)[vwk->text.alignment.vertical];
    h = font->height;

    /* clipping, and the screen */
    cx1 = 0;
    cy1 = 0;
    cx2 = wk->screen.mfdb.width - 1;
    cy2 = wk->screen.mfdb.height - 1;
    if (vwk->clip.on)
    {
        if (vwk->clip.rectangle.x1 > cx1) cx1 = vwk->clip.rectangle.x1;
        if (vwk->clip.rectangle.y1 > cy1) cy1 = vwk->clip.rectangle.y1;
        if (vwk->clip.rectangle.x2 < cx2) cx2 = vwk->clip.rectangle.x2;
        if (vwk->clip.rectangle.y2 < cy2) cy2 = vwk->clip.rectangle.y2;
    }
    vx1 = dst_x > cx1 ? dst_x : cx1;
    vx2 = dst_x + length * 8 - 1 < cx2 ? dst_x + length * 8 - 1 : cx2;
    vy1 = dst_y > cy1 ? dst_y : cy1;
    vy2 = dst_y + h - 1 < cy2 ? dst_y + h - 1 : cy2;
    if (vx1 > vx2 || vy1 > vy2)
        return 1;

    g0 = vx1 >> 4;
    g1 = vx2 >> 4;
    ngroups = g1 - g0 + 1;
    if (ngroups > MAX_GROUPS)
        return 0;

    low = font->code.low;
    high = font->code.high;

    /* The glyph bytes are copied into a monochrome buffer, a column of
     * bytes per character; the buffer starts one word before group g0.
     * Character j starts at pixel base + 8 j of the buffer; when base
     * is not a multiple of 8 the characters are put o pixels too far
     * left, at byte (base - o) / 8 + j, and taken o pixels further left
     * in the buffer by the expansion. */
    {
        long base = dst_x - 16 * g0 + 16, o, kb, used, nrows, r0, j, k, kend;
        unsigned char *b8 = (unsigned char *) buf;

        o = base & 7;
        kb = (base - o) / 8;
        used = 2 * (ngroups + 2);
        nrows = vy2 - vy1 + 1;
        r0 = vy1 - dst_y;
        if (used > TPITCH)
            return 0;

        /* the characters that land in the buffer, the rest cleared */
        j = kb < 0 ? -kb : 0;
        kend = kb + length < used ? kb + length : used;
        for (k = 0; k < nrows; k++)
        {
            unsigned char *line = b8 + k * TPITCH;
            long x;

            for (x = 0; x < kb + j; x++)
                line[x] = 0;
            for (x = kend; x < used; x++)
                line[x] = 0;
        }
#if FAST_ASM
        if (nrows == 16 && kb + j < kend)
        {
            if (glyphs16(b8 + kb + j, text + j, kend - kb - j, data, low, high - low))
                return 0;               /* the engine knows what to do */
        } else
#endif
        for (; kb + j < kend; j++)
        {
            short c = text[j];
            const unsigned char *gl;
            unsigned char *q = b8 + kb + j;

            if (c < low || c > high)
                return 0;
            gl = data + (long) (c - low) * 16 + r0;
            for (k = 0; k < nrows; k++)
                q[k * TPITCH] = gl[k];
        }

        /* the o pixels left over are the expansion's shift */
        sx = 16 + (vx1 & 15) - o;
    }

    c_get_colours(vwk, ((long) vwk->text.colour.background << 16) | (unsigned short) vwk->text.colour.foreground, &fg, &bg);
    mode = vwk->mode;
    if (mode == 4)
        bg = fg;                        /* as the TOS VDI does */

#if FAST_ASM
    if (bold)
    {
        expand4((unsigned short *) ((char *) wk->screen.mfdb.address + vy1 * wk->screen.wrap),
                wk->screen.wrap, buf, TPITCH / 2, sx, vx1, vx2 - vx1 + 1, vy2 - vy1 + 1,
                mode, (short) fg, (short) bg, 1);
        return 1;
    }
#endif

    src.address = (short *) buf;
    src.width = TPITCH * 8;
    src.height = vy2 - vy1 + 1;
    src.wdwidth = TPITCH / 2;
    src.standard = 0;
    src.bitplanes = 1;

    if (!fast_expand(wk, &src, sx, 0, 0, vx1, vy1, vx2 - vx1 + 1, vy2 - vy1 + 1,
                     mode, fg, bg))
        return 0;

    return 1;
}

/*
 * A solid line (no style), from line.c once it has the address of the
 * first pixel, its bit and the deltas (dx >= 0): two planes per long in
 * assembler, the same pixels as the C loops.  Returns 0 when not handled.
 */
long
fast_line(Workstation *wk, void *adr, unsigned short bit, long dx, long dy,
          long xinc, long yinc, long pattern, unsigned long colour, long mode)
{
#if FAST_ASM
    short planes = wk->screen.mfdb.bitplanes;
    unsigned long c[4] = { 0, 0, 0, 0 };
    long flags = 0, n, eps, e1, e2;
    short k;

    if ((planes != 4 && planes != 8) || (pattern & 0xffff) != 0xffff || mode < 1 || mode > 4)
        return 0;
    colour_longs(colour, planes / 2, c);
    if (mode == 4)                      /* 1 bits in the colour's complement */
        for (k = 0; k < 4; k++)
            c[k] = ~c[k];
    if (mode == 3)
        flags |= 2;
    if (dx >= dy)
    {
        n = dx;
        e1 = 2 * dy;
        eps = -dx;
        e2 = 2 * dx;
    } else
    {
        flags |= 1;
        n = dy;
        e1 = 2 * dx;
        eps = -dy;
        e2 = 2 * dy;
    }
    (planes == 4 ? line_draw4 : line_draw8)(adr, bit * 0x10001UL, n, eps, e1, e2,
                                            xinc, yinc, c, flags);
    return 1;
#else
    (void) wk; (void) adr; (void) bit; (void) dx; (void) dy;
    (void) xinc; (void) yinc; (void) pattern; (void) colour; (void) mode;
    return 0;
#endif
}

/*
 * A table of spans (y, x1, x2, already clipped), as the engine gives
 * for polygons, circles and ellipses: each span is one line of the
 * assembler fills, without going through c_fill_area for each.  Solid
 * fills in replace or transparent mode, pattern fills in replace mode.
 * Returns 0 when not handled.
 */
long
fast_spans(Workstation *wk, const short *s, long n, const short *pattern,
           unsigned long colour, long mode)
{
#if FAST_ASM
    short planes = wk->screen.mfdb.bitplanes, npairs, solid;
    unsigned long c[4] = { 0, 0, 0, 0 };
    long nxln = wk->screen.wrap;
    char *base = (char *) wk->screen.mfdb.address;
    fill_func *f;

    if ((planes != 4 && planes != 8) || (mode != 1 && mode != 2))
        return 0;
    solid = solid_pattern(pattern);
    if (!solid && mode != 1)
        return 0;
    npairs = planes / 2;
    colour_longs(colour, npairs, c);
    f = planes == 4 ? (solid ? fill_solid4 : fill_pat4) : (solid ? fill_solid8 : fill_pat8);
    for (; n > 0; n--, s += 3)
    {
        long y = s[0], x1 = s[1], x2 = s[2], g0, ngroups;
        unsigned short lm, rm;

        if (x1 > x2)
            continue;
        g0 = x1 >> 4;
        ngroups = (x2 >> 4) - g0 + 1;
        lm = 0xffff >> (x1 & 15);
        rm = 0xffff << (15 - (x2 & 15));
        if (ngroups == 1)
            lm &= rm;
        f((unsigned long *) (base + y * nxln) + g0 * npairs, 1, ngroups - 2, nxln,
          c, pattern, y, lm * 0x10001UL, rm * 0x10001UL);
    }
    return 1;
#else
    (void) wk; (void) s; (void) n; (void) pattern; (void) colour; (void) mode;
    return 0;
#endif
}
