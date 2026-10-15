/*
 * 4 and 8 interleaved planes: monochrome to colour expansion (text,
 * icons) from a source already aligned on the destination, whole lines
 * in one call.
 *
 * void fast4_rows(unsigned long *d, const unsigned short *s, long h,
 *                 long n, long dnxln, long snxln,
 *                 const unsigned long *c, long mode,
 *                 unsigned long lmask, unsigned long rmask)
 * void fast8_rows(... the same ...)
 *
 *   d, s    first group of the first line, its source word
 *   h, n    lines (> 0), groups per line (> 0)
 *   dnxln, snxln  bytes from one line to the next
 *   lmask, rmask  pixels of the first and last group that may change,
 *           in both halves (for n == 1, lmask holds both edges)
 *   c, mode (np = 2 longs per group with 4 planes, 4 with 8 planes)
 *     1 replace: c = X0 X1 X2 X3 B0 B1 B2 B3, each long k of a group
 *       becoming Bk ^ (m & Xk), m being the source word in both halves
 *     2 transparent: c = F0 F1 F2 F3, each long d ^ ((d ^ F) & m)
 *     5 replace, colour with all planes set on colour 0: each long is m
 *     6 transparent, colour with all planes set: d | m
 *     7 transparent, colour 0: d & ~m
 *
 * Edges: with an edge mask e, a long becomes d ^ ((d ^ new) & e); in
 * the transparent modes this is just m & e as the source.
 *
 * void shift_rows(unsigned short *q, const unsigned short *s, long h,
 *                 long n, long snxln, long sh, long flags)
 *   Aligns a monochrome source on the destination groups, into q (n
 *   words per line): word g of a line is (S[g] << sh) | (S[g+1] >>
 *   (16 - sh)), s pointing to S[0] of the first line.  flags bit 0:
 *   S[0] may be read (it is outside the source rectangle otherwise, and
 *   taken as 0), bit 1: the same for S[n].
 *
 * This software is licensed under the GNU General Public License.
 * Please, see LICENSE.TXT for further information.
 */

	.text
	.globl	_fast4_rows
	.globl	_fast8_rows
	.globl	_shift_rows

#define D	48(%sp)
#define S	52(%sp)
#define H	56(%sp)
#define N	60(%sp)
#define DNXLN	64(%sp)
#define SNXLN	68(%sp)
#define C	72(%sp)
#define MODE	76(%sp)
#define LMASK	80(%sp)
#define RMASK	84(%sp)

| d0 = the next source word in both halves (d1 is used)
.macro	getm
	move.w	(%a1)+,%d0
	move.w	%d0,%d1
	swap	%d0
	move.w	%d1,%d0
.endm

| a line: left edge \le, middle groups \mid, right edge \re
| a0 = line start, a1 = source, a3 = end of the middle groups
.macro	line le, mid, re, name
\name\()line:
	move.l	%a4,%a0
	move.l	%a5,%a1
	\le	LMASK
	cmp.l	#1,N
	beq	\name\()next
	lea	(%a0,%a6.l),%a3
	cmp.l	%a3,%a0
	beq	\name\()right
\name\()mid:
	\mid
	cmp.l	%a3,%a0
	bne	\name\()mid
\name\()right:
	\re	RMASK
\name\()next:
	add.l	DNXLN,%a4
	add.l	SNXLN,%a5
	subq.l	#1,H
	bne	\name\()line
	bra	done
.endm

| ---- 1: replace, any colours ------------------------------------------
| X0 B0 X1 B1 in d2-d5; with 8 planes X2 B2 in d6/d7, X3 B3 in memory

.macro	rep_mid np
	getm
	move.l	%d0,%d1
	and.l	%d2,%d1
	eor.l	%d3,%d1
	move.l	%d1,(%a0)+
	.if	\np == 4
	move.l	%d0,%d1
	and.l	%d4,%d1
	eor.l	%d5,%d1
	move.l	%d1,(%a0)+
	move.l	%d0,%d1
	and.l	%d6,%d1
	eor.l	%d7,%d1
	move.l	%d1,(%a0)+
	and.l	12(%a2),%d0
	move.l	28(%a2),%d1
	eor.l	%d1,%d0
	move.l	%d0,(%a0)+
	.else
	and.l	%d4,%d0
	eor.l	%d5,%d0
	move.l	%d0,(%a0)+
	.endif
