"""Audit A5: the town's characters blend across a motion-matching switch instead of jumping to the new clip frame, with
ludens-core's procedural.inertialize.Inertializer (ROADMAP 17.64; it is a standalone struct, so a matcher can drive it).

At a switch (and at a loop wrap, where the CMU clips are not periodic and the pose jumps from the last frame to the first)
the Inertializer records the offset from the pose being shown to the new frame's pose, per joint (translation and
rotation, scale carried unchanged), and adds it back decaying to zero over BLEND_S with a quintic of zero slope at both
ends. The pose being shown is the old clip at this tick's advanced frame plus whatever offset was still active.

The drawn yaw jumps at a switch too: it is the agent's heading minus the clip frame's facing, and the facing changes with
the frame. A one-joint Inertializer carries the yaw in its translation's x and decays its offset the same way.
"""
from std.math import pi
from geometry.mat import Mat4
from geometry.quat import Quat
from geometry.vec import Real
from app.assets import Character, strip_root_xz
from app.skin_pass import build_palette_root, palette_to_mats
from app.town_motion import TownMotion
from procedural.inertialize import Inertializer

comptime BLEND_S = Real(0.25)


struct LocalPose(Copyable, Movable):
    """Per joint: translation (3), rotation x y z w (4), scale (3)."""

    var pos: List[Real]
    var rot: List[Real]
    var scale: List[Real]

    def __init__(out self):
        self.pos = List[Real]()
        self.rot = List[Real]()
        self.scale = List[Real]()


def sample(clip: List[Float32], frame: Int, joints: Int) -> LocalPose:
    """A clip frame (the converter's 10 values per joint: translation, quaternion x y z w, scale) as a LocalPose."""
    var p = LocalPose()
    for j in range(joints):
        var o = (frame * joints + j) * 10
        for k in range(3):
            p.pos.append(Real(Float64(clip[o + k])))
        for k in range(4):
            p.rot.append(Real(Float64(clip[o + 3 + k])))
        for k in range(3):
            p.scale.append(Real(Float64(clip[o + 7 + k])))
    return p^


def local_mats(p: LocalPose, joints: Int) -> List[Mat4]:
    """T * R * S per joint, as app.assets.trs builds it."""
    var out = List[Mat4]()
    for j in range(joints):
        var q = Quat(p.rot[4 * j], p.rot[4 * j + 1], p.rot[4 * j + 2], p.rot[4 * j + 3])
        var m = q.to_mat4()
        for col in range(3):
            for row in range(3):
                m.set(row, col, m.get(row, col) * p.scale[3 * j + col])
        for row in range(3):
            m.set(row, 3, p.pos[3 * j + row])
        out.append(m^)
    return out^


def _wrap(a: Real) -> Real:
    var x = a
    while x > Real(pi):
        x -= Real(2 * pi)
    while x < -Real(pi):
        x += Real(2 * pi)
    return x


struct TownBlend(Movable):
    var joints: Int
    var on: Bool
    var pose: List[Inertializer]  # per agent
    var yaw: List[Inertializer]  # per agent: one joint, the yaw in pos[0]
    var last_clip: List[Int]  # per agent: database clip and frame index drawn after the previous update
    var last_frame: List[Int]
    var wraps: Int
    var blends: Int

    def __init__(out self, joints: Int, agents: Int, on: Bool = True):
        self.joints = joints
        self.on = on
        self.pose = List[Inertializer]()
        self.yaw = List[Inertializer]()
        self.last_clip = List[Int](length=agents, fill=-1)
        self.last_frame = List[Int](length=agents, fill=-1)
        self.wraps = 0
        self.blends = 0
        for _ in range(agents):
            self.pose.append(Inertializer(joints))
            self.yaw.append(Inertializer(1))

    def _shown(self, a: Int, clip: List[Float32], frame: Int) -> LocalPose:
        var p = sample(clip, frame, self.joints)
        self.pose[a].apply(p.pos, p.rot)
        return p^

    def _shown_yaw(self, a: Int, target: Real) -> Real:
        var y = List[Real](length=3, fill=Real(0))
        y[0] = target
        var r = List[Real](length=4, fill=Real(0))
        r[3] = Real(1)
        self.yaw[a].apply(y, r)
        return y[0]

    def _start(mut self, a: Int, src: LocalPose, dst: LocalPose, src_yaw: Real, dst_yaw: Real):
        self.pose[a].start(src.pos, src.rot, dst.pos, dst.rot, BLEND_S)
        var sy = List[Real](length=3, fill=Real(0))
        sy[0] = dst_yaw + _wrap(src_yaw - dst_yaw)
        var dy = List[Real](length=3, fill=Real(0))
        dy[0] = dst_yaw
        var q = List[Real](length=4, fill=Real(0))
        q[3] = Real(1)
        self.yaw[a].start(sy, q, dy, q, BLEND_S)

    def update(mut self, tm: TownMotion, c: Character, dt: Real):
        """After tm.step: decay the running blends by dt, then start one for every switch and every loop wrap."""
        for a in range(tm.agents()):
            self.pose[a].advance(dt)
            self.yaw[a].advance(dt)
        var switched = List[Bool](length=tm.agents(), fill=False)
        if self.on:
            for e in tm.last:
                var a = e.agent
                switched[a] = True
                var from_frame = Int(e.from_frame)
                var src = self._shown(a, c.motion[tm.kinds[e.from_clip]], from_frame)
                var src_yaw = self._shown_yaw(a, tm.m.heading[a] - tm.m.mm.tracks[e.from_clip].facing_yaw(from_frame))
                var dst = sample(c.motion[tm.kinds[e.to_clip]], e.to_frame, self.joints)
                self._start(a, src, dst, src_yaw, tm.yaw(a))
                self.blends += 1
        for a in range(tm.agents()):
            var clip = tm.m.clip[a]
            var f = tm.frame_index(a)
            if self.on and not switched[a] and clip == self.last_clip[a] and f < self.last_frame[a]:
                ref data = c.motion[tm.kinds[clip]]
                var lf = self.last_frame[a]
                var src = self._shown(a, data, lf)
                var src_yaw = self._shown_yaw(a, tm.m.heading[a] - tm.m.mm.tracks[clip].facing_yaw(lf))
                self._start(a, src, sample(data, f, self.joints), src_yaw, tm.yaw(a))
                self.wraps += 1
            self.last_clip[a] = clip
            self.last_frame[a] = f

    def local_pose(self, a: Int, tm: TownMotion, c: Character) -> LocalPose:
        """Agent a's pose as drawn: its clip frame with the blend's offset."""
        return self._shown(a, c.motion[tm.kind(a)], tm.frame_index(a))

    def drawn_yaw(self, a: Int, tm: TownMotion) -> Real:
        return self._shown_yaw(a, tm.yaw(a))

    def palette(self, a: Int, tm: TownMotion, c: Character) raises -> List[Float32]:
        """Agent a's skinning palette (the clip played in place, as pose_palette_clip does)."""
        var locals = local_mats(self.local_pose(a, tm, c), self.joints)
        var ibm = palette_to_mats(c.ibm)
        var root = palette_to_mats(c.root)[0].copy()
        strip_root_xz(locals, root)
        return build_palette_root(locals, c.parents, ibm, root)
