"""Reference baseline E2 (original stage 4, foot IK): CesiumMan's feet placed on a slope with ludens-core's
procedural.ik.two_bone.

The clip is authored on a flat floor (y = 0 in model space). On ground of height g(x, z) relative to the character's
base, each ankle's target comes from ludens-core's foot_plant with the clip frame's own ankle height as the height above
the ground: the ankle is raised by g under that foot, so the clip's lift (swing, heel roll) is kept on top of the slope,
and foot_plant's tilt (at most MAX_TILT) turns the foot toward the slope's normal. The pelvis is lowered by the lower foot's offset when that is negative (the whole body moves
down), so the downhill leg can reach. two_bone gives the new knee and ankle positions with the knee bending toward where
it already points; they become two rotations of the model-space joint matrices: the thigh's subtree about the hip (the
knee onto its new position), then the shin's subtree about the new knee (the ankle onto its target). The palette is
rebuilt from those matrices. The step from two_bone's positions to joint rotations is the playground's own (ludens-engine#76:
the engine's IK returns positions, not a pose).

Joints (CesiumMan): hip 11 / 12, knee 13 / 14, ankle 15 / 16, toe 17 / 18 (left / right); 0 is the pelvis.
The error of a foot is its ankle's height above the ground under it minus the clip's ankle height above the flat floor:
0 when the foot sits on the slope exactly as the clip set it on the floor. Without IK it is -g.
"""
from std.math import sqrt, acos, sin, cos, tan
from geometry.mat import Mat4
from geometry.vec import Real, Vec3, dot, cross, length, normalize
from procedural.ik import two_bone, foot_plant
from frontier_assets import Character, locals_at, strip_root_xz
from app.skin_pass import palette_to_mats

comptime HIP_L = 11
comptime HIP_R = 12
comptime KNEE_L = 13
comptime KNEE_R = 14
comptime ANKLE_L = 15
comptime ANKLE_R = 16
comptime MAX_LIFT = Real(0.5)  # foot_plant leaves a foot alone when the ground is farther than this
comptime MAX_TILT = Real(0.6)  # radians


@fieldwise_init
struct Slope(Copyable, ImplicitlyCopyable, Movable):
    """Ground rising along the character's world heading: height = tan(angle) * (distance along the heading)."""

    var angle: Real  # radians
    var yaw: Real  # the character's draw yaw about +Y (model x, z turned by it give the world offset)
    var heading_x: Real  # the world direction the ground rises along (unit, on the ground)
    var heading_z: Real

    def height(self, mx: Real, mz: Real) -> Real:
        """The ground height under a model-space point, relative to the character's base."""
        var c = cos(self.yaw)
        var s = sin(self.yaw)
        var wx = c * mx + s * mz
        var wz = -s * mx + c * mz
        return tan(self.angle) * (wx * self.heading_x + wz * self.heading_z)

    def normal_model(self) -> Vec3:
        """The ground's unit normal in model space (the world normal turned back by the yaw)."""
        var sn = sin(self.angle)
        var nx = -sn * self.heading_x
        var nz = -sn * self.heading_z
        var c = cos(self.yaw)
        var s = sin(self.yaw)
        return Vec3(c * nx - s * nz, cos(self.angle), s * nx + c * nz, 0.0)


def _pos(m: Mat4) -> Vec3:
    return Vec3(m.get(0, 3), m.get(1, 3), m.get(2, 3), 0.0)


def _rot_about(axis: Vec3, angle: Real, pivot: Vec3) -> Mat4:
    """The rotation by `angle` about the line through `pivot` along unit `axis`, as a 4x4 matrix."""
    var c = cos(angle)
    var s = sin(angle)
    var t = 1 - c
    var x = axis[0]
    var y = axis[1]
    var z = axis[2]
    var r = Mat4.identity()
    r.set(0, 0, t * x * x + c)
    r.set(0, 1, t * x * y - s * z)
    r.set(0, 2, t * x * z + s * y)
    r.set(1, 0, t * x * y + s * z)
    r.set(1, 1, t * y * y + c)
    r.set(1, 2, t * y * z - s * x)
    r.set(2, 0, t * x * z - s * y)
    r.set(2, 1, t * y * z + s * x)
    r.set(2, 2, t * z * z + c)
    for i in range(3):
        var rp = r.get(i, 0) * pivot[0] + r.get(i, 1) * pivot[1] + r.get(i, 2) * pivot[2]
        r.set(i, 3, pivot[i] - rp)
    return r^


