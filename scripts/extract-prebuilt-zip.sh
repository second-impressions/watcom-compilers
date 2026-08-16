#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# extract-prebuilt-zip.sh — extract a Watcom C/C++ pre-extracted install tree
# from a ZIP archive into DEST_DIR.
#
# Usage:
#     extract-prebuilt-zip.sh DEST_DIR ZIP [STRIP_PREFIX]
#
# Arguments:
#     DEST_DIR       Target directory (created if absent).
#     ZIP            Path to the ZIP archive.
#     STRIP_PREFIX   If set, only extract entries under this prefix and strip
#                    it from the paths (e.g. "WATCOM/" for ISOs that nest the
#                    tree). Optional; if absent, all entries are extracted.
#
# Used for the pre-extracted Watcom distributions from the Discmaster
# collection (10.6a, 11.0, the 11.0c update) and WinWorld (10.5 is an ISO,
# handled by extract-10.5.sh). These ZIPs contain a ready-to-use install
# tree — no WPK unpacking, no INSTALL.SCR interpretation, no patching needed.
#
# All paths are lowercased on extraction for consistency with the 9.5 and
# 10.0 trees.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    err "usage: $0 DEST_DIR ZIP [STRIP_PREFIX]"
fi

DEST="$1"
ZIP="$2"
STRIP_PREFIX="${3:-}"

[ -f "$ZIP" ] || err "ZIP not found: $ZIP"

log "extract-prebuilt-zip: dest   = $DEST"
log "extract-prebuilt-zip: source = $(basename "$ZIP")"
[ -n "$STRIP_PREFIX" ] && log "extract-prebuilt-zip: prefix = $STRIP_PREFIX"

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

if [ -n "$STRIP_PREFIX" ]; then
    # Extract only entries under the prefix, stripping it so files land
    # directly in $DEST. unzip -j flattens dirs so we use Python instead.
    python3 - "$ZIP" "$DEST" "$STRIP_PREFIX" <<'PYEOF'
import sys, zipfile, os

zip_path, dest, prefix = sys.argv[1], sys.argv[2], sys.argv[3].rstrip('/')
prefix_lower = prefix.lower() + '/'

with zipfile.ZipFile(zip_path) as z:
    for info in z.infolist():
        name_lower = info.filename.lower().rstrip('/')
        if not name_lower.startswith(prefix_lower):
            continue
        rel = info.filename[len(prefix)+1:]  # strip prefix + separator
        if not rel:
            continue
        rel_lower = rel.lower()
        out = os.path.join(dest, rel_lower)
        if info.filename.endswith('/'):
            os.makedirs(out, exist_ok=True)
        else:
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with z.open(info) as src, open(out, 'wb') as dst:
                dst.write(src.read())
PYEOF
else
    # Extract everything, lowercasing paths.
    python3 - "$ZIP" "$DEST" <<'PYEOF'
import sys, zipfile, os

zip_path, dest = sys.argv[1], sys.argv[2]

with zipfile.ZipFile(zip_path) as z:
    for info in z.infolist():
        rel_lower = info.filename.lower()
        out = os.path.join(dest, rel_lower)
        if info.filename.endswith('/'):
            os.makedirs(out, exist_ok=True)
        else:
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with z.open(info) as src, open(out, 'wb') as dst:
                dst.write(src.read())
PYEOF
fi

file_count=$(find "$DEST" -type f | wc -l)
log "  $file_count files extracted"
log "extract-prebuilt-zip: done"
