# Mandel Z80 optimization - working plan

Consolidated tracking doc - context was getting large across many work
items, so this replaces scattered task tracking as the durable record.
See `README.md` for project history/timings; this file is for in-flight
and backlog work only.

## Current status

Branch `z80-optimization`, all committed. Three real optimizations
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

**Not yet decided:** what to tackle next. Precision reduction (drop
`scale` from 256, shrinking the multiply routine itself) is the main
candidate left on the table from the original optimization list.

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
