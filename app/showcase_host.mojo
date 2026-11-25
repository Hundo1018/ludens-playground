"""The showcase page's wasm host: the scene of showcase/scene.mojo through the engine's renderer with every picture
feature on at once, and a HUD in Traditional Chinese from the engine's SDF font (ludens-engine#116).

    passes   Then[ShadowPass, Then[DefaultPasses, ParticlePass]]   sun shadow map, primitives / meshes / skinned, particles
    stages   ThenPost[Fxaa, ThenPost[Bloom, Grade]]                 FXAA, bloom, colour-grading LUT (ludens-engine#139)
    caps     RenderCaps.samples = 4                                  MSAA 4x (rebuilt with 1 when it is switched off)

Keys (the page forwards them as GLFW codes): 1 MSAA, 2 FXAA, 3 bloom, 4 grade, 5 shadows, 6 point lights, 7 particles,
Space drops ten bodies, R starts over, H hides the HUD; a left-button drag turns the camera.
Build: scripts/build_showcase.sh; check: scripts/showcase_check.mjs."""
from showcase.scene import Showcase, v3
from game.camera_view import View
from game.draw_item import DrawItem, MAT_SKY
from geometry.vec import Real, Vec3
from hud import Hud
from render3d import SceneRendererOf, DefaultPasses
from app.render_pass import Then
from app.render_res import PointLight, RenderCaps
from app.shadow_pass import ShadowPass
from app.particle_pass import ParticlePass
from app.post import ThenPost
from app.post_fx import Fxaa, Bloom, Grade, graded_lut
from app.lights import sky_environment, sun_shadow_vp
from ui.draw import Color, DrawList
from ui.geom import Rect
from ui.sdf_font import SdfFont
from wgpu import raw_alloc
from wgpu import WGPUTextureFormat, WGPUTextureHandle, WGPUTextureUsage
from wgpu.buffer import MapRequest
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.rendercanvas.glfw import MojoInputEvent
from wgpu.rendercanvas.input import InputState
from wgpu.surface import Surface, create_surface_canvas
from wgpu.texture import Texture
from wgpu.web.boot import GPUBoot
from std.time import perf_counter_ns

comptime Passes = Then[ShadowPass, Then[DefaultPasses, ParticlePass]]
comptime Look = ThenPost[Fxaa, ThenPost[Bloom, Grade]]
comptime Renderer = SceneRendererOf[Passes, Look]

# effect switches, in key order 1 .. 7 (showcase_toggle and the HUD use the same numbers)
comptime FX_MSAA = 0
comptime FX_FXAA = 1
comptime FX_BLOOM = 2
comptime FX_GRADE = 3
comptime FX_SHADOW = 4
comptime FX_LIGHTS = 5
comptime FX_PARTICLES = 6
comptime FX_COUNT = 7

comptime KEY_SPACE: Int32 = 32
comptime KEY_1: Int32 = 49
comptime KEY_H: Int32 = 72
comptime KEY_R: Int32 = 82
comptime MOUSE_LEFT: Int32 = 0

comptime SKY_TOP = (0.015, 0.02, 0.045)
comptime SKY_HOR = (0.16, 0.17, 0.21)
comptime SEED: UInt64 = 7


def _fx_name(i: Int) -> String:
    if i == FX_MSAA:
        return "多重取樣抗鋸齒 MSAA 4x"
    if i == FX_FXAA:
        return "快速近似抗鋸齒 FXAA"
    if i == FX_BLOOM:
        return "泛光 Bloom"
    if i == FX_GRADE:
        return "色彩分級 LUT"
    if i == FX_SHADOW:
        return "太陽陰影"
    if i == FX_LIGHTS:
        return "點光源 x7"
    return "粒子（火花、煙、餘燼、塵）"