.endm

| one long of an edge: d1 = new, merged under the mask; m is reloaded
.macro	rep_edge_long x, b, mask
	move.l	%d0,%d1
	and.l	\x,%d1
	eor.l	\b,%d1
	move.l	(%a0),%d0
	eor.l	%d0,%d1
	and.l	\mask,%d1
	eor.l	%d1,(%a0)+
	move.w	-2(%a1),%d0
	move.w	%d0,%d1
	swap	%d0
	move.w	%d1,%d0
.endm

.macro	rep_edge4 mask
	getm
	rep_edge_long %d2, %d3, \mask
	rep_edge_long %d4, %d5, \mask
	rep_edge_long %d6, %d7, \mask
	and.l	12(%a2),%d0
	move.l	28(%a2),%d1
	eor.l	%d0,%d1			| d1 = new
	move.l	(%a0),%d0
	eor.l	%d0,%d1
	and.l	\mask,%d1
	eor.l	%d1,(%a0)+
.endm

.macro	rep_edge2 mask
	getm
	rep_edge_long %d2, %d3, \mask
	and.l	%d4,%d0
	move.l	%d5,%d1
	eor.l	%d0,%d1			| d1 = new
	move.l	(%a0),%d0
	eor.l	%d0,%d1
	and.l	\mask,%d1
	eor.l	%d1,(%a0)+
.endm

.macro	rep_mid4
	rep_mid	4
.endm
.macro	rep_mid2
	rep_mid	2
.endm

| ---- 2: transparent, any colour: F0..F3 in d2-d5 -----------------------

.macro	tr_long f
	move.l	(%a0),%d1
	eor.l	\f,%d1
	and.l	%d0,%d1
	eor.l	%d1,(%a0)+
.endm

.macro	tr_body np
	tr_long	%d2
	tr_long	%d3
	.if	\np == 4
	tr_long	%d4
	tr_long	%d5
	.endif
.endm

.macro	tr_mid np
	getm
	tst.l	%d0
	beq.s	8f
	tr_body	\np
	bra.s	9f
8:	lea	4*\np(%a0),%a0
9:
.endm

.macro	tr_edge np, mask
	getm
	and.l	\mask,%d0
	tr_body	\np
.endm

.macro	tr_mid4
	tr_mid	4
.endm
.macro	tr_mid2
	tr_mid	2
.endm
.macro	tr_edge4 mask
	tr_edge	4, \mask
.endm
.macro	tr_edge2 mask
	tr_edge	2, \mask
.endm

| ---- 5: replace, all planes set on colour 0 ----------------------------

.macro	pl_mid np
	getm
	.rept	\np
	move.l	%d0,(%a0)+
	.endr
.endm

.macro	pl_edge np, mask
	getm
	move.l	\mask,%d2
	.rept	\np
	move.l	(%a0),%d1
	eor.l	%d0,%d1
	and.l	%d2,%d1
	eor.l	%d1,(%a0)+
	.endr
.endm

.macro	pl_mid4
	pl_mid	4
.endm
.macro	pl_mid2
	pl_mid	2
.endm
.macro	pl_edge4 mask
	pl_edge	4, \mask
.endm
.macro	pl_edge2 mask
	pl_edge	2, \mask
.endm

| ---- 6: transparent, all planes set ------------------------------------

.macro	se_mid np
	getm
	.rept	\np
	or.l	%d0,(%a0)+
	.endr
.endm

.macro	se_edge np, mask
	getm
	and.l	\mask,%d0
	.rept	\np
	or.l	%d0,(%a0)+
	.endr
.endm

.macro	se_mid4
	se_mid	4
.endm
.macro	se_mid2
	se_mid	2
.endm
.macro	se_edge4 mask
	se_edge	4, \mask
.endm
.macro	se_edge2 mask
	se_edge	2, \mask
.endm

| ---- 7: transparent, all planes cleared --------------------------------

.macro	cl_mid np
	getm
	not.l	%d0
	.rept	\np
	and.l	%d0,(%a0)+
	.endr
.endm

.macro	cl_edge np, mask
	getm
	and.l	\mask,%d0
	not.l	%d0
	.rept	\np
	and.l	%d0,(%a0)+
	.endr
.endm

.macro	cl_mid4
	cl_mid	4
