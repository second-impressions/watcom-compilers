#!/usr/bin/env python3
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
"""
setup_inf_manifest.py — interpret Watcom 10.0 LA / 10.0 GA-era SETUP.INF
to lay down an installed Watcom tree from a flat staging directory of
pack files.

Format overview
===============

SETUP.INF is an INI-style config file read by the Windows 3.x SETUP.EXE
(and its OS/2 / NT siblings). The sections we care about:

[Dirs]
    ID=subpath, flag, parent_id
    e.g.  1=., 1, -1
          2=bin, 1, 1
          6=binp\\dll, 1, 5
    Produces a tree of directories relative to `DstDir`.  `parent_id=-1`
    is the root.  The middle `flag` (always 1 in the Watcom files) we ignore.

[Files]
    destname, packfile, sizeKB, dirID, diskID, overwrite, flags

    Columns 4 and 5 look like "dir, disk" empirically: verified by
    cross-referencing retail 10.0a's tree layout (wcc386.exe -> binb)
    against SETUP.INF's `wcc386.exe, pack0022, 508, 3, 2, Y, .`
    where 3 = binb in [Dirs].  Header files likewise: `assert.h, ..., 0,
    10, 14, N, .` where 10 = h is the correct placement.
    e.g.  dos4gw.doc, pack0001, 24, 1, 1, Y, doshost dostarg
          vi.exe,     pack0009.1, 0, 2, 1, N, doshost winhost |
          vi.exe,     +pack0009.2, 420, 2, 2, Y, doshost winhost |

    destname    Filename to create under the destination dir identified
                by dirID.
    packfile    Source pack file in the staging dir. A `+` prefix means
                "this is a continuation — concatenate to the previous
                accumulating buffer". A `.N` suffix (e.g., pack0009.1,
                pack0009.2) is literal floppy-disk split naming and has
                no special semantics for us (files are named that way
                on disk).
    sizeKB      Size of the unpacked output in KB. 0 on the first entry
                of a multi-part run — the run is flushed when a later
                entry has size > 0.
    diskID      Original floppy disk number (unused here — all files are
                in one staging dir).
    dirID       Index into [Dirs].  The unpacked file goes there.
    overwrite   Y = write, N = skip (first entry of a multi-part run
                has N).
    flags       Space-separated feature flags.  Filter options:
                  doshost, winhost, os2host, wnthost     — host OS
                  dostarg, wintarg, os2targ, wnttarg     — target OS
                  adstarg, nlmtarg                       — more targets
                  tools16, wkframe, toolkt2x, samples,
                  startup, MFC21                         — feature
                  . (literal dot)                        — no filter
                  | (literal pipe)                       — terminator
                Trailing `|` in the source file is a line-continuation
                artifact, not semantic. We ignore it.

Multi-part packs
----------------
WPK archives too large for a single floppy were split into `packNNNN.1`,
`packNNNN.2`, …  The .1 part starts with the WPK magic; .2+ are raw
continuations.  `cat` them in order and the result is a valid WPK that
unpacks normally.  [Files] models this as a run of entries with the
same destname, the first with `+`-less packfile and size 0 (N-overwrite),
subsequent entries with `+`-prefixed packfile, the last having size > 0
(Y-overwrite).

Usage
=====

    setup_inf_manifest.py \\
        --inf /staging/SETUP.INF \\
        --source /staging \\
        --dest /opt/watcom \\
        --watcom-tools /opt/watcom-tools \\
        [--selection all-yes]

`--selection all-yes` (default) treats every host/target/feature flag as
selected, producing a full install.  This mirrors the `--yes-all` mode of
install_scr.py for [0-9].01d / 9.5.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

from _dosemu import wpack_unpack_batch


# ---------------------------------------------------------------------------
# Tiny INI parser that tolerates duplicate keys (Watcom uses multiple
# [Dialog] sections and repeated keys like static_text).
# ---------------------------------------------------------------------------

SECTION_RE = re.compile(r"^\s*\[([^\]]+)\]\s*$")


def parse_inf(path: Path) -> dict[str, list[str]]:
    sections: dict[str, list[str]] = {}
    current: list[str] | None = None
    with open(path, "r", encoding="latin-1") as fh:
        for raw in fh:
            line = raw.rstrip("\r\n")
            m = SECTION_RE.match(line)
            if m:
                name = m.group(1).strip()
                # Merge duplicate sections (they concatenate).
                current = sections.setdefault(name, [])
                continue
            if current is None:
                continue
            current.append(line)
    return sections


# ---------------------------------------------------------------------------
# Directory table
# ---------------------------------------------------------------------------

def parse_dirs(lines: list[str], dst_dir: Path) -> dict[int, Path]:
    """Resolve [Dirs] entries to absolute paths.

    Format: `id=subpath, flag, parent_id`.

    The `subpath` is ALREADY the full relative path from the destination
    root (e.g. `6=binp\\dll, 1, 5` means `<dst>/binp/dll`, not
    `<dst>/binp/binp/dll`).  The `parent_id` field is a tree-structure
    hint used by the installer's UI, not a path component.  We therefore
    ignore it.
    """
    resolved: dict[int, Path] = {}
    for line in lines:
        line = line.strip()
        if not line or "=" not in line:
            continue
        key, rest = line.split("=", 1)
        try:
            dir_id = int(key.strip())
        except ValueError:
            continue
        parts = [p.strip() for p in rest.split(",")]
        if not parts:
            continue
        sub = parts[0].replace("\\", "/")
        if sub == ".":
            resolved[dir_id] = dst_dir
        else:
            resolved[dir_id] = dst_dir / sub
    return resolved


# ---------------------------------------------------------------------------
# File table
# ---------------------------------------------------------------------------

class FileEntry:
    __slots__ = ("dest", "pack", "is_append", "size_kb", "disk",
                 "dir_id", "overwrite", "flags")

    def __init__(self, dest: str, pack: str, is_append: bool, size_kb: int,
                 disk: int, dir_id: int, overwrite: bool, flags: list[str]):
        self.dest = dest
        self.pack = pack
        self.is_append = is_append
        self.size_kb = size_kb
        self.disk = disk
        self.dir_id = dir_id
        self.overwrite = overwrite
        self.flags = flags

    def __repr__(self):
        return f"FileEntry({self.dest}, {'+' if self.is_append else ''}{self.pack}, dir={self.dir_id})"


def parse_files(lines: list[str]) -> list[FileEntry]:
    entries: list[FileEntry] = []
    for line in lines:
        s = line.strip()
        if not s or s.startswith(";"):
            continue
        parts = [p.strip() for p in s.split(",")]
        if len(parts) < 6:
            continue
        dest = parts[0]
        pack = parts[1]
        is_append = pack.startswith("+")
        if is_append:
            pack = pack[1:]
        try:
            size_kb = int(parts[2])
            # Column 4 = dirID, column 5 = diskID (see format note above).
            dir_id = int(parts[3])
            disk = int(parts[4])
        except ValueError:
            continue
        overwrite = parts[5].upper() == "Y"
        flag_str = " ".join(parts[6:]).strip()
        # Strip trailing `|` continuation marker.
        flag_str = flag_str.rstrip("|").rstrip("&").strip()
        flags = [f for f in flag_str.split() if f and f not in IGNORED_FLAG_TOKENS]
        entries.append(FileEntry(dest.lower(), pack.lower(), is_append,
                                 size_kb, disk, dir_id, overwrite, flags))
    return entries


# ---------------------------------------------------------------------------
# Selection model
# ---------------------------------------------------------------------------

# Flags accepted as "selectable features".  `all-yes` mode sets them all.
KNOWN_FLAGS = {
    # Host OS
    "doshost", "winhost", "os2host", "wnthost",
    # Target OS / platform
    "dostarg", "wintarg", "os2targ", "wnttarg", "adstarg", "nlmtarg",
    # Features
    "tools16", "wkframe", "toolkt2x", "samples", "startup", "mfc21",
    # 16-bit memory models (preset to 1 in [Application], always on).
    "ms", "mc", "mm", "ml", "mh",
}

# Non-flag tokens in the flags column that we ignore.  `.` = "no filter",
# `|` and `&` are line/continuation sentinels in SETUP.INF that have no
# selection semantics.
IGNORED_FLAG_TOKENS = {".", "|", "&"}


def entry_selected(entry: FileEntry, selected: set[str]) -> bool:
    """True if the entry's flag list is satisfied by the selection.

    Watcom's flag list for a file is a conjunction: every listed flag
    must be selected.  An empty list means "always install".
    """
    if not entry.flags:
        return True
    for f in entry.flags:
        fl = f.lower()
        if fl not in selected:
            return False
    return True


# ---------------------------------------------------------------------------
# WPK unpacking lives in _dosemu.wpack_unpack_batch (shared with the
# other interpreters).  One dosemu2 boot per ~50 archives keeps the
# full 10.0 LA extraction under half a minute.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

def run(inf_path: Path, source_dir: Path, dst_dir: Path,
        watcom_tools: Path, selection_mode: str) -> None:

    sections = parse_inf(inf_path)
    if "Dirs" not in sections:
        raise SystemExit("SETUP.INF has no [Dirs] section")
    if "Files" not in sections:
        raise SystemExit("SETUP.INF has no [Files] section")

    dirs = parse_dirs(sections["Dirs"], dst_dir)
    files = parse_files(sections["Files"])

    if selection_mode == "all-yes":
        selected = set(KNOWN_FLAGS)
    else:
        raise SystemExit(f"unsupported selection mode: {selection_mode}")

    # Pre-create directories
    for p in dirs.values():
        p.mkdir(parents=True, exist_ok=True)

    # Build list of cases files are written into.  A "case" is one logical
    # destination file, composed of one or more pack parts.
    cases: list[tuple[FileEntry, list[str]]] = []
    pending: tuple[FileEntry, list[str]] | None = None

    for entry in files:
        if entry.is_append:
            if pending is None:
                # Malformed but recoverable — treat as standalone.
                pending = (entry, [entry.pack])
            else:
                pending[1].append(entry.pack)
            if entry.size_kb > 0:
                # Final segment — flush the run.  Use the FIRST entry's
                # dir_id / flags because the continuation entries often
                # carry placeholder dir_ids (the original installer used
                # them to record disk-spanning geometry, not a real
                # destination).  Size/overwrite come from the final entry
                # because that's where they're meaningful.
                head = pending[0]
                parts = pending[1]
                final = FileEntry(
                    dest=head.dest,
                    pack=parts[0],
                    is_append=False,
                    size_kb=entry.size_kb,
                    disk=head.disk,
                    dir_id=head.dir_id,
                    overwrite=entry.overwrite,
                    flags=head.flags,
                )
                cases.append((final, parts))
                pending = None
        else:
            # Flush any dangling pending run before starting a new one.
            if pending is not None:
                head, parts = pending
                cases.append((head, parts))
                pending = None
            if entry.size_kb == 0 and entry.overwrite is False:
                # Start of multi-part run.
                pending = (entry, [entry.pack])
            else:
                cases.append((entry, [entry.pack]))

    if pending is not None:
        cases.append(pending)

    # First pass: select runnable jobs, resolve pack parts, concatenate
    # multi-part archive bytes.  Each job becomes a (bytes, dst_dir,
    # final_name) tuple suitable for wpack_unpack_batch.
    batch_jobs: list[tuple[bytes, Path, str]] = []
    stats = {"installed": 0, "skipped_filter": 0, "skipped_nopack": 0,
             "multi_part": 0}
    for entry, parts in cases:
        if not entry_selected(entry, selected):
            stats["skipped_filter"] += 1
            continue
        if entry.dir_id not in dirs:
            raise SystemExit(f"[Files] entry references unknown dir ID {entry.dir_id}: {entry}")
        dest_dir = dirs[entry.dir_id]

        part_paths: list[Path] = []
        missing_part = False
        for part in parts:
            for candidate in (part, part.upper(), part.lower()):
                cand = source_dir / candidate
                if cand.is_file():
                    part_paths.append(cand)
                    break
            else:
                missing_part = True
                break
        if missing_part:
            stats["skipped_nopack"] += 1
            continue
        if len(part_paths) > 1:
            stats["multi_part"] += 1

        buf = bytearray()
        for p in part_paths:
            with open(p, "rb") as fh:
                buf.extend(fh.read())
        batch_jobs.append((bytes(buf), dest_dir, entry.dest))

    # Second pass: dispatch in fixed-size batches, one dosemu2 invocation
    # per batch.  This eliminates the per-file DOS boot overhead (≈1–2 s
    # each) that would otherwise dominate the runtime.  Order within and
    # between batches is preserved (declaration order of [Files]).
    #
    # Batch size is a tradeoff: too small → boot overhead dominates; too
    # large → DOS command.com may hit BAT-file or open-file limits, and
    # a single failure wastes more work on retry.  50 was empirically
    # safe for 9.5 / 9.01d installers; the LA disc has ~660 files so
    # this gives ~14 batches.
    BATCH_SIZE = int(os.environ.get("WATCOM_SETUP_INF_BATCH", "50"))
    total = len(batch_jobs)
    print(f"[setup-inf] unpacking {total} files in batches of {BATCH_SIZE}")
    for start in range(0, total, BATCH_SIZE):
        batch = batch_jobs[start:start + BATCH_SIZE]
        end = start + len(batch)
        print(f"[setup-inf]   batch {start + 1}–{end} of {total}")
        wpack_unpack_batch(batch, watcom_tools=watcom_tools)
        stats["installed"] += len(batch)

    print(f"[setup-inf] installed         {stats['installed']}")
    print(f"[setup-inf] multi-part packs  {stats['multi_part']}")
    print(f"[setup-inf] skipped (filter)  {stats['skipped_filter']}")
    print(f"[setup-inf] skipped (nopack)  {stats['skipped_nopack']}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--inf", required=True)
    ap.add_argument("--source", required=True)
    ap.add_argument("--dest", required=True)
    ap.add_argument("--watcom-tools", required=True)
    ap.add_argument("--selection", default="all-yes", choices=["all-yes"])
    args = ap.parse_args()

    run(
        inf_path=Path(args.inf),
        source_dir=Path(args.source),
        dst_dir=Path(args.dest),
        watcom_tools=Path(args.watcom_tools),
        selection_mode=args.selection,
    )


if __name__ == "__main__":
    main()
