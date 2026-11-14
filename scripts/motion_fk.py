#!/usr/bin/env python3
"""CMU motion (ASF/AMC) to .lmotion v2: the bonedata, units and root order, the per-frame dof values in degrees, and the
static-composition forward kinematics that step 6 settled (docs/design/step6-motion.md §1.5).

    python3 scripts/motion_fk.py --selftest <asf> <amc> <fps>     write build/assets/converted/<name>.lmotion, run M1
    python3 scripts/motion_fk.py <asf> <amc> <fps> <out>         write the .lmotion v2 only

Composition (static, §1.5):  C = Rz·Ry·Rx from the bone's axis; M = Rz·Ry·Rx from its dofs (absent dof = 0);
L = C·M·C⁻¹; W_root = M_root from RX RY RZ; W_child = W_parent·L; end = start + len·units·W·dir.
Standard library only."""
import math
import pathlib
import re
import struct
import sys

MAGIC = b"LMOT"
VERSION = 2


def _mat_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def _mat_T(a):
    return [[a[j][i] for j in range(3)] for i in range(3)]


def _mat_vec(a, v):
    return [sum(a[i][k] * v[k] for k in range(3)) for i in range(3)]


def _rx(d):
    c, s = math.cos(math.radians(d)), math.sin(math.radians(d))
    return [[1, 0, 0], [0, c, -s], [0, s, c]]


def _ry(d):
    c, s = math.cos(math.radians(d)), math.sin(math.radians(d))
    return [[c, 0, s], [0, 1, 0], [-s, 0, c]]


def _rz(d):
    c, s = math.cos(math.radians(d)), math.sin(math.radians(d))
    return [[c, -s, 0], [s, c, 0], [0, 0, 1]]


def static_rot(x, y, z):
    """Rz·Ry·Rx for angles in degrees (§1.5)."""
    return _mat_mul(_mat_mul(_rz(z), _ry(y)), _rx(x))


def parse_asf(path):
    """Bones (in ASF id order, with parents and the bonedata fields), the root's channel order and the units."""
    txt = pathlib.Path(path).read_text(encoding="utf-8", errors="replace")
    units = {m.group(1): m.group(2) for m in re.finditer(r"^\s*(length|angle)\s+(\S+)", txt.split(":units", 1)[1].split(":", 1)[0], re.M)} if ":units" in txt else {}
    length_unit = float(units.get("length", "1.0"))
    root_block = re.search(r":root(.*?):bonedata", txt, re.S).group(1)
    root_order = [t.upper() for t in re.search(r"order (.*)", root_block).group(1).split()]
    bd = re.search(r":bonedata(.*?):hierarchy", txt, re.S).group(1)
    bones = {}
    for blk in re.findall(r"begin(.*?)end", bd, re.S):
        d = {}
        for line in blk.strip().splitlines():
            k, _, v = line.strip().partition(" ")
            if k:
                d[k] = v.strip()
        ax = d["axis"].split()
        bones[d["name"]] = {
            "id": int(d["id"]),
            "dir": [float(x) for x in d["direction"].split()],
            "length": float(d["length"]),
            "axis": [float(ax[0]), float(ax[1]), float(ax[2])],
            "axis_order": ax[3] if len(ax) > 3 else "XYZ",
            "dof": [t.lower() for t in d.get("dof", "").split()],
        }
    hier = re.search(r":hierarchy(.*?)end", txt, re.S).group(1)
    parent = {}
    for line in hier.strip().splitlines():
        tok = line.split()
        if not tok or tok[0] == "begin":
            continue
        for ch in tok[1:]:
            parent[ch] = tok[0]
    for name, b in bones.items():
        b["parent"] = parent.get(name, "root")
    order = sorted(bones, key=lambda n: bones[n]["id"])
    return {"root_order": root_order, "length_unit": length_unit, "bones": bones, "order": order}


