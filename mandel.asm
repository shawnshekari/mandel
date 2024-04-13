*Title  Compute a Mandelbrot set on a simple Z80 computer.
;
; From https://rosettacode.org/wiki/Mandelbrot_set#Z80_Assembly
; Adapted to CP/M and colorzied by J.B. Langston
; Updated to support HiTech-C Assembler on CP/M 04/03/2024 Shawn Reed
; Updated to use RomWBW BIOS calls to output 04/06/2024 Shawn Reed
; Updated skip sending color codes unless the iteration count changes 
;    to reduce overhead of sending via serial 04/08/2024 Shawn Reed
; Updated to Check for ESC key to stop processing 04/08/2024 Shawn Reed
; Updated to read RTC and print start and end date/time 04/10/2024 Shawn Reed
; Updated to Calculate processing time and display 04/12/2024 Shawn Reed
;
; ToDo
;
; Take in command line parameters and/or read config file
; Produce CSV file for high res on host PC
; Any gains in separating calculation from sending over serial?

; Running the downloaded origial mandel.com from J.B. Langston on my SC722 it takes 2:20
; Current version as of 04/10/2024 is taking 45 seconds
; With not char out it takes 39 seconds


;*Include widget.asm

        ORG     100h

        ; get the current date/time
        ld      b, hbios_rtcgetime
        ld      hl, startDT
        rst     hbios

        jp      start

; Program Start
start:
        ld      hl, cls                 ; Terminal code to clear the screen
        call    printSt
        ld      hl, welcome             ; Welcome message
        call    printSt
        ld      de, startDT
        call    printDT                 

outer_loop:     
        ld      hl, (y_end)
        ld      de, (y)
        and     a
        sbc     hl, de
        jp      m, mandel_end

        ld      hl, (x_start)
        ld      (x), hl
inner_loop:     
        jp      charIn
inner_loop2:
        ld      hl, (x_end)
        ld      de, (x)
        and     a
        sbc     hl, de
        jp      m, inner_loop_end

        ld      hl, 0
        ld      (z_0), hl
        ld      (z_1), hl

        ld      a, (iteration_max)
        ld      b, a
iteration_loop: 
        push    bc

        ld      hl, (z_1)               ; Compute DE HL = z_1 * z_1
        ld      d, h
        ld      e, l
        call    l_muls_32_16x16
        ld      (z_1_square_low), hl    ; z_1 ** 2 is needed later again
        ld      (z_1_square_high), de

        ld      hl, (z_0)               ; Compute DE HL = z_0 * z_0
        ld      d, h
        ld      e, l
        call    l_muls_32_16x16
        ld      (z_0_square_low), hl    ; z_1 ** 2 will be also needed
        ld      (z_0_square_high), de
        
        and     a                       ; Compute subtraction
        ld      bc, (z_1_square_low)
        sbc     hl, bc
        push    hl                      ; Save lower 16 bit of result
        ld      h, d
        ld      l, e
        ld      bc, (z_1_square_high)
        sbc     hl, bc
        pop     bc                      ; HL BC = z_0 ^ 2 - z_1 ^ 2

        ld      c, b                    ; Divide by scale = 256
        ld      b, l                    ; Discard the rest
        push    bc                      ; We need BC later

        ld      hl, (z_0)               ; Compute DE HL = 2 * z_0 * z_1
        add     hl, hl
        ld      de, (z_1)
        call    l_muls_32_16x16

        ld      b, e                    ; Divide by scale (= 256)
        ld      c, h                    ; BC contains now z_3

        ld      hl, (y)
        add     hl, bc
        ld      (z_1), hl

        pop     bc                      ; Here BC is needed again :-)
        ld      hl, (x)
        add     hl, bc
        ld      (z_0), hl

        ld      hl, (z_0_square_low)    ; Use the squares computed
        ld      de, (z_1_square_low)    ; above
        add     hl, de
        ld      b, h                    ; BC contains lower word of sum
        ld      c, l

        ld      hl, (z_0_square_high)
        ld      de, (z_1_square_high)
        adc     hl, de

        ld      h, l                    ; HL now contains (z_0 ^ 2 -
        ld      l, b                    ; z_1 ^ 2) / scale
        
        ld      bc,(divergent)
        and     a
        sbc     hl, bc

        jr      C, iteration_dec        ; No break
        pop     bc                      ; Get latest iteration counter
        jr      iteration_end           ; Exit loop

