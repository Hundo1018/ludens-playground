#!/usr/bin/env python3
"""Run the page's browser checks the way CI does, against a page served locally:

    python3 scripts/page_checks.py <chrome> <base-url> [--only NAME ...] [--runs N]

<base-url> is the served build/page directory (e.g. http://127.0.0.1:8150/). The checks and their queries are read
from .github/workflows/pages.yml (every `node scripts/<name>.mjs "<chrome>" "<url>" ...` command), so this list cannot
drift from CI's. Each check runs once (or --runs N times); prints PASS or FAIL per check and the failing lines, and
exits 1 when any check fails. Run it from the project environment (pixi run -e wasm ...), as CI does.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PAGES = ROOT / ".github" / "workflows" / "pages.yml"
CMD = re.compile(r'node (scripts/[\w./-]+\.mjs) \\\s*\n\s*"\$\(which google-chrome \|\| which chromium\)" "http://127\.0\.0\.1:8150/([^"]*)"([^\n|]*)')


def checks() -> list[tuple[str, str, list[str]]]:
    text = PAGES.read_text()
    out = []
    for m in CMD.finditer(text):
        script, path, rest = m.group(1), m.group(2), m.group(3)
        extra = [a.strip('"') for a in rest.split() if a and not a.startswith("||")]
        out.append((script, path, extra))
    return out


def main() -> None:
    args = sys.argv[1:]
    if len(args) < 2:
        raise SystemExit(__doc__)
    chrome, base = args[0], args[1].rstrip("/") + "/"
    only = [args[i + 1] for i, a in enumerate(args) if a == "--only"]
    runs = int(args[args.index("--runs") + 1]) if "--runs" in args else 1
    failed = []
    seen = set()
    for script, path, extra in checks():
        name = pathlib.Path(script).stem
        if only and name not in only:
            continue
        key = (script, path)
        if key in seen:
            continue
        seen.add(key)
        # a third argument that is a directory (host_check's shots) goes under build/
        extra = [str(ROOT / e) if e.startswith("build/") else e for e in extra]
        for r in range(runs):
            proc = subprocess.run(["node", script, chrome, base + path, *extra], cwd=ROOT, capture_output=True, text=True)
            lines = (proc.stdout + proc.stderr).splitlines()
            ok = proc.returncode == 0
            print(f"{'PASS' if ok else 'FAIL'} {name} ({path}){'' if runs == 1 else f' run {r + 1}'}")
            if not ok:
                failed.append(name)
                for line in lines:
                    if "FAIL" in line or "Error" in line or "error" in line.lower()[:12]:
                        print("    " + line[:300])
    print(f"page-checks: {'PASS' if not failed else 'FAIL: ' + ', '.join(sorted(set(failed)))}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
