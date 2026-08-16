#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# build-toolchain.sh — bootstrap the two tools this repository needs
# (wpack and bpatch) by extracting them from their own original Watcom
# distribution archives.
#
# Executed by containers/toolchain/Containerfile during the toolchain
# image build.
#
# Input (mounted read-only at /archives via COPY during build):
#   /archives/watcom-10.0/WATCOM_C10A.ISO
#   /archives/watcom-9.5/floppies/W9532_03.img
#
# Output:
#   /opt/watcom-tools/wpack.exe   (Watcom Install Archiver 1.3, real-mode DOS)
#   /opt/watcom-tools/bpatch.exe  (Watcom Binary Patch 1.3, dual-mode DOS/OS2 NE)
#
# Rationale
# =========
#
# Earlier iterations of this script attempted to build Open Watcom 2.0
# from source (~30-90 min) or hand-compile a minimal subset of its
# wpack/bpatch C source with gcc (blocked by generated headers and
# the wres library dependency). Both approaches were over-engineered.
#
# The observation that cut through the problem: the Watcom distributions
# in archives/ already contain the tools that created and applied their
# own files. Specifically:
#
#   1. disk01/wpack.exe on the 10.0a ISO is a plain MZ real-mode DOS
#      executable — Watcom Install Archiver 1.3. It understands the
#      WPK format (magic 03 24 01 01) used by all WPK files on the
#      9.5 floppies and in the 10.0a installer pack files.
#
#   2. BPATCH.WPK on the 9.5 32-bit floppy W9532_03.img is a WPK
#      archive containing the Watcom 9.5 GA bpatch.exe. It is a hybrid
#      DOS/OS2 1.x NE executable with a fully functional DOS stub that
#      prints its banner and usage and applies patches correctly when
#      run under dosemu2's real-mode interpreter.
#
# So the bootstrap is:
#
#   1. Copy wpack.exe out of the ISO (plain file copy — the ISO's
#      filesystem is ISO 9660, readable natively by mount -o loop).
#   2. Use that wpack.exe under dosemu2 to unpack BPATCH.WPK from
#      W9532_03.img, producing bpatch.exe.
#   3. Leave both tools in /opt/watcom-tools/ where the downstream
#      extract-*.sh and apply-patches-*.sh scripts expect them.
#
# Running these under dosemu2 inside downstream extract stages is done
# through small shell shims in scripts/shims/.

set -euo pipefail

ISO_PATH="${ISO_PATH:-/archives/watcom-10.0/WATCOM_C10A.ISO}"
FLOPPY_PATH="${FLOPPY_PATH:-/archives/watcom-9.5/floppies/W9532_03.img}"
OUT_DIR="${OUT_DIR:-/opt/watcom-tools}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

log() { printf '[build-toolchain] %s\n' "$*"; }

# -----------------------------------------------------------------------------
# Step 1: extract wpack.exe from the 10.0a ISO.
#
# We read the ISO via `bsdtar -xf`, which handles ISO 9660 read-only
# without needing loopback mount privileges. In a rootful build this
# could equivalently use `mount -o loop,ro`.
# -----------------------------------------------------------------------------
log "Step 1/3: extracting wpack.exe from ${ISO_PATH}"
mkdir -p "$OUT_DIR"
cd "$WORK_DIR"

# bsdtar handles ISO 9660 natively. Pull just the one file we need.
# Note: filenames inside the raw ISO 9660 directory are uppercase —
# the lowercase names we see when loopback-mounting come from the
# kernel's Rock Ridge / Joliet extension handling, which bsdtar does
# not apply by default when reading the image directly.
bsdtar -xf "$ISO_PATH" DISK01/WPACK.EXE
install -m 0755 DISK01/WPACK.EXE "$OUT_DIR/wpack.exe"
rm -rf DISK01

log "  wpack.exe installed ($(stat -c%s "$OUT_DIR/wpack.exe") bytes)"

# -----------------------------------------------------------------------------
# Step 2: extract BPATCH.WPK from the W9532_03.img floppy.
#
# mtools reads FAT12 floppy images without mounting.
# -----------------------------------------------------------------------------
log "Step 2/3: extracting BPATCH.WPK from ${FLOPPY_PATH}"
mcopy -n -i "$FLOPPY_PATH" ::BPATCH.WPK "$WORK_DIR/BPATCH.WPK"
log "  BPATCH.WPK size: $(stat -c%s "$WORK_DIR/BPATCH.WPK") bytes"

# -----------------------------------------------------------------------------
# Step 3: use wpack.exe under dosemu2 to unpack BPATCH.WPK → bpatch.exe.
# -----------------------------------------------------------------------------
log "Step 3/3: unpacking BPATCH.WPK via dosemu2"

# dosemu2 needs a working directory it can map as a DOS drive.
DOS_DIR="$WORK_DIR/dos"
mkdir -p "$DOS_DIR"
cp "$OUT_DIR/wpack.exe" "$DOS_DIR/wpack.exe"
cp "$WORK_DIR/BPATCH.WPK" "$DOS_DIR/BPATCH.WPK"

cd "$DOS_DIR"
# -dumb: headless stdio mode, no curses or SDL
# -quiet: suppress startup banner
# -K $PWD: map this unix dir as the DOS current drive
# -E "CMD": run CMD inside DOS and exit
dosemu -dumb -quiet -K "$PWD" -E "wpack.exe BPATCH.WPK"

if [ ! -f "$DOS_DIR/bpatch.exe" ]; then
    log "ERROR: wpack.exe did not produce bpatch.exe"
    log "Contents of $DOS_DIR:"
    ls -la "$DOS_DIR"
    exit 1
fi

install -m 0755 "$DOS_DIR/bpatch.exe" "$OUT_DIR/bpatch.exe"
log "  bpatch.exe installed ($(stat -c%s "$OUT_DIR/bpatch.exe") bytes)"

# -----------------------------------------------------------------------------
# Sanity check: both tools should run under dosemu2 and print their banners.
# -----------------------------------------------------------------------------
log "Smoke test: running wpack.exe and bpatch.exe under dosemu2"

# Fresh DOS dir for the smoke test so we don't pollute with pre-existing files.
SMOKE_DIR="$WORK_DIR/smoke"
mkdir -p "$SMOKE_DIR"
cp "$OUT_DIR/wpack.exe" "$OUT_DIR/bpatch.exe" "$SMOKE_DIR/"
cd "$SMOKE_DIR"

log "  wpack output:"
dosemu -dumb -quiet -K "$PWD" -E "wpack.exe" 2>&1 | grep -E "WATCOM|Usage" | head -3 || true

log "  bpatch output:"
dosemu -dumb -quiet -K "$PWD" -E "bpatch.exe" 2>&1 | grep -E "BPATCH|Usage" | head -3 || true

log "Toolchain ready: $OUT_DIR"
ls -la "$OUT_DIR"
