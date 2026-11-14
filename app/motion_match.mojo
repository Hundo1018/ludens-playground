"""Motion matching over one character's clips (step 6.3, design 1.8).

The features are the playground's (ludens-core's MotionDB only stores rows and searches them): each frame's feet and hip
are read from the model-space joint transforms, then expressed in the character's facing frame, so a match does not
depend on where the character stands or which way it faces.

Feature layout, dim = 24, in this order:
- for each foot (joints FEET_A, FEET_B): its position relative to the hip (x, y, z), and its velocity (x, z). 5 each.
- the hip's velocity (x, z).
- the root trajectory at +0.33 s, +0.67 s and +1.0 s: the hip's position relative to now (x, z), and its facing (x, z).
  4 each.

Velocities are central differences over the neighbouring frames. Frames past either end of a clip are clamped to that
clip's end, and no feature reads across a clip boundary: each clip has its own track. The clip's root travel is not
periodic, so no wrap is used.

Each column is divided by its standard deviation over the clip's frames (no mean is removed), as design 1.8 says. The
same division is applied to the probe, so `query` compares like with like.
"""
from std.math import sqrt
from geometry.mat import Mat4
from geometry.vec import Real
from frontier_assets import Character, locals_at
from app.skin_pass import palette_to_mats
from procedural.anim_graph import MotionDB


comptime FEET_A = 17  # leg_joint_L_5 (CesiumMan's left toe)
comptime FEET_B = 18  # leg_joint_R_5 (right toe)
comptime HIP = 0  # torso_joint_1: the hip is its translation
comptime LEG_L = 11  # leg_joint_L_1: the left hip joint
comptime LEG_R = 12  # leg_joint_R_1: the right hip joint
comptime DIM = 24


def _world_from(c: Character, locals: List[Mat4]) raises -> List[Mat4]:
    """Model-space matrix of every joint from its local: the root transform applied to the root joints, then each
    joint's local, in the same order `pose_palette_frame` uses."""
    var root = palette_to_mats(c.root)[0].copy()
    var out = List[Mat4]()
    for j in range(c.joint_count):
        var p = c.parents[j]
        if p < 0:
            out.append(root.copy() * locals[j].copy())
        else:
            out.append(out[p].copy() * locals[j].copy())
    return out^


def _world_mats(c: Character, frame: Int) raises -> List[Mat4]:
    return _world_from(c, locals_at(c.clip, frame, c.joint_count))


struct Track(Movable):
    """Per frame: the hip's position (3), the hip's facing as a horizontal unit vector (2), and the two feet's positions
    (3 each, FEET_A then FEET_B). Stored flat, so a frame's values are at 3 * frame, 2 * frame and 6 * frame."""

    var frames: Int
    var fps: Int
    var hip: List[Real]
    var facing: List[Real]
    var feet: List[Real]
    var min_ground: Real  # the smallest length of the hip's ground projection over the clip, before normalising

    def __init__(out self, frames: Int, fps: Int):
        self.frames = frames
        self.fps = fps
        self.hip = List[Real]()
        self.facing = List[Real]()
        self.feet = List[Real]()
        self.min_ground = Real(1e30)


