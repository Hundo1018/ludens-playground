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
from physics.solver6 import ContactScene6
from physics.cloth import MeshCloth, grid_mesh
from physics.rope import Rope
from procedural.ik_pose import shortest_arc
from embed.world import unpack_body
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
comptime CAT_ROPE: UInt32 = 2  # B2: rope segments do not collide with each other

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
comptime STAT_YAW_MRAD = 10  # the camera yaw in milliradians (W1: the mouse and pad look)
comptime STAT_FREE_FRAGMENTS = 11  # fragments of the quarry wall that have come loose (W7; 0 while the wall stands)
comptime STAT_FRAGMENTS = 12  # fragments the quarry wall was cut into (W7)
comptime STAT_GOALS = 15  # zone goals reached, 0 to 4 (W6)
comptime STAT_BOB_Z_MM = 16  # B1: the pendulum bob's z in millimetres; -1 before the pendulum exists
comptime STAT_RAG_PELVIS_MM = 21  # B4: the knocked-down figure's pelvis height in millimetres; -1 before any
comptime STAT_RAG_X_MM = 22  # B4: its pelvis x and z in millimetres (0 before any)
comptime STAT_RAG_Z_MM = 23
comptime GOAL_R: Real = 4.0  # a goal is reached within this distance (metres)
comptime GOAL_COUNT = 4
comptime QUARRY_WALL = Vec3(112.0, 2.0, -124.0, 0.0)  # the quarry's fractured wall, standing on the ground 12 m past the quarry goal (plan card 2a)
comptime QUARRY_WALL_HALF = Vec3(4.0, 2.0, 0.3, 0.0)
comptime QUARRY_RELEASE_R = Real(20.0)  # the wall and the pendulum are added when the player comes this close (metres)
comptime PENDULUM_PIVOT = Vec3(112.0, 12.0, -124.0, 0.0)  # reference baseline B1: a hinge 10 m above the wall's top
comptime PENDULUM_LEN = Real(9.0)  # the bob hangs 9 m below the pivot, level with the wall's middle at the bottom of its swing
comptime PENDULUM_MASS = Real(2000.0)  # a wrecking ball: tests/pendulum_native.mojo measures 500 kg not breaking the wall, 2000 kg breaking it
comptime PENDULUM_BOB_R = Real(1.0)
comptime CAMP_CENTER = Vec3(-110.0, 0.0, -112.0, 0.0)  # B2, B3: the camp's rope and banner are built when the player comes near
comptime CAMP_BUILD_R = Real(25.0)
comptime ROPE_TOP = Vec3(-104.0, 8.0, -112.0, 0.0)  # B2: the rope hangs from a beam here
comptime ROPE_SEGS = 12  # segments of ludens-core's XPBD rope (physics.rope.Rope)
comptime ROPE_R = Real(0.06)
comptime ROPE_SEG_LEN = Real(0.52)  # rest length of one segment (6.24 m in all)
comptime ROPE_MASS = Real(4.8)
comptime ROPE_WEIGHT_R = Real(0.25)  # a 5 kg ball at the end, pushed sideways so the rope swings
comptime FLAG_POLE = Vec3(-114.0, 3.2, -112.0, 0.0)  # B3: the banner's pinned edge starts here and runs 1.2 m along z
comptime FLAG_NX = 12
comptime FLAG_NZ = 8
comptime FLAG_W = Real(1.8)
comptime FLAG_H = Real(1.2)
comptime STAT_ROPE_LEN_PERMILLE = 17  # B2: the rope's length (segment centres) over its rest length, in permille; -1 before the camp
comptime STAT_ROPE_SWING_MM = 18  # B2: the end ball's horizontal distance from below the beam, mm; -1 before the camp
comptime STAT_FLAG_CORNER_MM = 19  # B3: the banner's free corner's distance from its rest position, mm; -1 before the camp
comptime STAT_FLAG_PIN_UM = 20  # B3: the largest move of a pinned vertex, micrometres; -1 before the camp

comptime FNV_PRIME = UInt64(0x100000001B3)


def zone_of(x: Float64, z: Float64) -> Int:
    if abs(x) < HUB_HALF and abs(z) < HUB_HALF:
        return ZONE_HUB
    if z < 0:
        return ZONE_QUARRY if x >= 0 else ZONE_CAMP
    return ZONE_TOWN if x >= 0 else ZONE_TRAINING


def goal_point(i: Int) -> Vec3:
    """W6: the goal of zone i (0 quarry, 1 camp, 2 town, 3 training): the zone's fast-travel point."""
    if i == 0:
        return Vec3(112.0, 0.0, -112.0, 0.0)
    if i == 1:
        return Vec3(-112.0, 0.0, -112.0, 0.0)
    if i == 2:
        return Vec3(112.0, 0.0, 112.0, 0.0)
    return Vec3(-112.0, 0.0, 112.0, 0.0)


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


