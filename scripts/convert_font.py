#!/usr/bin/env python3
"""Rasterise a pixel font into an 8x8 glyph table (.lfont) for the HUD: printable ASCII 0x20..0x7E.

Usage:
  python3 scripts/convert_font.py <font.ttf> <out.lfont>
  python3 scripts/convert_font.py --selftest <font.ttf>

Needs Pillow (the only non-stdlib dependency in this script). The font is drawn at pixel size 8, which is its design
grid for Press Start 2P; each glyph is thresholded to one bit per pixel. Row-major, one byte per row, bit 7 = leftmost.

Format (little-endian): magic b"LFNT", u32 version=1, u32 header_len, JSON header {cell, first, count, source_font,
licence, note}, then count*8 bytes.
The header does not give the converted table the font's Reserved Font Name; it names the source only as attribution.
"""
import argparse
import json
import pathlib
import struct
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAGIC = b"LFNT"
VERSION = 1
CELL = 8
FIRST = 0x20
LAST = 0x7E
PIXEL_SIZE = 8


def render_glyphs(font_path: pathlib.Path):
    font = ImageFont.truetype(str(font_path), PIXEL_SIZE)
    rows_all = []
    for code in range(FIRST, LAST + 1):
        img = Image.new("L", (CELL, CELL), 0)
        draw = ImageDraw.Draw(img)
        draw.text((0, 0), chr(code), font=font, fill=255)
        px = img.load()
        rows = []
        for y in range(CELL):
            b = 0
            for x in range(CELL):
                if px[x, y] >= 128:
                    b |= 1 << (7 - x)
            rows.append(b)
        rows_all.append(rows)
    return rows_all


def write(out: pathlib.Path, glyphs, source_name: str):
    header = json.dumps({
        "cell": CELL, "first": FIRST, "count": len(glyphs),
        "source_font": source_name, "licence": "OFL-1.1",
        "note": "8x8 bitmap glyphs rasterised from the source font at its pixel size; attribution in assets/CREDITS.md",
    }, separators=(",", ":")).encode("utf-8")
    body = bytes(b for rows in glyphs for b in rows)
    with out.open("wb") as f:
        f.write(MAGIC + struct.pack("<II", VERSION, len(header)) + header)
        f.write(body)
    return out


def read_back(path: pathlib.Path):
    data = path.read_bytes()
    if data[:4] != MAGIC:
        raise SystemExit("bad magic")
    version, hlen = struct.unpack_from("<II", data, 4)
    header = json.loads(data[12:12 + hlen].decode("utf-8"))
    body = data[12 + hlen:]
    glyphs = [list(body[i * CELL:(i + 1) * CELL]) for i in range(header["count"])]
    return header, glyphs


def selftest(font_path: pathlib.Path) -> int:
    glyphs = render_glyphs(font_path)
    out = ROOT / "build" / "assets" / "converted" / "press_start_2p_8x8.lfont"
    out.parent.mkdir(parents=True, exist_ok=True)
    write(out, glyphs, "Press Start 2P")
    header, back = read_back(out)
    checks = []

    def check(cond, label):
        checks.append(cond)
        print(("PASS " if cond else "FAIL ") + label)

    check(header["count"] == LAST - FIRST + 1 and len(back) == header["count"], f"{header['count']} glyphs, 0x20..0x7E")
    check(all(len(g) == CELL for g in back), "every glyph has 8 rows")
    check(back == glyphs, "the file reads back equal to the rendered table")
    space = back[0]
    check(all(r == 0 for r in space), "space is blank")
    blank = [chr(FIRST + i) for i, g in enumerate(back) if not any(g) and chr(FIRST + i) != " "]
    check(not blank, f"every printable glyph has ink (blank: {blank or 'none'})")
    # Press Start 2P's capitals are 7 rows tall on the 8-row cell: row 0 and row 6 have ink, row 7 is the blank descender row
    h = back[ord("H") - FIRST]
    check(h[0] != 0 and h[6] != 0 and h[7] == 0, "'H' spans rows 0-6 (cap height 7) with row 7 blank")
    check(any(back[ord("I") - FIRST]), "'I' has ink")
    ok = all(checks)
    print(f"convert_font selftest: {sum(checks)} / {len(checks)} checks; wrote {out}")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("font", type=pathlib.Path)
    ap.add_argument("out", type=pathlib.Path, nargs="?")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest(args.font)
    if args.out is None:
        ap.error("out is required unless --selftest")
    write(args.out, render_glyphs(args.font), "Press Start 2P")
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
