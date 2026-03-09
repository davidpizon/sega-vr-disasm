# Rendering Pipeline — Virtua Racing Deluxe 32X

**End-to-end rendering flow: from 68K scene orchestration to final composite display.**

This document traces one frame through the complete pipeline. For deeper detail on individual
subsystems, see:
- [SYSTEM_EXECUTION_FLOW.md](SYSTEM_EXECUTION_FLOW.md) — frame lifecycle, V-INT state table
- [sh2-analysis/SH2_3D_PIPELINE_ARCHITECTURE.md](sh2-analysis/SH2_3D_PIPELINE_ARCHITECTURE.md) — 109 SH2 function catalog
- [COMM_REGISTERS_HARDWARE_ANALYSIS.md](COMM_REGISTERS_HARDWARE_ANALYSIS.md) — COMM protocol hazards
- [graphics-vdp/32X_FRAME_BUFFER_FORMAT.md](graphics-vdp/32X_FRAME_BUFFER_FORMAT.md) — framebuffer layout

---

## 1. Pipeline Overview

Three CPUs run concurrently. Data flows through COMM registers (16 bytes), SDRAM (256 KB),
and dual framebuffer DRAMs (128 KB each).

```
TIME    68K (7.67 MHz, 100%)     Master SH2 (23 MHz, 0-36%)   Slave SH2 (23 MHz, 78%)
 │      ════════════════════     ═══════════════════════════   ═════════════════════════
 │
 │  ┌─ V-INT fires ─────────────────────────────────────────────────────────────────────┐
 │  │  FM=0: 68K claims VDP      (waiting)                     (processing cmd $27s)    │
 │  │  DMA + palette xfer                                                               │
 │  │  Frame buffer swap (FS)                                                           │
 │  │  FM=1: SH2 regains VDP                                                           │
 │  └───────────────────────────────────────────────────────────────────────────────────┘
 │
 │      poll_controllers          poll COMM0_HI ──┐             poll COMM7 doorbell
 │      game logic (physics,      (idle, waiting   │             3D vertex transforms
 │       AI, collision)            for 68K cmd)    │             polygon processing
 │      depth_sort                                 │             rasterization
 │      render preparation                         │
 │                                                 │
 │  ┌─ Command Submission ──── COMM regs ──────────┘                                    ┐
 │  │  sh2_send_cmd ×14 ────→ dispatch cmd $22                  ← async cmd $27 ×21     │
 │  │  (BLOCKING: 68K waits    block copy: SDRAM → FB ────→ FRAMEBUFFER DRAM            │
 │  │   for each copy)         inline COMM cleanup              pixel fill ops           │
 │  │                          re-dispatch check                                        │
 │  └───────────────────────────────────────────────────────────────────────────────────┘
 │
 │  ┌─ Frame complete ──────────────────────────────────────────────────────────────────┐
 │  │  68K game logic continues  back to idle poll              back to COMM7 poll      │
 │  └───────────────────────────────────────────────────────────────────────────────────┘
 │
 ▼      ── next V-INT ──         VDP scans out displayed FB     Genesis VDP scans tiles
        Genesis + 32X composited by adapter hardware → TV
```

**Why ~20-24 FPS (not 60):** The 68K blocks on every `sh2_send_cmd`, adding Master SH2
execution time to the 68K frame. Combined with 100% 68K utilization for game logic,
frames cannot fit in 16.67 ms. See [ARCHITECTURAL_BOTTLENECK_ANALYSIS.md](ARCHITECTURAL_BOTTLENECK_ANALYSIS.md).

---

## 2. Frame Start — V-INT ($001684)

The vertical interrupt fires every 16.67 ms (60 Hz NTSC). The V-INT handler dispatches
one VDP/framebuffer operation per frame via a state variable.

**State dispatch:** `$FFC87A` (pre-multiplied ×4) indexes a jump table at ROM $0016B2.

| State | Handler | Purpose |
|-------|---------|---------|
| 24 | `vint_state_fb_toggle` ($001C66) | **Frame buffer swap** + palette DMA |
| 36 | `vint_state_fb_setup` ($001E42) | Frame buffer pointer setup |
| 52 | `vint_state_fb_palette` ($001E94) | FB + palette update |
| 60 | `vint_state_cleanup` ($002010) | Clear SH2 command flags |

### FM Bit Lifecycle (per frame)

The FM bit (bit 7 of `MARS_SYS_INTCTL` at $A15100) controls VDP/framebuffer access:
- FM=0 → 68K has access, SH2 blocked
- FM=1 → SH2 has access, 68K blocked

