#!/usr/bin/env bats
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# images.bats — verification matrix for every shipped watcom-* image.
#
# Per image it registers:
#   * shape — slim runtime, one release tree, a host driver, no toolchain leak
#   * C     — version-banner provenance + compile + link + run of hello.c
#   * C++   — compile + link + run of hello.cpp (only where a C++ compiler shipped)
#
# Run inside the test devshell:
#   nix develop -c bats -r tests          # whole matrix
#   nix develop -c bats -F tap -r tests   # TAP (CI)
#   nix develop -c bats -f 8.5 tests      # one release
# or:  nix run .#test
#
# wibo images compile under wibo but execute the produced DOS/4G program
# under the matching dosemu2 image (wibo ships no DOS extender).

bats_require_minimum_version 1.5.0

load 'lib/watcom'

setup_file() {
    WC_WORK="$BATS_FILE_TMPDIR/work"
    mkdir -p "$WC_WORK"
    cp "$BATS_TEST_DIRNAME/hello.c" "$BATS_TEST_DIRNAME/hello.cpp" "$WC_WORK/"
    export WC_WORK
}

setup() {
    bats_load_library bats-support
    bats_load_library bats-assert
}

# Parameterize: one set of tests per image.
for _img in "${WATCOM_IMAGES[@]}"; do
    bats_test_function \
        --description "$_img : shape (slim runtime, one release tree, driver)" \
        -- wc_shape "$_img"
    bats_test_function \
        --description "$_img : C (version provenance + compile + link + run)" \
        -- wc_lang "$_img" c
    if has_cpp "$_img"; then
        bats_test_function \
            --description "$_img : C++ (compile + link + run)" \
            -- wc_lang "$_img" cpp
    fi
    bats_test_function \
        --description "$_img : wmake (drives wcl/wcl386 via a makefile)" \
        -- wc_make "$_img"
    bats_test_function \
        --description "$_img : targets (emits + verifies nt/os2v2 binaries where supported)" \
        -- wc_targets "$_img"
done
