#!/usr/bin/env python3
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
r"""
setup_inf_manifest.py — interpreter for Watcom's SETUP.INF installer format.

Used by Watcom C/C++ 10.5 (and likely 10.6+). The SETUP.INF file lives in
DISKIMGS/DISK01/ on the CD-ROM ISO and maps WPK pack files to output paths,
similar in spirit to INSTALL.SCR on the 9.5 floppies.

Usage
-----
    setup_inf_manifest.py unpack SETUP_INF DISKS_DIR DEST_DIR
    setup_inf_manifest.py list   SETUP_INF DISKS_DIR DEST_DIR

    SETUP_INF   Path to the SETUP.INF file.
    DISKS_DIR   Directory containing DISK01/, DISK02/, … subdirectories,
                each holding the PCK* pack files from that floppy/disc slot.
    DEST_DIR    Installation destination (created if absent).

WPK decoding is done by the pure-Python decoder in wpack_decode.py
(no external binary needed).

SETUP.INF format
----------------
Sections: [Application], [Targets], [Dirs], [Files].

[Dirs] — one entry per line:
    dirname, target_idx, parent_dir_idx

    target_idx: which [Targets] entry this belongs to (1 = DstDir).
    parent_dir_idx: 1-based index of the parent directory entry (-1 = root).
    Directories are 1-indexed in the order they appear.

[Files] — one entry per line (may span multiple lines with trailing \):
    packfile[.part], nfiles, file1!size1[, file2!size2, …], dir_idx, disk_num,
                     component_idx, flag, condition [condition …]

    packfile   PCK file base name (e.g. pck00017). Optional .1/.2 suffix
               for split packs that must be concatenated before unpacking.
    nfiles     Number of output files in this pack entry (0 = metadata-only,
               skip extraction).
    fileN!sizeN  Output filename + base-36-encoded uncompressed size (the !
               size is used by the original installer for progress display;
               we ignore it).
    dir_idx    1-based index into [Dirs] for the output directory.
    disk_num   Which DISK directory holds this pack file.
    component  Component group index (ignored — we install everything).
    flag       '$' means this pack is a continuation; the pack file is the
               second half of a split that started with a previous entry
               (part suffix .1/.2 already handles the split).
    condition  Space-separated options restricting when to install. We
               install unconditionally (install-all policy).

Split packs: when a pack file is split across two disk images, its name
appears with a .1 suffix in the first entry (nfiles=0, metadata-only) and
a .2 suffix in the second entry (nfiles=N, flag='$'). Both halves must be
concatenated before calling wpack. This script handles that automatically.
"""

import os, sys, re, tempfile, shutil, argparse


def _b36(s):
    """Parse a field that may be decimal or base-36.

    SETUP.INF uses base-36 for any numeric field that could exceed 9 in a
    single character (nfiles, dir_idx, disk_num, comp, size suffixes, …).
    Values 0-9 happen to be valid in both decimal and base-36, which is
    why entries with only small numbers parsed correctly before.
    """
    return int(s, 36)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wpack_decode

def log(msg):
    print(msg, flush=True)

