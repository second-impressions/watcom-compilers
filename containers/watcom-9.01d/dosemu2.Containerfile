# syntax=docker/dockerfile:1.4
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Watcom C/386 9.01 series — dosemu2 runtime images.
#
# Produces two runnable images in a single multi-target build:
#
#     localhost/watcom-9.01d-dosemu2   (9.01d, the 1992 release)
#     localhost/watcom-9.01e-dosemu2   (9.01d + APPLYE → 9.01e)
#
# The chain starts at 9.01d because that is the earliest complete
# installed tree we have. The 9.01a–c patch levels require the original
# 9.01 base installer, which has not been located.
#
# Product naming
# --------------
# At this era the product was called "Watcom C/386" (not yet Watcom C/C++).
# The "d" and "e" suffix denote cumulative patch levels from Watcom, not
# version numbers; we inherit this naming convention.
#
# Patch ZIP structure
# -------------------
# 9.01 patches differ from 9.5/10.0 in having a two-level ZIP wrapper:
#   c386_e.zip → UPLOAD.DOC + C386_E.ZIP (inner) → APPLYE.BAT + *.e files
# scripts/apply-patches-9.01d.sh handles the unwrapping transparently.
#
# bpatch self-reference
# ---------------------
# APPLYD.BAT patches binb\bpatch.exe (same EBUSY problem as 9.5).
# APPLYE.BAT does NOT patch bpatch.exe, but we apply the _bpx_ workaround
# unconditionally in apply-patches-9.01d.sh for robustness.
#
# No prune for the 9.01 series
# ----------------------------
# The 9.01 install tree predates the bulk of the documentation,
# sample-program, IDE help-catalogue, and Sybase Win32 SDK content
# that the prune script targets.  Empirically prune-watcom-tree.sh
# only finds ~7 MB to drop in a 9.01 tree (the few .hlp files and
# the binp/, novh/, nlm/ subtrees), which is well under 4 % of the
# resulting image.  Pruning that small a delta is not worth it, so
# these images ship the unmodified tree.  (The 10.x / 11.x images
# prune by default, with a --build-arg PRUNE=0 escape hatch.)
#
# Source media
# ------------
# archives/watcom-9.01d/Watcom - C++ 9.01d.zip — a floppy-style layout with
# eight numbered directories (01-08) of WPK-packed files, as distributed on the
# original 3.5" disks.  From Discmaster item 43408 (a 2009 compilation).  File
# timestamps run 1992-05-28 to 1992-11-11.  Directory 08 is the OS/2 Header
# Files disk (INSTALL.EXE, INSTALL.SCR, OS2HDR.WPK).
#
# archives/watcom-9.01d/patches/ holds the complete cumulative chain for Watcom
# C/386 — the product name before the 9.5 rebrand to Watcom C/C++:
#
#   c386_a.zip  752,654 B  ~1992-10   5 Discmaster copies, all byte-identical
#   c386_b.zip  626,401 B  ~1992-10   5 copies, all byte-identical
#   c386_c.zip  336,976 B  ~1992-10   5 copies, all byte-identical
#   c386_d.zip  409,411 B  ~1992-11   4 copies; absent from the Hobbes Nov 1992
#                                     CD, which dates it after that snapshot
#   c386_e.zip  411,987 B  1993-02-28 7 Discmaster copies + os2site.com; the
#                                     inner C386_E.ZIP is byte-identical across
#                                     all of them (one copy adds a file_id.diz
#                                     wrapper, 143 bytes, same core content)
#
# Level e is the last patch before the 9.5 rebrand (1993-05-05); no c386_f
# exists on Discmaster or os2site.com.  Levels d and e contain j-prefixed patch
# files, confirming a Japanese edition of Watcom C/386 existed.
#
# Only level e is applied here: this tree is already at level d.  Levels b and c
# are applied to the 9.01 retail floppies instead — see
# containers/watcom-9.01/dosemu2.Containerfile, which also explains why level a
# applies to nothing in this collection.
#
# Build
# -----
#     podman build --target base -t localhost/watcom-9.01d-dosemu2 -f containers/watcom-9.01d/dosemu2.Containerfile .
#     podman build --target e    -t localhost/watcom-9.01e-dosemu2 -f containers/watcom-9.01d/dosemu2.Containerfile .
#
# Prerequisites:
#     - localhost/watcom-toolchain
#     - localhost/watcom-dosemu2-runtime

# =============================================================================
# Tree-producing stages.
# =============================================================================
FROM localhost/watcom-toolchain:latest AS base-tree

ENV WATCOM_ROOT=/opt/watcom \
    WORK_DIR=/src

RUN --mount=type=bind,source=archives/watcom-9.01d,target=/_archives,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/extract-9.01d.sh /opt/watcom "/_archives/Watcom - C++ 9.01d.zip"

FROM base-tree AS e-tree
RUN --mount=type=bind,source=archives/watcom-9.01d/patches,target=/_patches,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/apply-patches-9.01d.sh /opt/watcom e /_patches

# =============================================================================
# Shipping stages (single tag per patch level, unmodified tree).
# =============================================================================
FROM localhost/watcom-dosemu2-runtime AS base
COPY --from=base-tree /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/386 9.01d" \
      org.opencontainers.image.description="Watcom C/386 9.01d (1992) under dosemu2" \
      org.opencontainers.image.source="https://github.com/second-impressions/watcom-compilers"

FROM localhost/watcom-dosemu2-runtime AS e
COPY --from=e-tree /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/386 9.01e" \
      org.opencontainers.image.description="Watcom C/386 9.01d + patch level e (1993-02-28) under dosemu2" \
      org.opencontainers.image.source="https://github.com/second-impressions/watcom-compilers"

