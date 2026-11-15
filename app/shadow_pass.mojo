"""Step 5 shadow depth pass (docs/PLAN.md): the mesh items drawn into a depth texture from a light, with no fragment stage.

The vertex stage places each instance with its model columns (locations 3 to 6, the mesh pass's instance layout) and the
light's view-projection, a uniform. The pass has no colour attachment; it clears the depth texture on load and stores it.
Its pipeline depth state is the mesh pass's (LessEqual, depth write), so a later sampling pass compares against the
same depths the light saw.
"""
from game.arena import DrawItem
from game.camera_view import View
from geometry.vec import Real, Vec3
from app.textures import TextureArray, TRI_WGSL
from wgpu import (
    WGPUBufferUsage, WGPUShaderStage, WGPU_WHOLE_SIZE, WGPUBufferBindingType,
    WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout, WGPUSamplerBindingLayout,
    WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout, WGPUBindGroupEntry,
    WGPUVertexFormat, WGPUVertexStepMode, WGPUIndexFormat,
)
from wgpu._ffi.nulls import null_opaque, null_ptr
from wgpu._ffi.structs import (
    WGPURenderPipelineDescriptor, WGPUVertexState, WGPUVertexBufferLayout, WGPUVertexAttribute,
    WGPUFragmentState, WGPUColorTargetState, WGPUPrimitiveState, WGPUMultisampleState,
    WGPUDepthStencilState, WGPUStencilFaceState, WGPUBlendState, WGPUConstantEntry, WGPUStringView,
)
from wgpu._backend.wgpu_native.structs import str_to_sv
from wgpu._ffi.types import WGPUTextureFormat
from wgpu._backend.wgpu_native.alloc_guard import raw_alloc
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.pipeline import RenderPipeline
from wgpu.bind_group import BindGroup
from wgpu.render_pass import FrameRenderPass
from wgpu._ffi.structs import (
    WGPURenderPassDescriptor, WGPURenderPassColorAttachment, WGPURenderPassDepthStencilAttachment,
    WGPUPassTimestampWrites,
)
from wgpu.pipeline_layout import PipelineLayout
from wgpu.shader import ShaderModule
from wgpu.pipeline_layout import PipelineLayout
from wgpu.render_pass import RenderPassEncoder
from wgpu.command import CommandEncoder
from wgpu.texture import TextureView
from app.mesh_pass import MeshRegistry, model_floats, FLOATS_PER_INSTANCE, MAX_MESH_INSTANCES
from app.skin_gpu import SKIN_FN

comptime SHADOW_WGSL = """
struct Light {
  vp : mat4x4<f32>,
}
@group(0) @binding(0) var<uniform> light : Light;

struct VsIn {
  @location(0) pos : vec3<f32>,
  @location(3) m0 : vec4<f32>,
  @location(4) m1 : vec4<f32>,
  @location(5) m2 : vec4<f32>,
  @location(6) m3 : vec4<f32>,
}

@vertex
fn vs_main(i : VsIn) -> @builtin(position) vec4<f32> {
  let model = mat4x4<f32>(i.m0, i.m1, i.m2, i.m3);
  return light.vp * model * vec4<f32>(i.pos, 1.0);
}
"""

# the skinned casters: the engine's skinning arithmetic (SKIN_FN, the source the drawn character uses), at the palette
# base the instance carries in info.x. Only positions are needed for depth.
comptime SKIN_SHADOW_WGSL = """
struct Light {
  vp : mat4x4<f32>,
}
@group(0) @binding(0) var<uniform> light : Light;
@group(0) @binding(1) var<storage, read> palette : array<mat4x4<f32>>;
""" + SKIN_FN + """

struct SkVsIn {
  @location(0) pos : vec3<f32>,
  @location(3) m0 : vec4<f32>,
  @location(4) m1 : vec4<f32>,
  @location(5) m2 : vec4<f32>,
  @location(6) m3 : vec4<f32>,
  @location(8) info : vec4<f32>,
  @location(9) joints : vec4<u32>,
  @location(10) weights : vec4<f32>,
}

@vertex
fn vs_skin(i : SkVsIn) -> @builtin(position) vec4<f32> {
  let base = u32(i.info.x);
  let local = skin_position(i.pos, i.joints, i.weights, base);
  let model = mat4x4<f32>(i.m0, i.m1, i.m2, i.m3);
  return light.vp * model * vec4<f32>(local, 1.0);
}
"""

# the palette holds at most this many matrices (the engine's skinned limit); the storage buffer is sized for it
comptime MAX_PALETTE_MATRICES = 4096


