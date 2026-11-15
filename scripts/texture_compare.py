#!/usr/bin/env python3
"""Compare two Frontier frames (textures on vs off): luminance spread in named crops, and how much of the frame differs.

    python3 scripts/texture_compare.py <on.png> <off.png> [name=x0,y0,x1,y1 ...]

Crops default to the hub frame's open ground and the right-hand pillar. Coordinates are pixels of the frame. Prints one
line per crop (std-dev of luminance, on and off) and the count of differing pixels. Needs numpy and Pillow.
"""
import sys

import numpy as np
from PIL import Image

DEFAULT_CROPS = ["ground=500,380,940,470", "wall=660,60,700,115"]


def luminance(path: str) -> np.ndarray:
    rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)
    return 0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]


def crop(lum: np.ndarray, box: tuple[int, int, int, int]) -> np.ndarray:
    x0, y0, x1, y1 = box
    return lum[y0:y1, x0:x1]


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    on_path, off_path = sys.argv[1], sys.argv[2]
    specs = sys.argv[3:] or DEFAULT_CROPS
    on, off = luminance(on_path), luminance(off_path)
    if on.shape != off.shape:
        raise SystemExit(f"texture_compare: frames differ in size, {on.shape} vs {off.shape}")
    for spec in specs:
        name, coords = spec.split("=")
        box = tuple(int(v) for v in coords.split(","))
        a, b = crop(on, box), crop(off, box)
        print(f"{name}: std-dev on {a.std():.2f}, off {b.std():.2f}, on-off mean {a.mean() - b.mean():+.2f}")
    diff = np.abs(on - off) > 3.0
    print(f"frame: {int(diff.sum())} of {diff.size} pixels differ by more than 3 luminance levels "
          f"({100.0 * diff.mean():.2f}%)")


if __name__ == "__main__":
    main()
