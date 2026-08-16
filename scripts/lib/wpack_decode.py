#!/usr/bin/env python3
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
"""
Python port of Open Watcom's wpack decoder (bld/wpack/c/decode.c).

Supports both NoShannonDecode (7+9-bit LZSS) and DoDecode (Shannon-Fano LZSS).

Scope
=====
Validated against the WPK archives on the Watcom C/C++ **10.5 and 10.6**
media, which is what the 10.5/10.6 extract scripts use it for.

It does **not** correctly decode the 9.x-era archives (the 9.5 floppies,
the February 1993 9.5 beta, 8.5, 9.01). Those carry the same 0x2403
signature and the same version 1.1 header, parse cleanly, and pass the
stored CRC — but the compressed stream is a variant this port does not
reproduce, so the output is wrong. That failure used to be silent; it now
raises WpackError whenever the decoded length does not match the
directory, which catches most of these. Where the wrong output happens to
land on the right length it cannot be detected from the archive alone,
because the format stores no checksum of the decoded bytes.

For 9.x-era archives use the original DOS tool instead: wpack_unpack() in
scripts/lib/common.sh runs the real wpack.exe under dosemu2. That is the
path every 8.5/9.0x/9.5 extract script already takes.

Integrity checking
==================
The CRC-32 in each directory entry covers the entry's **compressed**
bytes, not the decoded output. verify_entry_crc() checks it, which proves
the archive is intact but says nothing about whether the decoder
understood it. Treat the two checks as answering different questions.
"""

import struct
import zlib, sys

STRBUF_SIZE = 4096
LAHEAD_SIZE = 60
THRESHOLD = 2
NUM_CHARS = 256 - THRESHOLD + LAHEAD_SIZE  # 314
MAX_CODE_BITS = 16

WPACK_SIGNATURE = 0x2403
NO_SHANNON_CODE = 0x80
NAMELEN_MASK    = 0x7F

# d_code: upper 6 bits of position decoded from a byte
# d_len:  number of bits to consume for that byte
def _build_dcode_dlen():
    # From decode.c: the pattern is doubled/halved run lengths
    d_code = [0]*256
    d_len  = [0]*256
    # Decoded from the C source:
    # d_code maps input byte -> high 6 bits of position
    # d_len  maps input byte -> total bit length of position code
    runs_code = [
        (32, 0x00), (16, 0x01), (16, 0x02), (16, 0x03),
        ( 8, 0x04), ( 8, 0x05), ( 8, 0x06), ( 8, 0x07),
        ( 8, 0x08), ( 8, 0x09), ( 8, 0x0A), ( 8, 0x0B),
        ( 4, 0x0C), ( 4, 0x0D), ( 4, 0x0E), ( 4, 0x0F),
        ( 4, 0x10), ( 4, 0x11), ( 4, 0x12), ( 4, 0x13),
        ( 4, 0x14), ( 4, 0x15), ( 4, 0x16), ( 4, 0x17),
        ( 2, 0x18), ( 2, 0x19), ( 2, 0x1A), ( 2, 0x1B),
        ( 2, 0x1C), ( 2, 0x1D), ( 2, 0x1E), ( 2, 0x1F),
        ( 2, 0x20), ( 2, 0x21), ( 2, 0x22), ( 2, 0x23),
        ( 2, 0x24), ( 2, 0x25), ( 2, 0x26), ( 2, 0x27),
        ( 2, 0x28), ( 2, 0x29), ( 2, 0x2A), ( 2, 0x2B),
        ( 2, 0x2C), ( 2, 0x2D), ( 2, 0x2E), ( 2, 0x2F),
        ( 1, 0x30), ( 1, 0x31), ( 1, 0x32), ( 1, 0x33),
        ( 1, 0x34), ( 1, 0x35), ( 1, 0x36), ( 1, 0x37),
        ( 1, 0x38), ( 1, 0x39), ( 1, 0x3A), ( 1, 0x3B),
        ( 1, 0x3C), ( 1, 0x3D), ( 1, 0x3E), ( 1, 0x3F),
    ]
    i = 0
    for n, v in runs_code:
        for _ in range(n):
            d_code[i] = v
            i += 1
    assert i == 256, i

    runs_len = [
        (32, 3), (48, 4), (64, 5), (48, 6), (48, 7), (16, 8),
    ]
    i = 0
    for n, v in runs_len:
        for _ in range(n):
            d_len[i] = v
            i += 1
    assert i == 256, i
    return d_code, d_len

