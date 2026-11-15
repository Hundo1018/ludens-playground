"""Step 8 (docs/PLAN.md): the range netcode session across one-way latencies from 0 to 150 ms (0 to 9 ticks at 60 Hz),
with 10 % loss and jitter 3 ticks, three seeds per latency, natively.

Prints one row per latency: how many seeds converged (every client reaches the target tick), how many matched the
reference hash, and the mean frames the run took. This measures convergence and state equality under latency. It does
not measure a prediction error: the plan's prediction-error bound is still unchecked.
"""
from geometry.vec import Real
from app.net_frontier import run_session


def main() raises:
    var T = 120
    var seeds: List[UInt64] = [UInt64(1), UInt64(2), UInt64(3)]
    print("| one-way latency | ms | converged | equal to reference | mean frames |")
    print("|---:|---:|---:|---:|---:|")
    for lat in range(10):
        var conv = 0
        var eq = 0
        var frames = 0
        for seed in seeds:
            var r = run_session(lat, 3, Real(0.1), seed, T)
            if r[0]:
                conv += 1
            if r[1]:
                eq += 1
            frames += r[3]
        print("|", lat, "|", lat * 1000 // 60, "|", conv, "/ 3 |", eq, "/ 3 |", frames // 3, "|")