.endm
.macro	cl_mid2
	cl_mid	2
.endm
.macro	cl_edge4 mask
	cl_edge	4, \mask
.endm
.macro	cl_edge2 mask
	cl_edge	2, \mask
.endm

| ---- the two functions -------------------------------------------------

.macro	rows np, name
	movem.l	%d2-%d7/%a2-%a6,-(%sp)
	move.l	D,%a4			| line starts
	move.l	S,%a5
	move.l	N,%d0
	subq.l	#2,%d0
	bpl.s	1f
	moveq	#0,%d0
1:	lsl.l	#2+\np/2,%d0
	move.l	%d0,%a6			| bytes of middle groups per line
	move.l	C,%a2
	move.l	MODE,%d0
	cmp.l	#5,%d0
	beq	\name\()p
	cmp.l	#6,%d0
	beq	\name\()s
	cmp.l	#7,%d0
	beq	\name\()c
	cmp.l	#2,%d0
	beq	\name\()t

	move.l	(%a2),%d2		| X0
	move.l	16(%a2),%d3		| B0
	move.l	4(%a2),%d4		| X1
	move.l	20(%a2),%d5		| B1
	.if	\np == 4
	move.l	8(%a2),%d6		| X2
	move.l	24(%a2),%d7		| B2
	.endif
	line	rep_edge\np, rep_mid\np, rep_edge\np, \name\()r

\name\()t:
	movem.l	(%a2),%d2-%d5		| F0..F3
	line	tr_edge\np, tr_mid\np, tr_edge\np, \name\()t

\name\()p:
	line	pl_edge\np, pl_mid\np, pl_edge\np, \name\()p

\name\()s:
	line	se_edge\np, se_mid\np, se_edge\np, \name\()s

\name\()c:
	line	cl_edge\np, cl_mid\np, cl_edge\np, \name\()c
.endm

_fast8_rows:
	rows	4, e8
_fast4_rows:
	rows	2, e4

done:
	movem.l	(%sp)+,%d2-%d7/%a2-%a6
	rts

| d2 = n - 1, d3 = sh, d4 = the source words S[g]:S[g+1], d6 = flags,
| d7 = lines left, a0 = source, a1 = q, a2 = line start, a3 = snxln
_shift_rows:
	movem.l	%d2-%d7/%a2-%a6,-(%sp)
	move.l	48(%sp),%a1
	move.l	52(%sp),%a2
	move.l	56(%sp),%d7
	move.l	60(%sp),%d2
	subq.l	#1,%d2
	move.l	64(%sp),%a3
	move.l	68(%sp),%d3
	move.l	72(%sp),%d6
1:	move.l	%a2,%a0
	moveq	#0,%d4
	btst	#0,%d6
	beq.s	2f
	move.w	(%a0),%d4
2:	addq.l	#2,%a0
	move.w	%d2,%d1
	beq.s	4f
	subq.w	#1,%d1
3:	swap	%d4
	move.w	(%a0)+,%d4
	move.l	%d4,%d5
	lsl.l	%d3,%d5
	swap	%d5
	move.w	%d5,(%a1)+
	dbra	%d1,3b
4:	swap	%d4
	clr.w	%d4
	btst	#1,%d6
	beq.s	5f
	move.w	(%a0),%d4
5:	lsl.l	%d3,%d4
	swap	%d4
	move.w	%d4,(%a1)+
	add.l	%a3,%a2
	subq.l	#1,%d7
	bne	1b
	bra	done

/*
 * void fast4s_rows(unsigned long *d, const unsigned short *s, long h,
 *                  long n, long dnxln, long snxln,
 *                  const unsigned long *c, long mode,
 *                  unsigned long lmask, unsigned long rmask, long shf)
 *
 * 4 planes, the source shifted on the fly: group g of a line takes
 * (S[g] << sh) | (S[g+1] >> (16 - sh)), s pointing to S[0] of the first
 * line (sh 1 to 16).  shf = sh | flag0 << 8 | flag1 << 9 | bold << 10:
 * S[0], S[n] may be read (they
 * are outside the source rectangle otherwise, taken as 0; S[1] to S[n-1]
 * always are inside).  The other arguments are those of fast4_rows,
 * except c: X0 B0 X1 B1 in replace mode, F0 F1 in transparent mode.
 * Words of the source that are 0 leave the screen alone in the
 * transparent modes.  Bold is the engine's one pixel thickening: each
 * source pixel also set on its right, across the groups.
 */
	.globl	_fast4s_rows

