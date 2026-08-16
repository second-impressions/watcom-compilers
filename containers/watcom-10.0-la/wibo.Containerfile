# syntax=docker/dockerfile:1.4
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Watcom C/C++ 10.0 LA — wibo runtime image.
#
# Produces:
#     localhost/watcom-10.0-la-wibo        (binnt/ from the watcom-10.0-la-dosemu2 tree)
#
# Inherits whatever tree the source dosemu2 image carries; build that
# image with --build-arg PRUNE=0 first if you want the full tree here.
#
# Build:
#     podman build -t localhost/watcom-10.0-la-wibo -f containers/watcom-10.0-la/wibo.Containerfile .

FROM localhost/watcom-10.0-la-dosemu2 AS watcom

FROM localhost/watcom-wibo-runtime AS base
COPY --from=watcom /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 10.0 LA (wibo)" \
      org.opencontainers.image.description="Watcom C/C++ 10.0 LA binnt/ under wibo"
