# Third-party media and components

The GNU Affero General Public License v3.0-or-later in `LICENSE` applies to
this repository's build scripts, Containerfiles, tests, and documentation. It
does not relicense third-party software downloaded or embedded by the builds.

## Watcom C/C++ distribution media

The historical Watcom/Powersoft/Sybase retail distributions are proprietary
binary releases. They are fetched from the preservation item
[`watcom-c-cpp-compilers-collection`](https://archive.org/details/watcom-c-cpp-compilers-collection)
and verified against `scripts/SHA256SUMS`.

The later Sybase Open Watcom Public License applies to the Open Watcom source
release, not automatically to these earlier retail distribution archives.
Users and image distributors are responsible for determining whether their use
and redistribution are permitted. This repository's AGPL-3.0 license does not
cover container layers containing those binaries — a built image is an
aggregate of separately licensed works, and the AGPL applies only to the parts
authored here.

## Published container images

The images at `ghcr.io/second-impressions/watcom-*` contain those proprietary
binaries. They are published for the same software-preservation reasons as the
Archive.org item they are built from, in good faith and without any claim to
ownership of the compiler itself. Copyright in Watcom C/C++ rests with the
successors-in-interest to Watcom/Sybase (Micro Focus / OpenText).

Pulling an image does not grant you a licence to the compiler. If you intend to
use it commercially, that is between you and the rights holder. Rights holders
may request removal, and such requests will be honoured.

## Runtime/build dependencies

- **dosemu2 / FDPP** — installed from the upstream dosemu2 Ubuntu PPA; their
  own licenses apply (dosemu2 is GPL-2.0-or-later, FDPP GPL-3.0).
- **wibo** — built from our fork at
  [`second-impressions/wibo`](https://github.com/second-impressions/wibo),
  pinned to an exact commit; it is upstream
  [`decompals/wibo`](https://github.com/decompals/wibo) plus a small
  eventually-upstreamable series. Upstream is **MIT** (Copyright 2022-2024
  Ash Wolf & Decompals) and the fork remains under those terms; this
  repository's AGPL does not extend to it.
- **Base images** — Ubuntu, Debian and Alpine, pulled by digest; each ships
  its own package licenses.

See [`SOURCES.md`](https://archive.org/details/watcom-c-cpp-compilers-collection) for artifact-by-artifact provenance.
