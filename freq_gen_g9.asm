#make_bin#
 
#LOAD_SEGMENT=FFFFh#
#LOAD_OFFSET=0000h#
 
#CS=0000h#
#IP=0000h#
 
#DS=0000h#
#ES=0000h#
 
#SS=0000h#
#SP=FFFEh#
 
#AX=0000h#
#BX=0000h#
#CX=0000h#
#DX=0000h#
#SI=0000h#
#DI=0000h#
#BP=0000h#
 
; add your code here 
;jump to the start of the code - reset address is kept at 0000:0000
;as this is only a limited simulation
        jmp     st1     
;jmp st1 - takes 3 bytes followed by nop that is 4 bytes
        nop  
;int 1 to 39 is not used so  ip and cs intialized to 0000
        dw      78 dup(0)   ;2 * 2 * (39 - 1 + 1)
;int 40 used for looping back to initial sequence when Generate Switch toggled OFF
        dw      g_off_isr
        dw      0000
;int 41 used for updating output table when mode changed via Column 1 key press
        dw      wr_tb_isr
        dw      0000
;int 42 used for pushing next element of output table to DAC when timer raises INT
        dw      smple_isr
        dw      0000
;int 43 used for starting wave generation when Generate Switch toggled ON
        dw      g_on_isr
        dw      0000
;int 44 to int 255 unused so ip and cs intialized to 0000    
        db      848 dup(0)   ;4 * (255 - 44 + 1)

;tables to use
    sine_tb     db      119, 136, 151, 167, 182, 196, 209, 220, 231, 239
                db      246, 251, 254, 255, 254, 251, 246, 239, 231, 220
                db      209, 196, 182, 167, 151, 136, 119, 104,  88,  73
                db       59,  46,  35,  24,  16,   9,   4,   1,   0,   1
                db        4,   9,  16,  24,  35,  36,  59,  73,  88, 104  

    sqr_tb      db      255, 255, 255, 255, 255, 255, 255, 255, 255, 255
                db      255, 255, 255, 255, 255, 255, 255, 255, 255, 255
                db      255, 255, 255, 255, 255,   0,   0,   0,   0,   0
                db      0  ,   0,   0,   0,   0,   0,   0,   0,   0,   0
                db      0  ,   0,   0,   0,   0,   0,   0,   0,   0,   0

    tri_tb      db      122, 133, 143, 153, 163, 174, 184, 194, 204, 214
                db      224, 235, 245, 255, 245, 235, 224, 214, 204, 194
                db      184, 174, 163, 153, 143, 133, 122, 112, 102,  92 
                db       82,  71,  61,  51,  41,  31,  20,  10,   0,  10
                db       20,  31,  41,  51,  61,  71,  82,  92, 102, 112

    out_tb      db      50 dup(0)

; state vars to keep track of
    1K_val      db      0
    100_val     db      0
    10_val      db      0
    1V_val      db      0
    wav_stat    db      0           ; pressed atleast once => 1
    AMP_stat    db      0           ; pressed atleast once => 1
    frq_stat    db      0           ; current freq val 0   => 0
    cnt_stat    db      0           ; count loaded to tmr0 => 1
    count       dw      0
    count_den   dw      0
    run_stat    db      0           ; when wave being output => 1
    fin_stat    db      0           ; when gen toggled OFF => 1


; MACROS

    port_in     MACRO   portaddr
                in al, portaddr
                ENDM

    port_out    MACRO   portaddr, value
                mov al, value
                out portaddr, al
                ENDM


; internal addresses of 8255
    portA       equ     80h
    portB       equ     82h
    portC       equ     84h
    cregPPI     equ     86h

; internal addresses of 8254
    timer0      equ     90h
    timer1      equ     92h
    timer2      equ     94h
    cregPIT     equ     96h

; internal addresses of 8259
    cregPIC1    equ     0A0h
    cregPIC2    equ     0A2h

