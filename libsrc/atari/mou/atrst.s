;
; Mouse driver for ST & Amiga mouses and Atari trakball.
;
; Original access routines: 05/07/2000 Freddy Offenga
; Converted to driver: Christian Groessler, 2014-01-04
;
; Defines:
;       AMIGA_MOUSE     -       builds Amiga mouse version
;       TRAK_MOUSE      -       builds trakball version
; If none of these defines are active, the ST mouse version
; is being built.
;

        .include        "zeropage.inc"
        .include        "mouse-kernel.inc"
        .include        "atari.inc"

        .macpack        generic

.if .not ( .defined (AMIGA_MOUSE) .or .defined (TRAK_MOUSE))
        ST_MOUSE = 1
.endif

; ------------------------------------------------------------------------
; Header. Includes jump table

.segment        "JUMPTABLE"

HEADER:

; Driver signature

        .byte   $6d, $6f, $75           ; "mou"
        .byte   MOUSE_API_VERSION       ; Mouse driver API version number

; Library reference

libref: .addr   $0000

; Jump table

        .addr   INSTALL
        .addr   UNINSTALL
        .addr   HIDE
        .addr   SHOW
        .addr   SETBOX
        .addr   GETBOX
        .addr   MOVE
        .addr   BUTTONS
        .addr   POS
        .addr   INFO
        .addr   IOCTL
        .addr   IRQ

; Mouse driver flags

        .byte   MOUSE_FLAG_LATE_IRQ

; Callback table, set by the kernel before INSTALL is called

CHIDE:  jmp     $0000                   ; Hide the cursor
CSHOW:  jmp     $0000                   ; Show the cursor
CMOVEX: jmp     $0000                   ; Move the cursor to X coord
CMOVEY: jmp     $0000                   ; Move the cursor to Y coord


;----------------------------------------------------------------------------
; Constants

SCREEN_HEIGHT   = 191
SCREEN_WIDTH    = 319

.enum   JOY
        UP      = $01
        DOWN    = $02
        LEFT    = $04
        RIGHT   = $08
.endenum

;----------------------------------------------------------------------------
; Global variables. The bounding box values are sorted so that they can be
; written with the least effort in the SETBOX and GETBOX routines, so don't
; reorder them.

.bss

Vars:
YPos:           .res    2               ; Current mouse position, Y
XPos:           .res    2               ; Current mouse position, X
XMin:           .res    2               ; X1 value of bounding box
YMin:           .res    2               ; Y1 value of bounding box
XMax:           .res    2               ; X2 value of bounding box
YMax:           .res    2               ; Y2 value of bounding box
Buttons:        .res    1               ; Button mask

XPosWrk:        .res    2
YPosWrk:        .res    2

visible:        .res    1

.if .defined (AMIGA_MOUSE) .or .defined (ST_MOUSE)
dumx:           .res    1
dumy:           .res    1
.endif

.ifdef TRAK_MOUSE
oldval:         .res    1
.endif

.ifndef __ATARIXL__
OldT1:          .res    2
.else

.data
set_VTIMR1_handler:
                .byte   $4C, 0, 0
.endif

.rodata

; Default values for some of the above variables
; (We use ".proc" because we want to define both a label and a scope.)

.proc   DefVars
        .word   (SCREEN_HEIGHT+1)/2     ; YPos
        .word   (SCREEN_WIDTH+1)/2      ; XPos
        .word   0                       ; XMin
        .word   0                       ; YMin
        .word   SCREEN_WIDTH            ; XMax
        .word   SCREEN_HEIGHT           ; YMax
        .byte   0                       ; Buttons
.endproc

.ifdef ST_MOUSE

; ST mouse lookup table

STTab:  .byte $FF,$01,$00,$01
        .byte $00,$FF,$00,$01
        .byte $01,$00,$FF,$00
        .byte $01,$00,$01,$FF

.endif

.ifdef AMIGA_MOUSE

; Amiga mouse lookup table

AmiTab: .byte $FF,$01,$00,$FF
        .byte $00,$FF,$FF,$01
        .byte $01,$FF,$FF,$00
        .byte $FF,$00,$01,$FF

