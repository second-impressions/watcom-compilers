#!/usr/bin/env python3
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
"""
iso_extract.py — extract an ISO 9660 image to a directory.

Usage:
    iso_extract.py ISO DEST_DIR [--lowercase]

A minimal, tolerant ISO 9660 reader. Written because:

- `bsdtar` / `7z` / `xorriso` / `pycdlib` all abort on the WinWorld
  Watcom 11.0b master CD because its directory records have a harmless
  LE/BE sequence-number mismatch and a slightly odd padding byte near
  the end of one directory extent.
- `isoinfo` (genisoimage) is permissive enough to print most of the
  listing but still bails halfway through, silently truncating 5 000+
  entries.
- `fuseiso` reads the entire image correctly but needs `/dev/fuse`,
  which is not available during `podman build`.

The code here walks the directory tree from the Primary Volume
Descriptor's root record, following `extent_lba` + `data_length` for
each subdirectory; it reads file contents as a contiguous run of
logical blocks at `extent_lba * block_size`. Nothing past that is
validated.

Limitations: no Joliet, no Rock Ridge, no multi-extent files, no
interleave. These are not needed for any ISO in this collection.
"""

import argparse
import os
import struct
import sys

BLOCK = 2048  # ISO 9660 logical block size; always 2048 in practice.


class ISOReader:
    def __init__(self, fp):
        self.fp     = fp
        self.skipped = []   # names skipped for containing control bytes

    def read_block(self, lba, nblocks=1):
        self.fp.seek(lba * BLOCK)
        return self.fp.read(nblocks * BLOCK)

    def find_pvd(self):
        """Scan volume descriptors starting at LBA 16. Return the PVD bytes."""
        for i in range(16, 32):  # 16..31 is more than enough
            blk = self.read_block(i)
            if not blk or len(blk) < 7:
                raise ValueError("ISO truncated before any volume descriptor")
            vd_type = blk[0]
            std_id  = blk[1:6]
            if std_id != b"CD001":
                raise ValueError(f"bad volume descriptor id {std_id!r} at LBA {i}")
            if vd_type == 1:          # Primary Volume Descriptor
                return blk
            if vd_type == 255:        # Volume Descriptor Set Terminator
                raise ValueError("no PVD found before terminator")
        raise ValueError("no PVD found in first 16 volume descriptors")

    def parse_root(self, pvd):
        """Return (root_lba, root_len) from the PVD's root directory record."""
        # The root directory record is a 34-byte embedded directory record
        # at PVD offset 156. extent_lba (LE) is at +2, data_length (LE) at +10.
        rec = pvd[156:156 + 34]
        root_lba    = struct.unpack_from("<I", rec, 2)[0]
        root_length = struct.unpack_from("<I", rec, 10)[0]
        return root_lba, root_length

    def iter_dir(self, lba, length):
        """Yield directory records from the extent at `lba` for `length` bytes.

        Each record is:
            u8  length
            u8  ext_attr_length
            u32 extent_lba_le, u32 extent_lba_be
            u32 data_length_le, u32 data_length_be
            u8  date[7]
            u8  flags              # bit 1 = is_dir
            u8  file_unit_size
            u8  interleave_gap
            u16 vol_seq_le, u16 vol_seq_be
            u8  name_length
            u8  name[name_length]
            u8  [pad to even]
            u8  system_use[...]    # rest of record
        """
        # Read the whole extent in one go.
        nblocks = (length + BLOCK - 1) // BLOCK
        self.fp.seek(lba * BLOCK)
        data = self.fp.read(nblocks * BLOCK)

        offset = 0
        while offset < length:
            reclen = data[offset]
            if reclen == 0:
                # Padding to next logical block boundary.
                offset = (offset + BLOCK) & ~(BLOCK - 1)
                continue
            rec = data[offset:offset + reclen]
            extent_lba  = struct.unpack_from("<I", rec,  2)[0]
            data_length = struct.unpack_from("<I", rec, 10)[0]
            flags       = rec[25]
            name_len    = rec[32]
            name        = rec[33:33 + name_len]
            is_dir      = bool(flags & 0x02)

            # Skip "." / ".." (ISO 9660 reserved) and any entry whose
            # name contains bytes that cannot legally appear in a
            # filename (NULs, control codes). The WinWorld 11.0b ISO
            # has a handful of records with garbage names near extent
            # boundaries; they are safe to skip.
            if name in (b"", b"\x00", b"\x01"):
                pass  # reserved/empty, not a real entry
            elif b"\x00" in name or any(b < 0x20 for b in name):
                self.skipped.append(name)
            else:
                yield {
                    "name":       name.decode("latin-1"),
                    "lba":        extent_lba,
                    "length":     data_length,
                    "is_dir":     is_dir,
                }
            offset += reclen


def _xform(name, lowercase):
    """Strip `;N` version suffix and an orphan trailing dot from each
    path component; optionally lowercase."""
    base = name.split(";", 1)[0].rstrip(".")
    return base.lower() if lowercase else base


def extract(iso_path, dest, lowercase=False):
    file_count = 0
    byte_count = 0
    iso = None

    with open(iso_path, "rb") as fp:
        iso = ISOReader(fp)
        pvd = iso.find_pvd()
        root_lba, root_len = iso.parse_root(pvd)

        # BFS walk so parents are created before children.
        stack = [(root_lba, root_len, dest)]
        while stack:
            lba, length, out_dir = stack.pop()
            os.makedirs(out_dir, exist_ok=True)
            for rec in iso.iter_dir(lba, length):
                name_out = _xform(rec["name"], lowercase)
                if not name_out:
                    continue
                out_path = os.path.join(out_dir, name_out)
                if rec["is_dir"]:
                    stack.append((rec["lba"], rec["length"], out_path))
                    continue
                # Regular file: read data_length bytes from extent_lba.
                fp.seek(rec["lba"] * BLOCK)
                remaining = rec["length"]
                with open(out_path, "wb") as w:
                    while remaining > 0:
                        chunk = fp.read(min(remaining, 1 << 20))
                        if not chunk:
                            raise EOFError(
                                f"unexpected EOF reading {out_path!r} "
                                f"(lba={rec['lba']} length={rec['length']})")
                        w.write(chunk)
                        remaining -= len(chunk)
                file_count += 1
                byte_count += rec["length"]

    return file_count, byte_count, iso.skipped


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("iso",       help="Path to the ISO 9660 image")
    ap.add_argument("dest_dir",  help="Destination directory (created if absent)")
    ap.add_argument("--lowercase", action="store_true",
                    help="Lowercase all extracted paths")
    args = ap.parse_args()

    if not os.path.isfile(args.iso):
        print(f"error: ISO not found: {args.iso}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(args.dest_dir, exist_ok=True)
    nfiles, nbytes, skipped = extract(args.iso, args.dest_dir,
                                      lowercase=args.lowercase)
    print(f"iso-extract: {nfiles} files, {nbytes} bytes \u2192 {args.dest_dir}")
    if skipped:
        print(f"iso-extract: skipped {len(skipped)} records with non-printable "
              f"names:", file=sys.stderr)
        for n in skipped:
            print(f"  {n!r}", file=sys.stderr)


if __name__ == "__main__":
    main()