; button equivalent hexcodes
    SIN_butn    equ     6Eh
    TRI_butn    equ     5Eh
    SQU_butn    equ     3Eh
    oneK_btn     equ     6Dh
    oneH_btn    equ     5Dh
    oneD_btn     equ     3Dh
    AMP_butn    equ     6Bh
    oneV_btn     equ     3Bh



;==================================\/ (main program) \/========================================

st1:    cli     ; sti only when all values input
; starting of the program
        mov     ax, 0200H
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, 0FFFEH
        mov     ax, 00H

; 8255 Initialization
        port_out cregPPI, 10000001b   ; Port A => Mode 0 O/P, Port B (unused) => Mode 0 O/P
                                      ; Port C Upper  => O/P, Port C Lower    => I/P

; 8259 Initialization
        port_out cregPIC1, 00010011b   ; ICW1: Edge-triggered, single 8259 used with x86
        port_out cregPIC2, 01000000b   ; ICW2: starting vec no. 40h
        port_out cregPIC2, 00000001b   ; ICW4: no SFR mode, no AEOI, no BUF M/S, with x86
        ; OCW1: at start, only IR3 enabled. Other three IRQs enabled once generation begins
        ; OCW2: used in ISRs (non-specific EOI)

rerun:
; reset all state vars, unmask IR3
        cli
        port_out cregPIC2, 11110111b   ; OCW1: IR3 enabled at start
        mov fin_stat, 0
        mov 1K_val, 0
        mov 100_val, 0
        mov 10_val, 0
        mov 1V_val, 0
        mov wav_stat, 0
        mov AMP_stat, 0
        mov cnt_stat, 0
        mov run_stat, 0
        mov frq_stat, 0
        lea di, count
        mov word ptr[di], 0
        lea di, count_den
        mov word ptr[di], 0

