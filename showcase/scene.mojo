"""The showcase's CPU side: rigid bodies (ludens-core EmbedWorld), the particle emitters' rows, the lights, the camera and
the HUD text. No GPU: `app/showcase_host.mojo` draws it; `tests/showcase_native.mojo` checks it.

What is in the scene:
- a floor and a dark backdrop, a shelf with two rows of seven spheres (gold metal and white ceramic) whose roughness goes
  0.05 .. 1;
- a drop zone: a box or a ball falls from 7 m every DROP_EVERY seconds onto a steel ramp and a low plinth, at most
  MAX_DYNAMIC bodies (the oldest one leaves); every contact that begins with an impulse over SPARK_MIN_IMPULSE throws
  sparks there; the bodies take one of five colours (warm white, charcoal, steel, copper, one orange accent);
- three point lights (two amber, one blue) circling the pile, a smoke vent, an ember fountain and four lamp posts for the
  bloom.

Everything follows from the seed and the number of `step` calls: `hash()` is the same on native and wasm64."""
from embed.world import EmbedWorld, EVENT_BEGAN
from game.draw_item import DrawItem, MAT_PBR, MAT_COLOR
from game.particles import ParticleSystem
from game.particles_table import ParticlesRow, particles_default_table, particles_row, PARTICLES_BLEND_ADD
from geometry.quat import Quat
from geometry.trig import sin, cos
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from scheduler.rng import SplitMix64

comptime DT = 1.0 / 60.0
comptime DROP_EVERY = 0.5  # seconds between two drops
comptime MAX_DYNAMIC = 30  # dynamic bodies kept; the oldest is removed past this
comptime SPARK_MIN_IMPULSE: Float32 = 1.5  # a contact that begins with less makes no sparks
comptime SPARKS_PER_STEP = 3  # bursts started in one physics step at most
comptime SPARK_EMITTERS = 6  # emitters reused round-robin for the impact bursts
comptime SETTLE_TICKS = 20
comptime PARTICLE_CAP = 6000
comptime TAU = 6.283185307179586
comptime ORBIT_RADIUS = 14.0
comptime ORBIT_HEIGHT = 4.8
comptime ORBIT_SPEED = 0.15  # radians per second of the swing's phase while the camera is not dragged
comptime YAW_LIMIT = 0.6  # the camera stays in front of the back wall


def v3(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0.0))


@fieldwise_init
struct Body(Copyable, ImplicitlyCopyable, Movable):
    var handle: Int64
    var kind: Int  # 0 box, 1 sphere
    var half: Vec3  # box half extents; a sphere's radius in half[0]
    var color: Vec3
    var roughness: Float32
    var metallic: Float32


@fieldwise_init
struct Light(Copyable, ImplicitlyCopyable, Movable):
    var pos: Vec3
    var color: Vec3
    var intensity: Float32
    var range: Float32


comptime PALETTE_SIZE = 5


def _palette(i: Int) -> Vec3:
    """Five body colours, linear: warm white, charcoal, steel, copper and one orange accent."""
    if i == 0:
        return v3(0.62, 0.60, 0.56)
    if i == 1:
        return v3(0.045, 0.045, 0.05)
    if i == 2:
        return v3(0.60, 0.61, 0.63)
    if i == 3:
        return v3(0.93, 0.62, 0.50)
    return v3(0.80, 0.28, 0.07)


def _palette_metal(i: Int) -> Float32:
    """Steel and copper are metals; the other three are dielectrics."""
    return Float32(1.0) if i == 2 or i == 3 else Float32(0.0)


