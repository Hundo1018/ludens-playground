"""The crowd (step 7, docs/PLAN.md): entities in ludens-core's ecs.World, moved by the engine's FlowField over a navmesh
of the floor, drawn as instanced skinned CesiumMan. Two worlds hold the same crowd, one per storage backend, and a HUD
switch picks which one is simulated and drawn (the other is rebuilt from it on switch).

The floor is the arena's (game/arena.mojo: 40 m square, two triangles), baked with the arena's navigation settings.
Members loop round four street corners (plan W4, the user's choice of a loop): each walks to its current corner, and on
arrival (within 0.6 m) takes the next one. Each corner has its own flow field, built once.
"""
from ecs.component import ComponentType
from ecs.naive_backend import NaiveBackend
from ecs.storage import StorageBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.world import World
from geometry.vec import Real, Vec3
from nav.heightfield import NavBakeConfig
from nav.navmesh import NavMesh, bake_navmesh
from nav.path import FlowField
from app.nav_boxes import tri, nav_box
from frontier.world import StaticBox

comptime SPEED = Real(1.4)  # metres per second
comptime STOP = Real(0.6)  # metres from the goal
comptime FLOOR = Real(20.0)  # the floor is -20 .. 20 m on each axis
comptime ROUTE_R = Real(12.0)  # the four route corners sit this far from the centre on each axis
comptime ROUTES = 4
comptime CLEAR = Real(0.3)  # a route corner keeps this far from a pillar's footprint


def route_corner(i: Int) -> Vec3:
    """Corner i of the loop: (-12, -12), (12, -12), (12, 12), (-12, 12)."""
    var x = -ROUTE_R if i == 0 or i == 3 else ROUTE_R
    var z = -ROUTE_R if i <= 1 else ROUTE_R
    return Vec3(x, 0.0, z, 0.0)


@fieldwise_init
struct CrowdPos(ComponentType):
    comptime ID: Int = 40
    var x: Real
    var z: Real


@fieldwise_init
struct CrowdPhase(ComponentType):
    comptime ID: Int = 41
    var offset: Int  # the member's clip frame is (the clock's frame + offset) mod the clip's length


@fieldwise_init
struct CrowdRoute(ComponentType):
    comptime ID: Int = 42
    var goal: Int  # the corner the member walks to now, 0 to ROUTES - 1; it advances on arrival


comptime SparseWorld = World[SparseSetBackend[CrowdPos, CrowdPhase, CrowdRoute]]
comptime NaiveWorld = World[NaiveBackend[CrowdPos, CrowdPhase, CrowdRoute]]


@fieldwise_init
struct CrowdRow(Copyable, ImplicitlyCopyable, Movable):
    var x: Real
    var z: Real
    var offset: Int
    var goal: Int


def floor_mesh(boxes: List[StaticBox]) raises -> NavMesh:
    """The 40 m floor with each box as an obstacle (the hub's pillars: plan W5), baked with the arena's settings."""
    var verts = List[Vec3]()
    var tris = List[Int]()
    tri(verts, tris, Vec3(-20.0, 0.0, -20.0, 0.0), Vec3(-20.0, 0.0, 20.0, 0.0), Vec3(20.0, 0.0, -20.0, 0.0))
    tri(verts, tris, Vec3(20.0, 0.0, -20.0, 0.0), Vec3(-20.0, 0.0, 20.0, 0.0), Vec3(20.0, 0.0, 20.0, 0.0))
    for bx in boxes:
        nav_box(verts, tris, bx.c, bx.h)
    return bake_navmesh(verts, tris, NavBakeConfig(0.25, 0.1, 1.8, 0.3, 0.4, 45.0, 16))


