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
VERSION = 2

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
        "root_transform": root_transform_of(gltf, joint_nodes)[0],
    }


def _parents(gltf, joint_nodes):
    parent_of = {}
    for i, n in enumerate(gltf["nodes"]):
        for c in n.get("children", []):
            parent_of[c] = i
    index = {node: i for i, node in enumerate(joint_nodes)}
    return [index.get(parent_of.get(node, -1), -1) for node in joint_nodes]


def _mat_from_trs(t, r, s):
    """Column-major 4x4 from translation (3), quaternion x,y,z,w (4) and scale (3)."""
    x, y, z, w = r
    xx, yy, zz = x * x, y * y, z * z
    xy, xz, yz = x * y, x * z, y * z
    wx, wy, wz = w * x, w * y, w * z
    m = [
        (1 - 2 * (yy + zz)) * s[0], 2 * (xy + wz) * s[0], 2 * (xz - wy) * s[0], 0.0,
        2 * (xy - wz) * s[1], (1 - 2 * (xx + zz)) * s[1], 2 * (yz + wx) * s[1], 0.0,
        2 * (xz + wy) * s[2], 2 * (yz - wx) * s[2], (1 - 2 * (xx + yy)) * s[2], 0.0,
        t[0], t[1], t[2], 1.0,
    ]
    return m


_IDENTITY = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]


def _mat_mul(a, b):
    """Column-major product a * b."""
    out = [0.0] * 16
    for c in range(4):
        for r in range(4):
            out[c * 4 + r] = sum(a[k * 4 + r] * b[c * 4 + k] for k in range(4))
    return out


def _mat_vec(m, v):
    return [sum(m[k * 4 + r] * v[k] for k in range(4)) for r in range(4)]


def _local_matrix(node):
    if "matrix" in node:
        return [float(x) for x in node["matrix"]]
    return _mat_from_trs(node.get("translation", [0.0, 0.0, 0.0]),
                         quat_norm(node.get("rotation", [0.0, 0.0, 0.0, 1.0])),
                         node.get("scale", [1.0, 1.0, 1.0]))


def root_transform_of(gltf, joint_nodes):
    """Product of the non-joint ancestors above the skeleton root (identity if none). One root only."""
    parent_of = {}
    for i, n in enumerate(gltf["nodes"]):
        for c in n.get("children", []):
            parent_of[c] = i
    joint_set = set(joint_nodes)
    roots = [n for n in joint_nodes if parent_of.get(n) not in joint_set]
    if len(roots) != 1:
        raise SystemExit(f"step 5 supports one skeleton root; found {len(roots)}")
    chain = []
    p = parent_of.get(roots[0])
    while p is not None:
        chain.append(p)
        p = parent_of.get(p)
    m = list(_IDENTITY)
    for node in reversed(chain):  # top-down
        m = _mat_mul(m, _local_matrix(gltf["nodes"][node]))
    return m, roots[0], parent_of


def rest_palette(gltf, joint_nodes, ibm_flat, rest_flat, root_m, root_node, parent_of):
    """Palette per joint at the rest pose: (root_transform * joint chain) * IBM, the same product for every joint."""
    index = {node: i for i, node in enumerate(joint_nodes)}
    joints = len(joint_nodes)
    glob = [None] * joints
    palette = [None] * joints
    # parents come before children in a valid skeleton; walk until every joint is placed
    placed = 0
    while placed < joints:
        progressed = False
        for i, node in enumerate(joint_nodes):
            if glob[i] is not None:
                continue
            pnode = parent_of.get(node)
            if node == root_node:
                parent_glob = None
            elif pnode in index and glob[index[pnode]] is not None:
                parent_glob = glob[index[pnode]]
            else:
                continue
            t = rest_flat[i * 10: i * 10 + 3]
            r = rest_flat[i * 10 + 3: i * 10 + 7]
            s = rest_flat[i * 10 + 7: i * 10 + 10]
            local = _mat_from_trs(t, r, s)
            # The exported IBMs exclude the non-joint ancestors, which live in root_m. Every joint's global chain
            # therefore starts from root_m, so every joint carries it (not only the root). Measured on CesiumMan:
            # with root_m on every joint, rest skinning maps p to root_m * p for every vertex; root-only gave an error of 0.74.
            glob[i] = _mat_mul(root_m, local) if parent_glob is None else _mat_mul(parent_glob, local)
            ibm = ibm_flat[i * 16:(i + 1) * 16]
            palette[i] = _mat_mul(glob[i], ibm)
            placed += 1
            progressed = True
        if not progressed:
            raise SystemExit("skeleton parents do not form a tree")
    return palette


