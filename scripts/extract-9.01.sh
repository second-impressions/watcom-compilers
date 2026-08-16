#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# extract-9.01.sh — produce an installed WATCOM C/386 9.01 (base, May 1992)
# tree by running the original INSTALL.SCR against a flattened floppy
# staging area.  This is the un-patched base onto which the c386_a..e
# patch chain applies; a pre-extracted 9.01d tree at a later patch level
# is handled separately by extract-9.01d.sh.
#
# Usage:
#     extract-9.01.sh DEST_DIR [ARCHIVE_DIR]
#
# Arguments:
#     DEST_DIR     Directory to install into (e.g. /opt/watcom).
#     ARCHIVE_DIR  Directory holding Disk01.img .. Disk06.img.  Defaults to
#                  /archives/watcom-9.01/floppies.
#
# Distribution shape
# ------------------
# Six 1.2 MB raw-FAT floppy images (Disk01.img .. Disk06.img, OEM-ID
# HDCPY17A, WinWorld provenance).  The payload is
# Watcom WPK-packed (0x2403, unpacked via the DOS wpack.exe under
# dosemu2 — wpack_decode.py does not handle the 9.x-era variant), and
# install is driven by INSTALL.SCR on disk 1 via install_scr.py
# (--yes-all).  Same mechanism as extract-8.5.sh, but the floppies are
# loose raw images rather than .vfd members inside a zip.
#
# The result compiles + links + runs 32-bit DOS/4GW targets via the
# bundled Rational DOS extender (`wcl386 -l=dos4g`), tree layout
# binb/ (host tools) + bin/ (wcc386, dos4gw).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    err "usage: $0 DEST_DIR [ARCHIVE_DIR]"
fi

DEST="$1"
ARCHIVE_DIR="${2:-/archives/watcom-9.01/floppies}"

[ -f "$ARCHIVE_DIR/Disk01.img" ]  || err "missing floppy images in: $ARCHIVE_DIR"
[ -f "$WATCOM_TOOLS/wpack.exe" ]  || err "missing $WATCOM_TOOLS/wpack.exe"

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

log "extract-9.01: destination = $DEST"
log "extract-9.01: archive dir = $ARCHIVE_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# -----------------------------------------------------------------------------
# Flatten every floppy into a single staging directory, lower-casing each
# filename so install_scr.py can resolve the INSTALL.SCR refs (written
# %1wcl386.wpk, %1wcc386.dos, ...).
# -----------------------------------------------------------------------------
STAGE="$WORK/stage"
mkdir -p "$STAGE"
for i in 01 02 03 04 05 06; do
    img="$ARCHIVE_DIR/Disk$i.img"
    [ -f "$img" ] || err "missing floppy image: $img"
    log "  staging Disk$i.img"
    while IFS= read -r name; do
        name="${name#::/}"
        [ -z "$name" ] && continue
        [[ "$name" == */ ]] && continue
        mcopy -n -i "$img" "::$name" \
            "$STAGE/$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    done < <(mdir -i "$img" -b :: 2>/dev/null)
done

# -----------------------------------------------------------------------------
# Run the original installer script against the staging dir.
# -----------------------------------------------------------------------------
mcopy -n -i "$ARCHIVE_DIR/Disk01.img" ::INSTALL.SCR "$WORK/install.scr"

log "run: 9.01/386 installer (--yes-all, full component set)"
python3 "$SCRIPT_DIR/lib/install_scr.py" \
    --script "$WORK/install.scr" \
    --source "$STAGE" \
    --dest   "$DEST" \
    --watcom-tools "$WATCOM_TOOLS" \
    --yes-all

log "extract-9.01: done"
log "  total size: $(du -sh "$DEST" | cut -f1)"
log "  top-level : $(ls "$DEST" | tr '\n' ' ')"
