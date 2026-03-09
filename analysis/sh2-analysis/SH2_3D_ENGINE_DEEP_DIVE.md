# SH2 3D Engine — Algorithmic Deep Dive

Detailed algorithmic analysis of the SH2 3D rendering engine used in Virtua Racing Deluxe.
Covers the internal workings of key pipeline stages: visibility testing, rasterization,
shading, and data flow.

**Last Updated**: March 8, 2026

## 1. Pipeline Overview

```
┌──────────────────────────────────────────────────────────────────┐
│  68K Scene Setup → COMM Command → Master SH2 Dispatch           │
│                                                                  │
│  SH2 Pipeline Stages:                                           │
│                                                                  │
│  ┌─────────────┐   ┌──────────────┐   ┌───────────────────┐    │
│  │ Transform    │──▶│ Visibility   │──▶│ Rasterization     │    │
│  │ mat_vec_mul  │   │ frustum_cull │   │ render_quad +     │    │
│  │ coord_pack   │   │ bounds_check │   │ span_filler       │    │
│  └─────────────┘   └──────────────┘   └───────────────────┘    │
│         │                                       │                │
│  ┌──────┴──────┐                    ┌───────────┴──────────┐    │
│  │ Matrix ×    │                    │ Framebuffer Write    │    │
│  │ Vector      │                    │ raster_batch →       │    │
│  │ (MAC.L)     │                    │ unrolled_data_copy   │    │
│  └─────────────┘                    └──────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
```

**Key stats**: 92 function IDs, ~8KB total code, 109 entry points (including sub-functions).

## 2. Transformation Pipeline

### Matrix × Vector Multiplication (`matrix_multiply` / `alt_matrix_multiply`)

The core vertex transform uses the SH2's hardware MAC (Multiply-Accumulate) unit:

- **matrix_multiply** (88 bytes): 4×4 matrix × 3D vector using `MAC.L @Rm+,@Rn+`
- **alt_matrix_multiply** (56 bytes): Variant with different register setup
- **Throughput**: ~45 cycles/vertex (hardware MAC advantage)
- **Called by**: `transform_loop` and `alt_transform_loop`

### Coordinate Packing (`coord_transform`)

The **single hottest function** in the 3D engine (17% of Slave SH2 time):

- 34 bytes at `$023368`
- Packs screen X/Y coordinates using bit operations
- Called 4× per quad by `quad_batch` / `quad_batch_alt`
- Inlining analysis: infeasible due to tight register coupling (see `COORD_TRANSFORM_INLINING_INFEASIBILITY.md`)

### Quad Batch Processing

Two parallel paths for quad vertex processing:

| Function | Size | Purpose |
|----------|------|---------|
| `quad_batch` | varies | Main quad array processor, calls `coord_transform` ×4 |
| `quad_batch_alt` | varies | Alternative path (different vertex layout?) |
| `vertex_helper` | small | Loop wrapper around utility at `$02350A` |
| `vertex_transform` | medium | Full vertex transform loop (Slave offload target) |

## 3. Visibility Pipeline

### Frustum Culling Hub (`frustum_cull_short`)

The **largest standalone function** (238 bytes). Acts as the central visibility dispatcher:

```
                    frustum_cull_short
                     ┌──────┐
                     │ Load │ vertex data from polygon descriptor
                     │ Test │ bounding box min/max
                     └──┬───┘
                        │
         ┌──────────────┼──────────────┐
         ▼              ▼              ▼
    screen_coords  bounds_compare  visibility
    (3D→2D proj)   (X-axis test)  (Y-axis + clip)
         │              │              │
         └──────────────┴──────┬───────┘
                               │
                 ┌─────────────┼─────────────┐
                 ▼             ▼             ▼
            scanline_setup  render_quad  render_dispatch
            (path B)        (path C)     (path D)
```

**Algorithm**:
1. Load 4 vertex coordinates from polygon descriptor (20-byte stride)
2. Call `screen_coords` for 3D→2D projection
3. Call `bounds_compare` for X-axis bounding box (min/max tracking)
4. Call `visibility` for Y-axis bounds + clip flags
5. CMP/GT tests on vertex pairs → determine visibility
6. Dispatch to one of 4 render paths based on visibility result:
   - Path A: fully culled (no render)
   - Path B: `scanline_setup` → basic rasterization
   - Path C: `render_quad` → edge-walking quad rasterizer
   - Path D: `render_dispatch` → display list polygon processor

### Bounding Box Classification

| Function | Axis | Output |
|----------|------|--------|
| `bounds_compare` | X | Min/max tracking across vertices |
| `visibility` | Y | Bounds + clip flag assignment |

**Clip flags** (set per vertex):
- `0` = fully inside viewport
- `4` = clipped at edge A (top or left)
- `8` = clipped at edge B (bottom or right)
- `12` = clipped at both edges

The clip flags select rendering mode: TST #8,R0 distinguishes between flat rendering and clipped edge handling.

## 4. Rasterization Pipeline

### Edge Walking (`render_quad_short`)

Classic quad edge-walking algorithm (98 bytes):

