*Title  Compute a Mandelbrot set on a simple Z80 computer.
;
; Plain-Z80 fork of mandel_z180.asm - see README.md for full history and
; measured timings on each board. No hardware multiply on plain Z80, so
; l_muls_32_16x16 is a software shift-add multiply instead of the Z180's
; MLT-based one.
;
; ToDo
;
; Take in command line parameters and/or read config file
; Produce CSV file for high res on host PC
; Any gains in separating calculation from sending over serial?

; Hi-Tech Z80 C Compiler (CP/M-80) V3.09-17
; Copyright (C) 1984-87 HI-TECH SOFTWARE
; Updated from https://github.com/agn453/HI-TECH-Z80-C
;
; Assemble to MANDEL.OBJ with "ZAS MANDEL.ASM"
; Link to MANDEL.COM with "LINQ -Z -N -C100H -DMANDEL.SYM -OMANDEL.COM MANDEL.OBJ"

; Test system is an RC2014 Pro (RCZ80_std), Z80 @ 7.372MHz, running RomWBW
; HBIOS/ZSDOS. Ported from the Z180 SC722/SC721/SC727/SC712/SC702 original.
; https://smallcomputercentral.com/sc792-modular-z180-computer/

;*Include widget.asm

; Set to 0 to skip all pixel/color output (colorpixel call below) - isolates
; compute time from serial-I/O time for timing comparisons. Set to 1 for
; normal operation. Use COND/ENDC, not IF/ENDIF - this ZAS build's "IF" alias
; for COND appears broken (silent syntax error), even though both are
; documented as synonyms and z80asm accepts either. COND/ENDC work on both.
OUTPUT          EQU     1

        ORG     100h

        ; get the current date/time
        ld      b, hbios_rtcgetime
        ld      hl, startDT
        rst     hbios
        or      a                       ; A=0 on success, nonzero (e.g. ERR_NOHW) if no RTC
        jr      z, rtc_start_ok
        xor     a
        ld      (rtc_ok), a             ; remember RTC is unavailable for mandel_end too
rtc_start_ok:

        jp      start

; Program Start
start:
        ld      hl, cls                 ; Terminal code to clear the screen
        call    printSt
        ld      hl, welcome             ; Welcome message
        call    printSt
        ld      a, (rtc_ok)
        or      a
        jr      z, start_norct
        ld      de, startDT
        call    printDT
        jr      outer_loop
start_norct:
        ld      hl, norct
        call    printSt

outer_loop:
        ld      hl, (y_end)
        ld      de, (y)
        and     a
        sbc     hl, de
        jp      m, mandel_end

        ld      hl, (x_start)
        ld      (x), hl

        ld      hl, line_buf            ; reset the per-row output buffer -
        ld      (buf_ptr), hl           ; colorpixel/showpixel append to it
                                         ; through the row, flushLine sends it
                                         ; and resets it at inner_loop_end

        jp      charIn                  ; ESC check once per row, not once per
                                         ; pixel - charInEnd falls back into
                                         ; inner_loop below either way
