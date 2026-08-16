#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# apply-patches-10.5.sh — raise an installed Watcom C/C++ 10.5 GA tree to
# 10.5a by running the original APPLYA.BAT from c105_a.zip under dosemu2.
#
# Usage:
#     apply-patches-10.5.sh DEST_DIR [PATCHES_DIR]
#
# Arguments:
#     DEST_DIR      An installed Watcom 10.5 GA tree (from extract-10.5.sh).
#     PATCHES_DIR   Directory holding c105_a.zip.
#                   Defaults to /archives/watcom-10.5/patches.
#
# Background
# ==========
# 10.5a shipped only as a maintenance patch (c105_a.zip), never as
# standalone media.  The patch was recovered from
# the Watcom Products Infobase Volume 1 (1996) CD.  It is structured
# exactly like the 10.0 c_a/c_b kits:
#
#   * APPLYA.BAT       — driver: %1=<watcom-dir>; sets PATH to %1\binw so
#                        bpatch resolves to the tree's own binw/bpatch.exe,
#                        then `bpatch -b %2 %3 ptch<N>.a` for each target.
#   * ptch<N>.a        — 337 Watcom binary patch files (one per target).
#
# The 10.5 tree is binw/-hosted (unlike the 10.0 binb/-hosted tree), and
# the 10.5 GA tree ships its own binw/bpatch.exe, so APPLYA.BAT runs
# verbatim with no modification and no bpatch self-patch problem.
#
# Layout (same scratch model as apply-patches-10.0.sh):
#   $SCRATCH/watcom  → symlink to DEST_DIR
#   $SCRATCH/patches → unzipped patch contents
#   $SCRATCH/run.bat → cd \patches && call applya.bat ..\watcom -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    err "usage: $0 DEST_DIR [PATCHES_DIR]"
fi

DEST="$1"
PATCHES_DIR="${2:-/archives/watcom-10.5/patches}"

[ -d "$DEST" ]               || err "dest dir does not exist: $DEST"
[ -f "$DEST/binw/wlib.exe" ] || err "dest is not an installed Watcom 10.5 tree: $DEST"
[ -d "$PATCHES_DIR" ]        || err "patches dir does not exist: $PATCHES_DIR"

DEST="$(cd "$DEST" && pwd)"

zip="$PATCHES_DIR/c105_a.zip"
[ -f "$zip" ] || err "missing patch zip: $zip"

log "apply-patches-10.5: dest = $DEST"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

ln -s "$DEST" "$SCRATCH/watcom"
mkdir -p "$SCRATCH/patches"

log "  unzip $(basename "$zip")"
unzip -o -q -j "$zip" -d "$SCRATCH/patches"

bat="$SCRATCH/patches/APPLYA.BAT"
[ -f "$bat" ] || err "missing $bat after unzip"

cat > "$SCRATCH/run.bat" <<EOF
@echo off
cd \\patches
call applya.bat ..\\watcom -p
EOF

log "run APPLYA.BAT"
# Snapshot existing .bak files so the cleanup below can tell ours apart
# from anything the distribution shipped.
BAK_BEFORE="$(mktemp)"
find "$DEST" -iname '*.bak' -type f | sort > "$BAK_BEFORE"

log_file="$(mktemp)"
if ! dosemu -dumb -quiet -K "$SCRATCH" -E "run.bat" > "$log_file" 2>&1; then
    cat "$log_file" >&2
    rm -f "$log_file"
    err "dosemu2 exited non-zero while running APPLYA.BAT"
fi

if grep -qE '^Error' "$log_file"; then
    log "APPLYA.BAT produced errors:"
    grep -E '^Error' "$log_file" >&2
    rm -f "$log_file"
    err "patch application failed"
fi

patched=$(grep -c '^Patching' "$log_file" || true)
created=$(grep -c '^Creating' "$log_file" || true)
log "  APPLYA.BAT: $patched patched, $created created"
rm -f "$log_file"


# -----------------------------------------------------------------------------
# Drop the .bak files bpatch leaves behind.
#
# bpatch renames each file it touches to .bak before writing the patched
# version, so a patched tree carries a full copy of the previous patch level.
# That level ships as its own image, making the backups pure duplication (they
# accounted for 271 files in the 9.5c tree alone).  Only files this run created
# are removed; anything already present beforehand is left alone.
# -----------------------------------------------------------------------------
BAK_AFTER="$(mktemp)"
BAK_NEW="$(mktemp)"
find "$DEST" -iname '*.bak' -type f | sort > "$BAK_AFTER"
comm -13 "$BAK_BEFORE" "$BAK_AFTER" > "$BAK_NEW"
removed=0
while IFS= read -r bak; do
    [ -n "$bak" ] || continue
    rm -f "$bak"
    removed=$((removed + 1))
done < "$BAK_NEW"
rm -f "$BAK_BEFORE" "$BAK_AFTER" "$BAK_NEW"
log "  removed $removed bpatch .bak backup(s)"
log "apply-patches-10.5: done (10.5 -> 10.5a)"
