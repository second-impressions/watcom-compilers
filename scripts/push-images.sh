#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# push-images.sh — retag locally built images and push them to a registry.
#
# The build always produces localhost/<tag> (the Containerfiles refer to each
# other by that name, so the prefix cannot be changed at build time without
# rewriting every FROM). Publishing is therefore a separate retag-and-push
# step, which this script performs. It is not CI-specific: point it at any
# registry you can log in to.
#
# Usage:
#     push-images.sh REGISTRY --filter REGEX [options]
#
# Arguments:
#     REGISTRY         Target prefix, e.g. ghcr.io/second-impressions
#
# Options:
#     --filter REGEX   Push images whose tag matches REGEX (same regex as
#                      build-images.sh --filter). Required unless --bases is
#                      given: pushing the whole matrix by accident is expensive.
#     --bases          Push the three shared base images instead, each under the
#                      content tag build-images.sh derives from its definition
#                      (plus :latest). These are what --bases-from retrieves.
#     --tag TAG        Extra tag to publish alongside :latest (e.g. a commit
#                      SHA). May be repeated.
#     --dry-run        Print what would be pushed and exit.
#     -h, --help       Show this help.
#
# Every image is published as :latest plus any --tag values given.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_TABLE="$SCRIPT_DIR/images.tsv"

REGISTRY=""
FILTER=""
BASES=0
DRY_RUN=0
declare -a EXTRA_TAGS=()

usage() { sed -n '5,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while (($#)); do
    case "$1" in
        --filter) shift; FILTER="${1:?--filter requires a regex}" ;;
        --bases)  BASES=1 ;;
        --tag)    shift; EXTRA_TAGS+=("${1:?--tag requires a value}") ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)
            [[ -z "$REGISTRY" ]] || { echo "error: unexpected argument: $1" >&2; exit 2; }
            REGISTRY="$1"
            ;;
    esac
    shift
done

[[ -n "$REGISTRY" ]] || { echo "error: REGISTRY is required" >&2; usage >&2; exit 2; }
(( BASES )) || [[ -n "$FILTER" ]] || {
    echo "error: --filter is required (or --bases)" >&2; usage >&2; exit 2
}

if (( BASES )); then
    command -v podman >/dev/null || { echo "error: podman is required" >&2; exit 127; }
    while IFS=$'\t' read -r name content_tag; do
        [[ -n "$name" ]] || continue
        src="localhost/$name:latest"
        podman image exists "$src" || {
            echo "error: $src is not built locally" >&2
            exit 1
        }
        for t in "$content_tag" latest; do
            dst="$REGISTRY/$name:$t"
            if (( DRY_RUN )); then
                printf 'would push %s -> %s\n' "$src" "$dst"
                continue
            fi
            printf 'push      %s -> %s\n' "$src" "$dst"
            podman tag "$src" "$dst"
            podman push "$dst"
        done
    done < <("$SCRIPT_DIR/build-images.sh" --print-base-tags)
    exit 0
fi
command -v podman >/dev/null || { echo "error: podman is required" >&2; exit 127; }
[[ -f "$IMAGE_TABLE" ]] || { echo "error: image table not found: $IMAGE_TABLE" >&2; exit 1; }

declare -a SELECTED=()
while IFS=$'\t' read -r tag file target; do
    [[ -z "$tag" || "$tag" == \#* ]] && continue
    [[ "$tag" =~ $FILTER ]] || continue
    SELECTED+=("${tag%%:*}")
done < "$IMAGE_TABLE"

((${#SELECTED[@]})) || { echo "error: --filter '$FILTER' matched no image" >&2; exit 1; }

failures=0
for name in "${SELECTED[@]}"; do
    src="localhost/$name"
    if ! podman image exists "$src"; then
        echo "error: $src is not built locally; run scripts/build-images.sh first" >&2
        failures=$((failures + 1))
        continue
    fi
    for t in latest "${EXTRA_TAGS[@]}"; do
        dst="$REGISTRY/$name:$t"
        if (( DRY_RUN )); then
            printf 'would push %s -> %s\n' "$src" "$dst"
            continue
        fi
        printf 'push      %s -> %s\n' "$src" "$dst"
        podman tag "$src" "$dst"
        podman push "$dst"
    done
done

if (( failures )); then
    echo "error: $failures image(s) were not available to push" >&2
    exit 1
fi
printf 'published %d image(s) to %s\n' "${#SELECTED[@]}" "$REGISTRY"
