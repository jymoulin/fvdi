/*
 * 4 and 8 interleaved planes: solid lines, two planes per long.
 *
 * void line_draw4(void *adr, unsigned long bit, long n, long eps,
 *                 long e1, long e2, long xinc, long yinc,
 *                 const unsigned long *c, long flags)
 * void line_draw8(... the same ...)
 *
 *   adr     the group of the first pixel
 *   bit     its pixel, in both halves
 *   n       pixels - 1
 *   eps, e1, e2  the error term and its two steps (16 bit)
 *   xinc, yinc   bytes to the next group, to the next line (signed)
 *   c       the colour longs of the line (2 or 4)
 *   flags   bit 0: y major (one pixel per line), bit 1: xor
 *
 * The same pixels as the C loops in line.c: each step plots, moves
 * along the major axis, adds e1 to eps and, when eps gets >= 0,
 * subtracts e2 and moves along the other axis.  A pixel bit rotated
 * right in a long holding it in both halves wraps to 0x80008000 when
 * it leaves a group, and the carry says so.
 *
 * This software is licensed under the GNU General Public License.
 * Please, see LICENSE.TXT for further information.
 */

	.text
	.globl	_line_draw4
	.globl	_line_draw8

| d0 = bit, d1/d2/d4/d5 = colours, d3 = eps, d6 = count, d7 = temporary,
| a0 = address, a1 = yinc, a2 = xinc, a3 = e1, a4 = e2

| one long of the pixel: d ^ ((d ^ c) & bit)
.macro	put c, off
	move.l	\off(%a0),%d7
	eor.l	\c,%d7
	and.l	%d0,%d7
	eor.l	%d7,\off(%a0)
.endm

.macro	plot np, xor
	.if	\xor
	eor.l	%d0,(%a0)
	eor.l	%d0,4(%a0)
	.if	\np == 4
	eor.l	%d0,8(%a0)
	eor.l	%d0,12(%a0)
	.endif
	.else
	put	%d1, 0
	put	%d2, 4
	.if	\np == 4
	put	%d4, 8
	put	%d5, 12
	.endif
	.endif
.endm

| x major: one pixel per column
.macro	xloop np, xor
1:	plot	\np, \xor
	ror.l	#1,%d0
	bcc.s	2f
	add.l	%a2,%a0
2:	add.w	%a3,%d3
	bmi.s	3f
	sub.w	%a4,%d3
	add.l	%a1,%a0
3:	dbra	%d6,1b
	bra	done
.endm

| y major: one pixel per line
.macro	yloop np, xor
1:	plot	\np, \xor
	add.l	%a1,%a0
	add.w	%a3,%d3
	bmi.s	3f
	sub.w	%a4,%d3
	ror.l	#1,%d0
	bcc.s	3f
	add.l	%a2,%a0
3:	dbra	%d6,1b
	bra	done
.endm

.macro	ldraw np
	movem.l	%d2-%d7/%a2-%a6,-(%sp)
	move.l	48(%sp),%a0
	move.l	52(%sp),%d0
	move.l	56(%sp),%d6
	move.l	60(%sp),%d3
	move.l	64(%sp),%a3
	move.l	68(%sp),%a4
	move.l	72(%sp),%a2
	move.l	76(%sp),%a1
	move.l	80(%sp),%a5
	movem.l	(%a5),%d1-%d2/%d4-%d5	| d1 d2 d4 d5 = c[0..3]
	move.l	84(%sp),%d7
	btst	#1,%d7
	bne	6f
	btst	#0,%d7
	bne	5f
	xloop	\np, 0
5:	yloop	\np, 0
6:	btst	#0,%d7
	bne	7f
	xloop	\np, 1
7:	yloop	\np, 1
.endm

_line_draw4:
	ldraw	2
_line_draw8:
	ldraw	4

done:
	movem.l	(%sp)+,%d2-%d7/%a2-%a6
	rts

/*
 * long bp_line(...): the driver's line entry (wk->r.line), with the
 * engine's register interface (engine/draw.s): a0 = the VDI struct (an
 * odd address marks a table), d0 = colours (foreground in the low word),
 * d1-d4 = x1, y1, x2, y2, d5 = pattern, d6 = mode; every register is
 * kept.  A solid horizontal line in replace or transparent mode on 4 or
 * 8 planes is drawn here: clipped, its pen from bp_pen, then edges and
 * plain writes in between.  Anything else goes on to the common C glue
 * (_c_line), registers untouched.
 */
	.globl	_bp_line

/* the Virtual and Workstation members used (checked in fast.c) */
#define VWK_CLIP_X1	92
#define VWK_CLIP_Y1	94
#define VWK_CLIP_X2	96
#define VWK_CLIP_Y2	98
#define WK_ADDRESS	24
#define WK_PLANES	36
#define WK_WRAP		44