#define SHF	88(%sp)

| d0 = the source bits of the next group in both halves; d7 = the
| source window, its high word S[g] on entry, S[g+1] on exit
.macro	shiftm
	move.l	%d7,%d0
	lsl.l	%d6,%d0
	swap	%d7
	move.l	%d0,%d1
	swap	%d1
	move.w	%d1,%d0
.endm

| bold (one pixel of thickening): the pixel left of the group, the
| last bit shifted out (X), is or-ed in with the group shifted right
.macro	shiftmb
	move.l	%d7,%d0
	lsl.l	%d6,%d0
	swap	%d7
	move.l	%d0,%d1
	roxr.l	#1,%d1
	or.l	%d1,%d0
	move.l	%d0,%d1
	swap	%d1
	move.w	%d1,%d0
.endm

.macro	getms b
	move.w	(%a1)+,%d7
	.if	\b
	shiftmb
	.else
	shiftm
	.endif
.endm

| the last group of a line: S[n] only if it may be read
.macro	getlast b
	btst	#9,%d6
	beq.s	1f
	move.w	(%a1)+,%d7
	bra.s	2f
1:	clr.w	%d7
2:
	.if	\b
	shiftmb
	.else
	shiftm
	.endif
.endm

| the lines: left edge \le, middle groups \mid, right edge \re (d0
| holds the source bits when they are called), with the edge masks \lm
| and \rm and the line counter \cnt (registers where the mode leaves
| some free); lines of a single group have their own loop
.macro	sline le, mid, re, name, b, lm, rm, cnt
	cmp.l	#1,N
	beq	\name\()one
\name\()line:
	move.l	%a4,%a0
	move.l	%a5,%a1
	moveq	#0,%d7
	btst	#8,%d6
	beq.s	1f
	move.w	(%a1),%d7
	swap	%d7
1:	addq.l	#2,%a1
	getms	\b
	\le	\lm
	lea	(%a0,%a6.l),%a3
	cmp.l	%a3,%a0
	beq.s	\name\()right
\name\()mid:
	getms	\b
	\mid
	cmp.l	%a3,%a0
	bne.s	\name\()mid
\name\()right:
	getlast	\b
	\re	\rm
	add.l	DNXLN,%a4
	add.l	SNXLN,%a5
	subq.l	#1,\cnt
	bne	\name\()line
	bra	done
\name\()one:
	move.l	%a4,%a0
	move.l	%a5,%a1
	moveq	#0,%d7
	btst	#8,%d6
	beq.s	1f
	move.w	(%a1),%d7
	swap	%d7
1:	addq.l	#2,%a1
	getlast	\b
	\le	\lm
	add.l	DNXLN,%a4
	add.l	SNXLN,%a5
	subq.l	#1,\cnt
	bne.s	\name\()one
	bra	done
.endm

| 1: replace, X0 B0 X1 B1 in d2-d5
.macro	srep_mid
	move.l	%d0,%d1
	and.l	%d2,%d1
	eor.l	%d3,%d1
	move.l	%d1,(%a0)+
	and.l	%d4,%d0
	eor.l	%d5,%d0
	move.l	%d0,(%a0)+
.endm

| d6 is borrowed for the old screen long, and reloaded
.macro	srep_edge mask
	move.l	%d0,%d1
	and.l	%d2,%d1
	eor.l	%d3,%d1
	move.l	(%a0),%d6
	eor.l	%d6,%d1
	and.l	\mask,%d1
	eor.l	%d1,(%a0)+
	and.l	%d4,%d0
	eor.l	%d5,%d0
	move.l	(%a0),%d6
	eor.l	%d6,%d0
	and.l	\mask,%d0
	eor.l	%d0,(%a0)+
	move.l	SHF,%d6
.endm

| 2: transparent, F0 F1 in d2/d3
.macro	str_mid
	tst.l	%d0
	beq.s	8f
	tr_body	2
	bra.s	9f
8:	addq.l	#8,%a0
9:
.endm

.macro	str_edge mask
	and.l	\mask,%d0
	tr_body	2
.endm

| 5: replace, all planes set on colour 0
.macro	spl_mid
	move.l	%d0,(%a0)+
	move.l	%d0,(%a0)+