d_code, d_len = _build_dcode_dlen()

MASK = [0, 1, 3, 7, 0xF, 0x1F, 0x3F, 0x7F, 0xFF]


class BitReader:
    """Bit-level reader matching decode.c's getbuf/secondbuf/getlen state machine.

    DecReadByte() reads raw bytes from the input stream. Neither getbuf nor
    secondbuf is primed at construction time — callers (make_shannon_trie,
    no_shannon_decode, do_decode) reset the bit state themselves at the right
    moment, matching the C reference implementation.
    """
    def __init__(self, data, offset):
        self.data = data
        self.pos = offset
        self.getbuf = 0
        self.getlen = 0
        self.secondbuf = 0

    def _raw(self):
        if self.pos >= len(self.data):
            return 0
        b = self.data[self.pos]
        self.pos += 1
        return b


def no_shannon_decode(textsize, br):
    """Mirror of NoShannonDecode(). Returns decoded bytes."""
    out = bytearray()
    if textsize == 0:
        return bytes(out)
    # text_buf is a C global: bytes 0..STRBUF_SIZE-LAHEAD_SIZE = ' ',
    # bytes STRBUF_SIZE-LAHEAD_SIZE..STRBUF_SIZE = 0x00 (BSS).
    text_buf = bytearray(b' ' * (STRBUF_SIZE - LAHEAD_SIZE) + b'\x00' * LAHEAD_SIZE)
    r = STRBUF_SIZE - LAHEAD_SIZE
    br.getbuf = 0
    br.getlen = 0
    br.secondbuf = br._raw()
    count = 0
    while count < textsize:
        if br.getlen == 0:
            br.getbuf = ((br.secondbuf << 8) | br._raw()) & 0xFFFF
            br.getlen = 16
            br.secondbuf = br._raw()
        elif br.getlen <= 8:
            br.getbuf = (br.getbuf | (br.secondbuf << (8 - br.getlen))) & 0xFFFF
            br.getlen += 8
            br.secondbuf = br._raw()
        if br.getbuf & 0x8000:  # copy command
            j = (br.getbuf >> 9) & 0x3F
            br.getlen -= 7
            br.getbuf = (br.getbuf << 7) & 0xFFFF
            i = (r - decode_position(br) - 1) & (STRBUF_SIZE - 1)
            for k in range(j):
                c = text_buf[(i + k) & (STRBUF_SIZE - 1)]
                text_buf[r] = c
                out.append(c)
                r = (r + 1) & (STRBUF_SIZE - 1)
            count += j
        else:
            c = (br.getbuf >> 7) & 0xFF
            br.getbuf = (br.getbuf << 9) & 0xFFFF
            br.getlen -= 9
            out.append(c)
            text_buf[r] = c
            r = (r + 1) & (STRBUF_SIZE - 1)
            count += 1
    return bytes(out)


def get_byte(br):
    """Mirror of GetByte(): consume 8 bits and return them."""
    i = (br.getbuf >> 8) & 0xFF
    if br.getlen >= 8:
        br.getbuf = (br.getbuf << 8) & 0xFFFF
        br.getlen -= 8
    else:
        br.getbuf = br.secondbuf
        i |= br.getbuf >> br.getlen
        i &= 0xFF
        br.getbuf = (br.getbuf << (16 - br.getlen)) & 0xFFFF
        br.secondbuf = br._raw()
    return i


def decode_position(br):
    i = get_byte(br)
    c = d_code[i] << 6
    j = d_len[i]
    j -= 2
    if j > br.getlen:
        br.getbuf = (br.getbuf | (br.secondbuf << (8 - br.getlen))) & 0xFFFF
        br.getlen += 8
        br.secondbuf = br._raw()
    i = ((i << j) | (br.getbuf >> (16 - j))) & 0xFFFF
    br.getbuf = (br.getbuf << j) & 0xFFFF
    br.getlen -= j
    return c | (i & 0x3F)


class ShannonTable:
    def __init__(self):
        self.MinVal    = [0xFFFF] * (MAX_CODE_BITS + 1)
        self.MapOffset = [0] * (MAX_CODE_BITS + 1)
        self.CharMap   = [0] * NUM_CHARS
        self.MinCodeLen = 0
        self.length    = [0] * NUM_CHARS   # len[] in C
        self.indicies  = [0] * NUM_CHARS


