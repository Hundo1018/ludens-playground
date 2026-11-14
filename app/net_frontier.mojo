"""The Frontier's simulation for the engine's netcode (step 8, docs/design/step8-netcode.md).

FrontierSim implements ludens-core's NetSim: N players, each a position on the arena floor, moved by its input each
tick. Positions are integers in millimetres, so the state, its hash and its bytes are exact on native and wasm alike.
SnapshotServer and SnapshotClient (ludens-core gameplay/netcode) carry it; this module adds nothing to the transport.

Lag-compensated hits: the server keeps a ring of target positions per tick (TargetRing); a shot is tested against the
targets as they stood at the tick the shooter saw, not the current tick. This is the playground's own check: the
engine's rewind_ray_cast needs a ContactScene6 of colliders, which the Frontier's position-only world does not have.
"""
from geometry.vec import Real
from gameplay.netcode import NetSim, PlayerInput, SnapshotServer, SnapshotClient, SimLink

comptime NP = 3  # players in the session the page and the native test run

comptime MM_PER_STEP = 50  # a move of 127 is 6.35 m per tick at full stick; the tick is 1/60 s in the page
comptime BOUND = 10000  # the arena floor is -10 m .. 10 m on each axis
comptime FNV_OFFSET = UInt64(0xCBF29CE484222325)
comptime FNV_PRIME = UInt64(0x100000001B3)


struct FrontierSim(NetSim):
    var count: Int
    var now: Int
    var x: List[Int]  # millimetres, one per player
    var z: List[Int]

    def __init__(out self, count: Int):
        self.count = count
        self.now = 0
        self.x = List[Int](length=count, fill=0)
        self.z = List[Int](length=count, fill=0)
        # spread the players on a circle of radius 4 m, so the tests see distinct positions
        for p in range(count):
            self.x[p] = (p * 2000) - (count - 1) * 1000
            self.z[p] = 0

    def players(self) -> Int:
        return self.count

    def tick(self) -> Int:
        return self.now

    def step(mut self, inputs: List[PlayerInput]) raises:
        for p in range(self.count):
            var i = inputs[p]
            var nx = self.x[p] + Int(i.mx) * MM_PER_STEP
            var nz = self.z[p] + Int(i.mz) * MM_PER_STEP
            self.x[p] = max(-BOUND, min(BOUND, nx))
            self.z[p] = max(-BOUND, min(BOUND, nz))
        self.now += 1

    def save(self) -> List[UInt8]:
        var out = List[UInt8]()
        _put(out, self.now)
        for p in range(self.count):
            _put(out, self.x[p])
            _put(out, self.z[p])
        return out^

    def load(mut self, data: List[UInt8]) raises:
        var pos = 0
        self.now = _get(data, pos)
        for p in range(self.count):
            self.x[p] = _get(data, pos)
            self.z[p] = _get(data, pos)

    def hash(self) -> UInt64:
        var h = FNV_OFFSET
        h = _fnv(h, self.now)
        for p in range(self.count):
            h = _fnv(h, self.x[p])
            h = _fnv(h, self.z[p])
        return h


def _put(mut out: List[UInt8], v: Int):
    """An Int as 8 little-endian bytes (two's complement)."""
    var u = UInt64(v)
    for k in range(8):
        out.append(UInt8((u >> UInt64(8 * k)) & UInt64(255)))


def _get(data: List[UInt8], mut pos: Int) raises -> Int:
    if pos + 8 > len(data):
        raise Error("frontier sim: state bytes end early")
    var u = UInt64(0)
    for k in range(8):
        u |= UInt64(data[pos + k]) << UInt64(8 * k)
    pos += 8
    return Int(u)


def _fnv(h: UInt64, v: Int) -> UInt64:
    var out = h
    var u = UInt64(v)
    for k in range(8):
        out = (out ^ ((u >> UInt64(8 * k)) & UInt64(255))) * FNV_PRIME
    return out


