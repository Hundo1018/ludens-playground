"""The town (plan stage 3, card 3; W4): 24 ORCA residents on corner routes, and a guard, in the TOWN zone.

The town is the square 64 m on a side, centred on (128, 128): cells 3 and 4 of the 16 by 16 map. Its navmesh is the
floor of that square with each building as an obstacle. The buildings are the frontier's own static boxes
(`Frontier.static_boxes`), so the navmesh and the drawn town come from one source; a box taller than a step is a hole.

The four corners (112,112), (144,112), (144,144), (112,144) lie in the street gaps between buildings (checked by
tests/town_native.mojo). Residents loop the corners, starting at spread points on the streets. The guard patrols the
same loop until the player stands inside the town square; then it closes on the player.
"""
from nav.nav_input import nav_tri, nav_box
from frontier.world import StaticBox
from geometry.vec import Real, Vec3
from nav.heightfield import NavBakeConfig
from nav.navmesh import NavMesh, bake_navmesh
from nav.crowd import Crowd, Orca, CrowdParams
from geometry.aabb import AABB
from geometry.ray import Ray
from spatial.bvh import BVH
from ai.blackboard import Blackboard
from ai.bt import BehaviorTree, BtState, BtHost, bt_tick, SUCCESS, RUNNING
from ai.perception import Perception, SenseConfig

comptime RESIDENTS = 24
comptime RESIDENT_RADIUS = Real(0.3)
comptime RESIDENT_SPEED = Real(1.4)
comptime GUARD_RADIUS = Real(0.4)
comptime GUARD_SPEED = Real(7.0)  # W6: 7 m/s, so the guard can catch a player who runs (was 2.2, slower than the player's 9 m/s)
comptime CONTACT_R = Real(1.0)  # W6: the guard touches the player within this distance
comptime CENTRE = Real(128.0)
comptime HALF = Real(32.0)  # the square is 64 m on a side
comptime CORNER = Real(16.0)  # the corners sit this far from the centre on each axis
comptime MIN_BUILDING_HEIGHT = Real(1.0)  # a static box taller than this blocks the navmesh
# Reference baseline D1: the residents run one shared behavior tree (ai.bt), one BtState each:
#   selector (reactive)
#     sequence: CHECK player within WATCH_R -> ACTION watch (stop and stay)
#     sequence: ACTION walk to the current corner -> WAIT IDLE_TICKS -> ACTION pick the next corner
comptime ACT_WALK = 0
comptime ACT_NEXT = 1
comptime ACT_WATCH = 2
comptime COND_PLAYER_NEAR = 0
comptime IDLE_TICKS = 90  # 1.5 s at a corner
comptime WATCH_R = Real(4.0)  # a resident within this distance of the player stops and watches
comptime CMD_KEEP = -2
comptime CMD_STOP = -1
# Reference baseline D2: the guard sees through ai.perception: a cone with a range, and line of sight tested against the
# town's buildings (a BVH of the same boxes the navmesh is baked from).
comptime GUARD_SIGHT_RANGE = Real(30.0)
comptime GUARD_FOV_DEG = Real(110.0)
comptime GUARD_MEMORY_TICKS = 120  # 2 s: the guard keeps chasing a player it saw this recently
comptime GUARD_EYE = Real(1.7)


