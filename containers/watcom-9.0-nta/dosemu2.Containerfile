# syntax=docker/dockerfile:1.4
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# WATCOM C/386 9.0 "NT Alpha" (Feb 1992) — dosemu2 runtime image.
#
# Produces:
#
#     localhost/watcom-9.0-nta-dosemu2     (full /opt/watcom tree)
#
# Source: archives/watcom-9.0/nt-alpha/WC90NTA1.ZIP .. WC90NTA4.ZIP
# (four BBS distribution disks, Discmaster provenance).
# This 1992-02 build sits between 8.5 (1991) and the base 9.01 (May 1992).
# C-only — Watcom C++ did not arrive until 10.0.
#
# Like the other pre-9.5 trees this predates the sdk/, samples/, mfc/ and
# large IDE help catalogues that prune-watcom-tree.sh targets, so a single
# unmodified tag is shipped (no prune).
#
# Extraction: scripts/extract-9.0-nta.sh unzips the four disks into a
# lower-cased staging area and runs the original INSTALL.SCR through
# scripts/lib/install_scr.py (--yes-all).  The tree is binb/ (wcl386,
# wlink, wlib, wmake) + bin/ (wcc386, dos4gw); it compiles + links + runs
# 32-bit DOS/4GW programs end to end (`wcl386 -l=dos4g`).
#
# Source media
# ------------
# archives/watcom-9.0/nt-alpha/WC90NTA1.ZIP .. WC90NTA4.ZIP — the four-disk BBS
# distribution, from Discmaster item 29624; an independent second copy exists at
# item 30011 and is byte-identical.
#
# Identity evidence: the file name decodes as "Watcom C 9.0 NT Alpha"; binaries
# are dated 1992-02-19; disk 1 carries INSTALL.EXE (34,416 B — the same
# installer as the 8.5 BBS set), WCC386.DOS (114,602 B), WCC386.OS2
# (302,231 B), WCC386P.WPK, WCCOPTS.DLL/.HPK and a README.NTA.  The set is
# exactly four disks; no WC90NTA5 exists.
#
# This 1992-02 build sits between 8.5 (1991) and the base 9.01 (May 1992).
# "NT" refers to the OS/2 2.x / Windows NT pre-release era of early 1992, not
# to a Windows NT host.
#
# Build:
#     podman build -t localhost/watcom-9.0-nta-dosemu2 \
#         -f containers/watcom-9.0-nta/dosemu2.Containerfile .
#
# Prerequisites:
#     - localhost/watcom-toolchain        (mtools + python + wpack/bpatch)
#     - localhost/watcom-dosemu2-runtime  (shared dosemu2 runtime base)

FROM localhost/watcom-toolchain:latest AS tree

ENV WATCOM_ROOT=/opt/watcom \
    WORK_DIR=/src

RUN --mount=type=bind,source=archives/watcom-9.0/nt-alpha,target=/archives/watcom-9.0/nt-alpha,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/extract-9.0-nta.sh /opt/watcom

FROM localhost/watcom-dosemu2-runtime AS base
COPY --from=tree /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="WATCOM C/386 9.0 NT Alpha" \
      org.opencontainers.image.description="WATCOM C/386 9.0 NT Alpha (1992-02) under dosemu2"
