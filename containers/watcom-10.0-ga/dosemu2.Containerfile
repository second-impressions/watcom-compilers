# syntax=docker/dockerfile:1.4
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Watcom C/C++ 10.0 GA — dosemu2 runtime image.
#
# Produces:
#
#     localhost/watcom-10.0-ga-dosemu2        (pruned /opt/watcom tree)
#
# The prune runs by default.  Pass --build-arg PRUNE=0 to ship the
# unmodified (full) tree under the same tag.
#
# Why a separate 10.0-ga/ directory rather than a target in
# containers/watcom-10.0/ ?
#
# The 10.0 GA source is a pre-extracted install tree (Discmaster-sourced
# Sybase ZIP), whereas 10.0a/10.0b come from WATCOM_C10A.ISO with
# INSTALL.EXE-style extraction + APPLYB patching.  The two pipelines
# share nothing.
#
# Source
# ------
# `archives/watcom-10.0/discmaster/Sybase - Watcom C++ 10.0.zip` contains
# a top-level BIN/, BINB/, BINW/, BINNT/, SAMPLES/, ... tree.  10.0 GA
# identity is confirmed by BINB/wcc386.exe being 536,624 B (the
# unpatched input size of a_level/ptch23.a, not the 541,364-byte A-level
# output) and by file mtimes clustered around 1994-05-31 (the 10.0 GA
# release date).  See the Source media section below.
#
# Source media
# ------------
# archives/watcom-10.0/discmaster/Sybase - Watcom C++ 10.0.zip — a pre-extracted
# install tree (55 MiB, 489 files), from Discmaster item 43408 (a 2009
# compilation).  The original GA floppy set has never been recovered; this is
# the only surviving form of the GA release.
#
# Identity evidence that this is GA and not 10.0a:
#   * BINB/wcc386.exe is 536,624 bytes, dated 1994-05-31 — the *input* size to
#     a_level/ptch23.a, whose output (541,364 B) is what the 10.0a ISO ships.
#   * Every compiler binary (wcc, wcc386, wpp, wpp386, wasm, wlib, wlink,
#     wmake) is dated 1994-05-31, consistent with the mid-1994 GA ship date.
#   * BINNT/ holds the 7,680-byte NT loader stubs characteristic of this era,
#     not real compilers.
#   * SETVARS.BAT still points at C:\FICHEROS\WC10, a prior owner's install
#     path — this is a real installation that was zipped up, not a manufactured
#     archive.
#
# Build
# -----
#     podman build -t localhost/watcom-10.0-ga-dosemu2 -f containers/watcom-10.0-ga/dosemu2.Containerfile .
#
# Prerequisites:
#     - localhost/watcom-toolchain
#     - localhost/watcom-dosemu2-runtime

FROM localhost/watcom-toolchain:latest AS tree

ENV WATCOM_ROOT=/opt/watcom \
    WORK_DIR=/src

# Mount just the ZIP this stage reads; a directory-wide mount would make
# scripts/fetch-sources.sh --filter pull the 289 MB 10.0a ISO too, which this
# image never opens.
RUN --mount=type=bind,source=archives/watcom-10.0/discmaster,target=/_archives/discmaster,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/extract-prebuilt-zip.sh /opt/watcom \
        "/_archives/discmaster/Sybase - Watcom C++ 10.0.zip"

# Prune by default; --build-arg PRUNE=0 keeps the full tree.
FROM tree AS tree-final
ARG PRUNE=1
RUN --mount=type=bind,source=scripts/lib/prune-watcom-tree.sh,target=/tmp/prune.sh \
    if [ "$PRUNE" = "0" ]; then echo "prune: skipped (PRUNE=0, full tree)"; \
    else sh /tmp/prune.sh /opt/watcom; fi

FROM localhost/watcom-dosemu2-runtime AS base
COPY --from=tree-final /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 10.0 GA" \
      org.opencontainers.image.description="Watcom C/C++ 10.0 GA (1994-05-31) under dosemu2" \
      org.opencontainers.image.source="https://github.com/second-impressions/watcom-compilers"

