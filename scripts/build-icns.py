#!/usr/bin/env python3
"""Assemble a complete macOS ICNS file from an AppIcon.appiconset directory."""

from __future__ import annotations

import pathlib
import struct
import sys


REPRESENTATIONS = (
    ("icp4", "icon_16x16.png", 16),
    ("ic11", "icon_16x16@2x.png", 32),
    ("icp5", "icon_32x32.png", 32),
    ("ic12", "icon_32x32@2x.png", 64),
    ("ic07", "icon_128x128.png", 128),
    ("ic13", "icon_128x128@2x.png", 256),
    ("ic08", "icon_256x256.png", 256),
    ("ic14", "icon_256x256@2x.png", 512),
    ("ic09", "icon_512x512.png", 512),
    ("ic10", "icon_512x512@2x.png", 1024),
)


def png_size(data: bytes) -> tuple[int, int]:
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError("input is not a PNG with an IHDR header")
    return struct.unpack(">II", data[16:24])


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: build-icns.py APPICON_DIR OUTPUT.icns")

    app_icon_dir = pathlib.Path(sys.argv[1])
    output_path = pathlib.Path(sys.argv[2])
    chunks: list[bytes] = []

    for chunk_type, filename, expected_pixels in REPRESENTATIONS:
        data = (app_icon_dir / filename).read_bytes()
        actual_size = png_size(data)
        expected_size = (expected_pixels, expected_pixels)
        if actual_size != expected_size:
            raise ValueError(
                f"{filename} is {actual_size[0]}x{actual_size[1]}, "
                f"expected {expected_pixels}x{expected_pixels}"
            )
        chunks.append(
            chunk_type.encode("ascii") + struct.pack(">I", len(data) + 8) + data
        )

    body = b"".join(chunks)
    output_path.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


if __name__ == "__main__":
    main()
