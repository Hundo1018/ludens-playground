#!/usr/bin/env python3
"""Convert a CMU skeleton (.asf) and motion (.amc) pair into the playground's motion format (.lmotion).

Usage:
  python3 scripts/convert_amc.py <skeleton.asf> <motion.amc> <out.lmotion>
  python3 scripts/convert_amc.py --selftest <skeleton.asf> <motion.amc>

Layout: each frame holds the root translation (3 floats, the ASF axis order TX TY TZ), then for every bone in ASF
order three rotation channels rx, ry, rz in degrees. A channel the bone does not have in the ASF DOF list is 0.
Bone names, parents and DOF lists go in the JSON header. Stdlib only.

Format (little-endian): magic b"LMOT", u32 version=1, u32 header_len, JSON header, float32 frames*(3+3*bones) values.
"""
import argparse
import array
import json
import pathlib
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAGIC = b"LMOT"
VERSION = 1
AXES = ("rx", "ry", "rz")


def _clean(path: pathlib.Path):
    return [ln.strip() for ln in path.read_text(encoding="utf-8", errors="replace").splitlines()]


def parse_asf(path: pathlib.Path):
    """Return (bones, root_order) where bones is a list of dicts in ASF id order."""
    lines = _clean(path)
    root_order = ["TX", "TY", "TZ", "RX", "RY", "RZ"]
    i = 0
    while i < len(lines) and lines[i] != ":root":
        i += 1
    i += 1
    while i < len(lines) and not lines[i].startswith(":bonedata"):
        tok = lines[i].split()
        if tok and tok[0] == "order":
            root_order = [t.upper() for t in tok[1:]]
        i += 1
    bones = []
    i += 1
    cur = None
    while i < len(lines) and not lines[i].startswith(":hierarchy"):
        tok = lines[i].split()
        if tok == ["begin"]:
            cur = {"id": None, "name": None, "dof": [], "order": None}
        elif tok == ["end"] and cur is not None:
            bones.append(cur)
            cur = None
        elif cur is not None and tok:
            key = tok[0]
            if key == "id":
                cur["id"] = int(tok[1])
            elif key == "name":
                cur["name"] = tok[1]
            elif key == "dof":
                cur["dof"] = [t.lower() for t in tok[1:]]
            elif key == "order":
                cur["order"] = [t.upper() for t in tok[1:]]
        i += 1
    bones.sort(key=lambda b: b["id"])
    # hierarchy: "parent child child ..." lines inside begin/end
    while i < len(lines) and not lines[i].startswith(":hierarchy"):
        i += 1
    i += 1
    parent = {}
    while i < len(lines) and lines[i] != "end":
        tok = lines[i].split()
        if tok and tok[0] != "begin":
            for child in tok[1:]:
                parent[child] = tok[0]
        i += 1
    names = [b["name"] for b in bones]
    for b in bones:
        b["parent"] = parent.get(b["name"], None)
    # the root is not in :bonedata; the hierarchy names it "root" and its DOF order comes from the :root section
    root = {"id": 0, "name": "root", "dof": [], "order": root_order, "parent": None}
    for b in bones:
        b.setdefault("parent", parent.get(b["name"]))
    bones.insert(0, root)
    names = [b["name"] for b in bones]
    return bones, names


def parse_amc(path: pathlib.Path, bone_names):
    """Return a list of frames; each frame maps bone name to its list of floats in the AMC order."""
    frames = []
    cur = None
    for ln in _clean(path):
        if not ln or ln.startswith("#") or ln.startswith(":"):
            continue
        tok = ln.split()
        if len(tok) == 1 and tok[0].isdigit():
            cur = {}
            frames.append(cur)
            continue
        if cur is None:
            continue
        if tok[0] in bone_names:
            cur[tok[0]] = [float(v) for v in tok[1:]]
    return frames


def build(asf: pathlib.Path, amc: pathlib.Path):
    bones, names = parse_asf(asf)
    frames = parse_amc(amc, set(names))
    root = bones[0]
    root_order = root["order"] or ["TX", "TY", "TZ", "RX", "RY", "RZ"]
    # the AMC root line lists the channels in root_order: translation then rotation
    t_idx = [root_order.index(a) for a in ("TX", "TY", "TZ")]
    r_idx = [root_order.index(a) for a in ("RX", "RY", "RZ")]

    values = []
    for fr in frames:
        row = []
        rv = fr[root["name"]]
        row += [rv[t_idx[0]], rv[t_idx[1]], rv[t_idx[2]]]
        for b in bones:
            if b is root:
                continue
            row_b = [0.0, 0.0, 0.0]
            if b["name"] in fr:
                vals = fr[b["name"]]
                k = 0
                for ax_name in b["dof"]:
                    if ax_name in AXES:
                        row_b[AXES.index(ax_name)] = vals[k]
                    k += 1
            row += row_b
        # the root rotation sits with the bones, in the same channel slots as every other bone
        row_root = [rv[r_idx[0]], rv[r_idx[1]], rv[r_idx[2]]]
        values += row[:3] + row_root + row[3:]
    return {
        "bones": [{"name": b["name"], "parent": names.index(b["parent"]) if b["parent"] in names else -1,
                   "dof": b["dof"]} for b in bones],
        "frames": len(frames),
        "values": values,
    }


