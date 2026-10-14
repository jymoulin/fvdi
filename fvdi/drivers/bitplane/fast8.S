/*
 * 8 interleaved planes: monochrome to colour expansion (text, icons
 * already aligned on the destination), whole lines in one call.
 *
 * void fast8_rows(unsigned long *d, const unsigned short *s, long h,
 *                 long n, long dnxln, long snxln,
 *                 const unsigned long *c, long mode,
 *                 unsigned long lmask, unsigned long rmask)
 *
 *   d, s    first group of the first line, its source word
 *   h, n    lines (> 0), groups per line (> 0)
 *   dnxln, snxln  bytes from one line to the next
 *   lmask, rmask  pixels of the first and last group that may change,
 *           in both halves (for n == 1, lmask holds both edges)
 *   c, mode
 *     1 replace: c = X0 X1 X2 X3 B0 B1 B2 B3, each long of a group
 *       becoming B ^ (m & X), m being the source word in both halves
 *     2 transparent: c = F0 F1 F2 F3, each long d ^ ((d ^ F) & m)
 *     5 replace, black on white: each long is m
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

_fast8_rows:
	movem.l	%d2-%d7/%a2-%a6,-(%sp)
	move.l	D,%a4			| line starts
	move.l	S,%a5
	move.l	N,%d0
	subq.l	#2,%d0
	bpl.s	1f
	moveq	#0,%d0
1:	lsl.l	#4,%d0
	move.l	%d0,%a6			| bytes of middle groups per line
	move.l	C,%a2
	move.l	MODE,%d0
	cmp.l	#5,%d0
	beq	plain
	cmp.l	#6,%d0
	beq	setall
	cmp.l	#7,%d0
	beq	clrall
	cmp.l	#2,%d0
	beq	trans

| ---- 1: replace, any colours ------------------------------------------
	move.l	(%a2),%d2		| X0
	move.l	16(%a2),%d3		| B0
	move.l	4(%a2),%d4		| X1
	move.l	20(%a2),%d5		| B1
	move.l	8(%a2),%d6		| X2
	move.l	24(%a2),%d7		| B2

.macro	rep_mid
	getm
	move.l	%d0,%d1
	and.l	%d2,%d1
	eor.l	%d3,%d1
	move.l	%d1,(%a0)+
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

.macro	rep_edge mask
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

	line	rep_edge, rep_mid, rep_edge, r

| ---- 2: transparent, any colour ----------------------------------------
trans:
	move.l	(%a2),%d2		| F0
	move.l	4(%a2),%d3		| F1
	move.l	8(%a2),%d4		| F2
	move.l	12(%a2),%d5		| F3

.macro	tr_body
	move.l	(%a0),%d1
	eor.l	%d2,%d1
	and.l	%d0,%d1
	eor.l	%d1,(%a0)+
	move.l	(%a0),%d1
	eor.l	%d3,%d1
	and.l	%d0,%d1
	eor.l	%d1,(%a0)+
	move.l	(%a0),%d1
	eor.l	%d4,%d1
	and.l	%d0,%d1
	eor.l	%d1,(%a0)+
	move.l	(%a0),%d1
	eor.l	%d5,%d1
	and.l	%d0,%d1
	eor.l	%d1,(%a0)+
.endm

.macro	tr_mid
	getm
	tst.l	%d0
	beq.s	8f
	tr_body
	bra.s	9f
8:	lea	16(%a0),%a0
9:
.endm

.macro	tr_edge mask
	getm
	and.l	\mask,%d0
	tr_body
.endm

	line	tr_edge, tr_mid, tr_edge, t

| ---- 5: replace, black on white ----------------------------------------
plain:
.macro	pl_mid
	getm
	move.l	%d0,(%a0)+
	move.l	%d0,(%a0)+
	move.l	%d0,(%a0)+
	move.l	%d0,(%a0)+
.endm

.macro	pl_edge mask
	getm
	move.l	\mask,%d2
	move.l	(%a0),%d1
	eor.l	%d0,%d1
	and.l	%d2,%d1
	eor.l	%d1,(%a0)+
	move.l	(%a0),%d1
	eor.l	%d0,%d1
	and.l	%d2,%d1
	eor.l	%d1,(%a0)+
	move.l	(%a0),%d1
	eor.l	%d0,%d1
	and.l	%d2,%d1
	eor.l	%d1,(%a0)+
	move.l	(%a0),%d1
	eor.l	%d0,%d1
	and.l	%d2,%d1
	eor.l	%d1,(%a0)+
.endm

	line	pl_edge, pl_mid, pl_edge, p

| ---- 6: transparent, all planes set ------------------------------------
setall:
.macro	se_mid
	getm
	or.l	%d0,(%a0)+
	or.l	%d0,(%a0)+
	or.l	%d0,(%a0)+
	or.l	%d0,(%a0)+
.endm

.macro	se_edge mask
	getm
	and.l	\mask,%d0
	or.l	%d0,(%a0)+
	or.l	%d0,(%a0)+
	or.l	%d0,(%a0)+
	or.l	%d0,(%a0)+
.endm

	line	se_edge, se_mid, se_edge, s

| ---- 7: transparent, all planes cleared --------------------------------
clrall:
.macro	cl_mid
	getm
	not.l	%d0
	and.l	%d0,(%a0)+
	and.l	%d0,(%a0)+
	and.l	%d0,(%a0)+
	and.l	%d0,(%a0)+
.endm

.macro	cl_edge mask
	getm
	and.l	\mask,%d0
	not.l	%d0
	and.l	%d0,(%a0)+
	and.l	%d0,(%a0)+
	and.l	%d0,(%a0)+
	and.l	%d0,(%a0)+
.endm

	line	cl_edge, cl_mid, cl_edge, c

done:
	movem.l	(%sp)+,%d2-%d7/%a2-%a6
	rts
