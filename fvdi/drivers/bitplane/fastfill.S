/*
 * 4 and 8 interleaved planes: pattern fills in replace mode, whole
 * rectangles in one call.
 *
 * void fill_rows4(unsigned long *d, long h, long nmid, long nxln,
 *                 const unsigned short *pat, long py,
 *                 const unsigned long *c, long edges,
 *                 unsigned long lmask, unsigned long rmask)
 * void fill_rows8(... the same ...)
 *
 *   d       first group of the first line (the left edge group when
 *           edges bit 0 is set, else the first full group)
 *   h       lines (> 0)
 *   nmid    full groups between the edges (>= 0, < 32768)
 *   nxln    bytes from one line to the next
 *   pat, py the 16 line pattern and the index of the first line in it
 *   c       X0 X1 X2 X3 B0 B1 B2 B3: each long of a group becomes
 *           B ^ (m & X), m being the pattern word in both halves
 *           (4 planes use X0 X1 and B0 B1)
 *   edges   bit 0: a masked group on the left, bit 1: on the right
 *   lmask, rmask  the pixels of the edge groups that change, in both
 *           halves
 *
 * The groups between the edges are pure writes, unrolled 16 times.
 *
 * This software is licensed under the GNU General Public License.
 * Please, see LICENSE.TXT for further information.
 */

	.text
	.globl	_fill_rows4
	.globl	_fill_rows8

#define D	48(%sp)
#define H	52(%sp)
#define NMID	56(%sp)
#define NXLN	60(%sp)
#define PAT	64(%sp)
#define PY	68(%sp)
#define C	72(%sp)
#define EDGESB	79(%sp)
#define LMASK	80(%sp)
#define RMASK	84(%sp)

| one long of an edge group: d5 = d & ~mask | v & mask
| d4 = mask, d6 = ~mask
.macro	edge_long v
	move.l	(%a0),%d5
	and.l	%d6,%d5
	move.l	\v,%d7
	and.l	%d4,%d7
	or.l	%d7,%d5
	move.l	%d5,(%a0)+
.endm

| d5 = the pattern word of this line in both halves; a6 = py
.macro	pattern
	move.l	%a6,%d7
	and.w	#15,%d7
	move.w	(%a2,%d7.w*2),%d5
	move.w	%d5,%d6
	swap	%d5
	move.w	%d6,%d5
	addq.l	#1,%a6
.endm

.macro	colour reg, k
	move.l	4*\k(%a3),\reg
	and.l	%d5,\reg
	move.l	16+4*\k(%a3),%d6
	eor.l	%d6,\reg
.endm

| a1 = entry into the unrolled loop, a5 = full passes
| \gsize = bytes of code per group
.macro	setup loop_end, gsize
	movem.l	%d2-%d7/%a2-%a6,-(%sp)
	move.l	D,%a4
	move.l	PAT,%a2
	move.l	C,%a3
	move.l	PY,%a6
	move.l	NMID,%d0
	move.l	%d0,%d1
	lsr.l	#4,%d1
	move.l	%d1,%a5
	and.w	#15,%d0
	mulu.w	#\gsize,%d0
	lea	\loop_end(%pc),%a1
	sub.l	%d0,%a1
.endm

.macro	finish_line name
	add.l	NXLN,%a4
	subq.l	#1,H
	bne	\name
	movem.l	(%sp)+,%d2-%d7/%a2-%a6
	rts
.endm

| ---- 4 planes: two longs per group ------------------------------------
_fill_rows4:
	setup	4f, 4
1:	pattern
	colour	%d0, 0
	colour	%d1, 1
	move.l	%a4,%a0
	btst	#0,EDGESB
	beq.s	2f
	move.l	LMASK,%d4
	move.l	%d4,%d6
	not.l	%d6
	edge_long %d0
	edge_long %d1
2:	move.l	%a5,%d7
	jmp	(%a1)
3:
	.rept	16
	move.l	%d0,(%a0)+
	move.l	%d1,(%a0)+
	.endr
4:	dbra	%d7,3b
	btst	#1,EDGESB
	beq.s	5f
	move.l	RMASK,%d4
	move.l	%d4,%d6
	not.l	%d6
	edge_long %d0
	edge_long %d1
5:	finish_line 1b

| ---- 8 planes: four longs per group -----------------------------------
_fill_rows8:
	setup	4f, 8
1:	pattern
	colour	%d0, 0
	colour	%d1, 1
	colour	%d2, 2
	colour	%d3, 3
	move.l	%a4,%a0
	btst	#0,EDGESB
	beq.s	2f
	move.l	LMASK,%d4
	move.l	%d4,%d6
	not.l	%d6
	edge_long %d0
	edge_long %d1
	edge_long %d2
	edge_long %d3
2:	move.l	%a5,%d7
	jmp	(%a1)
3:
	.rept	16
	move.l	%d0,(%a0)+
	move.l	%d1,(%a0)+
	move.l	%d2,(%a0)+
	move.l	%d3,(%a0)+
	.endr
4:	dbra	%d7,3b
	btst	#1,EDGESB
	beq.s	5f
	move.l	RMASK,%d4
	move.l	%d4,%d6
	not.l	%d6
	edge_long %d0
	edge_long %d1
	edge_long %d2
	edge_long %d3
5:	finish_line 1b
