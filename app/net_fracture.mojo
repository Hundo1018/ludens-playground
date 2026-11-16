"""Reference baseline C (Battlefield 1: destruction synchronized across players): a fractured wall served by the engine's
SnapshotServer to two SnapshotClients over lossy SimLinks.

FractureSim implements ludens-core's NetSim over an EmbedWorld holding a fractured wall (40 Voronoi pieces, seed 7) on a
ground box. Player 0's fire button (bit 0) launches a 2000 kg crate at the wall once; the server steps the physics, the
wall breaks, and its fragments' poses are the replicated state.

The state is the fragments' poses in integers (millimetres, rotations times 1e6) plus whether each is alive, not
EmbedWorld.save(): EmbedWorld refuses save and load while it holds a fractured object (ludens-engine#75). A client
builds the same wall from the same seed and, on load, teleports each fragment to the server's pose; clients never step
the physics (SnapshotClient only displays), so their welds stay as built and do not matter.

A client's hash is computed from its own world (EmbedWorld.state read back after the teleport), not from the received
bytes, so a pose that does not survive the round trip shows up as a hash mismatch. teleport normalises the rotation, and
plain rounding does not survive it (measured: 2 of 160 rotation integers off by one), so the server quantises each
rotation with ludens-core's embed.world.quantize_rotation (ludens-engine#75, ROADMAP 17.93), whose integers are a fixed
point of dequantise -> teleport -> state -> round.
"""
from std.math import sqrt
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from embed.world import EmbedWorld, quantize_rotation, dequantize_rotation
from gameplay.netcode import NetSim, PlayerInput, SnapshotServer, SnapshotClient, SimLink

comptime NC = 2  # clients (the baseline: the server and both clients)
comptime WALL_POS = Vec3(0.0, 2.0, 0.0, 0.0)
comptime WALL_HALF = Vec3(4.0, 2.0, 0.3, 0.0)
comptime WALL_PIECES = 40
comptime WALL_SEED = 7
comptime WALL_STRESS = Real(5e1)
comptime WALL_DENSITY = Real(2000.0)
comptime CRATE_START = Vec3(0.0, 2.2, 4.0, 0.0)  # fired at the wall's middle from 4 m (a crate slides to rest; a ball rolls)
comptime CRATE_HALF = Vec3(0.6, 0.6, 0.6, 0.0)
comptime CRATE_MASS = Real(2000.0)
comptime CRATE_SPEED = Real(30.0)  # m/s toward the wall (-z)
comptime FIRE_TICK = 10  # player 0 holds fire on ticks 10..12 (the crate is launched once)
comptime ROT_SCALE = Real(1000000.0)
comptime FNV_OFFSET = UInt64(0xCBF29CE484222325)
comptime FNV_PRIME = UInt64(0x100000001B3)


def _rot_ints(q: Quat) -> List[Int]:
    var r = List[Int]()
    r.append(Int(round(q.x * ROT_SCALE)))
    r.append(Int(round(q.y * ROT_SCALE)))
    r.append(Int(round(q.z * ROT_SCALE)))
    r.append(Int(round(q.w * ROT_SCALE)))
    return r^




