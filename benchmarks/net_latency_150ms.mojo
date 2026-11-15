"""Step 8 (docs/PLAN.md): the range netcode session across one-way latencies from 0 to 150 ms (0 to 9 ticks at 60 Hz),
with 10 % loss and jitter 3 ticks, three seeds per latency, natively.

Table 1: convergence and state equality per latency.
Table 2: display error of a snapshot client. Client 0 shoots at player 1 while showing an older tick (`seen`); the
server is at `now`. The lag is `now - seen` in ticks, and the target's displacement is the change in its distance from
the shooter between those two ticks, in mm (run_shot_session's ahead values). This is the display error of a snapshot
client, not a prediction error: SnapshotClient shows the last received snapshot and does not predict. RollbackPeer, the
prediction seam in ludens-core, is not used here.
"""
from geometry.vec import Real
from app.net_frontier import run_session, run_shot_session


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

    print("")
    print("| one-way latency | ms | shots found | mean lag (ticks) | max lag (ticks) | mean target shift (mm) | max target shift (mm) |")
    print("|---:|---:|---:|---:|---:|---:|---:|")
    for lat in range(10):
        var found = 0
        var lag_sum = 0
        var lag_max = 0
        var shift_sum = 0
        var shift_max = 0
        for seed in seeds:
            var c = run_shot_session(lat, 3, Real(0.1), seed, T)
            if not c.found:
                continue
            found += 1
            var lag = c.now - c.seen
            var shift = c.ahead_now - c.ahead_seen
            if shift < 0:
                shift = -shift
            lag_sum += lag
            shift_sum += shift
            if lag > lag_max:
                lag_max = lag
            if shift > shift_max:
                shift_max = shift
        var lag_mean = Float64(lag_sum) / Float64(found) if found > 0 else 0.0
        var shift_mean = Float64(shift_sum) / Float64(found) if found > 0 else 0.0
        print("|", lat, "|", lat * 1000 // 60, "|", found, "/ 3 |", lag_mean, "|", lag_max, "|", shift_mean, "|", shift_max, "|")