def spark_row() raises -> ParticlesRow:
    """The engine's `spark` row as a burst we start by hand: no burst at time 0, a wider cone, brighter and hotter."""
    var r = particles_row(particles_default_table(), "spark")
    r.burst_count = 0
    r.cone_deg = 70
    r.speed_min = 2.5
    r.speed_max = 7.0
    r.gravity = [0.0, -9.81, 0.0]
    r.lifetime_min = 0.35
    r.lifetime_max = 0.9
    r.color_start = [3.0, 2.2, 0.9, 1.0]
    r.color_mid = [2.0, 0.8, 0.2, 0.9]
    r.color_end = [0.6, 0.1, 0.0, 0.0]
    r.max_particles = 900
    return r^


def ember_row() raises -> ParticlesRow:
    """A continuous fountain of additive embers."""
    var r = particles_row(particles_default_table(), "spark")
    r.burst_count = 0
    r.rate = 110
    r.cone_deg = 14
    r.speed_min = 5.0
    r.speed_max = 7.5
    r.gravity = [0.0, -9.81, 0.0]
    r.drag = 0.2
    r.lifetime_min = 0.9
    r.lifetime_max = 1.5
    r.size_curve = [0.10, 0.07, 0.02]
    r.color_start = [3.0, 1.7, 0.6, 1.0]
    r.color_mid = [1.8, 0.6, 0.12, 0.8]
    r.color_end = [0.4, 0.06, 0.0, 0.0]
    r.max_particles = 400
    return r^


def smoke_row() raises -> ParticlesRow:
    var r = particles_row(particles_default_table(), "smoke")
    r.rate = 30
    r.lifetime_min = 3.0
    r.lifetime_max = 4.5
    r.speed_min = 0.6
    r.speed_max = 1.1
    r.size_curve = [0.4, 1.2, 2.0]
    r.lod_far = 0.0  # no LOD: the camera orbits at 15 m
    return r^


def dust_row() raises -> ParticlesRow:
    var r = particles_row(particles_default_table(), "dust")
    r.rate = 25
    r.cone_deg = 90
    r.max_particles = 300
    return r^


