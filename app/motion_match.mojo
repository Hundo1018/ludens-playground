"""Motion matching over one character's clip (step 6.3, design 1.8).

The features are the playground's (ludens-core's MotionDB only stores rows and searches them): each frame's feet and hip
are read from the model-space joint transforms, then expressed in the character's facing frame, so a match does not
depend on where the character stands or which way it faces.

Feature layout, dim = 24, in this order:
- for each foot (joints FEET_A, FEET_B): its position relative to the hip (x, y, z), and its velocity (x, z). 5 each.
- the hip's velocity (x, z).
- the root trajectory at +0.33 s, +0.67 s and +1.0 s: the hip's position relative to now (x, z), and its facing (x, z).
  4 each.

Velocities are central differences over the neighbouring frames. Frames past either end of the clip are clamped to the
end, so the trajectory of the last frames is the trajectory of the clip's last frame and not a continuation. The
clip's root travel is not periodic, so no wrap is used.

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
comptime HIP = 0  # torso_joint_1: its translation is the hip, its matrix gives the facing
comptime DIM = 24


def _world_mats(c: Character, frame: Int) raises -> List[Mat4]:
    """Model-space matrix of every joint at a clip frame: the root transform applied to the root joints, then each
    joint's local, in the same order `pose_palette_frame` uses."""
    var locals = locals_at(c.clip, frame, c.joint_count)
    var root = palette_to_mats(c.root)[0].copy()
    var out = List[Mat4]()
    for j in range(c.joint_count):
        var p = c.parents[j]
        if p < 0:
            out.append(root.copy() * locals[j].copy())
        else:
            out.append(out[p].copy() * locals[j].copy())
    return out^


struct Track(Movable):
    """Per frame: the hip's position (3), the hip's facing as a horizontal unit vector (2), and the two feet's positions
    (3 each, FEET_A then FEET_B). Stored flat, so a frame's values are at 3 * frame, 2 * frame and 6 * frame."""

    var frames: Int
    var fps: Int
    var hip: List[Real]
    var facing: List[Real]
    var feet: List[Real]

    def __init__(out self, frames: Int, fps: Int):
        self.frames = frames
        self.fps = fps
        self.hip = List[Real]()
        self.facing = List[Real]()
        self.feet = List[Real]()


def _track(c: Character) raises -> Track:
    var t = Track(c.frames, c.fps)
    for f in range(c.frames):
        var w = _world_mats(c, f)
        var h = w[HIP].copy()
        t.hip.append(h.get(0, 3))
        t.hip.append(h.get(1, 3))
        t.hip.append(h.get(2, 3))
        # The local +z axis of the hip, projected on the ground: the facing.
        var fx = h.get(0, 2)
        var fz = h.get(2, 2)
        var n = sqrt(fx * fx + fz * fz)
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
    """The clip's frames as a MotionDB (ludens-core), with the per-column scale and the track the probes come from."""

    var db: MotionDB
    var scale: List[Real]
    var track: Track

    def __init__(out self, var db: MotionDB, var scale: List[Real], var track: Track):
        self.db = db^
        self.scale = scale^
        self.track = track^

    def probe(self, f: Int) -> List[Real]:
        """The normalised feature of clip frame f: the vector a query at that frame sends to `query`."""
        var raw = _raw_feature(self.track, f)
        var out = List[Real]()
        for d in range(DIM):
            out.append(raw[d] / self.scale[d])
        return out^

    def nearest(self, f: List[Real]) raises -> Int:
        """Index of the nearest stored frame. The probe's length must be the database's dimension."""
        if len(f) != self.db.dim:
            raise Error("motion match: probe has " + String(len(f)) + " values, the database " + String(self.db.dim))
        return self.db.query(f)


def build_match(c: Character) raises -> MotionMatch:
    """The matching database for one clip of a character, one row per clip frame."""
    var t = _track(c)
    var rows = List[List[Real]]()
    var sumsq = List[Real](length=DIM, fill=Real(0))
    for f in range(t.frames):
        var r = _raw_feature(t, f)
        for d in range(DIM):
            sumsq[d] += r[d] * r[d]
        rows.append(r^)
    var scale = List[Real]()
    for d in range(DIM):
        var sd = sqrt(sumsq[d] / Real(t.frames))
        if sd < Real(1e-9):
            sd = Real(1)
        scale.append(sd)
    var db = MotionDB()
    db.dim = DIM
    for f in range(t.frames):
        for d in range(DIM):
            db.feats.append(rows[f][d] / scale[d])
        db.clip_of.append(0)
        db.time_of.append(Real(f) / Real(t.fps))
    return MotionMatch(db^, scale^, t^)


def m6_frames(frames: Int) -> List[Int]:
    """The 20 database frames M6 queries: frame i * frames // 20 for i in 0 .. 19."""
    var ks = List[Int]()
    for i in range(20):
        ks.append(i * frames // 20)
    return ks^


def m6_hash_of(hits: List[Int]) -> Int:
    """A hash of an index list, exact in Int: the same on native and wasm when the indices are the same."""
    var h = 0
    for x in hits:
        h = (h * 31 + x) % 1000003
    return h


def m6_hash(m: MotionMatch) raises -> Int:
    """M6's hash: the index each of the 20 query frames returns, hashed."""
    var hits = List[Int]()
    for k in m6_frames(m.track.frames):
        hits.append(m.nearest(m.probe(k)))
    return m6_hash_of(hits)
