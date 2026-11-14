#!/usr/bin/env python3
"""Convert a skinned glTF 2.0 binary (.glb) into the playground's flat format (.lcharacter).

Usage:
  python3 scripts/convert_glb.py <in.glb> <out.lcharacter> [--fps 30]
  python3 scripts/convert_glb.py --selftest <in.glb>

Reads only what the game needs: the first mesh's POSITION, NORMAL, TEXCOORD_0, JOINTS_0, WEIGHTS_0 and indices
(all primitives of that mesh are concatenated), the skin's joint list and inverse bind matrices, and every animation
sampled at a fixed rate (linear for translation and scale, normalised linear for rotation). Stdlib only.

Format (little-endian):
  magic b"LCHR", u32 version=1, u32 header_len, JSON header (utf-8), then the blobs named in the header, in order.
  Blobs: float32 positions (n*3), normals (n*3), uv (n*2), uint16 joints (n*4), float32 weights (n*4),
  uint32 indices (m), float32 inverse_bind (joints*16), float32 rest (joints*10: T3 R4 S3, local rest pose),
  float32 clips: for each clip, frames*joints*10 values (same layout as rest).
"""
import argparse
import array
import json
import math
import pathlib
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAGIC_GLTF = 0x46546C67  # "glTF"
CHUNK_JSON = 0x4E4F534A
CHUNK_BIN = 0x004E4942
MAGIC_OUT = b"LCHR"
VERSION = 1

COMPONENT = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def read_glb(path: pathlib.Path):
    data = path.read_bytes()
    magic, version, length = struct.unpack_from("<III", data, 0)
    if magic != MAGIC_GLTF or version != 2:
        raise SystemExit(f"{path}: not a glTF 2.0 binary")
    if length != len(data):
        raise SystemExit(f"{path}: header length {length} != file size {len(data)}")
    off, gltf, binchunk = 12, None, None
    while off < length:
        clen, ctype = struct.unpack_from("<II", data, off)
        body = data[off + 8: off + 8 + clen]
        if ctype == CHUNK_JSON:
            gltf = json.loads(body.decode("utf-8"))
        elif ctype == CHUNK_BIN:
            binchunk = body
        off += 8 + clen
    if gltf is None or binchunk is None:
        raise SystemExit(f"{path}: missing JSON or BIN chunk")
    return gltf, binchunk


def accessor_values(gltf, binchunk, index: int):
    """Return (flat list of floats or ints, count, ncomp) for accessor `index`, normalised if the accessor says so."""
    acc = gltf["accessors"][index]
    view = gltf["bufferViews"][acc["bufferView"]]
    fmt, size = COMPONENT[acc["componentType"]]
    ncomp = NCOMP[acc["type"]]
    count = acc["count"]
    base = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
    stride = view.get("byteStride", size * ncomp)
    out = []
    for i in range(count):
        o = base + i * stride
        vals = struct.unpack_from("<" + fmt * ncomp, binchunk, o)
        if acc.get("normalized") and acc["componentType"] in (5121, 5123):
            scale = 255.0 if acc["componentType"] == 5121 else 65535.0
            vals = tuple(v / scale for v in vals)
        out.extend(vals)
    return out, count, ncomp


def quat_norm(q):
    n = math.sqrt(sum(c * c for c in q)) or 1.0
    return [c / n for c in q]


def node_rest(node):
    t = list(node.get("translation", [0.0, 0.0, 0.0]))
    r = quat_norm(node.get("rotation", [0.0, 0.0, 0.0, 1.0]))
    s = list(node.get("scale", [1.0, 1.0, 1.0]))
    return t + r + s


def sample_clip(gltf, binchunk, anim, joint_nodes, rest_by_node, fps):
    """Sample one animation: returns (frames, flat float list of frames*joints*10)."""
    samplers = anim["samplers"]
    channels = anim["channels"]
    # per node: list of (path, times, values, interp)
    tracks = {}
    duration = 0.0
    for ch in channels:
        target = ch["target"]
        if "node" not in target or target["path"] not in ("translation", "rotation", "scale"):
            continue
        smp = samplers[ch["sampler"]]
        times, _, _ = accessor_values(gltf, binchunk, smp["input"])
        vals, count, ncomp = accessor_values(gltf, binchunk, smp["output"])
        duration = max(duration, times[-1] if times else 0.0)
        tracks.setdefault(target["node"], {})[target["path"]] = (times, vals, ncomp, smp.get("interpolation", "LINEAR"))
    frames = max(1, int(math.ceil(duration * fps)) + 1)
    out = []
    for f in range(frames):
        t = min(f / fps, duration)
        for node in joint_nodes:
            pose = list(rest_by_node[node])
            for path, slot, n in (("translation", slice(0, 3), 3), ("rotation", slice(3, 7), 4), ("scale", slice(7, 10), 3)):
                tr = tracks.get(node, {}).get(path)
                if tr is None:
                    continue
                times, vals, ncomp, interp = tr
                value = _interp(times, vals, ncomp, t, interp)
                if path == "rotation":
                    value = quat_norm(value)
                pose[slot] = value
            out.extend(pose)
    return frames, out


