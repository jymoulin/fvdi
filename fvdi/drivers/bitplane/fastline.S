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
