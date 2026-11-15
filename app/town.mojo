"""The town (plan stage 3, card 3; W4): 24 ORCA residents on corner routes, and a guard, in the TOWN zone.

The town is the square 64 m on a side, centred on (128, 128): cells 3 and 4 of the 16 by 16 map. Its navmesh is the
floor of that square with each building as an obstacle. The buildings are the frontier's own static boxes
(`Frontier.static_boxes`), so the navmesh and the drawn town come from one source; a box taller than a step is a hole.

The four corners (112,112), (144,112), (144,144), (112,144) lie in the street gaps between buildings (checked by
tests/town_native.mojo). Residents loop the corners, starting at spread points on the streets. The guard patrols the
same loop until the player stands inside the town square; then it closes on the player.
"""
from app.nav_boxes import tri, nav_box
from frontier.world import StaticBox
from geometry.vec import Real, Vec3
from nav.heightfield import NavBakeConfig
from nav.navmesh import NavMesh, bake_navmesh
from nav.crowd import Crowd, Orca, CrowdParams

comptime RESIDENTS = 24
comptime RESIDENT_RADIUS = Real(0.3)
comptime RESIDENT_SPEED = Real(1.4)
comptime GUARD_RADIUS = Real(0.4)
comptime GUARD_SPEED = Real(2.2)
comptime CENTRE = Real(128.0)
comptime HALF = Real(32.0)  # the square is 64 m on a side
comptime CORNER = Real(16.0)  # the corners sit this far from the centre on each axis
comptime MIN_BUILDING_HEIGHT = Real(1.0)  # a static box taller than this blocks the navmesh


def corner(i: Int) -> Vec3:
    """Corner i of the loop, clockwise from the south-west: (112,112), (144,112), (144,144), (112,144)."""
    var x = CENTRE - CORNER if i == 0 or i == 3 else CENTRE + CORNER
    var z = CENTRE - CORNER if i <= 1 else CENTRE + CORNER
    return Vec3(x, 0.0, z, 0.0)


def town_mesh(boxes: List[StaticBox]) raises -> NavMesh:
    """The town square's floor with each box as an obstacle, baked with the card 3 settings."""
    var verts = List[Vec3]()
    var tris = List[Int]()
    var a = CENTRE - HALF
    var b = CENTRE + HALF
    tri(verts, tris, Vec3(a, 0.0, a, 0.0), Vec3(a, 0.0, b, 0.0), Vec3(b, 0.0, a, 0.0))
    tri(verts, tris, Vec3(b, 0.0, a, 0.0), Vec3(a, 0.0, b, 0.0), Vec3(b, 0.0, b, 0.0))
    for bx in boxes:
        nav_box(verts, tris, bx.c, bx.h)
    return bake_navmesh(verts, tris, NavBakeConfig(0.25, 0.1, 1.8, 0.3, 0.4, 45.0, 32))


def inside_square(p: Vec3) -> Bool:
    return p[0] >= CENTRE - HALF and p[0] <= CENTRE + HALF and p[2] >= CENTRE - HALF and p[2] <= CENTRE + HALF


struct Town(Movable):
    var mesh: NavMesh
    var crowd: Crowd[Orca]
    var goal: List[Int]  # each resident's corner index
    var guard: Int  # the guard's agent index (after the residents)
    var guard_goal: Int  # the guard's corner while the player is outside the square

    def __init__(out self, boxes: List[StaticBox]) raises:
        self.mesh = town_mesh(boxes)
        self.crowd = Crowd[Orca](Orca(), CrowdParams.default())
        self.goal = List[Int]()
        # Residents start at spread points along the street from their corner to the next, so they begin apart.
        for k in range(RESIDENTS):
            var seg = k % 4
            var f = Real(k // 4 + 1) / Real(7.0)
            var a = corner(seg)
            var b = corner((seg + 1) % 4)
            var start = a + (b - a) * f
            var agent = self.crowd.add_agent(self.mesh, start, RESIDENT_RADIUS, RESIDENT_SPEED)
            var g = (seg + 1) % 4
            self.goal.append(g)
            if not self.crowd.set_target(self.mesh, agent, corner(g)):
                raise Error("town: resident " + String(k) + " has no route to corner " + String(g))
        # The guard starts on the street south of the north-west building row, between corners 0 and 3.
        self.guard = self.crowd.add_agent(self.mesh, Vec3(112.0, 0.0, 128.0, 0.0), GUARD_RADIUS, GUARD_SPEED)
        self.guard_goal = 0
        if not self.crowd.set_target(self.mesh, self.guard, corner(0)):
            raise Error("town: the guard has no route to corner 0")

    def step(mut self, dt: Real, player: Vec3) raises:
        """One tick: residents move on to the next corner on arrival; the guard closes on the player inside the square,
        and patrols the loop otherwise."""
        for k in range(RESIDENTS):
            if self.crowd.arrived[k]:
                self.goal[k] = (self.goal[k] + 1) % 4
                _ = self.crowd.set_target(self.mesh, k, corner(self.goal[k]))
        if inside_square(player):
            _ = self.crowd.set_target(self.mesh, self.guard, player)  # a target off the mesh is refused; the guard keeps its last
        else:
            if self.crowd.arrived[self.guard]:
                self.guard_goal = (self.guard_goal + 1) % 4
            _ = self.crowd.set_target(self.mesh, self.guard, corner(self.guard_goal))
        self.crowd.step(self.mesh, dt)

    def reached(self) -> Int:
        """Residents that have arrived at their current corner at least once: counted by the caller across ticks."""
        var n = 0
        for k in range(RESIDENTS):
            if self.crowd.arrived[k]:
                n += 1
        return n

    def guard_distance(self, player: Vec3) -> Real:
        var g = self.crowd.pos[self.guard]
        var dx = g[0] - player[0]  # Vec3 is SIMD: x at 0, z at 2
        var dz = g[2] - player[2]
        return (dx * dx + dz * dz) ** Real(0.5)