; keypad detection
    kinit:
        cmp fin_stat, 1
        jz rerun                ; restart process, if Generate toggle OFF
        ;checking if current selected frequency is zero
        mov al, frq_stat
        add al, 1K_val
        add al, 100_val
        add al, 10_val
        mov frq_stat, al
        ;checking keys
        port_out portC, 00h
    kup:
        port_in portC
        and al, 0Fh
        cmp al, 0Fh
        jnz kup
        port_out portC, 00H
    kdwn:
        port_in portC
        and al, 0FH
        cmp al, 0Fh
        jz kdwn

    ; exec reaches here => a valid keypress was detected
    ; now to identify which column contains the pressed key
    col1:
        mov bl, 60h         
        port_out portC, bl
        port_in portC
        and al, 0Fh
        cmp al, 0Fh
        jz col2             ; jump to col 2 code if not col 1
        add bl, al
        c1r1: 
            cmp bl, SIN_butn
            jnz c1r2
            int 41h             ; col 1,row 1 keypress
            mov wav_stat, 1      ; raise table set interrupt, set wav_stat var to 1
            jmp rd_test          ; then go to readiness test
        c1r2:
            cmp bl, oneK_btn
            jnz c1r3
            cmp wav_stat, 0     ; col 1, row 2 keypress
            jz kinit
            cmp AMP_stat, 1       ; if mode buttons still not pushed yet, or
            jz kinit              ; if amp button pushed before, ignore freq keypress
            inc 1K_val            ; else increment 1K count
            cmp 1K_val, 99
            jbe kinit             ; jump to kinit if 1K_val <= ceiling (99)
            mov 1K_val, 0         ; rolling over 1K count if value = 100
            jmp kinit             ; check next keypress
        c1r3:
            cmp bl, AMP_butn
            jnz kinit
            cmp frq_stat, 0     ; col 1, row 3 keypress
            jz kinit              ; if freq still zero, ignore AMP keypress
            mov AMP_stat, 1       ; else set AMP_state var to 1
            jmp kinit             ; check next keypress
    col2:
        mov bl, 50h
        port_out portC, bl
        port_in portC
        and al, 0Fh 
        cmp al, 0Fh
        jz col3             ; jump to col 3 code if not col 2
        add bl, al
        c2r1:
            cmp bl, TRI_butn
            jnz c2r2
            int 41h             ; col 2, row 1 keypress
            mov wav_stat, 1      ; raise table set interrupt, set wav_stat var to 1
            jmp rd_test          ; then go to readiness test
        c2r2:
            cmp bl, oneH_btn
            jnz kinit
            cmp wav_stat, 0     ; col 2, row 2 keypress
            jz kinit
            cmp AMP_stat, 1       ; if mode buttons still not pushed yet, or
            jz kinit              ; if amp button pushed before, ignore freq keypress
            inc 100_val           ; else increment 100 count
            cmp 100_val, 9
            jbe kinit             ; jump to kinit if 100_val <= ceiling (9)
            mov 100_val, 0        ; rolling over 100 count if value = 10
            jmp kinit             ; check next keypress
    col3:
        mov bl, 30h
        port_out portC, bl
        port_in portC
        and al, 0Fh
        cmp al, 0Fh
        jz kinit            ; go to starting of keypad press check if not col 3
        add bl, al
        c3r1:
            cmp bl, SQU_butn
            jnz c3r2
            int 41h             ; col 3, row 1 keypress
            mov wav_stat, 1      ; raise table set interrupt, set wav_stat var to 1
            jmp rd_test          ; then go to readiness test
        c3r2:
            cmp bl, oneD_btn
            jnz c3r3
            cmp wav_stat, 0     ; col 3, row 2 keypress
            jz kinit
            cmp AMP_stat, 1       ; if mode buttons still not pushed yet, or
            jz kinit              ; if amp button pushed before, ignore freq keypress
            inc 10_val            ; else increment 10 count
            cmp 10_val, 9
            jbe kinit             ; jump to kinit if 10_val <= ceiling (9)
            mov 10_val, 0         ; rolling over 10 count if value = 10
            jmp kinit             ; check next keypress
        c3r3:
            cmp bl, oneV_btn
            jnz kinit
            cmp AMP_stat, 0     ; col 3, row 3 keypress
            jz kinit              ; if AMP button still not pushed yet, ignore 1V keypress
            inc 1V_val            ; else increase 1V count
            cmp 1V_val, 10
            jbe le_ceil           ; jump to rd_state if 1V_val <= ceiling (10)
            mov 1V_val, 10        ; setting a ceiling value of 1V count at 10
            le_ceil:
                cmp count, 0      ; all required values entered by this point
                jz rd_state       ; if count not ready yet, go ready it
                jmp gen_state     ; if count ready, then wait for Generate toggle ON


    rd_test:
        cmp frq_stat, 0
        jz kinit                ; if freq still zero, wait for it to be non-zero
        cmp 1V_val, 0
        jz kinit                ; if 1V button not pressed yet, wait for it
        cmp cnt_stat, 0
        jnz gen_state           ; if count ready, wait for Generate toggle ON, else ready the count
    rd_state:
        ; 8254 Initialization
        port_out cregPIT, 00110100b     ; Timer 0 used, 16 bit count, binary counting
        ; calculate count and load into Timer 0         count = quotient((500,000/SR) / (count_den))
        ;                                                     = quotient((10000) / (count_den))
        ;                                               count_den = 1K_val*100 + 100_val*10 + 10_val*1
        lea di, count_den
        mov al, 100
        mul 1K_val
        add word ptr[di], ax
        mov al, 10
        mul 100_val
        add word ptr[di], ax
        mov al, 1
        mul 10_val
        add word ptr[di], ax    ; accumulating count_den values according to above equation ^
        cmp word ptr[di],9900
        jbe clamped                 ; jump to clamped count_den state if count_den <= ceiling (9900)
        mov word ptr[di],9900       ; else clamp cout_den value to ceiling (9900)
    clamped:
        ; move 10000 into DX:AX
        mov dx, 0
        mov ax, 2710h               ; i.e. 10000d
        div word ptr[di]            ; AX <- quotient((10000) / (count_den)), and
        lea di, count               ; DX <- remainder((10000) / (count_den))
        mov word ptr[di], ax        ; count now contains the required value to be loaded to timer 0
        port_out timer0, [di]
        port_out timer0, [di+1]   ; loaded count value in Timer 0
        mov cnt_stat,1
    gen_state:
        ; just waiting for any further mode/amplitude changes, till Generate toggle ON happens
        sti
        jmp kinit

