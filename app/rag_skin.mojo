"""V5 (and reference baseline B4): the knocked-down guard drawn as CesiumMan, skinned to the six bodies of the Frontier's
figure (frontier/world.mojo knock_down), instead of six boxes.

Each joint follows one body: the pelvis (0) joint 0; the torso (1) the spine (1, 2) and the right arm (6, 8, 10); the head
(2) the neck (3, 4); the left thigh (3) the left leg (11, 13, 15, 17); the right thigh (4) the right leg (12, 14, 16, 18);
the arm (5) the left arm (5, 7, 9). The standing pose is the guard's clip frame at the tackle, placed where the guard stood
and turned by its heading. A body's motion since the knock-down, D = C * R^-1 (C its pose now, R its pose when it was
added), moves its joints' world matrices: world_j = D_b(j) * place * model_j. The palette is world_j * inverse bind, so
the draw item sits at the origin with no turn. ludens-engine #74 asks for this in gameplay.ragdoll.
"""
from std.math import sin, cos
from geometry.mat import Mat4
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from frontier_assets import Character
from app.foot_ik import _model_mats
from app.skin_pass import palette_to_mats

def joint_body(j: Int) -> Int:
    """The figure's body a CesiumMan joint follows (see the module comment)."""
    if j == 0:
        return 0
    if j == 1 or j == 2 or j == 6 or j == 8 or j == 10:
        return 1
    if j == 3 or j == 4:
        return 2
    if j == 5 or j == 7 or j == 9:
        return 5
    if j == 11 or j == 13 or j == 15 or j == 17:
        return 3
    if j == 12 or j == 14 or j == 16 or j == 18:
        return 4
    return 0


def pose_mat(p: Vec3, q: Quat) -> Mat4:
    """The rigid transform of a body: rotation from the quaternion, then the translation."""
    var m = Mat4.identity()
    var x = q.x
    var y = q.y
    var z = q.z
    var w = q.w
    m.set(0, 0, 1 - 2 * (y * y + z * z))
    m.set(0, 1, 2 * (x * y - z * w))
    m.set(0, 2, 2 * (x * z + y * w))
    m.set(1, 0, 2 * (x * y + z * w))
    m.set(1, 1, 1 - 2 * (x * x + z * z))
    m.set(1, 2, 2 * (y * z - x * w))
    m.set(2, 0, 2 * (x * z - y * w))
    m.set(2, 1, 2 * (y * z + x * w))
    m.set(2, 2, 1 - 2 * (x * x + y * y))
    m.set(0, 3, p[0])
    m.set(1, 3, p[1])
    m.set(2, 3, p[2])
    return m^


def rigid_inverse(m: Mat4) -> Mat4:
    var r = Mat4.identity()
    for i in range(3):
        for k in range(3):
            r.set(i, k, m.get(k, i))
    for i in range(3):
        r.set(i, 3, -(r.get(i, 0) * m.get(0, 3) + r.get(i, 1) * m.get(1, 3) + r.get(i, 2) * m.get(2, 3)))
    return r^


def placement(pos: Vec3, yaw: Real) -> Mat4:
    """Model to world: turned about +Y by yaw, then moved to pos on the ground."""
    var m = Mat4.identity()
    var c = cos(yaw)
    var s = sin(yaw)
    m.set(0, 0, c)
    m.set(0, 2, s)
    m.set(2, 0, -s)
    m.set(2, 2, c)
    m.set(0, 3, pos[0])
    m.set(1, 3, Real(0.0))
    m.set(2, 3, pos[2])
    return m^


def rag_palette(c: Character, clip: List[Float32], frame: Int, place: Mat4, rest: List[Mat4], now: List[Mat4]) raises -> List[Float32]:
    """The palette of CesiumMan moved by the figure's bodies (rest: their poses when added; now: their poses this frame)."""
    var model = _model_mats(c, clip, frame)
    var delta = List[Mat4]()
    for b in range(len(rest)):
        delta.append(now[b].copy() * rigid_inverse(rest[b]))
    var ibm = palette_to_mats(c.ibm)
    var out = List[Float32]()
    for j in range(c.joint_count):
        var b = joint_body(j)
        if b >= len(delta):
            b = 0
        var m = delta[b].copy() * place.copy() * model[j].copy() * ibm[j].copy()
        for col in range(4):
            for row in range(4):
                out.append(Float32(Float64(m.get(row, col))))
    return out^
