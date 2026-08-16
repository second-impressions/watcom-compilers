# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
# scripts/lib/common.sh
#
# Shared shell helpers, sourced by every extract/apply/install script in
# scripts/. Not executable on its own.
#
# Usage:
#     . "$(dirname "$0")/lib/common.sh"
#
# Provides:
#   log MSG...                 — print a timestamped INFO line
#   err MSG...                 — print an ERROR line and exit 1
#   require_env VAR...         — assert variables are set
#   dos_exec DIR CMD...        — run a DOS command line via dosemu2 with
#                                DIR mapped as the current DOS drive
#   wpack_unpack DEST WPK      — unpack a Watcom .wpk into DEST using
#                                wpack.exe from $WATCOM_TOOLS
#   bpatch_apply TARGET PATCH  — apply a Watcom binary patch to TARGET
#                                using bpatch.exe from $WATCOM_TOOLS

set -euo pipefail

# Default location of the two Watcom tools — the toolchain image sets
# WATCOM_TOOLS=/opt/watcom-tools, but allow an override for tests.
: "${WATCOM_TOOLS:=/opt/watcom-tools}"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
err() { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

require_env() {
    local var
    for var in "$@"; do
        if [ -z "${!var-}" ]; then
            err "required environment variable $var is not set"
        fi
    done
}

# -----------------------------------------------------------------------------
# dos_exec DIR "DOS COMMAND LINE"
#
# Runs a single DOS command line via dosemu2 with DIR mapped as the
# current drive. All files referenced by the command must already live
# under DIR.
#
# Flags:
#   -dumb    headless stdio mode (no curses/SDL)
#   -quiet   suppress startup banner
#   -K DIR   map DIR as the DOS current drive
#   -E CMD   run CMD inside DOS and exit
#
# dosemu2 emits a harmless warning about "running without root" which
# we silence on stderr.
# -----------------------------------------------------------------------------
dos_exec() {
    local dir="$1"; shift
    local cmd="$*"
    [ -d "$dir" ] || err "dos_exec: directory does not exist: $dir"
    (
        cd "$dir"
        dosemu -dumb -quiet -K "$PWD" -E "$cmd" 2> >(grep -v "running dosemu2 with root" >&2 || true)
    )
}

# -----------------------------------------------------------------------------
# wpack_unpack DEST WPK_FILE
#
# Unpacks a Watcom Install Archiver (.wpk) file into DEST. The .wpk file
# itself is left untouched. Any files produced by wpack are moved into
# DEST (creating it if necessary).
#
# Implementation: wpack.exe takes an archive name and unpacks into the
# current DOS drive. We stage the archive plus wpack.exe in a scratch
# directory, run wpack there, delete the tool and the source archive,
# and move everything else to DEST.
# -----------------------------------------------------------------------------
wpack_unpack() {
    local dest="$1" wpk="$2"
    [ -f "$wpk" ] || err "wpack_unpack: no such file: $wpk"
    [ -f "$WATCOM_TOOLS/wpack.exe" ] || err "wpack_unpack: missing $WATCOM_TOOLS/wpack.exe"
    mkdir -p "$dest"

    local work name
    work=$(mktemp -d)
    name=$(basename "$wpk")

    cp "$WATCOM_TOOLS/wpack.exe" "$work/wpack.exe"
    cp "$wpk" "$work/$name"

    dos_exec "$work" "wpack.exe $name" >/dev/null

    rm -f "$work/wpack.exe" "$work/$name"

    # Move whatever wpack produced into DEST. wpack's DOS output is
    # always upper-case; we lower-case it so the tree is consistently
    # cased on a case-sensitive filesystem, matching the layout Watcom's
    # own Linux ports use.
    local f base lower
    shopt -s nullglob
    for f in "$work"/*; do
        base=$(basename "$f")
        lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
        mv "$f" "$dest/$lower"
    done
    shopt -u nullglob

    rmdir "$work"
}

# -----------------------------------------------------------------------------
# bpatch_apply TARGET PATCH
#
# Applies a Watcom binary patch file (.A / .B / .DIF / ptchNN.a) to
# TARGET in place. The patch file is not modified.
#
# The Watcom patch file format embeds the original and new filenames,
# sizes, and CRCs, so bpatch verifies the target before patching. We
# invoke it with `-p -b -f` which matches every install.scr call:
#
#   -p  suppress the "patched OK" prompt
#   -b  the next argument is the patch file
#   -f  the next argument is the target file (force-specifies name)
#
# Implementation: copy the tool, target, and patch into a scratch dir,
# run bpatch with bare filenames, copy the patched target back.
# -----------------------------------------------------------------------------
bpatch_apply() {
    local target="$1" patch="$2"
    [ -f "$target" ] || err "bpatch_apply: no such target: $target"
    [ -f "$patch" ]  || err "bpatch_apply: no such patch: $patch"
    [ -f "$WATCOM_TOOLS/bpatch.exe" ] || err "bpatch_apply: missing $WATCOM_TOOLS/bpatch.exe"

    local work tname pname
    work=$(mktemp -d)
    tname=$(basename "$target")
    pname=$(basename "$patch")

    cp "$WATCOM_TOOLS/bpatch.exe" "$work/bpatch.exe"
    cp "$target" "$work/$tname"
    cp "$patch"  "$work/$pname"

    dos_exec "$work" "bpatch.exe -p -b $pname -f $tname" >/dev/null

    cp "$work/$tname" "$target"
    rm -rf "$work"
}
