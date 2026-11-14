"""The playground's browser host for the Frontier: boot, input, one frame per call, capture for checks.

It follows the engine's `app/main.mojo` for the one mode this package runs (the Frontier, behind `GameMode`), and reuses
the engine's renderer and HUD modules unchanged (`render3d`, `hud`, `controls`). The page is `page/`, which loads this
module with the engine's JavaScript runtime."""
from controls import read_keys
from frontier.mode import FrontierMode
from game.camera_view import View
from game.controls import Controls
from geometry.vec import Real
from hud import Hud
from render3d import ArenaRenderer
from app.mesh_pass import MeshRegistry
from app.skin_pass import build_palette_root, cpu_skin, palette_to_mats
from app.skin_gpu import GpuSkinning, SkinJob
from app.skin_pass import CpuSkinning, Skinning
from frontier_assets import Character, parse_character, parse_ltexture, pose_palette, rest_palette, locals_at, pose_palette_frame
from motion_match import build_match, m6_hash
from net_frontier import run_session
from geometry.mat import Mat4, transform_point4
from game.arena import DrawItem
from wgpu._backend.wgpu_native.types import WGPUTextureAspect
from wgpu._backend.wgpu_native.structs import WGPUExtent3D, WGPUOrigin3D, WGPUTexelCopyBufferInfo, WGPUTexelCopyBufferLayout, WGPUTexelCopyTextureInfo
from wgpu.buffer import Buffer
from wgpu import WGPUMapMode
from wgpu._backend.wgpu_native.alloc_guard import raw_alloc
from wgpu._ffi.types import WGPUBufferUsage
from geometry.quat import Quat
from geometry.vec import Real, Vec3
from wgpu._backend.wgpu_native.alloc_guard import raw_alloc
from wgpu._ffi.types import WGPUTextureFormat, WGPUTextureHandle, WGPUTextureUsage
from wgpu.buffer import MapRequest
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.rendercanvas.glfw import MojoInputEvent
from wgpu.rendercanvas.input import InputState
from wgpu.surface import Surface, create_surface_canvas
from wgpu.texture import Texture
from wgpu.web.boot import GPUBoot


struct B3Job(Movable):
    """One (character, frame) pair in flight: the CPU result, the GPU job, and the factor from the character's units to
    metres (the Fox's glTF units are centimetres)."""

    var cpu: List[Vec3]
    var job: SkinJob
    var scale: Float64

    def __init__(out self, var cpu: List[Vec3], var job: SkinJob, scale: Float64):
        self.cpu = cpu^
        self.job = job^
        self.scale = scale


struct TexReadback(Movable):
    """The wall texture read back from the GPU: layer 1, mip 0 (256x256) and mip 4 (16x16, rows padded to 256 bytes)."""

    var level0: Buffer
    var level4: Buffer
    var req0: MapRequest
    var req4: MapRequest

    def __init__(out self, var level0: Buffer, var level4: Buffer, var req0: MapRequest, var req4: MapRequest):
        self.level0 = level0^
        self.level4 = level4^
        self.req0 = req0^
        self.req4 = req4^


