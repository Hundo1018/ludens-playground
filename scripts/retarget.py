#!/usr/bin/env python3
"""Retarget a CMU walk (ASF/AMC, 120 fps) onto CesiumMan by world-rotation transfer with rest alignment (step 6.1,
docs/design/step6-motion.md §1.6), bake it as a new clip through convert_glb.py's own writer (kind 101), and check M2 and
M3 on the written file.

    python3 scripts/retarget.py <CesiumMan.glb> <07.asf> <07_01.amc> <out.lcharacter> [--world]
      (the walk plays in place by default; --world keeps its root translation)
    python3 scripts/retarget.py --check <out.lcharacter> <CesiumMan.glb> <07.asf> <07_01.amc>

Math (shared frame: Y up, metres, facing +z; CMU is already there, the CesiumMan yaw is 0, §1.6):
  W^s_j(rest) = root_transform · (rest chain of joint j), column-major from convert_glb.
  A_j        = shortest arc from the target's rest direction of joint j to the source bone's rest direction; leaves take
               their parent's A.
  W_j(f)     = W_b(f) · A_j · W^s_j(rest)            (W_b(rest) = I, so the rest direction maps exactly)
  local_j    = W_parent(f)⁻¹ · W_j(f)                 (non-root, frame-independent)
  local_0    = root_transform⁻¹ · W_0(f)  and translation scaled by 0.755 (the hip-height ratio, §1.6 root rule).
  Clip frames: every 4th source frame (120 -> 30 fps). Standard library only, plus convert_glb for the glb and the writer.
"""
import math
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import convert_glb as cg  # noqa: E402
import motion_fk as mf  # noqa: E402

SRC_FPS = 120
DST_FPS = 30
STEP = SRC_FPS // DST_FPS

# CesiumMan joint -> CMU bone whose start is the joint's position (step 6 table, §1.6). Joint 0's direction comes from
# lowerback, the CMU segment that starts at the root.
MAP = {0: "root", 1: "upperback", 2: "thorax", 3: "upperneck", 4: "head",
       5: "lhumerus", 6: "rhumerus", 7: "lradius", 8: "rradius", 9: "lwrist", 10: "rwrist",
       11: "lfemur", 12: "rfemur", 13: "ltibia", 14: "rtibia", 15: "lfoot", 16: "rfoot", 17: "ltoes", 18: "rtoes"}
DIR_OF = dict(MAP)
DIR_OF[0] = "lowerback"
ROOT_RATIO = 0.755  # (CesiumMan hip above the lowest toe, 0.593) / (CMU, 0.785), §1.6


def mat4_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def mat4_from_colmajor(v):
    return [[v[c * 4 + r] for c in range(4)] for r in range(4)]


def affine_inv(m):
    """Inverse of a rigid-or-scaled affine 4x4 (rotation block R, translation t): [R^T·…] works for orthonormal R."""
    r = [[m[i][j] for j in range(3)] for i in range(3)]
    t = [m[i][3] for i in range(3)]
    rt = [[r[j][i] for j in range(3)] for i in range(3)]
    ti = [-sum(rt[i][k] * t[k] for k in range(3)) for i in range(3)]
    out = [[rt[i][j] for j in range(3)] + [ti[i]] for i in range(3)]
    return out + [[0, 0, 0, 1]]


def rot3_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def rot3_T(a):
    return [[a[j][i] for j in range(3)] for i in range(3)]


def rot3_vec(a, v):
    return [sum(a[i][k] * v[k] for k in range(3)) for i in range(3)]


def unit(v):
    n = math.sqrt(sum(c * c for c in v))
    return [c / n for c in v]


def shortest_arc(u, v):
    """The rotation R with R·u = v (unit vectors), by Rodrigues; a 180° turn picks a perpendicular axis."""
    d = max(-1.0, min(1.0, sum(a * b for a, b in zip(u, v))))
    if d > 1 - 1e-12:
        return [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    if d < -1 + 1e-12:
        axis = unit([1.0, 0.0, 0.0] if abs(u[0]) < 0.9 else [0.0, 1.0, 0.0])
        axis = unit([axis[1] * u[2] - axis[2] * u[1], axis[2] * u[0] - axis[0] * u[2], axis[0] * u[1] - axis[1] * u[0]])
        k = axis
        return _rodrigues(k, math.pi)
    c = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]
    s = math.sqrt(sum(x * x for x in c))
    axis = [x / s for x in c]
    return _rodrigues(axis, math.acos(d))


