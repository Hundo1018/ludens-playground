"""Arena: a small 3D game, collect and dodge. All of the game's rules, with no GPU, window or sound in it.

You walk a capsule around a walled arena and pick up 8 gold spheres before 90 seconds run out. Two chasers hunt you,
a bar sweeps the middle of the floor, and after the 4th sphere crates start to rain. Three hits end the run;
each hit takes 25 of 100 health and gives one second of immunity.

What the engine does here, so the sample covers it and a reader can find the call:
  - `EmbedWorld`: every body (boxes, a hinge-joint bar, capsules), `touching`, `raycast`, `apply_impulse`, `hash`.
  - `gameplay.phys_character.DynamicCharacter`: the player and the chasers walk on a spring-damper over the floor.
  - `gameplay.camera_rig.SpringArm`: the chase camera, sphere-cast against the walls.
  - `ai.bt` + `ai.steering`: each chaser runs a reactive behavior tree: see the player -> seek, else hunt along a path,
    else wander; `nav` bakes the navmesh and `PolyFunnel` finds the paths.
  - `gameplay.rules`: health, the damage and the one-second immunity effect.
  - `gameplay.flow` (inside `GameFlow`): the play / pause state stack and the flags; `scheduler`: timers and the RNG.
  - `game.eventsheet`: the rain of crates is written as an event sheet, not as code.

Determinism: the same `Intent` per frame gives the same `hash()`. The camera is outside the hashed state. The player's
direction uses the camera yaw, so a script that keeps the yaw at 0 reproduces exactly (`tests/arena.mojo`)."""
from ai.blackboard import Blackboard, CMP_TRUE
from ai.bt import BehaviorTree, BtState, BtHost, bt_tick, RUNNING
from ai.steering import seek
from embed.world import EmbedWorld, pack_body
from game.eventsheet import Sheet
from game.intent import Intent
from gameplay.camera_rig import SpringArm
from gameplay.checkpoint import GameFlow
from gameplay.flow import FLAG_INT, TICK_ALL
from gameplay.phys_character import DynamicCharacter
from gameplay.rules import Rules, Actor, EffectDef, KIND_DURATION, OP_ADD, STACK_REFRESH
from geometry.quat import Quat
from geometry.trig import sin, cos
from geometry.vec import Real, Vec3
from nav.heightfield import NavBakeConfig
from nav.navmesh import NavMesh, bake_navmesh
from nav.nav_input import nav_tri, nav_box
from nav.path import NavPath, PolyFunnel
from physics.rigid6 import QuatBody6, Inertia3
from procedural.camera_math import CameraPose
from scheduler.timers import TimerHeap, TimerFire
from std.math import sqrt
from game.draw_item import DrawItem, MAT_COLOR, MAT_UV, MAT_TRIPLANAR, MAT_SKY  # re-exported: hosts import them from here

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0.0, -9.81, 0.0, 0.0)

comptime STATUS_PLAYING = 0
comptime STATUS_WON = 1
comptime STATUS_LOST = 2

comptime FLOW_PLAY = 0
comptime FLOW_PAUSE = 1

comptime N_ITEMS = 8
comptime N_CHASERS = 2
comptime MAX_HEALTH = 100
comptime HIT_DAMAGE = 25
comptime TIME_LIMIT_TICKS = 90 * 60
comptime BAR_OMEGA: Real = 1.6
comptime BAR_OMEGA_FAST: Real = 2.4
comptime PLAYER_SPEED: Real = 5.5
comptime JUMP_IMPULSE: Real = 390.0  # 80 kg * 4.9 m/s, about 1.2 m up

comptime TIMER_TIME_UP = 1
comptime TIMER_FAST = 2
comptime TIMER_REPATH = 3
comptime REPATH_TICKS = 20

# collision categories (`EmbedWorld.set_layer`) and the ray mask that sees the world and the player
comptime CAT_WORLD: UInt32 = 1
comptime CAT_PLAYER: UInt32 = 2
comptime CAT_CHASER: UInt32 = 4
comptime ALL_LAYERS: UInt32 = 0xFFFFFFFF
comptime SIGHT_MASK: UInt32 = 3

