# syntax=docker/dockerfile:1.4
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Watcom C/C++ 9.5 series — wibo runtime images.
#
# Produces four images (one per patch level):
#
#     localhost/watcom-9.5-wibo
#     localhost/watcom-9.5a-wibo
#     localhost/watcom-9.5b-wibo
#     localhost/watcom-9.5c-wibo
#
# Same rationale as the dosemu2 side: 9.5 predates the bulk of what
# prune-watcom-tree.sh targets, so the 9.5 tree is shipped unmodified
# (no prune).  The image is built by overlaying /opt/watcom from the
# matching dosemu2 image onto the shared watcom-wibo-runtime base.
#
# Build:
#     podman build --target base   -t localhost/watcom-9.5-wibo  -f containers/watcom-9.5/wibo.Containerfile .
#     podman build --target a      -t localhost/watcom-9.5a-wibo -f containers/watcom-9.5/wibo.Containerfile .
#     podman build --target b      -t localhost/watcom-9.5b-wibo -f containers/watcom-9.5/wibo.Containerfile .
#     podman build --target c      -t localhost/watcom-9.5c-wibo -f containers/watcom-9.5/wibo.Containerfile .
#
# Prerequisites:
#     - localhost/watcom-wibo-runtime
#     - localhost/watcom-9.5{,a,b,c}-dosemu2

FROM localhost/watcom-9.5-dosemu2  AS watcom-base
FROM localhost/watcom-9.5a-dosemu2 AS watcom-a
FROM localhost/watcom-9.5b-dosemu2 AS watcom-b
FROM localhost/watcom-9.5c-dosemu2 AS watcom-c

FROM localhost/watcom-wibo-runtime AS base
COPY --from=watcom-base /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 9.5 (wibo)" \
      org.opencontainers.image.description="Watcom C/C++ 9.5 GA binnt/ under wibo" \
      org.opencontainers.image.source="https://github.com/second-impressions/watcom-compilers"

FROM localhost/watcom-wibo-runtime AS a
COPY --from=watcom-a /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 9.5a (wibo)" \
      org.opencontainers.image.description="Watcom C/C++ 9.5a binnt/ under wibo" \
      org.opencontainers.image.source="https://github.com/second-impressions/watcom-compilers"

FROM localhost/watcom-wibo-runtime AS b
COPY --from=watcom-b /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 9.5b (wibo)" \
      org.opencontainers.image.description="Watcom C/C++ 9.5b binnt/ under wibo" \
      org.opencontainers.image.source="https://github.com/second-impressions/watcom-compilers"

FROM localhost/watcom-wibo-runtime AS c
COPY --from=watcom-c /opt/watcom /opt/watcom
LABEL org.opencontainers.image.title="Watcom C/C++ 9.5c (wibo)" \
      org.opencontainers.image.description="Watcom C/C++ 9.5c binnt/ under wibo" \
      org.opencontainers.image.source="https://github.com/second-impressions/watcom-compilers"

