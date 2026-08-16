#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# dosemu2-shim.sh — entrypoint for the Watcom-under-dosemu2 runtime
# containers.
#
# Inside each watcom-*-dosemu2 image, /opt/watcom contains a complete
# installed Watcom C/C++ tree. This shim is what the container's
# ENTRYPOINT runs; it sets up a DOS environment, maps the caller's
# current working directory as a DOS drive, and forwards a command
# line to that drive.
#
# Usage:
#     docker run --rm -v "$PWD:/src" watcom-9.5-dosemu2 wcl386 hello.c
#     docker run --rm -it -v "$PWD:/src" watcom-9.5-dosemu2
#
# Form 1: `wcl386 hello.c` after the image name is the DOS command to
# run, with /src as the current DOS drive. dosemu2 runs headless
# (-dumb), exits when the command exits, and stdout/stderr carry the
# compiler's output. This is the CI path.
#
# Form 2 (no command + -it): starts an interactive DOS shell using
# dosemu2's S-Lang terminal mode (-t), with keyboard input and video
# output attached to the container's stdio. WATCOM / INCLUDE / PATH
# are pre-set and the CWD is F:\SRC. Type `exit` in command.com to
# end the session.
#
# Layout:
#     /opt/watcom   — the installed Watcom tree (from the extract stage)
#     /src          — bind-mounted by the user; becomes the DOS CWD
#     F:            — whatever drive letter dosemu2 assigns to /src
#
# The shim creates a DOS batch file at /src/_wcrun.bat, sets the
# WATCOM / INCLUDE / PATH environment variables inside DOS, and
# invokes the caller's command. dosemu2 runs the batch file headless
# via the -dumb -K -E flags and exits.

set -euo pipefail

WATCOM_ROOT="${WATCOM_ROOT:-/opt/watcom}"
WORK_DIR="${WORK_DIR:-/src}"

# Primary host-tools directory.  9.5 and 10.0 ship the DOS-host
# compilers in binb/; 10.5, 10.6a, 11.0 moved them to binw/; 10.0 LA
# is the outlier that puts them under binp/.  Auto-detect by looking
# for wcl386.exe so the runtime image doesn't need a per-version env.
# Prefer the 32-bit driver (wcl386); fall back to the 16-bit driver
# (wcl, e.g. Watcom C 6.5) only if no wcl386 exists in any host dir.
if [ -z "${WATCOM_BINDIR:-}" ]; then
    for drv in wcl386 wcl; do
        for cand in binw binb binp bin bin95 binnt; do
            if [ -e "$WATCOM_ROOT/$cand/$drv.exe" ] \
               || [ -e "$WATCOM_ROOT/$cand/$(printf '%s' "$drv" | tr a-z A-Z).EXE" ]; then
                WATCOM_BINDIR="$cand"
                break 2
            fi
        done
    done
    WATCOM_BINDIR="${WATCOM_BINDIR:-binb}"
fi

if [ ! -d "$WATCOM_ROOT" ]; then
    echo "shim: missing $WATCOM_ROOT" >&2
    exit 1
fi
if [ ! -d "$WORK_DIR" ]; then
    echo "shim: missing $WORK_DIR (bind-mount your source with -v \$PWD:$WORK_DIR)" >&2
    exit 1
fi

