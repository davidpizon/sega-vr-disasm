; ============================================================================
; sh2_object_and_sprite_update_orch — SH2 Object and Sprite Update Orchestrator
; Per-frame SH2 communication orchestrator. Sends DMA transfer, runs
; object_update + sprite_update, then transfers 3D geometry and sprite
; data via sh2_send_cmd. Computes text overlay addresses from palette
; index with MULU multiplication. Renders text overlays via
; text_render. Sends final sh2_cmd_27 for tile updates. Handles
; exit via button detection with fade-out transition ($A8 sound).
;
; Stage 1: Sends entity visibility bitmask to SH2 before first sh2_send_cmd.
;
; Uses: D0, D1, D2, D3, D4, A0, A1, A2
; Calls: object_update, animated_seq_player, sh2_send_cmd, sh2_cmd_27,
;        ByteProcessLoop, MemoryInit
; Confidence: high
; ============================================================================

; --- Per-frame init: memory, objects, sprites ---
sh2_object_and_sprite_update_orch:
        CLR.W  D0
        jsr     MemoryInit(pc)
        jsr     object_update(pc)
        jsr     animated_seq_player+10(pc)
; --- Stage 1: Send entity visibility bitmask to SH2 ---
; Wait for COMM ready, build 15-bit bitmask from D5 flags at $FF6218
; (stride $3C, 15 entities), send via COMM cmd $07.
; SH2 handler stores bitmask to SDRAM $2203E020.
.vis_wait:
        TST.B  COMM0_HI                         ; SH2 busy?
        BNE.S  .vis_wait
        LEA     $00FF6218,A0                    ; entity visibility table base
        MOVEQ   #0,D2                           ; bitmask accumulator
        MOVEQ   #14,D1                          ; 15 entities (0-14)
        MOVEQ   #1,D0                           ; bit 0
.vis_build:
        TST.W   (A0)                            ; D5 flag (0=invisible, !0=visible)
        BEQ.S   .vis_skip
        OR.W    D0,D2                           ; set bit for visible entity
.vis_skip:
        ADD.W   D0,D0                           ; shift bit left
        LEA     $3C(A0),A0                      ; next entity entry (stride $3C)
        DBRA    D1,.vis_build
        MOVE.W  D2,COMM3                        ; COMM3 = visibility bitmask
        MOVE.W  #$0107,COMM0_HI                 ; COMM0 = trigger ($01) + index ($07)
; --- Send 3D geometry to SH2 ---
.wait_comm_ready:
        TST.B  COMM0_HI                         ; SH2 busy? (waits for vis cmd done)
        BNE.S  .wait_comm_ready
        MOVEA.L #$06037000,A0                    ; 3D geo src (SDRAM)
        MOVEA.L #$24018010,A1                    ; frame buf dst
        MOVE.W  #$0120,D0                        ; width = 288
        MOVE.W  #$0030,D1                        ; height = 48
        bsr.w   sh2_send_cmd
; --- Send overlay tiles (5 panels, bit-masked) ---
        BTST    #7,(-600).W                     ; overlays disabled?
        BNE.S  .send_sprite_data                ; skip overlays
        MOVEA.L #$0603A600,A0                   ; overlay base addr
        MOVEQ   #$00,D3                         ; panel index
        MOVE.W  #$0004,D4                       ; 5 panels (0-4)
.overlay_loop:
        BTST    D3,(-4345).W                    ; panel enabled?
        BEQ.S  .next_overlay                    ; skip disabled
        LEA     $0088DEB6,A1                    ; overlay addr table
        MOVE.W  D3,D0                           ; index
        ADD.W   D0,D0                           ; *4 (longword)
        ADD.W   D0,D0
        MOVEA.L $00(A1,D0.W),A1                 ; dest address
        MOVE.W  #$0010,D0                        ; width = 16
        MOVE.W  #$0010,D1                        ; height = 16
        bsr.w   sh2_send_cmd
.next_overlay:
        ADDQ.W  #1,D3                           ; next panel
        DBRA    D4,.overlay_loop
; --- Send sprite data block ---
.send_sprite_data:
        MOVEA.L #$0603B600,A0                   ; sprite src (SDRAM)
        MOVEA.L #$24014010,A1                   ; sprite dst
        MOVE.W  #$0120,D0                        ; width = 288
        MOVE.W  #$0018,D1                        ; height = 24
        bsr.w   sh2_send_cmd
