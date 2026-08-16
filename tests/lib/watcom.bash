# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
# watcom.bash — helpers for the image verification matrix (images.bats).
#
# Loaded by the .bats file.  Holds the image list, the per-release knobs
# (how each toolchain is driven), and the actual check bodies that the
# parameterized tests call.  The check bodies use bats `run` + bats-assert,
# so they only run inside a bats test.

# Default set of images to verify: every shipped runtime image.
# (watcom-6.5-dosemu2 is excluded — its 1988 WLINK/WLIB reject the
#  distribution's own OMF libraries under dosemu2/FDPP, so linking is
#  blocked; see containers/watcom-6.5/dosemu2.Containerfile.)
WATCOM_IMAGES=(
    # dosemu2 — DOS-host compilers + bundled DOS/4GW
    watcom-8.5-dosemu2
    watcom-9.0-nta-dosemu2
    watcom-9.01-dosemu2
    watcom-9.01b-dosemu2
    watcom-9.01c-dosemu2
    watcom-9.01d-dosemu2
    watcom-9.01e-dosemu2
    watcom-9.5-dosemu2
    watcom-9.5a-dosemu2
    watcom-9.5b-dosemu2
    watcom-9.5c-dosemu2
    watcom-10.0-la-dosemu2
    watcom-10.0-ga-dosemu2
    watcom-10.0a-dosemu2
    watcom-10.0b-dosemu2
    watcom-10.5-dosemu2
    watcom-10.5a-dosemu2
    watcom-10.6-dosemu2
    watcom-10.6a-dosemu2
    watcom-11.0-dosemu2
    watcom-11.0a-dosemu2
    watcom-11.0b-dosemu2
    watcom-11.0c-dosemu2
    # wibo — NT-host compilers (9.5+, the versions that ship binnt/)
    watcom-9.5-wibo
    watcom-9.5a-wibo
    watcom-9.5b-wibo
    watcom-9.5c-wibo
    watcom-10.0-la-wibo
    watcom-10.0-ga-wibo
    watcom-10.0a-wibo
    watcom-10.0b-wibo
    watcom-10.5-wibo
    watcom-10.5a-wibo
    watcom-10.6-wibo
    watcom-10.6a-wibo
    watcom-11.0-wibo
    watcom-11.0a-wibo
    watcom-11.0b-wibo
    watcom-11.0c-wibo
)

# WATCOM_IMAGE_FILTER narrows the matrix using the *same* regex accepted by
# scripts/build-images.sh --filter, scripts/fetch-sources.sh --filter and
# scripts/push-images.sh --filter, so one expression drives fetch, build, test
# and publish. bats' own --filter matches test *descriptions*, which continue
# past the image tag, so an anchored tag regex like '^watcom-10\.0a-wibo$'
# silently matches nothing there; filtering the image list instead keeps the
# regex meaning identical everywhere.
if [[ -n ${WATCOM_IMAGE_FILTER:-} ]]; then
    _filtered=()
    for _i in "${WATCOM_IMAGES[@]}"; do
        [[ "$_i" =~ $WATCOM_IMAGE_FILTER ]] && _filtered+=("$_i")
    done
    if ((${#_filtered[@]} == 0)); then
        printf 'watcom.bash: WATCOM_IMAGE_FILTER=%s matched no image\n' \
            "$WATCOM_IMAGE_FILTER" >&2
        exit 1
    fi
    WATCOM_IMAGES=("${_filtered[@]}")
    unset _filtered _i
fi

# wibo output is a DOS/4G exe with no extender in the wibo image, so its
# output is executed under the matching dosemu2 image.
exec_image_for() {
    case "$1" in
        *-wibo) printf '%s' "${1%-wibo}-dosemu2" ;;
        *)      printf '%s' "$1" ;;
    esac
}

# Compile+link command for image $1, source $2.
compile_cmd_for() {
    case "$1" in
        watcom-6.5-*) printf 'wcl %s' "$2" ;;            # 16-bit DOS driver
        *)            printf 'wcl386 -l=dos4g %s' "$2" ;;
    esac
}

# How to execute the produced hello.exe.
run_cmd_for() {
    case "$1" in
        # 8.5's -l=dos4g output is a bare LX image loaded by the DOS/4GW
        # run-time; the self-loading stub arrived in the 9.x line.
        watcom-8.5-*) printf 'dos4gw hello.exe' ;;
        *)            printf 'hello.exe' ;;
    esac
}

# Which images shipped a C++ compiler (wpp386 first appeared in 9.5).
has_cpp() {
    case "$1" in
        watcom-6.5-*|watcom-8.5-*|watcom-9.0-nta-*|watcom-9.01*) return 1 ;;
        *) return 0 ;;
    esac
}

# Release version string the compiler banner must contain (provenance).
expected_ver_for() {
    case "$1" in
        watcom-6.5-*)     printf '6.5' ;;
        watcom-8.5-*)     printf '8.5' ;;
        watcom-9.0-nta-*) printf '9.0' ;;
        watcom-9.01*)     printf '9.01' ;;
        watcom-9.5*)      printf '9.5' ;;
        watcom-10.0*)  printf '10.0' ;;
        watcom-10.5*)  printf '10.5' ;;
        watcom-10.6*)  printf '10.6' ;;
        watcom-11.0*)  printf '11.0' ;;
        *)             printf '' ;;
    esac
}

