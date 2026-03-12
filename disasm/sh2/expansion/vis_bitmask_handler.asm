/*
 * vis_bitmask_handler — Entity Visibility Bitmask Handler (cmd $07)
 * Expansion ROM Address: $3011A0 (SH2: $023011A0)
 * Size: 36 bytes (30 bytes code + 2 NOP padding + 4 bytes literal pool)
 *
 * Receives a 15-bit entity visibility bitmask from the 68K via COMM3 and
 * stores it to a known SDRAM location ($0603E020, cache-through $2203E020).
 * The Slave SH2 entity rendering loops read this bitmask to skip invisible
 * entities, reducing SSH2 rendering workload.
 *
 * Phase 1: Store bitmask only. Phase 2 will add entity flag modification.
 *
 * COMM Register Layout (R8 = $20004020):
 *   COMM0_HI (offset 0):  $01 — trigger (written LAST by 68K)
 *   COMM0_LO (offset 1):  $07 — dispatch index; cleared to $00 by SH2
 *   COMM2_HI (offset 4):  $00 — NEVER WRITTEN (Slave polls this)
 *   COMM3    (offset 6,7): 15-bit visibility bitmask (bit N = entity N visible)
 *
 * SDRAM Work Area (cache-through):
 *   $2203E020 (word): current visibility bitmask
 *
 * Entry: R8 = $20004020 (COMM base, set by dispatch loop before JSR)
 *
 * Follows cmd22_single_shot COMM cleanup protocol:
 *   1. Read params, clear COMM0_LO (handshake)
 *   2. Do work
 *   3. Clear COMM1 + set COMM1_LO bit 0 ("done")
 *   4. Clear COMM0_HI (byte write)
 *   5. Return to dispatch loop
 */

.section .text
.align 2

vis_bitmask_handler:
    /* offset  0 */ mov.w   @(6,r8),r0          /* R0 = COMM3 word = visibility bitmask */
    /* offset  2 */ extu.w  r0,r1               /* R1 = bitmask (zero-extended) */

    /* === HANDSHAKE: signal params consumed === */
    /* offset  4 */ mov     #0,r0               /* R0 = 0 */
    /* offset  6 */ mov.b   r0,@(1,r8)          /* COMM0_LO = $00 (68K can proceed) */

    /* === STORE BITMASK TO SDRAM === */
    /* offset  8 */ mov.l   @(.vis_sdram,pc),r2 /* R2 = $2203E020 */
    /* offset 10 */ mov.w   r1,@r2              /* Store bitmask to SDRAM */

    /* === COMM1 CLEANUP (func_084 equivalent) === */
    /* offset 12 */ mov     #0,r0               /* R0 = 0 */
    /* offset 14 */ mov.w   r0,@(2,r8)          /* COMM1_HI:LO = $0000 */
    /* offset 16 */ mov.b   @(3,r8),r0          /* R0 = COMM1_LO (just cleared = 0) */
    /* offset 18 */ or      #1,r0               /* R0 |= 1 (set bit 0: "command done") */
    /* offset 20 */ mov.b   r0,@(3,r8)          /* COMM1_LO = 1 */

    /* === CLEAR COMM0_HI (byte write, preserves COMM0_LO) === */
    /* offset 22 */ mov     #0,r0               /* R0 = 0 */
    /* offset 24 */ mov.b   r0,@(0,r8)          /* COMM0_HI = 0 (completion signal) */

    /* === RETURN TO DISPATCH LOOP === */
    /* offset 26 */ rts
    /* offset 28 */ nop                         /* [delay slot] */

    /* === PADDING FOR 4-BYTE ALIGNMENT === */
    /* offset 30 */ nop

/* === LITERAL POOL ===
 * offset 32 ($3011C0): .vis_sdram = $2203E020 (4 bytes)
 * Total: 30 bytes code + 2 NOP padding + 4 bytes pool = 36 bytes
 *
 * PC-relative check for MOV.L at offset 8:
 *   PC = $3011A0 + 8 = $3011A8
 *   (PC & ~3) + 4 + disp*4 = $3011A8 + 4 + 5*4 = $3011AC + $14 = $3011C0 ✓
 */
.align 2
.vis_sdram:
    .long   0x2203E020          /* SDRAM visibility bitmask (cache-through) */

/* Total: 36 bytes */
.global vis_bitmask_handler