.endif

.code

;----------------------------------------------------------------------------
; INSTALL routine. Is called after the driver is loaded into memory. If
; possible, check if the hardware is present.
; Must return an MOUSE_ERR_xx code in a/x.

INSTALL:

; Initialize variables. Just copy the default stuff over

        ldx     #.sizeof(DefVars)-1
@L1:    lda     DefVars,x
        sta     Vars,x
        dex
        bpl     @L1

; Be sure the mouse cursor is invisible and at the default location.

        jsr     CHIDE
        lda     XPos
        sta     XPosWrk
        ldx     XPos+1
        stx     XPosWrk+1
        jsr     CMOVEX
        lda     YPos
        sta     YPosWrk
        ldx     YPos+1
        stx     YPosWrk+1
        jsr     CMOVEY

; Install timer irq routine to poll mouse.

.ifdef __ATARIXL__

        ; Setup pointer to wrapper install/deinstall function.
        lda     libref
        sta     set_VTIMR1_handler+1
        lda     libref+1
        sta     set_VTIMR1_handler+2

        ; Install my handler.
        sec
        lda     #<T1Han
        ldx     #>T1Han
        jsr     set_VTIMR1_handler

.else

        lda     VTIMR1
        sta     OldT1
        lda     VTIMR1+1
        sta     OldT1+1

        php
        sei
        lda     #<T1Han
        sta     VTIMR1
        lda     #>T1Han
        sta     VTIMR1+1
        plp

.endif

        lda     #%00000001
        sta     AUDCTL

        lda     #0
        sta     AUDC1

        lda     #15
        sta     AUDF1
        sta     STIMER

        lda     POKMSK
        ora     #%00000001              ; timer 1 enable
        sta     POKMSK
        sta     IRQEN

; Done, return zero (= MOUSE_ERR_OK)

        ldx     #$00
        txa
        rts

;----------------------------------------------------------------------------
; UNINSTALL routine. Is called before the driver is removed from memory.
; No return code required (the driver is removed from memory on return).

UNINSTALL:

; uninstall timer irq routine

        lda     POKMSK
        and     #%11111110              ; timer 1 disable
        sta     IRQEN
        sta     POKMSK

.ifdef __ATARIXL__

        clc
        jsr     set_VTIMR1_handler

.else

        php
        sei
        lda     OldT1
        sta     VTIMR1
        lda     OldT1+1
        sta     VTIMR1+1
        plp

.endif
        ; fall thru...

;----------------------------------------------------------------------------
; HIDE routine. Is called to hide the mouse pointer. The mouse kernel manages
; a counter for calls to show/hide, and the driver entry point is only called
; if the mouse is currently visible and should get hidden. For most drivers,
; no special action is required besides hiding the mouse cursor.
; No return code required.

HIDE:   dec     visible
        php
        sei
        jsr     CHIDE
        plp
        rts

;----------------------------------------------------------------------------
; SHOW routine. Is called to show the mouse pointer. The mouse kernel manages
; a counter for calls to show/hide, and the driver entry point is only called
; if the mouse is currently hidden and should become visible. For most drivers,
; no special action is required besides enabling the mouse cursor.
; No return code required.

SHOW:   inc     visible
        php
        sei
        jsr     CSHOW
        plp
        rts

;----------------------------------------------------------------------------
; SETBOX: Set the mouse bounding box. The parameters are passed as they come
; from the C program, that is, a pointer to a mouse_box struct in a/x.
; No checks are done if the mouse is currently inside the box, this is the job
; of the caller. It is not necessary to validate the parameters, trust the
; caller and save some code here. No return code required.

SETBOX: sta     ptr1
        stx     ptr1+1                  ; Save data pointer

        ldy     #.sizeof (MOUSE_BOX)-1
        php
        sei

@L1:    lda     (ptr1),y
        sta     XMin,y
        dey
        bpl     @L1

        plp
        rts

