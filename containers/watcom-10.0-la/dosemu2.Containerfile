# syntax=docker/dockerfile:1.4
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Watcom C/C++ 10.0 Limited Availability (LA) — dosemu2 runtime image.
#
# Produces:
#
#     localhost/watcom-10.0-la-dosemu2        (pruned /opt/watcom tree)
#
# The prune runs by default.  Pass --build-arg PRUNE=0 to ship the
# unmodified (full) tree under the same tag.
#
# This is the March–June 1994 pre-release beta that preceded the
# commercial 10.0 GA (July 1994).  It was distributed as a CD-ROM
# (watcom10la.iso, volume label `CDROM`) carrying a Windows 3.x
# SETUP.EXE driven by a SETUP.INF file — a different installer model
# from the INSTALL.SCR scripts used by 9.5 and 9.01d, and from the
# pre-extracted WATCOM/ tree on the 10.0a retail CD.
#
# scripts/lib/setup_inf_ini.py interprets this SETUP.INF directly (the
# format differs from the one used by 10.5 and later, which has its
# own interpreter at scripts/lib/setup_inf_manifest.py).
#
# Layout note
# -----------
# The LA disc places most DOS-bound utility executables (wlib, wmake,
# wcl386, wbind, wstrip, wrc, …) under `binp/` rather than `binb/` as
# on retail 10.0a.  Many of those are bound NE/LX executables that
# still run under DOS via their MZ stubs.  The shim
# (scripts/shims/dosemu2-shim.sh) includes `binp` in the DOS PATH so
# those tools are reachable at runtime, and scripts/lib/prune-watcom-tree.sh
# never drops any host bin directory for that exact reason.
#
# Source media
# ------------
# archives/watcom-10.0-la/watcom10la.iso — ISO 9660 image (47 MiB, volume label
# `CDROM`) from WinWorld.  Every payload file sits in the ISO root with no
# subdirectories: a floppy distribution's layout (WPK packs numbered
# pack0001..pack0757) pressed onto CD.
#
# The disc was manufactured 1994-03-16/17 — setup.exe, install.exe (OS/2) and
# ntsetup.exe are all dated 1994-03-17 — but readme.1st is dated 1994-06-07,
# so it circulated with late errata.  That readme self-describes as "WATCOM
# C/C++ 10.0 Limited Availibility" [sic]; the Open Watcom changelog calls it
# 10.0 LA.  It preceded the commercial GA by roughly four months and went to
# selected beta customers.
#
# Build
# -----
#     podman build -t localhost/watcom-10.0-la-dosemu2 -f containers/watcom-10.0-la/dosemu2.Containerfile .
#
# Prerequisites:
#     - localhost/watcom-toolchain
#     - localhost/watcom-dosemu2-runtime

FROM localhost/watcom-toolchain:latest AS tree

ENV WATCOM_ROOT=/opt/watcom \
    WORK_DIR=/src

RUN --mount=type=bind,source=archives/watcom-10.0-la,target=/_archives,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/extract-10.0-la.sh /opt/watcom /_archives/watcom10la.iso

# Prune by default; --build-arg PRUNE=0 keeps the full tree.
FROM tree AS tree-final
ARG PRUNE=1
RUN --mount=type=bind,source=scripts/lib/prune-watcom-tree.sh,target=/tmp/prune.sh \
    if [ "$PRUNE" = "0" ]; then echo "prune: skipped (PRUNE=0, full tree)"; \
    else sh /tmp/prune.sh /opt/watcom; fi

FROM localhost/watcom-dosemu2-runtime AS base
COPY --from=tree-final /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 10.0 LA" \
      org.opencontainers.image.description="Watcom C/C++ 10.0 Limited Availability (1994-03) under dosemu2"
