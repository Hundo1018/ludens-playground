# Reference baseline C (Battlefield 1: destruction synchronized across players): a fractured wall on a SnapshotServer with
# two SnapshotClients. Player 0 fires a 2000 kg ball at tick 10; the server steps the physics and the wall breaks. Checks,
# for the baseline's link (latency 4, no jitter, no loss) and the page's lossy link (latency 4, jitter 3, 10 % loss):
# every client reaches tick T; the server's hash and each client's hash (read back from its own world after loading)
# are equal; the server's hash 30 ticks before T equals its hash at T (the fragments have settled); the wall broke (fracture
# events > 0) and each client shows as many moved fragments as the server; the server sends fewer bytes over the settled
# last 30 ticks than over the 60 ticks of the break (the delta snapshots carry the change).
from harness.runner import Suite
from geometry.vec import Real
from app.net_fracture import run_fracture_session, FractureSim, NC


def main() raises:
    var s = Suite("net_fracture_native")
    var T = 240
    for k in range(2):
        var latency = 4
        var jitter = 0 if k == 0 else 3
        var loss = Real(0.0) if k == 0 else Real(0.1)
        var name = "latency 4" if k == 0 else "latency 4, jitter 3, loss 10 %"
        var r = run_fracture_session(latency, jitter, loss, 1234, T)
        print(name, ": frames", r.frames, "events", r.events, "moved (server, client 0, client 1)", r.moved_server,
              r.moved_client0, r.moved_client1, "bytes break", r.bytes_break, "bytes settled", r.bytes_settled)
        s.check(r.all_at_T, name + ": both clients reach tick " + String(T))
        s.check(r.hashes_equal, name + ": the server's and both clients' read-back hashes are equal at tick " + String(T))
        s.check(r.settled, name + ": the server's hash at tick " + String(T - 30) + " equals its hash at " + String(T))
        s.check(r.events > 0, name + ": the wall breaks (" + String(r.events) + " fracture events)")
        s.check(r.moved_server > 0 and r.moved_client0 == r.moved_server and r.moved_client1 == r.moved_server,
                name + ": each client shows the server's " + String(r.moved_server) + " moved fragments ("
                + String(r.moved_client0) + ", " + String(r.moved_client1) + ")")
        s.check(r.bytes_settled < r.bytes_break,
                name + ": settled snapshots cost less than the break (" + String(r.bytes_settled) + " < " + String(r.bytes_break) + " bytes)")
    s.finish()