During V-INT VDP operations (states 24, 36, 52):

```
1. BCLR #7, $A15100          ; FM=0 — 68K claims VDP access
2. BTST #7, $A1518A          ; Wait for VBLK=1 (V-blank period)
   BEQ.S .wait               ; (safe for palette + frame swap)
3. ... palette DMA, frame swap, CRAM transfer ...
4. BSET #7, $A15100          ; FM=1 — return access to SH2
```

> **HAZARD:** FM write is immediate and preemptive. Writing FM=0 while the SH2 is
> mid-write to the framebuffer can corrupt data. VRD mitigates this by only toggling
> FM during V-blank when the SH2 is typically idle between copy commands.

Source: [vdp_dma_palette_xfer_036.asm](../disasm/modules/68k/game/render/vdp_dma_palette_xfer_036.asm),
[vdp_dma_frame_swap_037.asm](../disasm/modules/68k/game/render/vdp_dma_frame_swap_037.asm)

---

## 3. 68K Scene Orchestration

After V-INT returns, the 68K runs the main game loop for ~16 ms.

```
Main loop:
    │
    ├─ poll_controllers ($00179E)       ; Read joypad → $FFC86C
    │
    ├─ Game state dispatch ($FFC87E)
    │   ├─ Race mode: physics, AI, collision, camera
    │   ├─ Menu mode: input, selection, transitions
    │   └─ Results/attract: display, timers
    │
    ├─ Object system update
    │   ├─ obj_position_update ($007084) — integrate velocities
    │   ├─ obj_collision_test ($007816) × 11 calls
    │   └─ ai_entity_main_update_orch ($00A972) — AI steering
    │
    ├─ Render preparation
    │   ├─ depth_sort ($009DD6) — selection sort, 16 elements
    │   │   (back-to-front, direction-based tie-breaking for painter's algorithm)
    │   ├─ sh2_graphics_cmd ($00E22C) × 14 — build block-copy parameters
    │   └─ object_visibility_collector — cull hidden objects
    │
    └─ Command submission (see §4)
```

**Key insight:** The 68K determines **what** to render (display list, object ordering),
while the SH2 determines **how** (rasterization, pixel copy). The 68K never writes
pixels directly to the framebuffer during gameplay — all pixel work goes through
SH2 commands.

**Framebuffer preparation:** `sh2_framebuffer_prep` ($0027DA) uses the VDP auto-fill
hardware to clear the draw buffer before new frame rendering begins.

Source: [SYSTEM_EXECUTION_FLOW.md §2](SYSTEM_EXECUTION_FLOW.md),
[depth_sort.asm](../disasm/modules/68k/game/render/depth_sort.asm)

---

## 4. Command Submission (68K → SH2)

Every frame, the 68K submits commands via two paths with fundamentally different
synchronization models.

### Path A: sh2_send_cmd — Blocking (Master SH2)

14 calls/frame. Each submits a 2D block copy (cmd $22). The 68K is **fully blocked**
until the Master SH2 finishes.

```
68K (sh2_send_cmd at $00E35A):             Master SH2:
─────────────────────────────────          ─────────────
WAIT: COMM0_HI == 0 ← ← ← ← ← ← ← ←─── clears COMM0_HI after copy
Write COMM2-6 (src, dst, dims)
Write COMM0: HI=$01, LO=$22 ─────────────→ dispatch cmd $22
WAIT: COMM0_LO == 0 ← ← ← ← ← ← ← ←─── clears COMM0_LO (params read)
RTS                                        ... copies pixels ...
                                           ... COMM cleanup ...
```

The first WAIT is the **10.84% 68K hotspot** — the 68K spin-waits for the Master SH2
to finish the previous block copy before it can submit the next one.

### Path B: sh2_cmd_27 — Fire-and-Forget (Slave SH2)

21 calls/frame. Pixel region operations via COMM7 doorbell. The 68K **returns immediately**.

```
68K (sh2_cmd_27 at $00E3B4):               Slave SH2:
─────────────────────────────────          ─────────────
WAIT: COMM7 == 0 ← ← ← ← ← ← ← ← ←──── clears COMM7 (previous ack)
Write COMM2-6 (ptr, dims, op)
Write COMM7 = $0027 (doorbell) ───────────→ detect non-zero COMM7
RTS (return immediately)                    read params, clear COMM7
                                            execute pixel operation
                                            loop back to poll
```

