"""Frontier: one large streamed world, the showcase sample. Rules only: no GPU, window or sound in here.

A 512 m by 512 m map in 32 m cells (16 by 16 = 256). Only the cells near the player are in the physics scene:
`gameplay.large_world.WorldPartition` loads a cell's bodies when the player comes within LOAD_R of it and takes them
out again, remembering pose and velocity, when the player is UNLOAD_R away. What is drawn is cut down a second time
by the camera frustum (`procedural.camera_math.Frustum`).

The map has a hub in the middle and four zones around it, one per quadrant. In this first stage a zone is only its
ground colour and its kind of scenery; each zone's own simulation (destruction, cloth, crowds, animation, netcode)
comes in later stages.

What the engine does here:
  - `EmbedWorld`: the ground, the border walls and the player; `hash`.
  - `WorldPartition`: every prop is a `BodySpec`; `update` moves specs in and out of the scene by cell.
  - `DynamicCharacter` and `SpringArm`: the player and the chase camera, as in the arena.
  - `Frustum`: `aabb_visible` for ground tiles, `sphere_visible` for props.

Determinism: the same `Intent` per frame gives the same `hash()`. Streaming runs on tick numbers, not on time."""
from embed.world import EmbedWorld, pack_body
from game.arena import DrawItem
from game.intent import Intent
from gameplay.camera_rig import SpringArm
from gameplay.large_world import WorldPartition, WorldPos, BodySpec, SPEC_BOX, SPEC_SPHERE, EV_LOAD
from gameplay.phys_character import DynamicCharacter
from geometry.quat import Quat
from geometry.trig import sin, cos
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from procedural.camera_math import CameraPose, Frustum
from std.math import sqrt

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0.0, -9.81, 0.0, 0.0)

comptime CELL: Float64 = 32.0
comptime CELLS_PER_SIDE = 16
comptime HALF_MAP: Float64 = 256.0
comptime LOAD_R: Float64 = 56.0
comptime UNLOAD_R: Float64 = 72.0
comptime STREAM_TICKS = 10  # the partition is updated every this many ticks
comptime HUB_HALF: Float64 = 48.0

comptime ZONE_HUB = 0
comptime ZONE_QUARRY = 1  # +x, -z
comptime ZONE_CAMP = 2  # -x, -z
comptime ZONE_TOWN = 3  # +x, +z
comptime ZONE_TRAINING = 4  # -x, +z

comptime PLAYER_SPEED: Real = 9.0
comptime JUMP_IMPULSE: Real = 390.0
comptime CAT_WORLD: UInt32 = 1
comptime ALL_LAYERS: UInt32 = 0xFFFFFFFF

comptime STAT_CELLS_LOADED = 0
comptime STAT_CELLS_TOTAL = 1
comptime STAT_BODIES_LIVE = 2
comptime STAT_BODIES_TOTAL = 3
comptime STAT_DRAWN = 4
comptime STAT_CULLED = 5
comptime STAT_LOADS = 6
comptime STAT_UNLOADS = 7
comptime STAT_ZONE = 8
comptime STAT_TICK = 9

comptime FNV_PRIME = UInt64(0x100000001B3)


def zone_of(x: Float64, z: Float64) -> Int:
    if abs(x) < HUB_HALF and abs(z) < HUB_HALF:
        return ZONE_HUB
    if z < 0:
        return ZONE_QUARRY if x >= 0 else ZONE_CAMP
    return ZONE_TOWN if x >= 0 else ZONE_TRAINING


def zone_name(zone: Int) -> String:
    if zone == ZONE_QUARRY:
        return "QUARRY"
    if zone == ZONE_CAMP:
        return "CAMP"
    if zone == ZONE_TOWN:
        return "TOWN"
    if zone == ZONE_TRAINING:
        return "TRAINING"
    return "HUB"


def zone_color(zone: Int) -> Vec3:
    if zone == ZONE_QUARRY:
        return Vec3(0.55, 0.52, 0.48, 0.0)
    if zone == ZONE_CAMP:
        return Vec3(0.42, 0.58, 0.36, 0.0)
    if zone == ZONE_TOWN:
        return Vec3(0.56, 0.56, 0.6, 0.0)
    if zone == ZONE_TRAINING:
        return Vec3(0.7, 0.62, 0.42, 0.0)
    return Vec3(0.36, 0.5, 0.62, 0.0)


