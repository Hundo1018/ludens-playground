#!/usr/bin/env python3
"""Review probe for the playground page: mouse-drag look, town residents on screen per zone, one frame per zone.

    python3 scripts/review_probe.py <chrome> <base-url-to-index.html> <out-dir>

Runs scripts/review_probe.mjs (headless Chrome, software WebGPU) and writes the frames to <out-dir>.
The page must be built (scripts/build_page.sh) and served at <base-url>. Prints the probe's lines and exits with its status.
"""
import pathlib
import subprocess
import sys


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    here = pathlib.Path(__file__).resolve().parent
    out = pathlib.Path(sys.argv[3])
    out.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(["node", str(here / "review_probe.mjs"), sys.argv[1], sys.argv[2], str(out)],
                          capture_output=True, text=True)
    print(proc.stdout.rstrip() or proc.stderr.rstrip())
    return proc.returncode


if __name__ == "__main__":
    raise SystemExit(main())