def _build_pipeline(
    device: Device, shader: ShaderModule, layout: PipelineLayout, depth_format: UInt32,
) raises -> RenderPipeline:
    """Vertex buffers: 0 positions (per vertex), 1 the instance records (locations 3 to 6). No fragment stage, no
    colour targets: the pass has a depth attachment only."""
    var a0 = raw_alloc[WGPUVertexAttribute](1)
    a0[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x3, UInt64(0), UInt32(0))
    var ai = raw_alloc[WGPUVertexAttribute](4)
    ai[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(0), UInt32(3))
    ai[unsafe_offset=1] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(16), UInt32(4))
    ai[unsafe_offset=2] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(32), UInt32(5))
    ai[unsafe_offset=3] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(48), UInt32(6))
    var vb = raw_alloc[WGPUVertexBufferLayout](2)
    vb[unsafe_offset=0] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Vertex, UInt64(12), UInt(1), a0)
    vb[unsafe_offset=1] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Instance, UInt64(96), UInt(4), ai)
    var vertex_state = WGPUVertexState(
        null_opaque(), shader.handle().raw, str_to_sv("vs_main"),
        UInt(0), null_ptr[WGPUConstantEntry](),
        UInt(2), vb,
    )
    var primitive = WGPUPrimitiveState(null_opaque(), 4, UInt32(0), UInt32(1), UInt32(0), UInt32(0))
    var multisample = WGPUMultisampleState(null_opaque(), UInt32(1), UInt32(0xFFFFFFFF), UInt32(0))
    var face = WGPUStencilFaceState(UInt32(8), UInt32(1), UInt32(1), UInt32(1))
    var dp = raw_alloc[WGPUDepthStencilState](1)
    dp[unsafe_offset=0] = WGPUDepthStencilState(
        null_opaque(), depth_format, UInt32(1), UInt32(4), face, face,
        UInt32(0xFFFFFFFF), UInt32(0xFFFFFFFF), Int32(0), Float32(0.0), Float32(0.0),
    )
    var label_name = String("shadow_pipeline")
    var desc = WGPURenderPipelineDescriptor(
        null_opaque(), str_to_sv(label_name), layout.handle().raw,
        vertex_state, primitive, dp, multisample, null_ptr[WGPUFragmentState](),
    )
    var result = device.create_render_pipeline(desc^)
    _ = label_name.byte_length()
    a0.unsafe_free()
    ai.unsafe_free()
    vb.unsafe_free()
    dp.unsafe_free()
    return result^


def _build_skin_pipeline(
    device: Device, shader: ShaderModule, layout: PipelineLayout, depth_format: UInt32,
) raises -> RenderPipeline:
    """Vertex buffers: 0 positions, 1 joints (4 x u16), 2 weights (4 x f32), per vertex; 3 the instance records (model
    columns at locations 3 to 6, the palette base at 8). Same depth state as the static pipeline."""
    var a0 = raw_alloc[WGPUVertexAttribute](1)
    a0[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x3, UInt64(0), UInt32(0))
    var a1 = raw_alloc[WGPUVertexAttribute](1)
    a1[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Uint16x4, UInt64(0), UInt32(9))
    var a2 = raw_alloc[WGPUVertexAttribute](1)
    a2[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(0), UInt32(10))
    var ai = raw_alloc[WGPUVertexAttribute](5)
    ai[unsafe_offset=0] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(0), UInt32(3))
    ai[unsafe_offset=1] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(16), UInt32(4))
    ai[unsafe_offset=2] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(32), UInt32(5))
    ai[unsafe_offset=3] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(48), UInt32(6))
    ai[unsafe_offset=4] = WGPUVertexAttribute(null_opaque(), WGPUVertexFormat.Float32x4, UInt64(80), UInt32(8))
    var vb = raw_alloc[WGPUVertexBufferLayout](4)
    vb[unsafe_offset=0] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Vertex, UInt64(12), UInt(1), a0)
    vb[unsafe_offset=1] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Vertex, UInt64(8), UInt(1), a1)
    vb[unsafe_offset=2] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Vertex, UInt64(16), UInt(1), a2)
    vb[unsafe_offset=3] = WGPUVertexBufferLayout(null_opaque(), WGPUVertexStepMode.Instance, UInt64(96), UInt(5), ai)
    var vertex_state = WGPUVertexState(
        null_opaque(), shader.handle().raw, str_to_sv("vs_skin"),
        UInt(0), null_ptr[WGPUConstantEntry](),
        UInt(4), vb,
    )
    var primitive = WGPUPrimitiveState(null_opaque(), 4, UInt32(0), UInt32(1), UInt32(0), UInt32(0))
    var multisample = WGPUMultisampleState(null_opaque(), UInt32(1), UInt32(0xFFFFFFFF), UInt32(0))
    var face = WGPUStencilFaceState(UInt32(8), UInt32(1), UInt32(1), UInt32(1))
    var dp = raw_alloc[WGPUDepthStencilState](1)
    dp[unsafe_offset=0] = WGPUDepthStencilState(
        null_opaque(), depth_format, UInt32(1), UInt32(4), face, face,
        UInt32(0xFFFFFFFF), UInt32(0xFFFFFFFF), Int32(0), Float32(0.0), Float32(0.0),
    )
    var label_name = String("shadow_skin_pipeline")
    var desc = WGPURenderPipelineDescriptor(
        null_opaque(), str_to_sv(label_name), layout.handle().raw,
        vertex_state, primitive, dp, multisample, null_ptr[WGPUFragmentState](),
    )
    var result = device.create_render_pipeline(desc^)
    _ = label_name.byte_length()
    a0.unsafe_free()
    a1.unsafe_free()
    a2.unsafe_free()
    ai.unsafe_free()
    vb.unsafe_free()
    dp.unsafe_free()
    return result^


