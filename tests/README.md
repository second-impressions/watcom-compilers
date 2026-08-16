# Tests

Verification matrix for every shipped `watcom-*` runtime image, driven by
[bats](https://github.com/bats-core/bats-core) (a language-agnostic
command/exit/output test runner). Definitions live in `images.bats`; the
per-release knobs and check bodies are in `lib/watcom.bash`.

## What it checks

For each image, three independent things:

- **shape** — the image is a slim runtime carrying exactly one release
  tree: `/opt/watcom` present, a host driver (`wcl386`, or the 16-bit
  `wcl`) present, and **no build-toolchain leak** (`/opt/watcom-tools`
  absent). This is the self-containment assertion.
- **C** — compile + link `hello.c` with the per-release command, assert
  the compiler banner reports the **expected release version** (the
  provenance check — catches an image carrying binaries from the wrong
  release), then run the program and verify its stdout.
- **C++** — same for `hello.cpp`, only where a C++ compiler shipped
  (`wpp386` first appeared in 9.5; 8.5 and the 9.01 series are C-only).

`wibo` images compile under wibo but execute the produced DOS/4G program
under the matching `dosemu2` image (wibo ships no DOS extender). 8.5's
`-l=dos4g` output is run via the `dos4gw` loader.

## Running

The test tools come from the flake devshell:

```bash
nix develop                      # enter the devshell (provides bats)
bats -r tests                    #   …then run the whole matrix
bats -F tap -r tests             #   TAP output for CI
bats -f 11.0c tests              #   filter to one release
bats --jobs 4 -r tests           #   parallel

nix run .#test                   # run the matrix without entering the shell
tests/run-tests.sh               # convenience wrapper (forwards to bats)
```

Exit status is `0` iff every test passes. Requires `podman` and the
`localhost/watcom-*` images already built.

## Not in the default matrix

- **watcom-6.5-dosemu2** — the 1988 16-bit compiler runs and passes the
  shape/version checks, but its own WLIB 1.1 / WLINK 4.1 reject the
  distribution's (byte-perfect) OMF libraries under dosemu2/FDPP, so the
  link step is blocked. Pass it explicitly to observe the failure.

## Other harnesses

- `run-interactive-tests.sh` — the shim's interactive-DOS-prompt and
  no-TTY behavior matrix (plain bash; not yet ported to bats).

## Source files

- `hello.c`   — plain `printf` hello world.
- `hello.cpp` — classic `<iostream.h>` / `cout` form. Watcom C/C++ predates
  the `std::` namespace; `<iostream>` / `std::cout` will not compile here.
