# syntax=docker/dockerfile:1.4
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Watcom C/C++ 10.5 — wibo runtime image.
#
# Produces:
#     localhost/watcom-10.5-wibo        (binnt/ from the watcom-10.5-dosemu2 tree)
#     localhost/watcom-10.5a-wibo       (binnt/ from the watcom-10.5a-dosemu2 tree)
#
# Inherits whatever tree the source dosemu2 image carries; build that
# image with --build-arg PRUNE=0 first if you want the full tree here.
#
# Build:
#     podman build --target base -t localhost/watcom-10.5-wibo  \
#         -f containers/watcom-10.5/wibo.Containerfile .
#     podman build --target a    -t localhost/watcom-10.5a-wibo \
#         -f containers/watcom-10.5/wibo.Containerfile .

FROM localhost/watcom-10.5-dosemu2  AS watcom
FROM localhost/watcom-10.5a-dosemu2 AS watcom-a

FROM localhost/watcom-wibo-runtime AS base
COPY --from=watcom /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 10.5 (wibo)" \
      org.opencontainers.image.description="Watcom C/C++ 10.5 binnt/ under wibo"

# 10.5a — the c105_a patch also updates binnt/ (114 patched files), so the
# NT-hosted tools under wibo are genuine 10.5a.
FROM localhost/watcom-wibo-runtime AS a
COPY --from=watcom-a /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 10.5a (wibo)" \
      org.opencontainers.image.description="Watcom C/C++ 10.5a binnt/ under wibo"
