#!/usr/bin/env python3
"""Write the page's asset index: {file: {"sha256": ..., "bytes": ...}} for every file in a directory, computed after the
files are converted, so a changed file changes its hash here.

    python3 scripts/write_index.py <dir> <index.json>

The index lists the converted assets only (the .l* files), not itself. Standard library only."""
import hashlib
import json
import pathlib
import sys


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__)
        return 2
    root = pathlib.Path(argv[1])
    out = pathlib.Path(argv[2])
    index = {}
    for path in sorted(root.iterdir()):
        if not path.is_file() or path.name == out.name or path.suffix not in (".lcharacter", ".ltexture", ".lmotion", ".lsound", ".lfont"):
            continue
        data = path.read_bytes()
        index[path.name] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
    if not index:
        print("write_index: no converted assets in", root)
        return 1
    out.write_text(json.dumps(index, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"write_index: {len(index)} files -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