def _track(c: Character) raises -> Track:
    """Hip, facing and feet per frame. The facing is the ground direction forward: the hip joints' lateral vector
    (leg_joint_L_1 minus leg_joint_R_1, joints 11 and 12) turned 90 degrees on the ground. The spine's local z is not
    used: it leans with the torso and its ground projection gets short (0.049 m at its minimum on the Khronos clip).
    The sign is fixed once, from the rest pose: forward is the side on which the toes (joints 17 and 18) lie from the hip."""
    var t = Track(c.frames, c.fps)
    var mats = List[List[Mat4]]()
    for f in range(c.frames):
        mats.append(_world_mats(c, f))
    # The sign comes from the rest pose, the same for every clip: a stance frame of a walk can have the toes behind the
    # hip, which flipped the facing of the slow and brisk trials when the sign was read from each clip's frame 0.
    var w0 = _world_from(c, locals_at(c.rest, 0, c.joint_count))
    var lat0x = w0[LEG_L].get(0, 3) - w0[LEG_R].get(0, 3)
    var lat0z = w0[LEG_L].get(2, 3) - w0[LEG_R].get(2, 3)
    var toe0x = Real(0.5) * (w0[FEET_A].get(0, 3) + w0[FEET_B].get(0, 3)) - w0[HIP].get(0, 3)
    var toe0z = Real(0.5) * (w0[FEET_A].get(2, 3) + w0[FEET_B].get(2, 3)) - w0[HIP].get(2, 3)
    # candidate forward (-lz, lx); keep it when the toes lie on that side
    var sign = Real(1)
    if (-lat0z) * toe0x + lat0x * toe0z < Real(0):
        sign = Real(-1)
    for f in range(c.frames):
        ref w = mats[f]
        var h = w[HIP].copy()
        t.hip.append(h.get(0, 3))
        t.hip.append(h.get(1, 3))
        t.hip.append(h.get(2, 3))
        var lx = w[LEG_L].get(0, 3) - w[LEG_R].get(0, 3)
        var lz = w[LEG_L].get(2, 3) - w[LEG_R].get(2, 3)
        var fx = -lz * sign
        var fz = lx * sign
        var n = sqrt(fx * fx + fz * fz)
        if n < t.min_ground:
            t.min_ground = n
        if n < Real(1e-6):
            fx = Real(0)
            fz = Real(1)
            n = Real(1)
        t.facing.append(fx / n)
        t.facing.append(fz / n)
        for foot in [FEET_A, FEET_B]:
            var m = w[foot].copy()
            t.feet.append(m.get(0, 3))
            t.feet.append(m.get(1, 3))
            t.feet.append(m.get(2, 3))
    return t^


def _clamp(i: Int, frames: Int) -> Int:
    if i < 0:
        return 0
    if i > frames - 1:
        return frames - 1
    return i


def _to_facing(t: Track, f: Int, dx: Real, dz: Real) -> Tuple[Real, Real]:
    """A world-ground vector in frame f's facing frame: u along the facing, v to its left."""
    var fx = t.facing[2 * f]
    var fz = t.facing[2 * f + 1]
    return (dx * fx + dz * fz, dx * (-fz) + dz * fx)


def _raw_feature(t: Track, f: Int) -> List[Real]:
    var out = List[Real]()
    var fps = Real(t.fps)
    var hx = t.hip[3 * f]
    var hz = t.hip[3 * f + 2]
    # Feet: position relative to the hip, in the facing frame, then the velocity.
    for k in range(2):
        var base = 3 * (2 * f + k)
        var rel = _to_facing(t, f, t.feet[base] - hx, t.feet[base + 2] - hz)
        out.append(rel[0])
        out.append(t.feet[base + 1] - t.hip[3 * f + 1])
        out.append(rel[1])
        var a = _clamp(f - 1, t.frames)
        var b = _clamp(f + 1, t.frames)
        var dt = Real(b - a) / fps
        if b == a:
            dt = Real(1)
        var va = 3 * (2 * a + k)
        var vb = 3 * (2 * b + k)
        var vel = _to_facing(t, f, (t.feet[vb] - t.feet[va]) / dt, (t.feet[vb + 2] - t.feet[va + 2]) / dt)
        out.append(vel[0])
        out.append(vel[1])
    # Hip velocity, in the facing frame.
    var a = _clamp(f - 1, t.frames)
    var b = _clamp(f + 1, t.frames)
    var dt = Real(b - a) / fps
    if b == a:
        dt = Real(1)
    var hv = _to_facing(
        t, f,
        (t.hip[3 * b] - t.hip[3 * a]) / dt,
        (t.hip[3 * b + 2] - t.hip[3 * a + 2]) / dt,
    )
    out.append(hv[0])
    out.append(hv[1])
    # Trajectory: where the hip and its facing are at +0.33, +0.67 and +1.0 s, in the current facing frame.
    var horizons = List[Real]()
    horizons.append(Real(0.33))
    horizons.append(Real(0.67))
    horizons.append(Real(1.0))
    for s in horizons:
        var i = _clamp(f + Int(s * fps + Real(0.5)), t.frames)
        var pos = _to_facing(t, f, t.hip[3 * i] - hx, t.hip[3 * i + 2] - hz)
        var dir = _to_facing(t, f, t.facing[2 * i], t.facing[2 * i + 1])
        out.append(pos[0])
        out.append(pos[1])
        out.append(dir[0])
        out.append(dir[1])
    return out^


