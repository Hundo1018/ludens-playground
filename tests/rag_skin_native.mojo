# V5 (and reference baseline B4): CesiumMan skinned to the knocked-down figure's six bodies (app/rag_skin.mojo). The figure
# is added in a Frontier and stepped 120 ticks (2 s). Checks, on the joint world positions the palette implies (world_j =
# D_body * place * model_j): standing, the pelvis joint is within 0.25 m of the pelvis body and the neck joint within
# 0.35 m of the head body; after the fall the same distances hold (the mesh follows its bodies); no joint is below the
# ground (y > -0.05 m); the pelvis joint is below 0.5 m (the guard lies down).
from harness.runner import Suite
from geometry.mat import Mat4
from geometry.vec import Real, Vec3
from frontier.world import Frontier
from app.assets import parse_character
from app.rag_skin import pose_mat, placement, rigid_inverse, joint_body
from app.foot_ik import _model_mats


def read_file(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def joint_positions(c_model: List[Mat4], place: Mat4, rest: List[Mat4], now: List[Mat4]) -> List[Vec3]:
    var out = List[Vec3]()
    for j in range(len(c_model)):
        var b = joint_body(j)
        var m = now[b].copy() * rigid_inverse(rest[b]) * place.copy() * c_model[j].copy()
        out.append(Vec3(m.get(0, 3), m.get(1, 3), m.get(2, 3), 0.0))
    return out^


def dist(a: Vec3, b: Vec3) -> Real:
    var d = a - b
    return (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]) ** 0.5


def main() raises:
    var s = Suite("rag_skin_native")
    var c = parse_character(read_file("build/assets/converted/CesiumMan.lcharacter"), 101)
    var f = Frontier()
    var at = Vec3(5.0, 0.0, 5.0, 0.0)
    f.knock_down(at, Vec3(1.0, 0.0, 0.0, 0.0))
    var rest = List[Mat4]()
    for i in range(len(f.rag.bodies)):
        rest.append(pose_mat(f.rag.rest_pos[i], f.rag.rest_rot[i]))
    var model = _model_mats(c, c.motion[1], 0)  # the slow walk, frame 0
    var place = placement(at, Real(0.0))
    var p0 = joint_positions(model, place, rest, rest)
    var d_pelvis0 = dist(p0[0], f.rag.rest_pos[0])
    var d_head0 = dist(p0[4], f.rag.rest_pos[2])
    print("standing: pelvis joint to pelvis body", d_pelvis0, "m; neck joint to head body", d_head0, "m")
    for _ in range(120):
        f.world.physics_tick()
    var now = List[Mat4]()
    for i in range(len(f.rag.bodies)):
        var st = f.world.state(f.rag.bodies[i])
        now.append(pose_mat(st.pos, st.rot))
    var p1 = joint_positions(model, place, rest, now)
    var d_pelvis1 = dist(p1[0], f.world.state(f.rag.bodies[0]).pos)
    var d_head1 = dist(p1[4], f.world.state(f.rag.bodies[2]).pos)
    var lowest = Real(1e9)
    for p in p1:
        lowest = min(lowest, p[1])
    print("after 2 s: pelvis joint y", p1[0][1], "m; pelvis joint to body", d_pelvis1, "m; neck joint to head body", d_head1,
          "m; lowest joint y", lowest, "m")
    s.check(d_pelvis0 < Real(0.25) and d_head0 < Real(0.35), "standing, the mesh's pelvis and neck sit on their bodies")
    s.check(d_pelvis1 < Real(0.25) and d_head1 < Real(0.35), "after the fall, the mesh's pelvis and neck still sit on their bodies")
    s.check(lowest > Real(-0.05), "no joint is below the ground (lowest " + String(lowest) + " m)")
    s.check(p1[0][1] < Real(0.5), "the pelvis joint lies below 0.5 m (" + String(p1[0][1]) + " m)")
    s.finish()
