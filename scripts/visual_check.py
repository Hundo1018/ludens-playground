#!/usr/bin/env python3
"""Visual quality check (reference baseline V, docs/reference-baselines.md): capture fixed views of the page and measure
what a picture can be measured on. Reusable from the project environment:

    python3 scripts/visual_check.py <chrome> <base-url> <out-dir> [--bounds]

<base-url> ends in index.html. Each view is one page load (`?offscreen`, so the frame is the app's own capture) with three
captures in the same session: the normal frame; the sky mask (playground_host_skymark: the sky drawn magenta and fog
off, so a sky pixel is told from far ground that fog has faded to the horizon colour); then playground_host_flatmark
(every colour-only item, material 0, drawn magenta). A page without the sky mask export (before V4) falls back to a
colour rule for sky pixels. Writes <out-dir>/<view>.png, <view>_sky.png, <view>_flat.png, sheet.png and metrics.json,
prints one line per metric, and with --bounds exits 1 when any metric is outside its bound.

Metrics (the HUD rectangles are left out of every count). A sky pixel is magenta in the sky mask capture; without the
mask export, a blue-dominant bright pixel of the normal frame (b > r + 30, b > g + 10, luminance > 110).
  flat          share of scene pixels drawn by colour-only items (magenta in the flatmark capture)
  floating_cols share of columns where, in the upper half, a sky pixel lies below a non-sky pixel: something hangs in the
                sky with sky under it (the border walls over unloaded ground did, in every view)
  sky_grad      hub view only: mean luminance of the sky pixels in the top three rows minus that of the sky pixels in
                the three rows above the horizon (a flat clear colour gives 0)
  fog           hub view only: colour distance from the sky at the horizon to the ground just below it, divided by the
                same distance for the ground near the bottom of the frame (fog pulls far ground toward the horizon)
  wall_layers   town view only: distinct texture layers on building faces (playground_host_wall_layers, at the source)
  mean_lum      mean luminance of the scene pixels: a frame that failed to render is black, and every other metric
                would pass on it, so a view below 25 fails
A hub capture without sky_grad or fog (no sky pixel found) fails as well.
"""
import json
import os
import pathlib
import subprocess
import sys

from PIL import Image, ImageDraw

VIEWS = [
    # name, query, PRE_JS (moves the player before the capture)
    ("hub", "offscreen&notown&nonetview", ""),
    ("town", "offscreen&nonetview&at=112,140", ""),
    ("quarry", "offscreen&notown&nonetview&at=112,-104", ""),
    ("camp", "offscreen&notown&nonetview&at=-110,-100", ""),
]
# A bound per metric: (low, high); None leaves a side open. The values are the acceptance in docs/reference-baselines.md.
BOUNDS = {
    "flat": (None, 0.002),
    "floating_cols": (None, 0.02),
    "sky_grad": (8.0, None),
    "fog": (None, 0.7),
    "wall_layers": (3, None),
    "mean_lum": (25.0, None),
}
REQUIRED = {"hub": ("sky_grad", "fog"), "town": ("wall_layers",)}
HUD_BOXES = [(0, 0, 170, 75)]  # the top-left status box, in a 960x540 frame; scaled to the frame size
HUD_BOTTOM = 32  # the help bar's height at the bottom, in a 540-high frame


def lum(p):
    return 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]


def hud_mask(w: int, h: int):
    sx, sy = w / 960.0, h / 540.0
    boxes = [(int(a * sx), int(b * sy), int(c * sx), int(d * sy)) for a, b, c, d in HUD_BOXES]
    bottom = h - int(HUD_BOTTOM * sy)

    def inside(x, y):
        if y >= bottom:
            return True
        return any(x0 <= x < x1 and y0 <= y < y1 for x0, y0, x1, y1 in boxes)

    return inside, bottom


def is_magenta(p) -> bool:
    r, g, b = p[0], p[1], p[2]
    m = max(r, b)
    return min(r, b) > 20 and g < 0.12 * m and 0.75 * b <= r <= 1.33 * b


def is_sky(p) -> bool:
    return p[2] > p[0] + 30 and p[2] > p[1] + 10 and lum(p) > 110


