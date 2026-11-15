# W7 (plan card 2a): the quarry's fractured wall. Scenario A (a weight dropped on a wall that stands on the ground) makes no
# fracture event: a wall that rests does not break. Scenario B (the wall falls 6 m onto the ground) breaks it. The page releases
# the wall as B.
from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from embed.world import EmbedWorld
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3


def run(mut w: EmbedWorld, ticks: Int) raises -> Int:
    var events = 0
    for _ in range(ticks):
        w.physics_tick()
        events += len(w.frame_fracture)
    return events


def main() raises:
    var s = Suite("quarry_native")
    # A: the wall on the ground, a 400 kg weight dropped from 12 m onto its top (the page's scenario)
    var a = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    _ = a.add_box(Vec3(0.0, -0.5, 0.0, 0.0), Vec3(50.0, 0.5, 50.0, 0.0), 0.0, True)
    _ = a.add_fracture_box(Vec3(0.0, 2.0, 0.0, 0.0), Vec3(4.0, 2.0, 0.3, 0.0), 40, 7, 5e1, 2000.0)
    _ = a.add_box(Vec3(0.0, 12.0, 0.0, 0.0), Vec3(0.6, 0.6, 0.6, 0.0), 400.0, False)
    var ev_a = run(a, 300)
    print("A (weight dropped on the wall): events", ev_a, "alive", a.fracture.alive_count(), "free", a.fracture.free_count())
    # B: the fractured wall itself falls from 6 m onto the ground (ludens-core's recipe: a falling fractured box)
    var b = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    _ = b.add_box(Vec3(0.0, -0.5, 0.0, 0.0), Vec3(50.0, 0.5, 50.0, 0.0), 0.0, True)
    _ = b.add_fracture_box(Vec3(0.0, 6.0, 0.0, 0.0), Vec3(4.0, 2.0, 0.3, 0.0), 40, 7, 5e1, 2000.0)
    var ev_b = run(b, 300)
    print("B (fractured wall falls 6 m): events", ev_b, "alive", b.fracture.alive_count(), "free", b.fracture.free_count())
    s.check(ev_a == 0, "A: a resting wall with a weight on it makes no fracture event (" + String(ev_a) + ")")
    s.check(ev_b > 0, "B: a wall falling 6 m onto the ground breaks (" + String(ev_b) + " events)")
    s.finish()
