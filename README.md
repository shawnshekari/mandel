Much of the code started life elseware and I greatly appriciate those authors.  

I am using this mostly to just learn some lessons on my SC722 18MHz Z180 modular computer from https://smallcomputercentral.com/sc792-modular-z180-computer/

I am writing directly to hardware and breaking portability (RomWBW HBIOS calls, Z180 specific instructions, ...)

## Two tracked versions

This repo tracks two diverging versions of the program:

- **`mandel_z180.asm`** - the original, targeting the SC722 Z180 board specifically (RomWBW HBIOS calls, Z180-specific instructions).
- **`mandel_z80.asm`** - a fork targeting plain Z80, used for the optimization work below. Current optimization effort is focused here.

Both assemble/link on-device with `ZAS`/`LINQ` (see `MAKE.SUB`).

## History

- Adapted to CP/M and colorized by J.B. Langston, from the original at
  https://rosettacode.org/wiki/Mandelbrot_set#Z80_Assembly
- 04/03/2024 - Updated to support HiTech-C assembler on CP/M
- 04/06/2024 - Updated to use RomWBW HBIOS calls to output
- 04/08/2024 - Skip sending color codes unless the iteration count changes,
  to reduce serial overhead
- 04/08/2024 - Check for ESC key to stop processing
- 04/10/2024 - Read RTC and print start/end date/time
- 04/12/2024 - Calculate and display processing time
- 08/10/2026 - Ported `mandel_z80.asm` from Z180 to plain Z80: replaced the
  MLT-based `l_muls_32_16x16` with a pure Z80 shift-and-add 16x16->32
  multiply (no `MLT` instruction on plain Z80). `RST 8` HBIOS calls are
  unchanged - portable across every RomWBW target, Z80 or Z180.

## Timings

Two different boards, so two separate sets of numbers - don't compare them
directly against each other.

### `mandel_z180.asm` - SC722 Z180 board (see file header for hardware detail)

`charIn` (the ESC-abort check) has always run once per pixel here - never
touched by the per-row-relocation optimization done on the Z80 fork
below - and there's no `OUTPUT`-flag equivalent in this file; the "no
char output" rows below were historical one-off measurements, not a
toggleable build option.

| Processor | Clock | OUTPUT | ESC check | Time | Notes |
|---|---|---|---|---|---|
| Z180 | 18.4MHz | 1 | per-pixel | 2:20 (140s) | Original downloaded `mandel.com` from J.B. Langston |
| Z180 | 18.4MHz | 1 | per-pixel | 45s | As of 04/10/2024 |
| Z180 | 18.4MHz | 0 | per-pixel | 39s | No char output |
| Z180 | 36.8MHz | 0 | per-pixel | 25s | No char output, 1 mem wait state |

### `mandel_z80.asm` - RC2014 Pro (RCZ80_std), Z80 @ 7.372MHz, RomWBW/ZSDOS

Measured on real hardware via the rc2014bridge MCP (`rc2014_run_command`,
wall-clock send-to-prompt-return timing). The Z80 port has no hardware
multiply, so `l_muls_32_16x16`/`square_16` are software shift-add
multiplies instead - expect this to run meaningfully slower per-pixel
than the Z180 original at a comparable clock speed. `OUTPUT` is the
`COND OUTPUT` build flag (top of the file) that skips all pixel/color
output to isolate compute time; `ESC check` is how often `charIn` polls
for the abort key - per-pixel for the whole file until the relocation
row below, per-row after.

