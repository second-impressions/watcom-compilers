#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# extract-10.6.sh — extract the Watcom C/C++ 10.6 install tree from the
# retail CD-ROM ISO into DEST_DIR.
#
# Usage:
#     extract-10.6.sh DEST_DIR [ISO]
#
# The 10.6 ISO root contains Win32 launcher stubs (not real compilers);
# the actual tools live under DISKIMGS/ packed in the Watcom WPK v1.1
# format. The file→pack mapping is in DISKIMGS/DISK01/SETUP.INF.
#
# Extraction flow
# ---------------
# 1. Extract DISKIMGS/ from the ISO with bsdtar.
# 2. Invoke scripts/lib/setup_inf_manifest.py to parse SETUP.INF and
#    extract every pack file via the pure-Python WPK decoder in
#    scripts/lib/wpack_decode.py. Split packs are concatenated first.
#
# No external unpack binary is needed — decoding is done entirely in
# Python by wpack_decode.unpack_archive().

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    err "usage: $0 DEST_DIR [ISO]"
fi

DEST="$1"
ISO="${2:-/archives/watcom-10.6/WATCOM_C106.iso}"

[ -f "$ISO" ] || err "ISO not found: $ISO"

log "extract-10.6: dest   = $DEST"
log "extract-10.6: source = $ISO"

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

log "  step 1/2: extracting DISKIMGS/ from ISO"
bsdtar -xf "$ISO" --include 'DISKIMGS/*' -C "$SCRATCH" 2>/dev/null

log "  step 2/2: running SETUP.INF interpreter (Python WPK decoder)"
python3 "$SCRIPT_DIR/lib/setup_inf_manifest.py" \
    unpack \
    "$SCRATCH/DISKIMGS/DISK01/SETUP.INF" \
    "$SCRATCH/DISKIMGS" \
    "$DEST"

[ -f "$DEST/binw/wcc386.exe" ] \
    || err "extraction failed: binw/wcc386.exe missing"

total_files=$(find "$DEST" -type f | wc -l)
log "  $total_files files extracted to $DEST"
log "extract-10.6: done"
