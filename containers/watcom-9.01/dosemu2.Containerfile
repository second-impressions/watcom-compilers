# syntax=docker/dockerfile:1.4
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# WATCOM C/386 9.01 (base, May 1992) — dosemu2 runtime image.
#
# Produces:
#
#     localhost/watcom-9.01-dosemu2     (retail media as pressed)
#     localhost/watcom-9.01b-dosemu2    (+ c386_b)
#     localhost/watcom-9.01c-dosemu2    (+ c386_b + c386_c)
#
# Patch level of the retail media
# ------------------------------
# The May 1992 floppy set is NOT pre-patch-A, despite being the original
# retail pressing.  Running APPLYA.BAT against it reports 50 files
# "already patched to level '.a'" (wcc386.exe, wlinkp.exe, dos4gw.exe,
# wcl386.exe, bpatch.exe, ...) and fails on 15 others whose sizes are
# already past what patch A expects as input.  APPLYB.BAT, by contrast,
# applies to it with 158 patched and zero errors — and bpatch validates
# every input file before touching it, so that only happens if the tree
# is exactly patch A's output.
#
# All files on the floppies carry a uniform 1992-05-28 date, so this is
# a manufacturing state rather than a field-patched copy: the retail
# pressing already incorporated what c386_a was distributed to fix.
# c386_a.zip is therefore not applicable to any tree in this collection
# and no 9.01a image is built.
#
# The c386_* patches are cumulative, so each level chains off the last.
# Levels d and e are not built here: the repo ships a pre-extracted
# 9.01d tree (containers/watcom-9.01d/), and 9.01e is produced from it
# there.  Chaining b+c+d off these floppies does yield a 9.01d-level
# tree, but not a byte-equal one — the two install paths select
# different optional components — so the pre-extracted tree remains the
# authoritative 9.01d source.
#
# Source: archives/watcom-9.01/floppies/Disk01.img .. Disk06.img
# (six 1.2 MB raw-FAT floppies, WinWorld provenance).
# This is the un-patched *base* 9.01 release — the install level onto
# which the c386_a..e patch chain (archives/watcom-9.01d/patches/)
# applies.  The repo separately ships a pre-extracted 9.01d tree
# (containers/watcom-9.01d/) at a later patch level; this image is the
# earlier, byte-for-byte-from-floppies base.
#
# Like 8.5/9.01d/9.5 this tree predates the sdk/, samples/, mfc/ and
# large IDE help catalogues that prune-watcom-tree.sh targets, so a
# single unmodified tag is shipped (no prune).
#
# Extraction: scripts/extract-9.01.sh flattens the six floppies and runs
# the original INSTALL.SCR through scripts/lib/install_scr.py (--yes-all).
# The tree is binb/ (wcl386, wlink, wlib, wmake) + bin/ (wcc386, dos4gw);
# it compiles + links + runs 32-bit DOS/4GW programs end to end
# (`wcl386 -l=dos4g`).  C-only — Watcom C++ did not arrive until 10.0.
#
# Source media
# ------------
# archives/watcom-9.01/floppies/Disk01.img .. Disk06.img — the WinWorld 3.5"
# set (six 1,228,800-byte FAT12 images, OEM-ID `HDCPY17A`, from the HD-Copy 1.7a
# imaging tool).  An independent copy exists on Vetusware (id 17094).
#
# Identity evidence: every file is dated 1992-05-28, matching EDM2's "WATCOM
# C9.01/386 (May 1992)" release date.  Disk 1 carries the real-mode WCC386.DOS
# (116,214 B) alongside the OS/2-hosted WCC386.OS2 (303,238 B), plus
# WCCOPTS.DLL, TO31.WPK and GOODIES.WPK — the file set previously seen only in
# the Liren c/c500 Discmaster dump, which is preserved at
# archives/watcom-9.0/liren-c500/ but not built (proprietary DiskDupe format,
# duplicating media already imaged here).
#
# The patch ZIPs applied above live under archives/watcom-9.01d/patches/
# because that is where the whole c386_* chain was recovered from; see that
# directory's provenance in containers/watcom-9.01d/dosemu2.Containerfile.
#
# Build:
#     podman build --target base -t localhost/watcom-9.01-dosemu2  \
#         -f containers/watcom-9.01/dosemu2.Containerfile .
#     podman build --target b    -t localhost/watcom-9.01b-dosemu2 \
#         -f containers/watcom-9.01/dosemu2.Containerfile .
#     podman build --target c    -t localhost/watcom-9.01c-dosemu2 \
#         -f containers/watcom-9.01/dosemu2.Containerfile .
#
# Prerequisites:
#     - localhost/watcom-toolchain        (mtools + python + wpack/bpatch)
#     - localhost/watcom-dosemu2-runtime  (shared dosemu2 runtime base)

FROM localhost/watcom-toolchain:latest AS tree

ENV WATCOM_ROOT=/opt/watcom \
    WORK_DIR=/src

RUN --mount=type=bind,source=archives/watcom-9.01/floppies,target=/archives/watcom-9.01/floppies,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/extract-9.01.sh /opt/watcom

# -----------------------------------------------------------------------------
# Patch levels.  Cumulative: b on the retail tree, c on b.
# The patch ZIPs live with the 9.01d archives because that is where the
# whole c386_* chain was recovered from.
# -----------------------------------------------------------------------------
FROM tree AS b-tree
RUN --mount=type=bind,source=archives/watcom-9.01d/patches,target=/_patches,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/apply-patches-9.01d.sh /opt/watcom b /_patches

FROM b-tree AS c-tree
RUN --mount=type=bind,source=archives/watcom-9.01d/patches,target=/_patches,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/apply-patches-9.01d.sh /opt/watcom c /_patches

# =============================================================================
# Shipping stages (single tag per patch level, unmodified tree).
# =============================================================================
FROM localhost/watcom-dosemu2-runtime AS base
COPY --from=tree /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="WATCOM C/386 9.01" \
      org.opencontainers.image.description="WATCOM C/386 9.01 base (1992) under dosemu2" \
      org.opencontainers.image.source="https://github.com/second-impressions/watcom-compilers"

FROM localhost/watcom-dosemu2-runtime AS b
COPY --from=b-tree /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="WATCOM C/386 9.01b" \
      org.opencontainers.image.description="WATCOM C/386 9.01 + patch level b (1992) under dosemu2" \
      org.opencontainers.image.source="https://github.com/second-impressions/watcom-compilers"

FROM localhost/watcom-dosemu2-runtime AS c
COPY --from=c-tree /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="WATCOM C/386 9.01c" \
      org.opencontainers.image.description="WATCOM C/386 9.01 + patch levels b-c (1992) under dosemu2" \
      org.opencontainers.image.source="https://github.com/second-impressions/watcom-compilers"