;----------------------------------------------------------------------------
; GETBOX: Return the mouse bounding box. The parameters are passed as they
; come from the C program, that is, a pointer to a mouse_box struct in a/x.

GETBOX: sta     ptr1
        stx     ptr1+1                  ; Save data pointer

        ldy     #.sizeof (MOUSE_BOX)-1
        php
        sei

@L1:    lda     XMin,y
        sta     (ptr1),y
        dey
        bpl     @L1

        plp
        rts

;----------------------------------------------------------------------------
; MOVE: Move the mouse to a new position. The position is passed as it comes
; from the C program, that is: X on the stack and Y in a/x. The C wrapper will
; remove the parameter from the stack on return.
; No checks are done if the new position is valid (within the bounding box or
; the screen). No return code required.
;

MOVE:   php
        sei                             ; No interrupts

        pha
        txa
        pha

        lda     visible
        beq     @L01

        jsr     CHIDE

@L01:   pla
        tax
        pla

        sta     YPos
        sta     YPosWrk
        stx     YPos+1                  ; New Y position
        stx     YPosWrk+1
        jsr     CMOVEY                  ; Set it

        ldy     #$01
        lda     (sp),y
        sta     XPos+1
        sta     XPosWrk+1
        tax
        dey
        lda     (sp),y
        sta     XPos                    ; New X position
        sta     XPosWrk

        jsr     CMOVEX                  ; Move the cursor

        lda     visible
        beq     @Ret

        jsr     CSHOW

@Ret:   plp                             ; Restore interrupt flag
        rts

;----------------------------------------------------------------------------
; BUTTONS: Return the button mask in a/x.

BUTTONS:
        lda     Buttons
        ldx     #$00
        rts

;----------------------------------------------------------------------------
; POS: Return the mouse position in the MOUSE_POS struct pointed to by ptr1.
; No return code required.

POS:    ldy     #MOUSE_POS::XCOORD      ; Structure offset

        php
        sei                             ; Disable interrupts
        lda     XPos                    ; Transfer the position
        sta     (ptr1),y
        lda     XPos+1
        iny
        sta     (ptr1),y
        lda     YPos
        iny
        sta     (ptr1),y
        lda     YPos+1
        plp                             ; Restore interrupt flag

        iny
        sta     (ptr1),y                ; Store last byte

        rts                             ; Done

;----------------------------------------------------------------------------
; INFO: Returns mouse position and current button mask in the MOUSE_INFO
; struct pointed to by ptr1. No return code required.
;
; We're cheating here to keep the code smaller: The first fields of the
; mouse_info struct are identical to the mouse_pos struct, so we will just
; call _mouse_pos to initialize the struct pointer and fill the position
; fields.

INFO:   jsr     POS

; Fill in the button state

        lda     Buttons
        ldy     #MOUSE_INFO::BUTTONS
        sta     (ptr1),y

        rts

;----------------------------------------------------------------------------
; IOCTL: Driver defined entry point. The wrapper will pass a pointer to ioctl
; specific data in ptr1, and the ioctl code in A.
; Must return an error code in a/x.
;

IOCTL:  lda     #<MOUSE_ERR_INV_IOCTL     ; We don't support ioclts for now
        ldx     #>MOUSE_ERR_INV_IOCTL
        rts

;----------------------------------------------------------------------------
; IRQ: Irq handler entry point. Called as a subroutine but in IRQ context
; (so be careful). The routine MUST return carry set if the interrupt has been
; 'handled' - which means that the interrupt source is gone. Otherwise it
; MUST return carry clear.
;

IRQ:

; Check for a pressed button and place the result into Buttons

        ldx     #0
        lda     TRIG0                   ; joystick #0 trigger
        bne     @L0                     ; not pressed
        ldx     #MOUSE_BTN_LEFT
@L0:    stx     Buttons

        ldx     visible
        beq     @L1
        jsr     CHIDE

; Limit the X coordinate to the bounding box

@L1:    lda     XPosWrk+1
        ldy     XPosWrk
        tax
        cpy     XMin
        sbc     XMin+1
        bpl     @L2
        ldy     XMin
        ldx     XMin+1
        jmp     @L3
