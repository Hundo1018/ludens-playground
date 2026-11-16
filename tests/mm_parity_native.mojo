# Audit B9 / A5 parity: motion matching moved to ludens-core (procedural.motion_match) must decide exactly what the
# playground's own code decided. 26 agents step 600 ticks (10 s) with speeds that differ per agent and change over time
# (standing, walking, running, turning); every tick's (kind, frame, yaw) of every agent and the switch count are hashed.
# The expected values were measured with the playground's app/motion_match.mojo and app/town_motion.mojo before the move.
from std.math import sin, cos
from harness.runner import Suite
from app.assets import parse_character
from app.town_motion import TownMotion
from app.motion_match import build_match, m6_hash
from geometry.vec import Real, Vec2

comptime WANT_STATE_HASH = 677951162
comptime WANT_SWITCHES = 757
comptime WANT_M6 = 992661


def read_file(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def main() raises:
    var s = Suite("mm_parity_native")
    var c = parse_character(read_file("build/assets/converted/CesiumMan.lcharacter"), 101)
    var tm = TownMotion(c, 26)
    var h = 0
    for tick in range(600):
        var vel = List[Vec2]()
        for a in range(26):
            var t = Real(tick) / Real(60.0)
            var speed = Real(0.0) if (a % 7 == 0 and tick < 120) else Real(0.8) + Real(0.25) * Real(a % 9) + Real(1.5) * sin(Real(0.4) * t + Real(a))
            if speed < Real(0):
                speed = -speed
            var dir = Real(0.3) * Real(a) + Real(0.2) * t
            vel.append(Vec2(speed * sin(dir), speed * cos(dir)))
        tm.step(Real(1.0 / 60.0), vel)
        for a in range(26):
            h = (h * 31 + tm.kind(a)) % 1000000007
            h = (h * 31 + tm.frame_index(a)) % 1000000007
            h = (h * 31 + Int(tm.yaw(a) * Real(1e5))) % 1000000007
    var m6 = m6_hash(build_match(c, c.motion))
    print("state hash", h, "switches", tm.switches, "M6", m6)
    s.check(h == WANT_STATE_HASH, "per-tick (kind, frame, yaw) of 26 agents over 600 ticks: hash " + String(h) + " == " + String(WANT_STATE_HASH))
    s.check(tm.switches == WANT_SWITCHES, "switches " + String(tm.switches) + " == " + String(WANT_SWITCHES))
    s.check(m6 == WANT_M6, "M6 hash " + String(m6) + " == " + String(WANT_M6))
    s.finish()