struct Host(Movable):
    var boot: GPUBoot
    var surface: Surface
    var width: UInt32
    var height: UInt32
    var configured: Bool
    var scene: Showcase
    var input: InputState
    var renderer: Optional[Renderer]
    var renderer_samples: Int
    var hud: Optional[Hud]
    var font: List[UInt8]
    var format: UInt32
    var fx: List[Bool]
    var hud_on: Bool
    var capture: Optional[FrameCapture]
    var capture_target: Optional[Texture]
    var capture_req: Optional[MapRequest]
    var capture_ptr: UInt64
    var want_capture: Bool
    var offscreen: Bool
    var frame_ms: Float32  # the page's measurement of the whole frame call
    var step_ms: Float32  # the scene's step (physics, particles) inside it
    var draw_ms: Float32  # building and submitting the frame inside it
    var primed: Bool  # the first pointer event is a jump from (0, 0), not a drag
    var hold: Bool  # the scene does not advance (checks compare pictures of one moment)

    def __init__(out self, selector: String, width: UInt32, height: UInt32) raises:
        self.boot = GPUBoot("showcase")
        self.surface = create_surface_canvas(self.boot.instance.lib(), self.boot.instance.handle(), selector)
        self.width = width
        self.height = height
        self.configured = False
        self.scene = Showcase(SEED)
        self.input = InputState()
        self.renderer = None
        self.renderer_samples = 0
        self.hud = None
        self.font = List[UInt8]()
        self.format = 0
        self.fx = List[Bool]()
        for i in range(FX_COUNT):
            self.fx.append(i != FX_FXAA)  # FXAA after MSAA is not an improvement (ludens-engine docs/rendering-tier1.md)
        self.hud_on = True
        self.capture = None
        self.capture_target = None
        self.capture_req = None
        self.capture_ptr = 0
        self.want_capture = False
        self.offscreen = False
        self.frame_ms = 0
        self.step_ms = 0
        self.draw_ms = 0
        self.primed = False
        self.hold = False

    def __init__(out self, *, deinit move: Self):
        self.boot = move.boot^
        self.surface = move.surface^
        self.width = move.width
        self.height = move.height
        self.configured = move.configured
        self.scene = move.scene^
        self.input = move.input^
        self.renderer = move.renderer^
        self.renderer_samples = move.renderer_samples
        self.hud = move.hud^
        self.font = move.font^
        self.format = move.format
        self.fx = move.fx^
        self.hud_on = move.hud_on
        self.capture = move.capture^
        self.capture_target = move.capture_target^
        self.capture_req = move.capture_req^
        self.capture_ptr = move.capture_ptr
        self.want_capture = move.want_capture
        self.offscreen = move.offscreen
        self.frame_ms = move.frame_ms
        self.step_ms = move.step_ms
        self.draw_ms = move.draw_ms
        self.primed = move.primed
        self.hold = move.hold

    def toggle(mut self, i: Int, on: Bool):
        self.fx[i] = on

    def _keys(mut self) raises:
        for i in range(FX_COUNT):
            if self.input.is_key_just_pressed(KEY_1 + Int32(i)):
                self.fx[i] = not self.fx[i]
        if self.input.is_key_just_pressed(KEY_SPACE):
            self.scene.drop_many(10)
        if self.input.is_key_just_pressed(KEY_R):
            self.scene = Showcase(SEED)
        if self.input.is_key_just_pressed(KEY_H):
            self.hud_on = not self.hud_on

    def frame(mut self, dt: Float64) raises -> Int32:
        """0 while the GPU is still being set up, 1 once a frame was drawn."""
        self._keys()
        var dx = 0.0
        var dy = 0.0
        if self.primed and self.input.is_mouse_button_pressed(MOUSE_LEFT):
            dx = self.input.mouse_dx
            dy = self.input.mouse_dy
        if self.input.mouse_dx != 0 or self.input.mouse_dy != 0:
            self.primed = True
        self.scene.paused_particles = not self.fx[FX_PARTICLES]
        var t0 = perf_counter_ns()
        self.scene.step(0.0 if self.hold else min(dt, 0.1), dx, dy)
        self.step_ms = Float32(Float64(perf_counter_ns() - t0) / 1e6)
        var rc = self._frame_draw()
        self.input.begin_frame()
        return rc

    def _ensure(mut self, format: UInt32, view: View) raises:
        var samples = 4 if self.fx[FX_MSAA] else 1
        if self.format != format or self.renderer_samples != samples:
            self.renderer = None
            self.hud = None
            self.format = format
        if not self.hud:
            self.hud = Hud(self.boot.device(), format)
            if len(self.font) > 0:
                self.hud.value().set_font(self.boot.device(), self.font.copy())
        if not self.renderer:
            var caps = RenderCaps.default()
            caps.samples = samples
            var r = Renderer(self.boot.device(), format, view, caps=caps)
            var top = v3(SKY_TOP[0], SKY_TOP[1], SKY_TOP[2])
            var hor = v3(SKY_HOR[0], SKY_HOR[1], SKY_HOR[2])
            r.set_atmosphere(self.boot.device(), top, hor, 0.012, 1.0, True, True, 0.4)
            r.set_environment(self.boot.device(), sky_environment(v3(0.10, 0.12, 0.18), v3(0.16, 0.15, 0.15), v3(0.03, 0.03, 0.035)))
            r.set_sun(self.boot.device(), v3(-0.55, 0.42, 0.5), v3(1.0, 0.84, 0.68), 1.4)
            r.set_lut(self.boot.device(), 16, graded_lut(16, 0.08, 1.06, 0.95))
            r.bloom_threshold = 0.72
            r.bloom_intensity = 1.0
            # the scene's particles live in showcase/scene.mojo; the pass draws an empty system of its own, the host packs
            # the scene's emitters into it each frame (_draw), so the simulation stays testable without a GPU
            self.renderer = r^
            self.renderer_samples = samples

    def _draw(mut self, target: WGPUTextureHandle, format: UInt32) raises:
        var t0 = perf_counter_ns()
        var aspect = Real(Float32(self.width) / Float32(self.height))
        var cam = self.scene.camera()
        cam.aspect = aspect
        var view = View(cam, aspect)
        self._ensure(format, view)
        ref r = self.renderer.value()
        r.fxaa_strength = 1.0 if self.fx[FX_FXAA] else 0.0
        r.bloom_intensity = 1.0 if self.fx[FX_BLOOM] else 0.0
        r.lut_amount = 1.0 if self.fx[FX_GRADE] else 0.0
        ref device = self.boot.device()
        r.set_shadow(device, sun_shadow_vp(v3(-0.55, 0.42, 0.5), v3(0.0, 0.0, -2.0), 12.0, 18.0), self.fx[FX_SHADOW])
        var lights = List[PointLight]()
        if self.fx[FX_LIGHTS]:
            for l in self.scene.lights:
                lights.append(PointLight(l.pos, l.range, l.color, l.intensity))
        r.set_lights(device, lights)
        r.begin(view)
        var sky = DrawItem(1, cam.position, 0.0, 0.0, 0.0, 1.0, v3(180, 180, 180), v3(1, 1, 1), -1, -1, MAT_SKY, 0)
        r.push(sky^)
        for it in self.scene.items():
            r.push(it.copy())
        # the scene's particle system is swapped into the pass for the draw and back out after it
        var hud_list = self._hud() if self.hud_on else DrawList()
        self.hud.value().set(hud_list, Float32(self.width), Float32(self.height))
        var parts = self.fx[FX_PARTICLES]  # off: the pass keeps its own empty system, so none are drawn
        if parts:
            swap(r.passes.second.second.system, self.scene.particles)
        r.post_time = Float32(self.scene.time)
        try:
            r.draw(device, target, self.width, self.height, self.hud.value())
        finally:
            if parts:
                swap(r.passes.second.second.system, self.scene.particles)
        self.hud.value().uploaded()
        self.draw_ms = Float32(Float64(perf_counter_ns() - t0) / 1e6)

    def _hud(self) -> DrawList:
        var dl = DrawList()
        var size = Float32(14.0)
        var line = Float32(19.0)
        var panel = Color(0.02, 0.025, 0.04, 0.62)
        var white = Color(1.0, 1.0, 1.0, 1.0)
        var on_c = Color(0.55, 0.95, 0.6, 1.0)
        var off_c = Color(0.6, 0.6, 0.65, 1.0)
        var x = Float32(14.0)
        var y = Float32(14.0)
        var w = Float32(272.0)
        dl.fill(Rect(x, y, w, line * Float32(FX_COUNT + 4) + 16.0), panel)
        dl.text(Rect(x + 10, y + 8, w - 20, line), "Ludens 視覺效果展示", white, 17.0)
        for i in range(FX_COUNT):
            var yy = y + 8 + line * Float32(i + 1) + 6
            var state = "開" if self.fx[i] else "關"
            dl.text(Rect(x + 10, yy, w - 20, line), "[" + String(i + 1) + "] " + _fx_name(i) + "：" + state, on_c if self.fx[i] else off_c, size)
        var yb = y + 8 + line * Float32(FX_COUNT + 1) + 10
        dl.text(Rect(x + 10, yb, w - 20, line), "剛體 " + String(self.scene.body_count()) + " 個，粒子 " + String(self.scene.live_particles()) + " 個", white, size)
        dl.text(Rect(x + 10, yb + line, w - 20, line), "幀時間 " + _ms(self.frame_ms) + " ms（模擬 " + _ms(self.step_ms) + "，繪製 " + _ms(self.draw_ms) + "）", white, size)
        var hint = "空白鍵：丟十個物體　R：重來　H：隱藏說明　拖曳滑鼠：轉動鏡頭"
        dl.fill(Rect(x, Float32(self.height) - 40, 470.0, 26), panel)
        dl.text(Rect(x + 10, Float32(self.height) - 36, 450.0, 20), hint, white, size)
        return dl^

    def _capture(mut self, format: UInt32) raises:
        if self.want_capture and not self.capture_req:
            if not self.capture:
                self.capture = FrameCapture(self.boot.device(), self.width, self.height)
                self.capture_target = self.boot.device().create_texture(
                    self.width, self.height, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC,
                    label="showcase_capture",
                )
            var target = self.capture_target.value().handle().raw
            self._draw(target, format)
            self.capture_req = self.capture.value().capture(self.boot.device(), target)
            self.want_capture = False

    def _finish_capture(mut self) raises:
        if self.capture_req and self.capture_req.value().ready():
            var req = self.capture_req.take()
            self.capture_ptr = UInt64(Int(req.take()))

    def _frame_draw(mut self) raises -> Int32:
        if not self.boot.step():
            return 0
        if self.offscreen:
            # headless checks never touch the canvas (headless Chrome loses the device after a canvas draw)
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


