# Plan stage 3 (card 3, docs/frontier_plan.md): the town's ORCA crowd. Checks: at least 12 of 24 residents reach a corner
# within 1200 ticks; minimum pairwise separation stays above -0.05 m; the guard closes on a still player within 60 ticks.
from harness.runner import Suite
from geometry.vec import Real, Vec3
from app.town import Town, RESIDENTS


def main() raises:
    var s = Suite("town_native")
    var dt = Real(1.0 / 60.0)
    var player = Vec3(0.0, 0.0, 0.0, 0.0)

    var t = Town()
    var reached = List[Bool]()
    for _ in range(RESIDENTS):
        reached.append(False)
    var worst = Real(1e30)
    var guard0 = t.guard_distance(player)
    var guard60 = guard0
    for tick in range(1200):
        t.step(dt, player)
        for k in range(RESIDENTS):
            if t.crowd.arrived[k]:
                reached[k] = True
        if tick % 10 == 0:
            var sep = t.crowd.min_separation()
            if sep < worst:
                worst = sep
        if tick == 59:
            guard60 = t.guard_distance(player)

    var n = 0
    for k in range(RESIDENTS):
        if reached[k]:
            n += 1
    s.check(n >= 12, "at least 12 of 24 residents reach a corner within 1200 ticks: " + String(n) + " did")
    s.check(worst > Real(-0.05), "minimum pairwise separation stays above -0.05 m over the run: " + String(worst) + " m")
    s.check(guard60 < guard0, "the guard closes on the still player within 60 ticks: " + String(guard0) + " m -> " + String(guard60) + " m")
    s.finish()