def _rodrigues(k, th):
    c, s = math.cos(th), math.sin(th)
    K = [[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]]
    K2 = rot3_mul(K, K)
    return [[(1 if i == j else 0) + s * K[i][j] + (1 - c) * K2[i][j] for j in range(3)] for i in range(3)]


def rot3_to_quat(m):
    tr = m[0][0] + m[1][1] + m[2][2]
    if tr > 0:
        s = math.sqrt(tr + 1.0) * 2
        w = 0.25 * s
        x = (m[2][1] - m[1][2]) / s
        y = (m[0][2] - m[2][0]) / s
        z = (m[1][0] - m[0][1]) / s
    elif m[0][0] > m[1][1] and m[0][0] > m[2][2]:
        s = math.sqrt(1.0 + m[0][0] - m[1][1] - m[2][2]) * 2
        w = (m[2][1] - m[1][2]) / s
        x = 0.25 * s
        y = (m[0][1] + m[1][0]) / s
        z = (m[0][2] + m[2][0]) / s
    elif m[1][1] > m[2][2]:
        s = math.sqrt(1.0 + m[1][1] - m[0][0] - m[2][2]) * 2
        w = (m[0][2] - m[2][0]) / s
        x = (m[0][1] + m[1][0]) / s
        y = 0.25 * s
        z = (m[1][2] + m[2][1]) / s
    else:
        s = math.sqrt(1.0 + m[2][2] - m[0][0] - m[1][1]) * 2
        w = (m[1][0] - m[0][1]) / s
        x = (m[0][2] + m[2][0]) / s
        y = (m[1][2] + m[2][1]) / s
        z = 0.25 * s
    n = math.sqrt(x * x + y * y + z * z + w * w)
    return [x / n, y / n, z / n, w / n]


def quat_to_rot3(q):
    x, y, z, w = q
    return [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]


def cesium_rest(d):
    """Rest chain per joint in CesiumMan's own frame (before root_transform): 4x4 affine, from convert_glb's rest blob."""
    parents = d["joint_parents"]
    rest = d["rest"]
    loc = []
    for j in range(len(parents)):
        t = rest[10 * j:10 * j + 3]
        q = rest[10 * j + 3:10 * j + 7]
        s = rest[10 * j + 7:10 * j + 10]
        R = quat_to_rot3(q)
        loc.append([[R[r][c] * s[c] for c in range(3)] + [t[r]] for r in range(3)] + [[0, 0, 0, 1]])
    world = []
    for j, p in enumerate(parents):
        world.append(loc[j] if p < 0 else mat4_mul(world[p], loc[j]))
    return loc, world


def source_frames(asf, amc_path):
    frames = mf.parse_amc(amc_path, set(asf["bones"]) | {"root"})
    return frames


def fk_world(asf, frame):
    """CMU FK per bone: world rotation and end position (ASF units), the static composition of motion_fk."""
    bones = asf["bones"]
    rv = frame["root"]
    tv = {l: rv[i] for i, l in enumerate(asf["root_order"])}
    W = {"root": mf.static_rot(tv.get("RX", 0.0), tv.get("RY", 0.0), tv.get("RZ", 0.0))}
    pos = {"root": [tv.get("TX", 0.0), tv.get("TY", 0.0), tv.get("TZ", 0.0)]}
    for name in asf["order"]:
        b = bones[name]
        p = b["parent"]
        C = mf.static_rot(*b["axis"])
        vals = frame.get(name, [0.0] * len(b["dof"]))
        ang = {"X": 0.0, "Y": 0.0, "Z": 0.0}
        for k, ch in enumerate(b["dof"]):
            ang[ch[1].upper()] = vals[k]
        M = mf.static_rot(ang["X"], ang["Y"], ang["Z"])
        L = mf._mat_mul(mf._mat_mul(C, M), mf._mat_T(C))
        W[name] = mf._mat_mul(W[p], L)
        dv = mf._mat_vec(W[name], [c * b["length"] for c in b["dir"]])
        pos[name] = [pos[p][i] + dv[i] for i in range(3)]
    return W, pos