src_for()    { case "$1" in c) printf 'hello.c' ;;   cpp) printf 'hello.cpp' ;; esac; }
expect_for() { case "$1" in c) printf 'hello from watcom C' ;; cpp) printf 'hello from watcom CPP' ;; esac; }

# Genuine extra OS targets (beyond DOS/4G, which the C test already covers)
# a release can PRODUCE, as tab-separated
#     system <TAB> linker-banner-substring <TAB> file(1)-format-substring
# lines.  Both signals are checked: the linker's own "creating a <X>
# executable" banner (older linkers silently default an unknown -l=system
# to OS/2-flat, which a file-existence check would miss) AND the actual
# emitted binary format via file(1) — so we prove the bytes really target
# that system even though we can't run them here.
extra_targets_for() {
    case "$1" in
        watcom-8.5-*|watcom-9.0-nta-*|watcom-9.01*) : ;;   # DOS/4G era only
        watcom-9.5*) printf 'nt\tWindows NT\tPE32\n' ;;    # Win32 yes; os2v2 lib gap
        *)           printf 'nt\tWindows NT\tPE32\nos2v2\tOS/2 32-bit\tLX for OS/2\n' ;;
    esac
}

# -- check bodies (run inside a bats test) ----------------------------

# SHAPE: a slim runtime carrying exactly one release tree — /opt/watcom
# present, a host driver (wcl386 or 16-bit wcl) present, and NO build
# toolchain leak (/opt/watcom-tools, the wpack/bpatch dir, absent).
wc_shape() {
    local img="$1"
    run podman run --rm --entrypoint sh "localhost/$img" -c '
        [ -d /opt/watcom ] || { echo "missing /opt/watcom"; exit 1; }
        [ -e /opt/watcom-tools ] && { echo "toolchain leak: /opt/watcom-tools present"; exit 1; }
        for d in binw binb binp bin bin95 binnt; do
          for v in wcl386.exe WCL386.EXE wcl.exe WCL.EXE; do
            [ -e "/opt/watcom/$d/$v" ] && { echo "driver: $d/$v"; exit 0; }
          done
        done
        echo "no wcl/wcl386 driver"; exit 1'
    assert_success
}

# C / C++: compile+link with the per-release command (asserting the
# compiler's banner reports the expected release version — the provenance
# check), then run the produced program and assert its stdout.
wc_lang() {
    local img="$1" lang="$2"
    local src exec_img comp run expect exp_ver
    src=$(src_for "$lang"); expect=$(expect_for "$lang")
    exec_img=$(exec_image_for "$img"); exp_ver=$(expected_ver_for "$img")
    comp=$(compile_cmd_for "$img" "$src"); run=$(run_cmd_for "$img")

    ( cd "$WC_WORK" && rm -f hello.exe hello.obj _wcrun.bat __WCL__.LNK )

    # compile + link
    run podman run --rm -v "$WC_WORK:/src" "localhost/$img" $comp
    if [ "$lang" = c ] && [ -n "$exp_ver" ]; then
        assert_output --regexp "Version ${exp_ver//./\\.}"
    fi
    assert [ -f "$WC_WORK/hello.exe" ]

    # execute + verify stdout (DOS CRLF survives the --partial match)
    run podman run --rm -v "$WC_WORK:/src" "localhost/$exec_img" $run
    assert_line --partial "$expect"
}

# wmake: drive a one-rule makefile that builds hello.exe with the same
# per-release compile command, and assert the target was produced.  This
# exercises wmake (and re-exercises the wcl/wcl386 driver it spawns).
# Works under both dosemu2 and wibo — the latter relies on our wibo
# FindFirstFile "*.*" fix (containers/wibo-runtime/patches/) so wmake can
# locate the makefile by directory enumeration.
wc_make() {
    local img="$1" comp
    comp=$(compile_cmd_for "$img" hello.c)
    ( cd "$WC_WORK" && rm -f hello.exe hello.obj makefile
      printf 'hello.exe : hello.c\n\t%s\n' "$comp" > makefile )
    run podman run --rm -v "$WC_WORK:/src" "localhost/$img" wmake
    assert_success
    assert [ -f "$WC_WORK/hello.exe" ]
}

# Targets: prove the shared code generator can PRODUCE for each extra OS
# backend the release supports (we can't run them all, but we can verify
# the linker emits the right target — asserted via its "creating a <X>
# executable" banner, not mere file existence).
wc_targets() {
    local img="$1" specs sys banner
    specs=$(extra_targets_for "$img")
    [ -n "$specs" ] || skip "this release produces only the DOS/4G target"
    while IFS=$'\t' read -r sys banner fmt; do
        [ -z "$sys" ] && continue
        ( cd "$WC_WORK" && rm -f hello.exe hello.obj )
        run podman run --rm -v "$WC_WORK:/src" "localhost/$img" wcl386 -l="$sys" hello.c
        assert_success
        assert_output --partial "$banner"          # linker says it built the right target
        assert [ -f "$WC_WORK/hello.exe" ]
        run file -b "$WC_WORK/hello.exe"
        assert_output --partial "$fmt"             # ...and the bytes ARE that target
    done <<< "$specs"
}