; sbr_scle: subroutine to scale the values of out_tb to out_tb * (1V_val/10)
sbr_scle:
        mov bx, 0
    elem_sc:
        mov al, 1V_val
        mul out_tb[bx]
        mov cl, 10
        div cl
        mov out_tb[bx], al
        inc bx
        cmp bx, 50
        jnz elem_sc
        ret

;=========================\/ (ISR Code) \/===================================  

; g_on_isr: enables the other 3 previously masked IRQs
;           space where the ISRs of 40h,41h,42h are allowed to nest in
;           keeps looping as long as run_stat is 1
g_on_isr:
        ; scale the latest out_Tb values to out_tb * (1V_val/10)
        call sbr_scle
        port_out cregPIC2, 11110000b  ; OCW1: unmasking IR0-IR2 now
        mov run_stat, 1
    tb_rlod:
        mov bx, 0                     ; maybe do reload in INT 42h itself, rather than here
    tb_push:
        sti
        ; INT 40(g_off), 41(mode change), 42(dat elem push) given space to work
        ; INT 40 should stop the looping of this ISR and go back to 'rerun' label
        cmp run_stat, 1
        jz tb_push
        ; if exec reach here, means Generate toggled OFF. Indicate this with flag for jumping back to 'rerun'
        mov fin_stat, 1
        port_out cregPIC2, 11111111b  ; OCW1: re-masks all IRQs. 'rerun' will unmask IR3 again
        port_out cregPIC1, 00010000b  ; OCW2: non-specific EOI
        iret


; smple_isr: pushes element i of output table onto Port A (DAC) : 0 <= i <= 49
;            increments i if i=/= 49,  resets i to 0 if == 49
smple_isr:
        port_out portA, out_tb[bx]
    chk_bx:
        cmp bx, 49
        jb inc_bx
        mov bx, 0
        jmp chk_end
    inc_bx:
        inc bx
    chk_end:
        port_out cregPIC1, 00010000b  ; OCW2: non-specific EOI
        iret


; wr_tb_isr: writes into out_tb the enter table corresponding to the newest mode button press
;            will not allow any other ISR to nest into this (second highest priority, besides process restart),
;             to prevent out_tb data corruption
wr_tb_isr:
    chk_sin:
        mov bl, 60h
        port_out portC, bl
        port_in portC
        and al, 0Fh
        cmp al, 0Fh
        jnz lod_sin
    chk_tri:
        mov bl, 50h
        port_out portC, bl
        port_in portC
        and al, 0Fh
        cmp al, 0Fh
        jnz lod_tri
    chk_squ:
        mov bl, 30h
        port_out portC, bl
        port_in portC
        and al, 0Fh
        cmp al, 0Fh
        jnz lod_squ
        jmp fin_lod
    lod_sin:
        mov bx, 0
        sin_loop:
            mov al, sine_tb[bx]
            mov out_tb[bx], al
            inc bx
            cmp bx, 50
            jb sin_loop
            jmp end_lod
    lod_tri:
        mov bx, 0
        tri_loop:
            mov al, tri_tb[bx]
            mov out_tb[bx], al
            inc bx
            cmp bx, 50
            jb tri_loop
            jmp end_lod
    lod_squ:
        mov bx, 0
        squ_loop:
            mov al, sqr_tb[bx]
            mov out_tb[bx], al
            inc bx
            cmp bx, 50
            jb squ_loop
            jmp end_lod
    end_lod:
        cmp run_stat, 1
        jnz fin_lod
        call sbr_scle
    fin_lod:
        port_out cregPIC1, 00010000b  ; OCW2: non-specific EOI
        iret


; g_off_isr: used to provide the loop breaking condition for g_on_isr
;            signifies that user has toggled OFF the Generate Switch
g_off_isr:
        mov run_stat, 0
        port_out cregPIC1, 00010000b  ; OCW2: non-specific EOI
        iret