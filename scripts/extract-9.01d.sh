#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# extract-9.01d.sh — produce an installed Watcom C/386 9.01d tree by running
# the original 1992 INSTALL.SCR against the floppy-style ZIP contents.
#
# Usage:
#     extract-9.01d.sh DEST_DIR [ZIP_FILE]
#
# Arguments:
#     DEST_DIR  Directory to install into.
#     ZIP_FILE  Path to "Watcom - C++ 9.01d.zip". Defaults to
#               /archives/watcom-9.01d/Watcom - C++ 9.01d.zip
#
# The 9.01d distribution is structured as eight "floppy" directories
# (01/ … 08/) inside a single ZIP. Each top-level disk directory has an
# INSTALL.SCR; disk 01's is the master installer. The interpreter at
# scripts/lib/install_scr.py handles the same DSL as the 9.5
# script (echo/ask/set/if/ifnot/goto/mkdir/unpack/file/enter + @-prefixed
# variants).
#
# Every `ask` prompt is answered 'y' (`--yes-all`), so the installer
# lays down the full distribution: DOS + OS/2 host binaries, DOS / OS/2 /
# Windows 3.x targets, SDK examples, on-line help, Profiler, Debugger
# NLM support, and PenPoint. The OS/2 library-building spawn steps
# (`wlib`, `wimp`) are handled by the general spawn dispatch in
# scripts/lib/install_scr.py.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    err "usage: $0 DEST_DIR [ZIP_FILE]"
fi

DEST="$1"
ZIP_FILE="${2:-/archives/watcom-9.01d/Watcom - C++ 9.01d.zip}"

[ -f "$ZIP_FILE" ] || err "zip not found: $ZIP_FILE"
[ -f "$WATCOM_TOOLS/wpack.exe" ] || err "missing $WATCOM_TOOLS/wpack.exe"

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

log "extract-9.01d: destination = $DEST"
log "extract-9.01d: zip         = $ZIP_FILE"

# -----------------------------------------------------------------------------
# Stage: unzip, flatten the eight disk directories into one, lower-case
# every filename. A prior check (outside this script) confirmed that the
# eight disks have no filename collisions, so flattening is lossless.
# -----------------------------------------------------------------------------
STAGING_ROOT="$(mktemp -d)"
trap 'rm -rf "$STAGING_ROOT"' EXIT

UNZIP_DIR="$STAGING_ROOT/zip"
STAGE="$STAGING_ROOT/stage"
mkdir -p "$UNZIP_DIR" "$STAGE"

log "stage: unzipping archive"
unzip -q -d "$UNZIP_DIR" "$ZIP_FILE"

log "stage: flattening 8 disk directories"
# Every disk ships its own INSTALL.SCR / INSTALL.EXE (the Watcom original
# installer was disk-at-a-time). When flattened, these collide on disk:
# disks 01, 06, 08 each have a file that lower-cases to `install.scr`.
# We want disk 01's (the master), so skip install.* from disks 02-08.
SCR="$STAGING_ROOT/install-01.scr"
cp "$UNZIP_DIR/01/INSTALL.SCR" "$SCR"
for disk in "$UNZIP_DIR"/??; do
    [ -d "$disk" ] || continue
    for f in "$disk"/*; do
        [ -f "$f" ] || continue
        base=$(basename "$f" | tr '[:upper:]' '[:lower:]')
        case "$base" in
            install.scr|install.exe) continue ;;
        esac
        cp "$f" "$STAGE/$base"
    done
done

# -----------------------------------------------------------------------------
# Full install: every `ask` prompt answered 'y'. The installer builds
# the OS/2 libraries by spawning `wlib` on .lbc response files, and
# the OS/2 import library via `wimp`; both are handled by
# scripts/lib/install_scr.py's general spawn dispatch path.
# -----------------------------------------------------------------------------
log "run: master installer (01/INSTALL.SCR)"
python3 "$SCRIPT_DIR/lib/install_scr.py" \
    --script "$SCR" \
    --source "$STAGE" \
    --dest   "$DEST" \
    --watcom-tools "$WATCOM_TOOLS" \
    --yes-all

log "extract-9.01d: done"
log "  total size: $(du -sh "$DEST" | cut -f1)"
log "  top-level : $(ls "$DEST" | tr '\n' ' ')"
