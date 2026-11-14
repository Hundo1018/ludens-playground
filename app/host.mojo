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
from wgpu._backend.wgpu_native.alloc_guard import raw_alloc
from wgpu._ffi.types import WGPUTextureFormat, WGPUTextureHandle, WGPUTextureUsage
from wgpu.buffer import MapRequest
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.rendercanvas.glfw import MojoInputEvent
from wgpu.rendercanvas.input import InputState
from wgpu.surface import Surface, create_surface_canvas
from wgpu.texture import Texture
from wgpu.web.boot import GPUBoot


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
        self.renderer.value().begin(view)
        for it in m.scene():
            self.renderer.value().push(it)
        self.hud.value().set(m.hud(Float32(self.width), Float32(self.height), self.frame_ms), Float32(self.width), Float32(self.height))
        self.renderer.value().draw(self.boot.device(), target, self.width, self.height, self.hud.value())
        self.world = m^

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
