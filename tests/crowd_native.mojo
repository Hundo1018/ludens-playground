# Step 7 (docs/PLAN.md) and W4: the crowd as ecs entities, moved by the engine's flow fields round four corners. Checks:
# members loop (every member arrives at corners, none gathers at the centre, all stay on the floor); the sparse-set and
# naive backends agree exactly; a switch in the middle of a run does not change the result.
from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real
from app.crowd import CrowdState, CrowdRow


def mean_distance(rows: List[CrowdRow]) -> Real:
    var s = Real(0)
    for r in rows:
        s += sqrt(r.x * r.x + r.z * r.z)
    return s / Real(len(rows))


def by_offset(rows: List[CrowdRow]) -> List[CrowdRow]:
    """Sorted by offset (offsets are unique), so two backends' rows compare index by index."""
    var out = rows.copy()
    for i in range(len(out)):
        for j in range(i + 1, len(out)):
            if out[j].offset < out[i].offset:
                var t = out[i]
                out[i] = out[j]
                out[j] = t
    return out^


def same(a: List[CrowdRow], b: List[CrowdRow]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i].offset != b[i].offset or a[i].x != b[i].x or a[i].z != b[i].z:
            return False
    return True


def main() raises:
    var s = Suite("crowd_native")
    var dt = Real(1.0 / 60.0)

    var sparse = CrowdState(64)
    for _ in range(2400):
        sparse.step(dt)
    var d1 = mean_distance(sparse.positions())
    s.check(sparse.arrivals >= 64, "every member reaches a corner in 40 s: " + String(sparse.arrivals) + " arrivals")
    s.check(d1 > Real(5.0), "members loop, they do not gather at the centre: mean distance " + String(d1) + " m after 40 s")
    var inside = True
    for r in sparse.positions():
        if abs(r.x) > Real(20.0) or abs(r.z) > Real(20.0):
            inside = False
    s.check(inside, "every member stays on the floor (inside 20 m on each axis)")
    s.check(len(sparse.positions()) == 64, "all 64 members are entities after the walk")

    # Parity: the naive backend, from the same start, ends in the same state.
    var naive = CrowdState(64)
    naive.switch()
    for _ in range(2400):
        naive.step(dt)
    s.check(same(by_offset(sparse.positions()), by_offset(naive.positions())), "sparse-set and naive backends agree exactly after 2400 ticks")

    # A switch mid-run: 150 ticks on one backend, switch, 150 more; the same as 300 ticks on one backend.
    var mixed = CrowdState(64)
    for _ in range(1200):
        mixed.step(dt)
    mixed.switch()
    for _ in range(1200):
        mixed.step(dt)
    s.check(same(by_offset(sparse.positions()), by_offset(mixed.positions())), "a backend switch at tick 1200 leaves the crowd where it was")
    s.check(mixed.backend_name() == "naive", "the switch made naive the live backend")
    s.finish()
