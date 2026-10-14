/*
 * 4 and 8 interleaved planes: screen to screen copies (S_ONLY), whole
 * rectangles in one call, left to right on each line.
 *
 * void blit_copy(unsigned long *d, const unsigned long *s, long h,
 *                long nmid, long dnxln, long snxln, long np,
 *                unsigned long lmask, unsigned long rmask)
 *   Source and destination at the same position inside 16 pixels: the
 *   edge groups are merged under their masks, the groups between are
 *   copied as longs.
 *
 * void blit_shift4(unsigned long *d, const unsigned long *s, long h,
 *                  long nmid, long dnxln, long snxln, long sh,
 *                  long flags, unsigned long lmask, unsigned long rmask)
 * void blit_shift8(... the same ...)
 *   Destination group g gets, in every plane, (S[g] << sh) | (S[g+1] >>
 *   (16 - sh)), s pointing to S[0].  flags bit 0: S[0] may be read (it
 *   is outside the source rectangle otherwise, and taken as 0), bit 1:
 *   the same for the last S[g+1].
 *
 *   d, s    first group of the first line
 *   h       lines (> 0)
 *   nmid    groups between the two edge groups (>= 0), or -1 for a
 *           single group (lmask then holds both edges)
 *   dnxln, snxln  bytes from one line to the next (negative to go up)
 *   lmask, rmask  the pixels of the edge groups that change, in both
 *           halves
 *
 * Two planes are shifted at once in a long: with M = the bits from sh
 * up in each half, ((a << sh) & M) | ((b >> (16 - sh)) & ~M) is the
 * same as y ^ (((a << sh) ^ y) & M), y = b >> (16 - sh).
 *
 * This software is licensed under the GNU General Public License.
 * Please, see LICENSE.TXT for further information.
 */

	.text
	.globl	_blit_copy
	.globl	_blit_shift4
	.globl	_blit_shift8

#define D	48(%sp)
#define S	52(%sp)
#define H	56(%sp)
#define NMID	60(%sp)
#define DNXLN	64(%sp)
#define SNXLN	68(%sp)
#define SH	72(%sp)
#define LMASK	76(%sp)
#define RMASK	80(%sp)
#define SLMASK	80(%sp)
#define SRMASK	84(%sp)

| ---- aligned copy ------------------------------------------------------
|
| d4/d5 = lmask/rmask, d3 = longs per group - 1, d7 = lines - 1,
| a4/a5 = line starts, a6 = dnxln, a2 = snxln, a3 = entry into the
| loop copying 16 longs per pass, d2 = its full passes

| one group under the mask \m: dbra on d6 over its longs
.macro	cedge m
	move.w	%d3,%d6
8:	move.l	(%a0)+,%d0
	move.l	(%a1),%d1
	eor.l	%d1,%d0
	and.l	\m,%d0
	eor.l	%d1,%d0
	move.l	%d0,(%a1)+
	dbra	%d6,8b
.endm

_blit_copy:
	movem.l	%d2-%d7/%a2-%a6,-(%sp)
	move.l	D,%a4
	move.l	S,%a5
	move.l	DNXLN,%a6
	move.l	SNXLN,%a2
	move.l	LMASK,%d4
	move.l	RMASK,%d5
	move.l	72(%sp),%d3		| np
	subq.w	#1,%d3
	move.l	H,%d7
	subq.w	#1,%d7
	move.l	NMID,%d0
	bmi	5f
	mulu.w	74(%sp),%d0		| longs between the edges (np)
	move.l	%d0,%d2
	lsr.l	#4,%d2
	and.w	#15,%d0
	add.w	%d0,%d0			| 2 bytes of code per long
	lea	4f(%pc),%a3
	sub.l	%d0,%a3
1:	move.l	%a5,%a0
	move.l	%a4,%a1
	cedge	%d4
	move.w	%d2,%d6
	jmp	(%a3)
3:
	.rept	16
	move.l	(%a0)+,(%a1)+
	.endr
4:	dbra	%d6,3b
	cedge	%d5
	add.l	%a6,%a4
	add.l	%a2,%a5
	dbra	%d7,1b
	bra	done

| a single group per line
5:	move.l	%a5,%a0
	move.l	%a4,%a1
	cedge	%d4
	add.l	%a6,%a4
	add.l	%a2,%a5
	dbra	%d7,5b
	bra	done

