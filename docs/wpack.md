# WPK archive format (Watcom Install Archiver)

Watcom's install archives are stored in a container format called WPK,
produced and consumed by `wpack.exe` / `INSTALL.EXE` / `DOSSETUP.EXE`
(depending on the release). Two format variants are relevant:

| Variant | Releases | Header size | `internal` field |
|---------|----------|-------------|------------------|
| v1.0    | 9.01d, 9.5 | 12 bytes | absent |
| v1.1    | 10.0, 10.5 | 12 bytes | absent |
| v1.3    | Open Watcom v2 | 16 bytes | 4-byte access key |

## On-disk layout

```
offset  size  field
  0      2    sig          0x2403 ("#$" little-endian)
  2      1    major_ver    1
  3      1    minor_ver    1 (10.5) or 3 (OW2)
  4      2    nfiles       number of files in archive
  6      2    info_len     directory block length in bytes
  8      4    info_off     offset of directory block from start of archive
 [12     4    internal     OW2 only — ignored by decoder]
```

Compressed streams follow the header contiguously. The directory block
sits at `info_off` and contains `nfiles` `file_info` records, each:

```
offset  size  field
  0      4    length       uncompressed size
  4      4    disk_addr    offset of compressed stream (from start of archive)
  8      4    stamp        DOS date/time stamp
 12      4    crc          CRC-32 of uncompressed bytes
 16      1    namelen_b    high bit = NO_SHANNON_CODE, low 7 bits = namelen
 17   namelen name         filename (no NUL terminator)
```

## Compression

Two-stage:

1. **LZSS** — 4 KiB sliding window (`text_buf[4096]`, initialised to
   spaces except the last 60 bytes which are zero from BSS), look-ahead
   60 bytes, minimum match 3. Each token is either a literal or a
   `(position, length)` back-reference.
2. **Shannon-Fano** — token fields (literals, lengths, and high 6 bits
   of positions) are coded separately using canonical Shannon-Fano
   codes built from a per-archive frequency trie serialised at the
   start of the stream.

The `NO_SHANNON_CODE` flag in `namelen_b` selects a plain LZSS variant
with fixed-width fields instead of Shannon-Fano coding. Small or
already-compressed files use this path.

## Reference decoder

`scripts/lib/wpack_decode.py` is a self-contained Python port of the
Open Watcom v2 decoder (`bld/wpack/c/decode.c`). It handles both v1.1
and v1.3 headers transparently.

Correctness is verified against a reference install tree produced by
the original `DOSSETUP.EXE` under DOSBox-X: of the 6 789 WPK entries
across the 10.5 ISO, 6 667 matched byte-for-byte and the remaining 122
are variants not present in the reference install (alternate platform
targets, unselected components). Zero mismatches.

### Using the decoder standalone

```
python3 scripts/lib/wpack_decode.py PACKFILE [OUTDIR]
```

### Using it programmatically

```python
import sys
sys.path.insert(0, "scripts/lib")
import wpack_decode

files = wpack_decode.unpack_archive("disk01/PCK00001", out_dir="./out")
```

## Non-trivial details worth preserving

- **Equal-length codes sort-order matters.** Encoder and decoder must
  agree on the Shannon-Fano code assignment for characters with equal
  code lengths. The C encoder uses the Bentley–McIlroy 3-way partition
  qsort from `bld/wpack/c/wqsort.c`, which is unstable, so a naive port
  using Python's stable `sorted()` produces garbled output. The Python
  decoder includes a faithful port of `wpack_qsort`.

- **`text_buf` initialisation.** The first 4036 bytes are 0x20 (space);
  the last 60 bytes are 0x00 (BSS zero-init). Filling all 4 096 bytes
  with spaces was another port bug that produced leading-space leaks.

- **`file_info` prefix is exactly 17 bytes**, not 16. The layout above
  was confirmed via both the OW2 source and the Ghidra decompile of
  the 10.5 `DOSSETUP.EXE::ReadHeader`.
