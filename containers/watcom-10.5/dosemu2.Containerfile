# syntax=docker/dockerfile:1.4
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Watcom C/C++ 10.5 — dosemu2 runtime image.
#
# Produces:
#
#     localhost/watcom-10.5-dosemu2        (10.5 GA)
#     localhost/watcom-10.5a-dosemu2       (10.5 GA + the c105_a patch)
#
# The prune runs by default.  Pass --build-arg PRUNE=0 to ship the
# unmodified (full) tree under the same tag.
#
# Source: archives/watcom-10.5/Watcom_C++_10.5.iso (retail CD-ROM).
#
# The ISO stores its install tree under DISKIMGS/, packed in the
# Watcom WPK v1.1 format (12-byte header, no `internal` field).
# Extraction is done entirely in Python by scripts/lib/wpack_decode.py
# (see that file for decoder details).  The file→pack mapping in
# DISKIMGS/DISK01/SETUP.INF is interpreted by
# scripts/lib/setup_inf_manifest.py.
#
# The compilers live under binw/ (Windows-hosted, LX format with
# DOS4GW stub).  The shim auto-detects binw/ because that is where
# wcl386.exe lives.
#
# Source media
# ------------
# archives/watcom-10.5/Watcom_C++_10.5.iso — ISO 9660 image (492 MiB, volume
# label `WATCOM_C105`) from WinWorld.  Binaries are dated 1995-07-11.
#
# The host binaries in the ISO's binnt/, binp/ and binw/ are installer stubs;
# the real tools live in diskimgs/ as WPK v1.1 packs laid out as floppy
# directories disk01/..disk123/ plus vp/.  diskimgs/disk01/setup.inf is the
# manifest mapping each pack to its install path, which is what makes a full
# install tree reconstructible without running any installer.
#
# archives/watcom-10.5/patches/c105_a.zip — the A-level maintenance patch
# (338 files, binaries dated 1995-11-09/10) that raises 10.5 GA to 10.5a.  Its
# APPLYA.BAT gates on binw\wlib.exe, i.e. it applies onto a GA install.
#
# 10.5a was long believed lost: it shipped only as this patch, never as
# standalone media.  It was recovered from the maint/c_cpp/ directory of the
# official Watcom Products Infobase Volume 1 (1996) disc, the same channel that
# carried the 10.0 c_a/c_b kits.  That directory holds no B-level patch for the
# 10.5 line, consistent with 10.5a being its last update.
#
# Build:
#     podman build --target base -t localhost/watcom-10.5-dosemu2 \
#         -f containers/watcom-10.5/dosemu2.Containerfile .
#     podman build --target a          -t localhost/watcom-10.5a-dosemu2 \
#         -f containers/watcom-10.5/dosemu2.Containerfile .
#
# Prerequisites:
#     - localhost/watcom-toolchain
#     - localhost/watcom-dosemu2-runtime

FROM localhost/watcom-toolchain:latest AS tree

ENV WATCOM_ROOT=/opt/watcom \
    WORK_DIR=/src

RUN --mount=type=bind,source=archives/watcom-10.5,target=/archives/watcom-10.5,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/extract-10.5.sh /opt/watcom

# 10.5a: apply the c105_a maintenance patch (recovered from the Watcom
# Products Infobase Vol 1 1996 CD) onto the 10.5 GA
# tree by running the original APPLYA.BAT under dosemu2.  10.5a shipped
# only as this patch, never as standalone media.
FROM tree AS a-tree
RUN --mount=type=bind,source=archives/watcom-10.5/patches,target=/_patches,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/apply-patches-10.5.sh /opt/watcom /_patches

# Prune by default; --build-arg PRUNE=0 keeps the full tree.
FROM tree AS tree-final
ARG PRUNE=1
RUN --mount=type=bind,source=scripts/lib/prune-watcom-tree.sh,target=/tmp/prune.sh \
    if [ "$PRUNE" = "0" ]; then echo "prune: skipped (PRUNE=0, full tree)"; \
    else sh /tmp/prune.sh /opt/watcom; fi

FROM a-tree AS a-tree-final
ARG PRUNE=1
RUN --mount=type=bind,source=scripts/lib/prune-watcom-tree.sh,target=/tmp/prune.sh \
    if [ "$PRUNE" = "0" ]; then echo "prune: skipped (PRUNE=0, full tree)"; \
    else sh /tmp/prune.sh /opt/watcom; fi

FROM localhost/watcom-dosemu2-runtime AS base
COPY --from=tree-final /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 10.5" \
      org.opencontainers.image.description="Watcom C/C++ 10.5 under dosemu2"

FROM localhost/watcom-dosemu2-runtime AS a
COPY --from=a-tree-final /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 10.5a" \
      org.opencontainers.image.description="Watcom C/C++ 10.5a (1995; 10.5 GA + c105_a patch) under dosemu2"
