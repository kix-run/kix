#!/usr/bin/env python3
"""seed.py BUNDLE... DIR: the seed corpora of the fuzz targets.

Writes each bundle into DIR/raw as it is, and into DIR/frames as its frames,
decompressed with the `zstd` command and joined by the separator
`kix_fuzz::FRAME_SEPARATOR` names.
"""

import pathlib
import struct
import subprocess
import sys

SEPARATOR = b"\n\0kix-frame\0\n"

*bundles, out = sys.argv[1:]
out = pathlib.Path(out)
for sub in ("raw", "frames"):
    (out / sub).mkdir(parents=True, exist_ok=True)
for path in map(pathlib.Path, bundles):
    data = path.read_bytes()
    (out / "raw" / path.name).write_bytes(data)
    footer = len(data) - 9
    (count,) = struct.unpack_from("<I", data, footer)
    table = footer - 8 * count
    frames, offset = [], 0
    for k in range(count):
        stored, _ = struct.unpack_from("<II", data, table + 8 * k)
        frame = subprocess.run(
            ["zstd", "-dc"],
            input=data[offset : offset + stored],
            capture_output=True,
            check=True,
        ).stdout
        frames.append(frame)
        offset += stored
    (out / "frames" / path.name).write_bytes(SEPARATOR.join(frames))
