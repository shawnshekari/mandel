*Title  Compute a Mandelbrot set on a simple Z80 computer.
;
; From https://rosettacode.org/wiki/Mandelbrot_set#Z80_Assembly
; Adapted to CP/M and colorzied by J.B. Langston
; Updated to support HiTech-C Assembler on CP/M 04/03/2024 Shawn Reed
; Updated to use RomWBW BIOS calls to output 04/06/2024 Shawn Reed
; Updated to skip sending color codes unless the iteration count changes to reduce overhead of sending via serial 04/06/2024 Shawn Reed
; ToDo
; Check for ctrl-c to stop processing
; Read realtime clock for calculating processing time
; Take in command line parameters
; Produce CSV file for high res on host PC

;*Include widget.asm

        ORG     100h
        jp      start

; Print Character
; Utilizing the RomWBW HBIOS calls to output the character in the A register
printCh:
        ; Save the registers
        push    bc
        push    de
        push    hl

        ld      b, hbios_cioout         ; RomWBW HBIOS Charater Output
        ld      c, hbios_device         ; The current console output device
        ld      e, a                    ; The character to output is in A
        rst     hbios                   ; Call the HBIOS routine note this can also be a CALL 0FFh

        ; Restore the registers
        pop    hl
        pop    de
        pop    bc
        ret

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


; Program Start
start:
        ld      hl, cls                 ; Terminal code to clear the screen
        call    printSt
        ld      hl, welcome             ; Welcome message
        call    printSt                 

outer_loop:     
        ld      hl, (y_end)
        ld      de, (y)
        and     a
        sbc     hl, de
        jp      m, mandel_end

        ld      hl, (x_start)
        ld      (x), hl
inner_loop:     
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
        ld      de, (z_1)
        ld      b, d
        ld	c, e
        call    mul_16
        ld      (z_0_square_l), hl
        ld      (z_0_square_h), de

        ld      de, (z_0)
        ld      b, d
        ld	c, e
        call    mul_16
        ld      (z_1_square_l), hl
        ld      (z_1_square_h), de

        and     a
        ld      bc, (z_0_square_l)
        sbc     hl, bc
        ld      (scratch_0), hl
        ld      h, d
        ld	l, e
        ld      bc, (z_0_square_h)
        sbc     hl, bc
        ld      bc, (scratch_0)

        ld      c, b
        ld      b, l
        push    bc

        ld      hl, (z_0)
        add     hl, hl
        ld      d, h
        ld	e, l
        ld      bc, (z_1)
        call    mul_16

        ld      b, e
        ld      c, h

        ld      hl, (y)
        add     hl, bc
        ld      (z_1), hl

        pop     bc
        ld      hl, (x)
        add     hl, bc
        ld      (z_0), hl

        ld      hl, (z_0_square_l)
        ld      de, (z_1_square_l)
        add     hl, de
        ld      b, h
        ld	c, l

        ld      hl, (z_0_square_h)
        ld      de, (z_1_square_h)
        adc     hl, de

        ld      h, l
        ld      l, b

        ld      bc, divergent
        and     a
        sbc     hl, bc

        jp      c, iteration_dec
        pop     bc
        jr      iteration_end

iteration_dec:  
        pop     bc
        djnz    iteration_loop
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
        ld      hl, finished
        call    printSt
        ret

; Send the color codes only if the iteration count has changed otherwise just print the pixel character.                
colorpixel:
        ld      c,b                 ; iter count in BC
        ld      b,0
        ld      hl, hsv             ; get ANSI color code table
        add     hl, bc              ; Now hl is pointing at the new color
        
        ld      a, (prevColor)      ; Get the previous color
        cp      (hl)                ; Compare to the current color
        ld      (prevColor), a      ; Store the current color for next check
        ld      a, (hl)             ; Put the current color into A
        jr      z, showpixel        ; skip setting the color if they were the same
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
        ld      c,-100
        call    pd1
        ld      c,-10
        call    pd1
        ld      c,-1
pd1:
        ld      e,'0'-1
