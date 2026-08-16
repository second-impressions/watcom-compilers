# syntax=docker/dockerfile:1.4
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Watcom C/C++ 10.6 (GA, 1996) — dosemu2 runtime image.
#
# Produces:
#
#     localhost/watcom-10.6-dosemu2        (pruned /opt/watcom tree)
#
# The prune runs by default.  Pass --build-arg PRUNE=0 to ship the
# unmodified (full) tree under the same tag.
#
# Source: archives/watcom-10.6/WATCOM_C106.iso (retail CD-ROM, GA).
#
# 10.6 GA vs 10.6a
# ----------------
# 10.6a is byte-identical to 10.6 GA except for the linkers: the compilers
# (WCC386/WPP386) and every library/tool are the same; only the three
# WLINK.EXE binaries differ (GA = 1996-02-29, 10.6a = 1997-01-10 "linker
# corrections for Win9x/NT").  A full tree-vs-tree hash comparison confirms
# the 3 linkers are the ONLY differing common files.  This image is the GA
# level (1996 linkers); the watcom-10.6a images carry the 1997 linkers.
# See cross-verification.md in the Archive.org item.
#
# Like 10.5, the ISO stores its install tree under DISKIMGS/, packed in the
# Watcom WPK v1.1 format; extraction is done entirely in Python by
# scripts/lib/wpack_decode.py driven by scripts/lib/setup_inf_manifest.py
# (SETUP.INF is at DISKIMGS/DISK01/SETUP.INF).  Compilers live under binw/.
#
# Source media
# ------------
# archives/watcom-10.6/WATCOM_C106.iso — the 10.6 GA retail CD-ROM.  The same
# disc is also archived as an Alcohol raw dump (.mdf/.mds/.log) for preservation;
# the build uses the ISO.
#
# 10.6 GA vs 10.6a: the two releases differ only in the linker.  10.6a's sole
# documented change is "linker corrections for Win9x/NT and Visual Programmer
# fixes", and that is exactly what separates the media — the compilers are
# byte-identical and only WLINK.EXE differs:
#
#   BINW/WCC386.EXE   567,698 (1996-02-29)  identical in both
#   BINW/WPP386.EXE   843,350 (1996-02-29)  identical in both
#   BINW/WLINK.EXE    277,196 (1996-02-29)  vs 279,616 (1997-01-10) in 10.6a
#   BINNT/WLINK.EXE   266,843 (1996-02-29)  vs 266,895 (1997-01-10)
#   BINP/WLINK.EXE    249,043 (1996-02-29)  vs 249,159 (1997-01-10)
#
# The uniform 1996-02-29 date across every binary here is the signature of a
# single GA build.  Both discs' README.TXT still say "version 10.6" — Sybase
# never bumped the banner for the "a" update — which is what conflated the two
# for years.  The full tree-vs-tree comparison is in cross-verification.md,
# published with the Archive.org item.
#
# Build:
#     podman build -t localhost/watcom-10.6-dosemu2 -f containers/watcom-10.6/dosemu2.Containerfile .
#
# Prerequisites:
#     - localhost/watcom-toolchain
#     - localhost/watcom-dosemu2-runtime

FROM localhost/watcom-toolchain:latest AS tree

ENV WATCOM_ROOT=/opt/watcom \
    WORK_DIR=/src

RUN --mount=type=bind,source=archives/watcom-10.6,target=/archives/watcom-10.6,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/extract-10.6.sh /opt/watcom

# Prune by default; --build-arg PRUNE=0 keeps the full tree.
FROM tree AS tree-final
ARG PRUNE=1
RUN --mount=type=bind,source=scripts/lib/prune-watcom-tree.sh,target=/tmp/prune.sh \
    if [ "$PRUNE" = "0" ]; then echo "prune: skipped (PRUNE=0, full tree)"; \
    else sh /tmp/prune.sh /opt/watcom; fi

FROM localhost/watcom-dosemu2-runtime AS base
COPY --from=tree-final /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 10.6" \
      org.opencontainers.image.description="Watcom C/C++ 10.6 GA (1996) under dosemu2"
