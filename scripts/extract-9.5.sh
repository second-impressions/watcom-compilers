#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# extract-9.5.sh — produce an installed Watcom C/C++ 9.5 tree by running
# the original Watcom installer scripts against a flattened floppy
# staging area.
#
# Usage:
#     extract-9.5.sh DEST_DIR [FLOPPY_DIR]
#
# Arguments:
#     DEST_DIR    Directory to install into.
#     FLOPPY_DIR  Directory holding the .img floppy images. Defaults
#                 to /archives/watcom-9.5/floppies (where the extract
#                 container stage COPYs them).
#
# The Watcom 9.5 distribution contains two installer scripts that run
# against the same destination tree:
#
#   1. The 32-bit installer (from W9532_01's INSTALL.SCR) builds the
#      main tree: h/, lib386/, binb/, binp/, binnt/, binw/, src/.
#      Runs first.
#   2. The 16-bit "Delta Pack" installer (from W9516_01's INSTALL.SCR)
#      layers 16-bit tools and libraries on top: bin/wcc.exe, lib286/,
#      startup sources. Runs second because it depends on the 32-bit
#      h/ tree already existing.
#
# Both scripts are executed by scripts/lib/install_scr.py with
# `--yes-all` so every `ask` prompt answers 'y', i.e. we request a
# full install with every optional component.
#
# The OS/2 Toolkit floppies (OS2TK_1..6.img) are a separate add-on and
# are not installed here. They are archived for completeness only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    err "usage: $0 DEST_DIR [FLOPPY_DIR]"
fi

DEST="$1"
FLOPPY_DIR="${2:-/archives/watcom-9.5/floppies}"

[ -d "$FLOPPY_DIR" ] || err "floppy directory does not exist: $FLOPPY_DIR"
[ -f "$WATCOM_TOOLS/wpack.exe" ] || err "missing $WATCOM_TOOLS/wpack.exe"

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

log "extract-9.5: destination = $DEST"
log "extract-9.5: floppy dir  = $FLOPPY_DIR"

# -----------------------------------------------------------------------------
# Pre-flatten every floppy into a staging directory.
#
# Each floppy is copied into its own flat directory, with every file
# name lower-cased. The 16-bit and 32-bit sets MUST land in separate
# directories: a few filenames (cplx.wpk, plib.wpk, cplx7.wpk, …) exist
# on both sets with *different* content (16-bit vs 32-bit libraries).
# -----------------------------------------------------------------------------
STAGING_ROOT="$(mktemp -d)"
trap 'rm -rf "$STAGING_ROOT"' EXIT

STAGE32="$STAGING_ROOT/s32"
STAGE16="$STAGING_ROOT/s16"
mkdir -p "$STAGE32" "$STAGE16"

stage_floppies() {
    local stage="$1"; shift
    local img
    for img in "$@"; do
        [ -f "$img" ] || err "missing floppy image: $img"
        log "  staging $(basename "$img")"
        # mcopy supports globbing with `::*`; -D o (overwrite)
        # preserves the expected behaviour if the same filename somehow
        # appears on two floppies in the same set. Filenames are
        # lower-cased by `mcopy -s ::` piped through a name filter.
        local name
        while IFS= read -r name; do
            [ -z "$name" ] && continue
            # Strip the leading ::/ that mdir adds.
            name="${name#::/}"
            [ -z "$name" ] && continue
            # Drop any directory entries (none expected on these
            # floppies but belt and braces).
            [[ "$name" == */ ]] && continue
            mcopy -n -i "$img" "::$name" \
                "$stage/$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
        done < <(mdir -i "$img" -b :: 2>/dev/null)
    done
}

log "stage: 32-bit floppies W9532_01..10"
stage_floppies "$STAGE32" "$FLOPPY_DIR"/W9532_{01..10}.img

log "stage: 16-bit floppies W9516_01..04"
stage_floppies "$STAGE16" "$FLOPPY_DIR"/W9516_{01..04}.img

# -----------------------------------------------------------------------------
# Extract both INSTALL.SCR files into a scratch location and run each
# one through the interpreter against the appropriate staging dir.
# -----------------------------------------------------------------------------
SCR_DIR="$STAGING_ROOT/scr"
mkdir -p "$SCR_DIR"

mcopy -n -i "$FLOPPY_DIR/W9532_01.img" ::INSTALL.SCR "$SCR_DIR/install-9532.scr"
mcopy -n -i "$FLOPPY_DIR/W9516_01.img" ::INSTALL.SCR "$SCR_DIR/install-9516.scr"

log "run: 32-bit installer"
python3 "$SCRIPT_DIR/lib/install_scr.py" \
    --script "$SCR_DIR/install-9532.scr" \
    --source "$STAGE32" \
    --dest   "$DEST" \
    --watcom-tools "$WATCOM_TOOLS" \
    --yes-all

log "run: 16-bit delta pack installer"
python3 "$SCRIPT_DIR/lib/install_scr.py" \
    --script "$SCR_DIR/install-9516.scr" \
    --source "$STAGE16" \
    --dest   "$DEST" \
    --watcom-tools "$WATCOM_TOOLS" \
    --yes-all

log "extract-9.5: done"
log "  total size: $(du -sh "$DEST" | cut -f1)"
log "  top-level : $(ls "$DEST" | tr '\n' ' ')"