struct TargetRing(Movable):
    """The targets' positions (millimetres) for the last `capacity` ticks: the server's history for lag compensation.
    Each target is one (x, z) at one tick; a tick's list has one entry per target, in target order."""

    var ticks: List[Int]
    var xs: List[List[Int]]
    var zs: List[List[Int]]

    def __init__(out self, capacity: Int):
        self.ticks = List[Int](length=capacity, fill=-1)
        self.xs = List[List[Int]]()
        self.zs = List[List[Int]]()
        for _ in range(capacity):
            self.xs.append(List[Int]())
            self.zs.append(List[Int]())

    def record(mut self, tick: Int, var x: List[Int], var z: List[Int]):
        var slot = tick % len(self.ticks)
        self.ticks[slot] = tick
        self.xs[slot] = x^
        self.zs[slot] = z^

    def has(self, tick: Int) -> Bool:
        return tick >= 0 and self.ticks[tick % len(self.ticks)] == tick


def shot_hits(ring: TargetRing, tick: Int, target: Int, ox: Int, oz: Int, reach: Int, radius: Int) raises -> Bool:
    """Whether a shot from (ox, oz) along +z reaches target `target` as it stood at `tick`: the target is within `reach`
    millimetres ahead (z >= oz) and within `radius` millimetres sideways. Raises when the tick has left the ring, so a
    shooter older than the history is refused rather than tested against the wrong pose."""
    if not ring.has(tick):
        raise Error("shot_hits: tick " + String(tick) + " is not in the target history")
    var slot = tick % len(ring.ticks)
    var tx = ring.xs[slot][target]
    var tz = ring.zs[slot][target]
    var ahead = tz - oz
    var side = tx - ox
    if side < 0:
        side = -side
    return ahead >= 0 and ahead <= reach and side <= radius


def script(p: Int, t: Int) -> PlayerInput:
    """A deterministic input per player and tick: a slow walk that turns every few ticks."""
    var mx = Int8(((t + p) % 5 - 2) * 30)
    var mz = Int8(((t * 2 + p) % 7 - 3) * 25)
    return PlayerInput(t, p, mx, mz, 0)


def reference(until: Int) raises -> FrontierSim:
    """The same inputs stepped in one process: the state every peer must reach."""
    var sim = FrontierSim(NP)
    for t in range(until):
        var ins = List[PlayerInput]()
        for p in range(NP):
            ins.append(script(p, t))
        sim.step(ins)
    return sim^


def run_session(latency: Int, jitter: Int, loss: Real, seed: UInt64, T: Int) raises -> Tuple[Bool, Bool, Int, Int]:
    """One server and NP clients. Returns (every client at tick T, every client's hash equals the reference, the
    reference hash, the frames it took)."""
    var srv = SnapshotServer[FrontierSim](FrontierSim(NP), 3)
    var clients = List[SnapshotClient[FrontierSim]]()
    var up = List[SimLink]()
    var down = List[SimLink]()
    for p in range(NP):
        clients.append(SnapshotClient[FrontierSim](FrontierSim(NP), p))
        up.append(SimLink(latency, jitter, loss, seed + UInt64(p) * 7919))
        down.append(SimLink(latency, jitter, loss, seed + UInt64(p) * 104729 + 1))
    var f = 0
    while f < 5000:
        for p in range(NP):
            if clients[p].newest < T:
                clients[p].submit(script(p, f))
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
        var done = True
        for p in range(NP):
            if clients[p].newest < T:
                done = False
        if done:
            break
        f += 1
    var want = reference(T)
    var all_at_T = True
    var all_equal = True
    for p in range(NP):
        if clients[p].newest != T:
            all_at_T = False
        if clients[p].world_hash() != want.hash():
            all_equal = False
    if srv.world_hash() != want.hash():
        all_equal = False
    return (all_at_T, all_equal, Int(want.hash() % UInt64(1000000007)), f)