def _turn(a: Vec3, b: Vec3, pivot: Vec3) -> Mat4:
    """The smallest rotation about `pivot` taking direction a onto direction b."""
    var la = length(a)
    var lb = length(b)
    if la < 1e-9 or lb < 1e-9:
        return Mat4.identity()
    var ax = cross(a, b)
    var n = length(ax)
    var cs = max(Real(-1), min(Real(1), dot(a, b) / (la * lb)))
    if n < 1e-9:
        return Mat4.identity()
    return _rot_about(ax * (1 / n), acos(cs), pivot)


def _in_subtree(parents: List[Int], j: Int, top: Int) -> Bool:
    var k = j
    while k >= 0:
        if k == top:
            return True
        k = parents[k]
    return False


def _model_mats(c: Character, clip: List[Float32], frame: Int) raises -> List[Mat4]:
    """Model-space joint matrices with the root transform and the clip played in place (as the palette does)."""
    var locals = locals_at(clip, frame, c.joint_count)
    var root = palette_to_mats(c.root)[0].copy()
    strip_root_xz(locals, root)
    var world = List[Mat4]()
    for j in range(c.joint_count):
        var p = c.parents[j]
        if p < 0:
            world.append(root.copy() * locals[j].copy())
        else:
            world.append(world[p].copy() * locals[j].copy())
    return world^


@fieldwise_init
struct FootIK(Copyable, Movable):
    var palette: List[Float32]
    var err_l: Real  # metres, with IK
    var err_r: Real
    var raw_l: Real  # metres, the same clip frame without IK
    var raw_r: Real
    var drop: Real  # the pelvis's drop (metres, <= 0)


def foot_ik(c: Character, clip: List[Float32], frame: Int, slope: Slope, on: Bool) raises -> FootIK:
    var world = _model_mats(c, clip, frame)
    var a_l = _pos(world[ANKLE_L])
    var a_r = _pos(world[ANKLE_R])
    var g_l = slope.height(a_l[0], a_l[2])
    var g_r = slope.height(a_r[0], a_r[2])
    var raw_l = -g_l
    var raw_r = -g_r
    var drop = Real(0)
    if on:
        drop = min(Real(0), min(g_l, g_r))
        if drop < 0:
            for j in range(c.joint_count):
                world[j].set(1, 3, world[j].get(1, 3) + drop)
        for side in range(2):
            var hip = HIP_L if side == 0 else HIP_R
            var knee = KNEE_L if side == 0 else KNEE_R
            var ankle = ANKLE_L if side == 0 else ANKLE_R
            var clip_ankle = a_l if side == 0 else a_r
            var g = g_l if side == 0 else g_r
            var plant = foot_plant(clip_ankle, clip_ankle[1], g, slope.normal_model(), MAX_LIFT, MAX_TILT)
            var target = plant.ankle
            var ph = _pos(world[hip])
            var pk = _pos(world[knee])
            var pa = _pos(world[ankle])
            var pole = pk + (pk - (ph + pa) * Real(0.5))
            var tb = two_bone(ph, pk, pa, target, pole)
            var r1 = _turn(pk - ph, tb.mid - ph, ph)
            for j in range(c.joint_count):
                if _in_subtree(c.parents, j, hip):
                    world[j] = r1.copy() * world[j].copy()
            var pa1 = _pos(world[ankle])
            var r2 = _turn(pa1 - tb.mid, tb.end - tb.mid, tb.mid)
            for j in range(c.joint_count):
                if _in_subtree(c.parents, j, knee):
                    world[j] = r2.copy() * world[j].copy()
            if plant.planted and plant.foot_angle > 1e-6:
                var r3 = _rot_about(normalize(plant.foot_axis), plant.foot_angle, _pos(world[ankle]))
                for j in range(c.joint_count):
                    if _in_subtree(c.parents, j, ankle):
                        world[j] = r3.copy() * world[j].copy()
    var e = List[Real]()
    for side in range(2):
        var ankle = ANKLE_L if side == 0 else ANKLE_R
        var clip_ankle = a_l if side == 0 else a_r
        var p = _pos(world[ankle])
        e.append((p[1] - slope.height(p[0], p[2])) - clip_ankle[1])
    var ibm = palette_to_mats(c.ibm)
    var out = List[Float32]()
    for j in range(c.joint_count):
        var m = world[j].copy() * ibm[j].copy()
        for col in range(4):
            for row in range(4):
                out.append(Float32(Float64(m.get(row, col))))
    return FootIK(out^, e[0], e[1], raw_l, raw_r, drop)