def make_shannon_trie(br):
    st = ShannonTable()
    curr = 0
    num  = 0
    numcoded = br._raw() + 1
    while numcoded > 0:
        entry = br._raw()
        if entry & 0x80:
            curr += (entry & 0x7F) + 1
        else:
            entrynum = (entry >> 4) + 1
            entrylen = (entry & 0xF) + 1
            for _ in range(entrynum):
                st.indicies[num] = curr
                st.length[curr]  = entrylen
                num += 1
                curr += 1
        numcoded -= 1
    _assign_codes(st, num)
    return st


def wpack_qsort(arr, cmp):
    """In-place port of OW2 bld/wpack/c/wqsort.c::wpack_qsort.

    The decoder relies on the EXACT ordering wpack_qsort produces for
    equal-length codes (same algorithm is used by the encoder when
    assigning bit patterns, so decoder must mirror it byte-for-byte).
    A plain Python stable sort DOES NOT produce the same result.

    This is a Bentley-McIlroy 3-way partition quicksort with a 2-gap
    shell sort fallback for n < 16.
    """
    SHELL = 3
    stack = []
    lo = 0
    n = len(arr)

    def shell_sort(lo, n):
        gap = SHELL
        while gap > 0:
            p1 = lo + gap
            while p1 < lo + n:
                p2 = p1
                while p2 > lo and cmp(arr[p2 - gap], arr[p2]) > 0:
                    arr[p2], arr[p2 - gap] = arr[p2 - gap], arr[p2]
                    p2 -= gap
                p1 += gap
            gap -= (SHELL - 1)

    def med3(a, b, c):
        if cmp(arr[a], arr[b]) > 0:
            if cmp(arr[a], arr[c]) > 0:
                return b if cmp(arr[b], arr[c]) > 0 else c
            return a
        else:
            if cmp(arr[a], arr[c]) >= 0:
                return a
            return c if cmp(arr[b], arr[c]) > 0 else b

    while True:
        while n > 1:
            if n < 16:
                shell_sort(lo, n)
                break
            mid = lo + (n >> 1)
            if n > 29:
                p1 = lo
                p2 = lo + n - 1
                if n > 42:
                    s = n >> 3
                    p1  = med3(p1, p1 + s, p1 + (s << 1))
                    mid = med3(mid - s, mid, mid + s)
                    p2  = med3(p2 - (s << 1), p2 - s, p2)
                mid = med3(p1, mid, p2)
            # swaptype=0 path: pivot stored OUT OF LINE (C: pv = &v; v = *mid).
            # base is NOT disturbed. Our list elements are int — always
            # word-size in C — so we always take this branch.
            pivot = arr[mid]
            pa = pb = lo
            pc = pd = lo + n - 1
            while True:
                while pb <= pc:
                    c = cmp(arr[pb], pivot)
                    if c > 0:
                        break
                    if c == 0:
                        arr[pa], arr[pb] = arr[pb], arr[pa]
                        pa += 1
                    pb += 1
                while pc >= pb:
                    c = cmp(arr[pc], pivot)
                    if c < 0:
                        break
                    if c == 0:
                        arr[pc], arr[pd] = arr[pd], arr[pc]
                        pd -= 1
                    pc -= 1
                if pb > pc:
                    break
                arr[pb], arr[pc] = arr[pc], arr[pb]
                pb += 1
                pc -= 1
            pn = lo + n
            # swap equal-to-pivot chunks back to middle
            s1 = min(pa - lo, pb - pa)
            for i in range(s1):
                arr[lo + i], arr[pb - s1 + i] = arr[pb - s1 + i], arr[lo + i]
            s2 = min(pd - pc, pn - pd - 1)
            for i in range(s2):
                arr[pb + i], arr[pn - s2 + i] = arr[pn - s2 + i], arr[pb + i]
            r = pb - pa
            s = pd - pc
            if s >= r:
                stack.append((pn - s, s))
                n = r
            else:
                if r <= 1:
                    break
                stack.append((lo, r))
                lo = pn - s
                n = s
        if not stack:
            break
        lo, n = stack.pop()