struct TownBt(BtHost):
    """The residents' BtHost: reads each resident's state (arrived, player near) and writes a command (a corner, stop, or
    keep); the town applies the commands after the tree has ticked. Counts action changes (state transitions)."""
    var arrived: List[Bool]
    var near: List[Bool]
    var goal: List[Int]
    var cmd: List[Int]
    var last: List[Int]
    var transitions: Int

    def __init__(out self, goals: List[Int]):
        var n = len(goals)
        self.arrived = List[Bool](length=n, fill=False)
        self.near = List[Bool](length=n, fill=False)
        self.goal = goals.copy()
        self.cmd = List[Int](length=n, fill=CMD_KEEP)
        self.last = List[Int](length=n, fill=-1)
        self.transitions = 0

    def run(mut self, agent: Int, action: Int, mut bb: Blackboard) -> Int:
        if self.last[agent] != action:
            self.transitions += 1
            self.last[agent] = action
        if action == ACT_WALK:
            self.cmd[agent] = self.goal[agent]
            return SUCCESS if self.arrived[agent] else RUNNING
        if action == ACT_NEXT:
            self.goal[agent] = (self.goal[agent] + 1) % 4
            self.arrived[agent] = False
            self.cmd[agent] = self.goal[agent]
            return SUCCESS
        self.cmd[agent] = CMD_STOP  # ACT_WATCH
        return RUNNING

    def abort(mut self, agent: Int, action: Int, mut bb: Blackboard):
        pass

    def check(mut self, agent: Int, cond: Int, bb: Blackboard) -> Bool:
        return self.near[agent] if cond == COND_PLAYER_NEAR else False

    def service(mut self, agent: Int, svc: Int, mut bb: Blackboard):
        pass


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
    nav_tri(verts, tris, Vec3(a, 0.0, a, 0.0), Vec3(a, 0.0, b, 0.0), Vec3(b, 0.0, a, 0.0))
    nav_tri(verts, tris, Vec3(b, 0.0, a, 0.0), Vec3(a, 0.0, b, 0.0), Vec3(b, 0.0, b, 0.0))
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
    var tree: BehaviorTree  # D1: shared by every resident
    var bt_states: List[BtState]
    var bbs: List[Blackboard]
    var bt: TownBt
    var applied: List[Int]  # the command last given to each resident's crowd agent (a corner, or CMD_STOP)
    var perception: Perception  # D2: the guard is observer 0, the player target 0
    var bvh: BVH[3]  # the town's buildings, for the guard's line of sight
    var tick: Int
    var guard_fwd: Vec3
    var guard_sees: Bool  # the guard saw the player this tick (in its cone, in range, nothing in between)

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
        # D1: the residents' tree
        self.tree = BehaviorTree()
        var root = self.tree.selector(True)
        var watch = self.tree.sequence()
        var c_near = self.tree.check(COND_PLAYER_NEAR)
        var a_watch = self.tree.action(ACT_WATCH)
        self.tree.add_child(watch, c_near)
        self.tree.add_child(watch, a_watch)
        var patrol = self.tree.sequence()
        var a_walk = self.tree.action(ACT_WALK)
        var w_idle = self.tree.wait(IDLE_TICKS)
        var a_next = self.tree.action(ACT_NEXT)
        self.tree.add_child(patrol, a_walk)
        self.tree.add_child(patrol, w_idle)
        self.tree.add_child(patrol, a_next)
        self.tree.add_child(root, watch)
        self.tree.add_child(root, patrol)
        self.tree.set_root(root)
        self.tree.validate()
        self.bt_states = List[BtState]()
        self.bbs = List[Blackboard]()
        for _ in range(RESIDENTS):
            self.bt_states.append(BtState(self.tree))
            self.bbs.append(Blackboard(1))
        self.bt = TownBt(self.goal)
        self.applied = self.goal.copy()
        # D2: the guard's sight
        self.perception = Perception()
        _ = self.perception.add_observer(self.crowd.pos[self.guard], Vec3(0.0, 0.0, -1.0, 0.0), 1,
                                         SenseConfig(GUARD_SIGHT_RANGE, GUARD_FOV_DEG, 0.0, GUARD_MEMORY_TICKS, GUARD_EYE))
        _ = self.perception.add_target(Vec3(0.0, 0.0, 0.0, 0.0), 0)
        var aabbs = List[AABB[3]]()
        var proxies = List[Int]()
        for i in range(len(boxes)):
            aabbs.append(AABB[3](boxes[i].c - boxes[i].h, boxes[i].c + boxes[i].h))
            proxies.append(i)
        self.bvh = BVH[3]()
        self.bvh.build_boxes(aabbs, proxies, sah=True)
        self.tick = 0
        self.guard_fwd = Vec3(0.0, 0.0, -1.0, 0.0)
        self.guard_sees = False

    def look(mut self, guard_pos: Vec3, fwd: Vec3, player: Vec3) raises -> Bool:
        """D2: one sight query from the guard: the pairs in its cone and range (Perception.sight_candidates), each ray
        tested against the buildings' BVH, the result committed to the guard's memory. True if the player was seen now."""
        self.perception.set_observer(0, guard_pos, fwd)
        self.perception.set_target(0, player)
        var n = self.perception.sight_candidates()
        var vis = List[Bool]()
        var seen = False
        for i in range(n):
            var a = self.perception.ray_from[i]
            var d = self.perception.ray_to[i] - a
            var l = (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]) ** Real(0.5)
            var blocked = False
            if l > Real(1e-6):
                blocked = self.bvh.raycast(Ray[3](a, d / l, l)).hit
            vis.append(not blocked)
            if not blocked:
                seen = True
        self.perception.commit_sight(vis, self.tick)
        return seen

    def step(mut self, dt: Real, player: Vec3) raises:
        """One tick. D1: each resident's behavior tree ticks, then its command is applied to its crowd agent. D2: the guard
        looks for the player; it chases a player it has seen within GUARD_MEMORY_TICKS while the player is in the square,
        and patrols the loop otherwise."""
        self.tick += 1
        for k in range(RESIDENTS):
            self.bt.arrived[k] = self.crowd.arrived[k]
            var p = self.crowd.pos[k]
            var dx = p[0] - player[0]
            var dz = p[2] - player[2]
            self.bt.near[k] = dx * dx + dz * dz < WATCH_R * WATCH_R
            self.bt.cmd[k] = CMD_KEEP
            _ = bt_tick(self.tree, self.bt_states[k], self.bt, k, self.bbs[k])
            var c = self.bt.cmd[k]
            if c == CMD_STOP and self.applied[k] != CMD_STOP:
                _ = self.crowd.set_target(self.mesh, k, self.crowd.pos[k])
                self.applied[k] = CMD_STOP
            elif c >= 0 and c != self.applied[k]:
                _ = self.crowd.set_target(self.mesh, k, corner(c))
                self.applied[k] = c
            self.goal[k] = self.bt.goal[k]
        var gv = self.crowd.vel[self.guard]
        var sp = (gv[0] * gv[0] + gv[1] * gv[1]) ** Real(0.5)
        if sp > Real(0.1):
            self.guard_fwd = Vec3(gv[0] / sp, 0.0, gv[1] / sp, 0.0)
        self.perception.forget(self.tick)
        self.guard_sees = self.look(self.crowd.pos[self.guard], self.guard_fwd, player)
        if self.perception.best_target(0) >= 0 and inside_square(player):
            _ = self.crowd.set_target(self.mesh, self.guard, player)  # a target off the mesh is refused; the guard keeps its last
        else:
            if self.crowd.arrived[self.guard]:
                self.guard_goal = (self.guard_goal + 1) % 4
            _ = self.crowd.set_target(self.mesh, self.guard, corner(self.guard_goal))
        self.crowd.step(self.mesh, dt)

    def watching(self) -> Int:
        """D1: residents whose tree is in the watch branch (stopped for the player)."""
        var n = 0
        for k in range(RESIDENTS):
            if self.applied[k] == CMD_STOP:
                n += 1
        return n

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
