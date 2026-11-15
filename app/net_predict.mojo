"""Step 8 (docs/frontier_plan.md lines 204-206, 430): a predicted client beside the unpredicted one.

Three positions of player 0, in millimetres:
- server: the server's own sim x at its current tick (SnapshotServer, interval 1: a snapshot every tick);
- predicted: a local FrontierSim the client steps itself, with its own input for each tick, at once and without
  waiting for the server;
- shown: the x the existing SnapshotClient displays, which is the snapshot it holds newest.

The server steps tick k only after every input for tick k has arrived (SnapshotServer.update waits on all_confirmed),
and it applies each input at its stamped tick without rewinding. So the prediction error is compared at the same tick
k. FrontierSim moves each player from that player's own input alone, so the predicted sim equals the server whenever
the client's inputs are the ones it sent. The shown client lags the server by the link's delay, not by a prediction
error.
"""
from gameplay.netcode import PlayerInput, SnapshotServer, SnapshotClient, SimLink
from app.net_frontier import FrontierSim, NP
from geometry.vec import Real

comptime IDLE_FROM = 540  # the walk stops at this tick, 60 ticks before T = 600
comptime PREDICT_T = 600
comptime PREDICT_SEED = UInt64(55)


def walk(p: Int, t: Int) -> PlayerInput:
    """A walk for ticks below IDLE_FROM, then no input (the stick at rest)."""
    if t >= IDLE_FROM:
        return PlayerInput.neutral(t, p)
    var mx = Int8(((t + p) % 5 - 2) * 30)
    var mz = Int8(((t * 2 + p) % 7 - 3) * 25)
    return PlayerInput(t, p, mx, mz, 0)


struct PredictFrame(Copyable, ImplicitlyCopyable, Movable):
    """Player 0's x, in millimetres, at one frame: the server's, the predicted sim's and the shown client's."""

    var server_mm: Int
    var predicted_mm: Int
    var shown_mm: Int

    def __init__(out self, server_mm: Int, predicted_mm: Int, shown_mm: Int):
        self.server_mm = server_mm
        self.predicted_mm = predicted_mm
        self.shown_mm = shown_mm


struct PredictRun(Movable):
    var frames: List[PredictFrame]
    var ticks_checked: Int  # snapshot ticks compared with the predicted sim at the same tick
    var worst_predicted_mm: Int  # max over those ticks of |predicted - truth|
    var worst_idle_mm: Int  # the same, over ticks from IDLE_FROM + 60 on
    var worst_lag_mm: Int  # max over frames of |predicted now - shown|
    var p0_equal_at_end: Bool  # player 0's tick, x and z equal the truth at T
    var world_equal_at_end: Bool  # the whole world hash of the predicted sim equals the server's at T

    def __init__(out self):
        self.frames = List[PredictFrame]()
        self.ticks_checked = 0
        self.worst_predicted_mm = 0
        self.worst_idle_mm = 0
        self.worst_lag_mm = 0
        self.p0_equal_at_end = False
        self.world_equal_at_end = False


def run_predict(latency: Int, jitter: Int, loss: Real, seed: UInt64, T: Int) raises -> PredictRun:
    """One server, NP clients on their own links, and the local predicted sim for player 0. Runs until every client
    holds tick T and the predicted sim reaches it."""
    var srv = SnapshotServer[FrontierSim](FrontierSim(NP), 1)  # a snapshot every tick
    var clients = List[SnapshotClient[FrontierSim]]()
    var up = List[SimLink]()
    var down = List[SimLink]()
    for p in range(NP):
        clients.append(SnapshotClient[FrontierSim](FrontierSim(NP), p))
        up.append(SimLink(latency, jitter, loss, seed + UInt64(p) * 7919))
        down.append(SimLink(latency, jitter, loss, seed + UInt64(p) * 104729 + 1))
    var pred = FrontierSim(NP)
    var predicted_hist = List[Int]()  # the predicted x after k steps, at index k
    predicted_hist.append(pred.x[0])
    var run = PredictRun()
    var last_recon = -1  # the newest snapshot tick the predicted sim has been reconciled with
    var f = 0
    while f < 5000:
        # the local player's input for this frame, applied to the predicted sim at once
        if pred.now < T:
            var ins = List[PlayerInput]()
            for p in range(NP):
                ins.append(walk(p, pred.now) if p == 0 else PlayerInput.neutral(pred.now, p))
            pred.step(ins)
            predicted_hist.append(pred.x[0])
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
        # the shown client's newest snapshot, decoded: its x, and the error against the predicted sim at that tick
        var shown = clients[0].newest
        var slot = shown % len(clients[0].have) if shown >= 0 else 0
        var shown_mm = 0
        if shown >= 0 and clients[0].have[slot] == shown:
            var truth = FrontierSim(NP)
            truth.load(clients[0].bytes[slot])
            shown_mm = truth.x[0]
            if shown < len(predicted_hist):
                var err = abs(predicted_hist[shown] - truth.x[0])
                run.ticks_checked += 1
                if err > run.worst_predicted_mm:
                    run.worst_predicted_mm = err
                if shown >= IDLE_FROM + 60 and err > run.worst_idle_mm:
                    run.worst_idle_mm = err
            var lag = abs(pred.x[0] - shown_mm)
            if lag > run.worst_lag_mm:
                run.worst_lag_mm = lag
            # reconcile with each new snapshot: the predicted sim takes the server's state at that tick and replays
            # this client's own inputs up to the current tick. The other players stay on neutral input in the replay.
            if shown > last_recon:
                var target = pred.now
                pred.load(clients[0].bytes[slot])
                for t in range(shown, target):
                    var replay = List[PlayerInput]()
                    for p in range(NP):
                        replay.append(walk(p, t) if p == 0 else PlayerInput.neutral(t, p))
                    pred.step(replay)
                last_recon = shown
        run.frames.append(PredictFrame(srv.sim.x[0], pred.x[0], shown_mm))
        var done = True
        for p in range(NP):
            if clients[p].newest < T:
                done = False
        if done and pred.now >= T:
            break
        f += 1
    # at T, the truth snapshot against the predicted sim: player 0's tick, x and z, and the whole world hash. The other
    # players are idle from IDLE_FROM on, so the reconciled sim holds their exact state once a snapshot after that arrives.
    var slot_t = T % len(clients[0].have)
    if clients[0].have[slot_t] == T:
        var truth_t = FrontierSim(NP)
        truth_t.load(clients[0].bytes[slot_t])
        run.p0_equal_at_end = truth_t.x[0] == pred.x[0] and truth_t.z[0] == pred.z[0] and truth_t.now == pred.now
        run.world_equal_at_end = truth_t.hash() == pred.hash()
    return run^