def measure(normal: pathlib.Path, flat: pathlib.Path, view: str, sky: pathlib.Path | None = None) -> dict:
    im = Image.open(normal).convert("RGB")
    fm = Image.open(flat).convert("RGB")
    w, h = im.size
    px, fx = im.load(), fm.load()
    sm = Image.open(sky).convert("RGB").load() if sky is not None and sky.exists() else None

    def sky_at(x, y):
        return is_magenta(sm[x, y]) if sm is not None else is_sky(px[x, y])

    inside, bottom = hud_mask(w, h)
    total = magenta = 0
    lum_sum = 0.0
    for y in range(bottom):
        for x in range(w):
            if inside(x, y):
                continue
            total += 1
            lum_sum += lum(px[x, y])
            if is_magenta(fx[x, y]):
                magenta += 1
    # per column: sky under something in the upper half, and the horizon (the lowest sky pixel above the ground)
    floating = cols = 0
    horizons = []
    for x in range(w):
        seen_solid = False
        hang = False
        low_sky = -1
        n = 0
        for y in range(h // 2):
            if inside(x, y):
                continue
            n += 1
            if sky_at(x, y):
                if seen_solid:
                    hang = True
                low_sky = y
            else:
                seen_solid = True
        if n:
            cols += 1
            floating += 1 if hang else 0
            if low_sky >= 0:
                horizons.append(low_sky)
    out = {"flat": magenta / total, "floating_cols": floating / max(cols, 1), "mean_lum": lum_sum / total}
    if view == "hub" and horizons:
        horizons.sort()
        hz = horizons[len(horizons) // 2]

        def row(y):
            vals = [px[x, y] for x in range(w) if not inside(x, y)]
            return tuple(sum(v[k] for v in vals) / len(vals) for k in range(3))

        def sky_lum(y0, y1):
            vals = [lum(px[x, y]) for y in range(max(0, y0), y1) for x in range(w) if not inside(x, y) and sky_at(x, y)]
            return sum(vals) / len(vals) if vals else 0.0

        # sky pixels only: the top rows against the rows just above the horizon
        out["sky_grad"] = abs(sky_lum(0, 3) - sky_lum(hz - 3, hz))
        def band(y0, y1, want_sky):
            vals = [px[x, y] for y in range(max(0, y0), min(bottom, y1)) for x in range(w)
                    if not inside(x, y) and sky_at(x, y) == want_sky]
            return tuple(sum(v[k] for v in vals) / len(vals) for k in range(3)) if vals else (0.0, 0.0, 0.0)

        sky = band(hz - 3, hz + 1, True)  # the sky just above the horizon
        far = band(hz + 2, hz + 10, False)  # the ground (not sky) just below it
        near = band(bottom - 12, bottom - 2, False)
        dist = lambda a, b: sum((a[k] - b[k]) ** 2 for k in range(3)) ** 0.5
        out["fog"] = dist(far, sky) / max(dist(near, sky), 1e-6)
        out["horizon_row"] = hz
    return out


def capture(chrome: str, base: str, view: str, query: str, pre: str, out_dir: pathlib.Path) -> tuple[bool, int]:
    normal, sky, flat = out_dir / f"{view}.png", out_dir / f"{view}_sky.png", out_dir / f"{view}_flat.png"
    env = dict(os.environ)
    env["THEN_OUT"] = f"{sky}||{flat}"
    env["THEN_JS"] = ("(async()=>{const h=window.host;if(!h.x.playground_host_skymark)return 'no sky mask';"
                      "h.x.playground_host_skymark(h.app,1);await new Promise(r=>setTimeout(r,300));return 'sky mask'})()"
                      "||(async()=>{const h=window.host;if(h.x.playground_host_skymark)h.x.playground_host_skymark(h.app,0);"
                      "h.x.playground_host_flatmark(h.app,1);"
                      "await new Promise(r=>setTimeout(r,300));return h.x.playground_host_wall_layers(h.app)})()")
    if pre:
        env["PRE_JS"] = pre
    proc = subprocess.run(["node", "scripts/capture_scene.mjs", chrome, f"{base}?{query}", str(normal), "300"],
                          capture_output=True, text=True, env=env)
    print(proc.stdout.strip() or proc.stderr.strip())
    layers = -1
    for line in proc.stdout.splitlines():
        if line.startswith("capture-scene: then:"):
            v = line.split(":", 2)[2].strip()
            if v.lstrip("-").isdigit():
                layers = int(v)
        if line.startswith("capture-scene: then:") and "no sky mask" in line and sky.exists():
            sky.unlink()
    return proc.returncode == 0 and normal.exists() and flat.exists(), layers


def sheet(out_dir: pathlib.Path) -> None:
    ims = [(v, Image.open(out_dir / f"{v}.png").convert("RGB")) for v, _, _ in VIEWS if (out_dir / f"{v}.png").exists()]
    if not ims:
        return
    w, h = ims[0][1].size
    canvas = Image.new("RGB", (2 * w, ((len(ims) + 1) // 2) * (h + 22)), (20, 20, 20))
    d = ImageDraw.Draw(canvas)
    for k, (name, im) in enumerate(ims):
        x, y = (k % 2) * w, (k // 2) * (h + 22)
        d.text((x + 6, y + 5), name, fill=(240, 240, 240))
        canvas.paste(im, (x, y + 22))
    canvas.save(out_dir / "sheet.png")


def check(metrics: dict) -> list[str]:
    bad = []
    for view, keys in REQUIRED.items():
        for key in keys:
            if view in metrics and key not in metrics[view]:
                bad.append(f"{view}.{key} could not be measured")
    for view, m in metrics.items():
        for key, (lo, hi) in BOUNDS.items():
            if key not in m:
                continue
            v = m[key]
            if (lo is not None and v < lo) or (hi is not None and v > hi):
                bad.append(f"{view}.{key} = {v:.4g} outside [{lo}, {hi}]")
    return bad


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) < 3:
        raise SystemExit(__doc__)
    chrome, base, out_dir = args[0], args[1], pathlib.Path(args[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    metrics = {}
    failed = []
    for view, query, pre in VIEWS:
        ok, layers = capture(chrome, base, view, query, pre, out_dir)
        if not ok:
            failed.append(f"{view}: capture failed")
            continue
        m = measure(out_dir / f"{view}.png", out_dir / f"{view}_flat.png", view, out_dir / f"{view}_sky.png")
        if view == "town":
            m["wall_layers"] = layers
        metrics[view] = m
        print(f"visual {view}: " + ", ".join(f"{k} {v:.4g}" for k, v in m.items()))
    (out_dir / "metrics.json").write_text(json.dumps(metrics, indent=2))
    sheet(out_dir)
    bad = failed + check(metrics)
    if "--bounds" in sys.argv:
        print("visual-check: " + ("FAIL\n  " + "\n  ".join(bad) if bad else "PASS"))
        sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
