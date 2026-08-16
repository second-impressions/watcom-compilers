#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
# Fetch and verify the original media needed by the container builds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SUMS="$SCRIPT_DIR/SHA256SUMS"
BUILD_MANIFEST="$SCRIPT_DIR/build-media.txt"
IMAGE_TABLE="$SCRIPT_DIR/images.tsv"
# shellcheck source=lib/image-deps.sh
. "$SCRIPT_DIR/lib/image-deps.sh"

IA_BASE="${WATCOM_ARCHIVE_BASE_URL:-https://archive.org/download/watcom-c-cpp-compilers-collection}"
JOBS=4
MODE=build
FILTER=''
VERIFY_ONLY=0
FORCE=0

usage() {
    cat <<'EOF'
Usage: scripts/fetch-sources.sh [options]

Options:
  --all            fetch every artifact recorded in scripts/SHA256SUMS
  --filter REGEX   fetch only the media needed to build the images whose tags
                   match REGEX (same regex as scripts/build-images.sh --filter,
                   so the two stay in step)
  --verify-only    do not use the network; fail for missing/corrupt files
  --force          download all selected files, including valid existing ones
  --jobs N         concurrent downloads (default: 4)
  -h, --help       show this help
EOF
}

while (($#)); do
    case "$1" in
        --all) MODE=all ;;
        --filter)
            shift
            FILTER="${1:?--filter requires a regex}"
            MODE=filter
            ;;
        --verify-only) VERIFY_ONLY=1 ;;
        --force) FORCE=1 ;;
        --jobs)
            shift
            [[ ${1:-} =~ ^[1-9][0-9]*$ ]] || {
                echo "error: --jobs requires a positive integer" >&2
                exit 2
            }
            JOBS="$1"
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

command -v sha256sum >/dev/null || {
    echo "error: sha256sum is required" >&2
    exit 127
}
if (( ! VERIFY_ONLY )); then
    command -v curl >/dev/null || {
        echo "error: curl is required for downloads" >&2
        exit 127
    }
fi
[[ -f "$SUMS" ]] || {
    echo "error: checksum manifest not found: $SUMS" >&2
    exit 1
}

declare -A EXPECTED
while IFS= read -r line; do
    [[ "$line" =~ ^[0-9a-f]{64}[[:space:]][[:space:]]archives/ ]] || continue
    checksum="${line%%  *}"
    path="${line#*  }"
    EXPECTED["$path"]="$checksum"
done < "$SUMS"

