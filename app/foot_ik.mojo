"""Reference baseline E2 (original stage 4, foot IK): CesiumMan's feet placed on a slope with ludens-core's
procedural.ik.two_bone.

The clip is authored on a flat floor (y = 0 in model space). On ground of height g(x, z) relative to the character's
base, each ankle's target comes from ludens-core's foot_plant with the clip frame's own ankle height as the height above
the ground: the ankle is raised by g under that foot, so the clip's lift (swing, heel roll) is kept on top of the slope,
and foot_plant's tilt (at most MAX_TILT) turns the foot toward the slope's normal. The pelvis is lowered by the lower foot's offset when that is negative (the whole body moves
down), so the downhill leg can reach. two_bone gives the new knee and ankle positions with the knee bending toward where
it already points; they become two rotations of the model-space joint matrices: the thigh's subtree about the hip (the
knee onto its new position), then the shin's subtree about the new knee (the ankle onto its target). Both steps are
ludens-core's procedural.ik_pose.two_bone_pose on the joints' model-space Pose (CesiumMan's joint matrices are rigid, so a
position and a unit quaternion hold each one); the palette is rebuilt from that pose.

Joints (CesiumMan): hip 11 / 12, knee 13 / 14, ankle 15 / 16, toe 17 / 18 (left / right); 0 is the pelvis.
The error of a foot is its ankle's height above the ground under it minus the clip's ankle height above the flat floor:
0 when the foot sits on the slope exactly as the clip set it on the floor. Without IK it is -g.
"""
from std.math import sin, cos, tan
from geometry.mat import Mat4
from geometry.vec import Real, Vec3, normalize
from geometry.quat import Quat, quat_from_mat3
from geometry.mat import Mat3
from procedural.anim_graph import Pose
from procedural.ik_pose import two_bone_pose, rotate_subtree
from procedural.ik import foot_plant
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





def _to_pose(world: List[Mat4]) -> Pose:
    """Rigid joint matrices as a Pose (position, unit quaternion)."""
    var out = Pose(len(world))
    for j in range(len(world)):
        var r = Mat3()
        for a in range(3):
            for b in range(3):
                r.set(a, b, world[j].get(a, b))
        out.set(j, _pos(world[j]), quat_from_mat3(r).normalized())
    return out^


def _to_mats(pose: Pose) -> List[Mat4]:
    var out = List[Mat4]()
    for j in range(pose.bones):
        var m = pose.q(j).to_mat4()
        var p = pose.p(j)
        m.set(0, 3, p[0])
        m.set(1, 3, p[1])
        m.set(2, 3, p[2])
        out.append(m^)
    return out^


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
        var pose = _to_pose(world)
        for side in range(2):
            var hip = HIP_L if side == 0 else HIP_R
            var knee = KNEE_L if side == 0 else KNEE_R
            var ankle = ANKLE_L if side == 0 else ANKLE_R
            var clip_ankle = a_l if side == 0 else a_r
            var g = g_l if side == 0 else g_r
            var plant = foot_plant(clip_ankle, clip_ankle[1], g, slope.normal_model(), MAX_LIFT, MAX_TILT)
            var target = plant.ankle
            var ph = pose.p(hip)
            var pk = pose.p(knee)
            var pa = pose.p(ankle)
            var pole = pk + (pk - (ph + pa) * Real(0.5))
            _ = two_bone_pose(pose, c.parents, hip, knee, ankle, target, pole)
            if plant.planted and plant.foot_angle > 1e-6:
                rotate_subtree(pose, c.parents, ankle, pose.p(ankle), Quat.from_axis_angle(normalize(plant.foot_axis), plant.foot_angle))
        world = _to_mats(pose)
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
