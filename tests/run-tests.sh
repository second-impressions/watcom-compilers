#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# run-tests.sh — thin launcher for the bats image-verification matrix
# (tests/images.bats).  The harness itself is bats; this just forwards to
# it so existing docs / muscle memory keep working.
#
#   tests/run-tests.sh                 # whole matrix
#   tests/run-tests.sh -f 8.5          # filter to one release
#   tests/run-tests.sh -F tap          # TAP output (CI)
#
# Requires the test devshell (which provides bats):
#   nix develop          # then: tests/run-tests.sh  (or: bats -r tests)
# or run it without entering the shell:
#   nix run .#test -- [bats args]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

if ! command -v bats >/dev/null 2>&1; then
    cat >&2 <<'MSG'
run-tests.sh: bats is not on PATH.

Enter the test devshell first:
    nix develop
    tests/run-tests.sh

Or run the matrix directly without entering the shell:
    nix run .#test
MSG
    exit 127
fi

exec bats "$@" "$HERE/images.bats"