iteration_dec:  
        pop     bc                      ; Get iteration counter
        djnz    iteration_loop          ; We might fall through!
iteration_end:
        call    colorpixel

        ld      de, (x_step)
        ld      hl, (x)
        add     hl, de
        ld      (x), hl

        jp      inner_loop
inner_loop_end:
        ld	hl, crlfeos
        call	printSt

        ld      de, (y_step)
        ld      hl, (y)
        add     hl, de
        ld      (y), hl

        jp      outer_loop

mandel_end:
        ; get the current date/time
        ld      b, hbios_rtcgetime
        ld      hl, endDT
        rst     hbios

        ld      hl, crlfeos
        call    printSt
        ld      hl, finished
        call    printSt
        ld      de, endDT
        call    printDT
        ld      hl, elapsedSt
        call    printSt

        call    calcRuntime


        rst     0

; Send the color codes only if the iteration count has changed otherwise just print the pixel character.                
colorpixel:
        ; first lets check to see if the iteration has changed
        ld      a, (prevItCnt)     ; get the previous iteration count   
        cp      b                  ; compare them (current iteration count is in B)
        jp      z, showpixel       ; if they were the same skip the color change code 

        ld      a, b
        ld      (prevItCnt), a     ; They were different so store the new iteration count
        
        ld      c,b                 ; iter count in BC so swap then to little endian
        ld      b,0
        ld      hl, hsv             ; get ANSI color code table
        add     hl, bc              ; Now hl is pointing at the new color

        ld      a, (hl)             ; Put the current color into A
        call    setcolor
        ; Fall through to send the pixel char

showpixel:
        ld      a, pixel            ; show pixel
        call    printCh
        ret

setcolor:
        push    af              ; save accumulator
        ld      hl, ansifg      ; The first part of the terminal color code
        call    printSt
        pop     af              ; restore the acculator
        
        call    printdec        ; print ANSI color code
        ld      a, 'm'          ; The remaining part of the termial code for color
        call    printCh
        ret
        
printdec:
        ld      c,-100          ; print 100s place
        call    pd1
        ld      c,-10           ; print 10s place
        call    pd1
        ld      c,-1            ; print 1s place
pd1:
        ld      e,'0'-1         ; start ASCII right before 0
pd2:
        inc     e               ; increment ASCII code
        add     a,c             ; subtract 1 place value
        jr      C,pd2           ; loop until negative
        sub     c               ; add back the last value
        push    af              ; save accumulator
        ld      a,-1            ; are we in the ones place?
        cp      c
        jr      Z,pd3           ; if so, skip to output
        ld      a,'0'           ; don't print leading 0s
        cp      e
        jr      Z,pd4
pd3:
        ld      a, e
        call    printCh

pd4:
        pop     af
        ret

   ; signed multiplication of two 16-bit numbers into a 32-bit product.
   ; using the z180 hardware unsigned 8x8 multiply instruction
   ;
   ; enter : de = 16-bit multiplicand = y
   ;         hl = 16-bit multiplier = x
   ;
   ; exit  : dehl = 32-bit product
   ;         carry reset
   ;
   ; uses  : af, bc, de, hl

l_muls_32_16x16:
   ld           b,d             ; d = MSB of multiplicand
   ld           c,h             ; h = MSB of multiplier
   push         bc              ; save sign info

   bit          7,d
   jr           z,l_pos_de      ; take absolute value of multiplicand

   ld           a,e
   cpl 
   ld           e,a
   ld           a,d
   cpl
   ld           d,a
   inc          de

