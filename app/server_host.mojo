"""Step 8 (PLAN.md: 'Authoritative server in a second module'): the range server as its own wasm module, run in a Worker.

It holds one SnapshotServer over the Frontier's sim. The page's clients (the page module) exchange the same bytes with it:
receive a client's inputs, update, take the snapshot bytes for each client. Built by scripts/build_server.sh; the exports
are playground_server_* and the handle is an address in this module's memory (as the page's host handle is).
"""
from gameplay.netcode import SnapshotServer
from app.net_frontier import FrontierSim
from geometry.vec import Real
from wgpu._backend.wgpu_native.alloc_guard import raw_alloc

comptime SERVER_INTERVAL = 3
comptime MODULUS = UInt64(1000000007)


struct ServerState(Movable):
    var srv: SnapshotServer[FrontierSim]
    var out: List[UInt8]

    def __init__(out self, players: Int):
        self.srv = SnapshotServer[FrontierSim](FrontierSim(players), SERVER_INTERVAL)
        self.out = List[UInt8]()


def _server(handle: UInt64) -> Pointer[ServerState, MutUntrackedOrigin]:
    return Pointer[ServerState, MutUntrackedOrigin](unsafe_from_address=Int(handle))


@export
def playground_server_new(players: Int32) abi("C") -> UInt64:
    """A server for `players` clients (nodes 0 .. players-1). 0 if players is out of range."""
    if players < 1 or players > 8:
        return 0
    var p = raw_alloc[ServerState](1)
    p.unsafe_write(ServerState(Int(players)))
    return UInt64(Int(p))


@export
def playground_server_receive(handle: UInt64, from_node: Int32, ptr: UInt64, length: Int32) abi("C") -> Int32:
    """A message from client `from_node`: `length` bytes at `ptr` in this module's memory. 0, or -1 if it was refused."""
    var s = _server(handle)
    var msg = List[UInt8]()
    var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(ptr))
    for k in range(Int(length)):
        msg.append(src[k])
    try:
        s[].srv.receive(Int(from_node), msg)
        return 0
    except e:
        print("playground_server_receive:", e)
        return -1


@export
def playground_server_update(handle: UInt64, target: Int32) abi("C") -> Int32:
    """Step the authoritative sim toward tick `target` (it waits for every client's input for each tick). 0 or -1."""
    var s = _server(handle)
    try:
        s[].srv.update(Int(target))
        return 0
    except e:
        print("playground_server_update:", e)
        return -1


@export
def playground_server_outgoing(handle: UInt64, to_node: Int32) abi("C") -> Int32:
    """The bytes for client `to_node` (kept in the server's buffer: read them with playground_server_out_ptr). Returns the length."""
    var s = _server(handle)
    var m = s[].srv.outgoing(Int(to_node))
    s[].out = m^
    return Int32(len(s[].out))


@export
def playground_server_out_ptr(handle: UInt64) abi("C") -> UInt64:
    """The address of the last outgoing message in this module's memory."""
    var s = _server(handle)
    return UInt64(Int(s[].out.unsafe_ptr()))


@export
def playground_server_tick(handle: UInt64) abi("C") -> Int32:
    return Int32(_server(handle)[].srv.sim_tick())


@export
def playground_server_hash(handle: UInt64) abi("C") -> Int32:
    """The server's world hash, mod 1000000007 (the same number the page's net check reports)."""
    return Int32(Int(_server(handle)[].srv.world_hash() % MODULUS))
