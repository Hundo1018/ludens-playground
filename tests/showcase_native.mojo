"""The showcase scene (showcase/scene.mojo) with no GPU: bodies drop and are capped, impacts start spark bursts, every
emitter has live particles, and two runs from the same seed give the same hash. Prints the hash after 600 frames, which
`app/showcase_host.mojo` (`showcase_hash`) gives on wasm64 for the same seed.

    bash scripts/test_native.sh tests/showcase_native.mojo"""
from showcase.scene import Showcase, MAX_DYNAMIC, SPARK_EMITTERS
from std.time import perf_counter_ns

comptime FRAME = 1.0 / 60.0


def run(frames: Int, seed: UInt64) raises -> Showcase:
    var s = Showcase(seed)
    for _ in range(frames):
        s.step(FRAME, 0.0, 0.0)
    return s^


def main() raises:
    var failed = 0

    def need(cond: Bool, what: String) capturing:
        print("  [" + ("PASS" if cond else "FAIL") + "]", what)
        if not cond:
            failed += 1

    var t0 = perf_counter_ns()
    var a = run(600, 7)
    var ms = Float64(perf_counter_ns() - t0) / 1e6
    print("600 frames (10 s) in", ms, "ms native,", ms / 600.0, "ms per frame")
    need(a.drops >= 25, "bodies are dropped (" + String(a.drops) + " in 10 s)")
    need(len(a.dynamic) <= MAX_DYNAMIC, "at most MAX_DYNAMIC dynamic bodies (" + String(len(a.dynamic)) + ")")
    need(a.bursts > 0, "impacts start spark bursts (" + String(a.bursts) + ")")
    var spark_live = 0
    for k in range(SPARK_EMITTERS):
        spark_live += a.particles.emitters[a.spark_first + k].live()
    print("  live particles:", a.live_particles(), "of which sparks", spark_live, "; smoke", a.particles.emitters[0].live(),
          "embers", a.particles.emitters[1].live(), "dust", a.particles.emitters[2].live())
    need(a.particles.emitters[0].live() > 0 and a.particles.emitters[1].live() > 0 and a.particles.emitters[2].live() > 0,
         "smoke, embers and dust are alive")
    var b = run(600, 7)
    need(a.hash() == b.hash(), "same seed, same hash (" + String(a.hash()) + ")")
    var c = run(600, 8)
    need(a.hash() != c.hash(), "another seed, another hash")
    var long = run(1800, 7)
    need(len(long.dynamic) == MAX_DYNAMIC and long.removed > 0, "after 30 s the oldest bodies leave (" + String(long.removed) + " removed)")
    print("showcase hash 600 frames seed 7:", a.hash())
    if failed > 0:
        raise Error(String(failed) + " check(s) failed")
    print("showcase_native: all checks passed")
