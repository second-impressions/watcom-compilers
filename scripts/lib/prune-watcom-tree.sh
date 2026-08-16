#!/bin/sh
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# prune-watcom-tree.sh — strip documentation, samples, IDE help
# catalogues, and installer media from a fully-extracted /opt/watcom
# while preserving every piece needed to compile, assemble, link,
# librarian, or make for ANY target the toolchain supports.
#
# Usage:
#     prune-watcom-tree.sh /opt/watcom
#
# This is runtime-agnostic — the same prune is correct for both the
# dosemu2 (DOS-host binw/ or binb/) and wibo (NT-host binnt/) runtime
# images.  Whichever host directory the runtime invokes, the prune
# leaves it intact, and the target-side artefacts (lib386/, lib286/,
# h/, sdk/, mfc/, som/, wstub.exe, dos4gw.exe, …) stay in place.
#
# What stays
# ----------
# Every host toolchain directory:
#
#     bin/  binb/  binp/  binw/  binnt/  bin95/
#
# All six are kept because at least one Watcom revision uses each as
# the active host toolchain location.  10.0 LA, for instance, ships
# its DOS-host utilities (wcl386, wlib, wbind, ...) in binp/ rather
# than the binb/ used by 10.0a; the shim adds every host bin dir to
# PATH for that reason.  Keeping all six host dirs lets the same
# prune work across every revision without per-version logic.
# Per-directory junk inside these dirs (WinHelp catalogues) is still
# trimmed.
#
# Every header and library tree:
#
#     h/               C / C++ / NT / OS/2 / Win headers
#     lib386/          dos/ nt/ os2/ win/ netware/ + root math/complex/...
#     lib286/          dos/ os2/ win/ + root math/complex/...
#     sdk/             Sybase Win32 SDK pieces — MAPI, OpenGL 95,
#                       RPC (DCE), SNMP, ICMP, win32s, hookole, posix
#                       (the sdk/samples/ tree is removed; everything
#                       else under sdk/ stays)
#     mfc/             MFC headers + sources
#     som/             IBM System Object Model for OS/2
#
# Runtime data the linker reads at link time:
#
#     eddat/           wlink message catalogues + editor data
#     binw/wlsystem.lnk  (or binb/wlsystem.lnk on 9.5 – 10.0b)
#     binw/wstub.exe   binw/wstubq.exe   binw/dos4gw.exe   (or in binb/)
#
# Per-target wcc386 / wpp386 option profile files at the tree root:
#
#     wcc386.prf  wpp386.prf
#
# What goes
# ---------
#     samples/             example programs
#     pdf/                  manuals
#     src/                  Watcom CRT sources
#     vp/                   Visual Programmer (GUI IDE)
#     winsys/               Win 3.x runtime DLLs (end-user runtime,
#                           not needed at build time)
#     novh/  novi/  nlm/    NetWare host pieces (the *target* NetWare
#                           libraries in lib386/netware/ stay)
#     updates/  toolkt2x/  windir/    legacy install metadata
#     Root setup*.exe / install*.exe / *.sym / license.txt / readme.txt /
#     dos4gw.doc / watcom.ico
#     sdk/samples/  sdk/doc/  sdk/help/  sdk/readme.txt  sdk/license/
#     sdk/mssetup/
#     {bin,binb,binw,binnt}/*.{hlp,ihp,cnt}   WinHelp catalogues (these
#                                              are 18 MB on binw/ alone
#                                              and the CLI build chain
#                                              never reads them)
#
# Net effect on Watcom 11.0c: /opt/watcom shrinks from ~350 MB to
# ~120 MB without losing any documented build capability.  Smaller
# revisions (9.5 ~150 MB, 10.0a ~190 MB) end up around 60–90 MB.

set -eu

WCM="${1:-/opt/watcom}"
if [ ! -d "$WCM" ]; then
    echo "prune: $WCM does not exist" >&2
    exit 1
fi

before_kb=$(du -sk "$WCM" 2>/dev/null | awk '{print $1}')

#
# 1. Whole top-level subtrees that hold no build inputs.
#
for d in \
    samples pdf src vp winsys \
    novh novi nlm \
    updates toolkt2x windir
do
    rm -rf "$WCM/$d"
done

#
# 2. Loose installer / documentation files at the tree root.
#
for f in \
    setup.exe setup.sym setup.inf \
    setup32.exe setup32.sym setupaxp.sym \
    dossetup.exe dossetup.sym \
    98setup.exe 98setup.sym \
    install.exe install.sym \
    license.txt readme.txt dos4gw.doc watcom.ico
do
    rm -f "$WCM/$f"
done

#
# 3. Inside sdk/: drop the giant samples tree and the doc/setup
#    metadata.  Keep every actual SDK piece (mapi, opengl95, rpc_sdk,
#    rpc_rt16, snmpapi, icmp, win32s, hookole, posix).
#
if [ -d "$WCM/sdk" ]; then
    for d in samples doc help mssetup license; do
        rm -rf "$WCM/sdk/$d"
    done
    rm -f "$WCM/sdk/readme.txt"
fi

#
# 4. IDE WinHelp catalogues inside the host bin dirs.  These are
#    multi-megabyte .hlp/.ihp/.cnt files that the command-line build
#    chain never touches.  Sweep by extension so the rule works on
#    every Watcom revision regardless of which catalogues happen to
#    be installed.
#
for d in bin binb binw binnt; do
    [ -d "$WCM/$d" ] || continue
    find "$WCM/$d" -maxdepth 1 -type f \
        \( -iname '*.hlp' -o -iname '*.ihp' -o -iname '*.cnt' \) \
        -delete
done

after_kb=$(du -sk "$WCM" 2>/dev/null | awk '{print $1}')
saved_kb=$((before_kb - after_kb))
printf 'prune: %s -> %s (saved %s)\n' \
    "$(numfmt --to=iec --suffix=B $((before_kb*1024)) 2>/dev/null || echo "${before_kb}K")" \
    "$(numfmt --to=iec --suffix=B $((after_kb*1024))  2>/dev/null || echo "${after_kb}K")" \
    "$(numfmt --to=iec --suffix=B $((saved_kb*1024))  2>/dev/null || echo "${saved_kb}K")"
echo "prune: top entries left in $WCM:"
du -sk "$WCM"/* 2>/dev/null | sort -nr | head -10