def err(msg):
    print(f"ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Parse SETUP.INF
# ---------------------------------------------------------------------------

def parse_setup_inf(path):
    """Return (dirs, files) where:
      dirs  = list of (dirname, target_idx, parent_idx)   (0-indexed)
      files = list of {pack, parts, filenames, dir_idx, disk}
    """
    with open(path, encoding='latin-1') as f:
        raw = f.read()

    # Join continuation lines (trailing backslash)
    lines = []
    buf = ""
    for line in raw.splitlines():
        s = line.rstrip()
        if s.endswith("\\"):
            # Strip the backslash only; keep trailing comma if present
            buf += s[:-1]
        else:
            buf += s.strip()
            lines.append(buf)
            buf = ""
    if buf:
        lines.append(buf)

    section = None
    dirs  = []   # (dirname, target_idx, parent_idx)  — 0-indexed
    files = []

    for line in lines:
        line = line.strip()
        if not line or line.startswith(";"):
            continue
        m = re.match(r'^\[(.+)\]$', line)
        if m:
            section = m.group(1)
            continue

        if section == "Dirs":
            # dirname, target_idx, parent_idx
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 3:
                dirs.append((parts[0], int(parts[1]), int(parts[2])))

        elif section == "Files":
            # packfile[.part], nfiles, [file!size, ...], dir_idx, disk, comp, flag, cond...
            # All numeric fields are base-36-encoded (except leading `-` for -1).
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 4:
                continue
            pack_raw = parts[0]          # e.g. pck00017.2  or pck00017
            try:
                nfiles = _b36(parts[1])
            except ValueError:
                continue
            if nfiles == 0:
                continue  # metadata-only split header, skip

            # Remaining fields after packfile and nfiles:
            #   file1!size, [file2!size, ...], dir_idx, disk_num, comp, flag, cond
            rest = parts[2:]
            filenames = []
            idx = 0
            while idx < len(rest):
                tok = rest[idx]
                if "!" in tok:
                    filenames.append(tok.split("!")[0])
                    idx += 1
                else:
                    break  # reached numeric fields
            if len(rest) - idx < 2:
                continue
            try:
                dir_idx  = _b36(rest[idx])
                disk_num = int(rest[idx + 1])  # decimal; may be -1
            except ValueError:
                continue

            # Resolve pack base name (strip .1/.2 suffix for lookup).
            # Preserve original case — on case-sensitive filesystems the
            # ISO files are lowercase and uppercasing here silently breaks
            # every lookup, causing wpack to run on an empty concatenation.
            pack_base = re.sub(r'\.\d+$', '', pack_raw)

            files.append({
                "pack":      pack_base,
                "pack_raw":  pack_raw,
                "filenames": filenames,
                "dir_idx":   dir_idx,   # 1-based
                "disk":      disk_num,
            })

    return dirs, files


def resolve_dirs(dirs, dest):
    """Build a mapping dir_idx (1-based) -> absolute path under dest.

    [Dirs] entries are 1-indexed. Each dirname is the full DOS path from
    the entry's target root (1 = DstDir, 2 = windir, 3 = winsys) using
    backslash as separator; parent_idx is informational and is ignored
    here. All target roots are mapped onto `dest` — Windows-system files
    land in the install tree alongside the compilers, which is fine for
    a headless compiler container.
    """
    resolved = {}
    for i, (dirname, target_idx, parent_idx) in enumerate(dirs):
        idx = i + 1  # 1-based
        rel = dirname.replace('\\', '/').lstrip('/')
        if rel in ('', '.'):
            resolved[idx] = dest
        else:
            resolved[idx] = os.path.join(dest, rel)
    return resolved


# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

def find_pack_files(disks_dir, pack_base):
    """Return sorted list of absolute paths for pack_base parts (.1 .2 …),
    or a single un-suffixed file if no parts exist.

    Lookup is case-insensitive so this works on both the case-sensitive
    Linux filesystem (where the ISO mounts with lowercase names) and
    anywhere else the caller might have copied the tree.
    """
    pack_lc = pack_base.lower()
    # Build (disk_dir -> {lowercase_name: real_name}) index once.
    index = {}
    for disk in sorted(os.listdir(disks_dir)):
        disk_path = os.path.join(disks_dir, disk)
        if not os.path.isdir(disk_path):
            continue
        index[disk_path] = {name.lower(): name for name in os.listdir(disk_path)}

    parts = []
    for part_num in range(1, 200):
        needle = f"{pack_lc}.{part_num}"
        hit = None
        for disk_path, names in index.items():
            if needle in names:
                hit = os.path.join(disk_path, names[needle])
                break
        if hit is None:
            break
        parts.append(hit)

    if not parts:
        # Try unsuffixed (single-disk, unsplit pack).
        for disk_path, names in index.items():
            if pack_lc in names:
                return [os.path.join(disk_path, names[pack_lc])]
    return parts


# ---------------------------------------------------------------------------
# WPK extraction
# ---------------------------------------------------------------------------

def unpack(pack_base, disks_dir, out_dir):
    """Concatenate all split parts of pack_base into a single WPK archive
    and decode it with the pure-Python wpack_decode module.

    Returns None on success, or a string describing the failure. Callers must
    treat a returned string as fatal: a partially extracted install tree looks
    superficially fine but is missing binaries, and that has to surface as a
    failed build rather than as log noise.
    """
    parts = find_pack_files(disks_dir, pack_base)
    if not parts:
        return "no parts found on the install disks"

    with tempfile.TemporaryDirectory() as tmp:
        combined = os.path.join(tmp, pack_base)
        with open(combined, "wb") as out:
            for p in parts:
                with open(p, "rb") as f:
                    out.write(f.read())
        try:
            wpack_decode.unpack_archive(combined, out_dir)
        except Exception as e:
            return f"{type(e).__name__}: {e}"
    return None


# ---------------------------------------------------------------------------
# Install driver
# ---------------------------------------------------------------------------

def _do_install(setup_inf, disks_dir, dest_dir):
    """Core install logic shared between the legacy and native subcommands."""
    log(f"setup-inf: parsing {setup_inf}")
    dirs, files = parse_setup_inf(setup_inf)
    log(f"  {len(dirs)} dirs, {len(files)} file entries")

    dir_map = resolve_dirs(dirs, dest_dir)

    seen = {}
    failures = []
    total_files = 0
    for entry in files:
        pack    = entry["pack"]
        out_dir = dir_map.get(entry["dir_idx"], dest_dir)
        os.makedirs(out_dir, exist_ok=True)

        if pack in seen:
            # Pack already extracted; relocate any files destined for a
            # different directory.
            if out_dir != seen[pack]:
                for fname in entry["filenames"]:
                    src = os.path.join(seen[pack], fname.lower())
                    dst = os.path.join(out_dir, fname.lower())
                    if os.path.exists(src):
                        shutil.move(src, dst)
            continue

        log(f"  {pack} → {os.path.relpath(out_dir, dest_dir) or '.'}")
        failure = unpack(pack, disks_dir, out_dir)
        seen[pack] = out_dir
        if failure is None:
            total_files += len(entry["filenames"])
        else:
            log(f"  ERROR: {pack}: {failure}")
            failures.append((pack, failure))

    if failures:
        log(f"setup-inf: {len(failures)} of {len(seen)} packs failed to extract:")
        for pack, why in failures:
            log(f"  {pack}: {why}")
        err(
            f"install tree is incomplete ({len(failures)} pack(s) failed) — "
            "refusing to hand back a partial /opt/watcom"
        )

    log(f"setup-inf: done — approximately {total_files} files installed to {dest_dir}")


def main():
    ap = argparse.ArgumentParser(
        description="Extract a Watcom SETUP.INF install tree",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Subcommands:\n"
            "  unpack SETUP_INF DISKS_DIR DEST_DIR      — extract all pack files\n"
            "  list   SETUP_INF DISKS_DIR DEST_DIR      — list-only (dry run)\n"
        ),
    )
    ap.add_argument("subcommand",
                    choices=["unpack", "list"],
                    help="Action to perform")
    ap.add_argument("setup_inf",  help="Path to SETUP.INF")
    ap.add_argument("disks_dir",  help="Directory containing DISK01/, DISK02/, … subdirs")
    ap.add_argument("dest_dir",   help="Install destination (created if absent)")
    args = ap.parse_args()

    if args.subcommand == "list":
        dirs, files = parse_setup_inf(args.setup_inf)
        dir_map = resolve_dirs(dirs, args.dest_dir)
        for entry in files:
            out_dir = dir_map.get(entry["dir_idx"], args.dest_dir)
            rel = os.path.relpath(out_dir, args.dest_dir) or "."
            for fname in entry["filenames"]:
                print(f"{rel}/{fname.lower()}\t{entry['pack']}")
        return

    # subcommand == "unpack"
    os.makedirs(args.dest_dir, exist_ok=True)
    _do_install(args.setup_inf, args.disks_dir, args.dest_dir)


if __name__ == "__main__":
    main()