def _skin_point(p, joints_v, weights_v, palette):
    out = [0.0, 0.0, 0.0]
    for k in range(4):
        w = weights_v[k]
        if w == 0.0:
            continue
        m = palette[joints_v[k]]
        q = _mat_vec(m, [p[0], p[1], p[2], 1.0])
        out[0] += w * q[0]
        out[1] += w * q[1]
        out[2] += w * q[2]
    return out


def write(out: pathlib.Path, d: dict):
    """Write the v2 layout (see docs/design/step5-rendering.md, 1.4)."""
    blobs = []

    def add(kind, typecode, values):
        blobs.append((kind, array.array(typecode, values).tobytes()))

    add(1, "f", d["rows"]["positions"])
    add(2, "f", d["rows"]["normals"])
    add(3, "f", d["rows"]["uv"])
    add(4, "H", d["rows"]["joints"])
    add(5, "f", d["rows"]["weights"])
    add(6, "I", d["rows"]["indices"])
    add(7, "f", d["ibm"])
    add(8, "f", d["rest"])
    add(9, "i", d["joint_parents"])
    add(10, "f", d["root_transform"])
    for k, clip in enumerate(d["clips"]):
        add(100 + k, "f", clip["values"])

    header = {
        "format": "lcharacter",
        "version": VERSION,
        "vertices": d["vertices"],
        "indices": d["indices"],
        "joints": d["joints"],
        "fps": d["fps"],
        "joint_names": d["joint_names"],
        "clips": [{"name": c["name"], "frames": c["frames"], "kind": 100 + k} for k, c in enumerate(d["clips"])],
    }
    head = json.dumps(header, separators=(",", ":")).encode("utf-8")
    count = len(blobs)
    pos = 12 + 12 * count + 4 + len(head)
    directory = []
    placed = []
    for kind, data in blobs:
        pos = (pos + 15) & ~15
        directory.append((kind, pos, len(data)))
        placed.append(data)
        pos += len(data)
    with out.open("wb") as f:
        f.write(MAGIC_OUT + struct.pack("<II", VERSION, count))
        for kind, off, nbytes in directory:
            f.write(struct.pack("<III", kind, off, nbytes))
        f.write(struct.pack("<I", len(head)) + head)
        cur = 12 + 12 * count + 4 + len(head)
        for (kind, off, nbytes), data in zip(directory, placed):
            f.write(b"\x00" * (off - cur))
            f.write(data)
            cur = off + nbytes
    return out


def read_back(path: pathlib.Path):
    """Read a v2 file. Returns (header, {kind: bytes}, {kind: offset})."""
    data = path.read_bytes()
    if data[:4] != MAGIC_OUT:
        raise SystemExit("bad magic")
    version, count = struct.unpack_from("<II", data, 4)
    if version != 2:
        raise SystemExit(f"expected version 2, got {version}; regenerate the asset")
    directory = [struct.unpack_from("<III", data, 12 + 12 * i) for i in range(count)]
    hpos = 12 + 12 * count
    (hlen,) = struct.unpack_from("<I", data, hpos)
    header = json.loads(data[hpos + 4: hpos + 4 + hlen].decode("utf-8"))
    blobs, offsets = {}, {}
    for kind, off, nbytes in directory:
        blobs[kind] = data[off: off + nbytes]
        offsets[kind] = off
    return header, blobs, offsets


def _floats(blob, typecode="f"):
    arr = array.array(typecode)
    arr.frombytes(blob)
    return arr