struct FractureSim(NetSim):
    var count: Int
    var now: Int
    var world: EmbedWorld
    var frags: List[Int64]
    var crate: Int64  # -1 until fired
    var events: Int  # fracture events since the start (stepped on the server; carried in the state)
    var snap: List[Int]  # the server's state integers after its latest step (empty on a client)

    def __init__(out self, count: Int) raises:
        self.count = count
        self.now = 0
        self.world = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
        _ = self.world.add_box(Vec3(0.0, -0.5, 0.0, 0.0), Vec3(50.0, 0.5, 50.0, 0.0), 0.0, True)
        _ = self.world.add_fracture_box(WALL_POS, WALL_HALF, WALL_PIECES, WALL_SEED, WALL_STRESS, WALL_DENSITY)
        self.frags = List[Int64]()
        for i in range(self.world.fracture.fragments()):
            self.frags.append(self.world.fragment_handle(i))
        self.crate = -1
        self.events = 0
        self.snap = List[Int]()

    def players(self) -> Int:
        return self.count

    def tick(self) -> Int:
        return self.now

    def _launch(mut self) raises:
        self.crate = self.world.add_box(CRATE_START, CRATE_HALF, CRATE_MASS, False)

    def step(mut self, inputs: List[PlayerInput]) raises:
        if self.crate < 0 and (inputs[0].buttons & 1) != 0:
            self._launch()
            self.world.set_velocity(self.crate, Vec3(0.0, 0.0, -CRATE_SPEED, 0.0), Vec3(0.0, 0.0, 0.0, 0.0))
        _ = self.world.ticks_due(0.0)  # clears the frame's event lists, so frame_fracture holds this tick's records
        self.world.physics_tick()
        self.events += len(self.world.frame_fracture)
        self.now += 1
        self.snap = self._ints(True)

    def _pose(mut self, h: Int64, fixed: Bool, mut out: List[Int]) raises:
        var st = self.world.state(h)
        out.append(Int(round(st.pos[0] * 1000.0)))
        out.append(Int(round(st.pos[1] * 1000.0)))
        out.append(Int(round(st.pos[2] * 1000.0)))
        if fixed:
            out.extend(quantize_rotation(st.rot, ROT_SCALE))
        else:
            out.extend(_rot_ints(st.rot))

    def _ints(mut self, fixed: Bool) raises -> List[Int]:
        """now, events, fired, then per fragment: alive, x, y, z (mm), qx, qy, qz, qw (x 1e6); then the crate's pose."""
        var out = List[Int]()
        out.append(self.now)
        out.append(self.events)
        out.append(1 if self.crate >= 0 else 0)
        for i in range(len(self.frags)):
            var h = self.frags[i]
            if self.world.is_alive(h):
                out.append(1)
                self._pose(h, fixed, out)
            else:
                out.append(0)
                for _ in range(7):
                    out.append(0)
        if self.crate >= 0:
            self._pose(self.crate, fixed, out)
        return out^

    def state_ints(self) raises -> List[Int]:
        """The server's integers from its latest step, or a client's own world read back."""
        if len(self.snap) > 0:
            return self.snap.copy()
        var me = self._read_back()
        return me^

    def _read_back(self) raises -> List[Int]:
        var out = List[Int]()
        out.append(self.now)
        out.append(self.events)
        out.append(1 if self.crate >= 0 else 0)
        for h in self.frags:
            if self.world.is_alive(h):
                out.append(1)
                var st = self.world.state(h)
                out.append(Int(round(st.pos[0] * 1000.0)))
                out.append(Int(round(st.pos[1] * 1000.0)))
                out.append(Int(round(st.pos[2] * 1000.0)))
                out.extend(_rot_ints(st.rot))
            else:
                out.append(0)
                for _ in range(7):
                    out.append(0)
        if self.crate >= 0:
            var st = self.world.state(self.crate)
            out.append(Int(round(st.pos[0] * 1000.0)))
            out.append(Int(round(st.pos[1] * 1000.0)))
            out.append(Int(round(st.pos[2] * 1000.0)))
            out.extend(_rot_ints(st.rot))
        return out^

    def save(self) -> List[UInt8]:
        var out = List[UInt8]()
        try:
            for v in self.state_ints():
                _put(out, v)
        except:
            pass  # state() raises only on a stale handle, which the readers check first
        return out^

    def load(mut self, data: List[UInt8]) raises:
        var pos = 0
        self.now = _get(data, pos)
        self.events = _get(data, pos)
        var fired = _get(data, pos) != 0
        for h in self.frags:
            var alive = _get(data, pos) != 0
            var p = _read_pose(data, pos)
            if alive and self.world.is_alive(h):
                self.world.teleport(h, p[0], p[1])
            elif not alive and self.world.is_alive(h):
                self.world.remove(h)
        if fired:
            if self.crate < 0:
                self._launch()
            var p = _read_pose(data, pos)
            self.world.teleport(self.crate, p[0], p[1])

    def hash(self) -> UInt64:
        var h = FNV_OFFSET
        try:
            for v in self.state_ints():
                h = _fnv(h, v)
        except:
            pass
        return h

    def frag_hash(self) raises -> UInt64:
        """The fragments' part of the state only (the settle check)."""
        var ints = self.state_ints()
        var h = FNV_OFFSET
        for k in range(3, 3 + 8 * len(self.frags)):
            h = _fnv(h, ints[k])
        return h

    def moved(self, threshold_mm: Int) raises -> Int:
        """Fragments farther than threshold_mm from where the wall was built, or removed (the destruction a viewer sees)."""
        var fresh = FractureSim(self.count)
        var n = 0
        for i in range(len(self.frags)):
            if not self.world.is_alive(self.frags[i]):
                n += 1
                continue
            var d = self.world.state(self.frags[i]).pos - fresh.world.state(fresh.frags[i]).pos
            if sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]) * 1000.0 > Real(threshold_mm):
                n += 1
        return n


