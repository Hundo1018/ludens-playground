# Audit A5: the town's characters blend across motion-matching switches and loop wraps (app/town_blend.mojo).
# One TownMotion run (26 agents, 600 ticks, the speeds of tests/mm_parity_native.mojo) feeds two TownBlends, off and on;
# the switch decisions are the matcher's and do not depend on the blend. Per agent and tick, the step is the largest
# distance any joint moves since the previous tick, in the drawn frame: model space, the drawn yaw applied, the walk's
# translation (the ORCA position) left out. Ticks are sorted into switch ticks, wrap ticks (the clip looped) and the rest.
# Checks: with the blend off the palette is pose_palette_clip's bit for bit; with it on, the largest switch step and the
# largest wrap step are at most twice the 95th percentile of the ordinary steps (ludens-engine#82's acceptance), and the
# switch decisions (state hash, switches) are unchanged.
from std.math import sin, cos
from geometry.mat import Mat4
from geometry.vec import Real, Vec2, Vec3
from harness.runner import Suite
from frontier_assets import parse_character, pose_palette_clip, strip_root_xz, Character
from app.skin_pass import palette_to_mats
from app.town_motion import TownMotion
from app.town_blend import TownBlend, local_mats


def read_file(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def joints_drawn(tb: TownBlend, a: Int, tm: TownMotion, c: Character) raises -> List[Vec3]:
    var locals = local_mats(tb.local_pose(a, tm, c), c.joint_count)
    var root = palette_to_mats(c.root)[0].copy()
    strip_root_xz(locals, root)
    var world = List[Mat4]()
    for j in range(c.joint_count):
        var p = c.parents[j]
        if p < 0:
            world.append(root.copy() * locals[j].copy())
        else:
            world.append(world[p].copy() * locals[j].copy())
    var y = tb.drawn_yaw(a, tm)
    var cy = cos(y)
    var sy = sin(y)
    var out = List[Vec3]()
    for j in range(c.joint_count):
        var x = world[j].get(0, 3)
        var z = world[j].get(2, 3)
        out.append(Vec3(cy * x + sy * z, world[j].get(1, 3), -sy * x + cy * z, 0.0))
    return out^


def max_step(a: List[Vec3], b: List[Vec3]) -> Real:
    var m = Real(0)
    for j in range(len(a)):
        var d = a[j] - b[j]
        m = max(m, (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]) ** 0.5)
    return m


def p95(var xs: List[Real]) -> Real:
    sort(xs)
    return xs[Int(Real(0.95) * Real(len(xs) - 1))]


def main() raises:
    var s = Suite("town_blend_native")
    var c = parse_character(read_file("build/assets/converted/CesiumMan.lcharacter"), 101)
    var tm = TownMotion(c, 26)
    var off = TownBlend(c.joint_count, 26, False)
    var on = TownBlend(c.joint_count, 26, True)
    var prev_off = List[List[Vec3]]()
    var prev_on = List[List[Vec3]]()
    var last_clip = List[Int](length=26, fill=-1)
    var last_frame = List[Int](length=26, fill=-1)
    var ordinary = List[Real]()
    var sw_off = Real(0)
    var sw_on = Real(0)
    var wr_off = Real(0)
    var wr_on = Real(0)
    var n_sw = 0
    var n_wr = 0
    var h = 0
    var same_palette = True
    var dt = Real(1.0 / 60.0)
    for tick in range(600):
        var vel = List[Vec2]()
        for a in range(26):
            var t = Real(tick) / Real(60.0)
            var speed = Real(0.0) if (a % 7 == 0 and tick < 120) else Real(0.8) + Real(0.25) * Real(a % 9) + Real(1.5) * sin(Real(0.4) * t + Real(a))
            if speed < Real(0):
                speed = -speed
            var dir = Real(0.3) * Real(a) + Real(0.2) * t
            vel.append(Vec2(speed * sin(dir), speed * cos(dir)))
        tm.step(dt, vel)
        off.update(tm, c, dt)
        on.update(tm, c, dt)
        var switched = List[Bool](length=26, fill=False)
        for e in tm.last:
            switched[e.agent] = True
        for a in range(26):
            h = (h * 31 + tm.kind(a)) % 1000000007
            h = (h * 31 + tm.frame_index(a)) % 1000000007
            h = (h * 31 + Int(tm.yaw(a) * Real(1e5))) % 1000000007
            var jo = joints_drawn(off, a, tm, c)
            var jn = joints_drawn(on, a, tm, c)
            var wrapped = not switched[a] and tm.m.clip[a] == last_clip[a] and tm.frame_index(a) < last_frame[a]
            if tick > 0:
                var so = max_step(jo, prev_off[a])
                var sn = max_step(jn, prev_on[a])
                if switched[a]:
                    n_sw += 1
                    sw_off = max(sw_off, so)
                    sw_on = max(sw_on, sn)
                elif wrapped:
                    n_wr += 1
                    wr_off = max(wr_off, so)
                    wr_on = max(wr_on, sn)
                else:
                    ordinary.append(so)
            last_clip[a] = tm.m.clip[a]
            last_frame[a] = tm.frame_index(a)
            if tick == 0:
                prev_off.append(jo^)
                prev_on.append(jn^)
            else:
                prev_off[a] = jo^
                prev_on[a] = jn^
            if tick % 97 == 0:
                var want = pose_palette_clip(c, c.motion[tm.kind(a)], tm.frame_index(a))
                var got = off.palette(a, tm, c)
                for k in range(len(want)):
                    if want[k] != got[k]:
                        same_palette = False
    var o95 = p95(ordinary.copy())
    var omax = Real(0)
    for x in ordinary:
        omax = max(omax, x)
    print("ordinary ticks", len(ordinary), ": p95 step", o95 * 1000, "mm, max", omax * 1000, "mm")
    print("switch ticks", n_sw, ": max step without blend", sw_off * 1000, "mm, with", sw_on * 1000, "mm")
    print("wrap ticks", n_wr, ": max step without blend", wr_off * 1000, "mm, with", wr_on * 1000, "mm")
    print("blends started", on.blends, "+", on.wraps, "wraps; state hash", h, "switches", tm.switches)
    s.check(same_palette, "blend off: the palette is pose_palette_clip's, bit for bit")
    s.check(h == 677951162 and tm.switches == 757, "the switch decisions are unchanged (hash " + String(h) + ", " + String(tm.switches) + " switches)")
    s.check(sw_on <= Real(2) * o95, "with the blend, the largest switch step " + String(sw_on * 1000) + " mm <= 2 x the ordinary p95 " + String(o95 * 1000) + " mm")
    s.check(wr_on <= Real(2) * o95, "with the blend, the largest wrap step " + String(wr_on * 1000) + " mm <= 2 x the ordinary p95")
    s.finish()
