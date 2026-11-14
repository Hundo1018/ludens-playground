"""The town's crowd (plan stage 3, card 3): 24 residents on ludens-core's ORCA crowd, each walking between the four street
corners, switching to the next corner on arrival; and a guard that closes on the player.

The floor is the arena's (app/crowd.mojo: floor_mesh). Residents keep ORCA separation from each other and from the guard.
The corners sit inside the floor's -20..20 m square. Purpose: the residents' routes are the town's traffic, so the crowd
reads as people going somewhere, not as a flock pulled toward the player.

Design choice recorded in docs/PLAN.md (Decisions): the crowd's purpose is taken from card 3 of docs/frontier_plan.md.
"""
from geometry.vec import Real, Vec3
from nav.navmesh import NavMesh
from nav.crowd import Crowd, Orca, CrowdParams
from app.crowd import floor_mesh

comptime RESIDENTS = 24
comptime RESIDENT_RADIUS = Real(0.3)
comptime RESIDENT_SPEED = Real(1.4)
comptime GUARD_RADIUS = Real(0.4)
comptime GUARD_SPEED = Real(2.2)
comptime CORNER = Real(12.0)  # the four corners sit this far from the centre on each axis


def corners() -> List[Vec3]:
    var out = List[Vec3]()
    out.append(Vec3(-CORNER, 0.0, -CORNER, 0.0))
    out.append(Vec3(CORNER, 0.0, -CORNER, 0.0))
    out.append(Vec3(CORNER, 0.0, CORNER, 0.0))
    out.append(Vec3(-CORNER, 0.0, CORNER, 0.0))
    return out^


struct Town(Movable):
    var mesh: NavMesh
    var crowd: Crowd[Orca]
    var goals: List[Vec3]  # each resident's current corner index is in `goal`
    var goal: List[Int]
    var guard: Int  # the guard's agent index (the last agent added)

    def __init__(out self) raises:
        self.mesh = floor_mesh()
        self.crowd = Crowd[Orca](Orca(), CrowdParams.default())
        self.goals = corners()
        self.goal = List[Int]()
        # Residents start on a grid around the centre, four to a corner's inner side, so they begin spread out.
        for k in range(RESIDENTS):
            var col = Real(k % 6) * Real(2.0) - Real(5.0)
            var row = Real(k // 6) * Real(2.0) - Real(3.0)
            _ = self.crowd.add_agent(self.mesh, Vec3(col, 0.0, row, 0.0), RESIDENT_RADIUS, RESIDENT_SPEED)
            self.goal.append(k % 4)
            _ = self.crowd.set_target(self.mesh, k, self.goals[k % 4])
        self.guard = self.crowd.add_agent(self.mesh, Vec3(-8.0, 0.0, -8.0, 0.0), GUARD_RADIUS, GUARD_SPEED)

    def step(mut self, dt: Real, player: Vec3) raises:
        """One tick: residents move on to the next corner on arrival; the guard heads for the player."""
        for k in range(RESIDENTS):
            if self.crowd.arrived[k]:
                self.goal[k] = (self.goal[k] + 1) % 4
                _ = self.crowd.set_target(self.mesh, k, self.goals[self.goal[k]])
        _ = self.crowd.set_target(self.mesh, self.guard, player)
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