| Processor | Clock | OUTPUT | ESC check | Time | Commit | What changed |
|---|---|---|---|---|---|---|
| Z80 | 7.372MHz | 1 | per-pixel | 45.09-45.13s | `dbcc494` | Baseline (unrolled multiply, before hand optimization) - two runs |
| Z80 | 7.372MHz | 0 | per-pixel | 41.82s | `dbcc494` | Baseline, compute only - serial I/O was only ~7% of runtime here at this point, compute dominated |
| Z80 | 7.372MHz | 1 | per-pixel | 44.36s | `b1eeb7f` | + clear-carry-before-bit-test in `l_muls_32_16x16` - ~1.7% faster |
| Z80 | 7.372MHz | 1 | per-pixel | 44.38s | `7ec2a68` | + hoist duplicate `pop bc` out of the exit branch - within measurement noise (~0.07s expected, below wall-clock resolution here) |
| Z80 | 7.372MHz | 1 | per-pixel | 43.61s | `8f1cf73` | + early bailout (check `z_0^2` alone, then combined, before the cross product) - ~3.3-3.7% below original baseline overall; see commit history for why the gain is smaller than the multiply-count reduction alone suggests |
| Z80 | 7.372MHz | 1 | per-pixel | 43.61s | `b89f9b5` | + per-pixel character varies with iteration count (visual only, colors unchanged) - no measurable timing impact, three consecutive runs; see PLAN.md for detail |
| Z80 | 7.372MHz | 1 | per-pixel | 43.7s | `34588c7` | + symmetric black->white->black color palette (visual only, same lookup cost) - no measurable timing impact, data-table swap only; see PLAN.md for detail |
| Z80 | 7.372MHz | 1 | per-pixel | 29.83-29.91s | `a6c5966` | + cardioid/period-2-bulb pre-check (skip interior pixels entirely) - ~32% faster than the 43.66-43.7s baseline, the biggest single win; verified byte-for-byte identical output, see PLAN.md for the two bugs found along the way |
| Z80 | 7.372MHz | 1 | per-pixel | 29.9s | `7a8c5a5` | + one-directional palette, reversed (black at far-field, white at boundary, sudden black at interior) - no measurable timing impact, data-table swap only; see PLAN.md for detail |
| Z80 | 7.372MHz | 1 | per-row | 28.8s | `74c7d92` | + ESC-key check moved from once per pixel to once per row - ~3.5% faster; `charIn` was dispatching an HBIOS status check ~120x/row for a key that's essentially never there; see PLAN.md for detail |
| Z80 | 7.372MHz | 1 | per-row | 28.63s | `2bdc89e` | + per-row output buffer (`colorpixel`/`setcolor`/`printdec` append to a buffer, `flushLine` sends it in one pass) - flat vs. 28.8s (within noise); see PLAN.md for why |
| Z80 | 7.372MHz | 0 | per-row | 25.53s | `2bdc89e` | Diagnostic re-check: compute only, same code as the row above with `OUTPUT` flipped for the measurement (never itself committed) - ~3.1s of output overhead remained, essentially the same *absolute* amount as the very first `OUTPUT=0` row - evidence the remaining bottleneck is UART transmission time, not the CPU-side call/register overhead those two changes targeted; see PLAN.md for detail |
| Z80 | 7.372MHz | 1 | per-row | 27.63s | `8e64151` | + dedicated `square_16` routine for `z^2` (2 of 3 multiplies/iteration, plus all 3 cardioid/bulb pre-check squarings) - ~3.5% faster; skips the second operand's sign check/abs-value and the entire sign-restoration exit path, both unnecessary when squaring; verified against `x*x` across all 65536 signed 16-bit values before deploying, see PLAN.md for detail |

