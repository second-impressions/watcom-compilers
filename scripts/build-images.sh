#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
# Build the complete Watcom runtime image matrix in dependency order.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="${WATCOM_BUILD_LOG_DIR:-$REPO_ROOT/.cache/build-logs}"
IMAGE_TABLE="$SCRIPT_DIR/images.tsv"
# The three shared bases: always present, since every filtered build depends on
# them. They are also the only images worth publishing for reuse -- rebuilding
# them dominates a cold build.
BASE_TAGS="watcom-toolchain:latest watcom-dosemu2-runtime:latest watcom-wibo-runtime:latest"
declare -a PREBUILT_BASES=()
# shellcheck source=lib/image-deps.sh
. "$SCRIPT_DIR/lib/image-deps.sh"
FILTER='.'
FETCH=1
DRY_RUN=0
BASES_FROM=''
PRINT_BASE_TAGS=0

# base_content_tag FILE
#
# A tag that changes whenever this base image's definition does. The inputs are
# the Containerfile itself plus every repository file it COPYs in -- which for
# the three shared bases is one shim or helper script each. The wibo pin lives
# in its Containerfile, so bumping WIBO_COMMIT changes the tag too.
#
# Used to publish and retrieve prebuilt bases: rebuilding them accounts for
# almost all of a cold build (compiling wibo alone is ~4 minutes), while they
# change only rarely.
base_content_tag() {
    local file="$1" src
    {
        cat "$REPO_ROOT/$file"
        while IFS= read -r src; do
            [[ -f "$REPO_ROOT/$src" ]] && cat "$REPO_ROOT/$src"
        done < <(awk '/^COPY[[:space:]]/ && $0 !~ /--from=/ {print $2}' "$REPO_ROOT/$file")
    } | sha256sum | cut -c1-12
}

usage() {
    cat <<'EOF'
Usage: scripts/build-images.sh [options]

Build all shared bases, 24 dosemu2 images (including experimental 6.5)
and 16 wibo images.

Options:
  --skip-fetch       do not run scripts/fetch-sources.sh first
  --bases-from REG   reuse shared base images published at REG instead of
                     rebuilding them; falls back to building any that are
                     missing. Each is looked up by a content tag derived from
                     its own definition, so a changed base is never reused.
  --print-base-tags  print 'name<TAB>content-tag' for each shared base and exit
  --filter REGEX     build only image tags matching an extended regex
  --dry-run          print commands without running them
  -h, --help         show this help

Extra podman build arguments may be supplied in WATCOM_BUILD_ARGS.
EOF
}

while (($#)); do
    case "$1" in
        --skip-fetch) FETCH=0 ;;
        --bases-from) shift; BASES_FROM="${1:?--bases-from requires a registry}" ;;
        --print-base-tags) PRINT_BASE_TAGS=1 ;;
        --filter) shift; FILTER="${1:?--filter requires a regex}" ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

command -v podman >/dev/null || {
    echo "error: podman is required" >&2
    exit 127
}
mkdir -p "$LOG_DIR"

declare -a EXTRA_ARGS=()
if [[ -n ${WATCOM_BUILD_ARGS:-} ]]; then
    # Deliberately shell-like: this environment variable is an advanced escape
    # hatch for trusted local flags such as "--pull=always --no-cache".
    read -r -a EXTRA_ARGS <<< "$WATCOM_BUILD_ARGS"
fi

build_one() {
    local tag="$1" file="$2" target="${3:-}" force="${4:-0}" log
    (( force )) || [[ "$tag" =~ $FILTER ]] || return 0
    log="$LOG_DIR/${tag//[:\/]/_}.log"
    local -a cmd=(podman build)
    [[ -n "$target" ]] && cmd+=(--target "$target")
    cmd+=(-t "localhost/$tag" -f "$file")
    cmd+=("${EXTRA_ARGS[@]}" .)
    printf '\n==> %s\n' "$tag"
    printf '    '
    printf '%q ' "${cmd[@]}"
    printf '\n'
    if (( DRY_RUN )); then return 0; fi
    (cd "$REPO_ROOT" && "${cmd[@]}") 2>&1 | tee "$log"
}