@L2:    txa

        cpy     XMax
        sbc     XMax+1
        bmi     @L3
        ldy     XMax
        ldx     XMax+1
@L3:    sty     XPos
        stx     XPos+1

        tya
        jsr     CMOVEX

; Limit the Y coordinate to the bounding box

        lda     YPosWrk+1
        ldy     YPosWrk
        tax
        cpy     YMin
        sbc     YMin+1
        bpl     @L4
        ldy     YMin
        ldx     YMin+1
        jmp     @L5
@L4:    txa

        cpy     YMax
        sbc     YMax+1
        bmi     @L5
        ldy     YMax
        ldx     YMax+1
@L5:    sty     YPos
        stx     YPos+1

        tya
        jsr     CMOVEY

        ldx     visible
        beq     @Done

        jsr     CSHOW

@Done:  clc
        rts

;----------------------------------------------------------------------------
; T1Han: Local IRQ routine to poll mouse
;

T1Han:  tya
        pha
        txa
        pha

.ifdef DEBUG
        lda     RANDOM
        sta     COLBK
.endif

        lda     PORTA
        tay

.ifdef ST_MOUSE

; ST mouse version

        and     #%00000011
        ora     dumx
        tax
        lda     STTab,x
        bmi     nxst

        beq     xist

        dec     XPosWrk
        lda     XPosWrk
        cmp     #255
        bne     nxst
        dec     XPosWrk+1
        jmp     nxst

xist:   inc     XPosWrk
        bne     nxst
        inc     XPosWrk+1

nxst:   tya
        and     #%00001100
        ora     dumy
        tax
        lda     STTab,x
        bmi     nyst

        bne     yst

        dec     YPosWrk
        lda     YPosWrk
        cmp     #255
        bne     nyst
        dec     YPosWrk+1
        jmp     nyst

yst:    inc     YPosWrk
        bne     nyst
        inc     YPosWrk+1

; store old readings

nyst:   tya
        and     #%00000011
        asl
        asl
        sta     dumx
        tya
        and     #%00001100
        lsr
        lsr
        sta     dumy

.elseif .defined (AMIGA_MOUSE)

; Amiga mouse version

        lsr
        and     #%00000101
        ora     dumx
        tax
        lda     AmiTab,x
        bmi     nxami

        bne     xiami

        dec     XPosWrk
        lda     XPosWrk
        cmp     #255
        bne     nxami
        dec     XPosWrk+1
        jmp     nxami

xiami:  inc     XPosWrk
        bne     nxami
        inc     XPosWrk+1

nxami:  tya

        and     #%00000101
        ora     dumy
        tax
        lda     AmiTab,x
        bmi     nyami

        bne     yiami

        dec     YPosWrk
        lda     YPosWrk
        cmp     #255
        bne     nyami
        dec     YPosWrk+1
        jmp     nyami

yiami:  inc     YPosWrk
        bne     nyami
        inc     YPosWrk+1

; store old readings

nyami:  tya
        and     #%00001010
        sta     dumx
        tya
        and     #%00000101
        asl
        sta     dumy

.elseif .defined (TRAK_MOUSE)

; trakball version

        eor     oldval
        and     #%00001000
        beq     horiz

        tya
        and     #%00000100
        beq     mmup

        inc     YPosWrk
        bne     horiz
        inc     YPosWrk+1
        bne     horiz

mmup:   dec     YPosWrk
        lda     YPosWrk
        cmp     #255
        bne     horiz
        dec     YPosWrk+1

horiz:  tya
        eor     oldval
        and     #%00000010
        beq     mmexit

        tya
        and     #%00000001
        beq     mmleft

        inc     XPosWrk
        bne     mmexit
        inc     XPosWrk+1
        bne     mmexit

mmleft: dec     XPosWrk
        lda     XPosWrk
        cmp     #255
        bne     mmexit
        dec     XPosWrk+1

mmexit: sty     oldval

.endif

        pla
        tax
        pla
        tay
.ifdef  __ATARIXL__
        rts
.else
        pla
        rti
.endif
