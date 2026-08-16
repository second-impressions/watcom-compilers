# watcom-compilers

Containerized historical Watcom C/C++ compilers — 6.5 (1988) through 11.0c
(2002) — running on modern Linux, plus a byte-verified preservation index for
the original distribution media.

Every image is produced by `podman build` with no host-side preprocessing: the
full extraction, patching and installation pipeline runs inside container build
stages, starting from the original retail media.

> **This repository contains no compiler media.** `scripts/fetch-sources.sh`
> downloads it on demand from the consolidated
> [Archive.org preservation item](https://archive.org/details/watcom-c-cpp-compilers-collection)
> into `archives/`, verifying every file against `scripts/SHA256SUMS` before any
> build consumes it. That directory is a download target only — nothing under it
> is tracked. Provenance for each artifact lives in the Containerfile that uses
> it. The media are third-party proprietary binaries, not covered by this
> repository's license — see [`THIRD_PARTY.md`](THIRD_PARTY.md).

## Quick start

```bash
git clone https://github.com/second-impressions/watcom-compilers
cd watcom-compilers

scripts/fetch-sources.sh                  # download + verify media (~4 GB)
scripts/build-images.sh                   # build everything
scripts/build-images.sh --filter 11.0c    # ...or just one release
```

Then compile something:

```bash
# wibo — preferred where available (9.5 and later)
podman run --rm -v "$PWD:/src" localhost/watcom-11.0c-wibo \
    wcl386 -l=dos4g hello.c

# dosemu2 — also runs the produced binary
podman run --rm -v "$PWD:/src" localhost/watcom-11.0c-dosemu2 \
    wcl386 -l=dos4g hello.c
podman run --rm -v "$PWD:/src" localhost/watcom-11.0c-dosemu2 hello.exe

# interactive DOS prompt (dosemu2 S-Lang terminal over stdio)
podman run --rm -it -v "$PWD:/src" localhost/watcom-11.0c-dosemu2
```

Substitute any tag from the table below. With a command, the shim runs headless
and exits on completion; with no command and a TTY, the dosemu2 images drop you
at a DOS prompt with `WATCOM` / `INCLUDE` / `PATH` pre-set and `F:\SRC` as the
working directory.

## Prebuilt images

The toolchain images downstream projects use are published to the GitHub
Container Registry, so you do not have to build anything to compile with them:

```bash
podman pull ghcr.io/second-impressions/watcom-10.0a-wibo
podman run --rm -v "$PWD:/src" ghcr.io/second-impressions/watcom-10.0a-wibo \
    wcl386 -l=dos4g hello.c
```

The shared bases (`watcom-toolchain`, `watcom-dosemu2-runtime`,
`watcom-wibo-runtime`) are published too, tagged by a hash of their own
definition; `scripts/build-images.sh --bases-from ghcr.io/second-impressions`
reuses them so a local build skips recompiling wibo.

These images contain the original proprietary compiler binaries, which this
repository's licence does not cover — see [`THIRD_PARTY.md`](THIRD_PARTY.md).
Build them yourself with the instructions below if you would rather not rely on
a published artifact.

## Which image should I use?

| | `*-wibo` | `*-dosemu2` |
|---|---|---|
| How it works | runs the NT-host tools directly under a PE32 loader | boots a DOS environment and runs the DOS-host tools |
| Versions | 9.5 → 11.0c (needs `binnt/`) | 6.5 → 11.0c (all) |
| Speed | one `exec`, no emulation | DOS boot per invocation |
| Size (11.0c) | ~435 MB | ~536 MB |
| Runs its own output | no | yes |

**Prefer `*-wibo`** where it exists: faster, smaller, no emulation — and it
produces byte-identical output to the dosemu2 path.

Use `*-dosemu2` for anything at or below **9.01e** (those predate `binnt/`
entirely, so there are no NT-host tools for wibo to load), when you need to
**execute** the produced DOS/4G binary — a wibo image compiles and links but has
no DOS runtime — or when you want an interactive DOS prompt.

## Versions covered

40 images in total: 24 dosemu2 and 16 wibo. ✓ = compiles, links and executes
`hello.c` and `hello.cpp` in the `tests/run-tests.sh` matrix. C++ arrived in
10.0; earlier releases are C-only.

| Version | Date | Media | dosemu2 image | wibo image |
|---|---|---|---|---|
| **6.5**    | 1988-05    | ✓ | ⚠ compile-only¹ | — (16-bit)    |
| **7.0**    | 1989-08    | ✓ archive-only  | — (no linker²)  | — |
| **8.0**    | 1990-06    | ✓ archive-only³ | — (no extender³)| — |
| **8.5**    | 1991-09    | ✓ | ✓ tested        | — (no binnt/) |
| **9.0 NTA**| 1992-02    | ✓ | ✓ tested       | — (no binnt/) |
| **9.01**   | 1992-05    | ✓ | ✓ tested       | — (no binnt/) |
| **9.01b**  | 1992       | ✓ c386_b patch  | ✓ tested       | — (no binnt/) |
| **9.01c**  | 1992       | ✓ c386_c patch  | ✓ tested       | — (no binnt/) |
| **9.01d**  | 1992-11    | ✓ | ✓ tested       | — (no binnt/) |
| **9.01e**  | 1993-02-28 | ✓ patch zip    | ✓ tested       | — (no binnt/) |
| **9.5 GA** | 1993-05-05 | ✓ | ✓ tested       | ✓ tested      |
| **9.5a**   | 1993-08-27 | ✓ | ✓ tested       | ✓ tested      |
| **9.5b**   | 1994-01-11 | ✓ | ✓ tested       | ✓ tested      |
| **9.5c**   | 1994-06-30 | ✓ | ✓ tested       | ✓ tested      |
| **10.0 LA**| 1994-03-16 | ✓ | ✓ tested       | ✓ tested      |
| **10.0 GA**| 1994-05-31 | ✓ (tree only)   | ✓ tested       | ✓ tested      |
| **10.0a**  | 1994-09-01 | ✓ | ✓ tested       | ✓ tested      |
| **10.0b**  | 1995-01-11 | ✓ | ✓ tested       | ✓ tested      |
| **10.5**   | 1995-07-11 | ✓ | ✓ tested       | ✓ tested      |
| **10.5a**  | 1995-11    | ✓ c105_a patch  | ✓ tested       | ✓ tested      |
| **10.6**   | 1996-02-29 | ✓⁴ | ✓ tested       | ✓ tested      |
| **10.6a**  | 1997-01-10 | ✓ | ✓ tested       | ✓ tested      |
| **11.0**   | 1997-02-11 | ✓ | ✓ tested       | ✓ tested      |
| **11.0a**  | 1997-08-29 | ✓ | ✓ tested       | ✓ tested      |
| **11.0b**  | 1998-02-24 | ✓ | ✓ tested¹      | ✓ tested      |
| **11.0c**  | 2002-08-27 | ✓ | ✓ tested       | ✓ tested      |

### Per-release notes

- **8.5/386 (1991)** is the earliest *fully self-contained* Watcom toolchain:
  it bundles its own WLINK and the royalty-free Rational DOS/4GW 1.0 extender,
  so it compiles, links, and runs 32-bit DOS/4G programs end to end
  (`wcl386 -l=dos4g`; the output is run via the `dos4gw` loader). C-only —
  Watcom C++ did not arrive until 10.0.
- **6.5 (1988)¹** is the 16-bit DOS compiler. Its image builds and the
  compiler runs, but linking is blocked under dosemu2: the 1988 WLIB 1.1 /
  WLINK 4.1 reject the distribution's own (byte-perfect) OMF libraries — a
  real-mode file-I/O incompatibility with dosemu2's FDPP, not a bad dump.
  Kept as an experimental image; not in the test matrix.
- **7.0 (1989)²** shipped as a code generator only — no linker. It targeted
  the **Phar Lap 386|DOS-Extender** (`386|LINK` + runtime) or A.I. Architects
  OS/386, both third-party SDKs. Without that linker the archive cannot
  produce a runnable binary, so 7.0 stays archive-only by design (this is a
  Watcom collection, not a mixed toolchain). The intended pairing is
  preserved separately at archive.org (`phar-lap-386-dox-extender-4.1-sdk`).
- All three were acquired from old-dos.ru; see [`SOURCES.md`](https://archive.org/details/watcom-c-cpp-compilers-collection).
- The **9.5 32-bit floppy images** (archive.org source) carry injected macOS
  `.fseventsd` metadata. An independent copy with a byte-identical Watcom
  payload and none of that noise is preserved alongside them on Archive.org;
  the build inputs are left unchanged.
- **10.0 GA** ships as a pre-extracted install tree (recovered from Discmaster);
  the original floppy set has not surfaced. The `watcom-10.0-ga-dosemu2`
  image uses the Sybase ZIP directly via `extract-prebuilt-zip.sh`; see
  `containers/watcom-10.0-ga/dosemu2.Containerfile` for the identity
  argument (BINB/wcc386.exe is 536,624 B — the pre-A-patch size).
- **10.5** is extracted directly from `Watcom_C++_10.5.iso` at container
  build time. The WPK v1.1 archives it uses are decoded by a pure-Python
  decoder at `scripts/lib/wpack_decode.py`; format and decoder details in
  `docs/wpack.md`.
- **10.5a** shipped only as a maintenance *patch* (`c105_a.zip`), never as
  standalone media, which is why it eluded disc-image archives. The patch was
  recovered from the Watcom Products Infobase Vol 1 1996 CD and is applied onto
  the 10.5 GA tree at build time by `scripts/apply-patches-10.5.sh` (APPLYA:
  367 patched, 19 created). The patched compiler self-reports
  *"Version 10.5a"*; see [`RESEARCH.md`](https://archive.org/details/watcom-c-cpp-compilers-collection).
- **8.0 (1990)³** is C/386 with its own WLINK/WLIB/WMAKE but **no bundled DOS
  extender** (no DOS4GW/RUN386), so like 7.0 its 32-bit output cannot run
  standalone — archived and compilable, but no runnable image is built.
- **10.6 / 10.6a⁴.** These are the *same* release except for the linker: 10.6a
  is 10.6 GA plus the documented "linker corrections for Win9x/NT". The
  compilers (`WCC386.EXE`/`WPP386.EXE`) are byte-identical between the two;
  only `WLINK.EXE` differs — 10.6 GA's is dated 1996-02-29, 10.6a's 1997-01-10.
  Both discs' README still say "version 10.6" (Sybase never bumped the banner),
  which long conflated them. The GA disc (archive.org ISO + physical rip) is
  archived as the 10.6 GA disc image; the 10.6a ZIP is archived alongside it.
  **Both** now build runnable images: 10.6 GA extracts from the ISO's
  `DISKIMGS/` WPK packs (same path as 10.5), 10.6a from the pre-extracted ZIP.
  A full tree-vs-tree hash comparison confirmed the **only** differing common
  files are the three `WLINK.EXE` binaries. See [`cross-verification.md`](https://archive.org/details/watcom-c-cpp-compilers-collection).
- **9.0 NTA (1992-02)** and base **9.01 (1992-05)** are self-contained C/386
  toolchains (bundled WLINK + DOS4GW); their images compile, link, and run
  32-bit DOS/4GW programs (`wcl386 -l=dos4g`). C-only.
- **9.01 patch levels.** The May 1992 retail floppies are not pre-patch-A:
  `APPLYA.BAT` finds 50 files already stamped `.a` and errors on 15 more that
  are already past its expected input, while `APPLYB.BAT` applies to the same
  tree with 158 patched and zero errors. Since bpatch validates every input
  before touching it, the retail pressing already carried what `c386_a` was
  distributed to fix, and all files share a uniform 1992-05-28 date. So
  `c386_a.zip` applies to nothing in this collection and no 9.01a image
  exists; `watcom-9.01b` and `watcom-9.01c` chain `c386_b` and `c386_c` onto
  the retail tree. 9.01d comes from its own pre-extracted tree rather than
  from this chain — chaining b+c+d off the floppies reaches the same patch
  level but not a byte-equal tree, because the two install paths select
  different optional components. The 8.5-early
  (Liren c496 DOSIMG) and 9.0-mid (Liren c500 DiskDupe) dumps are
  proprietary-format duplicates of media already imaged here, so they are
  archived for preservation but not containerized.
- **9.5 pre-release (1993-02) is archive-only.** The two preserved copies are
  disks 6 and 7 of the beta and nothing else: the DOS/OS2 and NT compilers,
  linker, librarian and make (including `WPP386.NT`, so C++ was already
  present three months before GA), but no headers, no libraries and no
  `wlsystem.lnk`. The compiler itself does run — unpacked with the DOS
  `wpack.exe` and pointed at 9.5 GA headers it compiles cleanly under wibo and
  reports *"WATCOM C32 Optimizing Compiler Version 9.5, Copyright 1984,
  1993"* — but its linker rejects the GA system definitions
  (`Error(3109): system block novell too large`) and the beta's own are on a
  disk nobody has preserved. Any image would therefore be beta compilers on a
  GA runtime, which is not the release, so none is built.

- **Not preserved: 6.0 (1987).** 6.5 is the earliest surviving PC Watcom C.
  6.0 is confirmed real (it appears in Open Watcom's own history) but no dump
  exists anywhere — not on WinWorld, Vetusware, os2site, old-dos, Discmaster or
  archive.org, and the one museum holding a "Version C6.0" box holds an empty
  one. Treat 6.5 as the practical floor.
- **11.0b¹** ships a broken `wlink.exe` that page-faults at startup under
  dosemu2. The container overlays the 11.0c wlink.exe on top of the
  otherwise-unmodified 11.0b tree as a one-file surgical patch. See
  `containers/watcom-11.0/dosemu2.Containerfile` for the full diagnosis. The 11.0b
  ISO itself is also non-compliant with strict ISO 9660 readers, so
  extraction goes through `scripts/lib/iso_extract.py` — a small
  tolerant ISO 9660 walker.
- **wibo** images cover every Watcom revision that ships a `binnt/`
  directory — the full 9.5 – 11.0c range — by running the NT-host tools
  under the [`wibo`](https://github.com/second-impressions/wibo) PE32
  loader (~7 MiB static binary, no Wine, no Xvfb, no Wine prefix).  wibo
  is built from our pinned fork.  An earlier
  Wine-based experiment was blocked by the 9.5 – 10.6a `wlink.exe`
  overlay pager / SEH incompatibility; wibo is unaffected by the same
  mechanism.  9.01d/e have no `binnt/` so wibo is not applicable.  See [`host-binary-taxonomy.md`](https://archive.org/details/watcom-c-cpp-compilers-collection) for the matrix
  of which host binaries are real vs. stubs vs. DLL launchers in every
  version.

### Tree pruning

The 10.x and 11.x `/opt/watcom` trees are pruned at build time by
`scripts/lib/prune-watcom-tree.sh`, which removes documentation, samples, IDE
help catalogues, installer media and NetWare host pieces — ~30–60 MB on the
early 10.x images and ~320 MB (~40 %) on the 11.0 family. It keeps every
header, library and host tool, so the image can still compile, assemble, link,
archive and make for every documented target (DOS, DOS/4G, Win 3.x, Win 9x,
Win NT, OS/2, NetWare, NLM); that script's header carries the exact
kept/dropped list.

Nothing is lost permanently: the original media stay byte-identified by
`scripts/SHA256SUMS` and can be re-fetched at any time, and any image can be
rebuilt with `--build-arg PRUNE=0` to keep the complete tree under the same
tag.

The **9.01 and 9.5 series** are not pruned: those installs predate the
bulk of what the prune script targets (no `sdk/`, no `samples/`, no
`mfc/`, no big `binw/` help catalogues), so the prune finds under 4 % to
drop.  Those images ship the unmodified tree.

### Bundled DOS/4GW runtime versions

The DOS/4GW version bundled in a Watcom toolchain identifies the patch level
used to build a given target executable. The version string appears at run
time as `DOS/4GW Protected Mode Run-time  Version X.YY`.

### 9.5 series

| Image tag | Date | Compiler | Linker | DOS/4GW | Patch content |
|---|---|---|---|---|---|
| `watcom-9.5-dosemu2` | 1993-05-05 | wcc386 9.5 | wlink 9.5 | **1.9** (240 580 B) | GA — unpatched |
| `watcom-9.5a-dosemu2` | 1993-08-27 | wcc386 9.5a | wlink 9.5a | **1.92** (244 716 B) | APPLYA: 277 patched, 15 created |
| `watcom-9.5b-dosemu2` | 1994-01-11 | wcc386 9.5b | wlink 9.5b | **1.95** (254 556 B) | APPLYB: 255 patched, 19 created |
| `watcom-9.5c-dosemu2` | 1994-06-30 | wcc386 9.5c | wlink 9.5c | **1.97** (265 420 B) | APPLYC: 195 patched, 0 created |

### 10.0 series

| Image tag | Date | Compiler | Linker | DOS/4GW | Patch content |
|---|---|---|---|---|---|
| `watcom-10.0a-dosemu2` | 1994-09-01 | wcc386 10.0a | wlink 10.0 | **1.97** (254 556 B) | From retail ISO (earliest surviving level) |
| `watcom-10.0b-dosemu2` | 1995-01-11 | wcc386 10.0b | wlink 10.0 | **1.97** (254 556 B) | APPLYB: 57 patched (Pentium FDIV fix) |

## Media

`scripts/build-media.txt` lists the 56 artifacts needed to build every image.
`scripts/fetch-sources.sh` downloads them from the Archive.org item and checks
each against `scripts/SHA256SUMS`. Downloads land in a `.part` file and are
only renamed into place after the hash matches, so an interrupted or corrupt
download never replaces a valid input. Re-running is safe and normally
verifies only.

```text
--verify-only    fail instead of downloading missing or corrupt files
--force          re-download even valid files
--all            fetch every artifact in scripts/SHA256SUMS, not just the
                 subset the builds need (adds the archive-only media:
                 7.0, 8.0, the Liren dumps, the QNX 10.6b patch, ...)
--jobs N         concurrent downloads (default: 4)
```

`scripts/SHA256SUMS` is the single source of truth for identities; a path that
is not listed there is a hard error rather than an unverified download.

Media must never be committed. The `.gitignore` rules are a safety net, not a
guarantee — `git ls-files archives` should list only `SHA256SUMS` and provenance
READMEs. Note that built images *do* contain the proprietary binaries even
though this repository does not; publishing images is a separate decision from
publishing this source.

## Tests

```bash
tests/run-tests.sh                       # whole matrix
tests/run-tests.sh -f 11.0c              # one release
tests/run-interactive-tests.sh           # interactive DOS-prompt path
```

`run-tests.sh` compiles and links `hello.c` and `hello.cpp` with
`wcl386 -l=dos4g`, then executes the result — wibo output is run in the
matching dosemu2 image, which is also the check that both build paths produce
identical bytes. Requires `bats`; `nix develop` provides it.

## Continuous integration

Two workflows, both of which drive the same scripts a developer runs locally —
there is no CI-only code path in the repository.

- **`pr.yml`** builds and verifies every image on each pull request, split into
  five parallel groups of eight. It also checks that the repository stays
  self-consistent: each image is named in the header of the Containerfile that
  builds it, each documented `--target` resolves to a real stage, every
  bind-mounted artifact appears in `scripts/SHA256SUMS`, and nothing under
  `archives/` is tracked.
- **`publish.yml`** builds, verifies and pushes the images downstream projects
  consume to the GitHub Container Registry. The default set is what
  `caesar2-reconstruction` needs: `watcom-10.0a-wibo` to compile and
  `watcom-10.0a-dosemu2` to run the result.

Third-party actions are pinned by commit SHA, matching how the base images are
pinned by manifest digest.

### One filter everywhere

`scripts/images.tsv` is the single build table. The same regex selects images
for all four operations, so a CI job cannot fetch one set and test another:

```bash
F='^watcom-10\.0a-(wibo|dosemu2)$'
scripts/fetch-sources.sh --filter "$F"          # only the media those images need
scripts/build-images.sh --skip-fetch --filter "$F"
WATCOM_IMAGE_FILTER="$F" nix run .#test        # only those images
scripts/push-images.sh ghcr.io/OWNER --filter "$F" --tag sha-abc1234
```

The fetcher works out which media an image needs from the Containerfile's own
bind mounts, following `FROM localhost/…` edges, so nothing has to be listed
twice. For the pair above that is 4 files (~362 MB) rather than the full 54
(~3.4 GB) — which is what makes the CI media cache worth having, and keeps
repeat runs off Archive.org.

A stale or partial cache is safe: `fetch-sources.sh` verifies every file
against `scripts/SHA256SUMS` and re-downloads anything missing or corrupt, so a
cache miss costs time and never correctness.

## Documentation

Most of what used to live in `docs/` now sits next to the thing it describes:

- `containers/wibo-runtime/Containerfile` — which wibo fork/commit is built, and why
- `scripts/shims/wibo-shim.sh` — wibo's path, drive and DLL-search model
- `scripts/shims/dosemu2-shim.sh` — the DOS environment and shim branches
- `scripts/lib/prune-watcom-tree.sh` — the exact kept/dropped prune list
- each `containers/*/dosemu2.Containerfile` — provenance for the media it consumes
- [`docs/wpack.md`](docs/wpack.md) — WPK archive format reference and decoder notes

Provenance and identification research is not duplicated here. It ships with
the media it describes, in the
[Archive.org item](https://archive.org/details/watcom-c-cpp-compilers-collection):
`SOURCES.md`, `RESEARCH.md`, `cross-verification.md`, `host-binary-taxonomy.md`
and `iso-identity.md`.

## License

Copyright (C) 2026 Simon Brakhane

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License along
with this program. If not, see <https://www.gnu.org/licenses/>.

This covers the build tooling, container definitions, tests and documentation
authored here — `SPDX-License-Identifier: AGPL-3.0-or-later`. It does **not**
cover the historical Watcom compiler media the build downloads, nor the
third-party components the images are built from (dosemu2/FDPP, wibo, Debian,
Ubuntu, Alpine). Those keep their own terms and are not relicensed; see
[`THIRD_PARTY.md`](THIRD_PARTY.md).