```
render_quad_short (func_033)
  │
  ├─ Load edge buffer pointer from literal pool → R8
  ├─ MAC.W @R8+,@R9+  — hardware edge interpolation
  ├─ EXTS.B R1,R4     — extract edge parameters
  │
  ├─ Path 1: left-edge-first
  │   └─ BSR span_filler (R9 output)
  │
  └─ Path 2: right-edge-first
      └─ BSR span_filler (R13 output)
```

- Uses SH2 MAC.W for hardware-accelerated edge interpolation
- Two edge-walking paths for left-to-right vs right-to-left polygon orientation
- Calls `span_filler` twice (once per edge transition)

### Span Filling (`span_filler_short`)

Bresenham-style edge interpolation (122 bytes):

**Input**: Packed vertex pairs (Y1:X1 in R1, Y2:X2 in R2)
**Output**: Interpolated edge values to R9/R13 buffers

```
span_filler (func_034)
  │
  ├─ MOV.W @R9,R0    — store edge value A
  ├─ SWAP.W R1       — unpack Y1 from high word
  ├─ EXTS.W R1       — sign-extend Y coordinate
  ├─ SUB R1,R2       — ΔY = Y2 - Y1
  │
  ├─ [Large delta path]:
  │   ├─ MOV.L @(disp,PC),R3  → reciprocal table at $060048D0
  │   ├─ MOV.W @(R0,R3),R3    — table lookup: 1/ΔY
  │   ├─ MULS.W R3,R0         — ΔX * (1/ΔY) = slope
  │   └─ SHLL2 R0             — scale result
  │
  └─ [Small delta path]:
      └─ MULS.W R2,R0         — direct multiply for small deltas
```

**Key observations**:
- **Position-only interpolation** — no color values are interpolated
- Reciprocal lookup table at `$060048D0` (SH2 SDRAM address) for fast division
- Two-path design: large ΔY uses table lookup + multiply, small ΔY uses direct multiply
- First instruction (`$2902` = MOV.L R0,@R9) is shared as `render_quad`'s RTS delay slot

### Display List Rendering (`render_dispatch_short`)

Processes a display list of polygon entries (0xFF-terminated):

- Iterates through polygon descriptors in display list
- Each entry: active flag, polygon type, 4 vertex indices, color, texture
- Dispatches individual polygons to the appropriate render path
- 60-byte stride per display list entry

## 5. Shading Model

### Flat Shading — Confirmed

**No Gouraud shading, no texture interpolation** in the VRD 3D engine.

Evidence:
1. `span_filler` interpolates **position only** (X/Y edge coordinates)
2. `render_quad` sets up edge buffers with position data, not color gradients
3. No per-pixel color computation in any rasterization function
4. Color is pre-stored in edge buffers as a constant per polygon
5. Pixel writes use 8bpp palette index (single color per polygon face)

### Color Pipeline

```
Polygon descriptor → color field (+0x0C) → palette index
  │
  ├─ Stored in edge buffer as constant
  ├─ Copied to framebuffer via raster_batch → unrolled_data_copy
  └─ 8bpp indexed color → 32X CRAM palette lookup
```

The `raster_batch` functions (a/b/c/d) coordinate the actual pixel writes,
calling `unrolled_data_copy` which performs unrolled 14×8-byte block copies
with stride for fast framebuffer filling.

## 6. Data Flow

### Memory Layout

| Region | Address | Purpose |
|--------|---------|---------|
| Edge buffer | `$C0000740` | Interpolated edge values (position + color) |
| Display list A | `$C00007C0` | Polygon descriptor array |
| Display list B | `$C00007E0` | Secondary display list |
| Reciprocal LUT | `$060048D0` | 1/N lookup table for fast division |
| Framebuffer 0 | `$04000000` | 32X VDP framebuffer (current) |
| Framebuffer 1 | `$04020000` | 32X VDP framebuffer (back) |

### Polygon Descriptor Format

Each polygon descriptor is 20 bytes:

```
Offset  Size  Field
+0x00   1     active_flag (0 = skip, non-zero = process)
+0x01   1     poly_type (encoding unknown — selects render path?)
+0x02   8     vertex_indices[4] (2 bytes each, index into vertex array)
+0x0A   2     (unknown)
+0x0C   2     color_field (palette index? encoding unknown)
+0x0E   2     (unknown)
+0x10   4     texture_field (format unknown — may be unused)
```

### Data Copy Functions

| Function | Size | Purpose |
|----------|------|---------|
| `data_copy` | 26B | Copy 12 longwords (48B) to `$C0000740` |
| `data_copy_util_short` | varies | General data copy utility |
| `unrolled_data_copy` | varies | Unrolled 14×8B block copy with stride |
| `array_copy_short` | varies | Array copy with stride advance |
| `block_copy_stride_short` | varies | Block copy with configurable stride |
| `block_copy_14_short` | varies | 14-block copy variant |

## 7. Display Engine (Functions 040-059)

The display engine is a large subsystem with 12 entry points via jump table:

| Function | Purpose |
|----------|---------|
| `display_list_short` | Main entry, 12-case jump table |
| `display_cases_short` | Case handler implementations |
| `display_utility_short` | Utility operations |
| `render_coord_short` | Coordinate setup for rendering |
| `dispatch_loop_short` | Dispatcher loop with BSRF |
| `array_copy_short` | Array copy operations |
| `bounds_check/handler/entry` | Bounds validation group |
| `multi_bsr_short` et al. | BSR forwarding variants |

## 8. Utility Functions (066-091)

### RLE Decoder (`rle_decoder`)

Run-length decoder for compressed data:
- `rle_decoder`: Main decoder logic
- `rle_entry_alt1_short` / `rle_entry_alt2_short`: Alternative entry points

### Polling / Hardware Utilities

Small functions for hardware synchronization:
- `wait_ready`: Poll hardware status bit
- `poll_wait_short` / `poll_wait_2_short`: Wait loops
- `poll_zero_short` / `poll_zero_alt_short`: Poll until zero
- `hw_init_short`: Hardware register initialization (COMM0/COMM1 cleanup)
- `poll_branch_short`: Poll with conditional branch
- `struct_init_short`: Structure initialization from R14
- `clear_reg_short`: Register clear utility
- `memory_clear_short`: Memory zeroing

## 9. Remaining Unknowns

### High Priority

| Unknown | Location | Notes |
|---------|----------|-------|
| `poly_type` encoding | Descriptor +0x01 | Controls render path selection? Values observed? |
| Color field format | Descriptor +0x0C | Direct palette index? Packed RGB? Bit width? |
| Z-buffer presence | Multiple refs | `depth_buffer_ptr` references exist but unverified |
| Reciprocal table contents | `$060048D0` | Size, range, precision of 1/N table |

### Medium Priority

| Unknown | Location | Notes |
|---------|----------|-------|
| Texture field | Descriptor +0x10 | Is there any texture mapping? Format? |
| Display list entry details | 60-byte stride | Full field breakdown not documented |
| BSR forwarding logic | Functions 050-055 | Why 6 separate BSR forwarding stubs? |
| `display_engine` case table | 12 cases | What triggers each case? |

### Low Priority

| Unknown | Location | Notes |
|---------|----------|-------|
| Negative handler/fill | Functions 073, 078, 079 | Edge cases? Error handling? |
| Element processor | Function 072 | Processing loop — for what elements? |
| Value dispatch | Function 077 | Dispatches on 0/0x80/positive/negative — what values? |

## 10. Function ID Cross-Reference

For historical context, mapping between old numeric IDs and new descriptive names:

| Old ID | New Name | Category |
|--------|----------|----------|
| func_000 | `data_copy` | Transform |
| func_001 | `main_coordinator_short` | Transform |
| func_002 | `case_handlers_short` | Transform |
| func_003/004 | `offset_copy_short` | Transform |
| func_005 | `transform_loop` | Transform |
| func_006 | `matrix_multiply` | Transform |
| func_007 | `alt_transform_loop` | Transform |
| func_008 | `alt_matrix_multiply` | Transform |
| func_009 | `display_list_4elem` | Transform |
| func_010 | `display_list_3elem` | Transform |
| func_011 | `display_list_loop` | Transform |
| func_012 | `display_entry` | Transform |
| func_013 | `vdp_init_short` | VDP |
| func_014/015 | `vdp_copy_short` | VDP |
| func_016 | `coord_transform` | Transform |
| func_017 | `quad_helper` | Polygon Batch |
| func_018 | `quad_batch_short` | Polygon Batch |
| func_019 | `quad_batch_alt_short` | Polygon Batch |
| func_020 | `vertex_helper_short` | Polygon Batch |
| func_021 | `vertex_transform_orig` | Polygon Batch |
| func_022 | `wait_ready` | Polling |
| func_023 | `frustum_cull_short` | Visibility |
| func_024 | `screen_coords_short` | Visibility |
| func_025 | `coord_offset_short` | Visibility |
| func_026 | `bounds_compare_short` | Visibility |
| func_029/030/031 | `visibility_short` | Visibility |
| func_032 | `scanline_setup` | Rasterization |
| func_033 | `render_quad_short` | Rasterization |
| func_034 | `span_filler_short` | Rasterization |
| func_036 | `render_dispatch_short` | Rasterization |
| func_037/038/039 | `helpers_short` | Rasterization |
| func_040 | `display_list_short` | Display Engine |
| func_040_cases | `display_cases_short` | Display Engine |
| func_040_utility | `display_utility_short` | Display Engine |
| func_041-055 | Various display/bounds/BSR | Display Engine |
| func_060-063 | `raster_batch` | Batch Rasterization |
| func_065 | `unrolled_data_copy` | Data Copy |
| func_066 | `rle_decoder` | Data Processing |
| func_067/068 | `rle_entry_alt1/2_short` | Data Processing |
| func_069-074 | Various block copy/iterate | Data Processing |
| func_075-079 | Various VDP/fill/dispatch | Utilities |
| func_080 | `memory_clear_short` | Utilities |
| func_081-083 | Various JSR/poll | Utilities |
| func_084 | `hw_init_short` | Hardware Init |
| func_085-091 | Various poll/init | Utilities |