; --- Text overlay 1: compute address from palette index ---
; Address = base + cam_idx * 160 (MULU replaces shift+add chain)
        LEA     $24034850,A1                    ; SH2 text dest
        LEA     (-4344).W,A2                    ; text data base
        ADDA.L  (-24536).W,A2                   ; + scroll offset
        MOVEQ   #$00,D0
        MOVE.B  (-24551).W,D0                   ; cam/palette index
        MULU    #160,D0                         ; *160 (bytes)
        ADDA.L  D0,A2                           ; offset into table
        BTST    #7,(-600).W                     ; override mode?
        BEQ.S  .use_text_addr
        LEA     $0088DECA,A2                    ; use fixed addr
.use_text_addr:
        jsr     ByteProcessLoop(pc)             ; render text 1
; --- Text overlay 2: second text block with different base ---
        LEA     $240348E8,A1                    ; SH2 text dest 2
        LEA     (-1464).W,A2                    ; text data base 2
        MOVEQ   #$00,D0
        MOVE.B  (-335).W,D0                     ; palette slot A
; multiply by 48: MULU replaces shift+add chain
        MULU    #48,D0                          ; *48 (bytes)
        ADDA.L  D0,A2                           ; offset into table
; add cam_idx sub-offset (*8 + 4)
        MOVEQ   #$00,D0
        MOVE.B  (-24551).W,D0                   ; cam/palette index
        ASL.W   #3,D0                           ; *8
        ADDQ.W  #4,D0                           ; +4 header offset
        ADDA.L  D0,A2                           ; final addr
        BTST    #7,(-600).W                     ; override mode?
        BEQ.S  .use_text_addr_2
        LEA     $0088DECA,A2                    ; use fixed addr
.use_text_addr_2:
        jsr     ByteProcessLoop(pc)             ; render text 2
; --- Send tile update via SH2 cmd 27 ---
        MOVEQ   #$00,D0
        MOVE.B  (-24551).W,D0                   ; cam index
; lookup from 6-byte entry table (ptr:4 + param:2)
        LEA     $0088DE98,A1                    ; tile cmd table
        MULU    #6,D0                           ; *6 table stride
        MOVEA.L $00(A1,D0.W),A0                 ; tile src addr
        MOVE.W  $04(A1,D0.W),D0                 ; tile param
        MOVE.W  #$0030,D1                       ; width = 48
        MOVE.W  #$0010,D2                       ; height = 16
.wait_comm_ready_2:
        TST.B  COMM0_HI                        ; SH2 busy?
        BNE.S  .wait_comm_ready_2
        bsr.w   sh2_cmd_27                      ; send tile cmd
; --- Frame timing + exit state machine ---
        MOVE.W  #$0018,$00FF0008                ; V-INT period = 24
        CMPI.W  #$0001,(-24532).W               ; fade state 1?
        BEQ.S  .check_fade_done
        CMPI.W  #$0002,(-24532).W               ; fade state 2?
        BEQ.S  .check_fade_complete
; --- Button input ---
        MOVE.W  (-14228).W,D1                   ; P1 buttons
        ANDI.B  #$E0,D1                         ; A/B/C mask
        BNE.S  .begin_fadeout                    ; action → exit
        MOVE.W  (-14228).W,D1                   ; re-read buttons
        ANDI.B  #$10,D1                         ; Start mask
        BNE.S  .set_exit_flag                   ; Start → exit
        SUBQ.W  #8,(-14210).W                   ; tick timer
        BRA.S  .finish
.set_exit_flag:
        ST      (-24552).W                      ; set exit flag
; --- Begin exit transition ---
.begin_fadeout:
        MOVE.B  #$A8,(-14172).W                 ; SFX: confirm
        MOVE.B  #$01,(-14327).W                 ; fade flag 1
        MOVE.B  #$01,(-14326).W                 ; fade flag 2
        BSET    #7,(-14322).W                   ; trigger fade-out
        MOVE.B  #$01,(-14334).W                 ; transition active
        MOVE.W  #$0002,(-24532).W               ; state → phase 2
        BRA.S  .dec_timer
; --- Fade state handlers ---
.check_fade_done:
        BTST    #6,(-14322).W                   ; phase 1 done?
        BNE.S  .dec_timer                       ; still fading
        CLR.W  (-24532).W                       ; reset state
        BRA.S  .dec_timer
.check_fade_complete:
        BTST    #7,(-14322).W                   ; phase 2 done?
        BNE.S  .dec_timer                       ; still fading
        CLR.W  (-24532).W                       ; reset state
        ADDQ.W  #4,(-14210).W                   ; advance scene
        BRA.S  .finish
.dec_timer:
        SUBQ.W  #8,(-14210).W                   ; tick timer
.finish:
        MOVE.B  #$01,(-14303).W                 ; frame ready flag
        RTS