> **HAZARD:** COMM1 is a system signal register (hw_init_short manages bit 0 as "command done").
> COMM7 is the Slave doorbell. Never cross-purpose these registers — writing game
> commands to COMM7 caused a B-006 crash. See [MASTER_SH2_DISPATCH_ANALYSIS.md](architecture/MASTER_SH2_DISPATCH_ANALYSIS.md).

Source: [code_e200.asm](../disasm/sections/code_e200.asm) ($E35A, $E3B4),
[68K_SH2_COMMUNICATION.md](68K_SH2_COMMUNICATION.md)

---

## 5. Master SH2 Dispatch ($020460)

The Master SH2 runs a tight polling loop waiting for 68K commands:

```
$020460: R8 = $20004020         ; COMM base (cache-through)
$020462: R0 = MOV.B @R8        ; read COMM0_HI
$020464: CMP/EQ #0, R0         ; zero?
$020466: BT → $020460          ; yes → keep polling
$020468: R0 = MOV.B @(1,R8)    ; read COMM0_LO (dispatch index)
$02046A: SHLL2 R0              ; × 4 (jump table offset)
$02046C: R1 = $06000780        ; jump table base (SDRAM)
$02046E: R0 = MOV.L @(R0,R1)  ; load handler address
$020470: JSR @R0               ; call handler
$020474: BRA → $020460         ; loop (NO hw_init_short — handlers manage COMM)
```

**Jump table** at SDRAM $06000780:

| COMM0_LO | Handler | Purpose |
|----------|---------|---------|
| $01 | $060008A0 | Original 3-phase handler (game commands) |
| $22 | $023010F0 | Expansion: `cmd22_single_shot` (B-004) |
| $25 | $02300500 | Expansion: `cmd25_single_shot` (RLE decompress) |

### cmd22_single_shot (136 bytes at expansion $3010F0)

The optimized block copy handler with inline COMM cleanup:

```
1. Read ALL params from COMM2-6 into registers
2. Clear COMM0_LO = $00 (signal: params consumed — 68K .wait_consumed exits)
3. Reconstruct source ($06xxxxxx) and dest ($04xxxxxx) pointers
4. Block copy: word-by-word, src++ → dest, advance dest by $0200/row
5. Reload R8 = $20004020 (COMM base, clobbered during copy)
6. COMM1 cleanup: clear COMM1 word, set COMM1_LO bit 0 ("command done")
7. Clear COMM0_HI via byte write (preserves COMM0_LO)
8. Re-dispatch check: if COMM0_LO == $22 → loop to step 1
   if COMM0_LO != 0 → restore COMM0_HI=$01, exit
   if COMM0_LO == 0 → clean exit
```

> **HAZARD:** SH2 COMM access must use cache-through addressing ($20004020), never
> cached ($00004020). Cached reads may return stale data, missing 68K writes.

Source: [cmd22_single_shot.asm](../disasm/sh2/expansion/cmd22_single_shot.asm)

---

## 6. SH2 3D Rendering Pipeline

The SH2 3D engine consists of 109 functions spanning ~8 KB of optimized assembly.
This section summarizes the pipeline stages — for the full function catalog with
call graphs and register analysis, see
[SH2_3D_PIPELINE_ARCHITECTURE.md](sh2-analysis/SH2_3D_PIPELINE_ARCHITECTURE.md).

### Pipeline Stages

| Stage | Key Function | Purpose | Cost |
|-------|-------------|---------|------|
| 1. Init | $02224084 | VDP config, buffer setup | One-time |
| 2. Data load | $02224000 | Unpack vertex/polygon data to SDRAM | Per scene |
| 3. Vertex transform | matrix_multiply ($23120) | MAC.L matrix × vector (16.16 fixed-point) | ~45 cycles/vertex |
| 4. Polygon processing | $02224060 | 20-byte descriptors, active flag, dispatch | ~50-60 cycles/poly |
| 5. Visibility/culling | frustum_cull_short ($23508) | Frustum, Z-depth, screen bounds | 238 bytes (largest fn) |
| 6. Rasterization | render_quad_short/034 | Edge walking (MAC.W), span filling | Variable |
| 7. Coordinate packing | coord_transform ($23368) | Screen coord output | **17% frame budget** |

### Key Implementation Details

- **Fixed-point math:** All transforms use 16.16 format (no FPU). The `XTRCT` instruction
  extracts MAC[47:16] for 32×32→64 multiply results.
