# syntax=docker/dockerfile:1.4
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Watcom C/C++ 9.5 series — dosemu2 runtime images.
#
# Produces four runnable images:
#
#     localhost/watcom-9.5-dosemu2    (9.5 GA, unpatched)
#     localhost/watcom-9.5a-dosemu2   (9.5 + APPLYA)
#     localhost/watcom-9.5b-dosemu2   (9.5a + APPLYB)
#     localhost/watcom-9.5c-dosemu2   (9.5b + APPLYC)
#
# Each patch level is a linear child of the previous tree stage so
# layer caching reuses extract + patch work across builds: rebuilding
# only 9.5c re-runs only APPLYC.
#
# No prune for the 9.5 series
# ---------------------------
# 9.5 predates the sdk/, samples/, vp/, mfc/, som/, and big binw/
# IDE-help-catalogue content that the prune script targets in 10.x
# and 11.x trees.  Empirically prune-watcom-tree.sh only finds ~9 MB
# to drop in a 9.5 tree (binp/, src/, novh/, nlm/, and a handful of
# .hlp files in binw/), which is under 4 % of the resulting image.
# So these images just ship the unmodified tree.  The 10.x / 11.x
# images run the prune by default (their delta is 30-320 MB) and
# expose a --build-arg PRUNE=0 escape hatch for the full tree.
#
# Shim & ENTRYPOINT
# -----------------
# The container's ENTRYPOINT is `/usr/local/bin/watcom`, a small shim
# (scripts/shims/dosemu2-shim.sh) that wires up a DOS environment with
# /opt/watcom as the Watcom tree and /src (bind-mount point) as the
# DOS current drive.  Typical invocation:
#
#     podman run --rm -v "$PWD:/src" localhost/watcom-9.5a-dosemu2 \
#         wcl386 -l=dos4g hello.c
#
# Or, for an interactive DOS prompt (S-Lang terminal over stdio):
#
#     podman run --rm -it -v "$PWD:/src" localhost/watcom-9.5a-dosemu2
#
# Layout (three-tier)
# -------------------
# 1. Tree stages           extract + patch on `watcom-toolchain`
# 2. Pruned-tree stages    run prune-watcom-tree.sh on each tree
# 3. Shipping stages       `watcom-dosemu2-runtime` + COPY --from tree
#
# Steps 1 and 2 run on the toolchain image (dosemu2 + bpatch + mtools
# + python + libarchive), which is heavy.  Step 3 derives from the
# slim runtime image (dosemu2 + bash + shim only), so the final image
# does not carry the extractor tools at all.  This is why the shipping
# tags are smaller than the toolchain image alone.
#
# Layer hygiene
# -------------
# Archive files and scripts are made available to the extract RUNs
# via `--mount=type=bind` build-time bind mounts, so no archive data
# lands in any image layer.  The COPY --from pattern in the shipping
# stages writes only the post-prune (or full) /opt/watcom into the
# final layer chain.
#
# Source media
# ------------
# archives/watcom-9.5/floppies/ — twenty 1.44 MB FAT12 images (OEM-ID
# `WINIMAGE`) from https://archive.org/details/Watcom_C_9.5, covering three
# sets:
#
#   W9516_01-04   Watcom C/C++16, the 16-bit compiler (DOS, OS/2 1.x, Win 3.x)
#   W9532_01-10   Watcom C/C++32, the 32-bit compiler.  Disks 7 and 8 carry the
#                 NT-hosted tools (wcc386.nt, wpp386.nt, wlink.nt, ...), which
#                 is what makes the 9.5 wibo images possible.
#   OS2TK_1-6     the optional OS/2 Toolkit add-on, not needed for DOS or Win32
#                 targets and not used by these builds
#
# Nothing on the floppies is directly usable: every compiler, library and tool
# is WPK-packed (magic 03 24 01 01).  Extensions like .DOS, .NT, .OS2 and .WIN
# name the *target*, not the format — WCC386.NT is a WPK archive whose payload
# is a Win32 PE.  The canonical unpacker, INSTALL.EXE, is a hybrid DOS/OS-2 1.x
# NE binary; these builds instead run the original wpack.exe under dosemu2 (see
# containers/toolchain/).
#
# W9516's INSTALL.SCR calls itself "Installation procedure for WATCOM C/C++16
# Delta Pack", but it mkdir's a fresh tree and unpacks a complete set from
# scratch — "Delta Pack" was marketing for the 9.5 release, not an overlay on
# an earlier version.
#
# archives/watcom-9.5/old-dos/ holds an independent copy of the 32-bit set
# whose Watcom payload is byte-identical but which lacks the injected macOS
# .fseventsd metadata the archive.org images carry.  The build inputs are left
# unchanged; the cleaner copy is preserved for reference.
#
# Patches (archives/watcom-9.5/patches/)
# -------------------------------------
# Three cumulative levels per product line: c16_{a,b,c}.zip and
# c32_{a,b,c}.zip, from archive.org; c32_b and c32_c are also on os2site.com
# and byte-identical there.  The 16- and 32-bit patches at each letter carry
# the same fixes — the README.B files inside c16_b and c32_b are byte-identical,
# as are the README.C files — and differ only in which binaries they touch.
# Only the 32-bit line is applied here.
#
# Each ZIP holds a README.<X>, an APPLY<X>.BAT driver and a set of PTCH<n>.<X>
# binary patch files.  Note that the a-level patch updates BPATCH.EXE itself,
# which is why apply-patches-9.5.sh substitutes a private copy of the tool
# before running the batch.
#
# Build
# -----
#     podman build --target base   -t localhost/watcom-9.5-dosemu2  -f containers/watcom-9.5/dosemu2.Containerfile .
#     podman build --target a      -t localhost/watcom-9.5a-dosemu2 -f containers/watcom-9.5/dosemu2.Containerfile .
#     podman build --target b      -t localhost/watcom-9.5b-dosemu2 -f containers/watcom-9.5/dosemu2.Containerfile .
#     podman build --target c      -t localhost/watcom-9.5c-dosemu2 -f containers/watcom-9.5/dosemu2.Containerfile .
#
# Prerequisites
# -------------
#     - localhost/watcom-toolchain          (extract + patch tooling)
#     - localhost/watcom-dosemu2-runtime    (shared dosemu2 runtime base)

