# watcom-toolchain container image

An intermediate container image providing the two Watcom tools this
repository needs for extracting and patching archive artifacts, plus a
dosemu2 runtime to execute them. Used as the base for every
version-specific extract stage.

## What's inside

| Path | Source | Format | Purpose |
|---|---|---|---|
| `/opt/watcom-tools/wpack.exe` | `archives/watcom-10.0/WATCOM_C10A.ISO` → `DISK01/WPACK.EXE` | MZ real-mode DOS | Decompress Watcom WPK archives |
| `/opt/watcom-tools/bpatch.exe` | `archives/watcom-9.5/floppies/W9532_03.img` → `BPATCH.WPK` (unpacked at build time) | NE OS/2 1.x hybrid with functional DOS stub | Apply Watcom binary patch files |
| `/usr/bin/dosemu` | `ppa:dosemu2/ppa` | x86-64 ELF | Headless real-mode DOS execution |
| `/usr/bin/mcopy`, `mdir`, … | Ubuntu `mtools` | x86-64 ELF | Read FAT12 floppy images |
| `/usr/bin/bsdtar` | Ubuntu `libarchive-tools` | x86-64 ELF | Read ISO 9660 without loopback mount |
| `/usr/bin/python3` | Ubuntu `python3` | — | Run helper scripts |

## Why this approach

The `archives/` directory already contains the exact tools that
originally created and applied the files we need to process:

- **WPK format** is Watcom's own "Install Archiver 1.3" format (the
  banner even says so). The program that created every `.WPK`, `.DOS`,
  `.NT`, `.OS2`, `.WIN` file on the 9.5 floppies and every `packNNNN`
  file on the 10.0a ISO is `wpack.exe`. One copy lives on the 10.0a
  installer disk at `DISK01/WPACK.EXE` as a plain MZ real-mode DOS
  executable — no DOS extender, no OS/2 hybrid, just a classic 16-bit
  DOS `.EXE`.

- **Watcom binary patches** (the `.A` / `.B` / `.C` / `ptchN.a` files
  in every patch ZIP and in the ISO's `a_level/` directory) are applied
  by `bpatch.exe`. The 9.5 installer ships a copy of it on disk 3 of
  the 32-bit set, packed as `BPATCH.WPK`. Once unpacked it is a 47 KB
  Watcom BPATCH 1.3 executable.

The bootstrap is therefore trivial:

1. Copy `wpack.exe` out of the ISO directly (ISO 9660 is a public
   filesystem, `bsdtar` reads it natively without loopback mount).
2. Use that `wpack.exe` under dosemu2 to unpack `BPATCH.WPK` from
   `W9532_03.img`, yielding `bpatch.exe`.
3. Ship both tools in `/opt/watcom-tools/` and let dosemu2 execute them
   at runtime.

This replaces an earlier design that built Open Watcom 2.0 from source
inside the container (30–90 minutes of wall time, blocked by an
undocumented orphan project entry for `wpack` in the OW 2.0 build
system and the absence of a Linux host build for `bpatch` entirely).
The current approach takes under a minute and uses the actual
contemporaneous Watcom tools rather than modern reimplementations.

## Why dosemu2 (not DOSBox)

- `dosemu2` has a `-dumb` mode that wires DOS stdio through to the
  container's stdin/stdout without opening an SDL window or curses
  terminal. Perfect for batch extraction inside a `RUN` layer.
- Upstream maintains an official Ubuntu PPA
  (`ppa:dosemu2/ppa`), so the install is one-line and reproducible.
- The `-K` and `-E` flags together map a Linux directory as the
  current DOS drive and run a single DOS command line, exactly the
  interface `scripts/build-toolchain.sh` needs.

DOSBox is oriented toward interactive use and needs workarounds
(SDL dummy drivers, hand-written `.conf` files) to run headless for
batch workloads.

## Reproducibility

- **Ubuntu base image** is pinned by manifest digest (`sha256:…`) in
  the `FROM` line, not by the mutable `24.04` tag. Update with
  `podman pull docker.io/library/ubuntu:24.04 && podman inspect …   --format '{{index .RepoDigests 0}}'`.
- **dosemu2 and its dependencies** are installed from `ppa:dosemu2/ppa`
  without version pinning. The PPA rotates older snapshot builds out
  every few weeks, so pinning would break this build on a regular
  basis for no real reproducibility benefit. The PPA is maintained by
  dosemu2 upstream; trust is rooted in the PPA's signing key.
- **Archive source files** (the 10.0a ISO and the W9532_03 floppy
  image) are downloaded by `scripts/fetch-sources.sh`. Their SHA256 hashes
  are recorded in `scripts/SHA256SUMS`, and the fetcher refuses to install
  bytes that do not match.
- **Extracted Watcom tools** (`wpack.exe`, `bpatch.exe`) are not
  hash-verified either. The extraction is deterministic and the
  source archives are already trusted, so a post-extraction hash
  check would be circular.

## Build

```bash
# From the repository root (context includes archives/ and scripts/)
podman build -t localhost/watcom-toolchain:latest \
  -f containers/toolchain/Containerfile .
```

Expected output during the `RUN /usr/local/bin/build-toolchain.sh` step:

```
[build-toolchain] Step 1/3: extracting wpack.exe from /archives/watcom-10.0/WATCOM_C10A.ISO
[build-toolchain]   wpack.exe installed (66694 bytes)
[build-toolchain] Step 2/3: extracting BPATCH.WPK from /archives/watcom-9.5/floppies/W9532_03.img
[build-toolchain]   BPATCH.WPK size: 31467 bytes
[build-toolchain] Step 3/3: unpacking BPATCH.WPK via dosemu2
WATCOM Install Archiver Version 1.3
Unpacking file 'bpatch.exe'
[build-toolchain]   bpatch.exe installed (47074 bytes)
[build-toolchain] Smoke test: running wpack.exe and bpatch.exe under dosemu2
[build-toolchain]   wpack output:
Usage: wpack [-?acdklpqr] [-mNNNN] [-tDATE TIME] arcfile @filename files...
[build-toolchain]   bpatch output:
BPATCH Version 1.3
Usage: F:\BPATCH.EXE {-p} {-q} {-b} <file>
```

Final image size: ~730 MB (dominated by the dosemu2 runtime, FreeDOS,
FDPP, and SDL shared libraries — the two Watcom tools together are
under 120 KB).

## Interactive smoke test

```bash
podman run --rm -it localhost/watcom-toolchain:latest bash

# Inside the container:
ls -la /opt/watcom-tools/

# Run wpack directly
cd /tmp && mkdir dos && cd dos
cp /opt/watcom-tools/wpack.exe .
dosemu -dumb -quiet -K "$PWD" -E "wpack.exe -?"
```

## Downstream usage

Each version-specific extract stage starts with:

```
FROM localhost/watcom-toolchain:latest AS extract
```

and then COPYs the version's archives in (`archives/watcom-9.5/…` or
`archives/watcom-10.0/…`), along with the relevant extract script
(`scripts/extract-9.5.sh` or `scripts/extract-10.0a.sh`).
The extract scripts invoke `wpack.exe` and `bpatch.exe` through the
same `dosemu -dumb -K … -E …` pattern as the toolchain bootstrap.