- **Reciprocal LUT** at $060048D0 for fast 1/Z division in the rasterizer.
- **Data buffers** in SDRAM: transform matrices, vertex buffers, polygon buffers at
  $22000000+ (cache-through for inter-CPU coherency).

### Slave SH2 Interleaving

The Slave SH2 runs the 3D pipeline but also checks COMM7 between operations
(at `inline_slave_drain`, SDRAM $020608). When `sh2_cmd_27` pixel work arrives,
the Slave processes it between 3D pipeline stages, achieving 78% utilization.

---

## 7. Framebuffer Architecture

### Physical Layout

Two 1-Mbit DRAMs provide double-buffered rendering. One is displayed while the
other is drawn to.

```
FRAMEBUFFER (one DRAM, 128 KB = 65,536 words)
┌──────────────────────────────────────────┐
│ Line Table (256 words = 512 bytes)       │  $840000 (68K) / $04000000 (SH2)
│  Entry 0: offset → line 0 pixel data     │
│  Entry 1: offset → line 1 pixel data     │
│  ...                                     │
│  Entry 223: offset → line 223 pixel data │
├──────────────────────────────────────────┤
│ Pixel Data                               │  $840200+
│  Line 0: 320 bytes (320 pixels × 1B)    │
│  (padding to $0200 stride)               │
│  Line 1: 320 bytes                       │
│  ...                                     │
│  Line 223: 320 bytes                     │
│  Total: 224 lines × 512B stride = 112 KB │
└──────────────────────────────────────────┘
```

### Display Mode

VRD uses **Packed Pixel Mode** (8bpp indexed color):
- 1 byte per pixel → palette index (0-255)
- 256-color palette at CRAM ($A15200), each entry = 16-bit RGB555 + through-bit
- Set during scene init: `ORI.B #$01, MARS_VDP_MODE+1` (M0=1, M1=0)
- Line stride: $0200 (512 bytes) — used by cmd22 to advance between rows

### Access Rules

| CPU | Address | Condition |
|-----|---------|-----------|
| 68K | $840000-$85FFFF | FM=0 (68K has VDP access) |
| SH2 cached | $04000000-$0403FFFF | FM=1, for bulk pixel writes |
| SH2 cache-through | $24000000-$2403FFFF | FM=1, for I/O coherency |
| Overwrite image | $860000 / $04020000 | Separate layer, byte $00 = transparent |

> **HAZARD — DRAM bus width:** Framebuffer DRAM is 16-bit wide. SH2 `MOV.L` writes
> to $04xxxxxx are split by the BSC into two sequential word writes. No throughput
> gain from longword access on the write side.

> **HAZARD — Byte-zero writes:** Cannot write byte value $00 to the framebuffer
> using byte-width access (the write is ignored). Use word-width writes instead.

### Auto-Fill Hardware

Fast hardware-accelerated screen clear:

```
Write fill length  → $A15184 (words to fill, 0-255)
Write start addr   → $A15186 (word address within FB)
Write fill data    → $A15188 (triggers fill operation)
Poll FEN bit       → $A1518A bit 1 (0 = fill complete)
```

Fill time = 7 + 3 × length cycles.

> **HAZARD:** SH2 and VDP auto-fill share the DRAM bus. Do not access the framebuffer
> from SH2 while FEN=1.

Source: [32X_FRAME_BUFFER_FORMAT.md](graphics-vdp/32X_FRAME_BUFFER_FORMAT.md),
[mars_adapter_state_init_framebuffer_setup.asm](../disasm/modules/68k/game/render/mars_adapter_state_init_framebuffer_setup.asm)

---

## 8. Double-Buffer Swap

### Mechanism

VRD maintains a software toggle and writes the hardware FS bit during V-blank:

```
Software toggle:  $FFFFC80C (byte, bit 0) — tracks current draw buffer
Hardware select:  $A1518B bit 0 (FS bit in MARS_VDP_FBCTL low byte)
```

### Swap Sequence (vdp_dma_frame_swap_037 at $001D0C)

This function is called from V-INT state 24 (`vint_state_fb_toggle`):

```
1. VDP scroll/color register writes (Genesis VDP)
2. Z80 bus request → VDP DMA (palette to CRAM) → Z80 release
3. Check COMM1_LO bit 0:
   └─ If clear → skip swap (SH2 not done yet)
   └─ If set → proceed:
       a. Clear COMM1_LO bit 0 (acknowledge)
       b. game_state ($FFC87E) = 0 (reset state)
       c. BCLR #7, $A15100 (FM=0, 68K claims VDP)
       d. Wait VBLK=1 ($A1518A bit 7)
       e. BCHG frame_toggle ($FFC80C)
       f. BSET/BCLR #0, $A1518B (set FS bit based on toggle)
       g. BSET #7, $A15100 (FM=1, return to SH2)
```