struct Showcase(Movable):
    var world: EmbedWorld
    var rng: SplitMix64
    var statics: List[Body]
    var dynamic: List[Body]
    var particles: ParticleSystem
    var spark_first: Int  # index of the first impact emitter in `particles`
    var spark_next: Int
    var lights: List[Light]
    var time: Float64
    var tick: Int
    var drop_clock: Float64
    var drops: Int
    var removed: Int
    var bursts: Int  # impact bursts started since the start
    var yaw: Float64  # the camera's orbit angle
    var pitch: Float64
    var auto_orbit: Bool
    var orbit_clock: Float64
    var paused_particles: Bool

    def __init__(out self, seed: UInt64) raises:
        self.world = EmbedWorld(DT, v3(0.0, -9.81, 0.0))
        self.rng = SplitMix64.seeded(seed)
        self.statics = List[Body]()
        self.dynamic = List[Body]()
        self.particles = ParticleSystem(PARTICLE_CAP)
        self.spark_first = 0
        self.spark_next = 0
        self.lights = List[Light]()
        self.time = 0.0
        self.tick = 0
        self.drop_clock = 0.0
        self.drops = 0
        self.removed = 0
        self.bursts = 0
        self.yaw = YAW_LIMIT * sin(0.8)
        self.pitch = 0.33
        self.auto_orbit = True
        self.orbit_clock = 0.0
        self.paused_particles = False
        self._build()

    def __init__(out self, *, deinit move: Self):
        self.world = move.world^
        self.rng = move.rng^
        self.statics = move.statics^
        self.dynamic = move.dynamic^
        self.particles = move.particles^
        self.spark_first = move.spark_first
        self.spark_next = move.spark_next
        self.lights = move.lights^
        self.time = move.time
        self.tick = move.tick
        self.drop_clock = move.drop_clock
        self.drops = move.drops
        self.removed = move.removed
        self.bursts = move.bursts
        self.yaw = move.yaw
        self.pitch = move.pitch
        self.auto_orbit = move.auto_orbit
        self.orbit_clock = move.orbit_clock
        self.paused_particles = move.paused_particles

    def _static_box(mut self, pos: Vec3, half: Vec3, color: Vec3, rough: Float32, metal: Float32, rot: Quat = Quat.identity()) raises:
        var h = self.world.add_box(pos, half, 0.0, True)
        if rot.w != 1.0:
            self.world.teleport(h, pos, rot)
        self.statics.append(Body(h, 0, half, color, rough, metal))

    def _static_sphere(mut self, pos: Vec3, r: Float64, color: Vec3, rough: Float32, metal: Float32) raises:
        var h = self.world.add_sphere(pos, Real(r), 0.0, True)
        self.statics.append(Body(h, 1, v3(r, r, r), color, rough, metal))

    def _build(mut self) raises:
        # floor, a dark backdrop wide and tall enough that its edges stay out of the frame, and the shelf for the spheres
        self._static_box(v3(0, -0.5, 0), v3(40, 0.5, 40), v3(0.16, 0.16, 0.17), 0.45, 0.0)
        self._static_box(v3(0, 8.0, -13), v3(40, 8.0, 0.5), v3(0.06, 0.065, 0.075), 0.95, 0.0)
        self._static_box(v3(0, 0.3, -6.6), v3(9.4, 0.3, 1.9), v3(0.10, 0.10, 0.11), 0.6, 0.0)
        # the material rows: roughness 0.05 .. 1 left to right; gold metal behind, white ceramic in front
        for i in range(7):
            var x = -7.5 + 2.5 * Float64(i)
            var rough = Float32(0.05 + 0.95 * Float64(i) / 6.0)
            self._static_sphere(v3(x, 1.4, -7.4), 0.8, v3(1.0, 0.76, 0.33), rough, 1.0)
            self._static_sphere(v3(x, 1.2, -5.5), 0.6, v3(0.60, 0.58, 0.55), rough, 0.0)
        # the drop zone: a low tray with a rim, a tilted steel ramp inside it, so falling bodies roll off, collide and
        # stay in one pile
        self._static_box(v3(0.5, 0.15, 1.5), v3(2.8, 0.15, 2.3), v3(0.12, 0.12, 0.13), 0.5, 0.0)
        var rim = v3(0.30, 0.30, 0.32)
        self._static_box(v3(0.5, 0.45, -0.85), v3(2.8, 0.15, 0.05), rim, 0.35, 1.0)
        self._static_box(v3(0.5, 0.45, 3.85), v3(2.8, 0.15, 0.05), rim, 0.35, 1.0)
        self._static_box(v3(-2.35, 0.45, 1.5), v3(0.05, 0.15, 2.3), rim, 0.35, 1.0)
        self._static_box(v3(3.35, 0.45, 1.5), v3(0.05, 0.15, 2.3), rim, 0.35, 1.0)
        var ramp = Quat.from_axis_angle(v3(0, 0, 1), Real(0.32))
        self._static_box(v3(1.4, 0.85, 1.5), v3(1.3, 0.08, 1.1), v3(0.62, 0.63, 0.66), 0.25, 1.0, ramp)
        # four thin lamp posts with glowing caps (unlit colour above 1: the bloom picks them up)
        for i in range(4):
            var a = TAU * (Float64(i) + 0.5) / 4.0
            var x = 7.5 * cos(a)
            var z = 1.0 + 5.0 * sin(a)
            self._static_box(v3(x, 1.0, z), v3(0.08, 1.0, 0.08), v3(0.05, 0.05, 0.055), 0.4, 1.0)
        # emitters: smoke from a vent at the back left, embers at the back right, dust over the pile, then the impact ones
        self._static_box(v3(-9.0, 0.3, -2.5), v3(0.6, 0.3, 0.6), v3(0.08, 0.08, 0.09), 0.7, 0.3)
        self._static_box(v3(9.0, 0.3, -2.5), v3(0.45, 0.3, 0.45), v3(0.08, 0.08, 0.09), 0.3, 1.0)
        _ = self.particles.add(smoke_row(), -9.0, 0.7, -2.5, 11)
        _ = self.particles.add(ember_row(), 9.0, 0.7, -2.5, 12)
        _ = self.particles.add(dust_row(), 0.5, 0.2, 1.5, 13)
        self.spark_first = len(self.particles.emitters)
        for k in range(SPARK_EMITTERS):
            _ = self.particles.add(spark_row(), 0.0, 0.0, 0.0, UInt64(100 + k))
        self._lights()

    def glow_posts(self) -> List[Vec3]:
        var out = List[Vec3]()
        for i in range(4):
            var a = TAU * (Float64(i) + 0.5) / 4.0
            out.append(v3(7.5 * cos(a), 2.1, 1.0 + 5.0 * sin(a)))
        return out^

    def _lights(mut self):
        self.lights.clear()
        var c = [v3(1.0, 0.55, 0.25), v3(0.35, 0.55, 1.0), v3(1.0, 0.72, 0.45)]
        for i in range(3):
            var a = self.time * 0.5 + TAU * Float64(i) / 3.0
            self.lights.append(Light(v3(4.5 * cos(a), 2.4 + 0.4 * sin(self.time * 1.1 + Float64(i)), 1.5 + 4.0 * sin(a)), c[i], 3.5, 7.0))
        var posts = self.glow_posts()
        for i in range(len(posts)):
            self.lights.append(Light(posts[i], v3(1.0, 0.72, 0.42), 1.6, 3.5))

    def _drop(mut self) raises:
        var r = self.rng.next_f32()
        var x = Float64(self.rng.next_f32()) * 2.0 + 0.4
        var z = Float64(self.rng.next_f32()) * 1.6 + 0.7
        var pos = v3(x, 7.0, z)
        var ci = Int(self.rng.next_u64() % PALETTE_SIZE)
        var col = _palette(ci)
        var metal = _palette_metal(ci)
        var rough = Float32(0.2) + self.rng.next_f32() * Float32(0.4)
        if r < 0.5:
            var hx = 0.25 + 0.3 * Float64(self.rng.next_f32())
            var hy = 0.25 + 0.3 * Float64(self.rng.next_f32())
            var hz = 0.25 + 0.3 * Float64(self.rng.next_f32())
            var h = self.world.add_box(pos, v3(hx, hy, hz), Real(8.0 * hx * hy * hz * 600.0), False)
            var axis = v3(Float64(self.rng.next_f32()) - 0.5, 1.0, Float64(self.rng.next_f32()) - 0.5)
            self.world.teleport(h, pos, Quat.from_axis_angle(axis, Real(Float64(self.rng.next_f32()) * TAU)))
            self.dynamic.append(Body(h, 0, v3(hx, hy, hz), col, rough, metal))
        else:
            var rad = 0.25 + 0.3 * Float64(self.rng.next_f32())
            var h = self.world.add_sphere(pos, Real(rad), Real(4.19 * rad * rad * rad * 600.0), False)
            self.dynamic.append(Body(h, 1, v3(rad, rad, rad), col, rough, metal))
        self.drops += 1
        if len(self.dynamic) > MAX_DYNAMIC:
            self.world.remove(self.dynamic[0].handle)
            _ = self.dynamic.pop(0)
            self.removed += 1

    def drop_many(mut self, n: Int) raises:
        """Space: n bodies at once."""
        for _ in range(n):
            self._drop()

    def _sparks(mut self):
        if self.tick < SETTLE_TICKS:
            return
        var started = 0
        for e in self.world.tick_events:
            if started >= SPARKS_PER_STEP:
                return
            if e.kind != Int64(EVENT_BEGAN) or e.impulse < SPARK_MIN_IMPULSE:
                continue
            var k = self.spark_first + self.spark_next
            self.spark_next = (self.spark_next + 1) % SPARK_EMITTERS
            self.particles.emitters[k].origin = [Float64(e.point[0]), Float64(e.point[1]) + 0.02, Float64(e.point[2])]
            var n = 20 + Int(min(e.impulse, Float32(30.0)) * 4.0)
            self.particles.emitters[k].burst(n)
            self.bursts += 1
            started += 1

    def step(mut self, frame_dt: Float64, look_dx: Float64, look_dy: Float64) raises:
        """One frame of wall time: fixed physics ticks, drops, sparks, particles, lights and the camera."""
        if look_dx != 0.0 or look_dy != 0.0:
            self.auto_orbit = False
            self.yaw = min(max(self.yaw - look_dx * 0.006, -YAW_LIMIT), YAW_LIMIT)
            self.pitch = min(max(self.pitch + look_dy * 0.004, 0.05), 1.2)
        elif self.auto_orbit:  # swings between -YAW_LIMIT and YAW_LIMIT: the back wall stays behind the scene
            self.orbit_clock += frame_dt
            self.yaw = YAW_LIMIT * sin(self.orbit_clock * ORBIT_SPEED + 0.8)
        for _ in range(self.world.ticks_due(frame_dt)):
            self.drop_clock += DT
            if self.drop_clock >= DROP_EVERY:
                self.drop_clock -= DROP_EVERY
                self._drop()
            self.world.physics_tick()
            self.tick += 1
            self.time += DT
            self._sparks()
            if not self.paused_particles:
                var eye = self.camera().position
                self.particles.step(DT, Float64(eye[0]), Float64(eye[1]), Float64(eye[2]))
        self._lights()

    def camera(self) -> CameraPose:
        var target = v3(0.0, 1.0, -1.5)
        var eye = target + v3(ORBIT_RADIUS * cos(self.pitch) * sin(self.yaw), ORBIT_HEIGHT * sin(self.pitch) / sin(0.33),
                              ORBIT_RADIUS * cos(self.pitch) * cos(self.yaw))
        return CameraPose(eye, look_rotation(target - eye, v3(0, 1, 0)), Real(0.75), Real(16.0 / 9.0), Real(0.1), Real(400.0))

    def items(self) raises -> List[DrawItem]:
        """Every body as a MAT_PBR item (so it casts a shadow), the glowing caps as unlit colour."""
        var out = List[DrawItem]()
        for b in self.statics:
            var s = self.world.state(b.handle)
            out.append(DrawItem(b.kind, s.pos, Float64(s.rot.x), Float64(s.rot.y), Float64(s.rot.z), Float64(s.rot.w), b.half, b.color,
                                -1, -1, MAT_PBR, 0, b.roughness, b.metallic))
        for b in self.dynamic:
            var s = self.world.state(b.handle)
            out.append(DrawItem(b.kind, s.pos, Float64(s.rot.x), Float64(s.rot.y), Float64(s.rot.z), Float64(s.rot.w), b.half, b.color,
                                -1, -1, MAT_PBR, 0, b.roughness, b.metallic))
        for p in self.glow_posts():
            out.append(DrawItem(1, p, 0.0, 0.0, 0.0, 1.0, v3(0.13, 0.13, 0.13), v3(2.6, 1.8, 1.0)))
        for l in self.lights[:3]:
            out.append(DrawItem(1, l.pos, 0.0, 0.0, 0.0, 1.0, v3(0.07, 0.07, 0.07), l.color * Real(2.5)))
        return out^

    def live_particles(self) -> Int:
        return self.particles.live_total

    def body_count(self) -> Int:
        return len(self.world.bodies())

    def hash(self) -> UInt64:
        var h = self.world.hash()
        h = (h ^ self.particles.state_hash()) * UInt64(0x100000001B3)
        h = (h ^ UInt64(self.tick)) * UInt64(0x100000001B3)
        h = (h ^ UInt64(self.bursts)) * UInt64(0x100000001B3)
        return h