def _ms(v: Float32) -> String:
    var t = Int(v * 10.0 + 0.5)
    return String(t // 10) + "." + String(t % 10)


def _host(handle: UInt64) -> Pointer[Host, MutUntrackedOrigin]:
    return Pointer[Host, MutUntrackedOrigin](unsafe_from_address=Int(handle))


@export
def showcase_init(selector: UInt64, selector_len: UInt64, width: UInt32, height: UInt32) abi("C") -> UInt64:
    """Create the host on the canvas matching `selector` (UTF-8). 0 on failure."""
    try:
        var bytes = Span(unsafe_ptr=Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(selector)), length=Int(selector_len))
        var p = raw_alloc[Host](1)
        p.unsafe_write(Host(String(StringSlice(unsafe_from_utf8=bytes)), width, height))
        return UInt64(Int(p))
    except e:
        print("showcase_init:", e)
        return 0


@export
def showcase_frame(app: UInt64, dt: Float64) abi("C") -> Int32:
    """Advance one frame. 0 = setting up, 1 = drew a frame, -1 = error."""
    try:
        return _host(app)[].frame(dt)
    except e:
        print("showcase_frame:", e)
        return -1


@export
def showcase_set_frame_ms(app: UInt64, ms: Float64) abi("C"):
    _host(app)[].frame_ms = Float32(ms)