def populate[Bk: StorageBackend](mut w: World[Bk], n: Int):
    """Spawn n members on a grid 8 m to 18 m from the centre, phases spread by 7 frames."""
    for k in range(n):
        var e = w.spawn()
        var col = Real(Float64(k % 16) - 8.0) * Real(1.2)
        var row = Real(Float64(k // 16) * 1.2) - Real(12.0)
        w.set(e, CrowdPos(col, row))
        w.set(e, CrowdPhase(7 * k))
        w.set(e, CrowdRoute(k % ROUTES))


def step_members[Bk: StorageBackend](mut w: World[Bk], fields: List[FlowField], mesh: NavMesh, dt: Real) raises -> Int:
    """One tick: each member walks along the flow field of its current corner; on arrival it takes the next corner.
    Returns the arrivals this tick."""
    var arrivals = 0
    for e in w.query2[CrowdPos, CrowdPhase]():
        var p = w.get[CrowdPos](e)
        var r = w.get[CrowdRoute](e)
        var c = route_corner(r.goal)
        var dx = c[0] - p.x
        var dz = c[2] - p.z
        if dx * dx + dz * dz <= STOP * STOP:
            r.goal = (r.goal + 1) % ROUTES
            arrivals += 1
            w.set(e, r)
        var d = fields[r.goal].direction(mesh, Vec3(p.x, Real(0.0), p.z, Real(0.0)))
        p.x += d[0] * SPEED * dt
        p.z += d[2] * SPEED * dt
        w.set(e, p)
    return arrivals


def rows[Bk: StorageBackend](w: World[Bk]) -> List[CrowdRow]:
    var out = List[CrowdRow]()
    for e in w.query2[CrowdPos, CrowdPhase]():
        var p = w.get[CrowdPos](e)
        var ph = w.get[CrowdPhase](e)
        var rt = w.get[CrowdRoute](e)
        out.append(CrowdRow(p.x, p.z, ph.offset, rt.goal))
    return out^


def _rebuild[Bk: StorageBackend](mut w: World[Bk], src: List[CrowdRow]):
    for r in src:
        var e = w.spawn()
        w.set(e, CrowdPos(r.x, r.z))
        w.set(e, CrowdPhase(r.offset))
        w.set(e, CrowdRoute(r.goal))


def _route_field(mesh: NavMesh, i: Int) raises -> FlowField:
    var f = FlowField()
    if not f.build(mesh, route_corner(i)):
        raise Error("crowd: route corner " + String(i) + " is not on the navmesh")
    return f^


def _route_fields(mesh: NavMesh) raises -> List[FlowField]:
    var out = List[FlowField]()
    out.append(_route_field(mesh, 0))
    out.append(_route_field(mesh, 1))
    out.append(_route_field(mesh, 2))
    out.append(_route_field(mesh, 3))
    return out^


struct CrowdState(Movable):
    """The crowd in both backends, one flow field per route corner, and which backend is live."""

    var sparse: SparseWorld
    var naive: NaiveWorld
    var mesh: NavMesh
    var fields: List[FlowField]
    var use_naive: Bool
    var n: Int
    var arrivals: Int  # corner arrivals over the whole run, both backends

    def __init__(out self, n: Int, boxes: List[StaticBox]) raises:
        self.sparse = SparseWorld()
        self.naive = NaiveWorld()
        populate(self.sparse, n)
        populate(self.naive, n)
        self.mesh = floor_mesh(boxes)
        for i in range(ROUTES):
            var k = route_corner(i)
            for b in boxes:
                if abs(k[0] - b.c[0]) < b.h[0] + CLEAR and abs(k[2] - b.c[2]) < b.h[2] + CLEAR:
                    raise Error("crowd: route corner " + String(i) + " is inside a pillar; move the corner along its street")
        self.fields = _route_fields(self.mesh)
        self.use_naive = False
        self.n = n
        self.arrivals = 0

    def backend_name(self) -> String:
        return "naive" if self.use_naive else "sparse-set"

    def step(mut self, dt: Real) raises:
        if self.use_naive:
            self.arrivals += step_members(self.naive, self.fields, self.mesh, dt)
        else:
            self.arrivals += step_members(self.sparse, self.fields, self.mesh, dt)

    def positions(self) raises -> List[CrowdRow]:
        if self.use_naive:
            return rows(self.naive)
        return rows(self.sparse)

    def switch(mut self) raises:
        """Flip the live backend. The newly live world is rebuilt from the old one, so the crowd does not jump."""
        var keep = self.positions()
        if self.use_naive:
            self.sparse = SparseWorld()
            _rebuild(self.sparse, keep)
        else:
            self.naive = NaiveWorld()
            _rebuild(self.naive, keep)
        self.use_naive = not self.use_naive