def _assign_codes(st, num):
    # Sort indicies[0..num) by length ascending using OW2's EXACT sort —
    # Python's stable sort produces wrong order for equal-length entries.
    sub = st.indicies[:num]
    wpack_qsort(sub, lambda a, b: st.length[a] - st.length[b])
    st.indicies[:num] = sub
    codeval = 0
    codeinc = 0
    lastlen = 0
    curroffset = 0
    st.MinCodeLen = st.length[st.indicies[0]]
    for index in range(num - 1, -1, -1):
        codeval = (codeval + codeinc) & 0xFFFF
        L = st.length[st.indicies[index]]
        if L != lastlen:
            lastlen = L
            codeinc = 1 << (16 - lastlen)
            st.MinVal[lastlen]    = codeval
            st.MapOffset[lastlen] = curroffset
        st.CharMap[curroffset] = st.indicies[index]
        curroffset += 1


def do_decode(textsize, br):
    out = bytearray()
    if textsize == 0:
        return bytes(out)
    st = make_shannon_trie(br)
    br.getbuf = 0
    br.getlen = 0
    br.secondbuf = br._raw()
    # text_buf is a C global: bytes 0..STRBUF_SIZE-LAHEAD_SIZE = ' ',
    # bytes STRBUF_SIZE-LAHEAD_SIZE..STRBUF_SIZE = 0x00 (BSS).
    text_buf = bytearray(b' ' * (STRBUF_SIZE - LAHEAD_SIZE) + b'\x00' * LAHEAD_SIZE)
    r = STRBUF_SIZE - LAHEAD_SIZE
    count = 0
    while count < textsize:
        if br.getlen < 8:
            br.getbuf = (br.getbuf | (br.secondbuf << (8 - br.getlen))) & 0xFFFF
            br.getlen += 8
            br.secondbuf = br._raw()
        spare = br.getlen - 8
        br.getlen = 16
        br.getbuf = (br.getbuf | (br.secondbuf >> spare)) & 0xFFFF
        codelen = st.MinCodeLen
        while True:
            if br.getbuf >= st.MinVal[codelen]:
                break
            codelen += 1
            if codelen > MAX_CODE_BITS:
                raise RuntimeError(f"invalid code at count={count}")
        c = st.CharMap[st.MapOffset[codelen] +
                       ((br.getbuf - st.MinVal[codelen]) >> (16 - codelen))]
        br.getbuf = (br.getbuf << codelen) & 0xFFFF
        br.getlen -= codelen
        if spare > codelen:
            br.getlen -= 8 - spare
        else:
            br.getbuf = (br.getbuf | ((br.secondbuf & MASK[spare]) << (codelen - spare))) & 0xFFFF
            br.getlen += spare
            br.secondbuf = br._raw()
        if c < 256:
            out.append(c)
            text_buf[r] = c
            r = (r + 1) & (STRBUF_SIZE - 1)
            count += 1
        else:
            i = (r - decode_position(br) - 1) & (STRBUF_SIZE - 1)
            j = c - 255 + THRESHOLD  # c - 253
            for k in range(j):
                cc = text_buf[(i + k) & (STRBUF_SIZE - 1)]
                text_buf[r] = cc
                out.append(cc)
                r = (r + 1) & (STRBUF_SIZE - 1)
            count += j
    return bytes(out)


class WpackError(Exception):
    """Raised for a malformed archive or a decode that cannot be trusted."""


def parse_wpack(data):
    """Parse wpack header and file directory. Tries both 12- and 16-byte headers."""
    if len(data) < 12:
        raise WpackError(f"too short to be a wpack archive: {len(data)} bytes")
    sig, maj, min_, nfiles, info_len, info_off = struct.unpack_from('<HBBHHI', data, 0)
    if sig != WPACK_SIGNATURE:
        raise WpackError(f"bad signature: {hex(sig)} (expected {hex(WPACK_SIGNATURE)})")
    if not 0 < info_off <= len(data):
        raise WpackError(
            f"directory offset {info_off} outside archive ({len(data)} bytes)")
    if nfiles == 0:
        raise WpackError("archive declares zero files")
    # 16-byte header includes `internal` field
    # v1.1 archives (Watcom 10.5) have a 12-byte header with no `internal`
    # field. v1.3 archives (OW2) add a 4-byte `internal` at offset 12.
    # The decoder does not need `internal`; it's a weak access-control key.
    if min_ >= 3 and len(data) >= 16:
        internal = struct.unpack_from('<I', data, 12)[0]
    else:
        internal = 0

    files = []
    off = info_off
    for _ in range(nfiles):
        if off + 17 > len(data):
            raise WpackError("file directory runs past the end of the archive")
        length, disk_addr, stamp, crc, namelen_b = struct.unpack_from('<IIIIB', data, off)
        if not 0 < disk_addr < info_off:
            raise WpackError(
                f"data offset {disk_addr} outside the compressed region")
        no_shannon = bool(namelen_b & NO_SHANNON_CODE)
        namelen = namelen_b & NAMELEN_MASK
        name = data[off+17:off+17+namelen].decode('latin-1')
        files.append({
            'length': length, 'disk_addr': disk_addr, 'stamp': stamp, 'crc': crc,
            'namelen': namelen, 'no_shannon': no_shannon, 'name': name,
        })
        # file_info layout (verified against DOSSETUP.EXE ReadHeader in Ghidra,
        # matches OW2 bld/wpack/c/common.c::ReadHeader):
        #   u32 length; u32 disk_addr; u32 stamp; u32 crc;   -- 16 bytes
        #   u8  namelen_b;                                   -- 1 byte
        #   char name[namelen];                              -- variable
        # Total record size = 17 + namelen. Next record at off + 17 + namelen.
        off += 17 + namelen
    return files