# -----------------------------------------------------------------------------
# --filter: the media needed to build a subset of the images.
#
# No extra manifest is kept for this. Every Containerfile already declares what
# it consumes through `--mount=type=bind,source=archives/...`, and
# scripts/images.tsv says which Containerfile builds which tag, so the media set
# is derived from the same files the build itself reads. An image built FROM
# another localhost/ image inherits that image's media too -- each wibo image
# takes its tree from the matching dosemu2 image -- so those edges are followed
# transitively. The shared bases are always included because build-images.sh
# always builds them.
# -----------------------------------------------------------------------------
media_prefixes_for_filter() {
    local regex="$1"
    local -A seen=() tag_file=() tag_target=()
    local -a queue=()
    local tag file target name dep

    while IFS=$'\t' read -r tag file target; do
        [[ -z "$tag" || "$tag" == \#* ]] && continue
        [[ "$target" == "-" ]] && target=""
        name="${tag%%:*}"
        tag_file["$name"]="$file"
        tag_target["$name"]="$target"
        if [[ "$name" =~ ^watcom-(toolchain|dosemu2-runtime|wibo-runtime)$ ]] \
           || [[ "$name" =~ $regex ]]; then
            queue+=("$name")
        fi
    done < "$IMAGE_TABLE"

    # Walk image -> prerequisite images, collecting the media each *target*
    # reads. Resolving per target matters: containers/watcom-10.0/wibo.Container
    # file builds both 10.0a and 10.0b, and asking it at file level would fetch
    # the 10.0b patch kit for a 10.0a-only build.
    while ((${#queue[@]})); do
        name="${queue[0]}"
        queue=("${queue[@]:1}")
        [[ -n ${seen[$name]:-} ]] && continue
        seen["$name"]=1
        file="${tag_file[$name]:-}"
        [[ -n "$file" && -f "$REPO_ROOT/$file" ]] || continue

        stage_media "$REPO_ROOT/$file" "${tag_target[$name]}"

        while IFS= read -r dep; do
            [[ -n "$dep" ]] && queue+=("$dep")
        done < <(image_deps "$REPO_ROOT/$file" "${tag_target[$name]}")
    done
}

declare -a PATHS=()
if [[ "$MODE" == all ]]; then
    mapfile -t PATHS < <(
        printf '%s\n' "${!EXPECTED[@]}" | LC_ALL=C sort
    )
elif [[ "$MODE" == filter ]]; then
    declare -a PREFIXES=()
    mapfile -t PREFIXES < <(media_prefixes_for_filter "$FILTER" | LC_ALL=C sort -u)
    ((${#PREFIXES[@]})) || {
        echo "error: --filter '$FILTER' matched no image that consumes media" >&2
        exit 1
    }
    while IFS= read -r path; do
        [[ -z "$path" || "$path" == \#* ]] && continue
        for prefix in "${PREFIXES[@]}"; do
            # a mount is either the file itself or a directory containing it
            if [[ "$path" == "$prefix" || "$path" == "$prefix"/* ]]; then
                PATHS+=("$path")
                break
            fi
        done
    done < "$BUILD_MANIFEST"
    ((${#PATHS[@]})) || {
        echo "error: --filter '$FILTER' selected no media" >&2
        exit 1
    }
else
    while IFS= read -r path; do
        [[ -z "$path" || "$path" == \#* ]] && continue
        PATHS+=("$path")
    done < "$BUILD_MANIFEST"
fi

for path in "${PATHS[@]}"; do
    [[ -n ${EXPECTED[$path]:-} ]] || {
        echo "error: $path has no entry in scripts/SHA256SUMS" >&2
        exit 1
    }
done

valid_file() {
    local path="$1" expected="$2"
    [[ -f "$REPO_ROOT/$path" ]] || return 1
    printf '%s  %s\n' "$expected" "$REPO_ROOT/$path" | sha256sum -c --status -
}

url_for() {
    local path="$1" relative encoded
    relative="${path#archives/}"
    encoded="${relative// /%20}"
    printf '%s/%s' "$IA_BASE" "$encoded"
}

fetch_one() {
    local path="$1" expected="$2" dest part url
    dest="$REPO_ROOT/$path"

    if (( ! FORCE )) && valid_file "$path" "$expected"; then
        printf 'ok        %s\n' "$path"
        return 0
    fi
    if (( VERIFY_ONLY )); then
        if [[ -e "$dest" ]]; then
            printf 'corrupt   %s\n' "$path" >&2
        else
            printf 'missing   %s\n' "$path" >&2
        fi
        return 1
    fi

    mkdir -p "$(dirname "$dest")"
    part="${dest}.part"
    url="$(url_for "$path")"
    printf 'fetch     %s\n' "$path"
    curl --fail --location --retry 5 --retry-all-errors \
        --connect-timeout 30 --continue-at - \
        --output "$part" "$url"
    if ! printf '%s  %s\n' "$expected" "$part" | sha256sum -c --status -; then
        printf 'error: SHA-256 mismatch for %s\n' "$path" >&2
        rm -f "$part"
        return 1
    fi
    mv -f "$part" "$dest"
    printf 'verified  %s\n' "$path"
}

export REPO_ROOT IA_BASE VERIFY_ONLY FORCE
export -f valid_file url_for fetch_one

declare -a PIDS=()
failures=0
for path in "${PATHS[@]}"; do
    fetch_one "$path" "${EXPECTED[$path]}" &
    PIDS+=("$!")
    if ((${#PIDS[@]} >= JOBS)); then
        if ! wait "${PIDS[0]}"; then failures=$((failures + 1)); fi
        PIDS=("${PIDS[@]:1}")
    fi
done
for pid in "${PIDS[@]}"; do
    if ! wait "$pid"; then failures=$((failures + 1)); fi
done

if (( failures )); then
    echo "error: $failures source operation(s) failed" >&2
    exit 1
fi
printf 'source media ready: %d files\n' "${#PATHS[@]}"