def _interp(times, vals, ncomp, t, interp):
    if t <= times[0]:
        return list(vals[0:ncomp])
    if t >= times[-1]:
        k = len(times) - 1
        return list(vals[k * ncomp:(k + 1) * ncomp])
    lo = 0
    hi = len(times) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if times[mid] <= t:
            lo = mid
        else:
            hi = mid
    a = vals[lo * ncomp:(lo + 1) * ncomp]
    b = vals[hi * ncomp:(hi + 1) * ncomp]
    w = (t - times[lo]) / (times[hi] - times[lo])
    if interp == "STEP":
        return list(a)
    return [a[i] + (b[i] - a[i]) * w for i in range(ncomp)]


def convert(src: pathlib.Path, fps: int):
    gltf, binchunk = read_glb(src)
    mesh = gltf["meshes"][0]
    rows = {"positions": [], "normals": [], "uv": [], "joints": [], "weights": [], "indices": []}
    base = 0
    for prim in mesh["primitives"]:
        attrs = prim["attributes"]
        p, n, _ = accessor_values(gltf, binchunk, attrs["POSITION"])
        rows["positions"].extend(p)
        count = len(p) // 3
        rows["normals"].extend(accessor_values(gltf, binchunk, attrs["NORMAL"])[0] if "NORMAL" in attrs else [0.0, 1.0, 0.0] * count)
        rows["uv"].extend(accessor_values(gltf, binchunk, attrs["TEXCOORD_0"])[0] if "TEXCOORD_0" in attrs else [0.0, 0.0] * count)
        rows["joints"].extend(int(v) for v in accessor_values(gltf, binchunk, attrs["JOINTS_0"])[0])
        rows["weights"].extend(accessor_values(gltf, binchunk, attrs["WEIGHTS_0"])[0])
        if "indices" in prim:
            ii = accessor_values(gltf, binchunk, prim["indices"])[0]
            rows["indices"].extend(int(v) + base for v in ii)
        else:
            rows["indices"].extend(range(base, base + count))
        base += count

    skin = gltf["skins"][0]
    joint_nodes = skin["joints"]
    ibm = accessor_values(gltf, binchunk, skin["inverseBindMatrices"])[0] if "inverseBindMatrices" in skin else []
    rest_by_node = {i: node_rest(n) for i, n in enumerate(gltf["nodes"])}
    rest = [v for node in joint_nodes for v in rest_by_node[node]]
    clips = []
    for anim in gltf.get("animations", []):
        frames, values = sample_clip(gltf, binchunk, anim, joint_nodes, rest_by_node, fps)
        clips.append({"name": anim.get("name", f"clip{len(clips)}"), "frames": frames, "values": values})
    return {
        "vertices": len(rows["positions"]) // 3,
        "indices": len(rows["indices"]),
        "joints": len(joint_nodes),
        "joint_names": [gltf["nodes"][n].get("name", f"joint{i}") for i, n in enumerate(joint_nodes)],
        "joint_parents": _parents(gltf, joint_nodes),
        "rows": rows,
        "ibm": ibm,
        "rest": rest,
        "clips": clips,
        "fps": fps,
    }


def _parents(gltf, joint_nodes):
    parent_of = {}
    for i, n in enumerate(gltf["nodes"]):
        for c in n.get("children", []):
            parent_of[c] = i
    index = {node: i for i, node in enumerate(joint_nodes)}
    return [index.get(parent_of.get(node, -1), -1) for node in joint_nodes]


