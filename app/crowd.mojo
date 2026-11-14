"""The crowd (step 7, docs/PLAN.md): entities in ludens-core's ecs.World, moved by the engine's FlowField over a navmesh
of the floor, drawn as instanced skinned CesiumMan. Two worlds hold the same crowd, one per storage backend, and a HUD
switch picks which one is simulated and drawn (the other is rebuilt from it on switch).

The floor is the arena's (game/arena.mojo: 40 m square, two triangles), baked with the arena's navigation settings.
The goal is the arena's centre; a member stops within 0.6 m of it.
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

comptime SPEED = Real(1.4)  # metres per second
comptime STOP = Real(0.6)  # metres from the goal
comptime FLOOR = Real(20.0)  # the floor is -20 .. 20 m on each axis


@fieldwise_init
struct CrowdPos(ComponentType):
    comptime ID: Int = 40
    var x: Real
    var z: Real


@fieldwise_init
struct CrowdPhase(ComponentType):
    comptime ID: Int = 41
    var offset: Int  # the member's clip frame is (the clock's frame + offset) mod the clip's length


comptime SparseWorld = World[SparseSetBackend[CrowdPos, CrowdPhase]]
comptime NaiveWorld = World[NaiveBackend[CrowdPos, CrowdPhase]]


@fieldwise_init
struct CrowdRow(Copyable, ImplicitlyCopyable, Movable):
    var x: Real
    var z: Real
    var offset: Int


def _tri(mut verts: List[Vec3], mut tris: List[Int], a: Vec3, b: Vec3, c: Vec3):
    var i = len(verts)
    verts.append(a)
    verts.append(b)
    verts.append(c)
    tris.append(i)
    tris.append(i + 1)
    tris.append(i + 2)


def floor_mesh() raises -> NavMesh:
    """The arena's floor, baked with the arena's settings (game/arena.mojo, _make_mesh)."""
    var verts = List[Vec3]()
    var tris = List[Int]()
    _tri(verts, tris, Vec3(-20.0, 0.0, -20.0, 0.0), Vec3(-20.0, 0.0, 20.0, 0.0), Vec3(20.0, 0.0, -20.0, 0.0))
    _tri(verts, tris, Vec3(20.0, 0.0, -20.0, 0.0), Vec3(-20.0, 0.0, 20.0, 0.0), Vec3(20.0, 0.0, 20.0, 0.0))
    return bake_navmesh(verts, tris, NavBakeConfig(0.25, 0.1, 1.8, 0.3, 0.4, 45.0, 16))


def populate[Bk: StorageBackend](mut w: World[Bk], n: Int):
    """Spawn n members on a grid 8 m to 18 m from the centre, phases spread by 7 frames."""
    for k in range(n):
        var e = w.spawn()
        var col = Real(Float64(k % 16) - 8.0) * Real(1.2)
        var row = Real(Float64(k // 16) * 1.2) - Real(12.0)
        w.set(e, CrowdPos(col, row))
        w.set(e, CrowdPhase(7 * k))


def step_members[Bk: StorageBackend](mut w: World[Bk], field: FlowField, mesh: NavMesh, dt: Real) raises:
    """One tick: each member not yet at the goal moves along the flow field."""
    for e in w.query2[CrowdPos, CrowdPhase]():
        var p = w.get[CrowdPos](e)
        var dx = -p.x
        var dz = -p.z
        if dx * dx + dz * dz <= STOP * STOP:
            continue
        var d = field.direction(mesh, Vec3(p.x, Real(0.0), p.z, Real(0.0)))
        p.x += d[0] * SPEED * dt
        p.z += d[2] * SPEED * dt
        w.set(e, p)


def rows[Bk: StorageBackend](w: World[Bk]) -> List[CrowdRow]:
    var out = List[CrowdRow]()
    for e in w.query2[CrowdPos, CrowdPhase]():
        var p = w.get[CrowdPos](e)
        var ph = w.get[CrowdPhase](e)
        out.append(CrowdRow(p.x, p.z, ph.offset))
    return out^


def _rebuild[Bk: StorageBackend](mut w: World[Bk], src: List[CrowdRow]):
    for r in src:
        var e = w.spawn()
        w.set(e, CrowdPos(r.x, r.z))
        w.set(e, CrowdPhase(r.offset))


struct CrowdState(Movable):
    """The crowd in both backends, the flow field toward the centre, and which backend is live."""

    var sparse: SparseWorld
    var naive: NaiveWorld
    var mesh: NavMesh
    var field: FlowField
    var use_naive: Bool
    var n: Int

    def __init__(out self, n: Int) raises:
        self.sparse = SparseWorld()
        self.naive = NaiveWorld()
        populate(self.sparse, n)
        populate(self.naive, n)
        self.mesh = floor_mesh()
        self.field = FlowField()
        if not self.field.build(self.mesh, Vec3(0.0, 0.0, 0.0, 0.0)):
            raise Error("crowd: the goal is not on the navmesh")
        self.use_naive = False
        self.n = n

    def backend_name(self) -> String:
        return "naive" if self.use_naive else "sparse-set"

    def step(mut self, dt: Real) raises:
        if self.use_naive:
            step_members(self.naive, self.field, self.mesh, dt)
        else:
            step_members(self.sparse, self.field, self.mesh, dt)

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