comptime TAG_HURT: UInt64 = 1

# sound cues, one per thing that happened this frame (`Arena.take_cues`)
comptime CUE_PICKUP = 1
comptime CUE_HIT = 2
comptime CUE_JUMP = 3
comptime CUE_WIN = 4
comptime CUE_LOSE = 5
comptime CUE_RAIN = 6

comptime FNV_OFFSET = UInt64(0xCBF29CE484222325)
comptime FNV_PRIME = UInt64(0x100000001B3)

# What falls from the sky once 4 spheres are in: written as an event sheet, so the rule is data, not code.
comptime SHEET = """
event 1
  when pressed pickup
  do add collected 1
event 2 once
  when var collected >= 4
  do spawn_box rain1 -5 9 -3 0.45 0.45 0.45 4
  do spawn_box rain2 5 9 3 0.45 0.45 0.45 4
  do spawn_box rain3 0 11 -6 0.45 0.45 0.45 4
  do set rain_on 1
  do emit rain
  do sound 6
"""


@fieldwise_init
struct Prop(Copyable, Movable):
    """A box that is part of the level: static scenery, a crate, the bar."""

    var handle: Int64
    var half: Vec3
    var color: Vec3


struct ChaserHost(BtHost):
    """What the chasers' behavior tree can do: each action sets that agent's wished velocity."""

    var pos: List[Vec3]
    var vel: List[Vec3]
    var target: List[Vec3]  # next corner of the path
    var wish: List[Vec3]
    var player: Vec3

    def __init__(out self, n: Int):
        self.pos = List[Vec3]()
        self.vel = List[Vec3]()
        self.target = List[Vec3]()
        self.wish = List[Vec3]()
        for _ in range(n):
            self.pos.append(Vec3(0.0, 0.0, 0.0, 0.0))
            self.vel.append(Vec3(0.0, 0.0, 0.0, 0.0))
            self.target.append(Vec3(0.0, 0.0, 0.0, 0.0))
            self.wish.append(Vec3(0.0, 0.0, 0.0, 0.0))
        self.player = Vec3(0.0, 0.0, 0.0, 0.0)

    def run(mut self, agent: Int, action: Int, mut bb: Blackboard) -> Int:
        # action 0: the player is in sight, run straight at them; 1: follow the path; 2: wander along a path
        var to = self.player if action == 0 else self.target[agent]
        var speed: Real = 4.2 if action == 0 else 3.4
        var w = seek(self.pos[agent], self.vel[agent], to, speed) + self.vel[agent]
        self.wish[agent] = Vec3(w[0], 0.0, w[2], 0.0)
        return RUNNING

    def abort(mut self, agent: Int, action: Int, mut bb: Blackboard):
        pass

    def check(mut self, agent: Int, cond: Int, bb: Blackboard) -> Bool:
        return False

    def service(mut self, agent: Int, svc: Int, mut bb: Blackboard):
        pass


def _mix(h: UInt64, v: UInt64) -> UInt64:
    var x = h
    for i in range(8):
        x = (x ^ ((v >> UInt64(i * 8)) & UInt64(0xFF))) * FNV_PRIME
    return x




def _make_mesh() raises -> NavMesh:
    """The navmesh: the floor plus the two long walls (the outer walls are the floor's edge)."""
    var verts = List[Vec3]()
    var tris = List[Int]()
    nav_tri(verts, tris, Vec3(-20.0, 0.0, -20.0, 0.0), Vec3(-20.0, 0.0, 20.0, 0.0), Vec3(20.0, 0.0, -20.0, 0.0))
    nav_tri(verts, tris, Vec3(20.0, 0.0, -20.0, 0.0), Vec3(-20.0, 0.0, 20.0, 0.0), Vec3(20.0, 0.0, 20.0, 0.0))
    nav_box(verts, tris, Vec3(-4.0, 1.0, -8.0, 0.0), Vec3(10.0, 1.0, 0.4, 0.0))
    nav_box(verts, tris, Vec3(4.0, 1.0, 8.0, 0.0), Vec3(10.0, 1.0, 0.4, 0.0))
    return bake_navmesh(verts, tris, NavBakeConfig(0.25, 0.1, 1.8, 0.3, 0.4, 45.0, 16))