.endm

.macro	spl_edge mask
	.rept	2
	move.l	(%a0),%d1
	eor.l	%d0,%d1
	and.l	\mask,%d1
	eor.l	%d1,(%a0)+
	.endr
.endm

| 6: transparent, all planes set
.macro	sse_mid
	tst.l	%d0
	beq.s	8f
	or.l	%d0,(%a0)+
	or.l	%d0,(%a0)+
	bra.s	9f
8:	addq.l	#8,%a0
9:
.endm

.macro	sse_edge mask
	and.l	\mask,%d0
	or.l	%d0,(%a0)+
	or.l	%d0,(%a0)+
.endm

| 7: transparent, all planes cleared
.macro	scl_mid
	tst.l	%d0
	beq.s	8f
	not.l	%d0
	and.l	%d0,(%a0)+
	and.l	%d0,(%a0)+
	bra.s	9f
8:	addq.l	#8,%a0
9:
.endm

.macro	scl_edge mask
	and.l	\mask,%d0
	not.l	%d0
	and.l	%d0,(%a0)+
	and.l	%d0,(%a0)+
.endm

_fast4s_rows:
	movem.l	%d2-%d7/%a2-%a6,-(%sp)
	move.l	D,%a4
	move.l	S,%a5
	move.l	N,%d0
	subq.l	#2,%d0
	bpl.s	1f
	moveq	#0,%d0
1:	lsl.l	#3,%d0
	move.l	%d0,%a6			| bytes of middle groups per line
	move.l	SHF,%d6
	move.l	C,%a2
	move.l	MODE,%d0
	cmp.l	#1,%d0
	beq.s	1f
	move.l	H,%d5			| the other modes keep the count,
	move.l	LMASK,%d3		| and most of them the masks, in
	move.l	RMASK,%d4		| registers
1:	btst	#10,%d6
	bne	sb
	cmp.l	#5,%d0
	beq	s4p
	cmp.l	#6,%d0
	beq	s4s
	cmp.l	#7,%d0
	beq	s4c
	cmp.l	#2,%d0
	beq	s4t
	movem.l	(%a2),%d2-%d5		| X0 B0 X1 B1
	sline	srep_edge, srep_mid, srep_edge, s4r, 0, LMASK, RMASK, H
s4t:
	movem.l	(%a2),%d2-%d3		| F0 F1
	sline	str_edge, str_mid, str_edge, s4t, 0, LMASK, RMASK, %d5
s4p:
	sline	spl_edge, spl_mid, spl_edge, s4p, 0, %d3, %d4, %d5
s4s:
	sline	sse_edge, sse_mid, sse_edge, s4s, 0, %d3, %d4, %d5
s4c:
	sline	scl_edge, scl_mid, scl_edge, s4c, 0, %d3, %d4, %d5

| the same, bold
sb:	cmp.l	#5,%d0
	beq	b4p
	cmp.l	#6,%d0
	beq	b4s
	cmp.l	#7,%d0
	beq	b4c
	cmp.l	#2,%d0
	beq	b4t
	movem.l	(%a2),%d2-%d5
	sline	srep_edge, srep_mid, srep_edge, b4r, 1, LMASK, RMASK, H
b4t:
	movem.l	(%a2),%d2-%d3
	sline	str_edge, str_mid, str_edge, b4t, 1, LMASK, RMASK, %d5
b4p:
	sline	spl_edge, spl_mid, spl_edge, b4p, 1, %d3, %d4, %d5
b4s:
	sline	sse_edge, sse_mid, sse_edge, b4s, 1, %d3, %d4, %d5
b4c:
	sline	scl_edge, scl_mid, scl_edge, b4c, 1, %d3, %d4, %d5

/*
 * wk->r.expand, with the engine's registers (engine/blit.s
 * lib_vrt_cpyfm): a0 -> VDI struct, destination MFDB, VDI struct,
 * source MFDB; d0 = colours (background in the high word); d1/d2 =
 * source x/y; d3-d6 = destination x1, y1, x2, y2 (clipped); d7 = mode;
 * every register is kept.  vrt_cpyfm in replace and transparent mode to
 * a 4 plane form (the screen, or an interleaved MFDB) is set up here for
 * fast4_rows or fast4s_rows, as expand4 in fast.c does; the rest goes
 * on to the common C glue (_c_expand).  The set-up runs once per icon
 * and from memory, not from the cache: it is kept short.
 */
	.globl	_bp_expand