**Key synchronization:** The swap only happens when COMM1_LO bit 0 is set — this is
the "command done" signal managed by hw_init_short (or its inline equivalent in cmd22).
The 68K never swaps before the SH2 has finished all pixel work for the current frame.

> **TIMING:** FS writes during active display are queued until the next V-blank.
> Writes during V-blank take effect immediately. VRD waits for VBLK=1 before
> writing FS to ensure immediate effect.

Source: [vdp_dma_frame_swap_037.asm](../disasm/modules/68k/game/render/vdp_dma_frame_swap_037.asm)

---

## 9. VDP Compositing — Genesis + 32X

The final display is a hardware composite of two independent video signals produced
by the Genesis VDP and 32X VDP.

### Two Video Layers

```
┌─────────────────────────┐     ┌─────────────────────────┐
│     Genesis VDP          │     │      32X VDP             │
│  ┌─────────────────┐    │     │  ┌─────────────────┐    │
│  │ Scroll A (tiles) │    │     │  │ Framebuffer      │    │
│  │ Scroll B (tiles) │    │     │  │ (Packed Pixel    │    │
│  │ Sprites          │    │     │  │  8bpp indexed)   │    │
│  └─────────────────┘    │     │  └─────────────────┘    │
│         ↓                │     │         ↓                │
│  One composite screen    │     │  One screen from FB      │
└────────────┬────────────┘     └────────────┬────────────┘
             │                                │
             └──────────┬─────────────────────┘
                        ↓
              32X Adapter Hardware
              (priority compositing)
                        ↓
                   TV Display
```

### Priority Control — PRI Bit

The PRI bit (Bitmap Mode Register $A15180, bit 13) controls layer ordering:

| PRI | Front Layer | Back Layer | VRD Usage |
|-----|-------------|------------|-----------|
| 0 | **Genesis** (tiles + sprites) | 32X (framebuffer) | **Default — race mode** |
| 1 | **32X** (framebuffer) | Genesis (tiles + sprites) | Available but not used |

**VRD uses PRI=0** — the Genesis layer is in front. This means:
- **Genesis tiles** (HUD, timing, position numbers) overlay the 3D scene
- **Genesis color 0** (transparent) lets the 32X framebuffer show through
- The 3D racing scene rendered by SH2 appears behind the Genesis overlay
- This is the standard compositing strategy for 32X games with HUD elements

PRI takes effect on the next scanline after write — mid-frame changes are possible
for split-screen effects, though VRD does not use this.

### Per-Pixel Priority — Through-Bit

Each color entry has a through-bit (bit 15) that overrides the PRI setting
for individual pixels:

```
Palette entry format (16-bit word at $A15200 + index×2):
┌──┬──────┬──────┬──────┐
│T │BBBBB │GGGGG │RRRRR │
│15│14  10│ 9   5│ 4   0│
└──┴──────┴──────┴──────┘
T = through-bit (priority override)
```

| PRI | Through-bit | Pixel appears... |
|-----|-------------|------------------|
| 0 | 0 | Behind Genesis (normal 32X position) |
| 0 | 1 | **In front of Genesis** (priority override) |
| 1 | 0 | In front of Genesis (normal 32X position) |
| 1 | 1 | **Behind Genesis** (priority override) |

**VRD usage:** Palette entry 1 is initialized to $8000 (through-bit + RGB black).
With PRI=0, pixels using palette index 1 render in front of the Genesis layer
as opaque black — useful for masking or border regions that must hide Genesis content.

### Transparency Rules

```
32X pixel = palette index $00  →  transparent (Genesis shows through)
Genesis pixel = color 0        →  transparent (32X or background shows through)
Both transparent               →  system background color (32X backdrop register)
```

Palette index $00 is the designated transparent value for the 32X layer. The SH2
writes $00 to framebuffer pixels that should show the Genesis background.

### Resolution Constraint

Both VDPs must output matching resolution when the 32X is non-blank:
- 320×224 (NTSC, 40-cell mode) — VRD's standard
- 320×240 (PAL only)

> **HAZARD — Palette access:** CRAM writes are only allowed when PEN=1
> (during H-blank or V-blank). Writing when PEN=0 produces undefined results.
> Direct Color mode is exempt (no palette lookup).