if (( PRINT_BASE_TAGS )); then
    while IFS=$'\t' read -r tag file target; do
        [[ -z "$tag" || "$tag" == '#'* ]] && continue
        case " $BASE_TAGS " in
            *" $tag "*) printf '%s\t%s\n' "${tag%%:*}" "$(base_content_tag "$file")" ;;
        esac
    done < "$IMAGE_TABLE"
    exit 0
fi

if (( FETCH )); then
    if (( DRY_RUN )); then
        echo "scripts/fetch-sources.sh"
    else
        "$SCRIPT_DIR/fetch-sources.sh"
    fi
fi

# Everything this repo builds is listed in scripts/images.tsv, which is also
# what fetch-sources.sh --filter reads to decide which media to download. The
# three shared bases are marked there and are always built: filtered
# per-version builds still depend on those tags, and rebuilding them is
# cache-friendly.

# Work out the full set to build: everything matching --filter, plus whatever
# those images are built from.
#
# A filtered selection is not self-contained. Each watcom-X-wibo image takes
# its /opt/watcom from the matching watcom-X-dosemu2 image via COPY --from, so
# building only the wibo image leaves podman trying to *pull* a localhost/
# image that was never built. Prerequisites are therefore resolved and built
# first, whether or not they match the filter -- they are inputs, not output.
declare -A WANTED=()
declare -A TAG_FILE=() TAG_TARGET=()

# Pull prebuilt bases when asked. Anything that cannot be retrieved is simply
# built below, so a missing or stale publish degrades to the normal path.
if [[ -n "$BASES_FROM" ]]; then
    while IFS=$'\t' read -r tag file target; do
        [[ -z "$tag" || "$tag" == '#'* ]] && continue
        case " $BASE_TAGS " in *" $tag "*) : ;; *) continue ;; esac
        name="${tag%%:*}"
        ref="$BASES_FROM/$name:$(base_content_tag "$file")"
        printf '\n==> %s (reusing %s)\n' "$name" "$ref"
        if (( DRY_RUN )); then continue; fi
        if podman pull -q "$ref" >/dev/null 2>&1; then
            podman tag "$ref" "localhost/$name:latest"
            PREBUILT_BASES+=("$name")
        else
            printf '    not published yet; will build it\n'
        fi
    done < "$IMAGE_TABLE"
fi

while IFS=$'\t' read -r tag file target; do
    [[ -z "$tag" || "$tag" == '#'* ]] && continue
    [[ "$target" == "-" ]] && target=""
    TAG_FILE["${tag%%:*}"]="$file"
    TAG_TARGET["${tag%%:*}"]="$target"
done < "$IMAGE_TABLE"

mark_wanted() {
    local name="$1" dep
    [[ -n ${WANTED[$name]:-} ]] && return 0
    [[ -n ${TAG_FILE[$name]+x} ]] || return 0
    WANTED["$name"]=1
    while IFS= read -r dep; do
        [[ -n "$dep" ]] && mark_wanted "$dep"
    done < <(image_deps "$REPO_ROOT/${TAG_FILE[$name]}" "${TAG_TARGET[$name]}")
}

while IFS=$'\t' read -r tag file target; do
    [[ -z "$tag" || "$tag" == '#'* ]] && continue
    name="${tag%%:*}"
    case " $BASE_TAGS " in *" $tag "*) mark_wanted "$name"; continue ;; esac
    [[ "$name" =~ $FILTER ]] && mark_wanted "$name"
done < "$IMAGE_TABLE"

while IFS=$'\t' read -r tag file target; do
    [[ -z "$tag" || "$tag" == '#'* ]] && continue
    [[ "$target" == "-" ]] && target=""
    name="${tag%%:*}"
    [[ -n ${WANTED[$name]:-} ]] || continue
    # Already retrieved from the registry; nothing to build.
    skip=0
    for prebuilt in ${PREBUILT_BASES[@]+"${PREBUILT_BASES[@]}"}; do
        [[ "$prebuilt" == "$name" ]] && skip=1
    done
    (( skip )) && continue
    # Selection already happened above, so every remaining entry is built.
    build_one "$tag" "$file" "$target" 1
done < "$IMAGE_TABLE"
if (( ! DRY_RUN )); then
    {
        printf 'image\tid\tsize\n'
        podman images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}' \
            | LC_ALL=C sort \
            | grep '^localhost/watcom-' || true
    } > "$REPO_ROOT/.cache/watcom-images.tsv"
    echo
    echo "All requested images built. Inventory: .cache/watcom-images.tsv"
fi