def write(out: pathlib.Path, d: dict):
    header = json.dumps({"version": VERSION, "bones": d["bones"], "frames": d["frames"],
                         "layout": "per frame: root translation xyz, root rotation xyz, then 3 rotation channels per non-root bone (ASF order)"},
                        separators=(",", ":")).encode("utf-8")
    arr = array.array("f", d["values"])
    with out.open("wb") as f:
        f.write(MAGIC + struct.pack("<II", VERSION, len(header)) + header)
        f.write(arr.tobytes())
    return out


def read_back(path: pathlib.Path):
    data = path.read_bytes()
    if data[:4] != MAGIC:
        raise SystemExit("bad magic")
    version, hlen = struct.unpack_from("<II", data, 4)
    header = json.loads(data[12:12 + hlen].decode("utf-8"))
    arr = array.array("f")
    arr.frombytes(data[12 + hlen:])
    return header, arr


def selftest(asf: pathlib.Path, amc: pathlib.Path) -> int:
    bones, names = parse_asf(asf)
    frames = parse_amc(amc, set(names))
    out = ROOT / "build" / "assets" / "converted" / (amc.stem + ".lmotion")
    out.parent.mkdir(parents=True, exist_ok=True)
    d = build(asf, amc)
    write(out, d)
    header, arr = read_back(out)
    checks = []

    def check(cond, label):
        checks.append(cond)
        print(("PASS " if cond else "FAIL ") + label)

    raw = _clean(amc)
    amc_frame_markers = sum(1 for ln in raw if ln.isdigit())
    check(len(header["bones"]) == len(bones), f"bones {len(header['bones'])} == ASF bones incl. root {len(bones)}")
    check(header["frames"] == amc_frame_markers, f"frames {header['frames']} == frame markers in the AMC file {amc_frame_markers}")
    per_frame = 3 + 3 * (len(bones))
    check(len(arr) == header["frames"] * per_frame, f"{header['frames']} frames x {per_frame} values = {len(arr)}")
    # values: the first frame in the file, read by hand, must be what the converter wrote
    body = _clean(amc)
    first_start = body.index("1")
    first_lines = []
    for ln in body[first_start + 1:]:
        if ln.isdigit():
            break
        if ln.split():
            first_lines.append(ln.split())
    first = {t[0]: [float(x) for x in t[1:]] for t in first_lines if t[0] in set(names)}
    got_root_t = [round(x, 4) for x in arr[0:3]]
    want_root_t = [round(x, 4) for x in first["root"][0:3]]
    check(got_root_t == want_root_t, f"frame 0 root translation {got_root_t} == file {want_root_t}")
    got_root_r = [round(x, 4) for x in arr[3:6]]
    want_root_r = [round(x, 4) for x in first["root"][3:6]]
    check(got_root_r == want_root_r, f"frame 0 root rotation {got_root_r} == file {want_root_r}")
    k = next(i for i, b in enumerate(header["bones"]) if b["name"] == "lfemur")
    got_lf = [round(x, 4) for x in arr[3 + 3 * k: 6 + 3 * k]]
    want_lf = [round(x, 4) for x in first["lfemur"]]
    check(got_lf == want_lf, f"frame 0 lfemur {got_lf} == file {want_lf}")
    # every bone that has DOFs must appear in every frame of the AMC file
    dof_bones = {b["name"] for b in bones if b["dof"]}
    check(all(dof_bones <= set(fr) for fr in frames), "every bone with DOFs appears in every AMC frame")
    # a hierarchy check: each non-root bone has a parent that is itself a bone
    nonroot = [b for b in header["bones"] if b["parent"] != -1]
    check(all(0 <= b["parent"] < len(bones) for b in nonroot), "every non-root bone has a parent bone")
    check(sum(1 for b in header["bones"] if b["parent"] == -1) == 1, "exactly one root bone")
    ok = all(checks)
    print(f"convert_amc selftest: {sum(checks)} / {len(checks)} checks; wrote {out}")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("asf", type=pathlib.Path)
    ap.add_argument("amc", type=pathlib.Path)
    ap.add_argument("out", type=pathlib.Path, nargs="?")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest(args.asf, args.amc)
    if args.out is None:
        ap.error("out is required unless --selftest")
    write(args.out, build(args.asf, args.amc))
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
