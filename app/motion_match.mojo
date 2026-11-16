"""Motion matching over one character's clips (step 6.3, design 1.8), on ludens-core's procedural.motion_match.

The features, the per-column scale, the database and the matcher are ludens-core's (ROADMAP 17.92); this module only says
where CesiumMan's feet and hip are and which way it faces: the feet are the toes (joints FEET_A, FEET_B), the hip is joint
HIP's translation, the facing is read from the two hip joints (see `_track`). The trajectory horizons are +0.33, +0.67 and
+1.0 s, so a row has 24 values.
"""
from std.math import sqrt
from geometry.mat import Mat4
from geometry.vec import Real, Vec3
from frontier_assets import Character, locals_at
from app.skin_pass import palette_to_mats
from procedural.motion_match import MotionTrack, MotionMatchDB


comptime FEET_A = 17  # leg_joint_L_5 (CesiumMan's left toe)
comptime FEET_B = 18  # leg_joint_R_5 (right toe)
comptime HIP = 0  # torso_joint_1: the hip is its translation
comptime LEG_L = 11  # leg_joint_L_1: the left hip joint
comptime LEG_R = 12  # leg_joint_R_1: the right hip joint


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


def _track(c: Character) raises -> MotionTrack:
    """Hip, facing and feet per frame, as ludens-core's MotionTrack. The facing is the ground direction forward: the hip
    joints' lateral vector (leg_joint_L_1 minus leg_joint_R_1, joints 11 and 12) turned 90 degrees on the ground. The
    spine's local z is not used: it leans with the torso and its ground projection gets short (0.049 m at its minimum on
    the Khronos clip). The sign is fixed once, from the rest pose: forward is the side on which the toes (joints 17 and
    18) lie from the hip."""
    var t = MotionTrack(c.fps, 2)
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
        var w = _world_mats(c, f)
        var lx = w[LEG_L].get(0, 3) - w[LEG_R].get(0, 3)
        var lz = w[LEG_L].get(2, 3) - w[LEG_R].get(2, 3)
        var feet = List[Vec3]()
        for foot in [FEET_A, FEET_B]:
            feet.append(Vec3(w[foot].get(0, 3), w[foot].get(1, 3), w[foot].get(2, 3), Real(0)))
        t.add_frame(Vec3(w[HIP].get(0, 3), w[HIP].get(1, 3), w[HIP].get(2, 3), Real(0)), -lz * sign, lx * sign, feet)
    return t^


def horizons() -> List[Real]:
    """The trajectory horizons: +0.33, +0.67 and +1.0 s."""
    var h = List[Real]()
    h.append(Real(0.33))
    h.append(Real(0.67))
    h.append(Real(1.0))
    return h^


def build_match(c: Character, clips: List[List[Float32]]) raises -> MotionMatchDB:
    """The matching database over the given clips of one character (each in the converter's clip layout)."""
    var tracks = List[MotionTrack]()
    for i in range(len(clips)):
        var cc = c.copy()
        cc.clip = clips[i].copy()
        cc.frames = len(cc.clip) // (10 * cc.joint_count)
        tracks.append(_track(cc))
    return MotionMatchDB(tracks^, horizons())


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


def m6_hash(m: MotionMatchDB) raises -> Int:
    """M6's hash: the row each of the 20 query rows returns, hashed."""
    var hits = List[Int]()
    for row in m6_rows(m.rows()):
        hits.append(m.nearest(m.probe_row(row)))
    return m6_hash_of(hits)