# Two run modes:
#
#   * command given       → headless batch (-dumb). dosemu2 runs the
#                           command to completion and exits; stdout/
#                           stderr carry the compiler's output. This is
#                           the CI / `wcl386 hello.c` path.
#
#   * no command + TTY    → interactive DOS prompt via dosemu2's S-Lang
#                           terminal mode (-t). Keyboard input and video
#                           output are attached to the container's stdio,
#                           so `podman run -it IMAGE` drops the user at a
#                           DOS prompt with WATCOM / INCLUDE / PATH
#                           already set and F:\SRC as the CWD. Typing
#                           `exit` in command.com ends the session.
#
#   * no command + no TTY → would be silently useless (dosemu -t needs a
#                           real terminal to render into). Bail with a
#                           usage hint.
INTERACTIVE=0
if [ $# -eq 0 ]; then
    if [ -t 0 ] && [ -t 1 ]; then
        INTERACTIVE=1
    else
        cat >&2 <<'USAGE'
shim: no DOS command given and stdin/stdout are not a TTY.

Run a one-shot command:
    podman run --rm -v "$PWD:/src" IMAGE wcl386 -l=dos4g hello.c

Or start an interactive DOS shell (requires -it):
    podman run --rm -it -v "$PWD:/src" IMAGE
USAGE
        exit 2
    fi
fi

# -----------------------------------------------------------------------------
# Layout trick: dosemu2 maps a single unix directory as the current DOS
# drive, but we need BOTH the user's code (mounted at /src) and the
# Watcom tree (at /opt/watcom) visible under that drive. Solution: a
# throwaway scratch parent containing:
#
#     $SCRATCH/watcom  → symlink to /opt/watcom  (DOS path: F:\WATCOM\)
#     $SCRATCH/src     → symlink to /src         (DOS path: F:\SRC\)
#
# We then cd to F:\SRC (which, from the user's point of view, IS the
# host's $PWD thanks to the bind mount) before running the command,
# and set INCLUDE / PATH / WATCOM to point at F:\WATCOM subdirectories.
# -----------------------------------------------------------------------------
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
ln -s "$WATCOM_ROOT" "$SCRATCH/watcom"
ln -s "$WORK_DIR"    "$SCRATCH/src"

# Build the DOS command line. The user's argv is passed as a single
# string to the batch file, which runs it verbatim after the env
# setup. DOS batch syntax requires escaping certain characters; we
# do a minimal safe quoting by joining with spaces. In interactive
# mode the final command is command.com so the user lands at a shell
# after env setup instead of dosemu2 exiting when the batch ends.
# %COMSPEC% is set by FDPP to its bundled command.com (on the boot
# drive, not on our WATCOM PATH). Using it avoids a "Bad command or
# file name" when the batch ends and we want a shell.
if [ "$INTERACTIVE" = 1 ]; then
    DOS_CMD="%COMSPEC%"
else
    DOS_CMD="$*"
fi

# Use `F:` explicitly because the scratch dir will be mounted as the
# first available drive after the built-in C:/D:/E: aliases. dosemu2
# assigns drive letters in /etc/dosemu/drives.d/ order; the `-K PATH`
# flag maps PATH as the DEFAULT drive for the run, which is F: under
# the stock dosemu2 config used by the toolchain image.
# Build DOS PATH: primary bin dir first, then the others that exist.
# BINP is included for the 10.0 LA layout where DOS-bound utility
# executables (wlib, wmake, wcl386, …) live under binp/.  Images that
# don't have a binp/ directory get a harmless extra PATH entry.
DOS_PATH="F:\\WATCOM\\${WATCOM_BINDIR^^}"
for extra in BIN BINB BINW BINP; do
    UPPER="${WATCOM_BINDIR^^}"
    [ "$extra" != "$UPPER" ] && DOS_PATH="$DOS_PATH;F:\\WATCOM\\$extra"
done

# 16-bit toolchains (Watcom C 6.5) keep their libraries in a bare lib/
# and the linker locates them via the DOS LIB variable, not the
# wlink.lnk `system` libpath directives the 32-bit trees use.  Emit a
# SET LIB line only when that bare lib/ exists, so the 32-bit images
# (which have no lib/, only lib386/lib286) are completely unaffected.
SET_LIB=""
if [ -d "$WATCOM_ROOT/lib" ]; then
    SET_LIB="
SET LIB=F:\\WATCOM\\LIB"
fi

cat > "$SCRATCH/_wcrun.bat" <<EOF
@echo off
F:
SET WATCOM=F:\\WATCOM
SET INCLUDE=F:\\WATCOM\\H;F:\\WATCOM\\H\\NT;F:\\WATCOM\\H\\WIN
SET PATH=$DOS_PATH$SET_LIB
cd F:\\SRC
$DOS_CMD
EOF

# -dumb for headless batch; -t for S-Lang terminal on the host TTY.
# Both honour -K/-E identically; only the I/O backend differs.
if [ "$INTERACTIVE" = 1 ]; then
    exec dosemu -t -quiet -K "$SCRATCH" -E "_wcrun.bat"
else
    exec dosemu -dumb -quiet -K "$SCRATCH" -E "_wcrun.bat"
fi
