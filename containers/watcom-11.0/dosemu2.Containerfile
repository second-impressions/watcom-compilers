# syntax=docker/dockerfile:1.4
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Watcom C/C++ 11.0 series — dosemu2 runtime images.
#
# Produces four images:
#
#     localhost/watcom-11.0-dosemu2    (11.0, from Discmaster pre-extracted tree)
#     localhost/watcom-11.0a-dosemu2   (11.0a, from the WinWorld ISO)
#     localhost/watcom-11.0b-dosemu2   (11.0b, from WinWorld ISO — final
#                                       commercial Watcom release)
#     localhost/watcom-11.0c-dosemu2   (11.0 + 11.0c update overlay)
#
# Trees are pruned by default; pass --build-arg PRUNE=0 to ship the
# unmodified (full) tree under the same tags.
#
# 11.0c is not a standalone install — it is an update package containing
# replacement binaries for binw/, binp/, and binnt/ only. The update stage
# overlays those replacements onto the 11.0 base by unzipping the 11.0c ZIP
# over the existing /opt/watcom tree (any files in the update package
# overwrite their 11.0 counterparts; no patching required).
#
# 11.0b is a full retail CD-ROM ISO; its tree is flat (no WPK packs) so we
# just walk the ISO 9660 filesystem and copy every file. The ISO has a
# non-compliant directory record near one extent boundary that causes
# strict readers (bsdtar, 7z, xorriso, pycdlib) to bail, so extraction
# goes through scripts/lib/iso_extract.py — a small tolerant ISO 9660
# walker that reads the whole tree in one pass.
#
# One known bug in 11.0b: its binw/wlink.exe (320 631 bytes, dated
# 1998-02-24) crashes at startup under dosemu2 with a page fault at
# EIP 0x39BA inside its own protected-mode body, before main(). Every
# argument set reproduces the same crash. The 11.0 and 11.0c wlink.exe
# from the same family both run fine in the identical environment, and
# dos4gw.exe is byte-identical between 11.0 and 11.0b — the regression
# is isolated to this one binary. We overlay the 11.0c (Sybase 2002-08)
# wlink.exe on top of the 11.0b tree as a one-file surgical patch; all
# other 11.0b binaries, headers, libraries and samples remain unchanged.
# The replacement wlink prints "WATCOM Linker Version 11.0 ... 1985,
# 2002" when running, so it is not silently hidden.
#
# Sources:
#   11.0  : "Sybase - Watcom C++ 11.0.zip" (Discmaster item 43408)
#   11.0b : archives/watcom-11.0b/WATCOM_C11B.iso (WinWorld)
#   11.0c : "Sybase - Watcom C++ 11.0c Update.zip" (Discmaster item 43408)
#
# Compilers live in BINW/ (Windows-hosted, LX format with DOS4GW stub).
#
# Two-tier layout: `*-tree` stages do extract+overlay, shipping stages
# (`base`, `b`, `c`) add only the shim on top. See watcom-9.5
# Containerfile for the full rationale. Note that 11.0b's tree stage
# does NOT derive from base-tree (different ISO, different extractor).
#
# Source media
# ------------
# 11.0   archives/watcom-11.0/Sybase - Watcom C++ 11.0.zip — a pre-extracted
#        install tree (250 MiB, 18,658 files) from Discmaster.  Compiler
#        binaries are dated 1996-02-10; BINW/WCC386.EXE is 653,342 B; the
#        README.TXT welcomes you to "version 11.0".  Its installer executables
#        carry a later 2003-03-12 repackaging date.  A retail CD image
#        (WATCOMC_110.iso) is archived as an independent copy with confirmed
#        identical binaries; the ZIP is what the build consumes.
#
#        The ZIP also carries the Microsoft Win32 SDK (SDK/, ~14,000 files,
#        1997-02-10) that Sybase bundled with the product.  The prune drops it.
#
# 11.0a  archives/watcom-11.0a/WatcomC11a.iso — WinWorld CD image, volume label
#        `WATCOMC110A`, matching the EMS Professional Software identification
#        table for the 11.0a pressing.  Binaries are dated 1997-08-28/29,
#        matching the 29/08/97 README date EMS recorded.  The whole 11.0 line
#        shares one README banner ("version 11.0"), so the disc label and the
#        timestamps are the discriminator.  An independent OS/2-hosted copy
#        exists as os2site's watcomos2.zip.
#
# 11.0b  archives/watcom-11.0b/WATCOM_C11B.iso — WinWorld CD image, volume label
#        `WATCOM_C11B`, README.TXT and every binary dated 1998-02-24, which
#        confirms the whole tree is at the 11.0b level rather than a 11.0 base
#        with a patch applied.  BINW/WCC386.EXE is 660,850 B.
#
# 11.0c  archives/watcom-11.0/patches/Sybase - Watcom C++ 11.0c Update.zip — an
#        update package (47 MiB) of replacement binaries dated 2002-08-27,
#        organised by host as binp/, binw/ and binnt/ each with a dll/
#        subdirectory, applied by copying over an installed 11.0.  This is the
#        final commercial release of Watcom C/C++; Sybase open-sourced the
#        compiler as Open Watcom 1.0 a few months later, in January 2003.
#
# Build
# -----
#     podman build --target base -t localhost/watcom-11.0-dosemu2  \
#         -f containers/watcom-11.0/dosemu2.Containerfile .
#     podman build --target a    -t localhost/watcom-11.0a-dosemu2 \
#         -f containers/watcom-11.0/dosemu2.Containerfile .
#     podman build --target b    -t localhost/watcom-11.0b-dosemu2 \
#         -f containers/watcom-11.0/dosemu2.Containerfile .
#     podman build --target c    -t localhost/watcom-11.0c-dosemu2 \
#         -f containers/watcom-11.0/dosemu2.Containerfile .

