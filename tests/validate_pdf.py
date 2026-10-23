#!/usr/bin/env python3
"""Validate RAD_PDF byte offsets, stream lengths and zlib streams independently.

Usage: python3 tests/validate_pdf.py file.pdf [other.pdf ...]
Uses only Python's standard library. Text/layout validation can additionally use
Poppler's pdftotext -layout / -bbox-layout on the same generated files.
"""
import re
import sys
import zlib
from pathlib import Path


def validate(path: Path) -> None:
    data = path.read_bytes()
    assert data.startswith(b"%PDF-"), "missing PDF header"
    trailer = re.search(rb"startxref\s+(\d+)\s+%%EOF\s*\Z", data)
    assert trailer, "missing final trailer"
    offset = int(trailer[1])
    xref = re.match(rb"xref\s+0 (\d+)\s*\r?\n", data[offset:])
    assert xref, "startxref does not point to xref"
    count = int(xref[1])
    entries = data[offset + xref.end():].splitlines()[:count]
    assert len(entries) == count and entries[0] == b"0000000000 65535 f", "invalid xref size/free entry"
    positions = []
    for number, entry in enumerate(entries[1:], 1):
        assert re.fullmatch(rb"\d{10} 00000 n", entry), f"invalid xref entry {number}"
        pos = int(entry[:10])
        assert data[pos:].startswith(f"{number} 0 obj".encode() + b"\r\n"), f"invalid offset for object {number}"
        positions.append(pos)
    assert positions == sorted(positions), "objects out of order"
    streams = 0
    compressed = 0
    for start, end in zip(positions, positions[1:] + [offset]):
        obj = data[start:end]
        marker = re.search(rb"\nstream\r?\n", obj)
        if not marker:
            continue
        header = obj[:marker.start()]
        length = re.search(rb"/Length\s+(\d+)\b", header)
        assert length, "stream missing direct length"
        payload_end = marker.end() + int(length[1])
        assert re.match(rb"\r?\nendstream\s+endobj", obj[payload_end:]), "incorrect stream length/EOL"
        payload = obj[marker.end():payload_end]
        streams += 1
        if b"/FlateDecode" in header:
            decoder = zlib.decompressobj()
            decoder.decompress(payload)
            assert decoder.eof and not decoder.unused_data, "invalid zlib boundary/checksum"
            compressed += 1
    print(f"PASS {path.name}: {count - 1} objects, {streams} streams, {compressed} zlib, {len(data)} bytes")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    for filename in sys.argv[1:]:
        validate(Path(filename))
