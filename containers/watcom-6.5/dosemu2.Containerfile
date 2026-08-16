# syntax=docker/dockerfile:1.4
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# WATCOM C 6.5 (1988) — dosemu2 runtime image.
#
# Produces:
#
#     localhost/watcom-6.5-dosemu2     (full /opt/watcom tree)
#
# Source: archives/watcom-6.5/Watcom C.ver.6.5.English.zip
# (eight plain floppy directories; old-dos.ru provenance).
# This is the earliest Watcom C release in the
# repository — a 16-bit IBM PC/DOS compiler that predates the 386 line.
# It ships WCC (compiler), WLINK, WLIB and the small/compact/medium/
# large/huge memory-model libraries.  C only: Watcom C++ did not arrive
# until 10.0, so there is no wpp here.
#
# EXPERIMENTAL / known issue (link blocked under dosemu2)
# ------------------------------------------------------
# The compiler runs and produces 16-bit OMF objects, but the LINK step
# fails: the 1988 WATCOM Library Manager 1.1 and WATCOM Linker 4.1 both
# reject the distribution's own libraries ("invalid object record" /
# "invalid object file attribute").  Those libraries are byte-perfect
# (sha256-identical to the source media) and structurally valid OMF, so
# this is a real-mode file-I/O incompatibility between these 1988 tools
# and dosemu2's FDPP, NOT a bad dump.  Compilation works; link/run does
# not.  This image is therefore NOT in the tests/ verification matrix
# and is kept as a preservation/experimental artifact.
#
# No prune for the 6.5 series
# ---------------------------
# The 6.5 tree has nothing the prune script targets; a single unmodified
# tag is shipped (same policy as 8.5 / 9.01 / 9.5).
#
# Extraction
# ----------
# scripts/extract-6.5.sh merges the eight DISK*/ trees into one staging
# directory and runs the original (plain `copy`-based) INSTALL.SCR
# through scripts/lib/install_scr.py.  Nothing is WPK-packed, so the
# toolchain image is used only for python / unzip.
#
# Shim & ENTRYPOINT
# -----------------
# The ENTRYPOINT is /usr/local/bin/watcom (scripts/shims/dosemu2-shim.sh).
# 6.5 has no wcl386 — only the 16-bit `wcl` driver in bin/ — which the
# shim auto-detects (it prefers wcl386 and falls back to wcl).  Typical
# invocation:
#
#     podman run --rm -v "$PWD:/src" localhost/watcom-6.5-dosemu2 \
#         wcl hello.c
#     podman run --rm -v "$PWD:/src" localhost/watcom-6.5-dosemu2 hello.exe
#
# Source media
# ------------
# archives/watcom-6.5/Watcom C.ver.6.5.English.zip — a two-disk install set
# (DISK1/, DISK2/) from old-dos.ru.  README.1ST self-identifies as "WATCOM C
# Optimizing Compiler and Tools V6.5, Copyright by WATCOM Systems Inc. 1984,
# 1988, IBM PC - DOS"; every payload binary is dated 1988-05-31.
#
# Unusually for this collection there is no WPK packing: the files sit plainly
# in a floppy-style directory layout.  DISK1 carries INSTALL.EXE, INSTALL.SCR,
# WCC.EXE, WCG.EXE and WCL.EXE; DISK2 carries the H/ header tree and the
# runtime and math libraries.
#
# Build
# -----
#     podman build -t localhost/watcom-6.5-dosemu2 \
#         -f containers/watcom-6.5/dosemu2.Containerfile .
#
# Prerequisites:
#     - localhost/watcom-toolchain        (python + unzip)
#     - localhost/watcom-dosemu2-runtime  (shared dosemu2 runtime base)

# =============================================================================
# Tree stage — extract on the toolchain image.
# =============================================================================
FROM localhost/watcom-toolchain:latest AS tree

ENV WATCOM_ROOT=/opt/watcom \
    WORK_DIR=/src

RUN --mount=type=bind,source=archives/watcom-6.5,target=/archives/watcom-6.5,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/extract-6.5.sh /opt/watcom

# =============================================================================
# Shipping stage — slim dosemu2 runtime + tree.
# =============================================================================
FROM localhost/watcom-dosemu2-runtime AS base
COPY --from=tree /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="WATCOM C 6.5" \
      org.opencontainers.image.description="WATCOM C 6.5 (1988, 16-bit DOS) under dosemu2"