pd2:
        inc     e
        add     a,c
        jr      c,pd2
        sub     c
        push    af
        ld      a,-1
        cp      c
        jr      z,pd3
        ld      a,'0'
        cp      e
        jr      z,pd4
pd3:
        ld      a, e
        call    printCh

pd4:
        pop     af
        ret


;
;   Compute DEHL = BC * DE (signed): This routine is not too clever but it
; works. It is based on a standard 16-by-16 multiplication routine for unsigned
; integers. At the beginning the sign of the result is determined based on the
; signs of the operands which are negated if necessary. Then the unsigned
; multiplication takes place, followed by negating the result if necessary.
;
mul_16:
        xor     a
        bit     7, b
        jr      z, bc_positive
        sub     c
        ld      c, a
        ld      a, 0
        sbc     a, b
        ld      b, a
        scf
bc_positive:
        bit     7, D
        jr      z, de_positive
        push    af
        xor     a
        sub     e
        ld      e, a
        ld      a, 0
        sbc     a, d
        ld      d, a
        pop     af
        ccf
de_positive:
        push    af
        and     a
        sbc     hl, hl
        ld      a, 16
mul_16_loop:
        add     hl, hl
        rl      e
        rl      d
        jr      nc, mul_16_exit
        add     hl, bc
        jr      nc, mul_16_exit
        inc     de
mul_16_exit:
        dec     a
        jr      nz, mul_16_loop
        pop     af
        ret     nc
        xor     a
        sub     l
        ld      l, a
        ld      a, 0
        sbc     a, h
        ld      h, a
        ld      a, 0
        sbc     a, e
        ld      e, a
        ld      a, 0
        sbc     a, d
        ld      d, a
        ret

hbios           EQU     08      ; HBIOS call
hbios_cioin     EQU     00h     ; HBIOS Character inout command
hbios_cioout    EQU     01h     ; HBIOS Character output command
hbios_device    EQU     80h     ; HBIOS the current output device/port 
hbios_EOS       EQU     00h     ; End of String (ASCII 0)
sqBracket       EQU     5bh     ; ANSCII "[" (91 decimal/0x5B)
cr		EQU	13
lf		EQU	10
esc             EQU     27
pixel           EQU     88      ; The original block character 219
scale           EQU     256
divergent       EQU     scale * 4

iteration_max:  DEFB    30
x:              DEFW    0 
x_start:        DEFW    -2 * scale
x_end:          DEFW    1 * scale
x_step:         DEFW    scale / 40
y:              DEFW    -5 * scale / 4
y_end:          DEFW    0 * scale / 4
y_step:         DEFW    scale / 30
z_0:            DEFW    0
z_1:            DEFW    0
scratch_0:      DEFW    0
z_0_square_h:   DEFW    0
z_0_square_l:   DEFW    0
z_1_square_h:   DEFW    0
z_1_square_l:   DEFW    0

prevColor:      DEFW    1     ; A varible to store the previous color. (1 byte)

hsv:            DEFB    0                             ; hsv color table
                DEFB    201, 200, 199, 198, 197
                DEFB    196, 202, 208, 214, 220
                DEFB    226, 190, 154, 118, 82
                DEFB    46, 47, 48, 49, 50
                DEFB    51, 45, 39, 33, 27
                DEFB    21, 57, 93, 129, 165


welcome:        DEFM    'Generating a Mandelbrot set'
                DEFB    cr, lf, hbios_EOS

finished:       DEFB    esc, sqBracket, 48, 109                       ; Reset the color "esc[0m"
                DEFM    'Computations completed'        
                DEFB    cr, lf, hbios_EOS

crlfeos:        DEFB    cr, lf, hbios_EOS                              ; Carrage return, line feed, end of string
ansifg:         DEFB    esc, sqBracket, 51, 56, 59, 53, 59, hbios_EOS  ; Foreground "esc[38;5;"
cls:            DEFB    esc, sqBracket, 50, 74, hbios_EOS              ; Clear the screen "esc[2J"
        
                END