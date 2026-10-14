/*
 * 4 and 8 interleaved planes: solid and pattern fills, whole rectangles
 * in one call.
 *
 * void fill_solid4(unsigned long *d, long h, long nmid, long nxln,
 *                  const unsigned long *c, const short *pat, long py,
 *                  unsigned long lmask, unsigned long rmask)
 * void fill_solid8(... the same ...)
 * void fill_pat4(... the same ...)
 * void fill_pat8(... the same ...)
 *
 *   d       first group of the first line
 *   h       lines (> 0)
 *   nmid    groups between the two edge groups (>= 0), or -1 for a
 *           single group (lmask then holds both edges)
 *   nxln    bytes from one line to the next
 *   c       the colour longs of a group (2 or 4), all bits set
 *   pat, py (pattern fills) the 16 line pattern, the index of the first
 *           line in it: a line gets c & m, m being its pattern word in
 *           both halves (replace mode, 0 bits -> colour 0)
 *   lmask, rmask  the pixels of the edge groups that change, in both
 *           halves
 *
 * The groups between the edges are pure writes, unrolled and entered in
 * the middle for the remainder.  An edge long is (d | mask) ^ (~c & mask):
 * two memory instructions, no extra register.  The 68030 instruction
 * cache holds 256 bytes, and the line loop is kept well below that: an
 * instruction that misses the cache costs about twice the write it does.
 *
 * This software is licensed under the GNU General Public License.
 * Please, see LICENSE.TXT for further information.
 */

	.text
	.globl	_fill_solid4
	.globl	_fill_solid8
	.globl	_fill_pat4
	.globl	_fill_pat8

#define D	48(%sp)
#define H	52(%sp)
#define NMID	56(%sp)
#define NXLN	60(%sp)
#define C	64(%sp)
#define PAT	68(%sp)
#define PY	72(%sp)
#define LMASK	76(%sp)
#define RMASK	80(%sp)

| one edge long: (d | m) ^ (~c & m)
.macro	edge c, m
	move.l	\c,%d6
	not.l	%d6
	and.l	\m,%d6
	or.l	\m,(%a0)
	eor.l	%d6,(%a0)+
.endm

| Registers for the whole call: d4/d5 = lmask/rmask, d7 = lines - 1
| (and 2 * the pattern line in its high word), a2 = pattern,
| a3 = colours, a4 = line start, a6 = nxln, a1 = entry into the
| unrolled loop (\gsize bytes of code per group, 1 << \shift groups per
| pass), a5 = full passes; d0-d3 = colours.  Goes to \single for one
| group per line.
.macro	setup loop_end, gsize, shift, single
	movem.l	%d2-%d7/%a2-%a6,-(%sp)
	move.l	D,%a4
	move.l	NXLN,%a6
	move.l	LMASK,%d4
	move.l	RMASK,%d5
	move.l	NMID,%d0
	bmi.s	1f
	move.l	%d0,%d1
	lsr.l	#\shift,%d1
	move.l	%d1,%a5
	and.w	#(1 << \shift) - 1,%d0
	mulu.w	#\gsize,%d0
	lea	\loop_end(%pc),%a1
	sub.l	%d0,%a1
1:	move.l	PY,%d7
	and.w	#15,%d7
	add.w	%d7,%d7
	swap	%d7
	move.w	54(%sp),%d7		| h, low word
	subq.w	#1,%d7
	move.l	PAT,%a2
	move.l	C,%a3
	movem.l	(%a3),%d0-%d3
	tst.l	NMID
	bmi	\single
.endm

| the colours of this line: c & m (d6 = m, then free)
.macro	pattern np
	swap	%d7
	move.w	(%a2,%d7.w),%d6
	swap	%d6
	move.w	(%a2,%d7.w),%d6
	addq.w	#2,%d7
	and.w	#31,%d7
	swap	%d7
	move.l	(%a3),%d0
	and.l	%d6,%d0
	move.l	4(%a3),%d1
	and.l	%d6,%d1
	.if	\np == 4
	move.l	8(%a3),%d2
	and.l	%d6,%d2
	move.l	12(%a3),%d3
	and.l	%d6,%d3
	.endif
.endm

.macro	edges np, m
	edge	%d0, \m
	edge	%d1, \m
	.if	\np == 4
	edge	%d2, \m
	edge	%d3, \m
	.endif
.endm

| the whole function: \np longs per group, \pat = pattern fill
.macro	fill np, pat
	.if	\np == 2
	setup	4f, 4, 3, 5f
	.else
	setup	4f, 8, 2, 5f
	.endif
1:	move.l	%a4,%a0
	.if	\pat
	pattern	\np
	.endif
	edges	\np, %d4
	move.l	%a5,%d6
	jmp	(%a1)
3:
	.if	\np == 2
	.rept	8
	move.l	%d0,(%a0)+
	move.l	%d1,(%a0)+
	.endr
	.else
	.rept	4
	move.l	%d0,(%a0)+
	move.l	%d1,(%a0)+
	move.l	%d2,(%a0)+
	move.l	%d3,(%a0)+
	.endr
	.endif
4:	dbra	%d6,3b
	edges	\np, %d5
	add.l	%a6,%a4
	dbra	%d7,1b
	bra	done

| a single group per line
5:	move.l	%a4,%a0
	.if	\pat
	pattern	\np
	.endif
	edges	\np, %d4
	add.l	%a6,%a4
	dbra	%d7,5b
	bra	done
.endm

_fill_solid4:
	fill	2, 0
_fill_solid8:
	fill	4, 0
_fill_pat4:
	fill	2, 1
_fill_pat8:
	fill	4, 1

done:
	movem.l	(%sp)+,%d2-%d7/%a2-%a6
	rts