def parse_amc(path, names):
    """A list of frames; each maps bone name (or "root") to its channel values in the file's order."""
    frames, cur = [], None
    for ln in pathlib.Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        ln = ln.strip()
        if not ln or ln.startswith("#") or ln.startswith(":"):
            continue
        tok = ln.split()
        if len(tok) == 1 and tok[0].isdigit():
            cur = {}
            frames.append(cur)
            continue
        if cur is not None and tok[0] in names:
            cur[tok[0]] = [float(v) for v in tok[1:]]
    return frames


def positions(asf, frame):
    """Joint end positions in ASF length units (metres = units * 0.0254 / length_unit; see §1.3)."""
    bones = asf["bones"]
    rv = frame["root"]
    tv = {l: rv[i] for i, l in enumerate(asf["root_order"])}
    W = {"root": static_rot(tv.get("RX", 0.0), tv.get("RY", 0.0), tv.get("RZ", 0.0))}
    pos = {"root": [tv.get("TX", 0.0), tv.get("TY", 0.0), tv.get("TZ", 0.0)]}
    for name in asf["order"]:
        b = bones[name]
        p = b["parent"]
        C = static_rot(*b["axis"])
        Ci = _mat_T(C)
        vals = frame.get(name, [0.0] * len(b["dof"]))
        ang = {"X": 0.0, "Y": 0.0, "Z": 0.0}
        for k, ch in enumerate(b["dof"]):
            ang[ch[1].upper()] = vals[k]
        M = static_rot(ang["X"], ang["Y"], ang["Z"])
        L = _mat_mul(_mat_mul(C, M), Ci)
        Wb = _mat_mul(W[p], L)
        W[name] = Wb
        dv = _mat_vec(Wb, [c * b["length"] for c in b["dir"]])
        pos[name] = [pos[p][i] + dv[i] for i in range(3)]
    return pos


def write_v2(path, asf, frames, fps):
    """Layout: "LMOT", u32 version, u32 header length, JSON header, then f32 little-endian: the rest blob (per bone in
    the header's order: dir x y z, length, axis x y z = 7 floats) and the values (per frame: root TX TY TZ and RX RY RZ
    in the header's root order, then each non-root bone's dof values in its dof order)."""
    import json
    order = asf["order"]
    header = {
        "version": VERSION, "fps": fps, "frames": len(frames), "root_order": asf["root_order"],
        "length_unit": asf["length_unit"], "units_to_metres": 0.0254 / asf["length_unit"],
        "bones": [{"name": n, "parent": asf["bones"][n]["parent"], "dof": asf["bones"][n]["dof"],
                   "axis_order": asf["bones"][n]["axis_order"]} for n in order],
    }
    head = json.dumps(header, separators=(",", ":")).encode("utf-8")
    rest = []
    for n in order:
        b = asf["bones"][n]
        rest += b["dir"] + [b["length"]] + b["axis"]
    values = []
    for fr in frames:
        values += fr["root"][:6]
        for n in order:
            b = asf["bones"][n]
            vals = fr.get(n, [0.0] * len(b["dof"]))
            values += vals[: len(b["dof"])] + [0.0] * (len(b["dof"]) - len(vals))
    with pathlib.Path(path).open("wb") as f:
        f.write(MAGIC + struct.pack("<II", VERSION, len(head)) + head)
        f.write(struct.pack("<%df" % len(rest), *rest))
        f.write(struct.pack("<%df" % len(values), *values))
    return path