l_pos_de:
   bit          7,h
   jr           z,l_pos_hl      ; take absolute value of multiplier

   ld           a,l
   cpl
   ld           l,a
   ld           a,h
   cpl
   ld           h,a
   inc          hl

l_pos_hl:    ; prepare unsigned dehl = de x hl

    ; unsigned multiplication of two 16-bit numbers into a 32-bit product
    ;
    ; enter : de = 16-bit multiplicand = y
    ;         hl = 16-bit multiplicand = x
    ;
    ; exit  : dehl = 32-bit product
    ;         carry reset
    ;
    ; uses  : af, bc, de, hl

    ld          b,l             ; xl
    ld          c,d             ; yh
    ld          d,l             ; xl
    ld          l,c
    push        hl              ; xh yh
    ld          l,e             ; yl

    mlt         de              ; xl * yl

    mlt         bc              ; xl * yh
    mlt         hl              ; xh * yl

    add         hl,bc           ; sum cross products

    sbc         a,a
    and         01h
    ld          b,a             ; carry from cross products
    ld          c,h             ; LSB of MSW from cross products

    ld          a,d
    add         a,l
    ld          d,a             ; de = final product LSW

    pop         hl
    mlt         hl              ; xh * yh

    adc         hl,bc           ; hl = final product MSW
    ex          de,hl

    pop         bc              ; recover sign info from multiplicand and multiplier
    ld          a,b
    xor         c
    ret         P               ; return if positive product

    ld          a,l             ; negate product and return
    cpl
    ld          l,a
    ld          a,h
    cpl
    ld          h,a
    ld          a,e
    cpl
    ld          e,a
    ld          a,d
    cpl
    ld          d,a
    inc         l
    ret         NZ
    inc         h
    ret         NZ
    inc         de
    ret

;------------------------------------------------------------
; Print BCD number
; Input: B --> BCD number to print
; Alters the value of AF
;------------------------------------------------------------
printBCD:
        ld      a, b
        and     11110000B               ; Keep the upper nibble
        rrca
        rrca
        rrca
        rrca                            ; Rotated 4 times to move it to the lower nibble
        add     a, '0'                  ; Add the ASCII Zero
        call    printCh
        ld      a, b                    ; Reload the into A
        and     0fh                     ; Keep the lower nibble this time
        add     a, '0'                  ; Add the ACII Zero
        call    printCh
        ret

; Print Date/Time
; RTC structure address in DE
;       Offset         Contents
;       0              Year (00-99)
;       1              Month (01-12)
;       2              Date (01-31)
;       3              Hours (00-24)
;       4              Minutes (00-59)
;       5              Seconds (00-59)
printDT:
        ld      hl, 1            ; Month index
        add     hl, de           ; Add the index to buffer address
        ld      b, (hl)          ; Get the value at that indexed location
        call    printBCD
        ld      a, '/'
        call    printCh
        ld      hl, 2            ; Day index
        add     hl, de           ; Add the index to buffer address
        ld      b, (hl)          ; Get the value at that indexed location
        call    printBCD
        ld      a, '/'
        call    printCh
        ld      hl, 0            ; Year index amount
        add     hl, de           ; 
        ld      b, (hl)          ; Get the value at that indexed location
        call    printBCD
        ld      a, ' '
        call    printCh
        ld      hl, 3            ; Hour index
        add     hl, de           ; Add the index to buffer address
        ld      b, (hl)          ; Get the value at that indexed location
        call    printBCD
        ld      a, ':'
        call    printCh
        ld      hl, 4            ; Min index
        add     hl, de           ; Add the index to buffer address
        ld      b, (hl)          ; Get the value at that indexed location
        call    printBCD
        ld      a, ':'
        call    printCh
        ld      hl, 5            ; Sec index
        add     hl, de           ; Add the index to buffer address
        ld      b, (hl)          ; Get the value at that indexed location
        call    printBCD
        ld      a, cr
        call    printCh
        ld      a, lf
        call    printCh
        ret