def entry_extents(files, info_off):
    """Map each entry to the [start, end) span of its compressed bytes.

    Entries store only their start (disk_addr); an entry runs until the
    next entry's start, and the last one ends where the file directory
    begins. Entries are not required to appear in offset order, so sort
    before pairing them up.
    """
    starts = sorted(f['disk_addr'] for f in files)
    next_start = {s: (starts[i + 1] if i + 1 < len(starts) else info_off)
                  for i, s in enumerate(starts)}
    return {f['disk_addr']: (f['disk_addr'], next_start[f['disk_addr']])
            for f in files}


def verify_entry_crc(data, finfo, extents):
    """Check the stored CRC-32 of an entry's *compressed* bytes.

    The CRC in the file directory covers the compressed stream, not the
    decoded output, so this proves the archive arrived intact. It says
    nothing about whether the decoder understood it — see decode_entry.
    """
    start, end = extents[finfo['disk_addr']]
    actual = zlib.crc32(data[start:end]) & 0xFFFFFFFF
    if actual != finfo['crc']:
        raise WpackError(
            f"{finfo['name']}: CRC mismatch on compressed data "
            f"(stored 0x{finfo['crc']:08x}, computed 0x{actual:08x}) — "
            "the archive is corrupt or truncated")


def decode_entry(data, finfo):
    """Decode one parse_wpack() entry and return the raw bytes.

    Raises WpackError if the decoder does not land on exactly the declared
    uncompressed length. That is the only correctness signal the format
    offers: the stored CRC covers the compressed stream, so a decoder that
    misreads an archive can still produce CRC-clean garbage.
    """
    br = BitReader(data, finfo['disk_addr'])
    if finfo['no_shannon']:
        out = no_shannon_decode(finfo['length'], br)
    else:
        out = do_decode(finfo['length'], br)
    if len(out) != finfo['length']:
        raise WpackError(
            f"{finfo['name']}: decoded {len(out)} bytes but the directory "
            f"declares {finfo['length']} — this archive is not in a variant "
            "this decoder understands (see the module docstring)")
    return out


def unpack_archive(pack_path, out_dir, verbose=False):
    """Parse the WPK archive at pack_path and write every file inside it
    into out_dir (lowercased names). Returns the list of output filenames.
    """
    import os
    data = open(pack_path, 'rb').read()
    info_off = struct.unpack_from('<I', data, 8)[0]
    os.makedirs(out_dir, exist_ok=True)
    written = []
    files = parse_wpack(data)
    extents = entry_extents(files, info_off)
    for f in files:
        verify_entry_crc(data, f, extents)
        out = decode_entry(data, f)
        path = os.path.join(out_dir, f['name'].lower())
        open(path, 'wb').write(out)
        written.append(f['name'].lower())
        if verbose:
            print(f"  {f['name']}: {len(out)} bytes", file=sys.stderr)
    return written


def main():
    if len(sys.argv) < 2:
        print("usage: wpack-decode.py PACKFILE [OUTDIR]", file=sys.stderr)
        sys.exit(1)
    packfile = sys.argv[1]
    outdir = sys.argv[2] if len(sys.argv) > 2 else "."
    unpack_archive(packfile, outdir, verbose=True)


if __name__ == '__main__':
    main()
