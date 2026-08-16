# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# image-deps.sh — work out what building one image target actually depends on.
#
# Sourced by scripts/build-images.sh (to build prerequisites of a filtered
# selection) and scripts/fetch-sources.sh (to download only the media those
# prerequisites read). Both need the same answer, so the logic lives here once.
#
# Resolution is per *target*, not per file. Several images usually share a
# Containerfile — containers/watcom-11.0/wibo.Containerfile builds four — and
# each shipping stage pulls its tree from a different dosemu2 image. Answering
# at file level would drag in every sibling: a wibo-only build would fetch the
# media for release levels it never touches, and would try to build them too.
#
# The stage graph is walked backwards from the requested target through both
# `FROM <stage>` and `COPY --from=<stage>` edges, stopping at `localhost/<tag>`
# references, which are the external images this target needs built first.

# _stage_graph FILE
#
# Emit one record per stage, US-separated (0x1f):
#   name|from|COPY --from srcs|bind-mounted archives/ paths
#
# Not tab-separated: tab is IFS whitespace, so `read` collapses runs of them
# and an empty field would silently shift every later field left.
# An unnamed final stage is reported with the name '-'.
_stage_graph() {
    awk -v SEP="\037" '
        /^[[:space:]]*FROM[[:space:]]/ {
            if (n > 0) print name[n] SEP from[n] SEP copies[n] SEP media[n]
            n++
            from[n] = $2
            name[n] = "-"
            if (tolower($3) == "as") name[n] = $4
            copies[n] = ""
            media[n] = ""
            next
        }
        {
            if (n > 0) {
                s = $0
                while (match(s, /--from=[^ \t]+/)) {
                    copies[n] = copies[n] " " substr(s, RSTART + 7, RLENGTH - 7)
                    s = substr(s, RSTART + RLENGTH)
                }
                s = $0
                while (match(s, /source=archives\/[^,[:space:]]+/)) {
                    media[n] = media[n] " " substr(s, RSTART + 7, RLENGTH - 7)
                    s = substr(s, RSTART + RLENGTH)
                }
            }
        }
        END { if (n > 0) print name[n] SEP from[n] SEP copies[n] SEP media[n] }
    ' "$1"
}

# stage_media FILE TARGET
#
# Print the archives/ paths bind-mounted by TARGET and by every stage inside
# FILE that TARGET is built from. Stops at localhost/ references, whose media
# belong to that other image and are collected when it is visited in turn.
stage_media() {
    local file="$1" target="${2:-}"
    [[ -f "$file" ]] || return 0

    local -A stage_from=() stage_copies=() stage_media_paths=()
    local -a order=()
    local name from copies media
    while IFS=$'\037' read -r name from copies media; do
        stage_from["$name"]="$from"
        stage_copies["$name"]="$copies"
        stage_media_paths["$name"]="$media"
        order+=("$name")
    done < <(_stage_graph "$file")

    [[ -n "$target" ]] || target="${order[-1]}"

    local -A seen=()
    local -a queue=("$target")
    local cur ref
    while ((${#queue[@]})); do
        cur="${queue[0]}"
        queue=("${queue[@]:1}")
        [[ -n ${seen[$cur]:-} ]] && continue
        seen["$cur"]=1
        [[ -n ${stage_from[$cur]+x} ]] || continue

        local m
        for m in ${stage_media_paths[$cur]}; do
            [[ -n "$m" ]] && printf '%s\n' "$m"
        done
        for ref in "${stage_from[$cur]}" ${stage_copies[$cur]}; do
            if [[ -n "$ref" && "$ref" != localhost/* ]]; then
                queue+=("$ref")
            fi
        done
    done
    # Callers run under `set -e`. A for/while loop takes the status of its last
    # command, so a trailing test that happens to be false would abort them.
    return 0
}

# image_deps FILE TARGET
#
# Print the localhost image tags (bare, no registry prefix) that building
# TARGET out of FILE depends on. TARGET may be empty for a single-stage file.
image_deps() {
    local file="$1" target="${2:-}"
    [[ -f "$file" ]] || return 0

    local -A stage_from=() stage_copies=()
    local -a order=()
    local name from copies
    while IFS=$'\037' read -r name from copies media; do
        stage_from["$name"]="$from"
        stage_copies["$name"]="$copies"
        order+=("$name")
    done < <(_stage_graph "$file")

    # An empty target means the final stage.
    [[ -n "$target" ]] || target="${order[-1]}"

    local -A seen=()
    local -a queue=("$target")
    local cur ref
    while ((${#queue[@]})); do
        cur="${queue[0]}"
        queue=("${queue[@]:1}")
        [[ -n ${seen[$cur]:-} ]] && continue
        seen["$cur"]=1

        # Not a stage in this file: either an external image or a base image.
        if [[ -z ${stage_from[$cur]+x} ]]; then
            [[ "$cur" == localhost/* ]] && printf '%s\n' "${cur#localhost/}"
            continue
        fi

        for ref in "${stage_from[$cur]}" ${stage_copies[$cur]}; do
            [[ -n "$ref" ]] || continue
            if [[ "$ref" == localhost/* ]]; then
                printf '%s\n' "${ref#localhost/}"
            else
                queue+=("$ref")
            fi
        done
    done
    return 0
}