#define MFDB_ADDRESS	0
#define MFDB_WDWIDTH	8
#define MFDB_PLANES	12
#define WK_ADDRESS	24
#define WK_PLANES	36
#define WK_WRAP		44

| the frame: the arguments of fast4_rows/fast4s_rows, then the colours
#define A_D	0
#define A_S	4
#define A_H	8
#define A_N	12
#define A_DNX	16
#define A_SNX	20
#define A_C	24
#define A_MODE	28
#define A_LM	32
#define A_RM	36
#define A_SHF	40
#define A_COL	44
#define FRAME	76
#define R(n)	(FRAME + 4 * (n) + 2)(%sp)	/* low word of the saved d<n> */

_bp_expand:
	movem.l	%d0-%d7/%a0-%a6,-(%sp)
	lea	-FRAME(%sp),%sp
	subq.w	#1,%d7
	and.w	#3,%d7
	cmp.w	#1,%d7
	bhi	bx_no			| xor, reverse transparent
	move.l	12(%a0),%a1		| a monochrome source
	cmpa.w	#0,%a1
	beq	bx_no
	tst.l	MFDB_ADDRESS(%a1)
	beq	bx_no
	cmp.w	#1,MFDB_PLANES(%a1)
	bne	bx_no

	| the destination: a 4 plane MFDB, or the screen with 4 planes;
	| d0 = bytes per line, a4 = the form
	move.l	(%a0),%d0
	bclr	#0,%d0
	move.l	%d0,%a2
	move.l	(%a2),%a2		| the workstation
	move.l	4(%a0),%a3
	cmpa.w	#0,%a3
	beq.s	1f
	move.l	MFDB_ADDRESS(%a3),%d0
	beq.s	1f
	cmp.l	WK_ADDRESS(%a2),%d0
	beq.s	1f
	cmp.w	#4,MFDB_PLANES(%a3)
	bne	bx_no
	move.l	%d0,%a4
	move.w	MFDB_WDWIDTH(%a3),%d0
	ext.l	%d0
	lsl.l	#3,%d0
	bra.s	2f
1:	cmp.w	#4,WK_PLANES(%a2)
	bne	bx_no
	move.l	WK_ADDRESS(%a2),%a4
	move.w	WK_WRAP(%a2),%d0
	ext.l	%d0
2:	move.l	%d0,A_DNX(%sp)

	sub.w	%d3,%d5			| width
	addq.w	#1,%d5
	ble	bx_no
	sub.w	%d4,%d6			| height
	addq.w	#1,%d6
	ble	bx_no
	ext.l	%d6
	move.l	%d6,A_H(%sp)
	muls.w	%d4,%d0			| the first destination line
	add.l	%d0,%a4
	move.w	MFDB_WDWIDTH(%a1),%d0	| the first source line, a5
	ext.l	%d0
	add.l	%d0,%d0
	move.l	%d0,A_SNX(%sp)
	muls.w	%d2,%d0
	move.l	MFDB_ADDRESS(%a1),%a5
	add.l	%d0,%a5

	| d4 = x2, d6 = groups, a4 = the first one
	move.w	%d3,%d4
	add.w	%d5,%d4
	subq.w	#1,%d4
	move.w	%d3,%d0
	asr.w	#4,%d0
	move.w	%d4,%d6
	asr.w	#4,%d6
	sub.w	%d0,%d6
	addq.w	#1,%d6
	ext.l	%d6
	move.l	%d6,A_N(%sp)
	ext.l	%d0
	lsl.l	#3,%d0
	add.l	%d0,%a4
	move.l	%a4,A_D(%sp)

	| the edge masks, in both halves
	moveq	#15,%d0
	and.w	%d3,%d0
	moveq	#-1,%d3
	lsr.w	%d0,%d3
	move.w	%d3,%d0
	swap	%d3
	move.w	%d0,%d3
	moveq	#15,%d0
	and.w	%d4,%d0
	eor.w	#15,%d0
	moveq	#-1,%d4
	lsl.w	%d0,%d4
	move.w	%d4,%d0
	swap	%d4
	move.w	%d0,%d4
	cmp.w	#1,%d6
	bne.s	3f
	and.l	%d4,%d3			| a single group: both edges