struct ShadowPass(Movable):
    """The depth-only pipeline, the light's uniform, and the per-mesh buffers uploaded from a MeshRegistry."""

    var pipeline: RenderPipeline
    var group: BindGroup
    var light: Buffer
    var instances: Buffer
    var vbufs: List[Buffer]
    var ibufs: List[Buffer]
    var uploaded: Int
    var depth_format: UInt32
    var skin_pipeline: RenderPipeline
    var skin_group: BindGroup
    var palette_buf: Buffer  # the skinned casters' palette, uploaded per draw (the skin pass's buffer is written later)
    var skin_instances: Buffer
    var skin_vbufs: List[Buffer]  # per skinned mesh: positions, joints, weights
    var skin_ibufs: List[Buffer]
    var skin_uploaded: Int

    def __init__(out self, device: Device, depth_format: UInt32) raises:
        var shader = device.create_shader_module_wgsl(SHADOW_WGSL, "shadow_vs")
        var entries: List[WGPUBindGroupLayoutEntry] = [
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(0), WGPUShaderStage.VERTEX.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
        ]
        var bgl = device.create_bind_group_layout(entries)
        var pl = device.create_pipeline_layout(bgl, "shadow_layout")
        self.pipeline = _build_pipeline(device, shader, pl, depth_format)
        self.light = device.create_buffer(UInt64(64), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="shadow_light")
        var bg_entries: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), UInt32(0), self.light.handle().raw, UInt64(0), UInt64(64), null_opaque(), null_opaque()),
        ]
        self.group = device.create_bind_group(bgl, bg_entries, "shadow_group")
        self.instances = device.create_buffer(
            UInt64(MAX_MESH_INSTANCES * FLOATS_PER_INSTANCE * 4), WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST,
            label="shadow_instances",
        )
        self.vbufs = List[Buffer]()
        self.ibufs = List[Buffer]()
        self.uploaded = 0
        self.depth_format = depth_format
        var skin_shader = device.create_shader_module_wgsl(SKIN_SHADOW_WGSL, "shadow_skin_vs")
        var skin_entries: List[WGPUBindGroupLayoutEntry] = [
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(0), WGPUShaderStage.VERTEX.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
            WGPUBindGroupLayoutEntry(
                null_opaque(), UInt32(1), WGPUShaderStage.VERTEX.value, UInt32(0),
                WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.ReadOnlyStorage, UInt32(0), UInt64(0)),
                WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
                WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
                WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            ),
        ]
        var skin_bgl = device.create_bind_group_layout(skin_entries)
        var skin_pl = device.create_pipeline_layout(skin_bgl, "shadow_skin_layout")
        self.skin_pipeline = _build_skin_pipeline(device, skin_shader, skin_pl, depth_format)
        self.palette_buf = device.create_buffer(
            UInt64(MAX_PALETTE_MATRICES * 64), WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="shadow_palette",
        )
        var skin_bg_entries: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), UInt32(0), self.light.handle().raw, UInt64(0), UInt64(64), null_opaque(), null_opaque()),
            WGPUBindGroupEntry(null_opaque(), UInt32(1), self.palette_buf.handle().raw, UInt64(0), UInt64(MAX_PALETTE_MATRICES * 64), null_opaque(), null_opaque()),
        ]
        self.skin_group = device.create_bind_group(skin_bgl, skin_bg_entries, "shadow_skin_group")
        self.skin_instances = device.create_buffer(
            UInt64(MAX_MESH_INSTANCES * FLOATS_PER_INSTANCE * 4), WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST,
            label="shadow_skin_instances",
        )
        self.skin_vbufs = List[Buffer]()
        self.skin_ibufs = List[Buffer]()
        self.skin_uploaded = 0

    def upload(mut self, device: Device, registry: MeshRegistry) raises:
        """Upload any mesh the registry has that this pass does not hold yet: positions and indices (the shadow pass
        needs no normals or uv)."""
        while self.uploaded < registry.count():
            var m = registry.meshes[self.uploaded].copy()
            var vb_pos = device.create_buffer(UInt64(len(m.positions) * 4), WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST, label="shadow_pos")
            device.queue_write_data(vb_pos, UInt64(0), m.positions)
            var ib = device.create_buffer(UInt64(len(m.indices) * 4), WGPUBufferUsage.INDEX | WGPUBufferUsage.COPY_DST, label="shadow_idx")
            device.queue_write_data(ib, UInt64(0), m.indices)
            self.vbufs.append(vb_pos^)
            self.ibufs.append(ib^)
            self.uploaded += 1

    def upload_skinned(mut self, device: Device, registry: MeshRegistry) raises:
        """Upload the skinned meshes this pass does not hold yet: positions, joints (u16 x 4) and weights per vertex."""
        while self.skin_uploaded < len(registry.skinned):
            var m = registry.skinned[self.skin_uploaded].copy()
            var vb_pos = device.create_buffer(UInt64(len(m.positions) * 4), WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST, label="shadow_skin_pos")
            device.queue_write_data(vb_pos, UInt64(0), m.positions)
            var vb_jt = device.create_buffer(UInt64(len(m.joints) * 2), WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST, label="shadow_skin_jt")
            device.queue_write_data(vb_jt, UInt64(0), m.joints)
            var vb_w = device.create_buffer(UInt64(len(m.weights) * 4), WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST, label="shadow_skin_w")
            device.queue_write_data(vb_w, UInt64(0), m.weights)
            var ib = device.create_buffer(UInt64(len(m.indices) * 4), WGPUBufferUsage.INDEX | WGPUBufferUsage.COPY_DST, label="shadow_skin_idx")
            device.queue_write_data(ib, UInt64(0), m.indices)
            self.skin_vbufs.append(vb_pos^)
            self.skin_vbufs.append(vb_jt^)
            self.skin_vbufs.append(vb_w^)
            self.skin_ibufs.append(ib^)
            self.skin_uploaded += 1

    def draw(
        mut self, device: Device, items: List[DrawItem], registry: MeshRegistry,
        light_vp: List[Float32], depth_view: TextureView, palette: List[Float32],
    ) raises:
        """Write the light's view-projection (16 floats, column-major), upload the meshes, group the mesh items by mesh,
        and draw them into the depth view, cleared to 1.0 on load."""
        if len(light_vp) != 16:
            raise Error("shadow pass: the light's view-projection is 16 floats")
        self.upload(device, registry)
        self.upload_skinned(device, registry)
        device.queue_write_data(self.light, UInt64(0), light_vp)
        # the skinned casters: their palette goes to this pass's own buffer, so the shadow reads this frame's pose
        var skin_order = List[Int]()
        var skin_counts = List[Int]()
        for it in items:
            if it.mesh_id < 0 or it.pose_id < 0:
                continue
            var sfound = -1
            for k in range(len(skin_order)):
                if skin_order[k] == it.mesh_id:
                    sfound = k
            if sfound < 0:
                skin_order.append(it.mesh_id)
                skin_counts.append(0)
                sfound = len(skin_order) - 1
            skin_counts[sfound] += 1
        var skin_total = 0
        for c in skin_counts:
            skin_total += c
        if skin_total > MAX_MESH_INSTANCES:
            raise Error("shadow pass: more skinned instances than MAX_MESH_INSTANCES")
        if skin_total > 0:
            if len(palette) == 0 or len(palette) % 16 != 0 or len(palette) // 16 > MAX_PALETTE_MATRICES:
                raise Error("shadow pass: the skinned palette is 16 floats per matrix, at most MAX_PALETTE_MATRICES matrices")
            device.queue_write_data(self.palette_buf, UInt64(0), palette)
        var order = List[Int]()
        var counts = List[Int]()
        for it in items:
            if it.mesh_id < 0 or it.pose_id >= 0:
                continue
            var found = -1
            for k in range(len(order)):
                if order[k] == it.mesh_id:
                    found = k
            if found < 0:
                order.append(it.mesh_id)
                counts.append(0)
                found = len(order) - 1
            counts[found] += 1
        var total = 0
        for c in counts:
            total += c
        if total > MAX_MESH_INSTANCES:
            raise Error("shadow pass: more instances than MAX_MESH_INSTANCES")
        var floats = List[Float32]()
        var base = List[Int]()
        var running = 0
        for k in range(len(order)):
            base.append(running)
            for it in items:
                if it.mesh_id == order[k] and it.pose_id < 0:
                    model_floats(it, floats)
                    running += 1
        if total > 0:
            device.queue_write_data(self.instances, UInt64(0), floats)
        # skinned instance records: the mesh pass's layout, with the palette base in info.x (record float 20)
        var skin_floats = List[Float32]()
        var skin_base = List[Int]()
        var skin_running = 0
        for k in range(len(skin_order)):
            skin_base.append(skin_running)
            for it in items:
                if it.mesh_id == skin_order[k] and it.pose_id >= 0:
                    var rec = len(skin_floats)
                    model_floats(it, skin_floats)
                    skin_floats[rec + 20] = Float32(it.pose_id)
                    skin_running += 1
        if skin_total > 0:
            device.queue_write_data(self.skin_instances, UInt64(0), skin_floats)

        var depth_att_p = raw_alloc[WGPURenderPassDepthStencilAttachment](1)
        depth_att_p[unsafe_offset=0] = WGPURenderPassDepthStencilAttachment(
            null_opaque(),
            depth_view.handle().raw,
            UInt32(2),  # depth load: Clear
            UInt32(1),  # depth store: Store
            Float32(1.0),
            UInt32(0),
            UInt32(0), UInt32(0), UInt32(0), UInt32(0),  # stencil: unused
        )
        var rp_desc_p = raw_alloc[WGPURenderPassDescriptor](1)
        rp_desc_p[unsafe_offset=0] = WGPURenderPassDescriptor(
            null_opaque(),
            str_to_sv("shadow_depth"),
            UInt(0),
            null_ptr[WGPURenderPassColorAttachment](),
            depth_att_p,
            null_opaque(),
            null_ptr[WGPUPassTimestampWrites](),
        )
        # The encoder is created last, after every call that can raise: an encoder abandoned on an error path is a
        # compile error (linear types), so nothing that can raise may sit between its creation and its finish.
        var enc = device.create_command_encoder("shadow_enc")
        var rpass = enc.begin_render_pass(rp_desc_p)
        rp_desc_p.unsafe_free()
        depth_att_p.unsafe_free()
        if len(order) > 0:
            rpass.set_pipeline(self.pipeline)
            rpass.set_bind_group(UInt32(0), self.group)
            rpass.set_vertex_buffer(UInt32(1), self.instances, UInt64(0), UInt64(total * FLOATS_PER_INSTANCE * 4))
            for k in range(len(order)):
                var mid = order[k]
                var m = registry.meshes[mid].copy()
                rpass.set_vertex_buffer(UInt32(0), self.vbufs[mid], UInt64(0), UInt64(len(m.positions) * 4))
                rpass.set_index_buffer(self.ibufs[mid], WGPUIndexFormat.Uint32, UInt64(0), UInt64(len(m.indices) * 4))
                rpass.draw_indexed(UInt32(len(m.indices)), UInt32(counts[k]), UInt32(0), Int32(0), UInt32(base[k]))
        if len(skin_order) > 0:
            rpass.set_pipeline(self.skin_pipeline)
            rpass.set_bind_group(UInt32(0), self.skin_group)
            rpass.set_vertex_buffer(UInt32(3), self.skin_instances, UInt64(0), UInt64(skin_total * FLOATS_PER_INSTANCE * 4))
            for k in range(len(skin_order)):
                var smid = skin_order[k]
                var sm = registry.skinned[smid].copy()
                rpass.set_vertex_buffer(UInt32(0), self.skin_vbufs[3 * smid], UInt64(0), UInt64(len(sm.positions) * 4))
                rpass.set_vertex_buffer(UInt32(1), self.skin_vbufs[3 * smid + 1], UInt64(0), UInt64(len(sm.joints) * 2))
                rpass.set_vertex_buffer(UInt32(2), self.skin_vbufs[3 * smid + 2], UInt64(0), UInt64(len(sm.weights) * 4))
                rpass.set_index_buffer(self.skin_ibufs[smid], WGPUIndexFormat.Uint32, UInt64(0), UInt64(len(sm.indices) * 4))
                rpass.draw_indexed(UInt32(len(sm.indices)), UInt32(skin_counts[k]), UInt32(0), Int32(0), UInt32(skin_base[k]))
        rpass^.end()
        var cmd = enc^.finish("shadow_cmd")
        device.queue_submit(cmd)