def write(out: pathlib.Path, d: dict):
    blobs = []
    header = {
        "version": VERSION,
        "vertices": d["vertices"],
        "indices": d["indices"],
        "joints": d["joints"],
        "fps": d["fps"],
        "joint_names": d["joint_names"],
        "joint_parents": d["joint_parents"],
        "clips": [],
        "blobs": [],
    }

    def add(name, typecode, values):
        arr = array.array(typecode, values)
        blobs.append((name, arr.tobytes()))
        header["blobs"].append({"name": name, "type": typecode, "count": len(arr)})

    add("positions", "f", d["rows"]["positions"])
    add("normals", "f", d["rows"]["normals"])
    add("uv", "f", d["rows"]["uv"])
    add("joints", "H", d["rows"]["joints"])
    add("weights", "f", d["rows"]["weights"])
    add("indices", "I", d["rows"]["indices"])
    add("inverse_bind", "f", d["ibm"])
    add("rest", "f", d["rest"])
    for k, clip in enumerate(d["clips"]):
        add(f"clip{k}", "f", clip["values"])
        header["clips"].append({"name": clip["name"], "frames": clip["frames"], "blob": f"clip{k}"})

    head = json.dumps(header, separators=(",", ":")).encode("utf-8")
    with out.open("wb") as f:
        f.write(MAGIC_OUT + struct.pack("<II", VERSION, len(head)) + head)
        for _, b in blobs:
            f.write(b)
    return out


def read_back(path: pathlib.Path):
    data = path.read_bytes()
    if data[:4] != MAGIC_OUT:
        raise SystemExit("bad magic")
    version, hlen = struct.unpack_from("<II", data, 4)
    header = json.loads(data[12:12 + hlen].decode("utf-8"))
    off = 12 + hlen
    blobs = {}
    for b in header["blobs"]:
        arr = array.array(b["type"])
        arr.frombytes(data[off: off + b["count"] * arr.itemsize])
        off += b["count"] * arr.itemsize
        blobs[b["name"]] = arr
    if off != len(data):
        raise SystemExit(f"trailing bytes: {len(data) - off}")
    return header, blobs


def selftest(src: pathlib.Path):
    gltf, _ = read_glb(src)
    mesh = gltf["meshes"][0]
    json_count = sum(gltf["accessors"][p["attributes"]["POSITION"]]["count"] for p in mesh["primitives"])
    out = ROOT / "build" / "assets" / "converted" / (src.stem + ".lcharacter")
    out.parent.mkdir(parents=True, exist_ok=True)
    d = convert(src, 30)
    write(out, d)
    header, blobs = read_back(out)
    checks = []

    def check(cond, label):
        checks.append((cond, label))
        print(("PASS " if cond else "FAIL ") + label)

    check(header["vertices"] == json_count, f"vertices {header['vertices']} == sum of POSITION counts in the glb JSON {json_count}")
    check(len(blobs["positions"]) == 3 * json_count, "positions has 3 floats per vertex")
    check(len(blobs["joints"]) == 4 * json_count, "joints has 4 per vertex")
    check(len(blobs["weights"]) == 4 * json_count, "weights has 4 per vertex")
    check(header["joints"] == len(gltf["skins"][0]["joints"]), f"joints {header['joints']} == skin.joints in the glb JSON")
    ibm_count = gltf["accessors"][gltf["skins"][0]["inverseBindMatrices"]]["count"]
    check(len(blobs["inverse_bind"]) == 16 * ibm_count, f"inverse bind matrices {ibm_count} x 16 floats")
    weights = blobs["weights"]
    sums = [sum(weights[i * 4:(i + 1) * 4]) for i in range(json_count)]
    check(all(abs(s - 1.0) < 1e-3 for s in sums), "every vertex's joint weights sum to 1")
    check(max(blobs["joints"]) < header["joints"], "every joint index is inside the skin")
    max_index = max(blobs["indices"])
    check(max_index < json_count, "every index is inside the vertex range")
    for clip in header["clips"]:
        n = clip["frames"] * header["joints"] * 10
        check(len(blobs[clip["blob"]]) == n, f"clip '{clip['name']}': {clip['frames']} frames x joints x 10 floats")
    ok = all(c for c, _ in checks)
    print(f"convert_glb selftest: {sum(1 for c, _ in checks if c)} / {len(checks)} checks; wrote {out}")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("src", type=pathlib.Path)
    ap.add_argument("out", type=pathlib.Path, nargs="?")
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest(args.src)
    if args.out is None:
        ap.error("out is required unless --selftest")
    write(args.out, convert(args.src, args.fps))
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