def _read_pose(data: List[UInt8], mut pos: Int) raises -> Tuple[Vec3, Quat]:
    var x = Real(_get(data, pos)) / 1000.0
    var y = Real(_get(data, pos)) / 1000.0
    var z = Real(_get(data, pos)) / 1000.0
    var r = List[Int]()
    for _ in range(4):
        r.append(_get(data, pos))
    return (Vec3(x, y, z, 0.0), dequantize_rotation(r, ROT_SCALE))


def _put(mut out: List[UInt8], v: Int):
    var u = UInt64(v)
    for k in range(8):
        out.append(UInt8((u >> UInt64(8 * k)) & UInt64(255)))


def _get(data: List[UInt8], mut pos: Int) raises -> Int:
    if pos + 8 > len(data):
        raise Error("fracture sim: state bytes end early")
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


def fire_script(p: Int, t: Int) -> PlayerInput:
    """Player 0 holds fire on ticks FIRE_TICK..FIRE_TICK+2; everyone stands still."""
    var b = UInt8(1) if p == 0 and t >= FIRE_TICK and t < FIRE_TICK + 3 else UInt8(0)
    return PlayerInput(t, p, 0, 0, b)


@fieldwise_init
struct FractureNetResult(Copyable, Movable):
    """What run_fracture_session measured."""

    var all_at_T: Bool  # every client shows tick T
    var hashes_equal: Bool  # the server's and every client's read-back hash agree at T
    var settled: Bool  # the server's fragment hash at T - SETTLE equals its fragment hash at T
    var events: Int  # fracture events on the server
    var moved_server: Int  # fragments moved more than 100 mm (or removed) on the server
    var moved_client0: Int
    var moved_client1: Int
    var bytes_break: Int  # server bytes sent while the wall breaks (ticks FIRE_TICK..FIRE_TICK+60)
    var bytes_settled: Int  # server bytes sent over the last SETTLE ticks
    var frames: Int
    var server_ints: List[Int]  # the server's state integers at T (drawn by the page)
    var client_ints: List[Int]  # client 0's, read back from its world at T


comptime SETTLE = 30


def run_fracture_session(latency: Int, jitter: Int, loss: Real, seed: UInt64, T: Int) raises -> FractureNetResult:
    """One server (a snapshot every 3 ticks) and NC clients over SimLinks. T must be a multiple of 3."""
    var srv = SnapshotServer[FractureSim](FractureSim(NC), 3)
    var clients = List[SnapshotClient[FractureSim]]()
    var up = List[SimLink]()
    var down = List[SimLink]()
    for p in range(NC):
        clients.append(SnapshotClient[FractureSim](FractureSim(NC), p))
        up.append(SimLink(latency, jitter, loss, seed + UInt64(p) * 7919))
        down.append(SimLink(latency, jitter, loss, seed + UInt64(p) * 104729 + 1))
    var hash_settle = UInt64(0)
    var bytes_at_fire = -1
    var bytes_at_break_end = -1
    var bytes_at_settle = -1
    var f = 0
    while f < 5000:
        for p in range(NC):
            if clients[p].newest < T:
                clients[p].submit(fire_script(p, f))
        for p in range(NC):
            up[p].send(f, clients[p].outgoing(NC))
        for p in range(NC):
            for m in up[p].deliver(f):
                srv.receive(p, m)
        srv.update(min(f + 1, T))
        var now = srv.sim.tick()
        if now >= T - SETTLE and bytes_at_settle < 0:
            hash_settle = srv.sim.frag_hash()
            bytes_at_settle = srv.bytes_out
        if now >= FIRE_TICK and bytes_at_fire < 0:
            bytes_at_fire = srv.bytes_out
        if now >= FIRE_TICK + 60 and bytes_at_break_end < 0:
            bytes_at_break_end = srv.bytes_out
        for p in range(NC):
            down[p].send(f, srv.outgoing(p))
        for p in range(NC):
            for m in down[p].deliver(f):
                clients[p].receive(NC, m)
        var done = True
        for p in range(NC):
            if clients[p].newest < T:
                done = False
        if done:
            break
        f += 1
    var all_at_T = True
    var equal = True
    for p in range(NC):
        if clients[p].newest != T:
            all_at_T = False
        if clients[p].world_hash() != srv.world_hash():
            equal = False
    return FractureNetResult(
        all_at_T,
        equal,
        hash_settle == srv.sim.frag_hash(),
        srv.sim.events,
        srv.sim.moved(100),
        clients[0].sim.moved(100),
        clients[1].sim.moved(100),
        bytes_at_break_end - bytes_at_fire,
        srv.bytes_out - bytes_at_settle,
        f,
        srv.sim.state_ints(),
        clients[0].sim.state_ints(),
    )
