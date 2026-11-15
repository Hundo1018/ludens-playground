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
from app.net_frontier import FrontierSim, NP, BOUND, MM_PER_STEP, FNV_OFFSET, FNV_PRIME
from gameplay.netcode import NetSim
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
    var blocks: Int  # moves of player 0 the coupled sim refused (0 for the independent sim)
    var world_equal_at_end: Bool  # the whole world hash of the predicted sim equals the server's at T

    def __init__(out self):
        self.frames = List[PredictFrame]()
        self.ticks_checked = 0
        self.worst_predicted_mm = 0
        self.worst_idle_mm = 0
        self.worst_lag_mm = 0
        self.p0_equal_at_end = False
        self.blocks = 0
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


# ---- the coupled sim (step 8, the hard case) ----
# Player 0's move is refused when it would bring player 0 within COUPLE_RADIUS_MM of another player and closer than it
# was. The others move as before. Player 0's motion therefore depends on the other players' positions, which the
# predicted client cannot see in real time: the error the bound measures comes from there. FrontierSim above stays as
# it is, since the page's netcode check and frontier_net_native depend on it.
comptime COUPLE_RADIUS_MM = 1000
comptime COUPLE_R2 = COUPLE_RADIUS_MM * COUPLE_RADIUS_MM


def coupled_walk(p: Int, t: Int) -> PlayerInput:
    """Players 0 and 1 walk at each other and back (0.2 m per tick), so they come within the radius; player 2 crosses
    both paths. Below IDLE_FROM only; then no input."""
    if t >= IDLE_FROM:
        return PlayerInput.neutral(t, p)
    var mx = 0
    var mz = 0
    if p == 0:
        mx = 4 if (t % 40) < 30 else -4
        mz = ((t // 20) % 3 - 1) * 2
    elif p == 1:
        mx = -4 if (t % 60) < 40 else 4
        mz = ((t // 30) % 3 - 1) * -2
    else:
        mx = ((t * 5) % 7 - 3) * 2
        mz = ((t * 3) % 5 - 2) * 3
    return PlayerInput(t, p, Int8(mx), Int8(mz), 0)


def _put_i(mut out: List[UInt8], v: Int):
    for k in range(8):
        out.append(UInt8((v >> (8 * k)) & 255))


def _get_i(data: List[UInt8], mut pos: Int) raises -> Int:
    var v = 0
    for k in range(8):
        v = v | (Int(data[pos]) << (8 * k))
        pos += 1
    return v


struct CoupledSim(NetSim):
    var count: Int
    var now: Int
    var x: List[Int]  # millimetres, one per player
    var z: List[Int]
    var blocked: Int  # player 0's refused moves, a diagnostic; not part of the state

    def __init__(out self, count: Int):
        self.count = count
        self.now = 0
        self.x = List[Int](length=count, fill=0)
        self.z = List[Int](length=count, fill=0)
        self.blocked = 0
        for p in range(count):
            self.x[p] = (p * 2000) - (count - 1) * 1000
            self.z[p] = 0

    def players(self) -> Int:
        return self.count

    def tick(self) -> Int:
        return self.now

    def _too_close(self, nx: Int, nz: Int) -> Bool:
        """The move of player 0 to (nx, nz) would bring it within the radius of another player, and closer than now."""
        for q in range(1, self.count):
            var dx = nx - self.x[q]
            var dz = nz - self.z[q]
            var d2 = dx * dx + dz * dz
            var ox = self.x[0] - self.x[q]
            var oz = self.z[0] - self.z[q]
            var now2 = ox * ox + oz * oz
            if d2 < COUPLE_R2 and d2 < now2:
                return True
        return False

    def step(mut self, inputs: List[PlayerInput]) raises:
        # player 0 first, against the others' positions at the start of this tick, so every replica resolves it alike
        var nx0 = max(-BOUND, min(BOUND, self.x[0] + Int(inputs[0].mx) * MM_PER_STEP))
        var nz0 = max(-BOUND, min(BOUND, self.z[0] + Int(inputs[0].mz) * MM_PER_STEP))
        if self._too_close(nx0, nz0):
            self.blocked += 1
        else:
            self.x[0] = nx0
            self.z[0] = nz0
        for p in range(1, self.count):
            var i = inputs[p]
            self.x[p] = max(-BOUND, min(BOUND, self.x[p] + Int(i.mx) * MM_PER_STEP))
            self.z[p] = max(-BOUND, min(BOUND, self.z[p] + Int(i.mz) * MM_PER_STEP))
        self.now += 1

    def save(self) -> List[UInt8]:
        var out = List[UInt8]()
        _put_i(out, self.now)
        for p in range(self.count):
            _put_i(out, self.x[p])
            _put_i(out, self.z[p])
        return out^

    def load(mut self, data: List[UInt8]) raises:
        var pos = 0
        self.now = _get_i(data, pos)
        for p in range(self.count):
            self.x[p] = _get_i(data, pos)
            self.z[p] = _get_i(data, pos)

    def hash(self) -> UInt64:
        var h = FNV_OFFSET
        h = (h ^ UInt64(self.now + 2147483648)) * FNV_PRIME
        for p in range(self.count):
            h = (h ^ UInt64(self.x[p] + 2147483648)) * FNV_PRIME
            h = (h ^ UInt64(self.z[p] + 2147483648)) * FNV_PRIME
        return h


def run_predict_coupled(latency: Int, jitter: Int, loss: Real, seed: UInt64, T: Int) raises -> PredictRun:
    """One server, NP clients on their own links, and the local predicted sim for player 0. Runs until every client
    holds tick T and the predicted sim reaches it."""
    var srv = SnapshotServer[CoupledSim](CoupledSim(NP), 1)  # a snapshot every tick
    var clients = List[SnapshotClient[CoupledSim]]()
    var up = List[SimLink]()
    var down = List[SimLink]()
    for p in range(NP):
        clients.append(SnapshotClient[CoupledSim](CoupledSim(NP), p))
        up.append(SimLink(latency, jitter, loss, seed + UInt64(p) * 7919))
        down.append(SimLink(latency, jitter, loss, seed + UInt64(p) * 104729 + 1))
    var pred = CoupledSim(NP)
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
                ins.append(coupled_walk(p, pred.now) if p == 0 else PlayerInput.neutral(pred.now, p))
            pred.step(ins)
            predicted_hist.append(pred.x[0])
        for p in range(NP):
            if clients[p].newest < T:
                clients[p].submit(coupled_walk(p, f))
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
            var truth = CoupledSim(NP)
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
                        replay.append(coupled_walk(p, t) if p == 0 else PlayerInput.neutral(t, p))
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
        var truth_t = CoupledSim(NP)
        truth_t.load(clients[0].bytes[slot_t])
        run.p0_equal_at_end = truth_t.x[0] == pred.x[0] and truth_t.z[0] == pred.z[0] and truth_t.now == pred.now
        run.world_equal_at_end = truth_t.hash() == pred.hash()
    run.blocks = srv.sim.blocked
    return run^