inner_loop:
        ld      hl, (x_end)
        ld      de, (x)
        and     a
        sbc     hl, de
        jp      m, inner_loop_end

        ; Cheap pre-check before the main loop even starts: is this pixel
        ; provably INSIDE the set (period-2 bulb or main cardioid)? Interior
        ; points are the single biggest cost in this program - they never
        ; trigger early bailout, so each one pays for the full iteration_max
        ; budget (30 x 3 multiplies). A handful of multiplies up front to
        ; skip that entirely is a much better trade than the earlier
        ; magnitude pre-check (reverted - see PLAN.md): that one saved at
        ; most a single multiply on a hit; this one can save ~90.
        ;
        ; All in scale-256 fixed point, same "square via l_muls_32_16x16
        ; then >>8" trick used throughout iteration_loop (a raw value
        ; squared comes back scaled by 65536; >>8 renormalizes a squared
        ; quantity to scale 256, matching a real threshold T as T*256).
        ; Assumes coordinates stay within this file's default range
        ; (roughly -2..1 x, -1.25..1.25 y) - like the rest of the fixed-
        ; point math here, larger ranges risk overflowing the 16-bit
        ; intermediate sums/products.
        ld      hl, (y)                 ; cy2_scale256 = (Cy^2) at scale 256
        ld      d, h                    ; - shared by both checks below
        ld      e, l
        call    l_muls_32_16x16
        ld      l, h
        ld      h, e
        ld      (cy2_scale256), hl

        ld      hl, (x)                 ; Period-2 bulb: (Cx+1)^2+Cy^2 <= 1/16
        ld      bc, scale               ; -> at scale 256: (cx+256)^2>>8 + cy2
        add     hl, bc                  ; <= 16, i.e. sum < 17 - tightened to
        ld      d, h                    ; < 14: each of the two >>8 squaring
        ld      e, l                    ; steps floor-rounds down by up to
        call    l_muls_32_16x16         ; just under 1, so the computed sum
        ld      l, h                    ; can undershoot the true value by up
        ld      h, e                    ; to ~2 - margin of 3 verified by
        ld      de, (cy2_scale256)      ; brute-force check against exact
        add     hl, de                  ; float math across the full render
        ld      bc, 14                  ; range plus a wide margin: 0 false
        and     a                       ; positives (see PLAN.md)
        sbc     hl, bc
        jp      C, mark_interior

        ld      hl, (x)                 ; Main cardioid: q=(Cx-0.25)^2+Cy^2;
        ld      bc, scale/4             ; q*(q+(Cx-0.25)) <= Cy^2/4. b_raw =
        and     a                       ; cx-64 (0.25*scale); q_scale256 =
        sbc     hl, bc                  ; (b_raw^2>>8) + cy2_scale256
        push    hl                      ; save b_raw across the call
        ld      d, h
        ld      e, l
        call    l_muls_32_16x16
        ld      l, h
        ld      h, e
        ld      de, (cy2_scale256)
        add     hl, de                  ; hl = q_scale256
        pop     bc                      ; bc = b_raw
        ld      d, h                    ; de = q_scale256 (multiplicand 2)
        ld      e, l
        add     hl, bc                  ; hl = q_scale256+b_raw (multiplicand 1)
        call    l_muls_32_16x16         ; hl:de = q*(q+b_raw), scale 65536
        ld      l, h
        ld      h, e                    ; hl = LHS at scale 256
        ld      de, (cy2_scale256)
        srl     d                       ; de = cy2_scale256/4 = RHS at scale
        rr      e                       ; 256 (unsigned shift is fine - a
        srl     d                       ; square>>8 is always >= 0)
        rr      e
        dec     de                      ; <= test: LHS < RHS+1, tightened to
                                         ; < RHS-1 (3 chained >>8/floor steps
                                         ; this time - see bulb check above
                                         ; for why a margin is needed; this
                                         ; one's margin verified the same way
        and     a
        sbc     hl, de                  ; LHS can be negative here (unlike the
        jp      M, mark_interior        ; bulb sum, always >= 0) - jp M tests
                                         ; the sign flag for a true SIGNED
                                         ; "<0" test. jp C would be wrong: it
                                         ; reads the UNSIGNED borrow, and RHS-1
                                         ; wraps to 0xFFFF when RHS=0 (near
                                         ; Cy=0), making "hl unsigned< 0xFFFF"
                                         ; true for nearly everything - this
                                         ; was a real bug, caught by the user
                                         ; from a wrongly-solid-black band
                                         ; across several rows near the center

        ld      hl, 0
        ld      (z_0), hl
        ld      (z_1), hl

        ld      a, (iteration_max)
        ld      b, a
iteration_loop:
        push    bc

        ld      hl, (z_0)               ; Compute DE HL = z_0 * z_0 first -
        ld      d, h                    ; check it alone before doing any
        ld      e, l                    ; more work: z_1^2 >= 0 always, so
        call    l_muls_32_16x16         ; if z_0^2 alone already diverges,
        ld      (z_0_square_low), hl    ; the sum will too - skip z_1^2 and
        ld      (z_0_square_high), de   ; the cross product entirely

        ld      l, h                    ; reposition (z_0^2)/scale into hl
        ld      h, e                    ; (same divide-by-256 trick as below)
        ld      bc, divergent
        and     a
        sbc     hl, bc
        jp      NC, bailout             ; z_0^2 alone already >= divergent -
                                         ; jp not jr, bailout is >127 bytes
                                         ; away here

        ld      hl, (z_1)               ; Compute DE HL = z_1 * z_1
        ld      d, h
        ld      e, l
        call    l_muls_32_16x16
        ld      (z_1_square_low), hl    ; z_1 ** 2 is needed later again
        ld      (z_1_square_high), de

        ld      hl, (z_0_square_low)    ; Combined check: (z_0^2+z_1^2)/scale
        ld      de, (z_1_square_low)    ; >= divergent? If so, this is the
        add     hl, de                  ; last iteration for this pixel -
        ld      b, h                    ; skip the cross product too, it's
        ld      c, l                    ; only needed for the NEXT
                                         ; iteration's z_1
        ld      hl, (z_0_square_high)
        ld      de, (z_1_square_high)
        adc     hl, de

        ld      h, l                    ; HL now contains (z_0 ^ 2 +
        ld      l, b                    ; z_1 ^ 2) / scale

        ld      bc, divergent           ; immediate value, not (divergent) -
                                         ; that was dereferencing memory address
                                         ; 0x0400, which lands inside the hsv
                                         ; color table by coincidence
        and     a
        sbc     hl, bc
        jp      NC, bailout             ; jp not jr, out of jr's +-127 range

        ; Still converging - compute z_0^2 - z_1^2 and 2*z_0*z_1, then update
        ld      hl, (z_0_square_low)    ; Compute subtraction
        and     a
        ld      bc, (z_1_square_low)
        sbc     hl, bc
        push    hl                      ; Save lower 16 bit of result
        ld      hl, (z_0_square_high)
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

        pop     bc                      ; Get iteration counter
        djnz    iteration_loop          ; We might fall through!
        jr      iteration_end

mark_interior:
        ld      b, 0                    ; provably inside the set (cardioid/bulb
        jp      iteration_end           ; pre-check) - same as naturally running
                                         ; the full iteration budget without ever
                                         ; diverging, so use the same b=0 color/
                                         ; char index a normal exhaustion gets

bailout:
        pop     bc                      ; Get iteration counter (unchanged)
iteration_end:
        COND    OUTPUT
        call    colorpixel
        ENDC

        ld      de, (x_step)
        ld      hl, (x)
        add     hl, de
        ld      (x), hl

        jp      inner_loop
inner_loop_end:
        ld      hl, (buf_ptr)   ; append CR/LF + a NUL terminator (flushLine
        ld      (hl), cr        ; scans for it - safe since none of the real
        inc     hl              ; bytes we ever write, ESC/digits/;/m/pixel
        ld      (hl), lf        ; chars/CR/LF, are ever legitimately 0) and
        inc     hl              ; flush the whole row in one pass
        ld      (hl), 0
        call    flushLine

        ld      de, (y_step)
        ld      hl, (y)
        add     hl, de
        ld      (y), hl

        jp      outer_loop

mandel_end:
        ld      hl, crlfeos
        call    printSt
        ld      hl, finished
        call    printSt

        ld      a, (rtc_ok)
        or      a
        jr      z, mandel_end_norct

        ; get the current date/time
        ld      b, hbios_rtcgetime
        ld      hl, endDT
        rst     hbios
        or      a
        jr      z, mandel_end_rtc_ok
        xor     a
        ld      (rtc_ok), a
        jr      mandel_end_norct

mandel_end_rtc_ok:
        ld      de, endDT
        call    printDT
        ld      hl, elapsedSt
        call    printSt

        call    calcRuntime
        jr      mandel_end_done

mandel_end_norct:
        ld      hl, norct
        call    printSt

mandel_end_done:


        rst     0

; Append pixel output to the per-row buffer (buf_ptr/line_buf) instead of
; calling printCh directly - flushLine sends the whole row in one pass at
; inner_loop_end. Color codes are still only appended when the iteration
; count changes; the pixel char is appended on every pixel either way.
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

        ld      a, (hl)             ; Put the current color into A - hl is
        call    setcolor            ; free again, setcolor loads buf_ptr itself
        ; Fall through to send the pixel char

showpixel:
        ld      a, (prevItCnt)      ; iteration count for THIS pixel - safe to
                                     ; read here on both entry paths (jp z here
                                     ; means b already equalled prevItCnt; the
                                     ; fall-through path just stored the new b
                                     ; into prevItCnt above) - can't use b
                                     ; directly, colorpixel clobbers it to 0
                                     ; while building the hsv index
        ld      c, a                ; character varies with iteration count on
        ld      b, 0                ; every pixel (unlike color, which is only
        ld      hl, chartable       ; re-sent when it changes) so a plain-text
        add     hl, bc              ; capture with ANSI stripped stays legible
        ld      a, (hl)             ; and diffable without a color terminal

        ld      hl, (buf_ptr)       ; append the one char byte and advance
        ld      (hl), a
        inc     hl
        ld      (buf_ptr), hl
        ret

; a = color byte (0-255) on entry. Appends the full ANSI sequence
; (ansifg's 7 bytes, fully unrolled since they're compile-time constants -
; cheaper than a copy loop for a fixed 7-byte run) + up to 3 color digits
; + 'm' to the buffer. Loads buf_ptr itself rather than assuming a live
; HL from the caller, since colorpixel's hsv lookup uses hl as a table
; pointer right up until the call.
setcolor:
        ld      hl, (buf_ptr)
        ld      (hl), esc
        inc     hl
        ld      (hl), sqBracket
        inc     hl
        ld      (hl), '3'
        inc     hl
        ld      (hl), '8'
        inc     hl
        ld      (hl), ';'
        inc     hl
        ld      (hl), '5'
        inc     hl
        ld      (hl), ';'
        inc     hl
        call    printdec        ; appends up to 3 digit bytes via hl, advancing it
        ld      (hl), 'm'
        inc     hl
        ld      (buf_ptr), hl
        ret

; a = value to print (0-255), hl = buffer write position (from setcolor) -
; appends decimal digit bytes via (hl)/inc hl instead of printCh, and
; returns with hl positioned just past the last digit written. pd1-pd4's
; own logic only ever touches a/c/e/the stack, never h or l, so hl
; survives untouched as the buffer cursor throughout.
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
        ld      (hl), a         ; append the digit and advance the buffer
        inc     hl              ; cursor instead of calling printCh

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

    ; unsigned multiplication of two 16-bit numbers into a 32-bit product,
    ; done as a software shift-and-add since plain Z80 has no MLT.
    ;
    ; enter : de = 16-bit multiplicand = y
    ;         hl = 16-bit multiplicand = x
    ;
    ; exit  : hl = high 16 bits of product, de = low 16 bits of product
    ;         (matches what the Z180 mlt sequence used to leave here,
    ;         so the sign-fixup / ex de,hl below is unchanged)
    ;
    ; uses  : af, bc, de, hl

    ld          b,d             ; bc = multiplicand (fixed addend)
    ld          c,e
    ld          d,h             ; de = multiplier (consumed a bit at a time)
    ld          e,l
    ld          hl,0            ; hl = product accumulator, starts at 0

    ; unrolled 16x - the multiply is the hottest routine in this program
    ; (called 3x per Mandelbrot iteration), so the dec/jr nz loop-control
    ; overhead was worth trading for code size here
    or         a
    bit         0,e             ; bit 1 of 16
    jr         z,l_mul1_noadd
    add         hl,bc
l_mul1_noadd:
    rr         h
    rr         l
    rr         d
    rr         e

    or         a
    bit         0,e             ; bit 2 of 16
    jr         z,l_mul2_noadd
    add         hl,bc
l_mul2_noadd:
    rr         h
    rr         l
    rr         d
    rr         e

    or         a
    bit         0,e             ; bit 3 of 16
    jr         z,l_mul3_noadd
    add         hl,bc
l_mul3_noadd:
    rr         h
    rr         l
    rr         d
    rr         e

    or         a
    bit         0,e             ; bit 4 of 16
    jr         z,l_mul4_noadd
    add         hl,bc
l_mul4_noadd:
    rr         h
    rr         l
    rr         d
    rr         e

    or         a
    bit         0,e             ; bit 5 of 16
    jr         z,l_mul5_noadd
    add         hl,bc
l_mul5_noadd:
    rr         h
    rr         l
    rr         d
    rr         e

    or         a
    bit         0,e             ; bit 6 of 16
    jr         z,l_mul6_noadd
    add         hl,bc
l_mul6_noadd:
    rr         h
    rr         l
    rr         d
    rr         e

    or         a
    bit         0,e             ; bit 7 of 16
    jr         z,l_mul7_noadd
    add         hl,bc
l_mul7_noadd:
    rr         h
    rr         l
    rr         d
    rr         e

    or         a
    bit         0,e             ; bit 8 of 16
    jr         z,l_mul8_noadd
    add         hl,bc
l_mul8_noadd:
    rr         h
    rr         l
    rr         d
    rr         e

    or         a
    bit         0,e             ; bit 9 of 16
    jr         z,l_mul9_noadd
    add         hl,bc
l_mul9_noadd:
    rr         h
    rr         l
    rr         d
    rr         e

    or         a
    bit         0,e             ; bit 10 of 16
    jr         z,l_mul10_noadd
    add         hl,bc
l_mul10_noadd:
    rr         h
    rr         l
    rr         d
    rr         e

    or         a
    bit         0,e             ; bit 11 of 16
    jr         z,l_mul11_noadd
    add         hl,bc
l_mul11_noadd:
    rr         h
    rr         l
    rr         d
    rr         e

    or         a
    bit         0,e             ; bit 12 of 16
    jr         z,l_mul12_noadd
    add         hl,bc
l_mul12_noadd:
    rr         h
    rr         l
    rr         d
    rr         e

    or         a
    bit         0,e             ; bit 13 of 16
    jr         z,l_mul13_noadd
    add         hl,bc
l_mul13_noadd:
    rr         h
    rr         l
    rr         d
    rr         e

    or         a
    bit         0,e             ; bit 14 of 16
    jr         z,l_mul14_noadd
    add         hl,bc
l_mul14_noadd:
    rr         h
    rr         l
    rr         d
    rr         e

    or         a
    bit         0,e             ; bit 15 of 16
    jr         z,l_mul15_noadd
    add         hl,bc
l_mul15_noadd:
    rr         h
    rr         l
    rr         d
    rr         e

    or         a
    bit         0,e             ; bit 16 of 16
    jr         z,l_mul16_noadd
    add         hl,bc
l_mul16_noadd:
    rr         h
    rr         l
    rr         d
    rr         e

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

; Send the buffered row (line_buf, NUL-terminated by inner_loop_end) to
; the console in one pass. No push/pop and no EXX needed around the
; CIOOUT call - a real-hardware probe (see AGENT.md gotchas) confirmed
; D/H/L and B all survive it untouched, so hl (the walking source
; pointer) and b (the function code, loaded once below) don't need any
; protection; only c (device number) gets silently rewritten by the call
; and must be reloaded every time.
flushLine:
        ld      hl, line_buf
        ld      b, hbios_cioout
flushLine_top:
        ld      a, (hl)
        or      a
        jp      z, flushLine_done
        ld      e, a
        ld      c, hbios_device
        rst     hbios
        inc     hl
        jp      flushLine_top
flushLine_done:
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
        jp      inner_loop              ; back to work

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
hbios_cioin     EQU     00h     ; HBIOS Function 0x00 - Character Input (CIOIN)
hbios_cioout    EQU     01h     ; HBIOS Function 0x01 - Character Output (CIOOUT)
hbios_cioist    EQU     02h     ; HBIOS Function 0x02 - Character Input Status (CIOIST)
hbios_rtcgetime EQU     20h     ; HBIOS Function 0x20 - RTC Get Time (RTCGETTIM)
hbios_device    EQU     80h     ; HBIOS the current output device/port 
hbios_EOS       EQU     00h     ; End of String (ASCII 0)
sqBracket       EQU     5bh     ; ANSCII "[" (91 decimal/0x5B)
cr		EQU	13
lf		EQU	10
esc             EQU     27
scale           EQU     256
divergent       EQU     scale * 4

iteration_max:  DEFB    30              ; Default 30
x:              DEFW    0 
x_start:        DEFW    -2 * scale      ; Default -2
x_end:          DEFW    1 * scale       ; Default 1
x_step:         DEFW    scale / 40      ; Default 80
y:              DEFW    -5 * scale / 4  ; Default -5
y_end:          DEFW    5 * scale / 4   ; Default 5
y_step:         DEFW    scale / 20      ; Default 60
z_0:            DEFW    0
z_1:            DEFW    0
cy2_scale256:   DEFW    0               ; Cy^2 at scale 256, used by the
                                         ; cardioid/bulb pre-check above
z_0_square_high: DEFW    0
z_0_square_low:  DEFW    0
z_1_square_high: DEFW    0
z_1_square_low:  DEFW    0

; Per-row output buffer - colorpixel/showpixel append pixel chars and (on
; change only) ANSI color escapes here instead of calling printCh
; directly; flushLine sends the whole row in one pass at inner_loop_end.
; Sized for the worst case at the current x_start/x_end/x_step (120
; columns): 7 bytes ansifg prefix + up to 3 color digits + 'm' + 1 pixel
; char = 12 bytes/pixel if EVERY pixel changed color, which never
; actually happens but is the safe bound; 120*12 = 1440, +2 for the
; trailing CR/LF appended before each flush. Resize this (and re-check
; the math above) if x_start/x_end/x_step ever change.
buf_ptr:        DEFW    line_buf
line_buf:       DEFS    1536

prevItCnt:      DEFB    0     ; To store the previous iteration count

rtc_ok:         DEFB    1     ; Cleared if RTCGETTIM reports no RTC hardware
norct:          DEFM    'No RTC present - date/time and elapsed time skipped'
                DEFB    cr, lf, hbios_EOS

startDT:        DEFS    6     ; Reserve buffer for RTC start date time BCD
endDT:          DEFS    6     ; Reserve buffer for the end date time BCD
elapsedSecs:    DEFB    0
elapsedMins:    DEFB    0

; Color Table - 31 colors to match the iteration max of 30 plus black
; Terminal code for setting the color is ESC[38;5;COLORm
;hsv:            DEFB    0                             
;                DEFB    201, 200, 199, 198, 197       
;                DEFB    196, 202, 208, 214, 220
;                DEFB    226, 190, 154, 118, 82
;                DEFB    46, 47, 48, 49, 50
;                DEFB    51, 45, 39, 33, 27
;                DEFB    165, 129, 93, 57, 21

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

; Bright near-black, dark far-out (original hand-tuned palette)
;hsv:            DEFB    0
;                DEFB    159, 117, 87, 87, 81
;                DEFB    81, 51, 51, 45, 45
;                DEFB    44, 44, 33, 33, 32
;                DEFB    32, 27, 27, 26, 26
;                DEFB    25, 25, 21, 20, 20
;                DEFB    19, 19, 18, 18, 18

; One-directional black -> navy -> blue -> cyan -> white (tried, rejected):
; put white on indices 27-30, which turned out to be the fast-escaping
; FAR-FIELD background covering most of the image - made the bulk of the
; render a stark white field instead of the atmospheric dark one.
;hsv:            DEFB    0
;                DEFB    16, 17, 17, 18, 19
;                DEFB    20, 20, 21, 27, 27
;                DEFB    33, 33, 33, 39, 39
;                DEFB    45, 45, 45, 51, 51
;                DEFB    87, 87, 123, 123, 159
;                DEFB    159, 195, 195, 231, 231

; Symmetric "mountain" (tried, superseded): black at both ends, peaking
; at white around index 15 - put the brightest color in the middle of
; the escape-count range rather than at either extreme.
;hsv:            DEFB    0
;                DEFB    17, 18, 19, 20, 21
;                DEFB    27, 33, 39, 39, 45
;                DEFB    51, 87, 123, 195, 231
;                DEFB    195, 123, 87, 51, 45
;                DEFB    39, 39, 33, 27, 21
;                DEFB    20, 19, 18, 17, 0

; One-directional ramp: black at the far-field outer edge (index 30/29,
; the fast-escaping background - "T" in the char table), dithering
; through navy -> blue -> cyan, brightening all the way to white right at
; the boundary (index 1, slowest-escaping/closest to the set), then a
; SUDDEN hard cut to black at index 0 (the true interior - no fade, it
; just isn't part of the gradient). Density weighted toward the low-
; index/near-boundary end (indices 1-11 get the finest cyan/white steps)
; since that's where "getting brighter right up to the bulb" is the
; whole point; the far-field background (indices 24-30) is uninteresting
; and can be coarse/flat near-black.
hsv:            DEFB    0
                DEFB    231, 231, 195, 195, 159
                DEFB    159, 159, 123, 123, 87
                DEFB    87, 51, 51, 45, 45
                DEFB    45, 39, 39, 33, 33
                DEFB    33, 27, 27, 21, 20
                DEFB    19, 18, 18, 17, 16

; Character table - same shape/indexing as hsv above (index = iteration
; count at bailout: 0 = reached iteration_max without diverging, 1..30 =
; diverged with that many iterations left), but printed on EVERY pixel
; regardless of whether the color changed. Colors are for the fractal
; image; these are so a stripped-ANSI/plain-text capture of the output
; stays legible and diffable without a color-capable terminal - each
; char maps 1:1 to an iteration count, decodable at a glance ('0'-'9'
; then 'A'-'U' for 10-30).
chartable:      DEFB    '0'
                DEFB    '1','2','3','4','5'
                DEFB    '6','7','8','9','A'
                DEFB    'B','C','D','E','F'
                DEFB    'G','H','I','J','K'
                DEFB    'L','M','N','O','P'
                DEFB    'Q','R','S','T','U'



welcome:        DEFM    'Generating a Mandelbrot set'
                DEFB    cr, lf, hbios_EOS

finished:       DEFB    esc, sqBracket, 48, 109                       ; Reset the color "esc[0m"
                DEFM    'Computations completed'        
                DEFB    cr, lf, hbios_EOS

elapsedSt:      DEFM    'Time taken: '
                DEFB    hbios_EOS

crlfeos:        DEFB    cr, lf, hbios_EOS                              ; Carrage return, line feed, end of string
cls:            DEFB    esc, sqBracket, 50, 74, hbios_EOS              ; Clear the screen "esc[2J"
        
                END