@export
def showcase_timing(app: UInt64, which: Int32) abi("C") -> Float64:
    """0: the scene's step in the last frame, ms; 1: the draw (encode and submit), ms."""
    var h = _host(app)
    return Float64(h[].step_ms) if which == 0 else Float64(h[].draw_ms)


@export
def showcase_input(app: UInt64, kind: Int32, key: Int32, action: Int32, mods: Int32, x: Float64, y: Float64) abi("C"):
    _host(app)[].input.process_event(MojoInputEvent(kind, key, action, mods, x, y))


@export
def showcase_release_input(app: UInt64) abi("C"):
    _host(app)[].input.release_all()


@export
def showcase_load_font(app: UInt64, ptr: UInt64, length: UInt64) abi("C") -> Int32:
    """An `.lfont` (the engine's NotoSansTC-Regular-24): the HUD draws its text from it. 0 = ok, -1 = it does not parse."""
    try:
        var h = _host(app)
        var bytes = List[UInt8](length=Int(length), fill=0)
        var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(ptr))
        for i in range(Int(length)):
            bytes[i] = src[i]
        _ = SdfFont(bytes.copy())  # parse here so a bad file is reported to the page
        h[].font = bytes^
        h[].hud = None  # made again with the atlas on the next frame
        return 0
    except e:
        print("showcase_load_font:", e)
        return -1


