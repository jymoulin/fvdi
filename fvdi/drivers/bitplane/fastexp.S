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
 * This software is licensed under the GNU General Public License.
 * Please, see LICENSE.TXT for further information.
 */

	.text
	.globl	_fast4_rows
	.globl	_fast8_rows

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