def read_v2(path):
    import json
    data = pathlib.Path(path).read_bytes()
    if data[:4] != MAGIC:
        raise SystemExit("bad magic")
    version, hlen = struct.unpack_from("<II", data, 4)
    if version != VERSION:
        raise SystemExit(f"want version {VERSION}, got {version}")
    header = json.loads(data[12:12 + hlen].decode("utf-8"))
    n_bones = len(header["bones"])
    off = 12 + hlen
    rest = struct.unpack_from("<%df" % (7 * n_bones), data, off)
    off += 4 * 7 * n_bones
    values = struct.unpack_from("<%df" % ((len(data) - off) // 4), data, off)
    return header, rest, values


def selftest(asf_path, amc_path, fps, out_dir):
    asf = parse_asf(asf_path)
    names = set(asf["bones"]) | {"root"}
    frames = parse_amc(amc_path, names)
    out = pathlib.Path(out_dir) / (pathlib.Path(amc_path).stem + ".lmotion")
    out.parent.mkdir(parents=True, exist_ok=True)
    write_v2(out, asf, frames, fps)
    header, rest, values = read_v2(out)
    checks = []

    def check(cond, label):
        checks.append(bool(cond))
        print(("PASS " if cond else "FAIL ") + label)

    unit_m = 0.0254 / asf["length_unit"]  # metres per ASF length unit (§1.3)
    rest_frame = {"root": [0.0] * 6}
    p0 = positions(asf, rest_frame)
    femur = math.dist(p0["lhipjoint"], p0["lfemur"]) * unit_m
    print(f"lfemur {femur:.3f} m (units {asf['length_unit']} -> {unit_m:.5f} m per unit)")
    check(0.35 <= femur <= 0.50, f"M1 lfemur {femur:.3f} m is between 0.35 and 0.50")
    low0 = min(p0["ltoes"][1], p0["rtoes"][1]) * unit_m
    head0 = p0["head"][1] * unit_m
    rest_h = head0 - low0
    print(f"rest height {rest_h:.3f} m (head {head0:.3f} m above the root, lowest toe {low0:.3f} m)")
    check(1.5 <= rest_h <= 1.9, f"M1 rest height {rest_h:.3f} m is between 1.5 and 1.9")
    check(p0["head"][1] > p0["lfoot"][1] and p0["ltoes"][1] <= p0["head"][1], "M1 at rest the head is highest and the toes lowest")
    allp = [positions(asf, fr) for fr in frames]
    fps_f = float(fps)
    for side in ("ltoes", "rtoes"):
        hs = sorted(q[side][1] for q in allp)
        floor = hs[int(0.05 * (len(hs) - 1))]
        sp = []
        for i in range(1, len(allp)):
            a, b = allp[i - 1][side], allp[i][side]
            if b[1] <= floor + 0.03 * (1 / unit_m) and a[1] <= floor + 0.03 * (1 / unit_m) and abs(b[1] - a[1]) * unit_m * fps_f < 0.1:
                sp.append(math.hypot(b[0] - a[0], b[2] - a[2]) * unit_m * fps_f)
        sp.sort()
        med = sp[len(sp) // 2] if sp else float("nan")
        print(f"{side}: 5th-percentile floor {floor * unit_m:+.3f} m, contact frames {len(sp)}, median horizontal speed {med:.3f} m/s")
        check(sp and med < 0.15, f"M1 foot skate {side}: median {med:.3f} m/s is below 0.15")
    lo = min(min(q["ltoes"][1], q["rtoes"][1]) for q in allp) * unit_m
    print(f"lowest toe over the trial {lo:+.3f} m")
    for fi in [0, len(frames) // 2]:
        q = allp[fi]
        print(f"arms frame {fi}: left wrist-shoulder {(q['lwrist'][1]-q['lhumerus'][1])*unit_m:+.3f} m, right {(q['rwrist'][1]-q['rhumerus'][1])*unit_m:+.3f} m")
    print(f"wrote {out}")
    print(f"motion_fk selftest: {sum(checks)} / {len(checks)} checks")
    return 0 if all(checks) else 1


def main(argv):
    if argv[1:2] == ["--selftest"]:
        asf, amc, fps = argv[2], argv[3], argv[4]
        return selftest(asf, amc, fps, "build/assets/converted")
    asf_p, amc_p, fps, out = argv[1], argv[2], argv[3], argv[4]
    asf = parse_asf(asf_p)
    frames = parse_amc(amc_p, set(asf["bones"]) | {"root"})
    write_v2(out, asf, frames, int(fps))
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
