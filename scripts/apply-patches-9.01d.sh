#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# apply-patches-9.01d.sh — apply a Watcom C/386 9.01 cumulative patch level
# to an installed Watcom 9.01d tree by running the original APPLY*.BAT files
# under dosemu2.
#
# Usage:
#     apply-patches-9.01d.sh DEST_DIR PATCH_LETTER [PATCHES_ZIP_DIR]
#
# Arguments:
#     DEST_DIR         An installed Watcom C/386 tree (from extract-9.01d.sh
#                      or from an already-patched earlier level).
#     PATCH_LETTER     a–e.  Levels a, b and c apply on top of the base
#                      9.01 tree (containers/watcom-9.01/, from the May
#                      1992 floppies) and chain in order.  Level e applies
#                      on top of the pre-extracted 9.01d tree.  Level d is
#                      accepted but unused: the 9.01d tree we ship is
#                      already at that level.
#     PATCHES_ZIP_DIR  Directory holding c386_*.zip.
#                      Defaults to /archives/watcom-9.01d/patches.
#
# Patch ZIP structure
# ===================
# Watcom C/386 patch ZIPs have a two-level layout that differs from the
# 9.5 and 10.0 series:
#
#   c386_e.zip
#   ├── UPLOAD.DOC        (BBS metadata, not needed)
#   └── C386_E.ZIP        (inner ZIP — the actual patch archive)
#       ├── APPLYE.BAT    (driver: bpatch / wlib / copy operations)
#       ├── README.E      (change log)
#       └── *.e           (Watcom binary patch files, OMF lib members, etc.)
#
# This script unwraps both levels and then drives the inner APPLY*.BAT.
#
# Self-reference workaround
# =========================
# APPLYD.BAT patches binb\bpatch.exe (same EBUSY problem as 9.5).
# APPLYE.BAT does NOT patch bpatch.exe (no bpatch*.e file in c386_e).
# The workaround is applied unconditionally for robustness: we drop
# `_bpx_.exe` (a toolchain bpatch copy) into the patches directory and
# rewrite every `bpatch %2 %3` occurrence in the BAT to `_bpx_ %2 %3`.
# When APPLYE runs, it sets PATH = %1\bin;%1\binb before each bpatch
# call. Our `_bpx_.exe` sits in the patches directory (the DOS CWD), so
# DOS resolves it from there, not from PATH — no conflict.
#
# Library operations
# ==================
# APPLYE.BAT makes both bpatch (binary patch) and wlib (OMF library add)
# calls. The wlib calls use the form:
#
#   set path=%1\lib386\os2;%1\binb
#   wlib %1\lib386\os2\clib3r.lib -+3cr2l.e
#
# wlib here is resolved from %1\binb (the tree's own binb\wlib.exe). This
# works correctly once the scratch layout places `watcom` next to `patches`
# under the same DOS drive root.
#
# Layout (same as 9.5 / 10.0):
#   $SCRATCH/watcom  → symlink to DEST_DIR
#   $SCRATCH/patches → extracted inner patch archive contents
#   $SCRATCH/run.bat → cd \patches && call apply<x>.bat ..\watcom -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    err "usage: $0 DEST_DIR PATCH_LETTER [PATCHES_ZIP_DIR]"
fi

DEST="$1"
LEVEL="$2"
PATCHES_ZIP_DIR="${3:-/archives/watcom-9.01d/patches}"

[ -d "$DEST" ]               || err "dest dir does not exist: $DEST"
[ -f "$DEST/binb/wlib.exe" ] || err "dest does not look like an installed Watcom C/386 tree: $DEST"
[ -d "$PATCHES_ZIP_DIR" ]    || err "patches dir does not exist: $PATCHES_ZIP_DIR"

case "$LEVEL" in
    a|b|c|d|e) : ;;
    *) err "invalid patch letter: $LEVEL (expected a–e)" ;;
esac
UPPER=$(printf '%s' "$LEVEL" | tr '[:lower:]' '[:upper:]')

DEST="$(cd "$DEST" && pwd)"

outer_zip="$PATCHES_ZIP_DIR/c386_${LEVEL}.zip"
[ -f "$outer_zip" ] || err "missing outer patch zip: $outer_zip"

log "apply-patches-9.01d: dest   = $DEST"
log "apply-patches-9.01d: letter = $LEVEL"

# -----------------------------------------------------------------------------
# Build scratch layout.
# -----------------------------------------------------------------------------
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

ln -s "$DEST" "$SCRATCH/watcom"
mkdir -p "$SCRATCH/patches"

# -----------------------------------------------------------------------------
# Unwrap the patch ZIP.  Two layouts exist in this series:
#
#   a, b, c : single level — patch files + APPLY<X>.BAT at the top.
#   d, e    : two levels    — outer holds UPLOAD.DOC + C386_<X>.ZIP,
#                             and the inner ZIP holds the patch files.
#
# Unwrap the outer archive first, then descend only if an inner ZIP is
# actually present.
# -----------------------------------------------------------------------------
outer_tmp="$(mktemp -d)"
log "  unzip outer: $(basename "$outer_zip")"
unzip -q -j "$outer_zip" -d "$outer_tmp"

inner_zip="$outer_tmp/C386_${UPPER}.ZIP"
if [ -f "$inner_zip" ]; then
    log "  unzip inner: C386_${UPPER}.ZIP"
    unzip -o -q -j "$inner_zip" -d "$SCRATCH/patches"
else
    log "  single-level archive; using outer contents directly"
    cp -a "$outer_tmp/." "$SCRATCH/patches/"
fi

bat="$SCRATCH/patches/APPLY${UPPER}.BAT"
[ -f "$bat" ] || err "missing $bat after unzip of inner archive"

# -----------------------------------------------------------------------------
# Self-reference workaround: replace `bpatch %2 %3` with `_bpx_ %2 %3`
# and drop a toolchain-bpatch copy as _bpx_.exe.
# Safe even when bpatch itself is not a patch target (level e).
# -----------------------------------------------------------------------------
cp "$WATCOM_TOOLS/bpatch.exe" "$SCRATCH/patches/_bpx_.exe"
sed -i 's|bpatch %2 %3|_bpx_ %2 %3|gI' "$bat"

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

log "apply-patches-9.01d: done (letter $LEVEL)"
