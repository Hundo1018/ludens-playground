#!/usr/bin/env python3
"""Render assets/CREDITS.md as a plain HTML page (the page's Credits link points here).

    python3 scripts/write_credits_html.py <CREDITS.md> <credits.html>

Headings, tables, bullet lists, paragraphs and <links> only. Everything is HTML-escaped, so a licence line cannot inject
markup. Standard library only."""
import html
import pathlib
import re
import sys


def _inline(text: str) -> str:
    """Escape, then turn `code`, <url> and **bold** back into markup."""
    s = html.escape(text, quote=False)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"&lt;(https?://[^&]+?)&gt;", r'<a href="\1">\1</a>', s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    return s


def render(md: str) -> str:
    out = []
    in_list = False
    in_table = False
    header_done = False
    for line in md.splitlines():
        if line.startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if set("".join(cells)) <= set("-: "):
                header_done = True
                continue
            if not in_table:
                out.append("<table>")
                in_table = True
                tag = "th"
            else:
                tag = "td" if header_done else "th"
            out.append("<tr>" + "".join(f"<{tag}>{_inline(c)}</{tag}>" for c in cells) + "</tr>")
            continue
        if in_table:
            out.append("</table>")
            in_table = False
            header_done = False
        if line.startswith("- "):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{_inline(line[2:])}</li>")
            continue
        if in_list:
            out.append("</ul>")
            in_list = False
        m = re.match(r"^(#{1,3}) (.*)$", line)
        if m:
            level = len(m.group(1))
            out.append(f"<h{level}>{_inline(m.group(2))}</h{level}>")
        elif line.strip():
            out.append(f"<p>{_inline(line)}</p>")
    if in_table:
        out.append("</table>")
    if in_list:
        out.append("</ul>")
    body = "\n".join(out)
    return (
        "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n"
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
        "<title>Credits</title>\n"
        "<style>body{font:16px/1.5 system-ui,sans-serif;margin:16px;max-width:60em}"
        "table{border-collapse:collapse;font-size:14px}td,th{border:1px solid #888;padding:4px 6px;vertical-align:top}"
        "code{font-size:90%}</style>\n</head><body>\n"
        f"{body}\n</body></html>\n"
    )


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__)
        return 2
    src = pathlib.Path(argv[1])
    dst = pathlib.Path(argv[2])
    dst.write_text(render(src.read_text(encoding="utf-8")), encoding="utf-8")
    print(f"write_credits_html: {src} -> {dst}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