# V1-V3: the texture layers the page loads (app/host.mojo uploads them; assets/manifest.toml lists the sources). Every
# item the Frontier draws carries one (triplanar, material 2): no colour-only boxes. The colour stays as a tint.
comptime LAYER_CONCRETE = 1  # concrete_wall_003
comptime LAYER_GROUND = 2  # rocks_ground_01
comptime LAYER_FOX = 3
comptime LAYER_CESIUM = 4  # CesiumMan's own texture
comptime LAYER_BLOCKS = 5  # medieval_blocks_02
comptime LAYER_BRICK = 6  # castle_brick_07
comptime LAYER_PLASTER = 7  # plastered_wall_02
comptime LAYER_PLANKS = 8  # brown_planks_03
comptime LAYER_BARK = 9  # bark_brown_02
comptime LAYER_HESSIAN = 10  # hessian_230
comptime LAYER_METAL = 11  # rusty_metal_02
comptime TEXTURE_LAYERS = 12


def _turned(pos: Vec3, c: Real, s: Real, lx: Real, ly: Real, lz: Real) -> Vec3:
    """A point given in a frame at pos turned about +Y (cos c, sin s), in world space; y is the height above the ground."""
    return Vec3(pos[0] + c * lx + s * lz, ly, pos[2] - s * lx + c * lz, 0.0)


def tex(var d: DrawItem, layer: Int) -> DrawItem:
    """The item textured with `layer` (triplanar), its colour kept as the tint."""
    d.material = 2
    d.layer = layer
    return d^


def building_layer(x: Real, z: Real) -> Int:
    """V3: a building's face texture, from a hash of where it stands, so neighbours differ."""
    var h = (UInt64(Int(x * 7.0) + 100000) * UInt64(0x9E3779B97F4A7C15)) ^ (UInt64(Int(z * 13.0) + 100000) * UInt64(0xC2B2AE3D27D4EB4F))
    var k = Int((h >> 33) % 4)
    if k == 0:
        return LAYER_CONCRETE
    if k == 1:
        return LAYER_BLOCKS
    if k == 2:
        return LAYER_BRICK
    return LAYER_PLASTER


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


@fieldwise_init
struct StaticBox(Copyable, ImplicitlyCopyable, Movable):
    """A static box of the map: centre and half extents, in metres (the town's navmesh holes come from these)."""

    var c: Vec3
    var h: Vec3


def flag_grid() -> Tuple[List[Float32], List[UInt32]]:
    """The banner's uv (u along x, v along z) and triangle indices: the cloth's own grid_mesh triangles."""
    var g = grid_mesh(FLAG_NX, FLAG_NZ, FLAG_W, FLAG_H, FLAG_POLE)
    var uv = List[Float32]()
    for j in range(FLAG_NZ + 1):
        for i in range(FLAG_NX + 1):
            uv.append(Float32(i) / Float32(FLAG_NX))
            uv.append(Float32(j) / Float32(FLAG_NZ))
    var idx = List[UInt32]()
    for t in g[1]:
        idx.append(UInt32(t))
    return (uv^, idx^)


def _cell_item(p00: Vec3, p10: Vec3, p01: Vec3, p11: Vec3, color: Vec3) -> DrawItem:
    """A cloth cell drawn as a thin box: local x along the cell's u edge, local y along its normal, local z the third axis."""
    var centre = (p00 + p10 + p01 + p11) * Real(0.25)
    var u = (p10 + p11 - p00 - p01) * Real(0.5)
    var v = (p01 + p11 - p00 - p10) * Real(0.5)
    var lu = sqrt(u[0] * u[0] + u[1] * u[1] + u[2] * u[2])
    var lv = sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
    var x = u / max(lu, Real(1e-6))
    var n = Vec3(u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0], 0.0)
    var ln = sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2])
    var y = n / max(ln, Real(1e-6))
    var z = Vec3(x[1] * y[2] - x[2] * y[1], x[2] * y[0] - x[0] * y[2], x[0] * y[1] - x[1] * y[0], 0.0)
    # quaternion from the rotation whose columns are x, y, z
    var m00 = Float64(x[0]); var m01 = Float64(y[0]); var m02 = Float64(z[0])
    var m10 = Float64(x[1]); var m11 = Float64(y[1]); var m12 = Float64(z[1])
    var m20 = Float64(x[2]); var m21 = Float64(y[2]); var m22 = Float64(z[2])
    var tr = m00 + m11 + m22
    var qw: Float64; var qx: Float64; var qy: Float64; var qz: Float64
    if tr > 0:
        var s = (tr + 1.0) ** 0.5 * 2.0
        qw = 0.25 * s; qx = (m21 - m12) / s; qy = (m02 - m20) / s; qz = (m10 - m01) / s
    elif m00 > m11 and m00 > m22:
        var s = (1.0 + m00 - m11 - m22) ** 0.5 * 2.0
        qw = (m21 - m12) / s; qx = 0.25 * s; qy = (m01 + m10) / s; qz = (m02 + m20) / s
    elif m11 > m22:
        var s = (1.0 + m11 - m00 - m22) ** 0.5 * 2.0
        qw = (m02 - m20) / s; qx = (m01 + m10) / s; qy = 0.25 * s; qz = (m12 + m21) / s
    else:
        var s = (1.0 + m22 - m00 - m11) ** 0.5 * 2.0
        qw = (m10 - m01) / s; qx = (m02 + m20) / s; qy = (m12 + m21) / s; qz = 0.25 * s
    return tex(DrawItem(0, centre, qx, qy, qz, qw, Vec3(lu * Real(0.5), Real(0.01), lv * Real(0.5), 0.0), color), LAYER_HESSIAN)