def _mix(h: UInt64, v: UInt64) -> UInt64:
    return (h ^ v) * FNV_PRIME


struct Lcg:
    """A small generator seeded per cell, so a cell's scenery depends only on its coordinates."""

    var s: UInt64

    def __init__(out self, ix: Int, iz: Int):
        self.s = _mix(_mix(UInt64(0xCBF29CE484222325), UInt64(ix + 1000)), UInt64(iz + 1000)) | 1

    def unit(mut self) -> Float64:
        """In [0, 1)."""
        self.s = self.s * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        return Float64(Int((self.s >> 40) & UInt64(0xFFFFFF))) / 16777216.0

    def span(mut self, lo: Float64, hi: Float64) -> Float64:
        return lo + (hi - lo) * self.unit()


struct Frontier(Movable):
    var world: EmbedWorld
    var part: WorldPartition
    var spec_color: List[Vec3]  # parallel to part.specs
    var walls: List[DrawItem]
    var player: DynamicCharacter
    var player_h: Int64
    var arm: SpringArm
    var cam: CameraPose
    var yaw: Real
    var pitch: Real
    var tick: Int
    var loads: Int
    var unloads: Int
    var drawn: Int
    var culled: Int
    var culling: Bool  # False draws every loaded item: what culling saves can be measured

    def __init__(out self) raises:
        self.world = EmbedWorld(1.0 / 60.0, G)
        self.part = WorldPartition(CELL, LOAD_R, UNLOAD_R)
        self.spec_color = List[Vec3]()
        self.walls = List[DrawItem]()
        self.player_h = 0
        self.arm = SpringArm(8.0, 0.3, 0.12, 0.9)
        self.yaw = 0
        self.pitch = 0.4
        self.tick = 0
        self.loads = 0
        self.unloads = 0
        self.drawn = 0
        self.culled = 0
        self.culling = True
        self.player = DynamicCharacter.spawn(
            self.world.scene,
            QuatBody6.at_rest(Vec3(0.0, 1.0, 0.0, 0.0), Inertia3.box(80.0, 0.3, 0.9, 0.3)),
            80.0, 0.3, 0.3, 1.0,
        )
        self.cam = CameraPose(Vec3(0.0, 0.0, 0.0, 0.0), Quat(0.0, 0.0, 0.0, 1.0), 0.9, 1.78, 0.1, 400.0)
        self._build()

    def __init__(out self, *, deinit move: Self):
        self.world = move.world^
        self.part = move.part^
        self.spec_color = move.spec_color^
        self.walls = move.walls^
        self.player = move.player^
        self.player_h = move.player_h
        self.arm = move.arm^
        self.cam = move.cam
        self.yaw = move.yaw
        self.pitch = move.pitch
        self.tick = move.tick
        self.loads = move.loads
        self.unloads = move.unloads
        self.drawn = move.drawn
        self.culled = move.culled
        self.culling = move.culling

    # ------------------------------------------------------------------------------------------------- building

    def _spec(mut self, kind: Int, pos: Vec3, half: Vec3, mass: Real, color: Vec3) raises:
        var is_static = mass == 0
        _ = self.part.add(BodySpec(
            kind, half, mass, is_static, WorldPos(Float64(pos[0]), Float64(pos[1]), Float64(pos[2])),
            Quat(0.0, 0.0, 0.0, 1.0), Vec3(0.0, 0.0, 0.0, 0.0), Vec3(0.0, 0.0, 0.0, 0.0),
        ))
        self.spec_color.append(color)

    def _wall(mut self, pos: Vec3, half: Vec3) raises:
        var h = self.world.add_box(pos, half, 0.0, True)
        self.world.set_layer(h, CAT_WORLD, ALL_LAYERS)
        self.walls.append(DrawItem(0, pos, 0.0, 0.0, 0.0, 1.0, half, Vec3(0.3, 0.32, 0.38, 0.0)))

    def _cell(mut self, ix: Int, iz: Int) raises:
        """The scenery of one cell. Positions keep 3 m clear of the cell's edge so a prop belongs to one cell."""
        var x0 = Float64(ix) * CELL
        var z0 = Float64(iz) * CELL
        var zone = zone_of(x0 + CELL * 0.5, z0 + CELL * 0.5)
        var rng = Lcg(ix, iz)
        var base = zone_color(zone)
        if zone == ZONE_HUB:
            # four pillars
            for _ in range(4):
                var x = Real(rng.span(x0 + 4, x0 + CELL - 4))
                var z = Real(rng.span(z0 + 4, z0 + CELL - 4))
                if abs(x) < 6 and abs(z) < 6:
                    continue  # the player starts here
                self._spec(SPEC_BOX, Vec3(x, 2.0, z, 0.0), Vec3(0.5, 2.0, 0.5, 0.0), 0, Vec3(0.8, 0.82, 0.88, 0.0))
        elif zone == ZONE_QUARRY:
            # rocks, and stacks of blocks to push over
            for _ in range(5):
                var s = Real(rng.span(0.8, 2.2))
                self._spec(SPEC_BOX, Vec3(Real(rng.span(x0 + 4, x0 + CELL - 4)), s * 0.7, Real(rng.span(z0 + 4, z0 + CELL - 4)), 0.0),
                           Vec3(s, s * 0.7, s * 0.9, 0.0), 0, base * 0.75)
            for _ in range(2):
                var x = Real(rng.span(x0 + 5, x0 + CELL - 5))
                var z = Real(rng.span(z0 + 5, z0 + CELL - 5))
                for level in range(3):
                    self._spec(SPEC_BOX, Vec3(x, 0.5 + Real(level), z, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 20.0, Vec3(0.85, 0.6, 0.3, 0.0))
        elif zone == ZONE_CAMP:
            # posts, and balls that roll
            for _ in range(5):
                self._spec(SPEC_BOX, Vec3(Real(rng.span(x0 + 4, x0 + CELL - 4)), 1.5, Real(rng.span(z0 + 4, z0 + CELL - 4)), 0.0),
                           Vec3(0.15, 1.5, 0.15, 0.0), 0, Vec3(0.5, 0.35, 0.2, 0.0))
            for _ in range(4):
                self._spec(SPEC_SPHERE, Vec3(Real(rng.span(x0 + 4, x0 + CELL - 4)), 0.5, Real(rng.span(z0 + 4, z0 + CELL - 4)), 0.0),
                           Vec3(0.5, 0.5, 0.5, 0.0), 10.0, Vec3(0.9, 0.3, 0.3, 0.0))
        elif zone == ZONE_TOWN:
            # four buildings on a 2 by 2 grid, with streets between them
            for bx in range(2):
                for bz in range(2):
                    var hx = Real(rng.span(3.5, 5.5))
                    var hz = Real(rng.span(3.5, 5.5))
                    var hy = Real(rng.span(2.0, 7.0))
                    var shade = Real(rng.span(0.7, 1.1))
                    self._spec(SPEC_BOX, Vec3(Real(x0 + 8.0 + 16.0 * Float64(bx)), hy, Real(z0 + 8.0 + 16.0 * Float64(bz)), 0.0),
                               Vec3(hx, hy, hz, 0.0), 0, base * shade)
            for _ in range(2):
                self._spec(SPEC_BOX, Vec3(Real(x0 + 16.0 + rng.span(-1.5, 1.5)), 0.4, Real(z0 + 16.0 + rng.span(-1.5, 1.5)), 0.0),
                           Vec3(0.4, 0.4, 0.4, 0.0), 8.0, Vec3(0.3, 0.45, 0.8, 0.0))
        else:
            # low platforms and a few crates
            for _ in range(4):
                var hx = Real(rng.span(1.5, 3.0))
                self._spec(SPEC_BOX, Vec3(Real(rng.span(x0 + 5, x0 + CELL - 5)), 0.25, Real(rng.span(z0 + 5, z0 + CELL - 5)), 0.0),
                           Vec3(hx, 0.25, hx, 0.0), 0, base * 0.8)
            for _ in range(2):
                self._spec(SPEC_BOX, Vec3(Real(rng.span(x0 + 4, x0 + CELL - 4)), 0.5, Real(rng.span(z0 + 4, z0 + CELL - 4)), 0.0),
                           Vec3(0.5, 0.5, 0.5, 0.0), 15.0, Vec3(0.9, 0.8, 0.3, 0.0))

    def _build(mut self) raises:
        self.player_h = pack_body(self.player.id)
        self.world.set_layer(self.player_h, 2, ALL_LAYERS)
        self.arm.filter.mask = CAT_WORLD  # the arm is cast against the world, not against the player it follows
        var hm = Real(HALF_MAP)
        # the ground is one static box and is always in the scene; what streams is what stands on it
        var ground = self.world.add_box(Vec3(0.0, -0.5, 0.0, 0.0), Vec3(hm, 0.5, hm, 0.0), 0.0, True)
        self.world.set_layer(ground, CAT_WORLD, ALL_LAYERS)
        self._wall(Vec3(0.0, 2.0, -hm - 0.5, 0.0), Vec3(hm + 1.0, 2.0, 0.5, 0.0))
        self._wall(Vec3(0.0, 2.0, hm + 0.5, 0.0), Vec3(hm + 1.0, 2.0, 0.5, 0.0))
        self._wall(Vec3(-hm - 0.5, 2.0, 0.0, 0.0), Vec3(0.5, 2.0, hm, 0.0))
        self._wall(Vec3(hm + 0.5, 2.0, 0.0, 0.0), Vec3(0.5, 2.0, hm, 0.0))
        var half_cells = CELLS_PER_SIDE // 2
        for ix in range(-half_cells, half_cells):
            for iz in range(-half_cells, half_cells):
                self._cell(ix, iz)
        self._stream()
        self._camera()

    # -------------------------------------------------------------------------------------------------- queries

    def player_pos(self) raises -> Vec3:
        return self.world.state(self.player_h).pos

    def zone(self) raises -> Int:
        var p = self.player_pos()
        return zone_of(Float64(p[0]), Float64(p[2]))

    def bodies_live(self) -> Int:
        var n = 0
        for l in self.part.live:
            if l:
                n += 1
        return n

    def stat(self, which: Int) raises -> Int:
        if which == STAT_CELLS_LOADED:
            return len(self.part.loaded)
        if which == STAT_CELLS_TOTAL:
            return CELLS_PER_SIDE * CELLS_PER_SIDE
        if which == STAT_BODIES_LIVE:
            return self.bodies_live()
        if which == STAT_BODIES_TOTAL:
            return len(self.part.specs)
        if which == STAT_DRAWN:
            return self.drawn
        if which == STAT_CULLED:
            return self.culled
        if which == STAT_LOADS:
            return self.loads
        if which == STAT_UNLOADS:
            return self.unloads
        if which == STAT_ZONE:
            return self.zone()
        if which == STAT_TICK:
            return self.tick
        return -1

    def hash(self) -> UInt64:
        var h = self.world.hash()
        h = _mix(h, UInt64(self.tick))
        h = _mix(h, UInt64(len(self.part.loaded)))
        for k in self.part.loaded:
            h = _mix(h, UInt64(k))
        h = _mix(h, UInt64(self.loads))
        h = _mix(h, UInt64(self.unloads))
        return h

    # -------------------------------------------------------------------------------------------------- drawing

    def draw_items(mut self) raises -> List[DrawItem]:
        """What the camera can see of what is loaded: ground tiles, props, walls, the player.
        Sets `drawn` and `culled`; with `culling` off everything loaded is returned."""
        var out = List[DrawItem]()
        var fr = Frustum(self.cam)
        var culled = 0
        var half_cell = Real(CELL * 0.5)
        var half_cells = CELLS_PER_SIDE // 2
        # a tile per loaded cell that is on the map
        for k in self.part.loaded:
            var ix = (k >> 31) - (1 << 30)
            var iz = (k & ((1 << 31) - 1)) - (1 << 30)
            if ix < -half_cells or ix >= half_cells or iz < -half_cells or iz >= half_cells:
                continue
            var cx = Real((Float64(ix) + 0.5) * CELL)
            var cz = Real((Float64(iz) + 0.5) * CELL)
            if self.culling and not fr.aabb_visible(Vec3(cx - half_cell, -0.1, cz - half_cell, 0.0), Vec3(cx + half_cell, 0.02, cz + half_cell, 0.0)):
                culled += 1
                continue
            var c = zone_color(zone_of(Float64(cx), Float64(cz)))
            if (ix + iz) % 2 != 0:
                c = c * 0.9
            out.append(DrawItem(0, Vec3(cx, -0.04, cz, 0.0), 0.0, 0.0, 0.0, 1.0, Vec3(half_cell, 0.05, half_cell, 0.0), c))
        # props: a static one stands where its spec says, a dynamic one is read from the scene
        for i in range(len(self.part.specs)):
            if not self.part.live[i]:
                continue
            ref s = self.part.specs[i]
            var pos = Vec3(Real(s.pos.x), Real(s.pos.y), Real(s.pos.z), 0.0)
            var rot = s.rot
            if not s.is_static:
                var st = self.world.state(pack_body(self.part.body_of[i]))
                pos = st.pos
                rot = st.rot
            var radius = sqrt(s.half[0] * s.half[0] + s.half[1] * s.half[1] + s.half[2] * s.half[2]) if s.kind == SPEC_BOX else s.half[0]
            if self.culling and not fr.sphere_visible(pos, radius):
                culled += 1
                continue
            out.append(DrawItem(0 if s.kind == SPEC_BOX else 1, pos, Float64(rot.x), Float64(rot.y), Float64(rot.z), Float64(rot.w), s.half, self.spec_color[i]))
        for w in self.walls:
            var r = sqrt(w.half[0] * w.half[0] + w.half[1] * w.half[1] + w.half[2] * w.half[2])
            if self.culling and not fr.sphere_visible(w.pos, r):
                culled += 1
                continue
            out.append(w.copy())
        # the player: a body and a head
        var p = self.player_pos()
        out.append(DrawItem(0, p - Vec3(0.0, 0.1, 0.0, 0.0), 0.0, 0.0, 0.0, 1.0, Vec3(0.3, 0.5, 0.3, 0.0), Vec3(0.2, 0.55, 0.95, 0.0)))
        out.append(DrawItem(1, p + Vec3(0.0, 0.55, 0.0, 0.0), 0.0, 0.0, 0.0, 1.0, Vec3(0.28, 0.28, 0.28, 0.0), Vec3(0.25, 0.65, 1.0, 0.0)))
        self.drawn = len(out)
        self.culled = culled
        return out^

    # ------------------------------------------------------------------------------------------------- stepping

    def _stream(mut self) raises:
        var p = self.player_pos()
        var observers = List[WorldPos]()
        observers.append(WorldPos(Float64(p[0]), Float64(p[1]), Float64(p[2])))
        self.part.update(self.world.scene, WorldPos(0.0, 0.0, 0.0), observers, self.tick)
        for e in self.part.events:
            if e.kind == EV_LOAD:
                self.loads += 1
            else:
                self.unloads += 1
        self.part.events.clear()

    def _camera(mut self) raises:
        self.arm.aim(self.yaw, self.pitch)
        self.cam = self.arm.update(self.world.scene, self.player_pos() + Vec3(0.0, 0.5, 0.0, 0.0), DT)

    def teleport(mut self, x: Real, z: Real) raises:
        """Put the player somewhere else at once and stream for the new place (a test, or a fast-travel point)."""
        self.world.teleport(self.player_h, Vec3(x, 1.0, z, 0.0), Quat(0.0, 0.0, 0.0, 1.0))
        self.world.set_velocity(self.player_h, Vec3(0.0, 0.0, 0.0, 0.0), Vec3(0.0, 0.0, 0.0, 0.0))
        self._stream()
        self._camera()

    def update(mut self, intent: Intent, frame_dt: Float64) raises:
        """One frame: the camera angles, then as many fixed ticks as `frame_dt` buys, then the camera."""
        self.yaw -= intent.look_dx * 0.006
        self.pitch = min(Real(1.2), max(Real(0.1), self.pitch + intent.look_dy * 0.004))
        if intent.restart:
            self.teleport(0.0, 0.0)
        var first = True
        for _ in range(self.world.ticks_due(frame_dt)):
            self._tick(intent, first and intent.jump)
            first = False
        self._camera()

    def _tick(mut self, intent: Intent, jump: Bool) raises:
        self.tick += 1
        var f = Vec3(-sin(self.yaw), 0.0, -cos(self.yaw), 0.0)
        var r = Vec3(cos(self.yaw), 0.0, -sin(self.yaw), 0.0)
        var wish = f * intent.forward + r * intent.right
        var len2 = wish[0] * wish[0] + wish[2] * wish[2]
        if len2 > 1.0:
            wish = wish / sqrt(len2)
        self.player.update(self.world.scene, wish * PLAYER_SPEED, DT, G)
        if jump and self.player.on_ground:
            self.world.apply_impulse(self.player_h, Vec3(0.0, JUMP_IMPULSE, 0.0, 0.0))
        if self.tick % STREAM_TICKS == 0:
            self._stream()
        self.world.physics_tick()