struct Arena(Movable):
    var world: EmbedWorld
    var player: DynamicCharacter
    var player_h: Int64
    var chasers: List[DynamicCharacter]
    var chaser_h: List[Int64]
    var tree: BehaviorTree
    var bt_state: List[BtState]
    var bb: List[Blackboard]
    var host: ChaserHost
    var mesh: NavMesh
    var paths: List[NavPath]
    var path_at: List[Int]
    var wander: List[Int]  # index into the waypoint list
    var items: List[Vec3]
    var item_taken: List[Bool]
    var props: List[Prop]
    var bar_h: Int64
    var sheet: Sheet
    var rules: Rules
    var actors: List[Actor]
    var hurt_effect: Int
    var flow: GameFlow
    var f_status: Int
    var f_collected: Int
    var heap: TimerHeap
    var arm: SpringArm
    var cam: CameraPose
    var yaw: Real
    var pitch: Real
    var tick: Int
    var score: Int
    var bar_omega: Real
    var pickup_pulse: Bool
    var cues: List[Int]
    var hits: Int
    var hit_ticks: List[Int]  # the tick of every hit the player took
    var chasers_on: Bool  # False freezes the chasers: a test or a practice mode

    def __init__(out self) raises:
        self.world = EmbedWorld(1.0 / 60.0, G)
        self.player_h = 0
        self.chasers = List[DynamicCharacter]()
        self.chaser_h = List[Int64]()
        self.tree = BehaviorTree()
        self.bt_state = List[BtState]()
        self.bb = List[Blackboard]()
        self.host = ChaserHost(N_CHASERS)
        self.paths = List[NavPath]()
        self.path_at = List[Int]()
        self.wander = List[Int]()
        self.items = List[Vec3]()
        self.item_taken = List[Bool]()
        self.props = List[Prop]()
        self.bar_h = 0
        self.sheet = Sheet.parse(String(SHEET))
        self.rules = Rules(0)
        self.actors = List[Actor]()
        self.hurt_effect = 0
        self.flow = GameFlow(20241109)
        self.f_status = 0
        self.f_collected = 0
        self.heap = TimerHeap()
        self.arm = SpringArm(7.0, 0.3, 0.12, 0.9)
        self.yaw = 0
        self.pitch = 0.45
        self.tick = 0
        self.score = 0
        self.bar_omega = BAR_OMEGA
        self.pickup_pulse = False
        self.cues = List[Int]()
        self.hits = 0
        self.hit_ticks = List[Int]()
        self.chasers_on = True
        # the player is made first because the DynamicCharacter must exist before the rest of the fields are used
        self.player = DynamicCharacter.spawn(
            self.world.scene,
            QuatBody6.at_rest(Vec3(0.0, 1.0, 4.5, 0.0), Inertia3.box(80.0, 0.3, 0.9, 0.3)),
            80.0, 0.3, 0.3, 1.0,
        )
        self.mesh = _make_mesh()
        self.cam = CameraPose(Vec3(0.0, 0.0, 0.0, 0.0), Quat(0.0, 0.0, 0.0, 1.0), 0.9, 1.78, 0.1, 500.0)
        self._build()

    def __init__(out self, *, deinit move: Self):
        self.world = move.world^
        self.player = move.player^
        self.player_h = move.player_h
        self.chasers = move.chasers^
        self.chaser_h = move.chaser_h^
        self.tree = move.tree^
        self.bt_state = move.bt_state^
        self.bb = move.bb^
        self.host = move.host^
        self.mesh = move.mesh^
        self.paths = move.paths^
        self.path_at = move.path_at^
        self.wander = move.wander^
        self.items = move.items^
        self.item_taken = move.item_taken^
        self.props = move.props^
        self.bar_h = move.bar_h
        self.sheet = move.sheet^
        self.rules = move.rules^
        self.actors = move.actors^
        self.hurt_effect = move.hurt_effect
        self.flow = move.flow^
        self.f_status = move.f_status
        self.f_collected = move.f_collected
        self.heap = move.heap^
        self.arm = move.arm^
        self.cam = move.cam
        self.yaw = move.yaw
        self.pitch = move.pitch
        self.tick = move.tick
        self.score = move.score
        self.bar_omega = move.bar_omega
        self.pickup_pulse = move.pickup_pulse
        self.cues = move.cues^
        self.hits = move.hits
        self.hit_ticks = move.hit_ticks^
        self.chasers_on = move.chasers_on

    # ----------------------------------------------------------------------------------------------- building

    def _prop(mut self, h: Int64, half: Vec3, color: Vec3):
        self.props.append(Prop(h, half, color))

    def _static_box(mut self, pos: Vec3, half: Vec3, color: Vec3) raises:
        var h = self.world.add_box(pos, half, 0.0, True)
        self.world.set_layer(h, CAT_WORLD, ALL_LAYERS)
        self._prop(h, half, color)

    def _build(mut self) raises:
        var wall = Vec3(0.62, 0.64, 0.76, 0.0)
        # the floor and the four outer walls
        self._static_box(Vec3(0.0, -0.5, 0.0, 0.0), Vec3(20.0, 0.5, 20.0, 0.0), Vec3(0.42, 0.56, 0.42, 0.0))
        self._static_box(Vec3(0.0, 1.5, -20.5, 0.0), Vec3(21.0, 1.5, 0.5, 0.0), wall)
        self._static_box(Vec3(0.0, 1.5, 20.5, 0.0), Vec3(21.0, 1.5, 0.5, 0.0), wall)
        self._static_box(Vec3(-20.5, 1.5, 0.0, 0.0), Vec3(0.5, 1.5, 20.0, 0.0), wall)
        self._static_box(Vec3(20.5, 1.5, 0.0, 0.0), Vec3(0.5, 1.5, 20.0, 0.0), wall)
        # two long walls with gaps at opposite ends: the chasers have to walk around them
        self._static_box(Vec3(-4.0, 1.0, -8.0, 0.0), Vec3(10.0, 1.0, 0.4, 0.0), wall)
        self._static_box(Vec3(4.0, 1.0, 8.0, 0.0), Vec3(10.0, 1.0, 0.4, 0.0), wall)

        # the sweeping bar: a low axle and a bar that turns about the vertical axis on a hinge joint
        var axle = self.world.add_box(Vec3(0.0, 0.15, 0.0, 0.0), Vec3(0.2, 0.15, 0.2, 0.0), 0.0, True)
        self.world.set_layer(axle, CAT_WORLD, ALL_LAYERS)
        self._prop(axle, Vec3(0.2, 0.15, 0.2, 0.0), Vec3(0.55, 0.55, 0.6, 0.0))
        self.bar_h = self.world.add_box(Vec3(0.0, 0.55, 0.0, 0.0), Vec3(3.2, 0.2, 0.2, 0.0), 40.0, False)
        self.world.set_layer(self.bar_h, CAT_WORLD, ALL_LAYERS)
        self._prop(self.bar_h, Vec3(3.2, 0.2, 0.2, 0.0), Vec3(0.95, 0.35, 0.25, 0.0))
        _ = self.world.add_hinge_joint(
            axle, self.bar_h, Vec3(0.0, 0.175, 0.0, 0.0), Vec3(0.0, -0.225, 0.0, 0.0), Vec3(0.0, 1.0, 0.0, 0.0)
        )

        # crates to push around
        var crate_pos = List[Vec3]()
        crate_pos.append(Vec3(6.0, 0.5, -2.0, 0.0))
        crate_pos.append(Vec3(-7.0, 0.5, 3.0, 0.0))
        crate_pos.append(Vec3(8.0, 0.5, 12.0, 0.0))
        crate_pos.append(Vec3(-9.0, 0.5, -12.0, 0.0))
        for i in range(len(crate_pos)):
            var h = self.world.add_box(crate_pos[i], Vec3(0.5, 0.5, 0.5, 0.0), 6.0, False)
            self.world.set_layer(h, CAT_WORLD, ALL_LAYERS)
            self._prop(h, Vec3(0.5, 0.5, 0.5, 0.0), Vec3(0.62, 0.45, 0.28, 0.0))

        # the player, as a body in the world so touching, the hash and the camera see it
        self.player_h = pack_body(self.player.id)
        self.world.set_layer(self.player_h, CAT_PLAYER, ALL_LAYERS)
        # the camera is blocked by the level, not by the player or the chasers
        self.arm.filter.mask = CAT_WORLD

        # chasers: the same kind of body as the player
        var start = List[Vec3]()
        start.append(Vec3(17.0, 1.0, 17.0, 0.0))
        start.append(Vec3(-17.0, 1.0, -17.0, 0.0))
        for i in range(N_CHASERS):
            var c = DynamicCharacter.spawn(
                self.world.scene,
                QuatBody6.at_rest(start[i], Inertia3.box(60.0, 0.3, 0.9, 0.3)),
                60.0, 0.3, 0.3, 1.0,
            )
            var h = pack_body(c.id)
            self.world.set_layer(h, CAT_CHASER, ALL_LAYERS)
            self.chasers.append(c^)
            self.chaser_h.append(h)
            var b = Blackboard(2)
            self.bb.append(b^)
            self.paths.append(NavPath())
            self.path_at.append(0)
            self.wander.append(i * 4)

        # behavior tree: see the player -> run at them; else hunt along a path; else wander. Reactive, so each
        # tick re-checks the conditions and a running branch is dropped when a better one opens up.
        var sel = self.tree.selector(reactive=True)
        var see = self.tree.sequence(reactive=True)
        self.tree.add_child(sel, see)
        self.tree.add_child(see, self.tree.condition(0, CMP_TRUE))
        self.tree.add_child(see, self.tree.action(0))
        var hunt = self.tree.sequence(reactive=True)
        self.tree.add_child(sel, hunt)
        self.tree.add_child(hunt, self.tree.condition(1, CMP_TRUE))
        self.tree.add_child(hunt, self.tree.action(1))
        self.tree.add_child(sel, self.tree.action(2))
        self.tree.set_root(sel)
        self.tree.validate()
        for _ in range(N_CHASERS):
            self.bt_state.append(BtState(self.tree))

        # the 8 spheres
        var spots = List[Vec3]()
        spots.append(Vec3(-15.0, 1.0, -15.0, 0.0))
        spots.append(Vec3(15.0, 1.0, -15.0, 0.0))
        spots.append(Vec3(-15.0, 1.0, 15.0, 0.0))
        spots.append(Vec3(15.0, 1.0, 15.0, 0.0))
        spots.append(Vec3(0.0, 1.0, -14.0, 0.0))
        spots.append(Vec3(0.0, 1.0, 14.0, 0.0))
        spots.append(Vec3(-12.0, 1.0, 0.0, 0.0))
        spots.append(Vec3(12.0, 1.0, 0.0, 0.0))
        for i in range(N_ITEMS):
            self.items.append(spots[i])
            self.item_taken.append(False)

        # rules: 100 health, and a one-second effect that grants the "hurt" tag and blocks itself while it lasts
        self.hurt_effect = self.rules.define(
            EffectDef(KIND_DURATION, 60, 0, 0, OP_ADD, 0, TAG_HURT, TAG_HURT, STACK_REFRESH, 1)
        )
        var a = Actor(1, 1)
        a.attrs.set_base(0, MAX_HEALTH)
        self.actors.append(a^)

        # flow: the play state under any pause, and the two flags that go into the hash
        self.flow.stack.push(FLOW_PLAY, TICK_ALL)
        self.f_status = self.flow.flags.declare("status", FLAG_INT, STATUS_PLAYING)
        self.f_collected = self.flow.flags.declare("collected", FLAG_INT, 0)

        # timers: the clock, the faster bar, and the chasers' path refresh
        _ = self.heap.schedule(TIME_LIMIT_TICKS, TIMER_TIME_UP)
        _ = self.heap.schedule(30 * 60, TIMER_FAST)
        _ = self.heap.schedule(REPATH_TICKS, TIMER_REPATH, REPATH_TICKS)

        self._camera()

    # ----------------------------------------------------------------------------------------------- reading

    def status(self) -> Int:
        return self.flow.flags.get(self.f_status)

    def paused(self) -> Bool:
        return self.flow.stack.top() == FLOW_PAUSE

    def collected(self) -> Int:
        return self.flow.flags.get(self.f_collected)

    def health(self) -> Int:
        return self.actors[0].attrs.base[0]

    def seconds_left(self) -> Int:
        var left = TIME_LIMIT_TICKS - self.tick
        return left // 60 if left > 0 else 0

    def player_pos(self) raises -> Vec3:
        return self.world.state(self.player_h).pos

    def hash(self) -> UInt64:
        """World hash, then the game's own state: tick, status, collected, health, score and the flags."""
        var h = self.world.hash()
        h = _mix(h, UInt64(self.tick))
        h = _mix(h, UInt64(self.status()))
        h = _mix(h, UInt64(self.collected()))
        h = _mix(h, UInt64(self.health()))
        h = _mix(h, UInt64(self.score))
        for i in range(len(self.item_taken)):
            h = _mix(h, UInt64(1 if self.item_taken[i] else 0))
        for b in self.flow.flags.to_bytes():
            h = _mix(h, UInt64(b))
        return h

    def take_cues(mut self) -> List[Int]:
        var out = self.cues.copy()
        self.cues.clear()
        return out^

    def draw_items(self) raises -> List[DrawItem]:
        """Everything on screen, in world space. Boxes carry half extents, spheres a radius in half[0]."""
        var out = List[DrawItem]()
        for p in self.props:
            var s = self.world.state(p.handle)
            out.append(DrawItem(0, s.pos, Float64(s.rot.x), Float64(s.rot.y), Float64(s.rot.z), Float64(s.rot.w), p.half, p.color))
        # the rain boxes the sheet spawned
        if self.sheet.get("rain_on") == 1:
            for name in ["rain1", "rain2", "rain3"]:
                var h = Int64(self.sheet.get(String(name)))
                if self.world.is_alive(h):
                    var s = self.world.state(h)
                    out.append(DrawItem(0, s.pos, Float64(s.rot.x), Float64(s.rot.y), Float64(s.rot.z), Float64(s.rot.w), Vec3(0.45, 0.45, 0.45, 0.0), Vec3(0.85, 0.7, 0.2, 0.0)))
        for i in range(len(self.items)):
            if not self.item_taken[i]:
                out.append(DrawItem(1, self.items[i], 0.0, 0.0, 0.0, 1.0, Vec3(0.35, 0.35, 0.35, 0.0), Vec3(1.0, 0.82, 0.15, 0.0)))
        # the player: a body and a head, tinted while the immunity effect runs
        var hurt = self.actors[0].all_tags(self.rules.defs) & TAG_HURT
        var pcolor = Vec3(0.95, 0.9, 0.9, 0.0) if hurt != 0 else Vec3(0.2, 0.55, 0.95, 0.0)
        self._figure(out, self.player_h, pcolor)
        for i in range(len(self.chaser_h)):
            self._figure(out, self.chaser_h[i], Vec3(0.9, 0.2, 0.25, 0.0))
        return out^

    def _figure(self, mut out: List[DrawItem], h: Int64, color: Vec3) raises:
        var s = self.world.state(h)
        out.append(DrawItem(0, s.pos - Vec3(0.0, 0.1, 0.0, 0.0), 0.0, 0.0, 0.0, 1.0, Vec3(0.3, 0.5, 0.3, 0.0), color))
        out.append(DrawItem(1, s.pos + Vec3(0.0, 0.55, 0.0, 0.0), 0.0, 0.0, 0.0, 1.0, Vec3(0.28, 0.28, 0.28, 0.0), color * 1.15))

    # ----------------------------------------------------------------------------------------------- stepping

    def _camera(mut self) raises:
        self.arm.aim(self.yaw, self.pitch)
        var target = self.world.state(self.player_h).pos + Vec3(0.0, 0.5, 0.0, 0.0) if self.world.is_alive(self.player_h) else Vec3(0.0, 1.0, 0.0, 0.0)
        self.cam = self.arm.update(self.world.scene, target, DT)

    def update(mut self, intent: Intent, frame_dt: Float64) raises:
        """One frame: the camera, then as many fixed ticks as `frame_dt` buys."""
        self.yaw -= intent.look_dx * 0.006
        self.pitch = min(Real(1.2), max(Real(0.1), self.pitch + intent.look_dy * 0.004))
        if intent.pause and self.status() == STATUS_PLAYING:
            if self.paused():
                _ = self.flow.stack.pop()
            else:
                self.flow.stack.push(FLOW_PAUSE, 0)
        if self.flow.stack.ticks(TICK_ALL):
            var first = True
            for _ in range(self.world.ticks_due(frame_dt)):
                self._tick(intent, first and intent.jump)
                first = False
        self._camera()

    def _tick(mut self, intent: Intent, jump: Bool) raises:
        self.tick += 1
        var playing = self.status() == STATUS_PLAYING

        # timers
        var fired = List[TimerFire]()
        self.heap.advance(1, fired)
        for f in fired:
            if f.id == TIMER_TIME_UP and playing:
                self._end(STATUS_LOST)
            elif f.id == TIMER_FAST:
                self.bar_omega = BAR_OMEGA_FAST
            elif f.id == TIMER_REPATH:
                self._repath()
        playing = self.status() == STATUS_PLAYING

        # the player
        var wish = Vec3(0.0, 0.0, 0.0, 0.0)
        if playing:
            var f = Vec3(-sin(self.yaw), 0.0, -cos(self.yaw), 0.0)
            var r = Vec3(cos(self.yaw), 0.0, -sin(self.yaw), 0.0)
            wish = f * intent.forward + r * intent.right
            var len2 = wish[0] * wish[0] + wish[2] * wish[2]
            if len2 > 1.0:
                wish = wish / sqrt(len2)
            wish = wish * PLAYER_SPEED
        self.player.update(self.world.scene, wish, DT, G)
        if playing and jump and self.player.on_ground:
            self.world.apply_impulse(self.player_h, Vec3(0.0, JUMP_IMPULSE, 0.0, 0.0))
            self.cues.append(CUE_JUMP)

        # the chasers
        self._think()
        for i in range(N_CHASERS):
            var w = self.host.wish[i] if (playing and self.chasers_on) else Vec3(0.0, 0.0, 0.0, 0.0)
            self.chasers[i].update(self.world.scene, w, DT, G)

        # the bar keeps turning
        self.world.set_velocity(self.bar_h, Vec3(0.0, 0.0, 0.0, 0.0), Vec3(0.0, self.bar_omega, 0.0, 0.0))

        # the event sheet sees the pickup of the previous tick, then the world steps
        self.sheet.set_input("pickup", self.pickup_pulse)
        self.pickup_pulse = False
        self.sheet.step(self.world)
        for cue in self.sheet.take_sounds():  # the sheet's `do sound N`: N is one of the CUE_ numbers
            self.cues.append(cue)
        self.world.physics_tick()
        self.rules.step(self.actors)

        if playing:
            self._pickups()
            self._damage()
            if self.actors[0].dead:
                self._end(STATUS_LOST)

    def _think(mut self) raises:
        """Fill each chaser's blackboard (can it see the player, is there somewhere to hunt) and tick its tree."""
        var pp = self.world.state(self.player_h).pos
        self.host.player = pp
        for i in range(N_CHASERS):
            var s = self.world.state(self.chaser_h[i])
            self.host.pos[i] = s.pos
            self.host.vel[i] = s.vel
            var d = pp - s.pos
            var dist = sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2])
            var sees = False
            if dist < 16.0 and dist > 0.01:
                var r = self.world.raycast(s.pos, d, dist, SIGHT_MASK)
                sees = r.body == self.player_h
            self.bb[i].set_flag(0, sees)
            self.bb[i].set_flag(1, dist < 26.0 and self.paths[i].found)
            # the next corner of this chaser's path, flat at the chaser's height
            var n = len(self.paths[i].points)
            if self.paths[i].found and n > 0:
                var k = self.path_at[i]
                while k < n - 1:
                    var dx = self.paths[i].points[k][0] - s.pos[0]
                    var dz = self.paths[i].points[k][2] - s.pos[2]
                    if dx * dx + dz * dz > 0.5:
                        break
                    k += 1
                self.path_at[i] = k
                var c = self.paths[i].points[k]
                self.host.target[i] = Vec3(c[0], s.pos[1], c[2], 0.0)
            _ = bt_tick(self.tree, self.bt_state[i], self.host, i, self.bb[i])

    def _repath(mut self) raises:
        """Every 20 ticks: a path to the player if they are near, else to this chaser's next waypoint."""
        var pf = PolyFunnel()
        var pp = self.world.state(self.player_h).pos
        for i in range(N_CHASERS):
            var s = self.world.state(self.chaser_h[i])
            var goal = Vec3(pp[0], 0.0, pp[2], 0.0)
            var d = pp - s.pos
            if d[0] * d[0] + d[2] * d[2] > 26.0 * 26.0 or self.world.state(self.player_h).pos[1] < -1.0:
                # too far to hunt: wander between the sphere spots
                if self.path_at[i] >= len(self.paths[i].points) - 1:
                    self.wander[i] = (self.wander[i] + 1 + Int(self.flow.rng.next_u32() % 3)) % N_ITEMS
                var w = self.items[self.wander[i]]
                goal = Vec3(w[0], 0.0, w[2], 0.0)
            self.paths[i] = pf.find(self.mesh, Vec3(s.pos[0], 0.0, s.pos[2], 0.0), goal)
            self.path_at[i] = 1 if len(self.paths[i].points) > 1 else 0

    def _pickups(mut self) raises:
        var pp = self.world.state(self.player_h).pos
        for i in range(len(self.items)):
            if self.item_taken[i]:
                continue
            var d = self.items[i] - pp
            if d[0] * d[0] + d[2] * d[2] < 1.0 and abs(d[1]) < 1.4:
                self.item_taken[i] = True
                self.flow.flags.set(self.f_collected, self.flow.flags.get(self.f_collected) + 1)
                self.score += 100
                self.pickup_pulse = True
                self.cues.append(CUE_PICKUP)
        if self.collected() >= N_ITEMS:
            self.score += self.seconds_left() * 10
            self._end(STATUS_WON)

    def _hurt(mut self, source: Int, from_pos: Vec3) raises:
        """A hit: blocked while the immunity effect runs, otherwise 25 health and a shove away from the source."""
        if self.rules.apply(self.actors[0], self.hurt_effect, source):
            _ = self.rules.damage(self.actors[0], 0, HIT_DAMAGE, 0)
            self.hits += 1
            self.hit_ticks.append(self.tick)
            self.cues.append(CUE_HIT)
            var pp = self.world.state(self.player_h).pos
            var away = pp - from_pos
            away = Vec3(away[0], 0.0, away[2], 0.0)
            var l = sqrt(away[0] * away[0] + away[2] * away[2])
            if l > 0.001:
                self.world.apply_impulse(self.player_h, away * (180.0 / l) + Vec3(0.0, 60.0, 0.0, 0.0))

    def _damage(mut self) raises:
        for i in range(N_CHASERS):
            if self.world.touching(self.player_h, self.chaser_h[i]):
                self._hurt(10 + i, self.world.state(self.chaser_h[i]).pos)
        if self.world.touching(self.player_h, self.bar_h):
            self._hurt(20, self.world.state(self.bar_h).pos)
        if self.sheet.get("rain_on") == 1:
            for name in ["rain1", "rain2", "rain3"]:
                var h = Int64(self.sheet.get(String(name)))
                if self.world.touching(self.player_h, h):
                    self._hurt(30, self.world.state(h).pos)

    def _end(mut self, status: Int) raises:
        self.flow.flags.set(self.f_status, status)
        self.cues.append(CUE_WIN if status == STATUS_WON else CUE_LOSE)
