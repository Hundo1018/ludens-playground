# Reference baseline E1 (motion matching): the town's characters pick their clip by motion matching on their speed
# (app/town_motion.mojo). Checks on build/assets/converted/CesiumMan.lcharacter:
# - each clip's own speed (the hip's ground travel over the clip, per second), printed;
# - a probe at the resident speed (1.4 m/s) matches a walk; at the guard speed (7 m/s) it matches the run (kind 107);
# - sweeping the speed from 0.5 to 7 m/s, the matched clip changes at least once; every speed up to the fastest walk's own
#   speed matches a walk, and the run is first picked above it;
# - stepping 26 agents (25 at 1.4 m/s along +x, one at 7 m/s) for 120 ticks: the fast one is on the run, at least 20 of
#   the slow ones on walks; switches are counted (printed, with the queries made).
from std.math import sqrt, atan2, sin, cos
from harness.runner import Suite
from frontier_assets import parse_character
from app.town_motion import TownMotion, RUN_KIND
from geometry.vec import Real, Vec2

comptime PI = 3.141592653589793


def read_file(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def main() raises:
    var s = Suite("town_motion_native")
    var c = parse_character(read_file("build/assets/converted/CesiumMan.lcharacter"), 101)
    var tm = TownMotion(c, 26)
    var run_speed = Real(0)
    var fastest_walk = Real(0)
    for i in range(len(tm.m.mm.tracks)):
        ref t = tm.m.mm.tracks[i]
        var n = t.frames
        var dx = t.hip[3 * (n - 1)] - t.hip[0]
        var dz = t.hip[3 * (n - 1) + 2] - t.hip[2]
        var v = sqrt(dx * dx + dz * dz) / (Real(n - 1) / tm.fps)
        print("clip kind", 101 + tm.kinds[i], ":", n, "frames, hip speed", v, "m/s")
        if tm.kinds[i] == RUN_KIND:
            run_speed = v
        elif v > fastest_walk:
            fastest_walk = v
    var walk_hit = tm.m.mm.db.clip_of[tm.match(1.4, 0)]
    var run_hit = tm.m.mm.db.clip_of[tm.match(7.0, 0)]
    print("probe at 1.4 m/s matches kind", 101 + tm.kinds[walk_hit], "; at 7 m/s kind", 101 + tm.kinds[run_hit])
    s.check(tm.kinds[walk_hit] != RUN_KIND, "a probe at 1.4 m/s matches a walk (kind " + String(101 + tm.kinds[walk_hit]) + ")")
    s.check(tm.kinds[run_hit] == RUN_KIND, "a probe at 7 m/s matches the run (kind " + String(101 + tm.kinds[run_hit]) + ")")
    var changes = 0
    var last = -1
    var first_run = Real(-1)
    var walk_below = True
    var line = String("sweep:")
    for k in range(14):
        var v = Real(0.5) * Real(k + 1)
        var kind = tm.kinds[tm.m.mm.db.clip_of[tm.match(v, 0)]]
        line += " " + String(v) + "->" + String(101 + kind)
        if last >= 0 and kind != last:
            changes += 1
        if kind == RUN_KIND and first_run < 0:
            first_run = v
        if v <= fastest_walk and kind == RUN_KIND:
            walk_below = False
        last = kind
    print(line)
    s.check(changes >= 1, "the matched clip changes over 0.5..7 m/s (" + String(changes) + " changes)")
    s.check(walk_below and first_run > fastest_walk,
            "speeds up to the fastest walk (" + String(fastest_walk) + " m/s) match walks; the run (its clip "
            + String(run_speed) + " m/s) is first picked at " + String(first_run) + " m/s")
    # agents: 25 slow along +x, the last fast along +x
    var vel = List[Vec2]()
    for a in range(26):
        vel.append(Vec2(Real(7.0) if a == 25 else Real(1.4), Real(0.0)))
    for _ in range(120):
        tm.step(Real(1.0 / 60.0), vel)
    var walks = 0
    for a in range(25):
        if tm.kind(a) != RUN_KIND:
            walks += 1
    print("after 120 ticks: fast agent kind", 101 + tm.kind(25), "; slow agents on walks", walks, "of 25; switches", tm.switches,
          "of", 26 * 12, "queries")
    s.check(tm.kind(25) == RUN_KIND, "the 7 m/s agent is on the run after 120 ticks")
    s.check(walks >= 20, "at least 20 of the 25 agents at 1.4 m/s are on walks (" + String(walks) + ")")
    s.check(tm.switches > 0, "agents switch clips (" + String(tm.switches) + " switches)")
    s.finish()