Source: [docs/32x-hardware-manual.md](../docs/32x-hardware-manual.md) §3.2.3,
[gfx_32x_vdp_mode_reg_setup.asm](../disasm/modules/68k/game/render/gfx_32x_vdp_mode_reg_setup.asm),
[mars_adapter_state_init_framebuffer_setup.asm](../disasm/modules/68k/game/render/mars_adapter_state_init_framebuffer_setup.asm)

---

## 10. Quick Reference

### Address Map

| Resource | 68K Address | SH2 Address | Notes |
|----------|-------------|-------------|-------|
| COMM0 | $A15120 | $20004020 | Dispatch trigger (HI) + index (LO) |
| COMM1 | $A15122 | $20004022 | System signal (bit 0 = "done") |
| COMM2-6 | $A15124-$A1512C | $20004024-$2000402C | Command parameters |
| COMM7 | $A1512E | $2000402E | Slave SH2 doorbell |
| Adapter Ctrl | $A15100 | $20004000 | FM bit (bit 7) |
| VDP Mode | $A15180 | $20004100 | PRI (bit 13), M1:M0 (bits 1:0) |
| FB Control | $A1518A | $2000410A | VBLK (15), PEN (13), FEN (1), FS (0) |
| CRAM | $A15200 | $20004200 | 256 × 16-bit palette entries |
| Frame Buffer | $840000 | $04000000 | DRAM (FM-controlled access) |
| Overwrite | $860000 | $04020000 | Byte $00 = transparent |

### COMM Register Layout (VRD Protocol)

| Register | Offset | Purpose |
|----------|--------|---------|
| COMM0_HI | +0 | $01 = command active (Master trigger) |
| COMM0_LO | +1 | Dispatch index ($22 = block copy, $25 = RLE) |
| COMM1 | +2,3 | Cleared by completion; LO bit 0 = "done" |
| COMM2_HI | +4 | **NEVER WRITTEN** (Slave polls this byte) |
| COMM2_LO | +5 | Words per row (D0/2) |
| COMM3_HI | +6 | Height in rows (D1) |
| COMM3_LO | +7 | Source address byte 2 (A0[23:16]) |
| COMM4 | +8,9 | Source address bytes 1:0 (A0[15:0]) |
| COMM5:6 | +10-13 | Destination pointer (A1) |
| COMM7 | +14,15 | Slave doorbell ($0027 = cmd_27 work) |

### Key Work RAM Variables

| Address | Size | Name | Purpose |
|---------|------|------|---------|
| $FFC80C | byte | frame_toggle | Software double-buffer tracking (bit 0) |
| $FFC87A | word | vint_dispatch | V-INT handler selector (pre-×4) |
| $FFC87E | word | game_state | Main game state machine |
| $FFC964 | long | frame_counter | Global frame count (V-INT incremented) |

### Key SH2 Addresses

| Address | Purpose |
|---------|---------|
| $020460 | Master dispatch loop (COMM0 polling) |
| $06000780 | Jump table base (dispatch index × 4) |
| $023010F0 | cmd22_single_shot (expansion ROM) |
| $02300500 | cmd25_single_shot (expansion ROM) |
| $020608 | inline_slave_drain (COMM7 check) |
| $060048D0 | Reciprocal lookup table (rasterizer) |

---

## 11. Bottleneck Summary

The rendering pipeline achieves ~20-24 FPS against a 60 FPS target. The bottleneck
is **architectural serialization**, not raw compute capacity.

| CPU | Utilization | Bottleneck |
|-----|-------------|------------|
| 68K | **100%** | Game logic + COMM polling = fully saturated |
| Master SH2 | 0-36% | Idle 80%+ waiting for 68K to submit commands |
| Slave SH2 | 78% | Busy with cmd $27, could accept more work |

**Root cause:** Each `sh2_send_cmd` call blocks the 68K until the Master SH2 finishes
the previous block copy. The 68K's frame time = game logic + 14 × (SH2 copy time).
These should overlap but are serialized by the COMM0_HI handshake.

**The 10.84% sh2_send_cmd hotspot** (`.wait_ready` loop at $00E360) is the 68K
waiting for COMM0_HI to clear — it's an implicit frame synchronization barrier.
Attempts to remove it (B-005) caused display corruption because the 68K outran
the SH2, swapping frames before copies completed.

See [OPTIMIZATION_PLAN.md](../OPTIMIZATION_PLAN.md) for the full optimization strategy.
