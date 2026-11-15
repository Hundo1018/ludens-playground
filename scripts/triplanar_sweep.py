#!/usr/bin/env python3
"""Sweep the triplanar texture scale (per metre) for the Frontier page and measure the hub ground.

    python3 scripts/triplanar_sweep.py <chrome> <base-url> <out-dir> <scale> [scale ...]

For each scale: patch the three `world.* * <scale>` lines of TRI_WGSL in the pinned engine copy (build/deps, untracked),
rebuild the page, capture the hub frame with ?offscreen, and print the ground crop's luminance std-dev. The engine copy
and the page are restored to the pinned scale (0.25) at the end, and the page is rebuilt with it.

Needs the page served at <base-url> from build/page, pixi, node, numpy and Pillow. The sweep is local: nothing is
committed. A scale that changes the engine is an engine PR, not this script's output.
"""
import pathlib
import re
import subprocess
import sys

import numpy as np
from PIL import Image

ENGINE = pathlib.Path("build/deps/ludens-engine/app/textures.mojo")
PINNED = "0.25"
PATTERN = re.compile(r"(world\.zy|world\.xz|world\.xy) \* [0-9.]+")
GROUND = (500, 380, 940, 470)  # the open floor of the hub frame (scripts/texture_compare.py)


def set_scale(scale: str) -> None:
    text = ENGINE.read_text()
    new, n = PATTERN.subn(lambda m: f"{m.group(1)} * {scale}", text)
    if n != 3:
        raise SystemExit(f"triplanar_sweep: expected 3 scale lines in {ENGINE}, found {n}")
    ENGINE.write_text(new)


def build() -> None:
    subprocess.run(
        ["pixi", "run", "--manifest-path", "build/deps/ludens-engine/pixi.toml", "-e", "wasm",
         "bash", "scripts/build_page.sh"],
        check=True,
    )


def capture(chrome: str, url: str, out: str) -> None:
    subprocess.run(["node", "scripts/host_check.mjs", chrome, url, out, "240"], check=True,
                   stdout=subprocess.DEVNULL)


def ground_std(path: str) -> float:
    lum = np.asarray(Image.open(path).convert("L"), dtype=np.float64)
    x0, y0, x1, y1 = GROUND
    return float(lum[y0:y1, x0:x1].std())


def main() -> None:
    if len(sys.argv) < 5:
        raise SystemExit(__doc__)
    chrome, base, out_dir = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
    scales = sys.argv[4:]
    out_dir.mkdir(parents=True, exist_ok=True)
    original = ENGINE.read_text()
    rows = []
    try:
        for scale in scales:
            set_scale(scale)
            build()
            prefix = str(out_dir / f"scale_{scale}")
            capture(chrome, f"{base}/index.html?offscreen&notown", prefix)
            rows.append((scale, ground_std(f"{prefix}_hub.png")))
            print(f"scale {scale}: ground std-dev {rows[-1][1]:.2f}", flush=True)
    finally:
        ENGINE.write_text(original)
        build()
    print("| scale per metre | ground std-dev |")
    print("|---:|---:|")
    for scale, std in rows:
        print(f"| {scale} | {std:.2f} |")


if __name__ == "__main__":
    main()