(No commit column on the Z180 table below - its whole history predates this repo's git tracking; `dbcc494` is the only commit touching `mandel_z180.asm` at all, the one that split it out from the Z80 fork.)

# Mandelbrot Set Generator for Z80 (CP/M) - Optimization Readme

This document outlines potential optimizations for the Mandelbrot set generator written in Z80 assembly for CP/M, targeting RomWBW and the Z180 CPU. The optimizations are listed in order of their *likely* impact on rendering speed, from highest to lowest.  However, the actual impact may vary depending on the specific hardware and configuration.  **Thorough testing and measurement are crucial after implementing each optimization.**

## Optimization Action Plan

**Crucial Note:**  *Measure* the execution time before and after each change.  Use the RTC timing routines already present in the code.  This is the *only* way to know if a change actually helps.

### Phase 1: High-Impact Optimizations (Essential)

These optimizations are expected to provide the most significant speed improvements. They focus on the core Mandelbrot calculation loop and output efficiency.

1.  **Optimized Magnitude Check (Early Bailout):**  *This is the single most important optimization.*
    *   **Description:**  The current code checks if `z_0^2 + z_1^2 > divergent`. This optimization avoids unnecessary 32-bit operations by checking the high bytes of the intermediate results *first*.  It only proceeds to lower-byte calculations if necessary. This is *critical* for fast Mandelbrot generation.
    *   **Implementation:** See the detailed assembly code example in the previous response.  Replace the existing magnitude check with this optimized version. It prioritizes comparisons of the most significant parts, exiting the iteration early whenever possible.
    *   **Expected Impact:** Very High.  This should significantly reduce the number of calculations performed for points outside the Mandelbrot set.
    *   **File:** `MANDEL.ASM` (within `iteration_loop`)

2.  **Output Buffering:**
    *   **Description:**  Instead of sending each pixel character individually to the serial port, accumulate a line (or even multiple lines) of pixels in a memory buffer. Then, send the entire buffer at once.  This reduces the overhead of repeated HBIOS calls.
    *   **Implementation:**
        *   Declare a buffer in memory: `pixel_buffer: DEFS buffer_size` (where `buffer_size` is the length of a line in characters, e.g., 80, or a multiple of that for multi-line buffering).
        *   Modify `colorpixel`:  Instead of calling `printCh`, store the pixel character into the `pixel_buffer`.  Increment a buffer pointer after each store.
        *   Create a `flush_buffer` routine: This routine sends the contents of `pixel_buffer` to the serial port. It can use a loop with `printCh`, or, if you null-terminate the buffer, you can use `printSt`.
        *   Call `flush_buffer` at the end of each line (in `inner_loop_end`) and at the end of the program (`mandel_end`).
    *   **Expected Impact:** High, especially if the serial communication is slow.  This minimizes the overhead of interacting with the I/O system.
    *   **Files:** `MANDEL.ASM` (new `pixel_buffer`, `flush_buffer` routine, modifications to `colorpixel`, `inner_loop_end`, and `mandel_end`)

### Phase 2: Moderate-Impact Optimizations

These optimizations provide further improvements, but likely less dramatic than Phase 1.

3.  **Precision Analysis and Reduction (Fixed-Point):**
    *   **Description:**  The current code uses 16.16 fixed-point arithmetic.  This level of precision might be unnecessary for the visual output.  Reducing the precision (e.g., to 16.8 or even 8.8) will reduce the number of calculations in the core loop, especially the `mlt` instructions.
    *   **Implementation:**
        *   Change the `scale` constant to a smaller power of 2 (e.g., `scale EQU 128` for 16.8, or `scale EQU 16` for 8.8 or `scale EQU 256`).
        *   Adjust all scaling-related calculations (shifts and multiplications) accordingly.  Ensure you're using shifts (`SLA`, `SRA`, `SRL`) wherever possible instead of `mlt`.
        *   Re-evaluate the `divergent` value, it must be the square of the bailout magnitude divided by the NEW `scale` squared.
        *   *Thoroughly test* the visual output to find the lowest acceptable precision.
    *   **Expected Impact:** Moderate. The impact depends on how much you can reduce the precision without noticeably degrading the image quality.
    *   **Files:** `MANDEL.ASM` (changes to `scale`, `divergent`, and related calculations)

4.  **Loop Unrolling:**
    *   **Description:** Unroll the `iteration_loop` a few times (2 or 4 is a good starting point). This reduces the overhead of the `djnz` instruction and loop control.
    *   **Implementation:** Duplicate the body of the `iteration_loop` 2 or 4 times within the loop itself.  Adjust the `djnz` to jump back to the beginning of the unrolled block.  Ensure the bailout logic works correctly within the unrolled sections.
    *   **Expected Impact:** Moderate.  Reduces loop overhead, but increases code size.  The Z180's simple pipeline means the benefits might not be as large as on a more modern CPU.
    *   **File:** `MANDEL.ASM` (within `iteration_loop`)

### Phase 3: Minor Optimizations and Refinements

These optimizations are less likely to have a significant impact, but are good coding practices and might provide small gains.

5.  **Register Usage Review:**
    *   **Description:**  Carefully review the code to ensure maximum use of registers and minimize memory accesses.  The Z80 is register-limited, so this is always important.
    *   **Implementation:**
        *   Look for any places where values are unnecessarily loaded from or stored to memory.
        *   Consider using the alternate register set (`exx`) within subroutines (like `printCh`) if it avoids the need to push and pop registers.
        *   Use `ex (sp), hl` for fast swaps of HL with the top of the stack.
    *   **Expected Impact:** Low to Moderate.  Depends on finding inefficiencies in the existing code.
    *   **File:** `MANDEL.ASM` (global review)

6.  **HBIOS Device Caching:**
    *   **Description:**  If the `hbios_device` value (the console output device) never changes during the program's execution, hardcode its value rather than reloading it for every HBIOS call.
    *   **Implementation:** Replace `ld c, hbios_device` with `ld c, 80h` (or whatever the actual device value is) in `printCh` and `charIn`.
    *   **Expected Impact:** Very Low. This is a micro-optimization, but it can add up over many iterations.
    *   **Files:** `MANDEL.ASM` (within `printCh` and `charIn`)

7.  **Macros:**
    * **Description:**  Use macros to encapsulate common code sequences, making the code more readable and maintainable.  This doesn't directly improve speed, but makes future optimizations easier.
    * **Implementation:** Define macros for things like the optimized magnitude check, parts of the `printdec` routine, or any other frequently repeated code blocks.
    * **Expected Impact:**  Indirect (improved maintainability).
    *   **File:** `MANDEL.ASM` (add macro definitions)

### Phase 4: Advanced Optimizations (High Complexity, Potentially High Impact)

8.  **Asynchronous I/O (Interrupt-Driven):**
    *   **Description:**  Use interrupts to handle serial output in the background.  This allows the CPU to continue calculating the Mandelbrot set while characters are being transmitted.
    *   **Implementation:**  This is *highly* dependent on your specific hardware and requires in-depth knowledge of interrupt handling on the Z80 and your serial controller. It's a complex undertaking.  It is almost certainly not worthwhile on this platform.
    *   **Expected Impact:** Potentially High, but only if the serial I/O is a *major* bottleneck and the hardware fully supports it.  The complexity is very high.
    *   **Files:** `MANDEL.ASM` (significant modifications)

## Summary

The most important optimizations are the optimized magnitude check (early bailout) and output buffering. Focus on those first.  Precision reduction and loop unrolling are also likely to provide noticeable gains.  The other optimizations are smaller refinements.  Always measure the impact of each change to ensure it's actually improving performance.
