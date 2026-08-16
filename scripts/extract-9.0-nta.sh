#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# extract-9.0-nta.sh — produce an installed WATCOM C/386 9.0 "NT Alpha"
# (Feb 1992) tree by running the original INSTALL.SCR against a flattened
# staging area built from the four WC90NTA*.ZIP distribution disks.
#
# Usage:
#     extract-9.0-nta.sh DEST_DIR [ARCHIVE_DIR]
#
# Arguments:
#     DEST_DIR     Directory to install into (e.g. /opt/watcom).
#     ARCHIVE_DIR  Directory holding WC90NTA1.ZIP .. WC90NTA4.ZIP.
#                  Defaults to /archives/watcom-9.0/nt-alpha.
#
# Distribution shape
# ------------------
# Four BBS distribution ZIPs (WC90NTA1..4), each holding raw WPK-packed
# members plus (on disk 1) INSTALL.SCR.  Unlike 8.5/9.01 the disks are
# loose ZIPs rather than floppy images, so staging is a plain unzip +
# lower-case flatten; install is then driven by install_scr.py
# (--yes-all), same as the other pre-9.5 extractors.
#
# The tree is binb/ (wcl386, wlink, wlib, wmake) + bin/ (wcc386, dos4gw);
# it compiles + links + runs 32-bit DOS/4GW programs (`wcl386 -l=dos4g`).
# C-only — Watcom C++ did not arrive until 10.0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    err "usage: $0 DEST_DIR [ARCHIVE_DIR]"
fi

DEST="$1"
ARCHIVE_DIR="${2:-/archives/watcom-9.0/nt-alpha}"

[ -f "$ARCHIVE_DIR/WC90NTA1.ZIP" ] || err "missing WC90NTA*.ZIP in: $ARCHIVE_DIR"
[ -f "$WATCOM_TOOLS/wpack.exe" ]   || err "missing $WATCOM_TOOLS/wpack.exe"

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

log "extract-9.0-nta: destination = $DEST"
log "extract-9.0-nta: archive dir = $ARCHIVE_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STAGE="$WORK/stage"
mkdir -p "$STAGE"
for i in 1 2 3 4; do
    zip="$ARCHIVE_DIR/WC90NTA$i.ZIP"
    [ -f "$zip" ] || err "missing distribution zip: $zip"
    log "  staging WC90NTA$i.ZIP"
    tmp="$WORK/z$i"
    mkdir -p "$tmp"
    unzip -joq "$zip" -d "$tmp"
    for f in "$tmp"/*; do
        [ -f "$f" ] || continue
        cp "$f" "$STAGE/$(basename "$f" | tr '[:upper:]' '[:lower:]')"
    done
done

[ -f "$STAGE/install.scr" ] || err "INSTALL.SCR not found after staging"
cp "$STAGE/install.scr" "$WORK/install.scr"

log "run: 9.0 NT-Alpha installer (--yes-all, full component set)"
python3 "$SCRIPT_DIR/lib/install_scr.py" \
    --script "$WORK/install.scr" \
    --source "$STAGE" \
    --dest   "$DEST" \
    --watcom-tools "$WATCOM_TOOLS" \
    --yes-all

log "extract-9.0-nta: done"
log "  total size: $(du -sh "$DEST" | cut -f1)"
log "  top-level : $(ls "$DEST" | tr '\n' ' ')"
