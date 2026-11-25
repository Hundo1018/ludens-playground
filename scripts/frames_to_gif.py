#!/usr/bin/env python3
"""Turn a directory of PNG frames (frame_0000.png, ...) into an animated GIF or WebP.

    python3 scripts/frames_to_gif.py <frames-dir> <out.gif|out.webp> [--fps 15] [--width 640]

Frames are taken in name order and scaled to --width (height in proportion). Needs Pillow (the engine's wasm
environment has it)."""
import argparse
import pathlib
import sys

from PIL import Image


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("frames")
    ap.add_argument("out")
    ap.add_argument("--fps", type=float, default=15.0)
    ap.add_argument("--width", type=int, default=640)
    a = ap.parse_args(argv[1:])
    paths = sorted(pathlib.Path(a.frames).glob("*.png"))
    if not paths:
        print(f"frames_to_gif: no PNG in {a.frames}")
        return 1
    frames = []
    for p in paths:
        im = Image.open(p).convert("RGB")
        h = round(im.height * a.width / im.width)
        frames.append(im.resize((a.width, h), Image.LANCZOS))
    out = pathlib.Path(a.out)
    kw = {"save_all": True, "append_images": frames[1:], "duration": round(1000 / a.fps), "loop": 0}
    if out.suffix == ".webp":
        kw["quality"] = 85
    else:
        kw["optimize"] = True
    frames[0].save(out, **kw)
    print(f"frames_to_gif: {len(frames)} frames -> {out} ({out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
