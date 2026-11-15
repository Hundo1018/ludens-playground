#!/usr/bin/env python3
"""Offscreen visual check for one stage: capture named scenes of the playground page and assemble one labelled sheet.

    python3 scripts/stage_shots.py <chrome> <base-url> <out-dir> [scene ...]

Each scene is NAME=QUERY (the query is appended to the base URL, which should end in index.html). With no scene given,
the default set is: hub, netview, noshadow, crowd. Every scene is one captured frame from the page's offscreen render
path (scripts/capture_scene.mjs). Writes <out-dir>/<name>.png, <out-dir>/sheet.png (all scenes with their names), and
<out-dir>/manifest.json (name, query, file, and whether the capture completed). The advisor can view sheet.png directly.

Needs Pillow. The page must already be built (scripts/build_page.sh) and served at <base-url>.
"""
import json
import pathlib
import subprocess
import sys

from PIL import Image, ImageDraw

DEFAULT_SCENES = [
    "hub=offscreen&notown",
    "netview=offscreen&notown&netview",
    "noshadow=offscreen&notown&noshadow",
    "crowd=offscreen&notown&crowd=60",
]
LABEL_H = 22


def capture(chrome: str, base: str, name: str, query: str, out: pathlib.Path) -> bool:
    url = f"{base}?{query}"
    proc = subprocess.run(
        ["node", "scripts/capture_scene.mjs", chrome, url, str(out), "240"],
        capture_output=True, text=True,
    )
    print(proc.stdout.strip() or proc.stderr.strip())
    return proc.returncode == 0 and out.exists()


def sheet(entries: list[tuple[str, pathlib.Path]], out: pathlib.Path) -> None:
    images = [(name, Image.open(path).convert("RGB")) for name, path in entries if path.exists()]
    if not images:
        return
    cols = 2 if len(images) > 1 else 1
    w = max(im.width for _, im in images)
    h = max(im.height for _, im in images) + LABEL_H
    rows = (len(images) + cols - 1) // cols
    canvas = Image.new("RGB", (cols * w, rows * h), (20, 20, 20))
    draw = ImageDraw.Draw(canvas)
    for k, (name, im) in enumerate(images):
        x, y = (k % cols) * w, (k // cols) * h
        draw.text((x + 6, y + 5), name, fill=(240, 240, 240))
        canvas.paste(im, (x, y + LABEL_H))
    canvas.save(out)


def main() -> None:
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    chrome, base, out_dir = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
    scenes = sys.argv[4:] or DEFAULT_SCENES
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest, entries = [], []
    for spec in scenes:
        name, _, query = spec.partition("=")
        out = out_dir / f"{name}.png"
        ok = capture(chrome, base, name, query, out)
        manifest.append({"name": name, "query": query, "file": out.name, "captured": ok})
        entries.append((name, out))
    sheet(entries, out_dir / "sheet.png")
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"stage shots: {sum(m['captured'] for m in manifest)}/{len(manifest)} captured -> {out_dir / 'sheet.png'}")


if __name__ == "__main__":
    main()
