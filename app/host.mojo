"""The playground's browser host for the Frontier: boot, input, one frame per call, capture for checks.

It follows the engine's `app/main.mojo` for the one mode this package runs (the Frontier, behind `GameMode`), and reuses
the engine's renderer and HUD modules unchanged (`render3d`, `hud`, `controls`). The page is `page/`, which loads this
module with the engine's JavaScript runtime."""
from controls import read_keys
from frontier.mode import FrontierMode
from game.camera_view import View
from game.controls import Controls
from geometry.vec import Real
from scene import Scene
from hud import Hud
from render3d import ArenaRenderer
from app.mesh_pass import MeshRegistry, unit_cube_arrays
from app.shadow_pass import ShadowPass
from app.ao_grid import ao_grid, AO_N, AO_X0, AO_SIZE
from std.math import sqrt
from app.net_predict import PredictRun, run_predict_coupled, PREDICT_T, PREDICT_SEED
from app.net_fracture import FractureNetResult, run_fracture_session
from app.skin_pass import build_palette_root, cpu_skin, palette_to_mats
from app.skin_gpu import GpuSkinning, SkinJob
from app.skin_pass import CpuSkinning, Skinning
from frontier_assets import Character, parse_character, parse_ltexture, pose_palette, rest_palette, locals_at, pose_palette_frame, pose_palette_clip
from motion_match import build_match, m6_hash
from app.town_motion import TownMotion
from net_frontier import run_session, script, NP, FrontierSim
from gameplay.netcode import SnapshotClient
from crowd import CrowdState, CrowdRow, positions_hash
from town import Town, RESIDENTS, CONTACT_R
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
from std.math import atan2, cos, sin
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
    var bench_draw: Bool  # step 7 timing: draw every frame into the offscreen target, no readback
    var frame_ms: Float32
    var prot: List[Float64]  # the protagonist: drawn x, z, heading; player x, z; velocity heading (W3 check)
    var audio: Optional[Scene]  # W8: the audio scene (48 kHz), made by playground_host_audio_init
    var audio_goal: Int  # W8: the clip played when a zone goal is reached; -1 until set
    var audio_played: Int  # W8: sounds started on the scene
    var audio_rendered: Int  # W8: frames rendered for the page's worklet
    var goal_seen: Int  # W8: goals the sound has answered
    var cesium: Optional[Character]
    var fox: Optional[Character]
    var fox_clips: List[Character]  # the Fox's Survey (100), Walk (101) and Run (102) from the same file, in that order
    var wall: Optional[List[List[UInt8]]]
    var ground: Optional[List[List[UInt8]]]  # the rock texture for the flat ground tiles (layer 2)
    var ground_loaded: Bool
    var fox_tex: Optional[List[List[UInt8]]]  # the Fox's own base colour (layer 3), from its GLB
    var fox_tex_loaded: Bool
    var no_tex: Bool  # debug (?notex): the ground and Fox textures are not uploaded, so the same frame shows the untextured look
    var clock: Float64  # seconds of animation, advanced per frame
    var placed: Bool  # the meshes and the wall texture are registered with the renderer
    var skin_cesium: Int
    var skin_fox: Int
    var wall_mesh: Int  # the unit cube on the mesh pass, for the taller scenery (walls, boxes); -1 until registered
    var crowd: Optional[CrowdState]  # the crowd of step 7 (ecs entities, flow field), None until asked for
    var crowd_ext: Bool  # W11: the crowd's rows come from the worker (playground_host_crowd_feed); the page does not step it
    var ext_rows: List[CrowdRow]  # W11: the worker's rows for this frame
    var town: Optional[Town]  # the town's residents (ORCA, corner routes) and a guard; None until asked for
    var town_motion: Optional[TownMotion]  # E1: the town's characters' clips by motion matching on their velocity
    var contacts: Int  # W6: the guard touched the player (the player is sent back to the hub)
    var reset_player: Bool  # W6: set by a contact this frame, acted on after the draw
    var knock_pending: Bool  # B4: a contact this frame knocks the guard down (a figure on ball joints in its place)
    var knock_pos: Vec3
    var knock_dir: Vec3
    var guard_down: Int  # B4: frames left with the skinned guard hidden while its figure lies on the ground
    var tex_job: Optional[TexReadback]
    var b3_job: Optional[B3Job]
    var palette_dropped: Int  # skinned members that did not fit PALETTE_MATRICES, counted since the page started
    var tier_near: Int  # crowd members drawn in the near tier last frame (reference baseline A)
    var tier_mid: Int
    var tier_far: Int
    var crowd_culled: Int  # W11: crowd members outside the view, not skinned, counted since the page started
    var crowd_lod: Bool  # W11: the far-member LOD is on (default); playground_host_crowd_lod(app, 0) turns it off for the palette-drop check
    var palette_used: Int  # matrices in the last frame's skinned palette
    var shadow: Optional[ShadowPass]  # the sun's depth pass into the mesh pass's shadow map; made on the first shadowed frame
    var shadow_on: Bool  # ?noshadow turns the shadow factor and its pass off; on by default
    var ao_on: Bool  # ?noao turns the ambient-occlusion term off; on by default (W10)
    var ao_done: Bool  # the AO grid was filled by the GPU trace and set on the mesh pass (once, on the first frame)
    var net_run: Optional[PredictRun]  # step 8: the three-colour netcode run for player 0 (server, predicted, shown)
    var net_on: Bool  # the markers are drawn while on
    var fracnet: Optional[FractureNetResult]  # C: the last fracture replication run; its server and client 0 walls are drawn
    var net_frame: Int  # the frame counter that steps through the run, one run frame per draw

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
        self.bench_draw = False
        self.frame_ms = 0
        self.prot = List[Float64]()
        self.audio = None
        self.audio_goal = -1
        self.audio_played = 0
        self.audio_rendered = 0
        self.goal_seen = 0
        self.cesium = None
        self.fox = None
        self.fox_clips = List[Character]()
        self.wall = None
        self.ground = None
        self.ground_loaded = False
        self.fox_tex = None
        self.fox_tex_loaded = False
        self.no_tex = False
        self.clock = 0.0
        self.placed = False
        self.skin_cesium = -1
        self.skin_fox = -1
        self.wall_mesh = -1
        self.crowd = None
        self.town = None
        self.town_motion = None
        self.crowd_ext = False
        self.ext_rows = List[CrowdRow]()
        self.contacts = 0
        self.reset_player = False
        self.knock_pending = False
        self.knock_pos = Vec3(Real(0.0), Real(0.0), Real(0.0), Real(0.0))
        self.knock_dir = Vec3(Real(0.0), Real(0.0), Real(0.0), Real(0.0))
        self.guard_down = 0
        self.tex_job = None
        self.b3_job = None
        self.palette_dropped = 0
        self.tier_near = 0
        self.tier_mid = 0
        self.tier_far = 0
        self.crowd_culled = 0
        self.crowd_lod = True
        self.palette_used = 0
        self.shadow = None
        self.shadow_on = True
        self.ao_on = True
        self.ao_done = False
        self.net_run = None
        self.net_on = False
        self.fracnet = None
        self.net_frame = 0

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
        self.bench_draw = move.bench_draw
        self.frame_ms = move.frame_ms
        self.prot = move.prot^
        self.audio = move.audio^
        self.audio_goal = move.audio_goal
        self.audio_played = move.audio_played
        self.audio_rendered = move.audio_rendered
        self.goal_seen = move.goal_seen
        self.cesium = move.cesium^
        self.fox = move.fox^
        self.fox_clips = move.fox_clips^
        self.wall = move.wall^
        self.ground = move.ground^
        self.ground_loaded = move.ground_loaded
        self.fox_tex = move.fox_tex^
        self.fox_tex_loaded = move.fox_tex_loaded
        self.no_tex = move.no_tex
        self.clock = move.clock
        self.placed = move.placed
        self.skin_cesium = move.skin_cesium
        self.skin_fox = move.skin_fox
        self.wall_mesh = move.wall_mesh
        self.crowd = move.crowd^
        self.crowd_ext = move.crowd_ext
        self.ext_rows = move.ext_rows.copy()
        self.town = move.town^
        self.town_motion = move.town_motion^
        self.contacts = move.contacts
        self.reset_player = move.reset_player
        self.knock_pending = move.knock_pending
        self.knock_pos = move.knock_pos
        self.knock_dir = move.knock_dir
        self.guard_down = move.guard_down
        self.tex_job = move.tex_job^
        self.shadow = move.shadow^
        self.shadow_on = move.shadow_on
        self.ao_on = move.ao_on
        self.ao_done = move.ao_done
        self.b3_job = move.b3_job^
        self.palette_dropped = move.palette_dropped
        self.tier_near = move.tier_near
        self.tier_mid = move.tier_mid
        self.tier_far = move.tier_far
        self.crowd_culled = move.crowd_culled
        self.crowd_lod = move.crowd_lod
        self.palette_used = move.palette_used
        self.net_run = move.net_run^
        self.net_on = move.net_on
        self.fracnet = move.fracnet^
        self.net_frame = move.net_frame

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
            self.renderer = ArenaRenderer(self.boot.device(), format, view, texture_layers=4)  # layers: white, wall, ground, the Fox
        self._register()
        self.renderer.value().begin(view)
        # the mesh items that cast shadows: static meshes only (the skinned characters are not in the shadow pass yet)
        var shadow_items = List[DrawItem]()
        for it in m.scene():
            var item = it.copy()
            if item.kind == 0:  # the scenery (ground tiles, walls, boxes) is textured on the mesh pass
                item.material = 2
                if self.wall_mesh >= 0:
                    if self.ground_loaded and item.half[1] <= Real(0.1):  # the flat ground tiles (half height 0.05) on layer 2
                        item.layer = 2
                    item.mesh_id = self.wall_mesh  # walls keep layer 1
                    item.half = item.half * Real(2.0)  # the unit cube has half-extent 0.5; the mesh pass scales it by half
            if item.mesh_id >= 0:
                shadow_items.append(item.copy())
            self.renderer.value().push(item)
        if self.net_on and self.net_run:
            self._net_markers()
        if self.fracnet:
            self._fracnet_walls()
        var cview = View(m.camera(), Real(Float64(self.width) / Float64(self.height)))  # the crowd's visible set (W11 LOD)
        self._characters(m.world.player_pos(), m.world.player_vel(), cview)  # read while the world is held here, not inside _characters
        self.hud.value().set(m.hud(Float32(self.width), Float32(self.height), self.frame_ms), Float32(self.width), Float32(self.height))
        # the sun's depth pass, then the arena pass samples its shadow map (the factor is 1.0 with ?noshadow)
        var light = _light_vp()
        self.renderer.value().mesh.set_shadow(self.boot.device(), light, self.shadow_on)
        if self.ao_on and not self.ao_done:  # W10: the floor's occlusion, traced on the GPU over the pillars once
            var cells = ao_grid(m.world.static_boxes(-20.0, -20.0, 20.0, 20.0, 1.0))
            self.renderer.value().mesh.set_ao(self.boot.device(), cells, AO_N, AO_N, AO_X0, AO_X0, AO_SIZE, AO_SIZE, True)
            m.world.ao = True  # the HUD names the term (W10)
            self.ao_done = True
        if self.shadow_on:
            if not self.shadow:
                self.shadow = ShadowPass(self.boot.device(), WGPUTextureFormat.Depth32Float)
            var sview = self.renderer.value().mesh.shadow_tex.create_view_default()
            # the characters, the crowd and the town cast too: their skinned items, and the palette the skin pass reads this frame
            for it in self.renderer.value().items:
                if it.pose_id >= 0 and it.mesh_id >= 0:
                    shadow_items.append(it.copy())
            var pal = self.renderer.value().skin_palette.copy()
            self.shadow.value().draw(self.boot.device(), shadow_items, self.renderer.value().meshes, light, sview^, pal)
        self.renderer.value().draw(self.boot.device(), target, self.width, self.height, self.hud.value())
        self.world = m^

    def _net_markers(mut self) raises:
        """Step 8 (frontier_plan.md line 206): three markers for player 0 from the netcode run, one run frame per draw.
        Green is the server's truth, blue the predicted sim, red the client that shows the newest snapshot. Each sits on
        its own row in the world, so the three can be compared by eye as the frame advances."""
        var n = len(self.net_run.value().frames)
        if n == 0:
            return
        var fr = self.net_run.value().frames[self.net_frame % n].copy()
        self.net_frame += 1
        var sx = Real(Float64(fr.server_mm) / 1000.0)
        var px = Real(Float64(fr.predicted_mm) / 1000.0)
        var hx = Real(Float64(fr.shown_mm) / 1000.0)
        var r = Real(0.25)
        self.renderer.value().push(DrawItem(1, Vec3(sx, Real(0.3), Real(-6.0), Real(0.0)), 0.0, 0.0, 0.0, 1.0, Vec3(r, r, r, Real(0.0)), Vec3(Real(0.2), Real(0.9), Real(0.3), Real(0.0))))
        self.renderer.value().push(DrawItem(1, Vec3(px, Real(0.3), Real(-5.0), Real(0.0)), 0.0, 0.0, 0.0, 1.0, Vec3(r, r, r, Real(0.0)), Vec3(Real(0.2), Real(0.5), Real(1.0), Real(0.0))))
        self.renderer.value().push(DrawItem(1, Vec3(hx, Real(0.3), Real(-4.0), Real(0.0)), 0.0, 0.0, 0.0, 1.0, Vec3(r, r, r, Real(0.0)), Vec3(Real(1.0), Real(0.35), Real(0.2), Real(0.0))))

    def _fracnet_walls(mut self) raises:
        """C: the fracture replication run's last state, the server's wall at x = -5.5 and client 0's at x = +5.5, both
        12 m north of the hub (z - 14). A box per fragment (as the quarry's), and the crate. Same poses, side by side."""
        for side in range(2):
            var ints = self.fracnet.value().server_ints.copy() if side == 0 else self.fracnet.value().client_ints.copy()
            var off = Vec3(Real(-5.5) if side == 0 else Real(5.5), Real(0.0), Real(-14.0), Real(0.0))
            var col = Vec3(Real(0.55), Real(0.5), Real(0.45), Real(0.0)) if side == 0 else Vec3(Real(0.35), Real(0.5), Real(0.75), Real(0.0))
            var nfr = (len(ints) - 3) // 8
            if ints[2] != 0:
                nfr = (len(ints) - 3 - 7) // 8
            var k = 3
            for i in range(nfr + (1 if ints[2] != 0 else 0)):
                var crate = i == nfr
                if not crate:
                    if ints[k] == 0:
                        k += 8
                        continue
                    k += 1
                var pos = Vec3(Real(Float64(ints[k]) / 1000.0), Real(Float64(ints[k + 1]) / 1000.0), Real(Float64(ints[k + 2]) / 1000.0), Real(0.0)) + off
                var qx = Float64(ints[k + 3]) / 1e6
                var qy = Float64(ints[k + 4]) / 1e6
                var qz = Float64(ints[k + 5]) / 1e6
                var qw = Float64(ints[k + 6]) / 1e6
                k += 7
                var half = Vec3(Real(0.6), Real(0.6), Real(0.6), Real(0.0)) if crate else Vec3(Real(0.3), Real(0.3), Real(0.15), Real(0.0))
                var c = Vec3(Real(0.3), Real(0.3), Real(0.32), Real(0.0)) if crate else col
                self.renderer.value().push(DrawItem(0, pos, qx, qy, qz, qw, half, c))

    def _register(mut self) raises:
        """Once both characters and the wall are on the page: their meshes and the texture layer go to the renderer.
        The ground texture is uploaded on its own, as soon as both it and the renderer are there."""
        if self.ground and not self.ground_loaded and self.renderer and not self.no_tex:
            self.renderer.value().textures.load_layer(self.boot.device(), UInt32(2), self.ground.value().copy())
            self.ground_loaded = True
        if self.fox_tex and not self.fox_tex_loaded and self.renderer and not self.no_tex:
            self.renderer.value().textures.load_layer(self.boot.device(), UInt32(3), self.fox_tex.value().copy())
            self.fox_tex_loaded = True
        if self.placed or not self.cesium or not self.fox or not self.wall:
            return
        var c = self.cesium.value().copy()
        self.skin_cesium = self.renderer.value().meshes.add_skinned(c.positions.copy(), c.normals.copy(), c.uv.copy(), c.joints.copy(), c.weights.copy(), c.indices.copy())
        var f = self.fox.value().copy()
        self.skin_fox = self.renderer.value().meshes.add_skinned(f.positions.copy(), f.normals.copy(), f.uv.copy(), f.joints.copy(), f.weights.copy(), f.indices.copy())
        self.renderer.value().textures.load_layer(self.boot.device(), UInt32(1), self.wall.value().copy())
        var cube = unit_cube_arrays()
        self.wall_mesh = self.renderer.value().meshes.add_static(cube[0].copy(), cube[1].copy(), cube[2].copy(), cube[3].copy())
        self.placed = True

    def _characters(mut self, player: Vec3, vel: Vec3, view: View) raises:
        """Each frame: the two characters' palettes (one clip sampled at the clock, the rest pose's ancestors applied),
        their skinned draw items, and the palette buffer the renderer reads."""
        if not self.placed:
            return
        var c = self.cesium.value().copy()
        var f = self.fox.value().copy()
        var pal = pose_palette(c, self.clock)
        var fox_base = c.joint_count
        # the circling Fox walks at 1.5 m/s, so it keeps the Walk clip (plan W3: the four-second cycle is gone)
        var fx = self.fox_clips[1].copy() if len(self.fox_clips) == 3 else f.copy()
        var pal_fox = pose_palette(fx, self.clock)
        pal.extend(pal_fox^)
        # the protagonist (plan W3): the Fox at the player's position, its clip chosen by the player's speed
        var speed = sqrt(vel[0] * vel[0] + vel[2] * vel[2])
        var pclip = f.copy()
        if len(self.fox_clips) == 3:
            if speed < 0.2:
                pclip = self.fox_clips[0].copy()
            elif speed < 6.0:
                pclip = self.fox_clips[1].copy()
            else:
                pclip = self.fox_clips[2].copy()
        var player_base = len(pal) // 16
        pal.extend(pose_palette(pclip, self.clock)^)
        # crowd (step 7): the live backend's members, each at its own clip phase, one palette each after the two above.
        # The palette is a list of floats, 16 per matrix; pose_id is a matrix index.
        var crowd_rows = List[CrowdRow]()
        var crowd_bases = List[Int]()
        var crowd_idx = List[Int]()  # the row of each base: the members the palette holds, in the frustum
        if self.crowd:
            if self.crowd_ext:
                crowd_rows = self.ext_rows.copy()
            else:
                var cs = self.crowd.take()
                cs.step(Real(1.0 / 60.0))
                crowd_rows = cs.positions()
                self.crowd = cs^
            # Tiers (reference baseline A, after AC Unity's crowd: 40 full AIs, 120 high-res models, the rest low-res). The
            # visible members are ordered by whole metres to the eye (a counting sort over HIST_BINS one-metre bins, O(n)).
            # The nearest NEAR_TIER and the next MID_TIER get their own pose at their own clip phase; the rest are far and
            # share one table of TABLE_FRAMES poses of the walk clip (slot = clip offset mod TABLE_FRAMES), so the palette
            # does not grow with the crowd. A near or mid member that would not fit the palette is dropped with the rest
            # after it and counted in palette_dropped.
            # W11 LOD: a member outside the view (20 % margin) gets no pose and no draw; its row is still stepped.
            var vis = List[Int]()
            var dist = List[Int]()
            for k in range(len(crowd_rows)):
                var inside = True
                if self.crowd_lod:
                    var cp = view.project(Vec3(Real(crowd_rows[k].x), Real(0.9), Real(crowd_rows[k].z), Real(0.0)))
                    inside = cp.w > view.near and abs(cp.x) <= cp.w * Real(1.2) and abs(cp.y) <= cp.w * Real(1.2)
                if not inside:
                    self.crowd_culled += 1
                    continue
                var dx = Float64(crowd_rows[k].x) - Float64(view.eye[0])
                var dz = Float64(crowd_rows[k].z) - Float64(view.eye[2])
                vis.append(k)
                dist.append(min(Int((dx * dx + dz * dz) ** 0.5), HIST_BINS - 1))
            var start = List[Int]()
            for _ in range(HIST_BINS + 1):
                start.append(0)
            for d in dist:
                start[d + 1] += 1
            for b in range(HIST_BINS):
                start[b + 1] += start[b]
            var order = List[Int]()
            for _ in range(len(vis)):
                order.append(0)
            for i in range(len(vis)):
                order[start[dist[i]]] = vis[i]
                start[dist[i]] += 1
            self.tier_near = 0
            self.tier_mid = 0
            self.tier_far = 0
            var table_base = -1
            for j in range(len(order)):
                var k = order[j]
                if j < NEAR_TIER + MID_TIER:
                    if len(pal) // 16 + c.joint_count > PALETTE_MATRICES:
                        self.palette_dropped += len(order) - j
                        break
                    var fr = (Int(self.clock * Float64(c.fps)) + crowd_rows[k].offset) % c.frames
                    crowd_bases.append(len(pal) // 16)
                    crowd_idx.append(k)
                    pal.extend(pose_palette_frame(c, fr))
                    if j < NEAR_TIER:
                        self.tier_near += 1
                    else:
                        self.tier_mid += 1
                else:
                    if table_base < 0:
                        if len(pal) // 16 + TABLE_FRAMES * c.joint_count > PALETTE_MATRICES:
                            self.palette_dropped += len(order) - j
                            break
                        table_base = len(pal) // 16
                        var now = Int(self.clock * Float64(c.fps))
                        for tf in range(TABLE_FRAMES):
                            pal.extend(pose_palette_frame(c, (now + tf * c.frames // TABLE_FRAMES) % c.frames))
                    var slot = ((crowd_rows[k].offset % TABLE_FRAMES) + TABLE_FRAMES) % TABLE_FRAMES
                    crowd_bases.append(table_base + slot * c.joint_count)
                    crowd_idx.append(k)
                    self.tier_far += 1
        # the town (plan stage 3): 24 residents and the guard, each a CesiumMan at its ORCA position, its clip phase spread
        var town_rows = List[Vec3]()
        var town_bases = List[Int]()
        var town_guard = -1  # W6: the guard's row, drawn in a distinct colour
        var town_yaw = List[Float64]()  # E1: each character turned to face its velocity
        if self.town:
            var tn = self.town.take()
            town_guard = tn.guard
            for k in range(len(tn.crowd.pos)):
                if len(pal) // 16 + c.joint_count > PALETTE_MATRICES:
                    self.palette_dropped += len(tn.crowd.pos) - k
                    break
                town_bases.append(len(pal) // 16)
                if self.town_motion:
                    ref tm = self.town_motion.value()
                    pal.extend(pose_palette_clip(c, c.motion[tm.kind(k)], tm.frame_index(k)))
                    town_yaw.append(Float64(tm.yaw(k)))
                else:
                    var fr = (Int(self.clock * Float64(c.fps)) + 7 * k) % c.frames
                    pal.extend(pose_palette_frame(c, fr))
                    town_yaw.append(0.0)
                town_rows.append(tn.crowd.pos[k])
            self.town = tn^
        self.palette_used = len(pal) // 16
        self.renderer.value().skin_palette = pal^
        # the Fox walks a circle of radius 6 m round the hub's centre and faces its direction of travel (a yaw about +Y;
        # the glTF model faces +Z)
        var ang = self.clock * 0.25
        var fpos = Vec3(Real(6.0 * cos(ang)), Real(0.0), Real(6.0 * sin(ang)), Real(0.0))
        var heading = atan2(-sin(ang), cos(ang))
        var half_h = heading * 0.5
        # the Fox's glTF units are centimetres: 78.9 units tall, so scale 0.01 gives 0.79 m (U10)
        self.renderer.value().push(DrawItem(
            -1, fpos, 0.0, sin(half_h), 0.0, cos(half_h),
            Vec3(Real(0.01), Real(0.01), Real(0.01), Real(0.0)), Vec3(Real(0.9), Real(0.85), Real(0.7), Real(0.0)),
            self.skin_fox, fox_base, 1 if self.fox_tex_loaded else 0, 3,  # material 1 and layer 3 once the Fox's texture is up
        ))
        # the protagonist: the Fox at the player's feet. Its heading is the velocity's, kept while the player stands still;
        # the model faces +Z, so a yaw of atan2(vx, vz) about +Y points it along the velocity.
        var prot_heading = self.prot[2]
        if speed >= 0.2:
            prot_heading = Float64(atan2(vel[0], vel[2]))
        var prot_feet = Vec3(player[0], player[1] - Real(1.0), player[2], Real(0.0))
        var ph = prot_heading * 0.5  # Float64, like the circling Fox's half angle
        self.renderer.value().push(DrawItem(
            -1, prot_feet, 0.0, sin(ph), 0.0, cos(ph),
            Vec3(Real(0.01), Real(0.01), Real(0.01), Real(0.0)), Vec3(Real(0.9), Real(0.85), Real(0.7), Real(0.0)),
            self.skin_fox, player_base, 1 if self.fox_tex_loaded else 0, 3,
        ))
        self.prot = List[Float64]()
        self.prot.append(Float64(prot_feet[0]))
        self.prot.append(Float64(prot_feet[2]))
        self.prot.append(prot_heading)
        self.prot.append(Float64(player[0]))
        self.prot.append(Float64(player[2]))
        self.prot.append(Float64(atan2(vel[0], vel[2])) if speed >= 0.2 else prot_heading)
        # the crowd: each member at its position on the floor (the flow field's), feet on the ground
        for k in range(len(crowd_bases)):  # the members that fit the palette and the view (the rest were dropped above)
            var r = crowd_rows[crowd_idx[k]]
            var pos = Vec3(Real(r.x), Real(0.0), Real(r.z), Real(0.0))
            self.renderer.value().push(DrawItem(
                -1, pos, 0.0, 0.0, 0.0, 1.0,
                Vec3(Real(1.0), Real(1.0), Real(1.0), Real(0.0)), Vec3(Real(0.6), Real(0.75), Real(0.9), Real(0.0)),
                self.skin_cesium, crowd_bases[k], 0,
            ))

        for k in range(len(town_rows)):
            if k == town_guard and self.guard_down > 0:
                continue  # B4: the guard's figure lies on the ground (the Frontier draws it)
            var tp = town_rows[k]
            var pos = Vec3(tp[0], Real(0.0), tp[2], Real(0.0))
            var hy = town_yaw[k] * 0.5
            self.renderer.value().push(DrawItem(
                -1, pos, 0.0, sin(hy), 0.0, cos(hy),
                Vec3(Real(1.0), Real(1.0), Real(1.0), Real(0.0)),
                Vec3(Real(0.85), Real(0.12), Real(0.1), Real(0.0)) if k == town_guard else Vec3(Real(0.9), Real(0.6), Real(0.4), Real(0.0)),
                self.skin_cesium, town_bases[k], 0,
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
        self._town_step(m)
        self.world = m^
        self._audio_goals()
        var rc = self._frame_draw()
        # Every frame ends here, drawn or not: a key edge or a pointer movement lasts exactly one frame.
        self.input.begin_frame()
        return rc

    def _town_step(mut self, mut m: FrontierMode) raises:
        """The town steps with the simulation, not the draw: an offscreen page (no draw) still runs its residents and guard.
        W6: a guard contact sends the player back to the hub on the next frame. B4: it also knocks the guard down."""
        if self.guard_down > 0:
            self.guard_down -= 1
        if self.reset_player:
            self.reset_player = False
            m.world.teleport(0.0, 0.0)
        if self.knock_pending:
            self.knock_pending = False
            m.world.knock_down(self.knock_pos, self.knock_dir)
        if not self.town:
            return
        var player = m.world.player_pos()
        var tn = self.town.take()
        tn.step(Real(1.0 / 60.0), player)
        # E1: each character's clip and frame by motion matching on its velocity (built once CesiumMan is on the page)
        if not self.town_motion and self.cesium and len(self.cesium.value().motion) > 0:
            self.town_motion = TownMotion(self.cesium.value(), len(tn.crowd.pos))
        if self.town_motion:
            self.town_motion.value().step(Real(1.0 / 60.0), tn.crowd.vel)
        if tn.guard_distance(player) < CONTACT_R:
            self.contacts += 1
            self.reset_player = True
            # B4: the tackle knocks the guard down: a figure on ball joints falls where it stood, pushed toward the player
            var gp = tn.crowd.pos[tn.guard]
            var dx = player[0] - gp[0]
            var dz = player[2] - gp[2]
            var dl = (dx * dx + dz * dz) ** Real(0.5)
            self.knock_pending = True
            self.knock_pos = gp
            self.knock_dir = Vec3(dx / dl, Real(0.0), dz / dl, Real(0.0)) if dl > Real(1e-6) else Vec3(Real(1.0), Real(0.0), Real(0.0), Real(0.0))
            self.guard_down = 180
        self.town = tn^

    def _audio_goals(mut self) raises:
        """W8: each zone goal reached starts the goal sound once."""
        if not self.audio or not self.world:
            return
        var gc = self.world.value().world.goal_count
        while self.goal_seen < gc:
            self.goal_seen += 1
            if self.audio_goal >= 0:
                self.audio.value().play(self.audio_goal, 1.0)
                self.audio_played += 1

    def _frame_draw(mut self) raises -> Int32:
        if not self.boot.step():
            return 0
        if self.offscreen:
            # Never touch the canvas: headless Chrome loses the device after a canvas draw.
            if self.bench_draw:
                # Timing (step 7): the whole scene is drawn into the target every frame; no readback.
                if not self.capture_target:
                    self.capture_target = self.boot.device().create_texture(
                        self.width, self.height, 1, WGPUTextureFormat.RGBA8Unorm,
                        WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC,
                        label="bench_target",
                    )
                self._draw(self.capture_target.value().handle().raw, WGPUTextureFormat.RGBA8Unorm)
                self._capture(WGPUTextureFormat.RGBA8Unorm)  # a requested capture still works in this mode
                self._finish_capture()
                return 1
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


# the skinned palette holds this many matrices (the engine's limit); a member takes one matrix per joint
comptime PALETTE_MATRICES = 4096
comptime NEAR_TIER = 40  # crowd tiers (reference baseline A): own pose, nearest
comptime MID_TIER = 120  # own pose, next nearest
comptime TABLE_FRAMES = 16  # far members share this many poses of the walk clip
comptime HIST_BINS = 64  # one-metre distance bins for the tier ordering; farther than 63 m falls in the last


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
def playground_host_set_frame_ms(app: UInt64, ms: Float64) abi("C"):
    """The page's measured frame time (ms, around the previous playground_host_frame call); the HUD shows it."""
    _host(app)[].frame_ms = Float32(ms)


@export
def playground_host_debug(app: UInt64, on: Int32) abi("C") -> Int32:
    """W9: the HUD shows the streaming counters (?debug). Returns 0, or -1 when there is no Frontier world yet."""
    var h = _host(app)
    if not h[].world:
        return -1
    h[].world.value().world.debug = on != 0
    return 0


@export
def playground_host_frame_ms(app: UInt64) abi("C") -> Float64:
    """The frame time the HUD shows, in ms. 0 until the page has reported one."""
    return Float64(_host(app)[].frame_ms)


@export
def playground_host_input(app: UInt64, kind: Int32, key: Int32, action: Int32, mods: Int32, x: Float64, y: Float64) abi("C"):
    """One input event from the page (the same codes the engine's app_input takes: GLFW keys and buttons)."""
    _host(app)[].input.process_event(MojoInputEvent(kind, key, action, mods, x, y))


@export
def playground_host_release_input(app: UInt64) abi("C"):
    _host(app)[].input.release_all()


def _light_vp() -> List[Float32]:
    """The sun's orthographic view-projection, 16 floats column-major, z in [0, 1]. The sun sits along (0.4, 1.0, 0.6),
    the mesh shader's light direction, and looks back along it at the origin: half-extent 12 m across the view, depth
    from -30 m to 30 m along it (nearer the sun is smaller). The hub frame lies inside the 12 m square."""
    var lx = 0.4
    var ly = 1.0
    var lz = 0.6
    var ln = sqrt(lx * lx + ly * ly + lz * lz)
    # the view direction f points away from the sun
    var fx = -lx / ln
    var fy = -ly / ln
    var fz = -lz / ln
    # r = normalize(f x (0, 0, 1)) = (f.y, -f.x, 0); u = r x f
    var rl = sqrt(fy * fy + fx * fx)
    var rx = fy / rl
    var ry = -fx / rl
    var rz = 0.0
    var ux = ry * fz - rz * fy
    var uy = rz * fx - rx * fz
    var uz = rx * fy - ry * fx
    var half = 12.0
    var depth = 60.0  # the depth range: 30 m either side of the origin
    var m = List[Float32]()
    # column 0: the right axis, the up axis and the view axis over (half, half, depth), then 0
    m.append(Float32(rx / half)); m.append(Float32(ux / half)); m.append(Float32(fx / depth)); m.append(0.0)
    m.append(Float32(ry / half)); m.append(Float32(uy / half)); m.append(Float32(fy / depth)); m.append(0.0)
    m.append(Float32(rz / half)); m.append(Float32(uz / half)); m.append(Float32(fz / depth)); m.append(0.0)
    # column 3: the translation that maps the depth range [-30, 30] to [0, 1]
    m.append(0.0); m.append(0.0); m.append(0.5); m.append(1.0)
    return m^


@export
def playground_host_ao(app: UInt64, on: Int32) abi("C"):
    """The ambient-occlusion term (W10): on by default, off for ?noao. Set before the first frame it takes effect at once."""
    _host(app)[].ao_on = on != 0


@export
def playground_host_shadow(app: UInt64, on: Int32) abi("C"):
    """The shadow factor and the sun's depth pass: on by default, off for ?noshadow (the unshadowed colour)."""
    _host(app)[].shadow_on = on != 0


@export
def playground_host_offscreen(app: UInt64, on: Int32) abi("C"):
    """Draw only into the capture target, never the canvas (headless checks)."""
    _host(app)[].offscreen = on != 0


@export
def playground_host_bench_draw(app: UInt64, on: Int32) abi("C"):
    """Step 7 timing: with offscreen, draw every frame into the target (no readback), so the frame time includes the draw."""
    _host(app)[].bench_draw = on != 0


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
    """A converted asset from the page: 1 CesiumMan.lcharacter, 2 Fox.lcharacter, 3 concrete_wall_003.ltexture. The bytes
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
            h[].fox_clips = List[Character]()
            h[].fox_clips.append(parse_character(bytes, 100))
            h[].fox_clips.append(parse_character(bytes, 101))
            h[].fox_clips.append(parse_character(bytes, 102))
        elif kind == 3:
            h[].wall = parse_ltexture(bytes)
        elif kind == 4:
            h[].ground = parse_ltexture(bytes)
        elif kind == 5:
            h[].fox_tex = parse_ltexture(bytes)
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
def playground_host_netview(app: UInt64, on: Int32, latency: Int32, jitter: Int32, loss_permille: Int32) abi("C") -> Int32:
    """Step 8: the three-colour netcode view for player 0 (server truth, predicted, shown) on the page's link. on 0 hides
    the markers; on 1 runs the session for this link and draws the markers from it. Returns 0; -3 if a slider is out of
    range; -2 if the run failed (printed)."""
    var h = _host(app)
    h[].net_on = on != 0
    if not h[].net_on:
        return 0
    if latency < 0 or latency > 30 or jitter < 0 or jitter > 10 or loss_permille < 0 or loss_permille > 500:
        return -3
    try:
        h[].net_run = run_predict_coupled(Int(latency), Int(jitter), Real(Float64(loss_permille) / 1000.0), PREDICT_SEED, PREDICT_T)
        h[].net_frame = 0
        return 0
    except e:
        print("playground_host_netview:", e)
        return -2


@export
def playground_host_netview_stat(app: UInt64, which: Int32) abi("C") -> Int32:
    """Step 8: the last netview run, in millimetres. 0 the worst per-tick predicted error, 1 the worst error after the
    idle window, 2 the worst lag of the shown client behind the predicted sim, 3 the snapshot ticks compared, 4 1 when
    player 0 equals the truth at T, 5 1 when the whole world hash equals the server's at T. Returns -1 when no run exists, -2 for an unknown stat."""
    var h = _host(app)
    if not h[].net_run:
        return -1
    if which == 0:
        return Int32(h[].net_run.value().worst_predicted_mm)
    if which == 1:
        return Int32(h[].net_run.value().worst_idle_mm)
    if which == 2:
        return Int32(h[].net_run.value().worst_lag_mm)
    if which == 3:
        return Int32(h[].net_run.value().ticks_checked)
    if which == 4:
        return Int32(1) if h[].net_run.value().p0_equal_at_end else Int32(0)
    if which == 5:
        return Int32(1) if h[].net_run.value().world_equal_at_end else Int32(0)
    return -2


@export
def playground_host_fracture_net(app: UInt64, latency: Int32, jitter: Int32, loss_permille: Int32) abi("C") -> Int32:
    """Reference baseline C: the fractured wall's session (app/net_fracture.mojo) over SimLinks with these settings, run
    to tick 240. 1 when both clients reach it, their read-back hashes equal the server's and the fragments have settled;
    0 otherwise; -3 if a setting is out of range; -2 on an error. The run's last state is kept and drawn in the hub."""
    if latency < 0 or latency > 30 or jitter < 0 or jitter > 10 or loss_permille < 0 or loss_permille > 500:
        return -3
    try:
        var r = run_fracture_session(Int(latency), Int(jitter), Real(Float64(loss_permille) / 1000.0), UInt64(1234), 240)
        var ok = r.all_at_T and r.hashes_equal and r.settled
        _host(app)[].fracnet = r^
        return 1 if ok else 0
    except e:
        print("playground_host_fracture_net:", e)
        return -2


@export
def playground_host_fracture_net_stat(app: UInt64, which: Int32) abi("C") -> Int32:
    """The last fracture run: 0 events, 1-3 fragments moved over 100 mm on the server, client 0, client 1, 4 server bytes
    over the break's 60 ticks, 5 over the settled last 30, 6 hashes equal, 7 settled, 8 frames. -1 before a run."""
    ref h = _host(app)[]
    if not h.fracnet:
        return -1
    ref r = h.fracnet.value()
    if which == 0:
        return Int32(r.events)
    if which == 1:
        return Int32(r.moved_server)
    if which == 2:
        return Int32(r.moved_client0)
    if which == 3:
        return Int32(r.moved_client1)
    if which == 4:
        return Int32(r.bytes_break)
    if which == 5:
        return Int32(r.bytes_settled)
    if which == 6:
        return 1 if r.hashes_equal else 0
    if which == 7:
        return 1 if r.settled else 0
    if which == 8:
        return Int32(r.frames)
    return -1


@export
def playground_host_net_check(latency: Int32, jitter: Int32, loss_permille: Int32) abi("C") -> Int32:
    """Step 8 (netcode): the Frontier's session over SnapshotServer and SnapshotClient through a lossy SimLink, with the
    page's sliders: latency in ticks (0 to 30), jitter in ticks (0 to 10), loss in tenths of a percent (0 to 500). The
    default (4, 3, 100) is the check the HUD ran before the sliders. Returns the reference hash (mod 1000000007) when every
    client reaches tick 120 and every client and the server equal it; -1 otherwise; -3 if a slider is out of range."""
    if latency < 0 or latency > 30 or jitter < 0 or jitter > 10 or loss_permille < 0 or loss_permille > 500:
        return -3
    try:
        var r = run_session(Int(latency), Int(jitter), Real(Float64(loss_permille) / 1000.0), UInt64(2026), 120)
        if r[0] and r[1]:
            return Int32(r[2])
        return -1
    except e:
        print("playground_host_net_check:", e)
        return -2


# Step 8, second module: the page's clients. Each client is a SnapshotClient over the Frontier's sim; the bytes it sends
# and receives go through the server module (app/server_host.mojo) in a Worker, with the link delay applied on the page.
comptime CLIENT_MODULUS = UInt64(1000000007)


struct ClientPeer(Movable):
    var c: SnapshotClient[FrontierSim]
    var node: Int
    var out: List[UInt8]

    def __init__(out self, node: Int):
        self.c = SnapshotClient[FrontierSim](FrontierSim(NP), node)
        self.node = node
        self.out = List[UInt8]()


def _peer(handle: UInt64) -> Pointer[ClientPeer, MutUntrackedOrigin]:
    return Pointer[ClientPeer, MutUntrackedOrigin](unsafe_from_address=Int(handle))


@export
def playground_host_client_new(node: Int32) abi("C") -> UInt64:
    """A client for node `node` (0 .. NP-1). 0 if the node is out of range."""
    if node < 0 or node >= Int32(NP):
        return 0
    var p = raw_alloc[ClientPeer](1)
    p.unsafe_write(ClientPeer(Int(node)))
    return UInt64(Int(p))


@export
def playground_host_client_submit(handle: UInt64, f: Int32, total: Int32) abi("C") -> Int32:
    """The client's input for tick `f`, if it has not yet reached `total` (as run_session does). 0."""
    var s = _peer(handle)
    if s[].c.newest < Int(total):
        s[].c.submit(script(s[].node, Int(f)))
    return 0


@export
def playground_host_client_outgoing(handle: UInt64, to_node: Int32) abi("C") -> Int32:
    """The bytes for node `to_node` (read them with playground_host_client_out_ptr). Returns the length."""
    var s = _peer(handle)
    var m = s[].c.outgoing(Int(to_node))
    s[].out = m^
    return Int32(len(s[].out))


@export
def playground_host_client_out_ptr(handle: UInt64) abi("C") -> UInt64:
    var s = _peer(handle)
    return UInt64(Int(s[].out.unsafe_ptr()))


@export
def playground_host_client_receive(handle: UInt64, from_node: Int32, ptr: UInt64, length: Int32) abi("C") -> Int32:
    """A message from node `from_node`: `length` bytes at `ptr` in this module's memory. 0, or -1 if it was refused."""
    var s = _peer(handle)
    var msg = List[UInt8]()
    var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(ptr))
    for k in range(Int(length)):
        msg.append(src[k])
    try:
        s[].c.receive(Int(from_node), msg)
        return 0
    except e:
        print("playground_host_client_receive:", e)
        return -1


@export
def playground_host_client_newest(handle: UInt64) abi("C") -> Int32:
    """The newest tick this client has a snapshot for."""
    return Int32(_peer(handle)[].c.newest)


@export
def playground_host_client_hash(handle: UInt64) abi("C") -> Int32:
    """The client's world hash, mod 1000000007 (the number playground_host_net_check returns)."""
    return Int32(Int(_peer(handle)[].c.world_hash() % CLIENT_MODULUS))

@export
def playground_host_crowd(app: UInt64, n: Int32) abi("C") -> Int32:
    """Step 7: a crowd of n members (0 removes it): ecs entities in both backends, moved by the flow field, drawn as
    skinned CesiumMan. Returns n; -1 if n is out of range; -2 if the crowd could not be built (printed); -4 if the
    characters on the page and the crowd would need more than PALETTE_MATRICES matrices (the town's residents count, once
    the assets are up). A member that does not fit when the town is switched on after the crowd is dropped and counted
    in playground_host_palette_dropped."""
    var h = _host(app)
    if n < 0 or n > 4096:
        return -1
    if n == 0:
        h[].crowd = None
        return 0
    if h[].placed:
        var per = h[].cesium.value().copy().joint_count
        var fixed = per + h[].fox.value().copy().joint_count
        var residents = 0
        if h[].town:
            residents = len(h[].town.value().crowd.pos)
        var need = fixed + (residents + min(Int(n), NEAR_TIER + MID_TIER)) * per + TABLE_FRAMES * per  # far members share the table
        if need > PALETTE_MATRICES:
            return -4
    try:
        h[].crowd = CrowdState(Int(n), h[].world.value().world.static_boxes(-20.0, -20.0, 20.0, 20.0, 1.0))
        return n
    except e:
        print("playground_host_crowd:", e)
        return -2


@export
def playground_host_crowd_tiers(app: UInt64, which: Int32) abi("C") -> Int32:
    """Reference baseline A: crowd members drawn last frame in tier which (0 near, 1 mid, 2 far). -1 for another which."""
    var h = _host(app)
    if which == 0:
        return Int32(h[].tier_near)
    if which == 1:
        return Int32(h[].tier_mid)
    if which == 2:
        return Int32(h[].tier_far)
    return -1


@export
def playground_host_frontier_stat(app: UInt64, which: Int32) abi("C") -> Int32:
    """The Frontier world's numbers (frontier/world.mojo STAT_*): cells loaded and total, props live and total, drawn,
    culled, loads, unloads, the zone the player is in, the tick. -1 when there is no Frontier world yet or which is out
    of range."""
    var h = _host(app)
    if not h[].world:
        return -1
    try:
        return Int32(h[].world.value().world.stat(Int(which)))
    except e:
        print("playground_host_frontier_stat:", e)
        return -1


@export
def playground_host_frontier_teleport(app: UInt64, x: Int32, z: Int32) abi("C") -> Int32:
    """Put the player at (x, z) metres at once, and stream for that place (fast travel). Returns 0; -1 when there is no
    Frontier world; -2 if the teleport failed (printed)."""
    var h = _host(app)
    if not h[].world:
        return -1
    var m = h[].world.take()
    try:
        m.world.teleport(Real(Float64(x)), Real(Float64(z)))
        h[].world = m^
        return 0
    except e:
        print("playground_host_frontier_teleport:", e)
        h[].world = m^
        return -2


@export
def playground_host_palette_used(app: UInt64) abi("C") -> Int32:
    """Step 7: matrices in the last frame's skinned palette (the characters, the crowd and the town)."""
    return Int32(_host(app)[].palette_used)


@export
def playground_host_palette_dropped(app: UInt64) abi("C") -> Int32:
    """Step 7: skinned members dropped because the palette was full, counted since the page started."""
    return Int32(_host(app)[].palette_dropped)


@export
def playground_host_town(app: UInt64, on: Int32) abi("C") -> Int32:
    """The town (plan stage 3): 24 ORCA residents on corner routes and a guard that closes on the player. on=0 removes
    them. Returns the number of residents, or -2 if the town could not be built (printed)."""
    var h = _host(app)
    if on == 0:
        h[].town = None
        return 0
    try:
        if not h[].world:
            print("playground_host_town: the Frontier world is not there yet")
            return -2
        h[].town = Town(h[].world.value().world.static_boxes(96.0, 96.0, 160.0, 160.0, 1.0))
        return Int32(RESIDENTS)
    except e:
        print("playground_host_town:", e)
        return -2


@export
def playground_host_town_on_screen(app: UInt64) abi("C") -> Int32:
    """Debug (resident-visibility check): how many town members project inside the view (in front of the camera and
    within the frustum), counted from the camera the page is drawing with. -1 if the town or the world is not there."""
    var h = _host(app)
    if not h[].town or not h[].world:
        return -1
    var m = h[].world.take()
    var view = View(m.camera(), Real(Float64(h[].width) / Float64(h[].height)))
    h[].world = m^
    var tn = h[].town.take()
    var n: Int32 = 0
    for k in range(len(tn.crowd.pos)):
        var p = tn.crowd.pos[k]
        var c = view.project(Vec3(p[0], Real(0.9), p[2], Real(0.0)))
        if c.w > view.near and abs(c.x) <= c.w and abs(c.y) <= c.w:
            n += 1
    h[].town = tn^
    return n


@export
def playground_host_crowd_lod(app: UInt64, on: Int32) abi("C") -> Int32:
    """W11 LOD: on=1 (default) skins only the members in the view; on=0 skins every member that fits the palette, so the
    palette-drop path can be checked from any camera. Returns the setting."""
    _host(app)[].crowd_lod = on != 0
    return on


@export
def playground_host_crowd_culled(app: UInt64) abi("C") -> Int32:
    """W11 LOD: crowd members outside the view since the page started (not skinned, not drawn)."""
    return Int32(_host(app)[].crowd_culled)


@export
def playground_host_notex(app: UInt64, on: Int32) abi("C"):
    """Debug (?notex): on=1 keeps the ground and Fox textures out of the GPU, for a controlled untextured comparison."""
    _host(app)[].no_tex = on != 0


@export
def playground_host_crowd_switch(app: UInt64) abi("C") -> Int32:
    """The HUD's backend switch: flips the live backend of the crowd and returns 1 for the naive backend, 0 for the
    sparse-set one; -1 if there is no crowd."""
    var h = _host(app)
    if not h[].crowd:
        return -1
    var cs = h[].crowd.take()
    try:
        cs.switch()
    except e:
        print("playground_host_crowd_switch:", e)
        h[].crowd = cs^
        return -2
    var naive = 1 if cs.use_naive else 0
    h[].crowd = cs^
    return Int32(naive)


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


@export
def playground_host_protagonist(app: UInt64, which: Int32) abi("C") -> Float64:
    """W3: the protagonist as last drawn and the player's own state. 0 drawn x, 1 drawn z, 2 drawn heading (rad),
    3 player x, 4 player z, 5 velocity heading (rad). 0 until the first frame with the Fox placed."""
    var h = _host(app)
    if len(h[].prot) != 6 or which < 0 or which > 5:
        return 0.0
    return h[].prot[Int(which)]


@export
def playground_host_crowd_hash_after(app: UInt64, n: Int32, ticks: Int32) abi("C") -> Int32:
    """W11 parity: a fresh crowd of n members on the hub's pillars, stepped `ticks` times at 1/60 s, hashed with
    positions_hash. The worker runs the same steps; equal hashes are the check. -1 if there is no Frontier world yet."""
    var h = _host(app)
    if not h[].world:
        return -1
    try:
        var boxes = h[].world.value().world.static_boxes(-20.0, -20.0, 20.0, 20.0, 1.0)
        var cs = CrowdState(Int(n), boxes)
        for _ in range(Int(ticks)):
            cs.step(Real(1.0 / 60.0))
        return Int32(positions_hash(cs.positions()))
    except e:
        print("playground_host_crowd_hash_after:", e)
        return -2


@export
def playground_host_pillar_count(app: UInt64) abi("C") -> Int32:
    """W11: the hub's pillar boxes that the crowd's floor uses (static_boxes over -20..20 m, half height over 1 m)."""
    var h = _host(app)
    if not h[].world:
        return -1
    return Int32(len(h[].world.value().world.static_boxes(-20.0, -20.0, 20.0, 20.0, 1.0)))


@export
def playground_host_pillar(app: UInt64, i: Int32, k: Int32) abi("C") -> Float64:
    """Value k (0..5: centre x, y, z, then half x, y, z) of pillar box i. 0 when out of range."""
    var h = _host(app)
    if not h[].world:
        return 0.0
    var boxes = h[].world.value().world.static_boxes(-20.0, -20.0, 20.0, 20.0, 1.0)
    if i < 0 or Int(i) >= len(boxes) or k < 0 or k > 5:
        return 0.0
    var b = boxes[Int(i)]
    if k < 3:
        return Float64(b.c[Int(k)])
    return Float64(b.h[Int(k) - 3])


@export
def playground_host_crowd_ext(app: UInt64, on: Int32) abi("C") -> Int32:
    """W11: the crowd's rows come from the worker (on=1) or from the page's own step (on=0). Returns 0, or -1 without a crowd."""
    var h = _host(app)
    if not h[].crowd:
        return -1
    h[].crowd_ext = on != 0
    return 0


@export
def playground_host_crowd_feed(app: UInt64, ptr: UInt64, n: Int32) abi("C") -> Int32:
    """W11: the worker's rows for this frame: n members, 4 f32 each (x, z, offset, goal) at wasm address ptr. 0, or -1."""
    var h = _host(app)
    var src = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(ptr))
    var rows = List[CrowdRow]()
    for i in range(Int(n)):
        rows.append(CrowdRow(Real(Float64(src.unsafe_offset(4 * i)[])), Real(Float64(src.unsafe_offset(4 * i + 1)[])),
                             Int(src.unsafe_offset(4 * i + 2)[]), Int(src.unsafe_offset(4 * i + 3)[])))
    h[].ext_rows = rows^
    return 0


@export
def playground_host_town_ai(app: UInt64, which: Int32) abi("C") -> Int32:
    """Reference baselines D1 and D2: 0 the residents' behavior-tree transitions since the town was switched on, 1 the
    residents in the watch branch now, 2 whether the guard saw the player on the last tick (1 or 0). -1 without a town."""
    var h = _host(app)
    if not h[].town:
        return -1
    if which == 0:
        return Int32(h[].town.value().bt.transitions)
    if which == 1:
        return Int32(h[].town.value().watching())
    if which == 2:
        return 1 if h[].town.value().guard_sees else 0
    return -1


@export
def playground_host_town_motion(app: UInt64, which: Int32) abi("C") -> Int32:
    """E1: the town's motion matching. 0 the guard's clip kind (101..107), 1 residents on a walk, 2 residents on the run,
    3 clip switches so far, 4 the guard's speed in mm/s. -1 before the matching is built."""
    ref h = _host(app)[]
    if not h.town_motion or not h.town:
        return -1
    ref tm = h.town_motion.value()
    ref tn = h.town.value()
    if which == 0:
        return Int32(101 + tm.kind(tn.guard))
    if which == 1 or which == 2:
        var n = 0
        for a in range(len(tm.clip)):
            if a == tn.guard:
                continue
            var run = tm.kind(a) == 6
            if (which == 2) == run:
                n += 1
        return Int32(n)
    if which == 3:
        return Int32(tm.switches)
    if which == 4:
        var v = tn.crowd.vel[tn.guard]
        return Int32(Int(((v[0] * v[0] + v[1] * v[1]) ** 0.5) * 1000.0))
    return -1


@export
def playground_host_contacts(app: UInt64) abi("C") -> Int32:
    """W6: how many times the town's guard has touched the player since the town was switched on."""
    return Int32(_host(app)[].contacts)


# W8: the page's audio. The page decodes its .lsound files to stereo f32 and registers them; the mix is rendered on request
# and sent to an AudioWorklet (the page has no SharedArrayBuffer on Pages).
comptime AUDIO_RATE: UInt32 = 48000


@export
def playground_host_audio_init(app: UInt64) abi("C") -> Int32:
    var h = _host(app)
    if h[].audio:
        return 0
    try:
        h[].audio = Scene(AUDIO_RATE)
        return 0
    except e:
        print("playground_host_audio_init:", e)
        return -2


@export
def playground_host_audio_clip(app: UInt64, ptr: UInt64, frames: Int32) abi("C") -> Int32:
    """Register `frames` stereo frames (interleaved L R f32) at wasm address ptr as a clip. Returns the clip id, -1 if there is no scene."""
    var h = _host(app)
    if not h[].audio:
        return -1
    var src = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(ptr))
    var samples = List[Float32]()
    for i in range(Int(frames) * 2):
        samples.append(src.unsafe_offset(i)[])
    try:
        return Int32(h[].audio.value().add_clip_pcm(samples))
    except e:
        print("playground_host_audio_clip:", e)
        return -1


@export
def playground_host_audio_goal(app: UInt64, clip: Int32) abi("C") -> Int32:
    """The clip played when a zone goal is reached."""
    _host(app)[].audio_goal = Int(clip)
    return 0


@export
def playground_host_audio_render(app: UInt64, dst: UInt64, frames: Int32) abi("C") -> Int32:
    """Render `frames` frames of the mix into wasm address dst (interleaved stereo f32). 0, or -1/-2."""
    var h = _host(app)
    if not h[].audio:
        return -1
    var out = List[Float32]()
    try:
        h[].audio.value().render(out, UInt64(frames))
    except e:
        print("playground_host_audio_render:", e)
        return -2
    var dstp = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(dst))
    for i in range(len(out)):
        dstp.unsafe_offset(i)[] = out[i]
    h[].audio_rendered += Int(frames)
    return 0


@export
def playground_host_audio_played(app: UInt64) abi("C") -> Int32:
    """Sounds started on the scene (one per zone goal)."""
    return Int32(_host(app)[].audio_played)


@export
def playground_host_audio_rendered(app: UInt64) abi("C") -> Int32:
    """Frames rendered for the worklet so far."""
    return Int32(_host(app)[].audio_rendered)
