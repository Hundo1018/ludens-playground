#!/usr/bin/env python3
"""Retarget a CMU walk (ASF/AMC, 120 fps) onto CesiumMan by world-rotation transfer with rest alignment (step 6.1,
docs/design/step6-motion.md §1.6), bake it as a new clip through convert_glb.py's own writer (kind 101), and check M2 and
M3 on the written file.

    python3 scripts/retarget.py <CesiumMan.glb> <07.asf> <07_01.amc> <out.lcharacter>
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
ROOT_RATIO = None  # derived by leg_ratio() from segment lengths (§1.6); never a hard-coded constant


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


def leg_ratio(glb, asf_path):
    """CesiumMan's thigh plus shin (rest world, mean of the two legs) over subject's femur plus tibia (ASF, same units)."""
    d = cg.convert(pathlib.Path(glb), DST_FPS)
    root_m = mat4_from_colmajor(d["root_transform"])
    _, world_rest = cesium_rest(d)
    W = [mat4_mul(root_m, world_rest[j]) for j in range(len(d["joint_parents"]))]
    p = lambda j: [W[j][r][3] for r in range(3)]
    cm = (math.dist(p(11), p(13)) + math.dist(p(13), p(15)) + math.dist(p(12), p(14)) + math.dist(p(14), p(16))) / 2
    asf = mf.parse_asf(asf_path)
    u = 0.0254 / asf["length_unit"]
    b = asf["bones"]
    cmu = ((b["lfemur"]["length"] + b["ltibia"]["length"]) + (b["rfemur"]["length"] + b["rtibia"]["length"])) / 2 * u
    return cm / cmu


def build(glb, asf_path, amc_path, out_path, in_place=False, root_dy=0.0, window=None, ratio=None, step=None):
    """Bake the walk as clip kind 101. in_place (the page's choice, §6.2): the root's horizontal position is held at its
    value on the first frame, so the walk plays where it stands; the root height and every joint are kept."""
    asf = mf.parse_asf(asf_path)
    unit_m = 0.0254 / asf["length_unit"]
    frames = source_frames(asf, amc_path)
    if window is None:
        window = loop_window(asf, frames)
    a, b = window
    frames = frames[a:b]
    step = STEP if step is None else step
    ratio = leg_ratio(glb, asf_path) if ratio is None else ratio
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
    picked = list(range(0, len(frames), step))
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
                tr = [unit_m * pos["root"][r] * ratio for r in range(3)]
                if in_place:
                    tr = [0.0, tr[1], 0.0]
                tr = [tr[0], tr[1] + root_dy, tr[2]]  # the floor offset (§1.6, floating feet)
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
    return len(picked), J, window


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


def _positions_rel(asf, frame):
    """Joint end positions relative to the root's horizontal position (root xz removed), ASF units."""
    W, pos = fk_world(asf, frame)
    x0, z0 = pos["root"][0], pos["root"][2]
    return [[v[0] - x0, v[1], v[2] - z0] for k, v in pos.items() if k != "root"]


def loop_window(asf, frames, period_range=(100, 160), start_range=(0, 60), by_ratio=False):
    """Pick [a, b) about one gait cycle long whose end is closest to its start. Default objective: the summed joint
    distance between the two ends (root xz removed). by_ratio: the seam criterion itself, the jump from the window's
    last clip frame back to its first divided by the median per-clip-frame motion (the check's 'loop seam' bound is 2x).
    Periods are multiples of STEP, since the clip keeps every STEP-th source frame."""
    if by_ratio:
        start_range = (0, min(200, len(frames)))  # the seam criterion may start anywhere in the first 200 source frames
    best = None
    rel = {}
    def get(i):
        if i not in rel:
            rel[i] = _positions_rel(asf, frames[i])
        return rel[i]
    for a in range(start_range[0], start_range[1]):
        for period in range(period_range[0], period_range[1]):
            if period % STEP != 0:
                continue
            b = a + period
            if b >= len(frames):
                continue
            if by_ratio:
                seq = list(range(a, b, STEP))
                per = sorted(sum(math.dist(pa, pb) for pa, pb in zip(get(seq[k]), get(seq[k + 1]))) for k in range(len(seq) - 1))
                med = per[len(per) // 2]
                jump = sum(math.dist(pa, pb) for pa, pb in zip(get(seq[-1]), get(a)))
                d = jump / med if med > 0 else float("inf")
            else:
                d = sum(math.dist(pa, pb) for pa, pb in zip(get(a), get(b)))
            if best is None or d < best[0]:
                best = (d, a, b)
    return best[1], best[2]


def build_with_floor(glb, asf_path, amc_path, out_path, period_range=(100, 160), by_ratio=False):
    """Two passes: a bake with no offset, the feet measured in it, then the offset applied and the clip written again.
    The offset moves the root's height only."""
    import array as _array
    asf = mf.parse_asf(asf_path)
    frames_all = source_frames(asf, amc_path)
    window = loop_window(asf, frames_all, period_range=period_range, by_ratio=by_ratio)
    tmp = out_path + ".tmp"
    build(glb, asf_path, amc_path, tmp, root_dy=0.0, window=window)
    header, blobs, offsets = cg.read_back(pathlib.Path(tmp))
    vals = _array.array("f")
    vals.frombytes(blobs[101])
    d = cg.convert(pathlib.Path(glb), DST_FPS)
    parents = d["joint_parents"]
    root_m = mat4_from_colmajor(d["root_transform"])
    p5 = leg5_percentile(list(vals), len(parents), parents, root_m)
    _, world_rest = cesium_rest(d)
    rest_leg = mat4_mul(root_m, world_rest[17])[1][3]  # leg_L_5 at rest, in the shared frame (0.021 m)
    dy = rest_leg - p5
    pathlib.Path(tmp).unlink()
    n, J, window = build(glb, asf_path, amc_path, out_path, root_dy=dy, window=window)
    print(f"floor: 5th percentile of min(leg_L_5, leg_R_5) {p5:+.4f} m before the offset; rest leg {rest_leg:+.4f} m; offset {dy:+.4f} m")
    return n, J, window


def leg5_percentile(values, J, parents, root_m):
    n_frames = len(values) // (J * 10)
    lows = []
    for f in range(n_frames):
        w = mirror_world(root_m, values, f, J, parents)
        lows.append(min(w[17][1][3], w[18][1][3]))
    lows.sort()
    return lows[int(0.05 * (len(lows) - 1))]


def skate_speeds(worlds, j, fps):
    """Horizontal speeds (m/s) of joint j in contact: height within 0.03 m of its 5th percentile and vertical speed under
    0.1 m/s. Sorted."""
    hs = sorted(w[j][1][3] for w in worlds)
    floor = hs[int(0.05 * (len(hs) - 1))]
    sp = []
    for i in range(1, len(worlds)):
        pa, pb = worlds[i - 1][j], worlds[i][j]
        ya, yb = pa[1][3], pb[1][3]
        if yb <= floor + 0.03 and ya <= floor + 0.03 and abs(yb - ya) * fps < 0.1:
            sp.append(math.hypot(pb[0][3] - pa[0][3], pb[2][3] - pa[2][3]) * fps)
    return sorted(sp)


def eval_bake(glb, asf_path, amc_path, window):
    """The same window baked at full rate (step 1) with the derived ratio and the floor offset, read back as worlds."""
    import array as _array
    d = cg.convert(pathlib.Path(glb), DST_FPS)
    parents = d["joint_parents"]
    J = len(parents)
    root_m = mat4_from_colmajor(d["root_transform"])
    tmp = "/tmp/claude-0/m6/_eval_full.lcharacter"
    build(glb, asf_path, amc_path, tmp, root_dy=0.0, window=window, step=1)
    _, blobs, _ = cg.read_back(pathlib.Path(tmp))
    vals = _array.array("f"); vals.frombytes(blobs[101]); vals = list(vals)
    p5 = leg5_percentile(vals, J, parents, root_m)
    _, wr = cesium_rest(d)
    rest = mat4_mul(root_m, wr[17])[1][3]
    build(glb, asf_path, amc_path, tmp, root_dy=rest - p5, window=window, step=1)
    _, blobs, _ = cg.read_back(pathlib.Path(tmp))
    vals = _array.array("f"); vals.frombytes(blobs[101]); vals = list(vals)
    return [mirror_world(root_m, vals, f, J, parents) for f in range(len(vals) // (J * 10))]


def check(out_path, glb, asf_path, amc_path, kind=101, period_range=(100, 160), by_ratio=False):
    """M2 (direction, mapped non-leaf joints), M3 (bone lengths; the floor percentile within 0.01 m of rest; leg_5 not
    below -0.02 m), the target foot skate on leg_*_5 (median below 0.15 m/s, the root-ratio check), and the loop seam
    (the jump from the last clip frame to the first at most twice the median per-frame joint displacement)."""
    import array as _array
    asf = mf.parse_asf(asf_path)
    frames_all = source_frames(asf, amc_path)
    a0, b0 = loop_window(asf, frames_all, period_range=period_range, by_ratio=by_ratio)
    d = cg.convert(pathlib.Path(glb), DST_FPS)
    parents = d["joint_parents"]
    J = len(parents)
    root_m = mat4_from_colmajor(d["root_transform"])
    header, blobs, offsets = cg.read_back(pathlib.Path(out_path))
    vals = _array.array("f")
    vals.frombytes(blobs[kind])
    values = list(vals)
    n_frames = len(values) // (J * 10)
    worlds = [mirror_world(root_m, values, f, J, parents) for f in range(n_frames)]
    print(f"clip kind {kind}: {n_frames} frames x {J} joints; source window [{a0}, {b0})")
    fails = []

    # M2: mapped non-leaf directions against the source segments, at four clip frames
    worst_all = 0.0
    for f in [0, 8, 16, 24]:
        if f >= n_frames:
            continue
        s_src = a0 + STEP * f
        W, pos = fk_world(asf, frames_all[s_src])
        world = worlds[f]
        worst = 0.0
        per = {}
        for j in range(J):
            kids = [c for c in range(J) if parents[c] == j]
            if not kids:
                continue
            c = min(kids)
            td = unit([world[c][r][3] - world[j][r][3] for r in range(3)])
            sbone = asf["bones"][DIR_OF[j]]
            sd = unit(rot3_vec(W[DIR_OF[j]], sbone["dir"]))
            ang = math.acos(max(-1.0, min(1.0, sum(x * y for x, y in zip(td, sd)))))
            per[j] = math.degrees(ang)
            worst = max(worst, ang)
        worst_all = max(worst_all, worst)
        print(f"M2 clip frame {f} (source {s_src}): worst mapped direction error {math.degrees(worst):.4f} deg")
    m2 = worst_all < 1e-3
    fails.append(("M2", m2))

    # M3a: bone lengths over the clip
    base = worlds[0]
    lmax = 0.0
    for w in worlds:
        for j in range(J):
            if parents[j] < 0:
                continue
            pj = parents[j]
            l0 = math.dist([base[j][r][3] for r in range(3)], [base[pj][r][3] for r in range(3)])
            l1 = math.dist([w[j][r][3] for r in range(3)], [w[pj][r][3] for r in range(3)])
            lmax = max(lmax, abs(l1 - l0))
    # M3b: the floor: 5th percentile of min(leg_L_5, leg_R_5) within 0.01 m of the rest leg height
    lows = sorted(min(w[17][1][3], w[18][1][3]) for w in worlds)
    p5 = lows[int(0.05 * (len(lows) - 1))]
    rest_leg = mat4_mul(root_m, cesium_rest(d)[1][17])[1][3]
    floor_ok = abs(p5 - rest_leg) <= 0.01
    leg_min = min(lows)
    print(f"M3 bone lengths: max change {lmax:.2e} m (bound 1e-5)")
    print(f"M3 floor: 5th percentile {p5:+.4f} m, rest leg {rest_leg:+.4f} m, difference {p5 - rest_leg:+.4f} m (bound 0.01); lowest leg_5 {leg_min:+.4f} m (bound -0.02)")
    fails.append(("M3 lengths", lmax < 1e-5))
    fails.append(("M3 floor", floor_ok and leg_min >= -0.02))

    # target foot skate on leg_*_5, measured at 120 fps (a full-rate bake of the same window: §1.6, step 2)
    full = eval_bake(glb, asf_path, amc_path, (a0, b0))
    for side, j in (("left", 17), ("right", 18)):
        sp = skate_speeds(full, j, 120)
        med = sp[len(sp) // 2] if sp else float("nan")
        print(f"target foot skate, leg_{side}_5 at 120 fps: contact frames {len(sp)}, median {med:.3f} m/s (bound 0.15)")
        fails.append((f"target skate {side}", bool(sp) and med < 0.15))

    # loop seam: jump from the last frame to the first, against the median per-frame joint displacement
    def joints(w):
        # root xz removed per frame: the clip plays in place (§6.3), so the seam is judged in place too
        x0, z0 = w[0][0][3], w[0][2][3]
        return [[w[j][0][3] - x0, w[j][1][3], w[j][2][3] - z0] for j in range(J)]
    disp = []
    for i in range(1, n_frames):
        disp.append(sum(math.dist(p, q) for p, q in zip(joints(worlds[i - 1]), joints(worlds[i]))))
    disp.sort()
    med_disp = disp[len(disp) // 2]
    seam = sum(math.dist(p, q) for p, q in zip(joints(worlds[-1]), joints(worlds[0])))
    print(f"loop seam: total joint jump {seam:.4f} m vs median per-frame total {med_disp:.4f} m (bound 2x)")
    fails.append(("seam", seam <= 2 * med_disp))

    for name, ok in fails:
        print(f"{name}: {'PASS' if ok else 'FAIL'}")
    return 0 if all(ok for _, ok in fails) else 1


def build_clips(glb, asf_path, trials, out_path):
    """Several trials from one subject into one character: each trial is baked with build_with_floor (its own loop
    window and floor offset) and written as the next clip after the converter's own (kind 100, the Khronos rest clip):
    the first trial is kind 101, the next 102, and so on. trials: list of (name, amc_path, period_range); the period
    range bounds the loop window's length in source frames (the slow walk's cycle is longer than the default 100-160)."""
    import array as _array
    d = cg.convert(pathlib.Path(glb), DST_FPS)
    for k, (name, amc, period_range, by_ratio) in enumerate(trials):
        kind = 101 + k
        tmp = out_path + f".{kind}.tmp"
        n, J, window = build_with_floor(glb, asf_path, amc, tmp, period_range=period_range, by_ratio=by_ratio)
        header, blobs, offsets = cg.read_back(pathlib.Path(tmp))
        vals = _array.array("f")
        vals.frombytes(blobs[101])
        pathlib.Path(tmp).unlink()
        d["clips"].append({"name": name, "frames": n, "values": list(vals)})
        print(f"kind {kind} {name}: {n} frames, source window {window}")
    out = pathlib.Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    cg.write(out, d)
    return len(d["clips"])


def main(argv):
    if argv[1:2] == ["--clips"]:
        out, glb, asf_path = argv[2], argv[3], argv[4]
        # name=amc or name=amc:min:max (the loop window's period range, in source frames)
        trials = []
        for a in argv[5:]:
            name, rest = a.split("=", 1)
            parts = rest.split(":")
            pr = (int(parts[1]), int(parts[2])) if len(parts) >= 3 else (100, 160)
            trials.append((name, parts[0], pr, len(parts) == 4 and parts[3] == "r"))
        build_clips(glb, asf_path, trials, out)
        return 0
    if argv[1:2] == ["--check"]:
        return check(argv[2], argv[3], argv[4], argv[5])
    n, J, window = build_with_floor(argv[1], argv[2], argv[3], argv[4])
    print(f"wrote {argv[4]} with clip 1: {n} frames at {DST_FPS} fps, {J} joints, source window {window}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