@export
def showcase_toggle(app: UInt64, which: Int32, on: Int32) abi("C") -> Int32:
    """Switch effect `which` (FX_MSAA .. FX_PARTICLES, the keys 1 .. 7 minus one). Returns the new state, -1 if out of range."""
    if which < 0 or Int(which) >= FX_COUNT:
        return -1
    _host(app)[].toggle(Int(which), on != 0)
    return 1 if on != 0 else 0


@export
def showcase_fx(app: UInt64, which: Int32) abi("C") -> Int32:
    if which < 0 or Int(which) >= FX_COUNT:
        return -1
    return 1 if _host(app)[].fx[Int(which)] else 0


@export
def showcase_stat(app: UInt64, which: Int32) abi("C") -> Int64:
    """0 bodies, 1 live particles, 2 drops, 3 spark bursts, 4 physics ticks, 5 the renderer's sample count, 6 draw calls,
    7 triangles of the last draw."""
    var h = _host(app)
    if which == 0:
        return Int64(h[].scene.body_count())
    if which == 1:
        return Int64(h[].scene.live_particles())
    if which == 2:
        return Int64(h[].scene.drops)
    if which == 3:
        return Int64(h[].scene.bursts)
    if which == 4:
        return Int64(h[].scene.tick)
    if which == 5:
        return Int64(h[].renderer_samples)
    if which == 6:
        return Int64(h[].renderer.value().counts.draws) if h[].renderer else -1
    if which == 7:
        return Int64(h[].renderer.value().counts.triangles) if h[].renderer else -1
    return -1


@export
def showcase_hash(frames: Int32) abi("C") -> UInt64:
    """The scene alone (no GPU) after `frames` frames of 1/60 s from the page's seed: tests/showcase_native.mojo prints the
    same number natively."""
    try:
        var s = Showcase(SEED)
        for _ in range(Int(frames)):
            s.step(1.0 / 60.0, 0.0, 0.0)
        return s.hash()
    except e:
        print("showcase_hash:", e)
        return 0


@export
def showcase_hold(app: UInt64, on: Int32) abi("C"):
    """1: the scene stops advancing (frames still draw), so two captures show the same moment; 0: it runs again."""
    _host(app)[].hold = on != 0


@export
def showcase_advance(app: UInt64, seconds: Float64) abi("C") -> Int32:
    """Step the scene by `seconds` (in frames of 1/60 s) without drawing: with showcase_hold a recording steps the scene by
    exactly the time it wants between two captures. 0 = ok, -1 = error."""
    try:
        var h = _host(app)
        var n = Int(seconds * 60.0 + 0.5)
        for _ in range(n):
            h[].scene.step(1.0 / 60.0, 0.0, 0.0)
        return 0
    except e:
        print("showcase_advance:", e)
        return -1


@export
def showcase_hud(app: UInt64, on: Int32) abi("C"):
    """Show (1) or hide (0) the HUD, as the H key does."""
    _host(app)[].hud_on = on != 0


@export
def showcase_offscreen(app: UInt64, on: Int32) abi("C"):
    _host(app)[].offscreen = on != 0


@export
def showcase_request_capture(app: UInt64) abi("C"):
    _host(app)[].want_capture = True


@export
def showcase_capture_ptr(app: UInt64) abi("C") -> UInt64:
    return _host(app)[].capture_ptr


@export
def showcase_capture_pitch(app: UInt64) abi("C") -> UInt32:
    return padded_row_pitch(_host(app)[].width)


@export
def showcase_capture_release(app: UInt64) abi("C"):
    var h = _host(app)
    h[].capture_ptr = 0
    if h[].capture:
        h[].capture.value().unmap()
