# Reference baseline B1 (original stage 2: a destructible wall and a jointed machine): a pendulum on a hinge swings into the
# quarry's fractured wall, which stands on the ground. Scenario A, the wall alone, makes no fracture event. Scenario B, a
# bob of mass M released level with the pivot, 9 m from it, hits the wall at the bottom of its swing. Measured: a 500 kg bob
# does not break it (0 events); a 2000 kg bob, a wrecking ball, does (22 events, counted per tick). The page uses 2000 kg.
from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from embed.world import EmbedWorld


def wall_world() raises -> EmbedWorld:
    var w = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    _ = w.add_box(Vec3(0.0, -0.5, 0.0, 0.0), Vec3(50.0, 0.5, 50.0, 0.0), 0.0, True)
    _ = w.add_fracture_box(Vec3(0.0, 2.0, 0.0, 0.0), Vec3(4.0, 2.0, 0.3, 0.0), 40, 7, 5e1, 2000.0)
    return w^


def run(mut w: EmbedWorld, ticks: Int) raises -> Int:
    var events = 0
    for _ in range(ticks):
        var before = len(w.frame_fracture)  # the list grows tick by tick; only ticks_due clears it
        w.physics_tick()
        events += len(w.frame_fracture) - before
    return events


def pendulum_events(mass: Real) raises -> Int:
    var w = wall_world()
    var anchor = w.add_box(Vec3(0.0, 12.0, 0.0, 0.0), Vec3(0.4, 0.4, 0.4, 0.0), 0.0, True)
    var bob = w.add_sphere(Vec3(0.0, 12.0, 9.0, 0.0), 1.0, mass, False)
    _ = w.add_hinge_joint(anchor, bob, Vec3(0.0, 0.0, 0.0, 0.0), Vec3(0.0, 0.0, -9.0, 0.0), Vec3(1.0, 0.0, 0.0, 0.0))
    return run(w, 300)


def main() raises:
    var s = Suite("pendulum_native")
    var a = wall_world()
    var ev_a = run(a, 300)
    print("A (the wall alone): events", ev_a)
    s.check(ev_a == 0, "A: the wall standing alone makes no fracture event (" + String(ev_a) + ")")
    for m in [Real(500.0), Real(2000.0)]:
        var ev = pendulum_events(m)
        print("B (pendulum, bob", m, "kg): events", ev)
    var ev_b = pendulum_events(2000.0)
    s.check(ev_b > 0, "B: a 2000 kg bob on a 9 m hinge breaks the wall (" + String(ev_b) + " events)")
    s.finish()
