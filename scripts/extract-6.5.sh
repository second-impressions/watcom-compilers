#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# extract-6.5.sh — produce an installed WATCOM C 6.5 (16-bit) tree by
# running the original INSTALL.SCR against a flattened disk staging area.
#
# Usage:
#     extract-6.5.sh DEST_DIR [ARCHIVE_DIR]
#
# Arguments:
#     DEST_DIR     Directory to install into (e.g. /opt/watcom).
#     ARCHIVE_DIR  Directory holding the distribution zip.  Defaults to
#                  /archives/watcom-6.5.
#
# Distribution shape
# ------------------
# The 6.5 set is eight plain (un-WPK'd) floppy directories DISK1/ .. DISK8/
# inside `Watcom C.ver.6.5.English.zip`.  This is the 16-bit IBM PC/DOS
# compiler — it predates Watcom's 386 line.  Unlike 8.5+, nothing is
# packed: INSTALL.SCR is a plain `copy` script that lays out:
#
#     bin/   wcl.exe wcc.exe wcg.exe wcgl.exe wcpp.exe wlink.exe wlib.exe ...
#     lib/   clibs/clibc/clibm/clibl/clibh.lib (S/C/M/L/H models) + math/graph
#     h/, h/sys/   16-bit headers
#     src/         sample sources (hello.c, ...)
#
# The driver is `wcl` (16-bit), not `wcl386`; output is a plain DOS MZ
# executable that runs directly under dosemu2 (no DOS extender).
#
# Extraction
# ----------
# All eight DISK*/ trees are merged into one staging directory with every
# path lower-cased (the DISK2 H/ and SRC/ subtrees are preserved, since
# INSTALL.SCR copies e.g. `%1\h\assert.h` and `%1\src\hello.c`).  The
# original INSTALL.SCR is then run through scripts/lib/install_scr.py.
# No WPK decode and no DOS tool boot is needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    err "usage: $0 DEST_DIR [ARCHIVE_DIR]"
fi

DEST="$1"
ARCHIVE_DIR="${2:-/archives/watcom-6.5}"
ZIP="$ARCHIVE_DIR/Watcom C.ver.6.5.English.zip"

[ -f "$ZIP" ] || err "missing distribution zip: $ZIP"

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

log "extract-6.5: destination = $DEST"
log "extract-6.5: archive zip = $ZIP"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# -----------------------------------------------------------------------------
# 1. Unzip all eight DISK*/ trees.
# -----------------------------------------------------------------------------
RAW="$WORK/raw"
mkdir -p "$RAW"
unzip -oq "$ZIP" -d "$RAW"

# -----------------------------------------------------------------------------
# 2. Merge every DISK*/ into a single staging dir, lower-casing the whole
#    relative path (dir names included) so the INSTALL.SCR refs resolve.
# -----------------------------------------------------------------------------
STAGE="$WORK/stage"
mkdir -p "$STAGE"
for disk in "$RAW"/DISK[0-9] "$RAW"/DISK[0-9][0-9]; do
    [ -d "$disk" ] || continue
    log "  staging $(basename "$disk")"
    while IFS= read -r rel; do
        rel="${rel#./}"
        [ -z "$rel" ] && continue
        lower="$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]')"
        mkdir -p "$STAGE/$(dirname "$lower")"
        cp "$disk/$rel" "$STAGE/$lower"
    done < <(cd "$disk" && find . -type f)
done

# -----------------------------------------------------------------------------
# 3. Run the original installer script against the staging dir.
# -----------------------------------------------------------------------------
log "run: 6.5 (16-bit) installer (--yes-all)"
python3 "$SCRIPT_DIR/lib/install_scr.py" \
    --script "$STAGE/install.scr" \
    --source "$STAGE" \
    --dest   "$DEST" \
    --watcom-tools "$WATCOM_TOOLS" \
    --yes-all

log "extract-6.5: done"
log "  total size: $(du -sh "$DEST" | cut -f1)"
log "  top-level : $(ls "$DEST" | tr '\n' ' ')"
