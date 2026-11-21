"""W11 (plan, the 3b crowd off the main thread): the step-7 crowd as its own wasm module, run in a Worker.

It holds one CrowdState (the same class the page uses, app/crowd.mojo). The page passes the hub's pillar boxes as floats,
steps the crowd each tick, and reads the rows back; the rows are the crowd's positions, offsets and goals. Built by
scripts/build_crowd.sh; the exports are playground_crowd_* and the handle is an address in this module's memory.
"""
from app.crowd import CrowdState, CrowdRow, positions_hash
from frontier.world import StaticBox
from geometry.vec import Real, Vec3
from wgpu import raw_alloc


struct CrowdHost(Movable):
    var st: CrowdState
    var out: List[Float32]  # the last rows: x, z, offset, goal per member

    def __init__(out self, n: Int, var boxes: List[StaticBox]) raises:
        self.st = CrowdState(n, boxes)
        self.out = List[Float32]()


def _host(handle: UInt64) -> Pointer[CrowdHost, MutUntrackedOrigin]:
    return Pointer[CrowdHost, MutUntrackedOrigin](unsafe_from_address=Int(handle))


@export
def playground_crowd_new(n: Int32, boxes_ptr: UInt64, nboxes: Int32) abi("C") -> UInt64:
    """A crowd of n members. The boxes are nboxes records of 6 floats at boxes_ptr: centre x, y, z, then half x, y, z.
    0 if n or the boxes are refused (printed)."""
    if n < 1 or n > 4096 or nboxes < 0:
        return 0
    var src = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(boxes_ptr))
    var boxes = List[StaticBox]()
    for i in range(Int(nboxes)):
        var c = Vec3(Real(Float64(src[6 * i])), Real(Float64(src[6 * i + 1])), Real(Float64(src[6 * i + 2])), Real(0))
        var h = Vec3(Real(Float64(src[6 * i + 3])), Real(Float64(src[6 * i + 4])), Real(Float64(src[6 * i + 5])), Real(0))
        boxes.append(StaticBox(c, h))
    var p = raw_alloc[CrowdHost](1)
    try:
        p.unsafe_write(CrowdHost(Int(n), boxes^))
    except e:
        print("playground_crowd_new:", e)
        return 0
    return UInt64(Int(p))


@export
def playground_crowd_step(handle: UInt64, dt: Float64) abi("C") -> Int32:
    """Advance the crowd by dt seconds. 0, or -1 if the step failed (printed)."""
    var h = _host(handle)
    try:
        h[].st.step(Real(dt))
        return 0
    except e:
        print("playground_crowd_step:", e)
        return -1


@export
def playground_crowd_rows(handle: UInt64) abi("C") -> UInt64:
    """Refresh the rows (4 floats per member: x, z, offset, goal) and return their address in this module's memory."""
    var h = _host(handle)
    try:
        var rows = h[].st.positions()
        h[].out = List[Float32]()
        for r in rows:
            h[].out.append(Float32(Float64(r.x)))
            h[].out.append(Float32(Float64(r.z)))
            h[].out.append(Float32(r.offset))
            h[].out.append(Float32(r.goal))
        return UInt64(Int(h[].out.unsafe_ptr()))
    except e:
        print("playground_crowd_rows:", e)
        return 0


@export
def playground_crowd_count(handle: UInt64) abi("C") -> Int32:
    return Int32(len(_host(handle)[].out) // 4)


@export
def playground_crowd_hash(handle: UInt64) abi("C") -> Int32:
    """positions_hash of the current crowd (parity check against the page's crowd). Mod 1000000007."""
    var h = _host(handle)
    try:
        return Int32(positions_hash(h[].st.positions()))
    except e:
        print("playground_crowd_hash:", e)
        return -1