| ---- shifted copy ------------------------------------------------------
|
| d0 = sh, d1 = 16 - sh, d2 = M, d7 = temporary, a2 = temporary,
| a0/a1 = source/destination, a3 = end of the middle groups,
| a4/a5 = line starts, a6 = dnxln; the a values of the group (the
| source group to the left) in d3-d6; lines and snxln on the stack.

| \a = a value in, the result out, (a0)+ = b, whose value then goes
| to \a; the destination long is \dst: (a1)+ plain, or merged under
| the mask at \m
.macro	shl a
	lsl.l	%d0,\a
	move.l	(%a0)+,%d7
	move.l	%d7,%a2
	lsr.l	%d1,%d7
	eor.l	%d7,\a
	and.l	%d2,\a
	eor.l	%d7,\a
.endm

| the same, b taken as 0 (outside the source)
.macro	shl0 a
	lsl.l	%d0,\a
	and.l	%d2,\a
	addq.l	#4,%a0
	sub.l	%a2,%a2
.endm

.macro	put a
	move.l	\a,(%a1)+
	move.l	%a2,\a
.endm

.macro	putm a, m
	move.l	(%a1),%d7
	eor.l	%d7,\a
	and.l	\m,\a
	eor.l	%d7,\a
	move.l	\a,(%a1)+
	move.l	%a2,\a
.endm

| the first a values of a line: S[0], or 0
.macro	first np
	btst	#0,79(%sp)
	beq.s	7f
	move.l	(%a0)+,%d3
	move.l	(%a0)+,%d4
	.if	\np == 4
	move.l	(%a0)+,%d5
	move.l	(%a0)+,%d6
	.endif
	bra.s	8f
7:	moveq	#0,%d3
	moveq	#0,%d4
	.if	\np == 4
	moveq	#0,%d5
	moveq	#0,%d6
	.endif
	lea	4*\np(%a0),%a0
8:
.endm

| a whole group: \op = shl or shl0, \m = 0 for a plain write
.macro	group np, op, m
	\op	%d3
	.ifc	\m,0
	put	%d3
	.else
	putm	%d3, \m
	.endif
	\op	%d4
	.ifc	\m,0
	put	%d4
	.else
	putm	%d4, \m
	.endif
	.if	\np == 4
	\op	%d5
	.ifc	\m,0
	put	%d5
	.else
	putm	%d5, \m
	.endif
	\op	%d6
	.ifc	\m,0
	put	%d6
	.else
	putm	%d6, \m
	.endif
	.endif
.endm

.macro	shift np
	movem.l	%d2-%d7/%a2-%a6,-(%sp)
	move.l	D,%a4
	move.l	S,%a5
	move.l	DNXLN,%a6
	move.l	SH,%d0
	moveq	#16,%d1
	sub.l	%d0,%d1
	move.l	#0xffff,%d2
	lsl.w	%d0,%d2
	move.w	%d2,%d7
	swap	%d2
	move.w	%d7,%d2			| M
	tst.l	NMID
	bmi	5f
1:	move.l	%a5,%a0
	move.l	%a4,%a1
	first	\np
	group	\np, shl, SLMASK
	move.l	NMID,%d7
	lsl.l	#2+\np/2,%d7		| bytes of the middle groups
	lea	(%a1,%d7.l),%a3
	cmp.l	%a3,%a1
	beq.s	3f
2:	group	\np, shl, 0
	cmp.l	%a3,%a1
	bne	2b
3:	btst	#1,79(%sp)
	beq	4f
	group	\np, shl, SRMASK
	bra	6f
4:	group	\np, shl0, SRMASK
6:	add.l	%a6,%a4
	add.l	SNXLN,%a5
	subq.l	#1,H
	bne	1b
	bra	done

| a single group per line
5:	move.l	%a5,%a0
	move.l	%a4,%a1
	first	\np
	btst	#1,79(%sp)
	beq	4f
	group	\np, shl, SLMASK
	bra	6f
4:	group	\np, shl0, SLMASK
6:	add.l	%a6,%a4
	add.l	SNXLN,%a5
	subq.l	#1,H
	bne	5b
	bra	done
.endm

_blit_shift4:
	shift	2
_blit_shift8:
	shift	4

done:
	movem.l	(%sp)+,%d2-%d7/%a2-%a6
	rts
