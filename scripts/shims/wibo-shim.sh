#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# wibo-shim.sh — entrypoint for the Watcom-under-wibo runtime containers.
#
# Runs a Watcom NT-host tool (from /opt/watcom/binnt) under wibo, a
# minimal user-space Win32 PE32 loader.  The images build it from our
# pinned fork, https://github.com/second-impressions/wibo (upstream:
# https://github.com/decompals/wibo).
#
# wibo is a single ~7 MiB static binary.  It implements just enough of
# the Win32 API surface (kernel32, user32, advapi32, msvcrt, ...) to run
# command-line compilers; it provides no prefix directory, no X server,
# no DCOM, no registry, no mscoree, and no SEH-driven page-fault
# dispatcher.
#
# Status:
#   - Every Watcom revision that ships a binnt/ directory (9.5 GA
#     through 11.0c) has a wibo image and passes the compile+link
#     smoke test in tests/run-tests.sh.  The 9.5 - 10.6a wlink.exe
#     overlay pager that blocked the earlier Wine experiment runs
#     fine under wibo's memory model.
#   - 9.01d/e ship no binnt/ at all, so no wibo image is built for
#     them; use the dosemu2 images instead.
#   - Per-version, per-tool detail (which binnt/ tools are real vs.
#     stubs that forward into bin/ under DPMI) lives in
#     host-binary-taxonomy.md, published with the Archive.org item.
#
# Usage:
#     podman run --rm -v "$PWD:/src" localhost/watcom-11.0-wibo \
#         wcl386 -l=nt hello.c
#
# Without arguments, drops into an interactive bash with all wibo env
# vars set so you can poke the runtime by hand.
#
# Environment
# -----------
#     WATCOM_ROOT   Installed Watcom tree.   Default: /opt/watcom
#     WORK_DIR      Bind-mount for sources.  Default: /src
#     WIBO          Path to the wibo binary. Default: /usr/local/bin/wibo
#     WIBO_DEBUG    Set to 1 to enable wibo's verbose tracing.
#
# Drive / path model
# ------------------
# wibo has no configurable drive-mapping table: it translates any Z:\...
# or C:\... prefix to /, and forwards all other paths as-is.  The shim
# therefore exports DOS-style paths anchored at Z:\opt\watcom and uses
# the work directory as CWD directly.
#
# Sibling-tool spawn (wcl386 -> wcc386 -> wlink) works through wibo's
# CreateProcessA, which re-execs wibo on the child PE.  The child must
# be findable on disk; wcl386 looks for it on PATH (Windows-side), so
# we put Z:\opt\watcom\binnt at the front.  WIBO_PATH is the wibo-side
# DLL search list and points at the same directory.

set -euo pipefail

WATCOM_ROOT="${WATCOM_ROOT:-/opt/watcom}"
WORK_DIR="${WORK_DIR:-/src}"
WIBO="${WIBO:-/usr/local/bin/wibo}"

if [ ! -x "$WIBO" ]; then
    echo "shim: missing wibo binary at $WIBO" >&2
    exit 1
fi
if [ ! -d "$WATCOM_ROOT/binnt" ]; then
    echo "shim: missing $WATCOM_ROOT/binnt (no NT-host tools to run)" >&2
    exit 1
fi
if [ ! -d "$WORK_DIR" ]; then
    echo "shim: missing $WORK_DIR (bind-mount your source with -v \$PWD:$WORK_DIR)" >&2
    exit 1
fi

# DOS-style paths: wibo strips a leading drive letter; everything else
# is forwarded with '\' -> '/'.  We anchor at Z:\ which wibo maps to /.
to_dos() {
    local p="$1"
    printf 'Z:%s' "${p//\//\\}"
}
WATCOM_DOS=$(to_dos "$WATCOM_ROOT")
WORK_DOS=$(to_dos "$WORK_DIR")

# wibo's DLL search uses host paths joined with ':' (Unix-style) — see
# src/modules.cpp ("addFromEnv WIBO_PATH").  We point it at binnt so
# LoadLibrary("wccd386") etc. resolves.
export WIBO_PATH="$WATCOM_ROOT/binnt"

# Watcom-side environment.  WATCOM is consulted by wlink to find
# binw\wlsystem.lnk; INCLUDE / LIB are the usual compiler search
# paths.  All values are Windows-style (drive-letter, backslashes,
# ';' separators) because that's what the Watcom tools parse them as.
export WATCOM="$WATCOM_DOS"
export INCLUDE="$WATCOM_DOS\\h;$WATCOM_DOS\\h\\nt"
export EDPATH="$WATCOM_DOS\\eddat"

# Interactive shell fallback.  This branch keeps the host PATH intact
# so /bin/bash inside the container still works as a normal shell.
if [ $# -eq 0 ]; then
    exec /bin/bash
fi

# Change CWD to the work directory and invoke the requested tool.  The
# command is expected to be a Watcom binary name (wcl386, wcc386, ...)
# followed by its arguments.
cd "$WORK_DIR"

TOOL="$1"; shift
case "$TOOL" in
    /*)   TOOL_PATH="$TOOL" ;;
    *.exe) TOOL_PATH="$WATCOM_ROOT/binnt/$TOOL" ;;
    *)     TOOL_PATH="$WATCOM_ROOT/binnt/${TOOL}.exe" ;;
esac

if [ ! -f "$TOOL_PATH" ]; then
    echo "shim: tool not found: $TOOL_PATH" >&2
    exit 1
fi

# Optional verbose tracing.
WIBO_ARGS=()
if [ "${WIBO_DEBUG:-}" = "1" ]; then
    WIBO_ARGS+=(--debug)
fi

# wibo forwards the host PATH verbatim to the guest as the Win32
# %PATH%.  The Watcom driver (wcl386) parses %PATH% with ';' as the
# entry separator and searches it for wcc386.exe / wpp386.exe /
# wlink.exe.  A Unix-style PATH with ':' separators gets concatenated
# into one nonsensical entry and the spawn fails with
# "Error: Unable to find 'wcc386.exe'".  Replace PATH with a
# ';'-separated, drive-letter-anchored, Win-style list right before
# exec — the shell itself is being replaced so this no longer needs
# to find anything on the Unix side.
#
# binb / binw is included because wlink looks up wstub.exe there
# when producing -l=dos4g / -l=dos4gnz output ("op stub=wstub.exe"
# lines in {binb,binw}/wlsystem.lnk).  Without that directory on
# PATH the link still succeeds but emits the stub-default "this is
# a Rational Systems executable" / "this is a DOS/4G executable"
# placeholder instead of the real DOS4GW loader.
#
# 9.5 – 10.0b ship wstub.exe + wlsystem.lnk in binb/ (the original
# "bound DOS/Extended" directory).  10.5 – 11.0c moved them to binw/.
# We include both — absent directories are harmless on a Windows-
# style PATH lookup.
PATH="$WATCOM_DOS\\binnt;$WATCOM_DOS\\binw;$WATCOM_DOS\\binb" \
    exec "$WIBO" "${WIBO_ARGS[@]}" "$TOOL_PATH" "$@"