struct MotionMatch(Movable):
    """The clips' frames as one MotionDB (ludens-core): rows are the frames of clip 0, then clip 1, and so on. clip_of
    and frame_of map a row back to its clip and frame; tracks[i] is clip i's track, the probes come from it."""

    var db: MotionDB
    var scale: List[Real]
    var tracks: List[Track]
    var frame_of: List[Int]

    def __init__(out self, var db: MotionDB, var scale: List[Real], var tracks: List[Track], var frame_of: List[Int]):
        self.db = db^
        self.scale = scale^
        self.tracks = tracks^
        self.frame_of = frame_of^

    def rows(self) -> Int:
        return len(self.frame_of)

    def probe_row(self, row: Int) -> List[Real]:
        """The normalised feature of database row `row`: the vector a query from that frame sends to `nearest`."""
        var raw = _raw_feature(self.tracks[self.db.clip_of[row]], self.frame_of[row])
        var out = List[Real]()
        for d in range(DIM):
            out.append(raw[d] / self.scale[d])
        return out^

    def raw_row(self, row: Int) -> List[Real]:
        """The unnormalised feature of database row `row`."""
        return _raw_feature(self.tracks[self.db.clip_of[row]], self.frame_of[row])

    def nearest(self, f: List[Real]) raises -> Int:
        """Index of the nearest stored row. The probe's length must be the database's dimension."""
        if len(f) != self.db.dim:
            raise Error("motion match: probe has " + String(len(f)) + " values, the database " + String(self.db.dim))
        return self.db.query(f)


def build_match(c: Character, clips: List[List[Float32]]) raises -> MotionMatch:
    """The matching database over the given clips of one character (each in the converter's clip layout)."""
    var tracks = List[Track]()
    var raws = List[List[Real]]()
    var frame_of = List[Int]()
    var clip_of = List[Int]()
    var sumsq = List[Real](length=DIM, fill=Real(0))
    for i in range(len(clips)):
        var cc = c.copy()
        cc.clip = clips[i].copy()
        cc.frames = len(cc.clip) // (10 * cc.joint_count)
        var t = _track(cc)
        for f in range(t.frames):
            var r = _raw_feature(t, f)
            for d in range(DIM):
                sumsq[d] += r[d] * r[d]
            raws.append(r^)
            frame_of.append(f)
            clip_of.append(i)
        tracks.append(t^)
    var total = len(raws)
    var scale = List[Real]()
    for d in range(DIM):
        var sd = sqrt(sumsq[d] / Real(total))
        if sd < Real(1e-9):
            sd = Real(1)
        scale.append(sd)
    var db = MotionDB()
    db.dim = DIM
    for row in range(total):
        for d in range(DIM):
            db.feats.append(raws[row][d] / scale[d])
        db.clip_of.append(clip_of[row])
        db.time_of.append(Real(frame_of[row]) / Real(c.fps))
    return MotionMatch(db^, scale^, tracks^, frame_of^)


def m6_rows(total: Int) -> List[Int]:
    """The 20 database rows M6 queries: row i * total // 20 for i in 0 .. 19, spread over every clip."""
    var out = List[Int]()
    for i in range(20):
        out.append(i * total // 20)
    return out^


def m6_hash_of(hits: List[Int]) -> Int:
    """A hash of an index list, exact in Int: the same on native and wasm when the indices are the same."""
    var h = 0
    for x in hits:
        h = (h * 31 + x) % 1000003
    return h


def m6_hash(m: MotionMatch) raises -> Int:
    """M6's hash: the row each of the 20 query rows returns, hashed."""
    var hits = List[Int]()
    for row in m6_rows(m.rows()):
        hits.append(m.nearest(m.probe_row(row)))
    return m6_hash_of(hits)