; Print Character
; Utilizing the RomWBW HBIOS calls to output the character in the A register
; The slower CPM BDOS are just commented out for future testing or as needed
;
printCh:
        ; Save the registers
        push    bc
        push    de
        push    hl

        ld      e, a                    ; The character to output is in A
        
        ld      b, hbios_cioout         ; RomWBW HBIOS Charater Output
        ld      c, hbios_device         ; The current console output device
        rst     hbios                   ; Call the HBIOS routine note this can also be a CALL 0FFh

        ;ld      c, conout              ; CP/M BDOS version 
        ;call	bdos                    ; Quite a bit slower than the HBIOS call

        ; Restore the registers
        pop    hl
        pop    de
        pop    bc
        ret


; BCD to binary conversion
; Purpose: Convert one byte of BCD data to one byte of binary data
; Entry: Register A BCD data
; Exit: Register A = Binary data
; Registers used: A,B,C,F (bc will be preserved)
; Time: 60 cycles
BCD2Bin:
        push    bc
                                ; MULTIPLY UPPER NIBBLE BY 10 AND SAVE IT
                                ; UPPER NIBBLE * 10 = UPPER NIBBLE * (8 + 2)
        ld      b, a            ; SAVE ORIGINAL BCD VALUE IN B
        AND     0fh             ; MASK OFF UPPER NIBBLE
        RRCA                    ; SHIFT RIGHT 1 BIT
        LD      C, A            ; C = UPPER NIBBLE * 8
        RRCA                    ; SHIFT RIGHT 2 MORE TiMES
        RRCA                    ; A = UPPER NIBBLE * 2
        ADD     A, C
        LD      C, A            ; C = UF'PER NIBBLE * (8+2)
                                ; GET LOWER NIBBLE AND ADD IT TO THE
                                ; BINARY EQUIVALENT OF THE UPPER NIBBLE
        LD      A, B            ; GET ORIGINAL VALUE BACK
        AND     0fh             ; MASK OFF UPPER NIBBLE
        ADD     A, C            ; ADD TO( BINARY UPPER NIBBLE
        pop     bc
        RET 

; Print String
; The string is expected to be NULL (ASCII 0) terminated
; HL will contain the pointer to the string address
printSt:
        ld      a, (hl)                 ; Get the character at the address HL is pointing to 
        or      a                       ; Is it the NULL terminating character? (ASCII 0)
        ret     z                       ; If so we are done
        call    printCh                 ; Still here, well then lets print it
        inc     hl                      ; Increment the pointer to the next character
        jr      printSt                 ; Loop and do it again

; Monitor for an ESC key to abort calculation and end the application
charIn:
        ; Save the registers
        push    bc
        push    de
        push    hl

        ; Check the status of the input buffer since the read is blocking
        ld      b, hbios_cioist         ; Input status command
        ld      c, hbios_device         ; Console device
        rst     hbios                   ; Call the HBIOS routine
        cp      0                       ; Update the zero flag
        jp      z, charInEnd            ; nothing in the input buffer so return to the iteration loop

        ld      b, hbios_cioin          ; The input read HBIOS routine
        ld      c, hbios_device         ; Console Device
        rst     hbios                   ; Call the HBIOS Routine
        ld      a, 27                   ; Check for an ESC
        cp      e                       ; Char read in is in E so compare to the ESC in A
        jp      nz, charInEnd           ; If the zero flag is not set we can throw away the char and resume the iteration loop
        jp      mandel_end              ; We had gotten an ESC so we are done
        
charInEnd:
        ; Restore the registers
        pop     hl
        pop     de
        pop     bc
        jp      inner_loop2             ; back to work

;------------------------------------------------------------------------------------------------------------------------------
; Calculate the run time based on the start and end date/time buffers
;
; going to assume that we are only talking minuets right now
; hl, de, bc, a are used
; The start and end date/time buffers are assumed to already be populated and will be overwriten in this process 

calcRuntime:
                                ; Is the end seconds larger than the start seconds?
        ld      hl, endDT       
        inc     hl              ; offset to month
        inc     hl              ; offset to day
        inc     hl              ; offset to hours
        inc     hl              ; offset to min
        inc     hl              ; offset to sec
        ld      a, (hl)         ; A now has the ending seconds in BCD
        push    hl

        ld      hl, startDT     ; Address of the start date/time buffer
        inc     hl              ; offset to month
        inc     hl              ; offset to day
        inc     hl              ; offset to hours
        inc     hl              ; offset to min
        inc     hl              ; offset to sec
        cp      (hl)            ; Compare setting the carry flag if the start seconds is larger
        ld      b, (hl)         ; Store the start seconds in B for later
        pop      hl             ; Restore HL to the pointer to the end seconds buffer
        jp      c, startSecBigger
                                ; if we fell through then we can just subtract to get the seconds elapsed
        sub     b               ; Subtract the start seconds in B from the end seconds in A
        daa                     ; adjusts the Accumulator for BCD addition and subtraction 
        ld      (elapsedSecs), a
        jp      calculateMin
        
startSecBigger:                 ; The start seconds was larger than end so we need to subtract a min and add 60 secs
        add     a, 60h          ; 60 BCD / 01100000b / 96d 
        daa                     ; adjusts the Accumulator for BCD addition and subtraction
        sub     b               ; now subtract the start seconds
        daa                     ; adjusts the Accumulator for BCD addition and subtraction
        ld      (elapsedSecs), a
                                ; We have the seconds calculated so now we need to deduct 1 from the min
        dec     hl              ; Decrement HL so that it points to the end min
        ld      a, (hl)         ; Get the end sec
        dec     a               ; Subtract 1 min since we stole 60 seconds
        daa                     ; adjusts the Accumulator for BCD addition and subtraction
        ld      (hl), a         ; store the min back into the end min buffer

calculateMin:
                                ; Is the end min larger than the start min?
        ld      hl, endDT       
        inc     hl              ; offset to month
        inc     hl              ; offset to day
        inc     hl              ; offset to hours
        inc     hl              ; offset to min
        ld      a, (hl)         ; A now has the ending min in BCD
        push    hl

        ld      hl, startDT     ; Address of the start date/time buffer
        inc     hl              ; offset to month
        inc     hl              ; offset to day
        inc     hl              ; offset to hours
        inc     hl              ; offset to min
        cp      (hl)            ; Compare setting the carry flag if the start min is larger
        ld      b, (hl)         ; Store the start min in B for later
        pop      hl             ; Restore HL to the pointer to the end min buffer
        jp      c, startMinBigger
                                ; if we fell through then we can just subtract to get the minuets elapsed
        sub     b               ; Subtract the start min in B from the end min in A
        daa                     ; adjusts the Accumulator for BCD addition and subtraction 
        ld      (elapsedMins), a
        jp      calculateHours
        
startMinBigger:                 ; The start min was larger than end so we need to subtract an hour and add 60 min
        add     a, 60h          ; 60 BCD / 01100000b / 96d 
        daa                     ; adjusts the Accumulator for BCD addition and subtraction
        sub     b               ; now subtract the start min
        daa                     ; adjusts the Accumulator for BCD addition and subtraction
        ld      (elapsedMins), a
                                ; We have the min calculated so now we need to deduct 1 from the hours
        dec     hl              ; Decrement HL so that it points to the end hours
        ld      a, (hl)         ; Get the end hours
        dec     a               ; Subtract 1 min since we stole 60 min
        daa                     ; adjusts the Accumulator for BCD addition and subtraction
        ld      (hl), a         ; store the hours back into the end min buffer

calculateHours:
        ; ToDo

        ld      a, (elapsedMins)
        ld      b, a
        call    printBCD        ; Print out the minuets

        ld      a, ':'
        call    printCh
        ld      a, (elapsedSecs)
        ld      b, a
        call    printBCD        ; Print out the seconds

        ret

bdos		equ	05h     ; BDOS vector
conout		equ	2       ; BDOS console output call
hbios           EQU     08      ; HBIOS call
hbios_cioin     EQU     00h     ; HBIOS Function 0x00 – Character Input (CIOIN)
hbios_cioout    EQU     01h     ; HBIOS Function 0x01 – Character Output (CIOOUT)
hbios_cioist    EQU     02h     ; HBIOS Function 0x02 – Character Input Status (CIOIST)
hbios_rtcgetime EQU     20h     ; HBIOS Function 0x20 – RTC Get Time (RTCGETTIM)
hbios_device    EQU     80h     ; HBIOS the current output device/port 
hbios_EOS       EQU     00h     ; End of String (ASCII 0)
sqBracket       EQU     5bh     ; ANSCII "[" (91 decimal/0x5B)
cr		EQU	13
lf		EQU	10
esc             EQU     27
pixel           EQU     35      ; The original block character 219 I like using  35 as it is a #
scale           EQU     256
divergent       EQU     scale * 4

iteration_max:  DEFB    30              ; Default 30
x:              DEFW    0 
x_start:        DEFW    -2 * scale      ; Default -2
x_end:          DEFW    1 * scale       ; Default 1
x_step:         DEFW    scale / 80      ; Default 80
y:              DEFW    -5 * scale / 4  ; Default -5
y_end:          DEFW    5 * scale / 4   ; Default 5
y_step:         DEFW    scale / 60      ; Default 60
z_0:            DEFW    0
z_1:            DEFW    0
scratch_0:      DEFW    0
z_0_square_high: DEFW    0
z_0_square_low:  DEFW    0
z_1_square_high: DEFW    0
z_1_square_low:  DEFW    0

prevItCnt:      DEFB    0     ; To store the previous iteration count   


startDT:        DEFS    6     ; Reserve buffer for RTC start date time BCD
endDT:          DEFS    6     ; Reserve buffer for the end date time BCD
elapsedSecs:    DEFB    0
elapsedMins:    DEFB    0

; Color Table - 31 colors to match the iteration max of 30 plus black
; Terminal code for setting the color is ESC[38;5;COLORm
hsv:            DEFB    0                             
                DEFB    201, 200, 199, 198, 197       
                DEFB    196, 202, 208, 214, 220
                DEFB    226, 190, 154, 118, 82
                DEFB    46, 47, 48, 49, 50
                DEFB    51, 45, 39, 33, 27
                DEFB    165, 129, 93, 57, 21

; Grayscale to blue
;hsv:            DEFB    18                             
;                DEFB    255, 255, 254, 254, 253       
;                DEFB    253, 252, 252, 251, 251
;                DEFB    250, 250, 249, 249, 248
;                DEFB    248, 247, 247, 246, 245
;                DEFB    244, 243, 242, 241, 240
;                DEFB    239, 236, 234, 232, 0

; Bands blue green to white
;hsv:            DEFB    7                             
;                DEFB    16, 17, 18, 19, 20       
;                DEFB    25, 26, 27, 31, 32       
;                DEFB    33, 37, 38, 39, 45       
;                DEFB    16, 17, 18, 19, 20       
;                DEFB    25, 26, 27, 31, 32       
;                DEFB    33, 37, 38, 39, 45       


welcome:        DEFM    'Generating a Mandelbrot set'
                DEFB    cr, lf, hbios_EOS

finished:       DEFB    esc, sqBracket, 48, 109                       ; Reset the color "esc[0m"
                DEFM    'Computations completed'        
                DEFB    cr, lf, hbios_EOS

elapsedSt:      DEFM    'Time taken: '
                DEFB    hbios_EOS

crlfeos:        DEFB    cr, lf, hbios_EOS                              ; Carrage return, line feed, end of string
ansifg:         DEFB    esc, sqBracket, 51, 56, 59, 53, 59, hbios_EOS  ; Foreground "esc[38;5;"
cls:            DEFB    esc, sqBracket, 50, 74, hbios_EOS              ; Clear the screen "esc[2J"
        
                END