# =============================================================================
# Tree-producing stages.  Each one produces a complete /opt/watcom for
# one release level; they run on the heavy toolchain image because
# extract-prebuilt-zip.sh / iso_extract.py / unzip live there.
# =============================================================================
FROM localhost/watcom-toolchain:latest AS base-tree

ENV WATCOM_ROOT=/opt/watcom \
    WORK_DIR=/src

RUN --mount=type=bind,source=archives/watcom-11.0,target=/_archives,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/extract-prebuilt-zip.sh /opt/watcom \
        "/_archives/Sybase - Watcom C++ 11.0.zip"

FROM localhost/watcom-toolchain:latest AS b-tree

ENV WATCOM_ROOT=/opt/watcom \
    WORK_DIR=/src

RUN --mount=type=bind,source=archives/watcom-11.0b,target=/_archives,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    python3 /_scripts/lib/iso_extract.py \
        /_archives/WATCOM_C11B.iso /opt/watcom --lowercase

# Overlay only binw/wlink.exe from the 11.0c update (the 11.0b shipped
# wlink crashes at startup under dosemu2; all other binaries are fine).
RUN --mount=type=bind,source=archives/watcom-11.0/patches,target=/_archives,ro \
    unzip -jo "/_archives/Sybase - Watcom C++ 11.0c Update.zip" \
          "binw/wlink.exe" -d /opt/watcom/binw/

# 11.0a retail CD-ROM (WinWorld, vol WATCOMC110A, 1997-08-29).  Same flat
# ISO layout as 11.0b; extracted with the tolerant ISO 9660 walker for
# consistency with the rest of the 11.0 family.  Unlike 11.0b, the 11.0a
# binw/wlink.exe (367 815 B, "Version 11.0") runs fine under dosemu2, so
# no overlay is needed — this stage is a plain extraction.
FROM localhost/watcom-toolchain:latest AS a-tree

ENV WATCOM_ROOT=/opt/watcom \
    WORK_DIR=/src

RUN --mount=type=bind,source=archives/watcom-11.0a,target=/_archives,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    python3 /_scripts/lib/iso_extract.py \
        /_archives/WatcomC11a.iso /opt/watcom --lowercase

FROM base-tree AS c-tree
RUN --mount=type=bind,source=archives/watcom-11.0/patches,target=/_archives,ro \
    --mount=type=bind,source=scripts,target=/_scripts,ro \
    /_scripts/extract-prebuilt-zip.sh /opt/watcom \
        "/_archives/Sybase - Watcom C++ 11.0c Update.zip"

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

FROM a-tree AS a-tree-final
ARG PRUNE=1
RUN --mount=type=bind,source=scripts/lib/prune-watcom-tree.sh,target=/tmp/prune.sh \
    if [ "$PRUNE" = "0" ]; then echo "prune: skipped (PRUNE=0, full tree)"; \
    else sh /tmp/prune.sh /opt/watcom; fi

FROM c-tree AS c-tree-final
ARG PRUNE=1
RUN --mount=type=bind,source=scripts/lib/prune-watcom-tree.sh,target=/tmp/prune.sh \
    if [ "$PRUNE" = "0" ]; then echo "prune: skipped (PRUNE=0, full tree)"; \
    else sh /tmp/prune.sh /opt/watcom; fi

# =============================================================================
# Shipping stages.
# =============================================================================
FROM localhost/watcom-dosemu2-runtime AS base
COPY --from=base-tree-final /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 11.0" \
      org.opencontainers.image.description="Watcom C/C++ 11.0 under dosemu2" \
      org.opencontainers.image.source="https://github.com/second-impressions/watcom-compilers"

FROM localhost/watcom-dosemu2-runtime AS b
COPY --from=b-tree-final /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 11.0b" \
      org.opencontainers.image.description="Watcom C/C++ 11.0b (final commercial release) under dosemu2" \
      org.opencontainers.image.source="https://github.com/second-impressions/watcom-compilers"

FROM localhost/watcom-dosemu2-runtime AS a
COPY --from=a-tree-final /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 11.0a" \
      org.opencontainers.image.description="Watcom C/C++ 11.0a (1997) under dosemu2" \
      org.opencontainers.image.source="https://github.com/second-impressions/watcom-compilers"

FROM localhost/watcom-dosemu2-runtime AS c
COPY --from=c-tree-final /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 11.0c" \
      org.opencontainers.image.description="Watcom C/C++ 11.0 + 11.0c update under dosemu2" \
      org.opencontainers.image.source="https://github.com/second-impressions/watcom-compilers"