struct Frontier(Movable):
    var world: EmbedWorld
    var part: WorldPartition
    var spec_color: List[Vec3]  # parallel to part.specs
    var spec_layer: List[Int]  # V2: each spec's texture layer, parallel to part.specs
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
    var debug: Bool  # ?debug: the HUD shows the streaming counters (W9)
    var goal_done: List[Bool]  # W6: one goal per zone, at its fast-travel point; each counted once
    var goal_count: Int
    var wall_released: Bool  # W7: the fractured wall exists (it is added when the player comes near)
    var pendulum_anchor: Int64  # B1: the hinge's static anchor, -1 until the wall is added
    var pendulum_bob: Int64  # B1: the 2000 kg bob on the hinge, -1 until the wall is added
    var camp_built: Bool  # B2, B3: the rope and the banner exist
    var rope: Optional[Rope]  # B2: the rope, stepped on the world's scene after each physics tick
    var rope_ball: Int64  # B2: the 5 kg ball at its end
    var rope_beam: Int64
    var flag: Optional[MeshCloth]  # B3: the banner, a cloth stepped in its own contact scene
    var flag_scene: ContactScene6[QuatBody6]
    var flag_mesh: Int  # the banner's dynamic mesh in the host's renderer (ludens-engine#73); -1: drawn as cell boxes
    var flag_rest: List[Vec3]
    var rag: List[Int64]  # B4: the knocked-down figure's bodies (pelvis first)
    var rag_joints: List[Int]
    var rag_rest_pos: List[Vec3]  # V5: each body's pose when the figure was added (the skinned draw's reference)
    var rag_rest_rot: List[Quat]
    var rag_boxes: Bool  # V5: draw the figure as boxes; the host turns it off when it draws CesiumMan on the bodies
    var fracture_events: Int  # fracture events (bonds broken or fragments evicted) since the start (W7)

    def __init__(out self) raises:
        self.world = EmbedWorld(1.0 / 60.0, G)
        self.part = WorldPartition(CELL, LOAD_R, UNLOAD_R)
        self.spec_color = List[Vec3]()
        self.spec_layer = List[Int]()
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
        self.debug = False
        self.goal_done = List[Bool]()
        for _ in range(GOAL_COUNT):
            self.goal_done.append(False)
        self.goal_count = 0
        self.wall_released = False
        self.fracture_events = 0
        self.pendulum_anchor = -1
        self.pendulum_bob = -1
        self.camp_built = False
        self.rope = None
        self.rope_ball = -1
        self.rope_beam = -1
        self.flag = None
        self.flag_mesh = -1
        self.flag_scene = ContactScene6[QuatBody6]()
        self.flag_rest = List[Vec3]()
        self.rag = List[Int64]()
        self.rag_joints = List[Int]()
        self.rag_rest_pos = List[Vec3]()
        self.rag_rest_rot = List[Quat]()
        self.rag_boxes = True
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
        self.spec_layer = move.spec_layer^
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
        self.debug = move.debug
        self.goal_done = move.goal_done.copy()
        self.goal_count = move.goal_count
        self.wall_released = move.wall_released
        self.fracture_events = move.fracture_events
        self.pendulum_anchor = move.pendulum_anchor
        self.pendulum_bob = move.pendulum_bob
        self.camp_built = move.camp_built
        self.rope = move.rope^
        self.rope_ball = move.rope_ball
        self.rope_beam = move.rope_beam
        self.flag = move.flag^
        self.flag_mesh = move.flag_mesh
        self.flag_scene = move.flag_scene^
        self.flag_rest = move.flag_rest^
        self.rag = move.rag^
        self.rag_joints = move.rag_joints^
        self.rag_rest_pos = move.rag_rest_pos^
        self.rag_rest_rot = move.rag_rest_rot^
        self.rag_boxes = move.rag_boxes

    # ------------------------------------------------------------------------------------------------- building

    def _spec(mut self, kind: Int, pos: Vec3, half: Vec3, mass: Real, color: Vec3, layer: Int = LAYER_CONCRETE) raises:
        var is_static = mass == 0
        _ = self.part.add(BodySpec(
            kind, half, mass, is_static, WorldPos(Float64(pos[0]), Float64(pos[1]), Float64(pos[2])),
            Quat(0.0, 0.0, 0.0, 1.0), Vec3(0.0, 0.0, 0.0, 0.0), Vec3(0.0, 0.0, 0.0, 0.0),
        ))
        self.spec_color.append(color)
        self.spec_layer.append(layer)

    def _wall(mut self, pos: Vec3, half: Vec3) raises:
        var h = self.world.add_box(pos, half, 0.0, True)
        self.world.set_layer(h, CAT_WORLD, ALL_LAYERS)
        self.walls.append(tex(DrawItem(0, pos, 0.0, 0.0, 0.0, 1.0, half, Vec3(0.75, 0.75, 0.78, 0.0)), LAYER_BLOCKS))

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
                self._spec(SPEC_BOX, Vec3(x, 2.0, z, 0.0), Vec3(0.5, 2.0, 0.5, 0.0), 0, Vec3(0.95, 0.95, 1.0, 0.0), LAYER_BLOCKS)
        elif zone == ZONE_QUARRY:
            # rocks, and stacks of blocks to push over
            for _ in range(5):
                var s = Real(rng.span(0.8, 2.2))
                self._spec(SPEC_BOX, Vec3(Real(rng.span(x0 + 4, x0 + CELL - 4)), s * 0.7, Real(rng.span(z0 + 4, z0 + CELL - 4)), 0.0),
                           Vec3(s, s * 0.7, s * 0.9, 0.0), 0, Vec3(0.85, 0.82, 0.78, 0.0), LAYER_CONCRETE)
            for _ in range(2):
                var x = Real(rng.span(x0 + 5, x0 + CELL - 5))
                var z = Real(rng.span(z0 + 5, z0 + CELL - 5))
                for level in range(3):
                    self._spec(SPEC_BOX, Vec3(x, 0.5 + Real(level), z, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 20.0, Vec3(1.0, 0.9, 0.8, 0.0), LAYER_PLANKS)
        elif zone == ZONE_CAMP:
            # posts, and balls that roll
            for _ in range(5):
                self._spec(SPEC_BOX, Vec3(Real(rng.span(x0 + 4, x0 + CELL - 4)), 1.5, Real(rng.span(z0 + 4, z0 + CELL - 4)), 0.0),
                           Vec3(0.15, 1.5, 0.15, 0.0), 0, Vec3(1.0, 1.0, 1.0, 0.0), LAYER_BARK)
            for _ in range(4):
                self._spec(SPEC_SPHERE, Vec3(Real(rng.span(x0 + 4, x0 + CELL - 4)), 0.5, Real(rng.span(z0 + 4, z0 + CELL - 4)), 0.0),
                           Vec3(0.5, 0.5, 0.5, 0.0), 10.0, Vec3(1.0, 0.55, 0.5, 0.0), LAYER_METAL)
        elif zone == ZONE_TOWN:
            # four buildings on a 2 by 2 grid, with streets between them
            for bx in range(2):
                for bz in range(2):
                    var hx = Real(rng.span(3.5, 5.5))
                    var hz = Real(rng.span(3.5, 5.5))
                    var hy = Real(rng.span(2.0, 7.0))
                    var shade = Real(rng.span(0.7, 1.1))
                    var bpx = Real(x0 + 8.0 + 16.0 * Float64(bx))
                    var bpz = Real(z0 + 8.0 + 16.0 * Float64(bz))
                    var tint = Real(0.85) + Real(0.15) * shade / Real(1.1)
                    self._spec(SPEC_BOX, Vec3(bpx, hy, bpz, 0.0), Vec3(hx, hy, hz, 0.0), 0, Vec3(tint, tint, tint * Real(0.97), 0.0),
                               building_layer(bpx, bpz))
            for _ in range(2):
                self._spec(SPEC_BOX, Vec3(Real(x0 + 16.0 + rng.span(-1.5, 1.5)), 0.4, Real(z0 + 16.0 + rng.span(-1.5, 1.5)), 0.0),
                           Vec3(0.4, 0.4, 0.4, 0.0), 8.0, Vec3(1.0, 0.95, 0.9, 0.0), LAYER_PLANKS)
        else:
            # low platforms and a few crates
            for _ in range(4):
                var hx = Real(rng.span(1.5, 3.0))
                self._spec(SPEC_BOX, Vec3(Real(rng.span(x0 + 5, x0 + CELL - 5)), 0.25, Real(rng.span(z0 + 5, z0 + CELL - 5)), 0.0),
                           Vec3(hx, 0.25, hx, 0.0), 0, Vec3(0.9, 0.88, 0.85, 0.0), LAYER_BLOCKS)
            for _ in range(2):
                self._spec(SPEC_BOX, Vec3(Real(rng.span(x0 + 4, x0 + CELL - 4)), 0.5, Real(rng.span(z0 + 4, z0 + CELL - 4)), 0.0),
                           Vec3(0.5, 0.5, 0.5, 0.0), 15.0, Vec3(1.0, 0.95, 0.85, 0.0), LAYER_PLANKS)

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

    def static_boxes(self, x0: Real, z0: Real, x1: Real, z1: Real, min_height: Real) -> List[StaticBox]:
        """The static boxes of the map whose centre is in the square [x0, x1] x [z0, z1] and whose half height is over
        min_height: the buildings, for the town's navmesh. Read from the same specs the streaming loads."""
        var out = List[StaticBox]()
        for i in range(len(self.part.specs)):
            ref s = self.part.specs[i]
            if s.kind != SPEC_BOX or not s.is_static or s.half[1] <= min_height:
                continue
            var x = Real(s.pos.x)
            var z = Real(s.pos.z)
            if x < x0 or x > x1 or z < z0 or z > z1:
                continue
            out.append(StaticBox(Vec3(x, Real(s.pos.y), z, 0.0), s.half))
        return out^

    def player_vel(self) raises -> Vec3:
        return self.world.state(self.player_h).vel

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
        if which == STAT_YAW_MRAD:
            return Int(self.yaw * 1000.0)
        if which == 14:  # fracture events since the start (W7)
            return self.fracture_events
        if which == STAT_BOB_Z_MM:
            return Int(self.world.state(self.pendulum_bob).pos[2] * Real(1000.0)) if self.pendulum_bob >= 0 else -1
        if which == STAT_ROPE_LEN_PERMILLE:
            if not self.rope:
                return -1
            return Int(self.rope.value().length() / (ROPE_SEG_LEN * Real(ROPE_SEGS)) * Real(1000.0))
        if which == STAT_ROPE_SWING_MM:
            if self.rope_ball < 0:
                return -1
            var e = self.world.state(self.rope_ball).pos
            var dx = e[0] - ROPE_TOP[0]
            var dz = e[2] - ROPE_TOP[2]
            return Int(sqrt(dx * dx + dz * dz) * Real(1000.0))
        if which == STAT_FLAG_CORNER_MM or which == STAT_FLAG_PIN_UM:
            if not self.flag:
                return -1
            var xs = self.flag.value().x.copy()
            if which == STAT_FLAG_CORNER_MM:
                var d = xs[FLAG_NX] - self.flag_rest[FLAG_NX]
                return Int(sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]) * Real(1000.0))
            var worst = Real(0.0)
            for j in range(FLAG_NZ + 1):
                var i = j * (FLAG_NX + 1)
                var d = xs[i] - self.flag_rest[i]
                worst = max(worst, sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]))
            return Int(worst * Real(1000000.0))
        if which == STAT_RAG_X_MM or which == STAT_RAG_Z_MM:
            return Int(self.world.state(self.rag[0]).pos[0 if which == STAT_RAG_X_MM else 2] * Real(1000.0)) if len(self.rag) > 0 else 0
        if which == STAT_RAG_PELVIS_MM:
            return Int(self.world.state(self.rag[0]).pos[1] * Real(1000.0)) if len(self.rag) > 0 else -1
        if which == STAT_GOALS:
            return self.goal_count
        if which == STAT_FREE_FRAGMENTS:
            return self.world.fracture.free_count() if self.world.fracture_on else 0
        if which == STAT_FRAGMENTS:
            return self.world.fracture.fragments() if self.world.fracture_on else 0
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
        # V4: one ground plane under the whole map, below the cell tiles, so unloaded cells are ground too (the border walls
        # hung over the sky before)
        var hm = Real(HALF_MAP)
        out.append(tex(DrawItem(0, Vec3(0.0, -0.12, 0.0, 0.0), 0.0, 0.0, 0.0, 1.0, Vec3(hm, 0.05, hm, 0.0),
                                Vec3(0.62, 0.62, 0.6, 0.0)), LAYER_GROUND))
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
            out.append(tex(DrawItem(0, Vec3(cx, -0.04, cz, 0.0), 0.0, 0.0, 0.0, 1.0, Vec3(half_cell, 0.05, half_cell, 0.0), c), LAYER_GROUND))
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
            out.append(tex(DrawItem(0 if s.kind == SPEC_BOX else 1, pos, Float64(rot.x), Float64(rot.y), Float64(rot.z), Float64(rot.w), s.half, self.spec_color[i]), self.spec_layer[i]))
        for w in self.walls:
            var r = sqrt(w.half[0] * w.half[0] + w.half[1] * w.half[1] + w.half[2] * w.half[2])
            if self.culling and not fr.sphere_visible(w.pos, r):
                culled += 1
                continue
            out.append(w.copy())
        # the quarry wall's fragments, each drawn at its own pose (plan card 2a: a box per fragment)
        if self.world.fracture_on:
            for i in range(self.world.fracture.fragments()):
                var fh = self.world.fragment_handle(i)
                var fs = self.world.state(fh)
                out.append(tex(DrawItem(0, fs.pos, Float64(fs.rot.x), Float64(fs.rot.y), Float64(fs.rot.z), Float64(fs.rot.w),
                                    Vec3(0.3, 0.3, 0.15, 0.0), Vec3(0.9, 0.88, 0.85, 0.0)), LAYER_CONCRETE))
        # B1: the pendulum: the anchor, the bob, and the rod between them (along the bob's local z, the hinge's lever)
        if self.pendulum_bob >= 0:
            var bs = self.world.state(self.pendulum_bob)
            out.append(tex(DrawItem(0, PENDULUM_PIVOT, 0.0, 0.0, 0.0, 1.0, Vec3(0.5, 0.5, 0.5, 0.0), Vec3(0.8, 0.8, 0.8, 0.0)), LAYER_METAL))
            out.append(tex(DrawItem(1, bs.pos, Float64(bs.rot.x), Float64(bs.rot.y), Float64(bs.rot.z), Float64(bs.rot.w),
                                Vec3(PENDULUM_BOB_R, PENDULUM_BOB_R, PENDULUM_BOB_R, 0.0), Vec3(0.7, 0.7, 0.72, 0.0)), LAYER_METAL))
            var mid = (bs.pos + PENDULUM_PIVOT) * Real(0.5)
            out.append(tex(DrawItem(0, mid, Float64(bs.rot.x), Float64(bs.rot.y), Float64(bs.rot.z), Float64(bs.rot.w),
                                Vec3(0.1, 0.1, PENDULUM_LEN * Real(0.5), 0.0), Vec3(1.0, 1.0, 1.0, 0.0)), LAYER_PLANKS))
        # B2: the rope's beam, a box along each rope segment, and the end ball
        if self.camp_built:
            out.append(tex(DrawItem(0, ROPE_TOP, 0.0, 0.0, 0.0, 1.0, Vec3(0.6, 0.1, 0.1, 0.0), Vec3(1.0, 1.0, 1.0, 0.0)), LAYER_PLANKS))
            if self.rope:
                var xs = self.rope.value().x.copy()
                for k in range(len(xs) - 1):
                    var d = xs[k + 1] - xs[k]
                    var q = shortest_arc(Vec3(0.0, 1.0, 0.0, 0.0), d)
                    var half = sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]) * Real(0.5)
                    out.append(tex(DrawItem(0, (xs[k] + xs[k + 1]) * Real(0.5), Float64(q.x), Float64(q.y), Float64(q.z), Float64(q.w),
                                        Vec3(ROPE_R, half, ROPE_R, 0.0), Vec3(1.0, 0.95, 0.85, 0.0)), LAYER_HESSIAN))
            if self.rope_ball >= 0:
                var rs = self.world.state(self.rope_ball)
                out.append(tex(DrawItem(1, rs.pos, Float64(rs.rot.x), Float64(rs.rot.y), Float64(rs.rot.z), Float64(rs.rot.w),
                                    Vec3(ROPE_WEIGHT_R, ROPE_WEIGHT_R, ROPE_WEIGHT_R, 0.0), Vec3(0.7, 0.7, 0.72, 0.0)), LAYER_METAL))
        # B3: the banner's pole and its cells, each a thin box in the cell's own frame
        if self.flag:
            out.append(tex(DrawItem(0, FLAG_POLE + Vec3(0.0, 0.0, FLAG_H * Real(0.5), 0.0), 0.0, 0.0, 0.0, 1.0,
                                Vec3(0.05, 0.05, FLAG_H * Real(0.5) + Real(0.1), 0.0), Vec3(1.0, 1.0, 1.0, 0.0)), LAYER_BARK))
            if self.flag_mesh >= 0:  # one dynamic mesh, its vertices the cloth's particles (the host updates it)
                out.append(DrawItem(0, Vec3(0.0, 0.0, 0.0, 0.0), 0.0, 0.0, 0.0, 1.0, Vec3(1.0, 1.0, 1.0, 0.0),
                                    Vec3(0.75, 0.15, 0.12, 0.0), self.flag_mesh))
            else:
                var xs = self.flag.value().x.copy()
                for j in range(FLAG_NZ):
                    for i in range(FLAG_NX):
                        var a = j * (FLAG_NX + 1) + i
                        var c = a + FLAG_NX + 1
                        out.append(_cell_item(xs[a], xs[a + 1], xs[c], xs[c + 1], Vec3(0.75, 0.15, 0.12, 0.0)))
        # B4: the knocked-down figure (red, as the guard); V5: the host draws CesiumMan on these bodies instead
        for i in range(len(self.rag) if self.rag_boxes else 0):
            var rs = self.world.state(self.rag[i])
            var half = Vec3(0.11, 0.07, 0.08, 0.0)
            if i == 1:
                half = Vec3(0.13, 0.2, 0.08, 0.0)
            elif i == 2:
                half = Vec3(0.1, 0.1, 0.1, 0.0)
            elif i == 3 or i == 4:
                half = Vec3(0.05, 0.14, 0.05, 0.0)
            elif i == 5:
                half = Vec3(0.04, 0.13, 0.04, 0.0)
            out.append(tex(DrawItem(1 if i == 2 else 0, rs.pos, Float64(rs.rot.x), Float64(rs.rot.y), Float64(rs.rot.z), Float64(rs.rot.w),
                                half, Vec3(1.0, 0.45, 0.4, 0.0)), LAYER_HESSIAN))
        # the player is drawn by the host as a skinned character (plan W3), not here
        self.drawn = len(out)
        self.culled = culled
        return out^

    def flag_positions(self) -> List[Float32]:
        """The banner's particle positions, 3 floats each (empty before the camp is built)."""
        var out = List[Float32]()
        if self.flag:
            for p in self.flag.value().x:
                out.append(Float32(Float64(p[0])))
                out.append(Float32(Float64(p[1])))
                out.append(Float32(Float64(p[2])))
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

    def _check_goals(mut self) raises:
        """W6: each zone's goal is reached once, when the player comes within GOAL_R of its point."""
        var p = self.player_pos()
        for i in range(GOAL_COUNT):
            if self.goal_done[i]:
                continue
            var g = goal_point(i)
            var dx = p[0] - g[0]
            var dz = p[2] - g[2]
            if dx * dx + dz * dz < GOAL_R * GOAL_R:
                self.goal_done[i] = True
                self.goal_count += 1

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

    def _build_camp(mut self) raises:
        """B2: ludens-core's rope (physics.rope.Rope, ROPE_SEGS segments) from a beam to a 5 kg ball pushed sideways so it
        swings; its ends are attached to the beam and the ball, and `tie` carries the ball on a distance joint of the
        rope's length. B3: a banner of FLAG_NX x FLAG_NZ cells, its edge on the pole pinned, in a wind."""
        self.camp_built = True
        self.rope_beam = self.world.add_box(ROPE_TOP, Vec3(0.6, 0.1, 0.1, 0.0), 0.0, True)
        var total = ROPE_SEG_LEN * Real(ROPE_SEGS)
        var tip = ROPE_TOP - Vec3(0.0, total, 0.0, 0.0)
        var wgt = self.world.add_sphere(tip - Vec3(0.0, ROPE_WEIGHT_R, 0.0, 0.0), ROPE_WEIGHT_R, 5.0, False)
        self.world.set_layer(wgt, CAT_ROPE, ALL_LAYERS ^ CAT_ROPE)
        var rope = Rope(ROPE_TOP, tip, ROPE_SEGS, ROPE_MASS)
        rope.attach(0, self.world.scene, unpack_body(self.rope_beam).index(), Vec3(0.0, 0.0, 0.0, 0.0))
        rope.attach(1, self.world.scene, unpack_body(wgt).index(), Vec3(0.0, ROPE_WEIGHT_R, 0.0, 0.0))
        _ = rope.tie(self.world.scene)
        self.rope = rope^
        self.rope_ball = wgt
        self.world.set_velocity(wgt, Vec3(4.0, 0.0, 0.0, 0.0), Vec3(0.0, 0.0, 0.0, 0.0))
        var m = grid_mesh(FLAG_NX, FLAG_NZ, FLAG_W, FLAG_H, FLAG_POLE)
        var fl = MeshCloth(m[0], m[1], 0.1, 0, 1e-3)
        fl.wind = Vec3(3.0, 0.0, 1.0, 0.0)
        for j in range(FLAG_NZ + 1):
            fl.pin(j * (FLAG_NX + 1))
        self.flag_rest = fl.x.copy()
        self.flag = fl^
    def knock_down(mut self, pos: Vec3, push: Vec3, yaw: Real = 0.0) raises:
        """B4 (RDR2's physics-based reactions): a figure of six bodies on ball joints (pelvis, torso, head, two thighs, the
        left arm) stands at pos, turned by yaw about +Y, and is pushed along push; it falls under physics. V5: the bodies
        are laid out on CesiumMan's own joints (its slow walk, frame 0: pelvis 0.62 m, neck 1.13 m; +x is its left), so
        the skinned mesh drawn on them (app/rag_skin.mojo) sits on them. A new knock-down removes the previous one."""
        for j in self.rag_joints:
            self.world.remove_joint(j)
        for h in self.rag:
            self.world.remove(h)
        self.rag = List[Int64]()
        self.rag_joints = List[Int]()
        var c = cos(yaw)
        var sn = sin(yaw)
        var turn = Quat(0.0, sin(yaw * 0.5), 0.0, cos(yaw * 0.5))

        var pelvis = self.world.add_box(_turned(pos, c, sn, 0.0, 0.65, 0.0), Vec3(0.11, 0.07, 0.08, 0.0), 12.0, False)
        var torso = self.world.add_box(_turned(pos, c, sn, 0.01, 0.92, -0.02), Vec3(0.13, 0.2, 0.08, 0.0), 20.0, False)
        var head = self.world.add_sphere(_turned(pos, c, sn, 0.02, 1.22, -0.05), 0.1, 5.0, False)
        var lthigh = self.world.add_box(_turned(pos, c, sn, 0.087, 0.426, 0.03), Vec3(0.05, 0.14, 0.05, 0.0), 7.0, False)
        var rthigh = self.world.add_box(_turned(pos, c, sn, -0.054, 0.439, 0.07), Vec3(0.05, 0.14, 0.05, 0.0), 7.0, False)
        var arm = self.world.add_box(_turned(pos, c, sn, 0.124, 0.898, -0.06), Vec3(0.04, 0.13, 0.04, 0.0), 4.0, False)
        self.rag.append(pelvis); self.rag.append(torso); self.rag.append(head)
        self.rag.append(lthigh); self.rag.append(rthigh); self.rag.append(arm)
        for h in self.rag:
            self.world.teleport(h, self.world.state(h).pos, turn)
        self.rag_joints.append(self.world.add_ball_joint(pelvis, torso, Vec3(0.0, 0.07, 0.0, 0.0), Vec3(-0.01, -0.2, 0.02, 0.0)))
        self.rag_joints.append(self.world.add_ball_joint(torso, head, Vec3(0.01, 0.2, -0.03, 0.0), Vec3(0.0, -0.1, 0.0, 0.0)))
        self.rag_joints.append(self.world.add_ball_joint(pelvis, lthigh, Vec3(0.066, -0.093, 0.025, 0.0), Vec3(-0.021, 0.13, -0.005, 0.0)))
        self.rag_joints.append(self.world.add_ball_joint(pelvis, rthigh, Vec3(-0.069, -0.084, 0.038, 0.0), Vec3(-0.015, 0.127, -0.032, 0.0)))
        self.rag_joints.append(self.world.add_ball_joint(torso, arm, Vec3(0.102, 0.097, -0.02, 0.0), Vec3(-0.012, 0.119, 0.02, 0.0)))
        self.rag_rest_pos = List[Vec3]()
        self.rag_rest_rot = List[Quat]()
        for h in self.rag:
            var st = self.world.state(h)
            self.rag_rest_pos.append(st.pos)
            self.rag_rest_rot.append(st.rot)
        self.world.apply_impulse(torso, push * Real(60.0) + Vec3(0.0, 10.0, 0.0, 0.0))

    def clear_rag(mut self) raises:
        """V5: the figure leaves when the guard stands up again."""
        for j in self.rag_joints:
            self.world.remove_joint(j)
        for h in self.rag:
            self.world.remove(h)
        self.rag = List[Int64]()
        self.rag_joints = List[Int]()
        self.rag_rest_pos = List[Vec3]()
        self.rag_rest_rot = List[Quat]()

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
        if not self.wall_released:
            var p = self.player_pos()
            var dx = p[0] - QUARRY_WALL[0]
            var dz = p[2] - QUARRY_WALL[2]
            if dx * dx + dz * dz < QUARRY_RELEASE_R * QUARRY_RELEASE_R:
                # Reference baseline B1 (original stage 2, a destructible wall and a jointed machine): the wall stands on
                # the ground, and a 2000 kg bob on a hinge 9 m long is released level with the pivot, on the player's side.
                # It swings down and hits the wall at the bottom of its swing, about 1.5 s later.
                _ = self.world.add_fracture_box(QUARRY_WALL, QUARRY_WALL_HALF, 40, 7, 5e1, 2000.0)
                self.pendulum_anchor = self.world.add_box(PENDULUM_PIVOT, Vec3(0.4, 0.4, 0.4, 0.0), 0.0, True)
                var bob_start = PENDULUM_PIVOT + Vec3(0.0, 0.0, PENDULUM_LEN, 0.0)
                self.pendulum_bob = self.world.add_sphere(bob_start, PENDULUM_BOB_R, PENDULUM_MASS, False)
                _ = self.world.add_hinge_joint(self.pendulum_anchor, self.pendulum_bob, Vec3(0.0, 0.0, 0.0, 0.0),
                                               Vec3(0.0, 0.0, -PENDULUM_LEN, 0.0), Vec3(1.0, 0.0, 0.0, 0.0))
                self.wall_released = True
        if not self.camp_built:
            var pc = self.player_pos()
            var cx = pc[0] - CAMP_CENTER[0]
            var cz = pc[2] - CAMP_CENTER[2]
            if cx * cx + cz * cz < CAMP_BUILD_R * CAMP_BUILD_R:
                self._build_camp()
        if self.flag:
            var fl = self.flag.take()
            fl.step(self.flag_scene, DT, G)
            self.flag = fl^
        # frame_fracture is cleared by ticks_due once per frame and grows with each tick: count this tick's records only
        var before = len(self.world.frame_fracture)
        self.world.physics_tick()
        self.fracture_events += len(self.world.frame_fracture) - before
        if self.rope:
            var rp = self.rope.take()
            rp.step(self.world.scene, DT, G)
            self.rope = rp^
        self._check_goals()
