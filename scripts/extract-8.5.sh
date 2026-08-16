#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# extract-8.5.sh — produce an installed WATCOM C 8.5/386 tree by running
# the original INSTALL.SCR against a flattened floppy staging area.
#
# Usage:
#     extract-8.5.sh DEST_DIR [ARCHIVE_DIR]
#
# Arguments:
#     DEST_DIR     Directory to install into (e.g. /opt/watcom).
#     ARCHIVE_DIR  Directory holding the distribution zip.  Defaults to
#                  /archives/watcom-8.5 (where the build stage bind-mounts it).
#
# Distribution shape
# ------------------
# The 8.5/386 set is five 1.2 MB floppy images (disk1.vfd .. disk5.vfd)
# inside `Watcom C 386.ver.8.5.English.zip`.  The payload is packed in
# Watcom's WPK format ("Install Archiver Version 1.2"); every .wpk (and
# the .DOS/.OS2/.386/.WIN raw-named packs) carries the 0x2403 signature.
# These 9.x-era packs are NOT decoded correctly by the pure-Python
# decoder in scripts/lib/wpack_decode.py — it is validated only against
# the 10.5/10.6 archives — so unpacking goes through the real DOS
# wpack.exe under dosemu2 (wpack_unpack in scripts/lib/common.sh).
#
# Install is driven by the single INSTALL.SCR on disk 1, interpreted by
# scripts/lib/install_scr.py with --yes-all (request every optional
# component, matching the 9.5 extractor).  The script lays out the
# canonical tree: binb/ (wcl386, wlink, wlib, wmake, wstub, ...), bin/
# (wcc386, 386wcgl, dos4gw, ...), lib386/{,dos,win}/, h/, h/sys/, src/.
#
# The result compiles + links + runs DOS/4GW targets via the bundled
# Rational DOS extender (`wcl386 -l=dos4g`), exactly as the INSTALL.SCR
# sample command (`wcl386 /l=dos4g calendar`) documents.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    err "usage: $0 DEST_DIR [ARCHIVE_DIR]"
fi

DEST="$1"
ARCHIVE_DIR="${2:-/archives/watcom-8.5}"
ZIP="$ARCHIVE_DIR/Watcom C 386.ver.8.5.English.zip"

[ -f "$ZIP" ] || err "missing distribution zip: $ZIP"
[ -f "$WATCOM_TOOLS/wpack.exe" ] || err "missing $WATCOM_TOOLS/wpack.exe"

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

log "extract-8.5: destination = $DEST"
log "extract-8.5: archive zip = $ZIP"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# -----------------------------------------------------------------------------
# 1. Unzip the five floppy images out of the distribution zip.
# -----------------------------------------------------------------------------
DISK_DIR="$WORK/disks"
mkdir -p "$DISK_DIR"
unzip -joq "$ZIP" 'disk*.vfd' -d "$DISK_DIR"

# -----------------------------------------------------------------------------
# 2. Flatten every floppy into a single staging directory, lower-casing
#    each filename so install_scr.py can resolve the INSTALL.SCR refs
#    (which are written %1wcl386.wpk, %1clib3r.dos, ...).
# -----------------------------------------------------------------------------
STAGE="$WORK/stage"
mkdir -p "$STAGE"
for vfd in "$DISK_DIR"/disk1.vfd "$DISK_DIR"/disk2.vfd "$DISK_DIR"/disk3.vfd \
           "$DISK_DIR"/disk4.vfd "$DISK_DIR"/disk5.vfd; do
    [ -f "$vfd" ] || err "missing floppy image inside zip: $(basename "$vfd")"
    log "  staging $(basename "$vfd")"
    while IFS= read -r name; do
        name="${name#::/}"
        [ -z "$name" ] && continue
        [[ "$name" == */ ]] && continue
        mcopy -n -i "$vfd" "::$name" \
            "$STAGE/$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    done < <(mdir -i "$vfd" -b :: 2>/dev/null)
done

# -----------------------------------------------------------------------------
# 3. Run the original installer script against the staging dir.
# -----------------------------------------------------------------------------
mcopy -n -i "$DISK_DIR/disk1.vfd" ::INSTALL.SCR "$WORK/install.scr"

log "run: 8.5/386 installer (--yes-all, full component set)"
python3 "$SCRIPT_DIR/lib/install_scr.py" \
    --script "$WORK/install.scr" \
    --source "$STAGE" \
    --dest   "$DEST" \
    --watcom-tools "$WATCOM_TOOLS" \
    --yes-all

log "extract-8.5: done"
log "  total size: $(du -sh "$DEST" | cut -f1)"
log "  top-level : $(ls "$DEST" | tr '\n' ' ')"