struct Host(Movable):
    var boot: GPUBoot
    var surface: Surface
    var width: UInt32
    var height: UInt32
    var configured: Bool
    var world: Optional[FrontierMode]
    var input: InputState
    var controls: Controls
    var renderer: Optional[ArenaRenderer]
    var hud: Optional[Hud]
    var game_format: UInt32
    var capture: Optional[FrameCapture]
    var capture_target: Optional[Texture]
    var capture_req: Optional[MapRequest]
    var capture_ptr: UInt64
    var want_capture: Bool
    var offscreen: Bool
    var frame_ms: Float32
    var cesium: Optional[Character]
    var fox: Optional[Character]
    var wall: Optional[List[List[UInt8]]]
    var clock: Float64  # seconds of animation, advanced per frame
    var placed: Bool  # the meshes and the wall texture are registered with the renderer
    var skin_cesium: Int
    var skin_fox: Int
    var crowd: Int  # extra CesiumMan instances drawn each frame (step 7 measurement; 0 = none)
    var tex_job: Optional[TexReadback]
    var b3_job: Optional[B3Job]

    def __init__(out self, selector: String, width: UInt32, height: UInt32) raises:
        self.boot = GPUBoot("playground")
        self.surface = create_surface_canvas(self.boot.instance.lib(), self.boot.instance.handle(), selector)
        self.width = width
        self.height = height
        self.configured = False
        self.world = FrontierMode()
        self.input = InputState()
        self.controls = Controls()
        self.renderer = None
        self.hud = None
        self.game_format = 0
        self.capture = None
        self.capture_target = None
        self.capture_req = None
        self.capture_ptr = 0
        self.want_capture = False
        self.offscreen = False
        self.frame_ms = 0
        self.cesium = None
        self.fox = None
        self.wall = None
        self.clock = 0.0
        self.placed = False
        self.skin_cesium = -1
        self.skin_fox = -1
        self.crowd = 0
        self.tex_job = None
        self.b3_job = None

    def __init__(out self, *, deinit move: Self):
        self.boot = move.boot^
        self.surface = move.surface^
        self.width = move.width
        self.height = move.height
        self.configured = move.configured
        self.world = move.world^
        self.input = move.input^
        self.controls = move.controls^
        self.renderer = move.renderer^
        self.hud = move.hud^
        self.game_format = move.game_format
        self.capture = move.capture^
        self.capture_target = move.capture_target^
        self.capture_req = move.capture_req^
        self.capture_ptr = move.capture_ptr
        self.want_capture = move.want_capture
        self.offscreen = move.offscreen
        self.frame_ms = move.frame_ms
        self.cesium = move.cesium^
        self.fox = move.fox^
        self.wall = move.wall^
        self.clock = move.clock
        self.placed = move.placed
        self.skin_cesium = move.skin_cesium
        self.skin_fox = move.skin_fox
        self.crowd = move.crowd
        self.tex_job = move.tex_job^
        self.b3_job = move.b3_job^

    def _draw(mut self, target: WGPUTextureHandle, format: UInt32) raises:
        var aspect = Float32(self.width) / Float32(self.height)
        var m = self.world.take()
        var view = View(m.camera(), Real(aspect))
        if self.game_format != format:  # the pipelines are built for one target format
            self.hud = None
            self.renderer = None
            self.game_format = format
        if not self.hud:
            self.hud = Hud(self.boot.device(), format)
        if not self.renderer:
            self.renderer = ArenaRenderer(self.boot.device(), format, view)
        self._register()
        self.renderer.value().begin(view)
        for it in m.scene():
            var item = it.copy()
            if item.kind == 0:  # the scenery (ground, walls, boxes) is textured with the concrete wall, layer 1
                item.material = 2
            self.renderer.value().push(item)
        self._characters(view)
        self.hud.value().set(m.hud(Float32(self.width), Float32(self.height), self.frame_ms), Float32(self.width), Float32(self.height))
        self.renderer.value().draw(self.boot.device(), target, self.width, self.height, self.hud.value())
        self.world = m^

    def _register(mut self) raises:
        """Once both characters and the wall are on the page: their meshes and the texture layer go to the renderer."""
        if self.placed or not self.cesium or not self.fox or not self.wall:
            return
        var c = self.cesium.value().copy()
        self.skin_cesium = self.renderer.value().meshes.add_skinned(c.positions.copy(), c.normals.copy(), c.uv.copy(), c.joints.copy(), c.weights.copy(), c.indices.copy())
        var f = self.fox.value().copy()
        self.skin_fox = self.renderer.value().meshes.add_skinned(f.positions.copy(), f.normals.copy(), f.uv.copy(), f.joints.copy(), f.weights.copy(), f.indices.copy())
        self.renderer.value().textures.load_layer(self.boot.device(), UInt32(1), self.wall.value().copy())
        self.placed = True

    def _characters(mut self, view: View) raises:
        """Each frame: the two characters' palettes (one clip sampled at the clock, the rest pose's ancestors applied),
        their skinned draw items, and the palette buffer the renderer reads."""
        if not self.placed:
            return
        var c = self.cesium.value().copy()
        var f = self.fox.value().copy()
        var pal = pose_palette(c, self.clock)
        var fox_base = c.joint_count
        var pal_fox = pose_palette(f, self.clock)
        pal.extend(pal_fox^)
        # crowd (step 7): n more CesiumMan instances, each at its own clip phase, one palette each after the two above
        var crowd_bases = List[Int]()
        for k in range(self.crowd):
            var fr = (Int(self.clock * Float64(c.fps)) + 7 * k) % c.frames
            crowd_bases.append(len(pal) // 16)  # the palette is a list of floats, 16 per matrix; pose_id is a matrix index
            pal.extend(pose_palette_frame(c, fr))
        self.renderer.value().skin_palette = pal^
        # six units ahead of the eye, 1.5 to either side, feet on the ground (y = 0)
        var ahead = Float64(6.0)
        var side = Float64(1.5)
        var cs = Vec3(
            Real(Float64(view.eye[0]) + Float64(view.fwd[0]) * ahead - Float64(view.right[0]) * side), Real(0.0),
            Real(Float64(view.eye[2]) + Float64(view.fwd[2]) * ahead - Float64(view.right[2]) * side), Real(0.0),
        )
        var fs = Vec3(
            Real(Float64(view.eye[0]) + Float64(view.fwd[0]) * ahead + Float64(view.right[0]) * side), Real(0.0),
            Real(Float64(view.eye[2]) + Float64(view.fwd[2]) * ahead + Float64(view.right[2]) * side), Real(0.0),
        )
        self.renderer.value().push(DrawItem(
            -1, cs, 0.0, 0.0, 0.0, 1.0,
            Vec3(Real(1.0), Real(1.0), Real(1.0), Real(0.0)), Vec3(Real(0.85), Real(0.7), Real(0.6), Real(0.0)),
            self.skin_cesium, 0, 0,
        ))
        # the Fox's glTF units are centimetres: 78.9 units tall, so scale 0.01 gives 0.79 m (U10)
        self.renderer.value().push(DrawItem(
            -1, fs, 0.0, 0.0, 0.0, 1.0,
            Vec3(Real(0.01), Real(0.01), Real(0.01), Real(0.0)), Vec3(Real(0.9), Real(0.85), Real(0.7), Real(0.0)),
            self.skin_fox, fox_base, 0,
        ))
        # the crowd on a grid 8 to 30 m ahead of the eye, 16 across, 1.2 m apart; feet on the ground
        for k in range(self.crowd):
            var col = Real(Float64(k % 16) - 8.0) * Real(1.2)
            var row = Real(8.0 + Float64(k // 16) * 1.2)
            var pos = Vec3(
                Real(Float64(view.eye[0]) + Float64(view.fwd[0]) * Float64(row) + Float64(view.right[0]) * Float64(col)),
                Real(0.0),
                Real(Float64(view.eye[2]) + Float64(view.fwd[2]) * Float64(row) + Float64(view.right[2]) * Float64(col)),
                Real(0.0),
            )
            self.renderer.value().push(DrawItem(
                -1, pos, 0.0, 0.0, 0.0, 1.0,
                Vec3(Real(1.0), Real(1.0), Real(1.0), Real(0.0)), Vec3(Real(0.6), Real(0.75), Real(0.9), Real(0.0)),
                self.skin_cesium, crowd_bases[k], 0,
            ))

    def _capture(mut self, format: UInt32) raises:
        if self.want_capture and not self.capture_req:
            # Frames are read back from an app-owned target: headless Chrome cannot read a canvas texture.
            if not self.capture:
                self.capture = FrameCapture(self.boot.device(), self.width, self.height)
                self.capture_target = self.boot.device().create_texture(
                    self.width, self.height, 1, format,
                    WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC,
                    label="capture_target",
                )
            var target = self.capture_target.value().handle().raw
            self._draw(target, format)
            self.capture_req = self.capture.value().capture(self.boot.device(), target)
            self.want_capture = False

    def _finish_capture(mut self) raises:
        if self.capture_req and self.capture_req.value().ready():
            var req = self.capture_req.take()
            self.capture_ptr = UInt64(Int(req.take()))

    def frame(mut self, dt: Float64) raises -> Int32:
        """0 while the GPU is still being set up, 1 once a frame was drawn."""
        self.clock += min(dt, 0.1)
        var intent = self.controls.poll(read_keys(self.input))
        var m = self.world.take()
        m.step(intent, min(dt, 0.1))
        self.world = m^
        var rc = self._frame_draw()
        # Every frame ends here, drawn or not: a key edge or a pointer movement lasts exactly one frame.
        self.input.begin_frame()
        return rc

    def _frame_draw(mut self) raises -> Int32:
        if not self.boot.step():
            return 0
        if self.offscreen:
            # Never touch the canvas: headless Chrome loses the device after a canvas draw.
            self._capture(WGPUTextureFormat.RGBA8Unorm)
            self._finish_capture()
            return 1
        if not self.configured:
            self.surface.configure(self.boot.adapter().handle(), self.boot.device().handle().raw, self.width, self.height)
            self.configured = True
        var tex = self.surface.get_current_texture()
        if tex.is_renderable():
            self._draw(tex.texture, self.surface.format())
            self._capture(self.surface.format())
            self.surface.present()
        self._finish_capture()
        return 1


def _host(handle: UInt64) -> Pointer[Host, MutUntrackedOrigin]:
    return Pointer[Host, MutUntrackedOrigin](unsafe_from_address=Int(handle))


@export
def playground_host_init(selector: UInt64, selector_len: UInt64, width: UInt32, height: UInt32) abi("C") -> UInt64:
    """Create the Frontier host on the canvas matching `selector` (UTF-8). 0 on failure."""
    try:
        var bytes = Span(unsafe_ptr=Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(selector)), length=Int(selector_len))
        var p = raw_alloc[Host](1)
        p.unsafe_write(Host(String(StringSlice(unsafe_from_utf8=bytes)), width, height))
        return UInt64(Int(p))
    except e:
        print("playground_host_init:", e)
        return 0


@export
def playground_host_frame(app: UInt64, dt: Float64) abi("C") -> Int32:
    """Advance one frame. 0 = setting up, 1 = drew a frame, -1 = error."""
    try:
        return _host(app)[].frame(dt)
    except e:
        print("playground_host_frame:", e)
        return -1


@export
def playground_host_input(app: UInt64, kind: Int32, key: Int32, action: Int32, mods: Int32, x: Float64, y: Float64) abi("C"):
    """One input event from the page (the same codes the engine's app_input takes: GLFW keys and buttons)."""
    _host(app)[].input.process_event(MojoInputEvent(kind, key, action, mods, x, y))


@export
def playground_host_release_input(app: UInt64) abi("C"):
    _host(app)[].input.release_all()


@export
def playground_host_offscreen(app: UInt64, on: Int32) abi("C"):
    """Draw only into the capture target, never the canvas (headless checks)."""
    _host(app)[].offscreen = on != 0


@export
def playground_host_request_capture(app: UInt64) abi("C"):
    _host(app)[].want_capture = True


@export
def playground_host_capture_ptr(app: UInt64) abi("C") -> UInt64:
    return _host(app)[].capture_ptr


@export
def playground_host_capture_pitch(app: UInt64) abi("C") -> UInt32:
    return padded_row_pitch(_host(app)[].width)


@export
def playground_host_capture_release(app: UInt64) abi("C"):
    """Done with the captured pixels: the next request waits for a new frame (the engine's app_capture_release)."""
    var h = _host(app)
    h[].capture_ptr = 0
    if h[].capture:
        h[].capture.value().unmap()  # the buffer is used again by the next capture: it must not stay mapped


@export
def playground_host_asset(app: UInt64, kind: Int32, ptr: UInt64, length: UInt64) abi("C") -> Int32:
    """A converted asset from the page: 1 CesiumMan.lcharacter, 2 Fox.lcharacter, 3 concrete_wall_008.ltexture. The bytes
    are copied here, so the page may free its buffer when this returns. 0 ok, -1 failed."""
    var h = _host(app)
    try:
        var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(ptr))
        var bytes = List[UInt8](length=Int(length), fill=0)
        for i in range(Int(length)):
            bytes[i] = src[i]
        if kind == 1:
            h[].cesium = parse_character(bytes, 101)  # the CMU walk, retargeted in place (step 6.2)
        elif kind == 2:
            h[].fox = parse_character(bytes, 101)  # the Walk clip: the converter writes Survey 100, Walk 101, Run 102
        elif kind == 3:
            h[].wall = parse_ltexture(bytes)
        else:
            raise Error("playground_host_asset: unknown kind " + String(kind))
        return 0
    except e:
        print("playground_host_asset:", e)
        return -1


@export
def playground_host_motion_hash(app: UInt64) abi("C") -> Int32:
    """M6 (design 1.9): the hash of the indices the 20 query frames return in CesiumMan's clip (motion_match.m6_hash).
    -1: the character is not loaded. -2: the matching failed (printed)."""
    var h = _host(app)
    if not h[].cesium:
        return -1
    try:
        var c = h[].cesium.value().copy()
        var m = build_match(c, c.motion)
        return Int32(m6_hash(m))
    except e:
        print("playground_host_motion_hash:", e)
        return -2


@export
def playground_host_net_check() abi("C") -> Int32:
    """Step 8 (netcode): the Frontier's session over SnapshotServer and SnapshotClient through a lossy SimLink (jitter 3,
    10 % loss), in the page's wasm. Returns the reference hash (mod 1000000007) when every client reaches tick 120 and
    every client and the server equal it; -1 otherwise. tests/frontier_net_native.mojo prints the same number."""
    try:
        var r = run_session(4, 3, Real(0.1), UInt64(2026), 120)
        if r[0] and r[1]:
            return Int32(r[2])
        return -1
    except e:
        print("playground_host_net_check:", e)
        return -2


@export
def playground_host_crowd(app: UInt64, n: Int32) abi("C") -> Int32:
    """Step 7 measurement: draw n extra CesiumMan instances each frame (0 to stop). Returns n, or -1 if the host is not
    up or the crowd would not fit the palette (the engine's limit is 4096 matrices; see docs/design/step7-crowd.md)."""
    var h = _host(app)
    if n < 0 or n > 400:
        return -1
    h[].crowd = Int(n)
    return n


@export
def playground_host_b1_check(app: UInt64, which: Int32) abi("C") -> Float64:
    """B1 (design 1.10): the palette at the rest pose (the rest TRS, no clip), applied to every vertex of a character by
    the CPU reference, against root_transform * p. which: 1 CesiumMan, 2 Fox. The largest difference, or -1 if the
    character is not loaded."""
    var h = _host(app)
    if which == 1 and not h[].cesium:
        return -1.0
    if which == 2 and not h[].fox:
        return -1.0
    try:
        var c = h[].cesium.value().copy() if which == 1 else h[].fox.value().copy()
        var pal = rest_palette(c)
        var root = palette_to_mats(c.root)[0].copy()
        var rest = List[Vec3]()
        var n = len(c.positions) // 3
        for v in range(n):
            rest.append(Vec3(Real(Float64(c.positions[3 * v])), Real(Float64(c.positions[3 * v + 1])), Real(Float64(c.positions[3 * v + 2])), Real(0)))
        var out = List[Vec3]()
        for _ in range(n):
            out.append(Vec3(Real(0), Real(0), Real(0), Real(0)))
        cpu_skin(palette_to_mats(pal), rest, _joint_ints(c.joints), _weights(c.weights), 4, out)
        var worst = 0.0
        for v in range(n):
            var want = transform_point4(root, rest[v])
            for k in range(3):
                var d = Float64(out[v][k] - want[k])
                if d < 0.0:
                    d = -d
                if d > worst:
                    worst = d
        return worst
    except e:
        print("playground_host_b1_check:", e)
        return -2.0


def _joint_ints(j: List[UInt16]) -> List[Int]:
    var out = List[Int]()
    for x in j:
        out.append(Int(x))
    return out^


def _weights(w: List[Float32]) -> List[Real]:
    var out = List[Real]()
    for x in w:
        out.append(Real(Float64(x)))
    return out^


def _start_texture_readback(mut h: Host) raises:
    """Copy layer 1's mip 0 and mip 4 out of the texture array into two buffers and start mapping them."""
    var tex = h.renderer.value().textures.texture.handle().raw
    var bytes0 = UInt64(256 * 256 * 4)
    var bytes4 = UInt64(256 * 256)  # 16 rows of 256 bytes: the 64-byte rows padded to the copy's 256-byte alignment
    var b0 = h.boot.device().create_buffer(bytes0, WGPUBufferUsage.COPY_DST | WGPUBufferUsage.MAP_READ, label="tex_mip0")
    var b4 = h.boot.device().create_buffer(bytes4, WGPUBufferUsage.COPY_DST | WGPUBufferUsage.MAP_READ, label="tex_mip4")
    var enc = h.boot.device().create_command_encoder("tex_readback")
    var src0 = raw_alloc[WGPUTexelCopyTextureInfo](1)
    src0[] = WGPUTexelCopyTextureInfo(tex, UInt32(0), WGPUOrigin3D(UInt32(0), UInt32(0), UInt32(1)), WGPUTextureAspect.All)
    var dst0 = raw_alloc[WGPUTexelCopyBufferInfo](1)
    dst0[] = WGPUTexelCopyBufferInfo(WGPUTexelCopyBufferLayout(UInt64(0), UInt32(1024), UInt32(256)), b0.handle().raw)
    var size0 = raw_alloc[WGPUExtent3D](1)
    size0[] = WGPUExtent3D(UInt32(256), UInt32(256), UInt32(1))
    enc.copy_texture_to_buffer(src0, dst0, size0)
    var src4 = raw_alloc[WGPUTexelCopyTextureInfo](1)
    src4[] = WGPUTexelCopyTextureInfo(tex, UInt32(4), WGPUOrigin3D(UInt32(0), UInt32(0), UInt32(1)), WGPUTextureAspect.All)
    var dst4 = raw_alloc[WGPUTexelCopyBufferInfo](1)
    dst4[] = WGPUTexelCopyBufferInfo(WGPUTexelCopyBufferLayout(UInt64(0), UInt32(256), UInt32(16)), b4.handle().raw)
    var size4 = raw_alloc[WGPUExtent3D](1)
    size4[] = WGPUExtent3D(UInt32(16), UInt32(16), UInt32(1))
    enc.copy_texture_to_buffer(src4, dst4, size4)
    var cmd = enc^.finish("tex_readback_cmd")
    h.boot.device().queue_submit(cmd)
    src0.unsafe_free()
    dst0.unsafe_free()
    size0.unsafe_free()
    src4.unsafe_free()
    dst4.unsafe_free()
    size4.unsafe_free()
    var r0 = b0.map_async(WGPUMapMode.READ, UInt64(0), bytes0)
    var r4 = b4.map_async(WGPUMapMode.READ, UInt64(0), bytes4)
    h.tex_job = TexReadback(b0^, b4^, r0^, r4^)


@export
def playground_host_texture_start(app: UInt64) abi("C") -> Int32:
    """C2 on the page: start reading layer 1 (mip 0 and mip 4) back from the GPU. 0 started, -1 not ready."""
    var h = _host(app)
    if not h[].renderer or not h[].placed:
        return -1
    try:
        _start_texture_readback(h[])
        return 0
    except e:
        print("playground_host_texture_start:", e)
        return -1


@export
def playground_host_texture_result(app: UInt64) abi("C") -> Float64:
    """-1 while the readback is pending, -2 if there is none or it failed, else the largest channel difference between
    the GPU's mip 0 and mip 4 and the converted levels (0 expected: the upload is exact)."""
    var h = _host(app)
    if not h[].tex_job:
        return -2.0
    if not h[].tex_job.value().req0.ready() or not h[].tex_job.value().req4.ready():
        return -1.0
    try:
        var job = h[].tex_job.take()
        var levels = h[].wall.value().copy()
        var p0 = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(job.req0.take()))
        var p4 = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(job.req4.take()))
        var worst = 0
        for i in range(256 * 256 * 4):
            var d = Int(p0[i]) - Int(levels[0][i])
            if d < 0:
                d = -d
            if d > worst:
                worst = d
        for y in range(16):
            for x in range(16 * 4):
                var d = Int(p4[y * 256 + x]) - Int(levels[4][y * 64 + x])
                if d < 0:
                    d = -d
                if d > worst:
                    worst = d
        job.level0.unmap()
        job.level4.unmap()
        return Float64(worst)
    except e:
        print("playground_host_texture_result:", e)
        return -2.0