def selftest(src: pathlib.Path):
    gltf, _ = read_glb(src)
    mesh = gltf["meshes"][0]
    json_count = sum(gltf["accessors"][p["attributes"]["POSITION"]]["count"] for p in mesh["primitives"])
    out = ROOT / "build" / "assets" / "converted" / (src.stem + ".lcharacter")
    out.parent.mkdir(parents=True, exist_ok=True)
    d = convert(src, 30)
    write(out, d)
    header, blobs, offsets = read_back(out)
    checks = []

    def check(cond, label):
        checks.append(bool(cond))
        print(("PASS " if cond else "FAIL ") + label)

    check(all(off % 16 == 0 for off in offsets.values()), "every blob offset is a multiple of 16")
    check(header["vertices"] == json_count, f"vertices {header['vertices']} == sum of POSITION counts in the glb JSON {json_count}")
    pos = _floats(blobs[1])
    nrm = _floats(blobs[2])
    jnt = _floats(blobs[4], "H")
    wgt = _floats(blobs[5])
    idx = _floats(blobs[6], "I")
    check(len(pos) == 3 * json_count, "positions has 3 floats per vertex")
    check(len(jnt) == 4 * json_count and len(wgt) == 4 * json_count, "joints and weights have 4 per vertex")
    skin = gltf["skins"][0]
    check(header["joints"] == len(skin["joints"]), f"joints {header['joints']} == skin.joints in the glb JSON")
    ibm_count = gltf["accessors"][skin["inverseBindMatrices"]]["count"]
    check(len(blobs[7]) == 16 * 4 * ibm_count, f"inverse bind matrices {ibm_count} x 16 floats")
    sums = [sum(wgt[i * 4:(i + 1) * 4]) for i in range(json_count)]
    check(all(abs(s - 1.0) < 1e-3 for s in sums), "every vertex's joint weights sum to 1")
    check(max(jnt) < header["joints"], "every joint index is inside the skin")
    check(max(idx) < json_count, "every index is inside the vertex range")
    rt = _floats(blobs[10])
    check(len(rt) == 16 and [rt[3], rt[7], rt[11], rt[15]] == [0.0, 0.0, 0.0, 1.0], "root transform is affine (last row 0 0 0 1)")
    print(f"  root transform (column-major): {[round(v, 6) for v in rt]}")
    for clip in header["clips"]:
        n = clip["frames"] * header["joints"] * 10
        values = _floats(blobs[clip["kind"]])
        check(len(values) == n, f"clip '{clip['name']}': {clip['frames']} frames x joints x 10 floats")
        scales = [values[f * header["joints"] * 10 + j * 10 + k] for f in range(clip["frames"]) for j in range(header["joints"]) for k in (7, 8, 9)]
        # 1e-5, not 1e-6: the source animation data itself deviates by up to ~1.3e-6 (measured on CesiumMan, clip 0).
        # The purpose is to reject non-uniform scale, which the skinning does not support; 1e-5 still does that.
        check(all(abs(s - 1.0) <= 1e-5 for s in scales), f"clip '{clip['name']}': every scale channel within 1e-5 of 1")
    # rest-pose identity: skinning at the rest pose must reproduce the input positions
    rest = _floats(blobs[8])
    parents = list(_floats(blobs[9], "i"))
    ibm_flat = list(_floats(blobs[7]))
    root_node = skin["joints"][parents.index(-1)]
    _, _, parent_of = root_transform_of(gltf, skin["joints"])
    palette = rest_palette(gltf, skin["joints"], ibm_flat, list(rest), list(rt), root_node, parent_of)
    worst = 0.0
    worst_joint = None
    for v in range(json_count):
        p = pos[3 * v: 3 * v + 3]
        q = _skin_point(p, jnt[4 * v: 4 * v + 4], wgt[4 * v: 4 * v + 4], palette)
        err = max(abs(q[c] - p[c]) for c in range(3))
        if err > worst:
            worst = err
            worst_joint = int(jnt[4 * v + max(range(4), key=lambda k: wgt[4 * v + k])])
    print(f"  rest-pose skinning: max error {worst:.3e} over {json_count} vertices (worst dominant joint {worst_joint})")
    # Expected: the rest pose is the root transform applied to the input positions (the Z-up to Y-up ancestors),
    # because the IBMs exclude those ancestors. Compare against root_transform * p.
    worst_root = 0.0
    for v in range(json_count):
        p = pos[3 * v: 3 * v + 3]
        q = _skin_point(p, jnt[4 * v: 4 * v + 4], wgt[4 * v: 4 * v + 4], palette)
        rp = _mat_vec(list(rt), [p[0], p[1], p[2], 1.0])
        worst_root = max(worst_root, max(abs(q[c] - rp[c]) for c in range(3)))
    print(f"  rest-pose skinning vs root_transform * p: max error {worst_root:.3e}")
    check(worst_root < 1e-4, "rest-pose skinning reproduces root_transform * p (max error below 1e-4)")
    ok = all(checks)
    print(f"convert_glb selftest: {sum(checks)} / {len(checks)} checks; wrote {out}")
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
