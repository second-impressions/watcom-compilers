#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# extract-10.0a.sh — extract the Watcom C/C++ 10.0a tree from the retail
# CD-ROM ISO into DEST_DIR.
#
# Usage:
#     extract-10.0a.sh DEST_DIR [ISO]
#
# Arguments:
#     DEST_DIR  Target directory for the Watcom tree (created if absent).
#     ISO       Path to WATCOM_C10A.ISO.
#               Defaults to /archives/watcom-10.0/WATCOM_C10A.ISO
#
# The ISO contains a pre-extracted Watcom 10.0a install tree under
# WATCOM/ (uppercase). bsdtar extracts that subtree and a --strip-components
# pass removes the leading WATCOM/ prefix so the result lands directly in
# DEST_DIR. Paths are lowercased via a Python rename pass after extraction
# to be consistent with the 9.5 tree layout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    err "usage: $0 DEST_DIR [ISO]"
fi

DEST="$1"
ISO="${2:-/archives/watcom-10.0/WATCOM_C10A.ISO}"

[ -f "$ISO" ] || err "ISO not found: $ISO"

log "extract-10.0: dest = $DEST"
log "extract-10.0: source = $ISO"

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

# Extract the WATCOM/ subtree, stripping the leading path component so
# files land directly in $DEST.
log "  extracting WATCOM/ from ISO"
bsdtar -xf "$ISO" \
    --include 'WATCOM/*' \
    --strip-components 1 \
    -C "$DEST" 2>/dev/null

# Lowercase everything: directory names first (deepest first so parent renames
# don't break children), then file names.
log "  lowercasing paths"
python3 - "$DEST" <<'PYEOF'
import os, sys

root = sys.argv[1]

# Collect all entries sorted deepest-first so we rename leaves before parents.
all_entries = []
for dirpath, dirnames, filenames in os.walk(root, topdown=False):
    for name in filenames:
        all_entries.append(os.path.join(dirpath, name))
    for name in dirnames:
        all_entries.append(os.path.join(dirpath, name))

for path in all_entries:
    parent, name = os.path.split(path)
    lower = name.lower()
    if name != lower:
        os.rename(path, os.path.join(parent, lower))
PYEOF

[ -f "$DEST/binb/wcc386.exe" ] || err "extraction failed: binb/wcc386.exe missing"
[ -f "$DEST/binb/wlib.exe"   ] || err "extraction failed: binb/wlib.exe missing"

file_count=$(find "$DEST" -type f | wc -l)
log "  $file_count files extracted"
log "extract-10.0: done"
