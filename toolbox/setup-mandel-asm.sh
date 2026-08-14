#!/bin/sh
# Reproducible build script for the `mandel-asm` Fedora 44 toolbox: a local
# environment for fast local-syntax/assembly checks on mandel_z80.asm without
# a device round-trip. Provides:
#   - z80pack's z80asm: a plain CLI Z80 assembler, useful both for fast local
#     sanity checks and as a second data point for the cross-assembler
#     binary-comparison step
#   - fzf/sqlite3/lsd so oh-my-bash's ble.sh integrations and `ls`/`ll`/`dir`
#     aliases work as expected on entry
#
# Note: we tried running the real on-device HI-TECH ZAS.COM/LINQ.COM locally
# under z80pack's cpmsim (a cycle-accurate CP/M 2.2 simulator) first, since
# that would have given byte-identical output to the device. Abandoned: the
# device runs ZSDOS, cpmsim ships stock CP/M 2.2, and ZAS.COM appears to
# depend on a ZSDOS-specific BDOS extension (traps on an unimplemented opcode
# under cpmsim, or silently produces no output, depending on run). Real ZAS
# stays device-only for now. See task "[future] Build custom RomWBW/HBIOS-
# aware Z80 emulator" for a possible real fix later.
#
# Safe to re-run: `toolbox create`, `dnf install`, and the z80pack build all
# tolerate being run again.
#
# Usage: sh setup-mandel-asm.sh
set -e

TOOLBOX=mandel-asm

if ! podman ps -a --format '{{.Names}}' | grep -qx "$TOOLBOX"; then
	toolbox create --distro fedora --release 44 "$TOOLBOX"
fi

# One-time bootstrap exception: this is the only step that talks to podman
# directly instead of `toolbox run`. sreed ends up in the wheel group via
# toolbox's own container-init, but that init only runs on an interactive
# `toolbox enter` - and even once it has, wheel's default policy needs an
# interactive password, which non-interactive automation can't supply. So we
# grant this container's own user passwordless sudo once, up front; every
# other step below goes through `toolbox run ... sudo ...` as normal.
if ! podman exec --user root "$TOOLBOX" test -f /etc/sudoers.d/sreed-nopasswd 2>/dev/null; then
	podman exec --user root "$TOOLBOX" sh -c \
		'echo "sreed ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sreed-nopasswd && chmod 440 /etc/sudoers.d/sreed-nopasswd'
fi

toolbox run -c "$TOOLBOX" sudo dnf install -y \
	gcc gcc-c++ make git \
	kitty-terminfo \
	fzf sqlite lsd

# Clone z80pack, build only the z80asm tool (skip `make all` - that also
# builds the GUI frontpanel, cpmsim, and every other simulated machine we're
# not using).
toolbox run -c "$TOOLBOX" sh -c '
	set -e
	if [ ! -d ~/z80pack ]; then
		git clone --depth 1 https://github.com/udo-munk/z80pack.git ~/z80pack
	fi
	cd ~/z80pack/z80asm && make
'

echo "Done. Enter with: toolbox enter $TOOLBOX"
echo "Then:  ~/z80pack/z80asm/z80asm <flags> mandel_z80.asm"
