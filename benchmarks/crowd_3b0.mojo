"""Step 7, probe 3b-0 (docs/PLAN.md): the crowd step on each ECS backend against an object (OOP) list, at N = 1e4, 5e4
and 1e5, natively. Prints the median ms per step over the samples, and the entity count each run used.

Workloads, stated so the comparison is fair:
- ECS: `app.crowd.CrowdState`, the live crowd step (flow field + query + move) on the sparse-set backend and on the naive
  backend. The same population is in both worlds.
- OOP: a `List[Member]` of structs, integrated toward the centre with the same step length. It does NOT run the flow
  field, so the OOP number is a floor for the object layout, not the same workload. Read the two as separate lines.

Run (after `pixi run build`): see the command in scripts/test_frontier_native.sh; this file builds with the same flags.
"""
from std.time import perf_counter_ns
from app.crowd import CrowdState
from geometry.vec import Real


struct Member(Copyable, Movable):
    var x: Real
    var z: Real
    var vx: Real
    var vz: Real

    def __init__(out self, x: Real, z: Real):
        self.x = x
        self.z = z
        self.vx = Real(0)
        self.vz = Real(0)


def oop_step(mut ms: List[Member], dt: Real):
    """Integrate every member straight toward the centre at a fixed speed (the same step length as the crowd)."""
    var speed = Real(1.4)
    for i in range(len(ms)):
        var d = (ms[i].x * ms[i].x + ms[i].z * ms[i].z) ** Real(0.5)
        if d > Real(0.001):
            ms[i].vx = -ms[i].x / d * speed
            ms[i].vz = -ms[i].z / d * speed
        ms[i].x += ms[i].vx * dt
        ms[i].z += ms[i].vz * dt


def median(mut xs: List[Float64]) -> Float64:
    for i in range(1, len(xs)):
        var v = xs[i]
        var j = i
        while j > 0 and xs[j - 1] > v:
            xs[j] = xs[j - 1]
            j -= 1
        xs[j] = v
    return xs[len(xs) // 2]


def main() raises:
    var counts: List[Int] = [10000, 50000, 100000]
    var samples = 30
    var dt = Real(1.0 / 60.0)
    print("| backend | N | median ms/step | p90 ms/step | samples |")
    print("|---|---:|---:|---:|---:|")
    for n in counts:
        # ECS: both backends are populated by CrowdState; time the live one, then switch and time the other.
        var crowd = CrowdState(n)
        for _ in range(5):
            crowd.step(dt)
        for variant in range(2):
            if variant == 1:
                crowd.switch()
            var ms = List[Float64]()
            for _ in range(samples):
                var t0 = perf_counter_ns()
                crowd.step(dt)
                ms.append(Float64(perf_counter_ns() - t0) / 1.0e6)
            var med = median(ms)  # sorts ms in place
            var p90 = ms[Int(Float64(len(ms)) * 0.9)]
            print("| ", crowd.backend_name(), " | ", n, " | ", med, " | ", p90, " | ", samples, " |")
        # OOP: an object list of the same size.
        var members = List[Member]()
        for i in range(n):
            members.append(Member(Real(i % 200) - Real(100), Real(i // 200) - Real(250)))
        for _ in range(5):
            oop_step(members, dt)
        var ms2 = List[Float64]()
        for _ in range(samples):
            var t0 = perf_counter_ns()
            oop_step(members, dt)
            ms2.append(Float64(perf_counter_ns() - t0) / 1.0e6)
        var med2 = median(ms2)
        print("| oop list (no flow field) | ", n, " | ", med2, " | - | ", samples, " |")
