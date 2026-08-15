# Mandel Z80 optimization - working plan

Consolidated tracking doc - context was getting large across many work
items, so this replaces scattered task tracking as the durable record.
See `README.md` for project history/timings; this file is for in-flight
and backlog work only.

## Current status

Branch `z80-optimization`, all committed. Four real optimizations
measured on real hardware so far (see README's Timings table for exact
numbers and commit history for full detail on each):
1. Clear carry before bit-test in `l_muls_32_16x16` (~1.7% faster)
2. Hoist duplicate `pop bc` out of the loop exit branch (correct, but
   below measurement noise floor)
3. Early bailout in `iteration_loop` - check `z_0^2` alone, then
   `z_0^2+z_1^2`, before computing the cross-product multiply and
   updating z_0/z_1, so points that diverge fast skip work they don't
   need. ~3.3-3.7% below original baseline overall (cumulative with the
   two prior optimizations). **Confirmed true current baseline: 43.61-
   43.62s** (re-measured fresh from git HEAD this session after
   discovering the on-device `J:MANDEL.COM` had gone stale - see below).
4. Cardioid/period-2-bulb pre-check before `iteration_loop` even starts -
   see below. **~32% faster: 43.66s -> 29.83-29.91s**, the biggest single
   win so far.
5. ESC-key check moved from once per pixel to once per row (`charIn` was
   being called ~120x/row for a key that's essentially never there) -
   see below. **~3.5% faster: 29.83-29.91s -> 28.8s.**
6. Per-row output buffer - `colorpixel`/`setcolor`/`printdec` append to
   `line_buf` instead of calling `printCh` per byte, `flushLine` sends
   the whole row in one pass. **Measured flat: 28.63s, within noise of
   28.8s** - see below for why (real result, not a bug).
7. Dedicated `square_16` routine for `z^2` computations - see below.
   **~3.5% faster: 28.63s -> 27.63s.**

**Done for now on the output-buffering arc.** The `OUTPUT=0` split shows
why the buffering didn't move the needle much: ~3.1s of output overhead
remains (25.53s compute-only vs 28.63s with output), essentially the
*same absolute* overhead as the very first `OUTPUT=0` split ever measured
(~3.3s, before any output-path optimization existed) - strong evidence
the remaining cost is UART transmission time itself, not CPU-side
call/register overhead. Further CPU-side output optimization is likely
a dead end; **not** pursuing precision-independent output tricks further
unless something changes this picture (e.g. a faster baud rate, if the
hardware/terminal supports it - not investigated).

**Not yet decided:** what to tackle next. Precision reduction (drop
`scale` from 256, shrinking the multiply routine itself) is on the
backlog but explicitly **not wanted** - user is planning to zoom into
the render later and doesn't want reduced precision degrading detail at
higher zoom.

### Done: cardioid/period-2-bulb pre-check skips interior pixels entirely

User's idea: points inside the main cardioid or period-2 bulb never
diverge, so they're guaranteed to burn the *entire* `iteration_max`
budget (30 iterations x 3 multiplies each, ~90 multiplies) with zero
early exit - by far the most expensive pixels in the image. A cheap
test *before* `iteration_loop` starts (3-4 multiplies, worst case) can
identify them and skip straight to the interior color/char, the same way
a natural full-budget exhaustion would.

Formulas (real-valued): period-2 bulb: `(Cx+1)^2 + Cy^2 <= 1/16`. Main
cardioid: `q=(Cx-0.25)^2+Cy^2; q*(q+(Cx-0.25)) <= Cy^2/4`. Translated to
this program's scale-256 fixed point using the same "square via
`l_muls_32_16x16` then `>>8`" trick already used in `iteration_loop`
(raw value squared comes back scaled by 65536; `>>8` renormalizes to
scale 256). New `cy2_scale256` variable (renamed from an unused
`scratch_0`) holds `Cy^2` once per pixel, shared by both checks. On a
hit, `mark_interior:` sets `b=0` and jumps straight to `iteration_end` -
identical to what natural loop exhaustion produces.

**Two real bugs found and fixed before trusting this, both via measuring
on real hardware rather than assuming the math translation was right:**

1. **Threshold rounding (found via Python brute-force, before ever
   touching hardware).** Each `>>8` squaring step floor-rounds down,
   so a naive direct translation of the formulas gave **55 false
   positives** (points marked interior that truly aren't) out of 6966
   pixels when checked against exact floating-point math across the full
   render grid - a real visible bug, since misclassifying a boundary
   pixel as interior paints over real detail. Fixed by tightening both
   thresholds with a margin (bulb: `17`->`14`; cardioid: `RHS+1`->`RHS-1`)
   sized via brute-force search against exact float math across a *dense*
   grid (every integer raw coordinate, not just the actual pixel stride) -
   the coarser pixel-stride grid alone hid additional false positives that
   only showed up at finer resolution. Zero false positives confirmed
   across a generously wide coordinate range beyond the actual render
   bounds.

2. **`jp C` vs `jp M` (found by the user from a screenshot - a wrongly
   solid-black horizontal band spanning ~5 rows near the vertical
   center).** The cardioid check's final comparison can legitimately go
   negative (unlike the bulb sum, which is always >= 0), and `SBC HL,DE`'s
   **carry flag reflects an unsigned borrow, not a signed comparison**.
   Near `Cy=0` the threshold value underflowed `dec de` to `0xFFFF`
   (correct as a signed -1, but as an *unsigned* value that's 65535), so
   `jp C` (unsigned "less than") was true for nearly every pixel in those
   rows. The register *value* after `SBC` was always the correct signed
   difference - only the flag test was wrong. Fixed by testing the sign
   flag (`jp M`, true difference < 0) instead of carry. This is a sharp
   general lesson for any future signed 16-bit comparison on Z80: `SBC`'s
   carry is unsigned-only; use the sign flag (or overflow+sign together)
   for signed comparisons, and don't reach for `jp C`/`jp NC` out of habit
   from the rest of this file's mostly-non-negative comparisons.

**Verified correct after both fixes**: stripped-ANSI output diffed
byte-for-byte identical against a freshly-rebuilt true baseline (same
git HEAD source, pre-cardioid) - confirms the optimization changes
*only* performance, never a single rendered pixel.

### Done: per-pixel character now varies with iteration count (visual, not perf)

Colors are still the primary "for enjoyment" output and were left
completely untouched. Added a `chartable` (same 31-entry shape/indexing
as `hsv`) so `showpixel` prints a character that varies with iteration
count on *every* pixel - `'0'`-`'9'` then `'A'`-`'U'` for indices 0-30,
decodable at a glance. Point was output *comparison*: a stripped-ANSI/
plain-text capture (e.g. what you get pasting terminal output somewhere
without color support) now still shows the fractal's shape and lets two
runs be diffed meaningfully, where before every pixel was just `#` and
all the information was in color codes alone.

Implementation note: `showpixel` is entered two ways (direct jump when
color is unchanged from the previous pixel, or fall-through after
`colorpixel` sends a new color) - naively reading register `b` for the
iteration count would be wrong on the fall-through path, since
`colorpixel` clobbers `b` to 0 while building the `hsv` table index.
Reads `(prevItCnt)` instead, which by construction is already correct on
both paths (colorpixel just wrote the current count there, or it already
equalled the current count for the jump to have happened at all).

**Verified correct** via a self-consistency check on the captured
output (immune to the manual-retyping noise documented below): every
character maps to exactly one color throughout a full run, the pixel
count matches the known-good baseline exactly (6966), and the character-
to-color mapping matches `chartable`/`hsv`'s shared indexing exactly,
including the legitimate duplicate colors (e.g. both `3` and `4` map to
color 87, matching `hsv`'s own `87, 87` entries at those indices).

**Measured: 43.61s, three consecutive runs** - no measurable timing
impact versus the 43.61-43.62s baseline. The added lookup (a 16-bit add
and indexed read) only runs once per pixel print, not once per
iteration, so it doesn't touch the hot inner loop at all.

### Done: redesigned the color palette to a symmetric black->white->black mountain

User asked for a black -> dark blue -> light blue -> white progression
across the 31 `hsv` entries, with resolution concentrated where escape
counts change fastest (to highlight subtle boundary detail) rather than
spread evenly. First attempt was one-directional: black at index 0
(interior), climbing through navy/blue/cyan to white at index 30 (the
fastest-escaping, farthest-away points). Wrong call - index 30's
neighborhood turned out to be the huge, uninteresting far-field
background covering most of the image, so the render came out mostly
stark white instead of the atmospheric dark look the original palette
had. User caught this from a screenshot and asked for a symmetric
version instead.

**Final design**: black at *both* ends (index 0 = interior that never
diverges, index 30 = far-field points that diverge instantly - both
uninteresting), climbing navy -> blue -> cyan -> white and back down
again, peaking at white around index 15 (the boundary-detail band, where
escape counts are most varied pixel-to-pixel). Built by walking the
6x6x6 xterm-256 color cube's edge path (black -> pure blue -> pure cyan
-> white) and mirroring it around the midpoint; density still weighted
toward both black ends (the finest available navy steps sit right next
to black on either side). Confirmed on real hardware: 43.7s, no
measurable timing change (pure data-table swap, same lookup cost
regardless of what values are in the table).

Old one-directional attempt is left commented out above the active table
in `mandel_z80.asm`, same convention as the other retired palettes there.

### Done: reworked the palette again - one-directional, but the other way round

User revisited this after the cardioid pre-check landed: wanted black
around the *outside* (the outermost `T`/far-field background), dithering
through blue then brightening to white right at the boundary (closest to
diverging), then a **sudden** hard cut to black exactly at index 0 (the
true interior/bulb) - not a gradual fade into it. This is the mirror
image of the *first* (rejected) one-directional attempt: that one put
white at the far-field end (index 30) and black at the interior (index
0); this one puts black at the far-field end (index ~29-30) and white
near the boundary (index ~1), with index 0 handled as a separate, sudden
value rather than the start/end of the ramp.

Built the same way as the symmetric palette (walk the 6x6x6 cube's edge
path, black->blue->cyan->white) but as a single index-30-down-to-1 ramp,
density-weighted toward the *low*-index/near-boundary end (indices 1-11
get the finest cyan/white steps, since "getting brighter right up to the
bulb" is the whole point) with the far-field end (indices 24-30)
coarse/flat near-black. `hsv[0]` stays pure black, disconnected from the
ramp, giving the sudden cutoff into the interior. Confirmed on hardware:
29.9s x2, matching the cardioid-optimized baseline exactly (pure
data-table swap, no perf impact) - user confirmed the render looks
right.

### Done: ESC check moved from per-pixel to per-row, plus a register-clobber probe for the buffering work ahead

User wants to batch per-pixel serial output into a per-row buffer next
(motivation: `printCh` pays `push bc/de/hl` + an HBIOS dispatch on every
single byte, and `charIn`'s ESC check was doing the same *every pixel*
just to ask "any key waiting?", almost always answered no). Two pieces
landed this round:

**1. Register-clobber probe.** Before designing a buffered write loop,
needed to know what HBIOS's `CIOOUT` (function 0x01) actually clobbers -
the RomWBW System Guide only documents `A` (status) as a return value,
and `printCh`'s existing blanket `push bc/de/hl` doesn't tell you whether
that's necessary or just defensive. Wrote a throwaway probe
(`CIOTEST.ASM`, not committed) that poisons `D`/`H`/`L` with recognizable
values, makes one real `CIOOUT` call, and prints what survives. Result on
real hardware: `D`, `H`, `L`, and `B` (the function code) all come back
completely unchanged; only `A` changes (status) and, surprisingly, `C`
(the device number) - `0x80` (the "current console" alias) came back as
`0x81` after one call, undocumented anywhere. See AGENT.md's gotchas
section for the full writeup. Practical upshot for the buffering work:
a buffer pointer/count can live in `HL` (or similar) across `CIOOUT`
calls with *zero* protection - no `push`/`pop`, no `EXX` - and `B` can be
loaded once outside a send loop, but `C` must be reloaded every call.

**2. ESC-check relocation.** Moved the `charIn` call from `inner_loop`
(top of the per-pixel loop, ~120x/row at the current `x_step`) to run
once per row instead, right after `x` resets in `outer_loop`. Renamed
the old `inner_loop2` (the actual per-pixel x-bounds-check top) to
`inner_loop`, and updated `charIn`'s exit jump to match - purely a
control-flow change, doesn't touch `colorpixel`/`setcolor`/`showpixel`/
the `hsv`/`chartable` lookups or any iteration/cardioid math, so a full
byte-diff against baseline was skipped as low-value here (verified by
code inspection that the change is structurally disjoint from anything
that could alter pixel output, plus the completed render looked
structurally correct). User confirmed ESC still aborts a live render
correctly by testing it interactively.

**Measured: 28.8s, down from the 29.83-29.91s cardioid/palette
baseline - ~3.5% faster.**

### Done: per-row output buffer (real change, ~zero measured win - and a useful negative result)

Continuation of the same idea: `printCh` pays `push bc/de/hl` + an HBIOS
dispatch on *every single byte*. User's idea - accumulate a row's worth
of pixel chars and (on-change) color escapes into a buffer, then send it
in one pass at end-of-row, using the register-clobber probe's finding
that a buffer pointer needs zero save/restore around `CIOOUT`.

**Design:** `line_buf`/`buf_ptr` (1536 bytes, sized for the worst case at
the current 120-column width: 7-byte `ansifg` prefix + up to 3 color
digits + `'m'` + 1 pixel char = 12 bytes/pixel if *every* pixel changed
color, ×120, +2 for trailing CR/LF). `colorpixel`/`setcolor`/`showpixel`
each load `buf_ptr` fresh via `ld hl,(buf_ptr)`, append bytes with
`ld (hl),a`/`inc hl`, store `hl` back before returning - simpler than
trying to keep a single resident `hl` across the hsv/chartable table
lookups (which also want `hl` as a pointer), and the two extra memory
round-trips this costs per pixel are noise next to the per-byte savings.
`ansifg`'s 7 bytes are fully unrolled as immediate `ld (hl),n`/`inc hl`
pairs (compile-time constants, cheaper than a copy loop). `printdec`'s
digit-emission point (`pd3`) swapped from `call printCh` to
`ld (hl),a`/`inc hl` - the rest of `pd1`-`pd4`'s logic only ever touches
`a`/`c`/`e`/the stack, never `h`/`l`, so the buffer cursor survives the
call into it for free. `ansifg`'s DEFB table is now dead code (bytes
inlined) and was deleted rather than left stale.

`flushLine` sends the buffered row in one pass using a **NUL-terminator
scan** rather than a byte counter: `inner_loop_end` appends a `0` after
the trailing CR/LF, and `flushLine` just walks `hl` forward until it
hits one. This sidesteps a real register-allocation conflict: `CIOOUT`
needs `b`/`c` as its own inputs (function code/device) every call, so a
16-bit byte count can't live in `bc` without colliding with them, and
`d`/`h`/`l` (the registers actually free to hold persistent state) can't
hold a full 16-bit count either without a second register for the walk
pointer. A sentinel avoids needing a count register at all - safe here
specifically because none of the real bytes ever written (`ESC`, digits,
`;`, `'m'`, pixel chars, CR, LF) are ever legitimately `0`. `b` is loaded
with `hbios_cioout` once before the loop (confirmed stable across calls);
`c` is reloaded every iteration (confirmed *not* stable - see the
register-clobber probe above).

**Verified:** real hardware render visually confirmed correct by the
user (colors/shape match prior runs) rather than a manual byte-diff -
decided against hand-transcribing the ~10KB raw ANSI capture for this
one, since that transcription step is itself a known source of
introduced errors (see the "manually retyping...is unreliable" lesson
lower in this file), and a full-render visual confirmation on the actual
target hardware is this project's own stated standard of proof anyway.

**Measured: 28.63s vs. 28.8s before this change - flat, within noise.**
Re-ran the `OUTPUT=0`/`OUTPUT=1` split to understand why: 25.53s
compute-only vs. 28.63s with output, so ~3.1s of output overhead
remains - essentially the *same absolute* number as the very first
`OUTPUT=0` split ever measured on this project (~3.3s, back when the
*total* baseline was 45.09s and none of the output-path work existed
yet). That's strong evidence the ~3s left over isn't CPU-side
push/pop/dispatch cost at all (which is exactly what both the ESC
relocation and this buffering targeted, and both real wins on paper) -
it's much more likely bounded by the UART's actual transmission time at
whatever baud rate this board runs, a cost no amount of CPU-side
buffering can reduce. Keeping the buffering change anyway - it's
strictly correct, not slower, and structurally simpler at the call sites
(one buffer append instead of a `printCh` call each) - but not
worth further investment down this path without first finding a way to
raise the baud rate or confirming the bottleneck some other way.

### Done: dedicated square_16 routine for z^2 (skips redundant sign handling)

`l_muls_32_16x16` is fully generic - it takes the sign of *two
independent* operands (a `bit 7` check + conditional negate on each of
`d` and `h` at entry), then reconciles both signs via an XOR check and a
full 32-bit two's-complement negate at exit if they differed. But 5 of
the 7 multiply calls in this program are actually **squarings** (`Cy^2`
and the bulb/cardioid checks' operand^2 in the pre-check, plus `z_0^2`
and `z_1^2` in `iteration_loop`) - only the cardioid's `q*(q+b_raw)` and
the cross-product `2*z_0*z_1` are true two-operand multiplies. For a
squaring call, the second sign check is always redundant (same value,
same sign bit by definition) and the entire exit-path sign reconciliation
is dead code - XOR of two *identical* sign bits is always 0, so the
existing routine called as `l_muls_32_16x16(x,x)` was *already* taking
the immediate "positive, don't negate" return every single time; the
work was just always wasted, not incorrect.

Added `square_16`: same 16-step unrolled shift-add conveyor (bytewise
identical logic, duplicated with unique `sq_mulN_noadd` labels to avoid
colliding with the existing `l_mulN_noadd` ones - generated
programmatically to avoid a copy-paste slip across 16 near-identical
blocks, not typed by hand), but only one sign check/abs-value at entry
and a plain `ex de,hl` / `ret` at exit instead of the
pop/xor/ret-P/negate block. Deliberately **not** shared with
`l_muls_32_16x16` via a `call`/`ret` into a common conveyor - that would
add ~27T of call overhead back into the general routine (still used for
the two true multiplies) for roughly the same size as the win being
chased, so duplicating the conveyor inline was the right call despite
the code-size cost. Rewired all 5 squaring call sites (3 in the
cardioid/bulb pre-check, `z_0^2`/`z_1^2` in `iteration_loop`) to
`square_16`, dropping the now-unnecessary `ld d,h / ld e,l` duplication
at each of those sites too (`square_16` only needs `hl`). Left the two
true-multiply call sites (`q*(q+b_raw)`, `2*z_0*z_1`) on
`l_muls_32_16x16`, untouched.

**Verified two ways before touching hardware:** (1) traced through
`l_muls_32_16x16`'s own logic algebraically to confirm calling it with
identical operands always takes the "positive" exit path for any input,
by construction - not something that needed empirical checking, it's
just what the XOR-of-equal-bits does; (2) brute-force checked the
underlying shift-add conveyor algorithm (the part that's actually
duplicated) against Python's `x*x` across **all 65536 possible signed
16-bit values**, zero mismatches - this validates the *algorithm* both
routines share, which matters more here than checking my specific typed
bytes since the conveyor was generated programmatically rather than
hand-transcribed.

Both real ZAS and LINQ accepted the new code cleanly (worth checking
given several `jr` targets were added - all short forward jumps within
the new routine, never at risk of the known out-of-range-`JR` silent
-failure gotcha, but confirmed rather than assumed). Real-hardware render
visually confirmed correct by the user.

**Measured: 27.63s, down from 28.63s - ~3.5% faster.**

### Tried and reverted: magnitude pre-check before the multiply (negative result)

Idea: before each of the two `l_muls_32_16x16` calls in `iteration_loop`,
check whether `|z_0|` (or `|z_1|`) alone already exceeds the divergence
threshold in raw fixed-point units, and skip that multiply entirely
rather than computing the square just to immediately bail on it.

**Measured result after fixing a real correctness bug (below): ~44.44s,
vs the confirmed 43.61-43.62s baseline - about 1.9% *slower*, not
faster.** The overhead of the extra compare-and-branch on every
iteration outweighs the benefit of skipping the multiply on the (rarer
than expected) iterations where a point's magnitude already exceeds the
threshold before this iteration's multiply runs. **Reverted** -
`mandel_z80.asm` is back to the early-bailout-only version. Worth
remembering if precision reduction or other future work changes the
iteration count/shape enough to make this trade-off different, but not
worth keeping in the hot path as-is.

This was also a useful lesson in **not trusting a single measurement
against the wrong baseline**: the first pass compared the new build
against the on-device `J:MANDEL.COM`, which turned out to be a *stale*
build predating all three prior optimizations (it measured 45.1s,
matching README's original pre-optimization baseline, not the 43.61s
early-bailout figure). That made the regression look like a "modest
1.5% win" until a fresh git-HEAD build was assembled and measured
directly (43.62s) for a true apples-to-apples comparison. **Lesson:
don't assume a `J:` drive artifact from device state reflects the
current git HEAD - rebuild the exact baseline being compared against
when the numbers matter**, especially after any gap between sessions.

### Bug hit and fixed while building the (reverted) magnitude pre-check

First attempt at the pre-check used a single high-byte-only comparison
(`ld a,h` / `inc a` / `cp 3` / `jp NC,bailout`) reasoning that
`divergent*scale` (262144) is exactly `512^2`, so `|z_0| >= 512` should
be equivalent to the existing squared check. **This is wrong for
negative values** - two's complement is asymmetric here: for
`z_0` in the `h=0xFE` byte (raw values -512..-257), magnitude actually
*decreases* as the low byte increases, so only `z_0 == -512` exactly
should bail, but the high-byte-only check bailed on the *entire* byte
(all 256 values), incorrectly treating e.g. `z_0 = -257` (magnitude 257,
well under threshold) as divergent.

This was caught via real-hardware output comparison, not by inspection -
the rendered image looked visibly wrong (missing structure) on-device,
and stripping ANSI codes from the captured output to diff pixel colors
against a known-good baseline run showed **3283 of 6966 pixels (47%)**
had a different iteration-count color than the true baseline, despite
every pixel still being drawn (same `#` count both runs - the "sparse"
visual impression during debugging was a color-contrast illusion, not
missing pixels). That 47%-wrong version was the one that measured
~33.5s (~23% faster) - fast because it was bailing out of iterations it
had no business bailing out of.

**Fix:** bias `z_0` (or `z_1`) by `+511` and do a single unsigned 16-bit
compare against `1023` (`add hl,bc` / `sbc hl,bc` / `jp NC,bailout`).
This handles the wraparound correctly at both boundaries. Verified two
ways before re-touching hardware: (1) exhaustively in Python across all
65536 possible 16-bit `z_0` values, comparing against the *exact*
truncation semantics of the original 32-bit-multiply-then-shift check -
only diverges for `|z_0| > ~31000` raw units, far beyond what this loop
can ever produce given bounded per-iteration growth; (2) after
redeploying, stripped-ANSI pixel-color diff against the baseline run
came back **byte-for-byte identical (0 of 6966 pixels differ)**.

**Process lesson:** screenshots of the live terminal are not a reliable
way to diff program output - color-contrast illusions and ambiguity
about *which* run a screenshot was taken during (this session initially
mixed up which image was "old" vs "new") both got in the way. Capturing
raw command output and diffing the stripped ANSI/pixel data
programmatically is what actually resolved it. Also: manually
retyping/pasting captured terminal output (with its embedded ESC bytes)
into a file is unreliable - the ESC bytes got silently dropped on two
separate attempts in this session. If this comes up again, prefer a
method that doesn't require manually reproducing raw control characters
by hand.

### Second bug hit and fixed in the same change: `djnz` out-of-range

Adding the two pre-checks grew `iteration_loop`'s body by ~14 bytes,
pushing the loop's existing `djnz iteration_loop` backward branch to
**-141 bytes** - past `DJNZ`'s +-127 range. Unlike `JR` (which has a
`JP`-equivalent long form to fall back on), `DJNZ` has no such
substitute, so this can't be fixed by switching mnemonics the way the
earlier JR bug was (see README/commit history). Fixed with `dec b` /
`jp nz,iteration_loop` instead - `dec b` sets the Z flag the same way
djnz's implicit decrement would, and nothing between the old djnz site
and the next flag use depends on djnz's flags-unaffected behavior.

**Important correction to an earlier assumption:** PLAN.md previously
noted "z80asm (local toolbox) reported 0 errors" for the earlier JR
range bug, and guessed it silently auto-promotes out-of-range `JR` to
`JP`. Reading z80asm's own source (`~/z80pack/z80asm/z80asm.c`,
`z80arfun.c`) this session showed that's **not quite right**: z80asm's
`asmerr()` only prints the offending line/message when the error occurs
during **pass 1**; range-check failures like this happen during pass 2
(`chk_sbyte` inside `op_jr`/`op_djnz`), where `asmerr()` silently
increments the error counter with **no message at all** - only the final
"N error(s)" line changes from a JR/DJNZ range failure, with zero
indication of which line. Local z80asm does *not* auto-promote; it just
reports the error invisibly. **Lesson: always check the "N error(s)"
count itself, don't assume 0 just because no per-line error text
printed** - and if it's nonzero with no visible detail, suspect a
pass-2-only range check (JR/DJNZ backward or forward branch too far)
first, especially right after a code-size change near a
loop-back-edge.

### Known ZAS bug hit and fixed while building early-bailout

Used `jr NC,bailout` for the two new bailout branches. The `bailout:`
label sits ~145-189 bytes past those two jump sites - **out of `JR`'s
+-127 byte range**. This should be a hard assembly-time error ("Jump
target out of range"), but:
- **z80asm (local toolbox) reported 0 errors** - most likely silently
  auto-promotes an out-of-range `JR` to `JP` under the hood, which masked
  the bug entirely in local testing.
- **Real on-device ZAS also reported 0 errors**, but produced a corrupt
  object file: `LINQ` failed with "No File" and then its own `.COM` entry
  became unreadable/vanished from whatever drive it was loaded from
  (happened identically on both `B:` and `J:` - not drive-specific).
  Confirmed via a control test: re-linking a known-good `.OBJ`
  (`MANDELV3.OBJ`) worked fine immediately after, isolating the fault to
  the bad object file, not device/RAM-disk flakiness.

Fixed by changing both sites to `jp NC,bailout` (unconditional range, only
costs 1 extra byte / a few T-states, and these aren't hot-path jumps).

**Lesson for future work:** this ZAS build has now shown two silent-failure
modes with no error message (the `IF`/`COND` alias bug from earlier, and
this `JR`-range bug). Don't trust "0 errors" from ZAS alone for anything
involving a jump/conditional whose target distance isn't obviously short -
verify byte distance by hand or cross-check against z80asm's listing
output when in doubt. If `LINQ` ever says "No File" and a program that
worked a moment ago stops being findable afterward, suspect a bad `.OBJ`
from the *previous* assemble before suspecting the device.

Fixed and confirmed on-device: 43.61s, output unchanged, `LINQ`/`H:` left
intact afterward. Committed.

## Workflow notes

- **Build location:** assemble/link on `B:` (RAM disk) when possible -
  keeps iteration CF/SD-card-write-free. `ZAS`/`LINQ` themselves live on
  `H:` and are found via ZSDOS path search regardless of current drive, so
  they don't strictly need copying to `B:` - though caching copies there
  removes even the H: read from the loop. Persist only final `.ASM` +
  `.COM` to `J:` when a result is worth keeping.
- **Measured, not assumed:** moving the build to `B:` (or caching the
  toolchain there) made **no measurable difference** to assemble (~21s)
  or link (~5s) time versus `J:` - confirmed empirically, twice. The
  assemble/link steps are CPU-bound (two-pass parsing/codegen on a
  7.37MHz Z80), not disk-I/O-bound. Worth doing for CF wear, not speed.
- `B:` is only 344KB and fills up fast with iteration debris (source +
  obj + sym + com per attempt, plus the 64KB toolchain if cached there).
  `ERA B:*.*` (confirm with `Y`) between rounds of heavy iteration.

## Backlog

- **[bridge-coupled] Binary pixel-stream protocol for rc2014bridge,
  spec finalized, implementation not started.** Motivated by this
  session's `OUTPUT=0` finding: the ~3.1s of output overhead left after
  both the ESC-relocation and buffering work is essentially constant
  regardless of CPU-side changes, strong evidence it's bounded by UART
  transmission time rather than call/register overhead - meaning the
  only lever left is reducing actual bytes sent, not instructions per
  byte. Evolved past a simple char-only RLE idea once we noticed
  `chartable`/`hsv` are indexed by the *same* value (iteration count) -
  color and character were never two independent things to encode, so
  the design instead RLE-encodes the raw iteration count (0-30) directly
  in a fixed-width `iiiiirrr` binary token (5-bit index, 3-bit run code,
  extension byte for runs >7), with the receiving side (`rc2014bridge`)
  owning all color/character rendering - including a move from
  xterm-256-approximated ANSI colors to real RGB pixels drawn directly
  via `pygame` (already the bridge's actual rendering layer), bypassing
  the `pyte` character-grid path entirely for this mode. Verified against
  real captured render data: beats both a plain escape-byte RLE scheme
  and the same scheme without an extension byte, on both flat and
  detail-heavy rows (~10-25% of raw size depending on row content, vs.
  ~17-37% for the simpler schemes).

  Full spec, palette (RGB derived from the current `hsv` table, not
  invented), golden test vectors, and a Python reference encoder now live
  in `protocol/` in this repo (`DESIGN.md`, `mandel_pixel_stream.yaml`,
  `generate_test_vectors.py`), mirrored uncommitted into
  `~/src/rc2014bridge/protocol/` so a separate agent can build the
  bridge-side decoder/renderer against the same contract while this repo
  builds the Z80-side encoder - **read `protocol/DESIGN.md` first**, it
  covers the responsibility split, activation-mechanism open question,
  and testing order (golden vectors -> round-trip -> Z80-vs-Python
  cross-check -> real hardware last).

  Protocol is deliberately board-agnostic - no RC2014/Z80-specific
  assumptions - since a Z180 port later (hardware `MLT`, 36.8MHz vs. the
  RC2014's 7.372MHz, see `mandel_z180.asm`) is a real possibility worth
  not designing against. Not in scope for the initial build.

  One honest calibration worth remembering before chasing a big
  resolution increase to "show off detail": of the current 27.63s, only
  ~3.1s is output - even eliminating all of it only funds a ~11% bump in
  pixel count at the same wall-clock budget. A meaningfully higher-
  resolution render is a compute-time question, not something this
  protocol unlocks on its own (see `DESIGN.md`'s open questions).

  New source variant needed on this side (`mandel_z80.asm` stays as-is;
  something like `mandel_z80_pixelstream.asm` gets the new streaming
  encoder) - `hsv`/`chartable`/`colorpixel`/`setcolor`/`printdec` all go
  away under this protocol, replaced by a much smaller streaming RLE
  encoder tracking `(last_index, run_count)` across pixels. Not started.
- **[workflow] Keep a J: history of past .COM builds** - user wants each
  build worth keeping persisted to `J:` as `MANDELnn.COM` (`MANDEL01.COM`,
  `MANDEL02.COM`, ...) in order of progression, binary only, so they can
  re-run any past version themselves on the physical device without going
  through the host. Not done yet - current convention only keeps the
  latest source at `J:MANDEL.ASM` (see AGENT.md).
- ~~Test `UNZIP.COM` / source compression~~ **Done, validated, real win.**
  `UNZIP.COM` (`UNZIPZ 0.4-1 - SC`, from the RomWBW repo, sitting
  untracked in this repo pending a licensing decision - same provenance
  caution as the gitignored HI-TECH reference files) supports Deflate
  correctly. First attempt looked like it didn't (silently skipped a
  Deflate-compressed test file) - that was a syntax bug on my end (bare
  `E` instead of `/E`), not a real tool limitation; corrected syntax
  extracted a Deflate archive byte-identical. Re-tested with the actual
  source and measured the full real-world cycle:
  - Raw upload of `mandel_z80.asm` (32381 bytes, 253 XMODEM blocks):
    **53.30s**
  - `zip`-compressed upload (7810 bytes, 62 blocks, 76% smaller) + on-
    device `UNZIP ... /E`: **26.83s + 9.4s = 36.23s**
  - **~32% faster end-to-end, verified byte-identical** (sha256 of the
    unzipped file matched the raw upload exactly)

  Worth adopting for the main edit/build iteration loop: zip the source
  on host, upload the zip, `UNZIP <name> /E` on-device, then proceed as
  normal. Syntax notes for next time: `UNZIP <name>` (no `.ZIP`, no
  option) checks CRCs only; `UNZIP <name> /E` extracts (option must be
  `/E` with the leading slash - a bare `E` gets parsed as part of the
  archive-filename-filter field instead and silently matches nothing).
  8.3 filename truncation applies to the extracted name (`mandel_z80.asm`
  extracted as `MANDEL_Z.ASM`) - account for that in any scripted
  workflow.
- **[workflow] Multi-file transfer bundling** - separate idea surfaced
  while closing the item above: even without compression, bundling
  several files into one zip could still cut down the *number* of XMODEM
  sessions when transferring multiple files at once (each has its own
  ~15s fixed setup overhead, measured earlier via `rc2014_calibrate_
  pacing`). Not relevant to the current single-file source workflow, but
  worth remembering if a future task needs to push several files over at
  once.
- **Binary compare across all available assemblers** - once the current
  source is stable, build with real ZAS (device), pasmo, and z80asm and
  diff the output. Note: an earlier guess here that z80asm silently
  auto-promotes out-of-range `JR`/`DJNZ` was checked against z80asm's own
  source this session and found to be wrong - it just fails silently
  (see "Important correction to an earlier assumption" above) - so don't
  expect that particular difference; still worth doing the comparison for
  other possible divergences.
- **SDCC comparison build** (Phase 3.1) - port to C, build with `sdcc
  -mz80` in a `mandel-c` toolbox, compare size/runtime against hand-tuned
  asm. Educational/exploratory, lower priority than the asm optimization
  work.
- **z88dk comparison build** (Phase 3.2) - same idea, `zcc +cpm`. On
  Fedora both sdcc and z88dk are plain `dnf install`, no source build
  needed (unlike the originally-considered Ubuntu toolbox).
- **[rc2014bridge] Capture/relay VT100 color control codes** - cross-repo,
  not this session. The bridge's screen capture doesn't currently surface
  ANSI color codes for verification without a manual screen-capture-and-
  paste workaround.
- **[future] Custom RomWBW/HBIOS-aware Z80 emulator** - longer-term idea.
  z80pack's cpmsim was abandoned for running the *real* on-device ZAS/LINQ
  locally because it ships stock CP/M 2.2, not ZSDOS, and ZAS appears to
  depend on a ZSDOS-specific BDOS extension (this is a separate, earlier-
  discovered issue from the JR bug above - cpmsim traps/silently fails
  regardless of the JR bug). User has the RomWBW source and thinks a
  custom emulator with real HBIOS/RomWBW support may not be too hard.
  Before building one from scratch, take a look at an existing project
  that may already solve this: https://github.com/avwohl/romwbw_emu -
  not yet evaluated for whether it actually runs ZSDOS/ZAS correctly.