3:	move.l	%d3,A_LM(%sp)
	move.l	%d4,A_RM(%sp)

	| the source: s0 = sx - (x1 & 15), d3 = sh and the flags of
	| fast4s_rows, d2 = the word of the first group (wbase)
	move.w	R(3),%d0
	and.w	#15,%d0
	move.w	%d1,%d2
	sub.w	%d0,%d2
	moveq	#15,%d3
	and.w	%d2,%d3
	asr.w	#4,%d2
	move.w	%d1,%d0
	asr.w	#4,%d0
	cmp.w	%d0,%d2
	bne.s	4f
	bset	#8,%d3			| S[0] is inside the rectangle
4:	move.w	%d1,%d0
	add.w	%d5,%d0
	subq.w	#1,%d0
	asr.w	#4,%d0
	move.w	%d2,%d4
	add.w	%d6,%d4
	cmp.w	%d0,%d4
	bgt.s	5f
	bset	#9,%d3			| and S[n]
5:	ext.l	%d2
	add.l	%d2,%d2
	add.l	%d2,%a5
	move.l	%a5,A_S(%sp)
	move.l	%d3,A_SHF(%sp)

	| the pens, then their colour longs: d2/d4 = F0 F1, d5/d6 = B0 B1
	lea	_bp_pen,%a0
	moveq	#0,%d0
	move.b	FRAME+3(%sp),%d0
	move.b	(%a0,%d0.w),%d0
	moveq	#0,%d1
	move.b	FRAME+1(%sp),%d1
	move.b	(%a0,%d1.w),%d1
	lea	epairs(%pc),%a0
	moveq	#3,%d2
	and.w	%d0,%d2
	move.l	(%a0,%d2.w*4),%d2
	lsr.w	#2,%d0
	and.w	#3,%d0
	move.l	(%a0,%d0.w*4),%d4
	moveq	#3,%d5
	and.w	%d1,%d5
	move.l	(%a0,%d5.w*4),%d5
	lsr.w	#2,%d1
	and.w	#3,%d1
	move.l	(%a0,%d1.w*4),%d6
	lea	A_COL(%sp),%a0
	move.l	%a0,A_C(%sp)
	tst.w	%d7
	bne.s	7f

	| replace: X = F ^ B; all planes set on colour 0 is mode 5
	eor.l	%d5,%d2
	eor.l	%d6,%d4
	moveq	#1,%d0
	move.l	%d2,%d1
	and.l	%d4,%d1
	addq.l	#1,%d1
	bne.s	6f
	move.l	%d5,%d1
	or.l	%d6,%d1
	bne.s	6f
	moveq	#5,%d0
6:	move.l	%d0,A_MODE(%sp)
	move.l	%d2,(%a0)		| X0
	moveq	#15,%d1
	and.w	%d3,%d1
	beq.s	61f
	move.l	%d5,4(%a0)		| shifted: X0 B0 X1 B1
	move.l	%d4,8(%a0)
	move.l	%d6,12(%a0)
	bra.s	8f
61:	move.l	%d4,4(%a0)		| aligned: X0 X1 . . B0 B1
	move.l	%d5,16(%a0)
	move.l	%d6,20(%a0)
	bra.s	9f

	| transparent: F; all planes set is mode 6, none mode 7
7:	move.l	%d2,(%a0)
	move.l	%d4,4(%a0)
	moveq	#2,%d0
	move.l	%d2,%d1
	and.l	%d4,%d1
	addq.l	#1,%d1
	bne.s	71f
	moveq	#6,%d0
71:	move.l	%d2,%d1
	or.l	%d4,%d1
	bne.s	72f
	moveq	#7,%d0
72:	move.l	%d0,A_MODE(%sp)
	moveq	#15,%d1
	and.w	%d3,%d1
	beq.s	9f
8:	bsr	_fast4s_rows
	bra.s	bx_out
9:	bsr	_fast4_rows
bx_out:
	lea	FRAME(%sp),%sp
	movem.l	(%sp)+,%d0-%d7/%a0-%a6
	rts
bx_no:
	lea	FRAME(%sp),%sp
	movem.l	(%sp)+,%d0-%d7/%a0-%a6
	jmp	_c_expand

	.even
epairs:	.long	0, 0xffff0000, 0x0000ffff, 0xffffffff
