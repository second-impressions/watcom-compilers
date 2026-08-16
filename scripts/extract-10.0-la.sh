#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# extract-10.0-la.sh — produce an installed Watcom C/C++ 10.0 LA tree
# by running the SETUP.INF interpreter over the contents of
# watcom10la.iso.
#
# Usage:
#     extract-10.0-la.sh DEST_DIR [ISO]
#
# Arguments:
#     DEST_DIR  Directory to install into.
#     ISO       Path to watcom10la.iso.  Defaults to
#               /archives/watcom-10.0-la/watcom10la.iso
#
# Unlike the 9.5 / 9.01d releases (INSTALL.SCR DSL under the dosemu2
# installer) and the 10.0a retail CD (pre-extracted WATCOM/ tree), the
# LA pre-release uses a Windows 3.x/OS/2/NT SETUP.EXE driven by a
# SETUP.INF INI file.  We interpret SETUP.INF directly from Python.
#
# The disc content is a flat collection of pack files (pack0001–pack0757
# plus named packs like w32run, dipcv1, etc.) all in the ISO root; there
# are no subdirectories on the ISO itself.  SETUP.INF maps each pack
# filename → destination path + filename.
#
# See scripts/lib/setup_inf_ini.py for the full format spec.
# (10.0 LA uses a different SETUP.INF format than 10.5/11.x, which have
# their own interpreter in scripts/lib/setup_inf_manifest.py.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    err "usage: $0 DEST_DIR [ISO]"
fi

DEST="$1"
ISO="${2:-/archives/watcom-10.0-la/watcom10la.iso}"

[ -f "$ISO" ]                      || err "ISO not found: $ISO"
[ -f "$WATCOM_TOOLS/wpack.exe" ]   || err "missing $WATCOM_TOOLS/wpack.exe"

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

log "extract-10.0-la: dest = $DEST"
log "extract-10.0-la: iso  = $ISO"

# -----------------------------------------------------------------------------
# Extract the ISO to a flat staging directory.
# -----------------------------------------------------------------------------
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

log "stage: extracting ISO"
bsdtar -xf "$ISO" -C "$STAGING"

# bsdtar may preserve the `;1` version suffix on ISO9660 filenames.  Drop it.
python3 - "$STAGING" <<'PYEOF'
import os, sys
root = sys.argv[1]
for name in os.listdir(root):
    if ";" in name:
        src = os.path.join(root, name)
        dst = os.path.join(root, name.split(";", 1)[0])
        if os.path.exists(dst):
            os.remove(src)
        else:
            os.rename(src, dst)
PYEOF

[ -f "$STAGING/SETUP.INF" ] || err "SETUP.INF not found after ISO extract"

# -----------------------------------------------------------------------------
# Run the SETUP.INF interpreter.
# -----------------------------------------------------------------------------
log "run: SETUP.INF interpreter (all-yes)"
python3 "$SCRIPT_DIR/lib/setup_inf_ini.py" \
    --inf    "$STAGING/SETUP.INF" \
    --source "$STAGING" \
    --dest   "$DEST" \
    --watcom-tools "$WATCOM_TOOLS" \
    --selection all-yes

# -----------------------------------------------------------------------------
# Lowercase any directories/files that slipped through (belt-and-braces).
# -----------------------------------------------------------------------------
python3 - "$DEST" <<'PYEOF'
import os, sys
root = sys.argv[1]
for dirpath, dirnames, filenames in os.walk(root, topdown=False):
    for name in filenames:
        if name != name.lower():
            os.rename(os.path.join(dirpath, name),
                      os.path.join(dirpath, name.lower()))
    for name in dirnames:
        if name != name.lower():
            os.rename(os.path.join(dirpath, name),
                      os.path.join(dirpath, name.lower()))
PYEOF

# -----------------------------------------------------------------------------
# SETUP.INF places runner binaries (w32run / x32run / d4grun / tntrun /
# wasm / vi / wrc) and a few profile files directly under the install
# root (`[Dirs]` ID 1 = `.`).  On retail 10.0a these same tools live
# under `bin/` and that's where wcc386.exe and the shim's PATH expect
# them.  The LA's DOS-bound wcc386 fails at startup with "32-bit DOS
# programs require the BIN directory to be in your path before BINNT"
# when it can't find `w32run.exe` next to itself.  Move them.
for f in "$DEST"/*.exe "$DEST"/*.prf; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    [ -f "$DEST/bin/$name" ] && rm "$DEST/bin/$name"
    mv "$f" "$DEST/bin/$name"
done

# -----------------------------------------------------------------------------
# Sanity checks.
# -----------------------------------------------------------------------------
# Sanity checks: the key DOS-host tools must exist somewhere under the
# install tree.  SETUP.INF places the DOS-host wcc386 in `bin/`,
# wlink in `binb/`, and wlib in `binp/` (OS/2 host) — only one copy of
# wlib is shipped on the LA disc, and it's the OS/2-built one.
for bin in wcc386.exe wlink.exe wlib.exe; do
    if ! find "$DEST" -iname "$bin" -type f -print -quit | grep -q . ; then
        err "extraction incomplete: $bin not found anywhere under $DEST"
    fi
done

log "extract-10.0-la: done"
log "  total size: $(du -sh "$DEST" | cut -f1)"
log "  top-level : $(ls "$DEST" | tr '\n' ' ')"