| one edge long: d ^ ((d ^ c) & m)
.macro	hedge c, m
	move.l	(%a2),%d7
	eor.l	\c,%d7
	and.l	\m,%d7
	eor.l	%d7,(%a2)+
.endm

| the colour long of planes 2k and 2k+1 from the pen in d7 (kept)
.macro	hcolour k, reg
	move.w	%d7,\reg
	.if	\k
	lsr.w	#2*\k,\reg
	.endif
	and.w	#3,\reg
	move.l	(%a1,\reg\().w*4),\reg
.endm

_bp_line:
	cmp.w	%d2,%d4
	bne	9f
	cmp.w	#-1,%d5
	bne	9f
	movem.l	%d0-%d7/%a0-%a2,-(%sp)
	move.l	%a0,%d7
	btst	#0,%d7
	bne	7f			| a table
	moveq	#-1,%d7
	add.w	%d6,%d7
	cmp.w	#1,%d7
	bhi	7f			| not replace or transparent
	move.l	(%a0),%a1		| the workstation
	move.w	WK_PLANES(%a1),%d7
	cmp.w	#4,%d7
	beq.s	1f
	cmp.w	#8,%d7
	bne	7f
1:	cmp.w	%d1,%d3
	bge.s	2f
	exg	%d1,%d3
2:	cmp.w	VWK_CLIP_Y1(%a0),%d2
	blt	8f
	cmp.w	VWK_CLIP_Y2(%a0),%d2
	bgt	8f
	cmp.w	VWK_CLIP_X1(%a0),%d1
	bge.s	3f
	move.w	VWK_CLIP_X1(%a0),%d1
3:	cmp.w	VWK_CLIP_X2(%a0),%d3
	ble.s	4f
	move.w	VWK_CLIP_X2(%a0),%d3
4:	cmp.w	%d1,%d3
	blt	8f

	| a2 = first group, d6 = groups - 1, d4/d5 = left/right masks
	move.l	WK_ADDRESS(%a1),%a2
	move.w	WK_WRAP(%a1),%d4
	muls.w	%d2,%d4
	add.l	%d4,%a2
	move.w	%d1,%d4
	lsr.w	#4,%d4
	move.w	%d3,%d6
	lsr.w	#4,%d6
	sub.w	%d4,%d6
	mulu.w	%d7,%d4
	add.l	%d4,%d4
	add.l	%d4,%a2
	moveq	#15,%d2
	and.w	%d1,%d2
	moveq	#-1,%d4
	lsr.w	%d2,%d4
	move.w	%d4,%d2
	swap	%d4
	move.w	%d2,%d4
	moveq	#15,%d2
	and.w	%d3,%d2
	eor.w	#15,%d2
	moveq	#-1,%d5
	lsl.w	%d2,%d5
	move.w	%d5,%d2
	swap	%d5
	move.w	%d2,%d5
	tst.w	%d6
	bne.s	5f
	and.l	%d5,%d4			| a single group: both edges
5:	move.w	%d7,%a0			| planes
	moveq	#0,%d7
	move.b	3(%sp),%d7		| foreground (low byte of the saved d0)
	lea	_bp_pen,%a1
	move.b	(%a1,%d7.w),%d7
	lea	hpairs(%pc),%a1
	cmp.w	#8,%a0
	beq	h8

	hcolour	0, %d0
	hcolour	1, %d1
	hedge	%d0, %d4
	hedge	%d1, %d4
	subq.w	#1,%d6			| groups in between
	bmi.s	8f			| a single group
	beq.s	61f
	subq.w	#1,%d6
60:	move.l	%d0,(%a2)+
	move.l	%d1,(%a2)+
	dbra	%d6,60b
61:	hedge	%d0, %d5
	hedge	%d1, %d5
8:	movem.l	(%sp)+,%d0-%d7/%a0-%a2
	rts

7:	movem.l	(%sp)+,%d0-%d7/%a0-%a2
9:	jmp	_c_line

h8:	hcolour	3, %d3
	hcolour	2, %d2
	hcolour	1, %d1
	hcolour	0, %d0
	hedge	%d0, %d4
	hedge	%d1, %d4
	hedge	%d2, %d4
	hedge	%d3, %d4
	subq.w	#1,%d6
	bmi	8b
	beq.s	81f
	subq.w	#1,%d6
80:	move.l	%d0,(%a2)+
	move.l	%d1,(%a2)+
	move.l	%d2,(%a2)+
	move.l	%d3,(%a2)+
	dbra	%d6,80b
81:	hedge	%d0, %d5
	hedge	%d1, %d5
	hedge	%d2, %d5
	hedge	%d3, %d5
	bra	8b

	.even
hpairs:	.long	0, 0xffff0000, 0x0000ffff, 0xffffffff
