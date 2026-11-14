# Step 8 (docs/design/step8-netcode.md), native: the Frontier's simulation over ludens-core's SnapshotServer and
# SnapshotClient, through SimLink (latency, jitter, loss), converges to the server's state and the reference run's hash;
# and a lag-compensated shot is tested against the targets as the shooter saw them.
from harness.runner import Suite
from gameplay.netcode import PlayerInput
from app.net_frontier import FrontierSim, TargetRing, shot_hits, run_session, NP
from geometry.vec import Real


def main() raises:
    var s = Suite("frontier_net_native")
    var T = 120

    var a = run_session(3, 0, Real(0), UInt64(11), T)
    s.check(a[0], "clean link (latency 3): every client reaches tick " + String(T) + " in " + String(a[3]) + " frames")
    s.check(a[1], "clean link: every client and the server equal the reference run's hash")

    var b = run_session(4, 3, Real(0.1), UInt64(2026), T)
    s.check(b[0], "jitter 3 and 10 % loss: every client still reaches tick " + String(T) + " (" + String(b[3]) + " frames)")
    s.check(b[1], "jitter 3 and 10 % loss: every client and the server equal the reference run's hash")
    print("NET check", b[2])

    # Lag-compensated hits: target 0 walks away from the shooter at 100 mm per tick, from z = 2000 mm. The shooter sees
    # the state of tick 4 (its latency), when the target is 2400 mm away and inside a 2500 mm reach; at tick 10 it is
    # 3000 mm away and outside.
    var ring = TargetRing(8)
    for t in range(11):
        var xs = List[Int]()
        var zs = List[Int]()
        xs.append(0)
        zs.append(2000 + 100 * t)
        ring.record(t, xs^, zs^)
    s.check(shot_hits(ring, 4, 0, 0, 0, 2500, 200), "a shot at the tick the shooter saw (4) hits the target there")
    s.check(not shot_hits(ring, 10, 0, 0, 0, 2500, 200), "the same shot tested at the current tick (10) misses")
    # capacity 8 and ticks 0..10 recorded: tick 2 shares slot 2 with tick 10, so it has left the ring
    var raised = False
    try:
        _ = shot_hits(ring, 2, 0, 0, 0, 2500, 200)
    except:
        raised = True
    s.check(raised, "a shooter older than the history (tick 2 after tick 10) is refused, not tested against the wrong pose")
    s.finish()
