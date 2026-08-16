# syntax=docker/dockerfile:1.4
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# WATCOM C 8.5/386 (1991) — dosemu2 runtime image.
#
# Produces:
#
#     localhost/watcom-8.5-dosemu2     (full /opt/watcom tree)
#
# Source: archives/watcom-8.5/Watcom C 386.ver.8.5.English.zip
# (five 1.2 MB floppy images, WPK-packed; old-dos.ru provenance).
# This is the earliest *runnable* Watcom compiler in
# the collection: it ships its own WLINK and the Rational DOS extender
# (DOS4GW), so it can compile + link + run 32-bit DOS/4G programs end to
# end.  (Watcom C/386 7.0 predates it but bundled no linker — it relied
# on the external Phar Lap 386|LINK — so no 7.0 image is built.)
#
# No prune for the 8.5 series
# ---------------------------
# Like 9.01/9.5, the 8.5 tree predates the sdk/, samples/, mfc/, and
# large IDE help catalogues that prune-watcom-tree.sh targets, so there
# is effectively nothing to drop.  A single unmodified tag is shipped.
#
# Extraction
# ----------
# scripts/extract-8.5.sh flattens the five floppies and runs the
# original INSTALL.SCR through scripts/lib/install_scr.py (--yes-all).
# WPK members decode in pure Python (same 0x2403 format as 9.5+), so
# the heavy toolchain image is used only for its mtools / python /
# bsdtar; no DOS wpack.exe boot is needed in the common case.
#
# Shim & ENTRYPOINT
# -----------------
# The ENTRYPOINT is /usr/local/bin/watcom (scripts/shims/dosemu2-shim.sh).
# It auto-detects binb/ as the host tools dir (that is where wcl386.exe
# lands) and puts bin/ on the DOS PATH too (the compiler wcc386.exe and
# dos4gw.exe live there).  Typical invocation:
#
#     podman run --rm -v "$PWD:/src" localhost/watcom-8.5-dosemu2 \
#         wcl386 -l=dos4g hello.c
#
# Source media
# ------------
# archives/watcom-8.5/Watcom C 386.ver.8.5.English.zip — five 1.2 MB floppy
# images (disk1.vfd .. disk5.vfd) from old-dos.ru.  Disk 1's boot-sector volume
# label is `WATCOM C386` and the install payload self-identifies as "WATCOM C
# 8.5 /386, WATCOM Products Inc." with run-time code (c) 1990-1991.  Binary
# timestamps are 1991-09-18 (some support files 1991-08-20).
#
# Packed in WPK "WATCOM Install Archiver Version 1.2" (Copyright 1990) and
# unpacked by the bundled WPACK.EXE (42,027 B).  Disk 1 holds INSTALL.EXE,
# WPACK.EXE, WCC386.DOS (88,217 B), WCC386.OS2 (265,024 B), WCC386P.WPK,
# 386WCGL.WPK, WMAKE.WPK and WDISASM.WPK.
#
# archives/watcom-8.5/liren-c496/ holds an earlier 1991-08/09 pressing of the
# same release as five proprietary-format DOSIMG dumps (Liren CD, Discmaster
# item 30126).  It duplicates media already imaged here, so it is preserved but
# not built.
#
# Build
# -----
#     podman build -t localhost/watcom-8.5-dosemu2 \
#         -f containers/watcom-8.5/dosemu2.Containerfile .
#
# Prerequisites:
#     - localhost/watcom-toolchain        (mtools + python + wpack/bpatch)
#     - localhost/watcom-dosemu2-runtime  (shared dosemu2 runtime base)

# =============================================================================
# Tree stage — extract on the toolchain image.
# =============================================================================
FROM localhost/watcom-toolchain:latest AS tree

ENV WATCOM_ROOT=/opt/watcom \
    WORK_DIR=/src

RUN --mount=type=bind,source=archives/watcom-8.5,target=/archives/watcom-8.5,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/extract-8.5.sh /opt/watcom

# =============================================================================
# Shipping stage — slim dosemu2 runtime + tree.
# =============================================================================
FROM localhost/watcom-dosemu2-runtime AS base
COPY --from=tree /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="WATCOM C 8.5/386" \
      org.opencontainers.image.description="WATCOM C 8.5/386 (1991) under dosemu2" \
      org.opencontainers.image.source="https://github.com/second-impressions/watcom-compilers"