def build(glb, asf_path, amc_path, out_path, in_place=True):
    """Bake the walk as clip kind 101. in_place (the page's choice, §6.2): the root's horizontal position is held at its
    value on the first frame, so the walk plays where it stands; the root height and every joint are kept."""
    asf = mf.parse_asf(asf_path)
    unit_m = 0.0254 / asf["length_unit"]
    frames = source_frames(asf, amc_path)
    d = cg.convert(pathlib.Path(glb), DST_FPS)
    parents = d["joint_parents"]
    J = len(parents)
    root_m = mat4_from_colmajor(d["root_transform"])
    root_R = [[root_m[r][c] for c in range(3)] for r in range(3)]
    root_Ri = rot3_T(root_R)
    loc_c, world_c = cesium_rest(d)
    W_rest = [mat4_mul(root_m, world_c[j]) for j in range(J)]  # shared frame, includes root_transform
    # rest directions
    tgt_dir = {}
    for j in range(J):
        kids = [c for c in range(J) if parents[c] == j]
        if not kids:
            continue
        c = min(kids)
        pj = [W_rest[j][r][3] for r in range(3)]
        pc = [W_rest[c][r][3] for r in range(3)]
        tgt_dir[j] = unit([pc[i] - pj[i] for i in range(3)])
    src_rest_dir = {}
    for j, name in DIR_OF.items():
        if j in (0,):
            src_rest_dir[j] = unit(asf["bones"][name]["dir"])
        elif name in asf["bones"]:
            src_rest_dir[j] = unit(asf["bones"][name]["dir"])
    A = {}
    for j in range(J):
        if j in tgt_dir and j in src_rest_dir:
            A[j] = shortest_arc(tgt_dir[j], src_rest_dir[j])
    for j in range(J):
        if j not in A:
            A[j] = A[parents[j]]  # leaves: the parent's alignment (§1.6, edge cases)
    # frames
    values = []
    Wf = []
    picked = list(range(0, len(frames), STEP))
    for s in picked:
        W, pos = fk_world(asf, frames[s])
        Wj = [None] * J
        locs = []
        for j in range(J):
            # joint 0 (torso_1) follows lowerback: the M2 segment torso_1 -> torso_2 is lowerback's segment, and the
            # lowerback dofs must move it. The root's translation still places the chain (see tr below).
            Wb = W[DIR_OF.get(j, MAP[j])]
            Wj[j] = rot3_mul(rot3_mul(Wb, A[j]), [[W_rest[j][r][c] for c in range(3)] for r in range(3)])
        for j in range(J):
            if parents[j] < 0:
                R_local = rot3_mul(root_Ri, Wj[j])
            else:
                R_local = rot3_mul(rot3_T(Wj[parents[j]]), Wj[j])
            if parents[j] < 0:
                tr = [unit_m * pos["root"][r] * ROOT_RATIO for r in range(3)]
                if in_place:
                    tr = [0.0, tr[1], 0.0]
                t_local = rot3_vec(root_Ri, tr)
            else:
                t_local = [loc_c[j][r][3] for r in range(3)]
            q = rot3_to_quat(R_local)
            locs.append(t_local + q + [1.0, 1.0, 1.0])
        Wf.append(Wj)
        for row in locs:
            values += row
    d["clips"].append({"name": "cmu07_walk", "frames": len(picked), "values": values})
    out = pathlib.Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    cg.write(out, d)
    return len(picked), J


def mirror_world(root_m, values, frame, J, parents):
    """The Python mirror of build_palette_root's chain: world_0 = root · local_0, world_j = world_p · local_j."""
    base = frame * J * 10
    world = []
    for j in range(J):
        v = values[base + 10 * j: base + 10 * j + 10]
        R = quat_to_rot3(v[3:7])
        loc = [[R[r][c] * v[7 + c] for c in range(3)] + [v[r]] for r in range(3)] + [[0, 0, 0, 1]]
        world.append(loc if parents[j] < 0 else None)
        if parents[j] < 0:
            world[j] = mat4_mul(root_m, loc)
        else:
            world[j] = mat4_mul(world[parents[j]], loc)
    return world


