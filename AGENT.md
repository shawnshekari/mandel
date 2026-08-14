# Agent notes for this repo

Practical knowledge for picking this project back up cold - device
topology, build commands, toolbox setup, and gotchas that cost real time
to discover. See `PLAN.md` for current status/backlog and `README.md` for
project history and timings.

## The physical device

A real RC2014 Pro (RCZ80_std config), Z80 @ 7.372MHz, running RomWBW
HBIOS with ZSDOS/CP/M 2.2. Reached via the `rc2014bridge` MCP server
(package: `rc2014bridge`, tools prefixed `mcp__rc2014bridge__`). If those
tools aren't showing up in a session, it needs registering once per
project directory:
```
claude mcp add --transport http rc2014bridge http://127.0.0.1:8014/mcp --scope local
```
then restart the session - MCP tool lists only refresh on session start,
not mid-session. The bridge server itself runs locally on this same
machine; if it's not up, that's a separate concern (its own repo is
`~/src/rc2014bridge`).

Key tools: `rc2014_run_command` (send a command, get output + `duration_s`
wall-clock timing - this is how every timing number in README.md was
measured), `rc2014_upload`/`rc2014_download` (XMODEM file transfer),
`rc2014_send_keys` (e.g. `^C` to recover a stuck console).

## Drive layout (what's where, and why)

- **`H:`** - SD-backed, holds the HI-TECH Z80 C v3.09-17 toolchain:
  `ZAS.COM` (assembler), `LINQ.COM` (linker), headers, libraries. Treat as
  read-only/stable. Host-side backup copies exist at
  `~/src/rc2014bridge/ZAS.COM` and `~/src/rc2014bridge/LINQ.COM` (pulled
  once via `rc2014_download`) - if either ever goes missing from `H:`
  (has happened - see Gotchas below), restore from there with
  `rc2014_upload`.
- **`J:`** - SD-backed, persistent. Where the "real" `MANDEL.ASM` lives
  between sessions. Upload here (zipped, per below) when a result is worth
  keeping. **Just the source** - don't bother round-tripping `.OBJ`/`.COM`/
  `.SYM` through the host, they're one `ZAS`+`LINQ` away from `J:MANDEL.ASM`
  whenever they're actually needed, and keeping them in sync on every
  change is pure overhead.
- **`B:`** - RAM disk (`MD0:0`), 344KB, volatile (cleared on power cycle
  only, not between commands). Use for iteration scratch work - assemble/
  link/test here to keep the SD card write-free during rapid iteration.
  Fills up fast (block-size rounding wastes space on lots of small files)
  - `ERA B:*.*` (confirm with `Y`) between rounds of heavy iteration.
  `ZAS`/`LINQ` are found via ZSDOS path search from `H:` regardless of
  current drive, so they don't strictly need copying to `B:`, but caching
  them there removes even that read from the loop.
  **Note:** moving the build to `B:` measured as making no difference to
  assemble (~21s) or link (~5s) time vs `J:` - confirmed empirically,
  twice. The steps are CPU-bound, not disk-bound. Do it for SD wear, not
  speed.

## Uploading source: zip it first

Measured, real win: zip the source on host before `rc2014_upload`, then
`UNZIP` it on-device, instead of uploading the raw `.asm` directly.
`mandel_z80.asm` (32381 bytes, 253 XMODEM blocks) took 53.30s raw vs
26.83s zipped (7810 bytes, 62 blocks, ~76% smaller) + 9.4s to unzip on
device = 36.23s total - **~32% faster end-to-end**, verified
byte-identical after extraction. XMODEM transfer time is apparently
dominated by per-block overhead, not raw bytes, so shrinking the block
count wins even after paying for decompression.
**Two different `UNZIP.COM` builds exist on this device, with different
syntax, and ZSDOS path search (`A0,A1,H0`) picks whichever one it finds
first depending on what's currently on `A:`/`B:`/`H:`** - check the
banner line each time, don't assume:

```
UNZIPZ 0.4-1 - SC     (found on A: this session)
zip -j out.zip mandel_z80.asm          # on host, before rc2014_upload
UNZIP <name>       # no .ZIP, no option: check-only, CRCs of all files
UNZIP <name> /E    # extract - MUST be /E (leading slash); bare E is
                    # parsed as an archive-filename filter instead and
                    # silently matches nothing

UNZIP 1.8-7 - DPG      (showed up once B: was cleared and path search
                        landed on a different UNZIP.COM elsewhere)
UNZIP <name>              # no destination arg: check-only, lists "Skipping"
UNZIP <name> d:*.*        # MUST give an explicit drive-letter destination
                          # to extract, even for the current drive (bare
                          # "*.*" with no drive prefix silently no-ops too -
                          # "Checking" instead of "Extracting" in the banner
                          # is the tell)
```
8.3 filename truncation applies to the extracted name (`mandel_z80.asm` ->
`MANDEL_Z.ASM`) - account for that when scripting this, regardless of
which `UNZIP` variant is in play.

