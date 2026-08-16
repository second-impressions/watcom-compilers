# syntax=docker/dockerfile:1.4
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Watcom C/C++ 10.6a — dosemu2 runtime image.
#
# Produces:
#
#     localhost/watcom-10.6a-dosemu2        (pruned /opt/watcom tree)
#
# The prune runs by default.  Pass --build-arg PRUNE=0 to ship the
# unmodified (full) tree under the same tag.
#
# Source: "Sybase - Watcom C++ 10.6a.zip" (Discmaster item 43408).
# The compilers live in binw/ (Windows-hosted, LX format with DOS4GW
# stub); the shim auto-detects binw/ because that is where wcl386.exe
# lives.
#
# Source media
# ------------
# archives/watcom-10.6a/Sybase - Watcom C++ 10.6a.zip — the full installer
# package (138 MiB), not a pre-extracted tree, from Discmaster.
#
# 10.6a is 10.6 GA plus updated linkers.  Its compilers are byte-identical to
# the GA disc archived under archives/watcom-10.6/; only WLINK.EXE differs, and
# the 10.6a copies are dated 1997-01-10 against the GA's uniform 1996-02-29:
#
#   BINW/WLINK.EXE    279,616 (1997-01-10)  vs 277,196 (1996-02-29) in GA
#   BINNT/WLINK.EXE   266,895 (1997-01-10)  vs 266,843 (1996-02-29)
#   BINP/WLINK.EXE    249,159 (1997-01-10)  vs 249,043 (1996-02-29)
#
# The README.TXT still says "version 10.6"; the disc's own filename and the
# 1997 linker dates are what identify it as 10.6a.  See cross-verification.md,
# published with the Archive.org item.
#
# Build
# -----
#     podman build -t localhost/watcom-10.6a-dosemu2 -f containers/watcom-10.6a/dosemu2.Containerfile .
#
# Prerequisites:
#     - localhost/watcom-toolchain
#     - localhost/watcom-dosemu2-runtime

FROM localhost/watcom-toolchain:latest AS tree

ENV WATCOM_ROOT=/opt/watcom \
    WORK_DIR=/src

RUN --mount=type=bind,source=archives/watcom-10.6a,target=/_archives,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/extract-prebuilt-zip.sh /opt/watcom \
        "/_archives/Sybase - Watcom C++ 10.6a.zip"

# Prune by default; --build-arg PRUNE=0 keeps the full tree.
FROM tree AS tree-final
ARG PRUNE=1
RUN --mount=type=bind,source=scripts/lib/prune-watcom-tree.sh,target=/tmp/prune.sh \
    if [ "$PRUNE" = "0" ]; then echo "prune: skipped (PRUNE=0, full tree)"; \
    else sh /tmp/prune.sh /opt/watcom; fi

FROM localhost/watcom-dosemu2-runtime AS base
COPY --from=tree-final /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 10.6a" \
      org.opencontainers.image.description="Watcom C/C++ 10.6a under dosemu2"
