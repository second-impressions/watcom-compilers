# syntax=docker/dockerfile:1.4
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Watcom C/C++ 11.0 series — wibo runtime images.
#
# Produces:
#     localhost/watcom-11.0-wibo
#     localhost/watcom-11.0a-wibo
#     localhost/watcom-11.0b-wibo
#     localhost/watcom-11.0c-wibo
#
# Each inherits whatever tree its source dosemu2 image carries; build
# those with --build-arg PRUNE=0 first if you want full trees here.
#
# Build:
#     podman build --target base -t localhost/watcom-11.0-wibo  -f containers/watcom-11.0/wibo.Containerfile .
#     podman build --target a    -t localhost/watcom-11.0a-wibo -f containers/watcom-11.0/wibo.Containerfile .
#     podman build --target b    -t localhost/watcom-11.0b-wibo -f containers/watcom-11.0/wibo.Containerfile .
#     podman build --target c    -t localhost/watcom-11.0c-wibo -f containers/watcom-11.0/wibo.Containerfile .

FROM localhost/watcom-11.0-dosemu2  AS watcom-base
FROM localhost/watcom-11.0a-dosemu2 AS watcom-a
FROM localhost/watcom-11.0b-dosemu2 AS watcom-b
FROM localhost/watcom-11.0c-dosemu2 AS watcom-c

FROM localhost/watcom-wibo-runtime AS base
COPY --from=watcom-base /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 11.0 (wibo)" \
      org.opencontainers.image.description="Watcom C/C++ 11.0 binnt/ under wibo"

FROM localhost/watcom-wibo-runtime AS a
COPY --from=watcom-a /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 11.0a (wibo)" \
      org.opencontainers.image.description="Watcom C/C++ 11.0a binnt/ under wibo"

FROM localhost/watcom-wibo-runtime AS b
COPY --from=watcom-b /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 11.0b (wibo)" \
      org.opencontainers.image.description="Watcom C/C++ 11.0b binnt/ under wibo"

FROM localhost/watcom-wibo-runtime AS c
COPY --from=watcom-c /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 11.0c (wibo)" \
      org.opencontainers.image.description="Watcom C/C++ 11.0 + 11.0c update binnt/ under wibo"
