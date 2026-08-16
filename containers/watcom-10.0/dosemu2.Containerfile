# syntax=docker/dockerfile:1.4
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Watcom C/C++ 10.0 series — dosemu2 runtime images.
#
# Produces two runnable images:
#
#     localhost/watcom-10.0a-dosemu2        (10.0a, retail CD-ROM)
#     localhost/watcom-10.0b-dosemu2        (10.0a + APPLYB)
#
# Trees are pruned by default; pass --build-arg PRUNE=0 to ship the
# unmodified (full) tree under the same tags.
#
# The chain starts at 10.0a because WATCOM_C10A.ISO was pressed as a
# 10.0a disc from the start.
#
# Three-tier layout: tree -> tree-final -> shipping (COPY --from).
# See containers/watcom-9.5/dosemu2.Containerfile for the full
# rationale on the runtime base swap.
#
# Source media
# ------------
# archives/watcom-10.0/WATCOM_C10A.ISO — the retail CD-ROM.  It carries the
# installer (setup.exe + disk01/..disk62/), a pre-extracted tree under watcom/,
# a standalone A-level patch kit under a_level/, and bundled win32s/ and isv/.
#
# The disc was pressed as 10.0a from the start, despite shipping a_level/
# patches that raise 10.0 GA to 10.0a: the volume label is `WATCOM_C10A`, the
# on-disc readme welcomes you to "version 10.0a", the installer announces
# "version 10.0a", and watcom/binb/wcc386.exe is 541,364 bytes — the *output*
# size of a_level/ptch23.a, not its input.  That is why the chain here starts
# at 10.0a rather than GA.  (Two 10.0 ISO uploads exist on archive.org; the
# reasoning for keeping this one is in iso-identity.md, published with the
# Archive.org item.)
#
# archives/watcom-10.0/patches/c_b.zip — the 10.0a -> 10.0b cumulative patch
# (the Pentium FDIV workaround), from os2site.com.  Same shape as the other
# kits: a README.<X>, an APPLY<X>.BAT driver and PTCH<n>.<X> binary patches.
#
# c_a.zip (10.0 GA -> 10.0a) is archived but applies to nothing here, since the
# ISO is already at that level.  Two copies exist: the os2site c_a.zip (1,219
# patch files) and c_a.infobase.zip (1,273 files) recovered from the MAINT/C_CPP
# tree on the Watcom Products Infobase CDs — a strict superset of both the
# os2site copy and the ISO's own a_level/ (1,268).  The Infobase copy is the
# authoritative standalone A-level patch should anyone need it.
#
# Build
# -----
#     podman build --target base -t localhost/watcom-10.0a-dosemu2 -f containers/watcom-10.0/dosemu2.Containerfile .
#     podman build --target b    -t localhost/watcom-10.0b-dosemu2 -f containers/watcom-10.0/dosemu2.Containerfile .
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

# Mount the one artifact this stage reads rather than the whole release
# directory: scripts/fetch-sources.sh --filter derives the download set from
# these mounts, so a directory-wide mount would pull in every sibling artifact
# (the 10.0 GA tree and the A-level patch kits) that this image never touches.
RUN --mount=type=bind,source=archives/watcom-10.0/WATCOM_C10A.ISO,target=/_archives/WATCOM_C10A.ISO,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/extract-10.0a.sh /opt/watcom /_archives/WATCOM_C10A.ISO

FROM base-tree AS b-tree
RUN --mount=type=bind,source=archives/watcom-10.0/patches/c_b.zip,target=/_patches/c_b.zip,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/apply-patches-10.0.sh /opt/watcom b /_patches

# =============================================================================
# Final trees — pruned by default; --build-arg PRUNE=0 keeps the full tree.
# =============================================================================
FROM base-tree AS base-tree-final
ARG PRUNE=1
RUN --mount=type=bind,source=scripts/lib/prune-watcom-tree.sh,target=/tmp/prune.sh \
    if [ "$PRUNE" = "0" ]; then echo "prune: skipped (PRUNE=0, full tree)"; \
    else sh /tmp/prune.sh /opt/watcom; fi

FROM b-tree AS b-tree-final
ARG PRUNE=1
RUN --mount=type=bind,source=scripts/lib/prune-watcom-tree.sh,target=/tmp/prune.sh \
    if [ "$PRUNE" = "0" ]; then echo "prune: skipped (PRUNE=0, full tree)"; \
    else sh /tmp/prune.sh /opt/watcom; fi

# =============================================================================
# Shipping stages.
# =============================================================================
FROM localhost/watcom-dosemu2-runtime AS base
COPY --from=base-tree-final /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 10.0a" \
      org.opencontainers.image.description="Watcom C/C++ 10.0a under dosemu2"

FROM localhost/watcom-dosemu2-runtime AS b
COPY --from=b-tree-final /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 10.0b" \
      org.opencontainers.image.description="Watcom C/C++ 10.0a + patch level b (Pentium FDIV fix) under dosemu2"
