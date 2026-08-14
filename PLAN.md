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
   two prior optimizations).

**Not yet decided:** what to tackle next. Precision reduction (drop
`scale` from 256, shrinking the multiply routine itself) and further
early-bailout tuning (pushing the check even earlier/cheaper) were both
on the table when this was last picked up - see conversation/ask the user
which direction before starting.

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

- ~~Test `UNZIP.COM`~~ **Done, closed.** `UNZIP.COM` (`UNZIPZ 0.4-1 - SC`,
  from the RomWBW repo, sitting untracked in this repo pending a
  licensing decision - same provenance caution as the gitignored HI-TECH
  reference files) works correctly, but **only supports the `Stored`
  (uncompressed) method** - a `Deflate`-compressed zip was silently
  skipped; a `zip -0` (stored) archive extracted byte-identical. That
  kills the compression-for-transfer-speed idea via this tool: a stored
  zip of `mandel_z80.asm` is 32559 bytes vs 32381 raw - *larger*, not
  smaller, from container overhead with zero compression. Would need a
  Deflate-capable (or older Shrink/Reduce/Implode-capable) unzip to make
  this idea work at all, and producing those older formats isn't a quick
  `zip` flag with modern tools. Not pursuing further unless a different
  tool turns up.
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
  diff the output. Possible finding given what we now know: pasmo/z80asm
  may auto-promote out-of-range `JR`->`JP` silently, which would show up
  as a real byte-level difference worth explaining.
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
