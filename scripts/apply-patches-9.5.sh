#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# apply-patches-9.5.sh — apply a Watcom 9.5 cumulative patch level to
# an installed Watcom 9.5 tree by running the original `APPLY*.BAT`
# files under dosemu2 against the installed tree.
#
# Usage:
#     apply-patches-9.5.sh DEST_DIR PATCH_LETTER [PATCHES_ZIP_DIR]
#
# Arguments:
#     DEST_DIR         An installed Watcom 9.5 tree (from extract-9.5.sh
#                      or from an already-patched earlier level).
#     PATCH_LETTER     One of: a, b, c — applies exactly that letter
#                      (APPLYA.BAT, APPLYB.BAT, or APPLYC.BAT).
#                      The caller is responsible for running the
#                      letters in order. This non-cumulative design
#                      lets each container build stage cache cleanly:
#                      9.5a is 9.5+a, 9.5b is 9.5a+b, etc.
#     PATCHES_ZIP_DIR  Directory holding c16_*.zip and c32_*.zip.
#                      Defaults to /archives/watcom-9.5/patches.
#
# How it works
# ============
# Watcom shipped its 9.5 cumulative patches as paired 16-bit/32-bit
# ZIP files, each containing:
#
#   * The APPLY<LETTER>.BAT driver script.
#     c16_X.zip and c32_X.zip ship IDENTICAL APPLY*.BAT files because
#     one driver handles both bit widths; the `if exist %1\...` guards
#     simply skip targets that aren't present on the user's system.
#   * Hundreds of small `.A` / `.B` / `.C` files:
#       - Watcom binary patches (header "WATCOM binary patch file format")
#       - OMF object libraries (for `wlib -+` in-place library updates)
#       - Raw replacement files (for `copy` add-a-file operations)
#
# Rather than reimplement the APPLY*.BAT DSL (bpatch / copy / wlib /
# del operations, `@VAR` env-var expansion, cumulative `set path=…`
# tricks, …), this script runs the original, unmodified BAT files
# under dosemu2 with a single targeted edit.
#
# The only thing that needs patching in the BAT file is the self-
# reference problem: APPLYA.BAT's first action is to binary-patch
# %1\binb\bpatch.exe, which means the running bpatch.exe is asked to
# rename itself to .bak. On a real 1993 DOS box this worked because
# DOS has no concept of file locking for running executables. Under
# dosemu2 on Linux it fails with EBUSY ("Permission denied"). Fix:
# use a clash-free name for the bpatch tool:
#
#   1. Drop `_bpx_.exe` (a copy of the toolchain's bpatch.exe) into
#      the patches directory.
#   2. `sed` every `bpatch %2 %3` in the BAT into `_bpx_ %2 %3`.
#
# DOS then runs `_bpx_.exe` from the CWD (the patches dir) when the
# BAT invokes bpatch, and the target `%1\binb\bpatch.exe` is a
# separate file that can be renamed freely.
#
# Everything else in the BAT runs verbatim: wlib uses the target
# tree's own binb\wlib.exe, copy uses DOS's internal copy, del uses
# DOS's internal del. No reimplementation needed.
#
# Layout
# ------
# dosemu2 maps a single unix directory as the current DOS drive. We
# create a scratch parent that contains:
#
#   $SCRATCH/watcom  →  symlink to DEST_DIR (the install tree)
#   $SCRATCH/patches →  unzipped + sedded patches, plus `_bpx_.exe`
#
# and then invoke `dosemu -K $SCRATCH` so both appear as subdirectories
# of the same DOS drive. The BAT is invoked as
# `applyX.bat F:\watcom -p` where F: is whatever drive letter dosemu2
# assigned.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    err "usage: $0 DEST_DIR PATCH_LEVEL [PATCHES_ZIP_DIR]"
fi

DEST="$1"
LEVEL="$2"
PATCHES_ZIP_DIR="${3:-/archives/watcom-9.5/patches}"

[ -d "$DEST" ] || err "dest dir does not exist: $DEST"
[ -f "$DEST/binb/wlib.exe" ] || err "dest is not an installed Watcom tree: $DEST"
[ -d "$PATCHES_ZIP_DIR" ] || err "patches dir does not exist: $PATCHES_ZIP_DIR"
[ -f "$WATCOM_TOOLS/bpatch.exe" ] || err "missing $WATCOM_TOOLS/bpatch.exe"

case "$LEVEL" in
    a|b|c) : ;;
    *) err "invalid patch letter: $LEVEL (expected a, b, or c)" ;;
esac
UPPER=$(printf '%s' "$LEVEL" | tr '[:lower:]' '[:upper:]')

DEST="$(cd "$DEST" && pwd)"

log "apply-patches-9.5: dest = $DEST"
log "apply-patches-9.5: letter = $LEVEL"

# -----------------------------------------------------------------------------
# Build the scratch layout.
# -----------------------------------------------------------------------------
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

ln -s "$DEST" "$SCRATCH/watcom"
mkdir -p "$SCRATCH/patches"

# -----------------------------------------------------------------------------
# Unzip the letter's 16-bit and 32-bit patch zip into the scratch
# patches directory.
# -----------------------------------------------------------------------------
for bits in 16 32; do
    zip="$PATCHES_ZIP_DIR/c${bits}_${LEVEL}.zip"
    [ -f "$zip" ] || err "missing patch zip: $zip"
    log "  unzip $(basename "$zip")"
    unzip -o -q -j "$zip" -d "$SCRATCH/patches"
done

# -----------------------------------------------------------------------------
# Self-reference workaround for bpatch.exe patching itself.
# Drop a clash-free bpatch copy as `_bpx_.exe` and rewrite every
# `bpatch %2 %3` in every APPLY<LETTER>.BAT to `_bpx_ %2 %3`.
# -----------------------------------------------------------------------------
cp "$WATCOM_TOOLS/bpatch.exe" "$SCRATCH/patches/_bpx_.exe"

bat="$SCRATCH/patches/APPLY${UPPER}.BAT"
[ -f "$bat" ] || err "missing $bat after unzip"
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

# Error-scan the log: the BAT prints "Error!" lines from bpatch /
# wlib when something goes wrong but returns exit 0 regardless.
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

log "apply-patches-9.5: done (letter $LEVEL)"