`UNZIP.COM` itself is **not** kept in this repo - it ships as part of
RomWBW, and both variants above were eventually found already on-device
(`A:` had the `0.4-1 SC` build; a later session found `1.8-7 DPG`
elsewhere on the search path after `B:` was cleared) - the earlier note
here about it being missing was a stale drive-listing snapshot, not a
real gap.

## Build commands

```
ZAS <name>.ASM
LINQ -Z -N -C100H -D<name>.SYM -O<name>.COM <name>.OBJ
```
Both silent (no output) on success. Run the resulting `.COM` by bare name
(no extension) - `rc2014_run_command("<name>", timeout=120)` (a full
render takes ~40-45s; use a generous timeout).

## Local toolbox (`mandel-asm`)

Fedora 44 podman toolbox, fully reproducible via `toolbox/setup-mandel-
asm.sh` in this repo (re-run any time to rebuild from scratch). Provides
`z80pack`'s `z80asm` at `~/z80pack/z80asm/z80asm` for fast local syntax
checks with **zero device round-trip**:
```
toolbox run -c mandel-asm sh -c "~/z80pack/z80asm/z80asm -e32 -fb -o/tmp/out.bin mandel_z80.asm"
```
The `-e32` flag is required - without it (default is 8 significant
symbol-name characters) labels like `l_mul10_shift` collide with
`l_mul1_shift` and produce bogus "multiple defined symbol" errors.

Automation talks to the toolbox via `toolbox run -c mandel-asm ...`
(passwordless `sudo` was set up once for this container specifically -
see the setup script's comments for why that was necessary). The toolbox
shares the host home directory automatically, so it operates on this
repo's files directly at their normal host paths - no copying needed.

z80pack's `cpmsim` (a cycle-accurate CP/M simulator) was tried and
**abandoned** as a way to run the real on-device `ZAS`/`LINQ` locally -
it ships stock CP/M 2.2, but `ZAS` appears to depend on a ZSDOS-specific
BDOS extension and either traps or silently no-ops under cpmsim. See
`PLAN.md` backlog for the "build a real RomWBW-aware emulator" idea that
would actually solve this.

## Gotchas (cost real time to find - don't rediscover these)

- **This specific `ZAS` build has at least two silent-failure modes**,
  neither reported as an error:
  1. `IF`/`ENDIF` (documented as a `COND`/`ENDC` synonym) silently
     mis-parses and corrupts the following line. Use `COND`/`ENDC`
     directly - both `ZAS` and local `z80asm` accept that form.
  2. Out-of-range `JR` (target >127 bytes away) is silently accepted
     instead of erroring "Jump target out of range." Manifests
     downstream: `LINQ` fails with "No File" and then its *own* `.COM`
     entry becomes unreadable on whatever drive it was loaded from -
     looks exactly like device/RAM-disk corruption. It isn't - it's a
     bad `.OBJ` from the assemble before. If this happens, re-link a
     *known-good* `.OBJ` first as a control test before suspecting the
     device; if that works, the fault is in the most recent source
     change. Use `JP` for any jump whose target isn't obviously close by.
  3. Local `z80asm` does **not** reproduce bug #2 - it most likely
     auto-promotes out-of-range `JR` to `JP` silently, so "0 errors"
     locally doesn't guarantee `ZAS` will agree. Cross-check jump
     distances by hand when in doubt.
- **No RTC hardware on this board** (`rc2014_get_hardware_info` shows
  `DSRTC: ... NOT PRESENT`). The source has a working RTC-absence guard
  (`rtc_ok` flag, checked before printing date/time) - don't remove it,
  and don't trust wall-clock numbers from the program's own printed
  elapsed-time field (it's skipped entirely here). All real timing in
  this project comes from the bridge's `duration_s`, not the program.
- **The `OUTPUT` flag** (top of `mandel_z80.asm`, `COND OUTPUT` around
  `colorpixel`) toggles all pixel/color output for isolating compute time
  from serial-I/O time. Flip to `0`, rebuild, time both variants with the
  same `rc2014_run_command` call to split the two.

## Working style on this project

This is a for-fun/educational project. The user wants to work through
changes together, not have them applied autonomously in bulk - propose
one concrete change, explain the reasoning, wait for a go-ahead, measure
on real hardware, then check in again before the next one. Real hardware
measurement (not simulation, not theoretical T-state counting alone) is
the standard of proof for "did this help."