def check(out_path, glb, asf_path, amc_path):
    asf = mf.parse_asf(asf_path)
    frames = source_frames(asf, amc_path)
    d = cg.convert(pathlib.Path(glb), DST_FPS)
    parents = d["joint_parents"]
    J = len(parents)
    root_m = mat4_from_colmajor(d["root_transform"])
    header, blobs, offsets = cg.read_back(pathlib.Path(out_path))
    kind = 100 + 1
    raw = blobs[kind]
    import array
    vals = array.array("f")
    vals.frombytes(raw)
    values = list(vals)
    n_frames = len(values) // (J * 10)
    print(f"written clip kind {kind}: {n_frames} frames x {J} joints")
    worst_all = 0.0
    fails = []
    for s in [0, 60, 120, 200]:
        f = s // STEP
        if f >= n_frames:
            continue
        W, pos = fk_world(asf, frames[s])
        world = mirror_world(root_m, values, f, J, parents)
        worst = 0.0
        per = {}
        for j in range(J):
            kids = [c for c in range(J) if parents[c] == j]
            if not kids:
                continue
            c = min(kids)
            tj = [world[j][r][3] for r in range(3)]
            tc = [world[c][r][3] for r in range(3)]
            td = unit([tc[i] - tj[i] for i in range(3)])
            sbone = asf["bones"][DIR_OF[j]]
            sd = unit(rot3_vec(W[DIR_OF[j]], sbone["dir"]))  # the source segment in the world frame
            cosang = max(-1.0, min(1.0, sum(a * b for a, b in zip(td, sd))))
            ang = math.acos(cosang)
            per[j] = (DIR_OF[j], math.degrees(ang))
            worst = max(worst, ang)
        if s == 60 or s == 200:
            print("  per-joint (joint: source bone, error deg):", ", ".join(f"{j}:{v[0]}={v[1]:.2f}" for j, v in per.items()))
        worst_all = max(worst_all, worst)
        print(f"M2 frame {s} (clip {f}): worst mapped direction error {math.degrees(worst):.4f} deg ({worst:.6f} rad)")
        if worst >= 1e-3:
            fails.append((s, worst))
    rest_pos = [[world[j][r][3] for r in range(3)] for j in range(J)]
    # M3: target bone lengths constant over the clip (against frame 0), and leg_5 joints above -0.02 m
    base_world = mirror_world(root_m, values, 0, J, parents)
    lmax = 0.0
    floor_min = 1e9
    for f in range(n_frames):
        wf = mirror_world(root_m, values, f, J, parents)
        for j in range(J):
            if parents[j] < 0:
                continue
            p = parents[j]
            l0 = math.dist([base_world[j][r][3] for r in range(3)], [base_world[p][r][3] for r in range(3)])
            l1 = math.dist([wf[j][r][3] for r in range(3)], [wf[p][r][3] for r in range(3)])
            lmax = max(lmax, abs(l1 - l0))
        floor_min = min(floor_min, wf[17][1][3], wf[18][1][3])
    print(f"M3 bone lengths: max change {lmax:.2e} m (bound 1e-5); lowest leg_5 joint over the clip {floor_min:+.4f} m (bound -0.02)")
    ok = (worst_all < 1e-3) and lmax < 1e-5 and floor_min >= -0.02
    print("M2: PASS" if worst_all < 1e-3 else f"M2: FAIL at {fails}")
    print("M3: PASS" if (lmax < 1e-5 and floor_min >= -0.02) else "M3: FAIL")
    return 0 if ok else 1


def main(argv):
    if argv[1:2] == ["--check"]:
        return check(argv[2], argv[3], argv[4], argv[5])
    in_place = "--world" not in argv
    n, J = build(argv[1], argv[2], argv[3], argv[4], in_place=in_place)
    print(f"wrote {argv[4]} with clip 1: {n} frames at {DST_FPS} fps, {J} joints")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
