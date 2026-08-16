#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# apply-patches-10.0.sh — apply a Watcom 10.0 cumulative patch level to
# an installed Watcom 10.0 tree by running the original APPLY*.BAT files
# under dosemu2.
#
# Usage:
#     apply-patches-10.0.sh DEST_DIR PATCH_LETTER [PATCHES_DIR]
#
# Arguments:
#     DEST_DIR      An installed Watcom 10.0 tree (from extract-10.0a.sh
#                   or from an already-patched earlier level).
#     PATCH_LETTER  One of: a, b — applies exactly that letter.
#                   Run letters in order: a then b.
#     PATCHES_DIR   Directory holding c_a.zip and c_b.zip.
#                   Defaults to /archives/watcom-10.0/patches.
#
# How it works
# ============
# Watcom 10.0 patch ZIPs each contain:
#
#   * APPLY<LETTER>.BAT — the driver script, identical in structure to
#     the 9.5 series APPLY*.BAT files: takes %1=<watcom-dir>, reads patch
#     files from CWD, calls `bpatch -b %2 %3 ptch<N>.<letter>` for each
#     target file.
#   * ptch<N>.<letter> — Watcom binary patch files, one per patched file.
#
# Unlike the 9.5 series there is no bpatch self-patching problem: APPLYA
# does not patch binb/bpatch.exe. The APPLY*.BAT sets PATH to include
# %1\binb so bpatch resolves to the tree's own binb/bpatch.exe — the
# 10.0 GA tree ships its own bpatch (56 739 bytes, 1994-05-31).
#
# We therefore run the BAT verbatim without any modifications.
#
# Layout (same as 9.5):
#   $SCRATCH/watcom  → symlink to DEST_DIR
#   $SCRATCH/patches → unzipped patch contents
#   $SCRATCH/run.bat → cd \patches && call apply<x>.bat ..\watcom -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    err "usage: $0 DEST_DIR PATCH_LETTER [PATCHES_DIR]"
fi

DEST="$1"
LEVEL="$2"
PATCHES_DIR="${3:-/archives/watcom-10.0/patches}"

[ -d "$DEST" ]                || err "dest dir does not exist: $DEST"
[ -f "$DEST/binb/wlib.exe" ]  || err "dest is not an installed Watcom 10.0 tree: $DEST"
[ -d "$PATCHES_DIR" ]         || err "patches dir does not exist: $PATCHES_DIR"

case "$LEVEL" in
    a|b) : ;;
    *) err "invalid patch letter: $LEVEL (expected a or b)" ;;
esac
UPPER=$(printf '%s' "$LEVEL" | tr '[:lower:]' '[:upper:]')

DEST="$(cd "$DEST" && pwd)"

zip="$PATCHES_DIR/c_${LEVEL}.zip"
[ -f "$zip" ] || err "missing patch zip: $zip"

log "apply-patches-10.0: dest = $DEST"
log "apply-patches-10.0: letter = $LEVEL"

# -----------------------------------------------------------------------------
# Build the scratch layout.
# -----------------------------------------------------------------------------
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

ln -s "$DEST" "$SCRATCH/watcom"
mkdir -p "$SCRATCH/patches"

# -----------------------------------------------------------------------------
# Unzip the patch ZIP into the patches directory.
# -----------------------------------------------------------------------------
log "  unzip $(basename "$zip")"
unzip -o -q -j "$zip" -d "$SCRATCH/patches"

bat="$SCRATCH/patches/APPLY${UPPER}.BAT"
[ -f "$bat" ] || err "missing $bat after unzip"

# -----------------------------------------------------------------------------
# Run APPLY<LETTER>.BAT under dosemu2.
# -----------------------------------------------------------------------------
cat > "$SCRATCH/run.bat" <<EOF
@echo off
cd \\patches
call apply${UPPER}.bat ..\\watcom -p
EOF

log "run APPLY${UPPER}.BAT"
# Snapshot existing .bak files so the cleanup below can tell ours apart
# from anything the distribution shipped.
BAK_BEFORE="$(mktemp)"
find "$DEST" -iname '*.bak' -type f | sort > "$BAK_BEFORE"

log_file="$(mktemp)"
if ! dosemu -dumb -quiet -K "$SCRATCH" -E "run.bat" > "$log_file" 2>&1; then
    cat "$log_file" >&2
    rm -f "$log_file"
    err "dosemu2 exited non-zero while running APPLY${UPPER}.BAT"
fi

if grep -qE '^Error' "$log_file"; then
    log "APPLY${UPPER}.BAT produced errors:"
    grep -E '^Error' "$log_file" >&2
    rm -f "$log_file"
    err "patch application failed"
fi

patched=$(grep -c '^Patching' "$log_file" || true)
created=$(grep -c '^Creating' "$log_file" || true)
log "  APPLY${UPPER}.BAT: $patched patched, $created created"
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
log "apply-patches-10.0: done (letter $LEVEL)"