@export
def playground_host_b3_start(app: UInt64, which: Int32, frame: Int32) abi("C") -> Int32:
    """B3 (design 1.10): start one (character, clip frame) pair. which: 1 CesiumMan, 2 Fox. The CPU reference runs now;
    the GPU compute job is submitted and collected by playground_host_b3_result. 0 started, -1 not ready."""
    var h = _host(app)
    if which == 1 and not h[].cesium:
        return -1
    if which == 2 and not h[].fox:
        return -1
    try:
        var c = h[].cesium.value().copy() if which == 1 else h[].fox.value().copy()
        var pal = pose_palette_frame(c, Int(frame))
        var rest = List[Vec3]()
        var n = len(c.positions) // 3
        for v in range(n):
            rest.append(Vec3(Real(Float64(c.positions[3 * v])), Real(Float64(c.positions[3 * v + 1])), Real(Float64(c.positions[3 * v + 2])), Real(0)))
        var joints = _joint_ints(c.joints)
        var weights = _weights(c.weights)
        var cpu_skinner = CpuSkinning()
        var cpu = cpu_skinner.skin(h[].boot.device(), pal, rest, joints, weights)
        var gpu = GpuSkinning(h[].boot.device())
        var job = gpu.submit(h[].boot.device(), pal, rest, joints, weights)
        var scale = 0.01 if which == 2 else 1.0
        h[].b3_job = B3Job(cpu^, job^, scale)
        return 0
    except e:
        print("playground_host_b3_start:", e)
        return -1


@export
def playground_host_b3_result(app: UInt64) abi("C") -> Float64:
    """-1 while the GPU job is pending, -2 if there is none or it failed, else the largest difference between the GPU
    and the CPU reference over every vertex, in metres."""
    var h = _host(app)
    if not h[].b3_job:
        return -2.0
    if not h[].b3_job.value().job.ready():
        return -1.0
    try:
        var b = h[].b3_job.take()
        var gpu = b.job.collect()
        var worst = 0.0
        for v in range(len(gpu)):
            for k in range(3):
                var d = Float64(b.cpu[v][k] - gpu[v][k])
                if d < 0.0:
                    d = -d
                if d > worst:
                    worst = d
        return worst * b.scale
    except e:
        print("playground_host_b3_result:", e)
        return -2.0