# =============================================================================
# Tree-producing stages — extract + patch.  These run on the toolchain
# image (dosemu2 + bpatch + mtools + Python + libarchive) which has the
# helpers needed by the extract / apply-patches scripts.  Each stage
# produces a complete, unmodified /opt/watcom for one patch level.
# =============================================================================
FROM localhost/watcom-toolchain:latest AS base-tree

ENV WATCOM_ROOT=/opt/watcom \
    WORK_DIR=/src

RUN --mount=type=bind,source=archives/watcom-9.5/floppies,target=/_floppies,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/extract-9.5.sh /opt/watcom /_floppies

FROM base-tree AS a-tree
RUN --mount=type=bind,source=archives/watcom-9.5/patches,target=/_patches,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/apply-patches-9.5.sh /opt/watcom a /_patches

FROM a-tree AS b-tree
RUN --mount=type=bind,source=archives/watcom-9.5/patches,target=/_patches,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/apply-patches-9.5.sh /opt/watcom b /_patches

FROM b-tree AS c-tree
RUN --mount=type=bind,source=archives/watcom-9.5/patches,target=/_patches,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/apply-patches-9.5.sh /opt/watcom c /_patches

# =============================================================================
# Shipping stages — one per patch level, unmodified tree.
# =============================================================================
FROM localhost/watcom-dosemu2-runtime AS base
COPY --from=base-tree /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 9.5" \
      org.opencontainers.image.description="Watcom C/C++ 9.5 GA under dosemu2"

FROM localhost/watcom-dosemu2-runtime AS a
COPY --from=a-tree /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 9.5a" \
      org.opencontainers.image.description="Watcom C/C++ 9.5 GA + patch level a under dosemu2"

FROM localhost/watcom-dosemu2-runtime AS b
COPY --from=b-tree /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 9.5b" \
      org.opencontainers.image.description="Watcom C/C++ 9.5a + patch level b under dosemu2"

FROM localhost/watcom-dosemu2-runtime AS c
COPY --from=c-tree /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 9.5c" \
      org.opencontainers.image.description="Watcom C/C++ 9.5b + patch level c under dosemu2"
