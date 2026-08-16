# syntax=docker/dockerfile:1.4
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Watcom C/C++ 10.0 series — wibo runtime images.
#
# Produces:
#     localhost/watcom-10.0a-wibo
#     localhost/watcom-10.0b-wibo
#
# Each inherits whatever tree its source dosemu2 image carries; build
# those with --build-arg PRUNE=0 first if you want full trees here.
#
# Build:
#     podman build --target base -t localhost/watcom-10.0a-wibo -f containers/watcom-10.0/wibo.Containerfile .
#     podman build --target b    -t localhost/watcom-10.0b-wibo -f containers/watcom-10.0/wibo.Containerfile .
#
# Prerequisites:
#     - localhost/watcom-wibo-runtime
#     - localhost/watcom-10.0{a,b}-dosemu2

FROM localhost/watcom-10.0a-dosemu2 AS watcom-base
FROM localhost/watcom-10.0b-dosemu2 AS watcom-b

FROM localhost/watcom-wibo-runtime AS base
COPY --from=watcom-base /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 10.0a (wibo)" \
      org.opencontainers.image.description="Watcom C/C++ 10.0a binnt/ under wibo"

FROM localhost/watcom-wibo-runtime AS b
COPY --from=watcom-b /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 10.0b (wibo)" \
      org.opencontainers.image.description="Watcom C/C++ 10.0b binnt/ under wibo"
