#!/usr/bin/env python3
"""Convert a texture image into the playground's texture format (.ltexture, v1): RGBA8, square, with a full mip chain.

Usage:
  python3 scripts/convert_texture.py <in.jpg> <out.ltexture> [--size 256]
  python3 scripts/convert_texture.py --selftest <in.jpg> [--size 256]

Level 0 is the input resized to size x size with Lanczos. Each further level is a 2x2 box average of the one above,
down to 1x1. Needs Pillow (the only non-stdlib dependency, as in convert_font.py).

Format (little-endian): magic b"LTEX", u32 version=1, u32 width, u32 height, u32 levels, then the levels largest
first: rgba8, tightly packed, each starting on a 16-byte boundary. No JSON.
"""
import argparse
import pathlib
import struct
import sys

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAGIC = b"LTEX"
VERSION = 1


def build_levels(src: pathlib.Path, size: int):
    img = Image.open(src).convert("RGBA").resize((size, size), Image.Resampling.LANCZOS)
    levels = [img]
    while levels[-1].width > 1:
        prev = levels[-1]
        w, h = prev.width // 2, prev.height // 2
        nxt = Image.new("RGBA", (w, h))
        px = prev.load()
        out = nxt.load()
        for y in range(h):
            for x in range(w):
                acc = [0, 0, 0, 0]
                for dy in (0, 1):
                    for dx in (0, 1):
                        p = px[2 * x + dx, 2 * y + dy]
                        for c in range(4):
                            acc[c] += p[c]
                out[x, y] = tuple((a + 2) // 4 for a in acc)
        levels.append(nxt)
    return levels


def write(out: pathlib.Path, levels):
    w, h = levels[0].width, levels[0].height
    header = MAGIC + struct.pack("<IIII", VERSION, w, h, len(levels))
    pos = len(header)
    directory = []
    for lvl in levels:
        pos = (pos + 15) & ~15
        directory.append(pos)
        pos += lvl.width * lvl.height * 4
    with out.open("wb") as f:
        f.write(header)
        cur = len(header)
        for lvl, off in zip(levels, directory):
            f.write(b"\x00" * (off - cur))
            f.write(lvl.tobytes())
            cur = off + lvl.width * lvl.height * 4
    return out, directory


def read_back(path: pathlib.Path):
    data = path.read_bytes()
    if data[:4] != MAGIC:
        raise SystemExit("bad magic")
    version, w, h, n = struct.unpack_from("<IIII", data, 4)
    if version != VERSION:
        raise SystemExit(f"expected version {VERSION}, got {version}")
    pos = 20
    levels = []
    lw, lh = w, h
    for _ in range(n):
        pos = (pos + 15) & ~15
        nbytes = lw * lh * 4
        levels.append((pos, data[pos: pos + nbytes], lw, lh))
        pos += nbytes
        lw, lh = max(1, lw // 2), max(1, lh // 2)
    if pos != len(data):
        raise SystemExit(f"trailing bytes: {len(data) - pos}")
    return w, h, levels


def selftest(src: pathlib.Path, size: int) -> int:
    levels = build_levels(src, size)
    out = ROOT / "build" / "assets" / "converted" / (src.stem + ".ltexture")
    out.parent.mkdir(parents=True, exist_ok=True)
    _, directory = write(out, levels)
    w, h, back = read_back(out)
    checks = []

    def check(cond, label):
        checks.append(bool(cond))
        print(("PASS " if cond else "FAIL ") + label)

    expect_levels = size.bit_length()  # log2(size) + 1 for a power of two
    check(len(back) == expect_levels, f"{len(back)} levels == log2({size}) + 1 = {expect_levels}")
    check(all(off % 16 == 0 for off, _, _, _ in back), "every level offset is a multiple of 16")
    check(w == size and h == size, f"header size {w}x{h} == {size}x{size}")
    base = levels[0].tobytes()
    check(back[0][1] == base, "level 0 reads back equal to the Pillow resize")
    last = back[-1]
    check(last[2] == 1 and last[3] == 1 and len(last[1]) == 4, "the last level is 1x1 rgba8")
    avg = [sum(channel) for channel in zip(*[levels[-2].getpixel((x, y)) for x in (0, 1) for y in (0, 1)])]
    check(all(abs(levels[-1].getpixel((0, 0))[c] - (avg[c] + 2) // 4) == 0 for c in range(4)), "the last mip equals the 2x2 average of the level above")
    print(f"convert_texture selftest: {sum(checks)} / {len(checks)} checks; wrote {out}")
    return 0 if all(checks) else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("src", type=pathlib.Path)
    ap.add_argument("out", type=pathlib.Path, nargs="?")
    ap.add_argument("--size", type=int, default=256)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.size < 1 or args.size & (args.size - 1):
        ap.error("--size must be a power of two")
    if args.selftest:
        return selftest(args.src, args.size)
    if args.out is None:
        ap.error("out is required unless --selftest")
    write(args.out, build_levels(args.src, args.size))
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
