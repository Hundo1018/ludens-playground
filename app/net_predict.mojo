"""Step 8 (docs/frontier_plan.md lines 204-206, 430): a predicted client beside the unpredicted one, natively.

Three positions of player 0 are compared, one per tick:
- truth: the server's state at tick k, delivered as a snapshot (SnapshotServer with interval 1, so every tick is one);
- predicted: a local FrontierSim the client steps itself, with its own input for tick k, at once and without waiting;
- unpredicted: the state the existing SnapshotClient shows, which is the newest snapshot it received.

The server steps tick k only after every input for tick k has arrived (SnapshotServer.update waits on all_confirmed).
It applies an input at its stamped tick and does not rewind, so the prediction error is measured at the same tick k.
The predicted client is exact here: FrontierSim moves each player from that player's own input alone, so the local
sim reproduces the server's state whenever the client's own inputs are the ones it sent. The unpredicted client shows
truth from an earlier tick, so its gap is the lag the link adds, not a prediction error.
"""
from gameplay.netcode import PlayerInput, SnapshotServer, SnapshotClient, SimLink
from app.net_frontier import FrontierSim, NP, MM_PER_STEP
from geometry.vec import Real

comptime IDLE_FROM = 540  # the input stops at this tick, 60 ticks before T = 600


def walk(p: Int, t: Int) -> PlayerInput:
    """A walk for ticks below IDLE_FROM, then no input (the stick at rest)."""
    if t >= IDLE_FROM:
        return PlayerInput.neutral(t, p)
    var mx = Int8(((t + p) % 5 - 2) * 30)
    var mz = Int8(((t * 2 + p) % 7 - 3) * 25)
    return PlayerInput(t, p, mx, mz, 0)


struct PredictReport(Copyable, ImplicitlyCopyable, Movable):
    var frames: Int
    var worst_predicted_m: Float64  # max over ticks of |predicted - truth| for player 0, in metres
    var worst_idle_m: Float64  # the same, over ticks from IDLE_FROM + 60 on
    var worst_unpredicted_lag_m: Float64  # max over frames of |predicted now - unpredicted shown|
    var p0_equal_at_end: Bool  # player 0 equal to the truth at tick T (tick, x and z)
    var ticks_checked: Int

    def __init__(out self):
        self.frames = 0
        self.worst_predicted_m = 0.0
        self.worst_idle_m = 0.0
        self.worst_unpredicted_lag_m = 0.0
        self.p0_equal_at_end = False
        self.ticks_checked = 0


def _x0(sim: FrontierSim) -> Float64:
    return Float64(sim.x[0]) / 1000.0


def run_predict(latency: Int, jitter: Int, loss: Real, seed: UInt64, T: Int) raises -> PredictReport:
    """One server, NP clients on their own links, and the local predicted sim for player 0."""
    var srv = SnapshotServer[FrontierSim](FrontierSim(NP), 1)  # a snapshot every tick
    var clients = List[SnapshotClient[FrontierSim]]()
    var up = List[SimLink]()
    var down = List[SimLink]()
    for p in range(NP):
        clients.append(SnapshotClient[FrontierSim](FrontierSim(NP), p))
        up.append(SimLink(latency, jitter, loss, seed + UInt64(p) * 7919))
        down.append(SimLink(latency, jitter, loss, seed + UInt64(p) * 104729 + 1))
    var pred = FrontierSim(NP)
    var predicted_x = List[Float64]()  # predicted x of player 0 after tick k steps, at index k
    predicted_x.append(_x0(pred))
    var report = PredictReport()
    var f = 0
    while f < 5000:
        # the local player's input for this frame, applied to the predicted sim at once
        if pred.now < T:
            var ins = List[PlayerInput]()
            for p in range(NP):
                ins.append(walk(p, pred.now) if p == 0 else PlayerInput.neutral(pred.now, p))
            pred.step(ins)
            predicted_x.append(_x0(pred))
        for p in range(NP):
            if clients[p].newest < T:
                clients[p].submit(walk(p, f))
        for p in range(NP):
            up[p].send(f, clients[p].outgoing(NP))
        for p in range(NP):
            for m in up[p].deliver(f):
                srv.receive(p, m)
        srv.update(min(f + 1, T))
        for p in range(NP):
            down[p].send(f, srv.outgoing(p))
        for p in range(NP):
            for m in down[p].deliver(f):
                clients[p].receive(NP, m)
        # the newest snapshot the unpredicted client shows, against the predicted sim at the same tick
        var shown = clients[0].newest
        var slot = shown % len(clients[0].have) if shown >= 0 else 0
        if shown >= 0 and shown <= pred.now and clients[0].have[slot] == shown:
            var truth = FrontierSim(NP)
            truth.load(clients[0].bytes[slot])
            # predicted_x[k] is the predicted state after k steps, the same tick as the snapshot
            var err = abs(predicted_x[shown] - _x0(truth))
            report.ticks_checked += 1
            if err > report.worst_predicted_m:
                report.worst_predicted_m = err
            if shown >= IDLE_FROM + 60 and err > report.worst_idle_m:
                report.worst_idle_m = err
            # the gap the unpredicted client shows: its tick's truth against the predicted sim now
            var lag = abs(predicted_x[pred.now] - _x0(truth))
            if lag > report.worst_unpredicted_lag_m:
                report.worst_unpredicted_lag_m = lag
        var done = True
        for p in range(NP):
            if clients[p].newest < T:
                done = False
        if done and pred.now >= T:
            break
        f += 1
    report.frames = f
    # at T, player 0 against the truth snapshot at T: the same tick, x and z. The world hash is not compared: the
    # predicted sim steps players 1 and 2 with neutral input (it does not know their inputs), so their state differs.
    var slot_t = T % len(clients[0].have)
    if clients[0].have[slot_t] == T:
        var truth_t = FrontierSim(NP)
        truth_t.load(clients[0].bytes[slot_t])
        report.p0_equal_at_end = truth_t.x[0] == pred.x[0] and truth_t.z[0] == pred.z[0] and truth_t.now == pred.now
    return report^
