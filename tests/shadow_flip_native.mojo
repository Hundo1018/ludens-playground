# tier: unit
"""Step 5 shadow map orientation (docs/PLAN.md, step 5), native: one box, off the centre, drawn into the sun's depth map
by the shadow pass. The light is orthographic with x and y untouched and z' = 0.5 z + 0.5, so the box at (0.25, -0.25, 0)
with half-extent 0.1 covers NDC x in [0.15, 0.35] and y in [-0.35, -0.15]. Its nearest face (z = -0.1) gives depth 0.45.
In the 64 by 64 map the NDC point (x, y) lands at texel column (x + 1) * 32 and row (1 - y) * 32, so the box is at texel
(40, 40). A map flipped in x or in y would put it at (24, 40) or (40, 24). The test reads all four texels and checks the
box is at (40, 40) and the mirrored texels are open (1.0).
"""
from harness.runner import Suite
from geometry.vec import Real, Vec3
from game.draw_item import DrawItem
from app.mesh_pass import MeshRegistry, unit_cube_arrays
from app.shadow_pass import ShadowPass
from wgpu import (
    Instance, WGPUBufferUsage, WGPUShaderStage, WGPUBufferBindingType, WGPUBindGroupLayoutEntry,
    WGPUBufferBindingLayout, WGPUSamplerBindingLayout, WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout,
    WGPUBindGroupEntry, WGPUMapMode, WGPUTextureFormat, WGPUTextureUsage,
)
from wgpu._ffi.nulls import null_opaque

comptime READ_CS = """
@group(0) @binding(0) var shadow : texture_depth_2d;
@group(0) @binding(1) var<storage, read_write> outv : array<f32>;

@compute @workgroup_size(1)
fn main() {
  outv[0] = textureLoad(shadow, vec2<i32>(40, 40), 0);
  outv[1] = textureLoad(shadow, vec2<i32>(24, 40), 0);
  outv[2] = textureLoad(shadow, vec2<i32>(40, 24), 0);
  outv[3] = textureLoad(shadow, vec2<i32>(24, 24), 0);
}
"""


def main() raises:
    var s = Suite("shadow_flip_native")
    var instance = Instance()
    var device = instance.request_adapter().request_device()
    var depth_tex = device.create_texture(
        UInt32(64), UInt32(64), UInt32(1), WGPUTextureFormat.Depth32Float,
        WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING,
        dimension=2, mip_level_count=1, label="shadow_flip_map",
    )
    var depth_view = depth_tex.create_view_default()
    var depth_view_keep = depth_tex.create_view_default()
    var registry = MeshRegistry()
    var cube = unit_cube_arrays()
    var mid = registry.add_static(cube[0].copy(), cube[1].copy(), cube[2].copy(), cube[3].copy())
    var items = List[DrawItem]()
    # half 0.2 scales the unit cube (half-extent 0.5) to a box of half-extent 0.1
    items.append(DrawItem(0, Vec3(0.25, -0.25, 0.0, 0.0), 0.0, 0.0, 0.0, 1.0, Vec3(0.2, 0.2, 0.2, 0.0), Vec3(1.0, 1.0, 1.0, 0.0), mid))
    var vp: List[Float32] = [
        Float32(1.0), Float32(0.0), Float32(0.0), Float32(0.0),
        Float32(0.0), Float32(1.0), Float32(0.0), Float32(0.0),
        Float32(0.0), Float32(0.0), Float32(0.5), Float32(0.0),
        Float32(0.0), Float32(0.0), Float32(0.5), Float32(1.0),
    ]
    var shadow = ShadowPass(device, WGPUTextureFormat.Depth32Float)
    shadow.draw(device, items, registry, vp, depth_view^, List[Float32]())
    var out = device.create_buffer(UInt64(16), WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_SRC, label="flip_out")
    var readback = device.create_buffer(UInt64(16), WGPUBufferUsage.MAP_READ | WGPUBufferUsage.COPY_DST, label="flip_map")
    var entries: List[WGPUBindGroupLayoutEntry] = [
        WGPUBindGroupLayoutEntry(
            null_opaque(), UInt32(0), WGPUShaderStage.COMPUTE.value, UInt32(0),
            WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
            WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
            WGPUTextureBindingLayout(null_opaque(), UInt32(4), UInt32(2), UInt32(0)),
            WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
        ),
        WGPUBindGroupLayoutEntry(
            null_opaque(), UInt32(1), WGPUShaderStage.COMPUTE.value, UInt32(0),
            WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Storage, UInt32(0), UInt64(0)),
            WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
            WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
        ),
    ]
    var bgl = device.create_bind_group_layout(entries)
    var pl = device.create_pipeline_layout(bgl, "flip_layout")
    var shader = device.create_shader_module_wgsl(READ_CS, "flip_cs")
    var pipeline = device.create_compute_pipeline(shader, "main", pl, "flip_pipe")
    var bg_entries: List[WGPUBindGroupEntry] = [
        WGPUBindGroupEntry(null_opaque(), UInt32(0), null_opaque(), UInt64(0), UInt64(0), null_opaque(), depth_view_keep.handle().raw),
        WGPUBindGroupEntry(null_opaque(), UInt32(1), out.handle().raw, UInt64(0), UInt64(16), null_opaque(), null_opaque()),
    ]
    var bg = device.create_bind_group(bgl, bg_entries, "flip_group")
    _ = depth_view_keep.handle().raw
    var enc = device.create_command_encoder("flip_enc")
    var cpass = enc.begin_compute_pass("flip_read")
    cpass.set_pipeline(pipeline)
    cpass.set_bind_group(UInt32(0), bg)
    cpass.dispatch_workgroups(UInt32(1))
    cpass^.end()
    enc.copy_buffer_to_buffer(out, UInt64(0), readback, UInt64(0), UInt64(16))
    var cmd = enc^.finish("flip_cmd")
    device.queue_submit(cmd)
    var request = readback.map_async(WGPUMapMode.READ, UInt64(0), UInt64(16))
    while not request.ready():
        _ = device.poll(True)
    var raw = request.take()
    var f = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(raw))
    var at = Float64(f[0])
    var flip_x = Float64(f[1])
    var flip_y = Float64(f[2])
    var corner = Float64(f[3])
    readback.unmap()
    print("shadow flip: (40,40)", at, " (24,40)", flip_x, " (40,24)", flip_y, " (24,24)", corner)
    s.almost(at, 0.45, "the box's near face is at (40, 40), depth 0.45", tol=1e-3)
    s.almost(flip_x, 1.0, "the x-mirrored texel (24, 40) is open", tol=1e-6)
    s.almost(flip_y, 1.0, "the y-mirrored texel (40, 24) is open", tol=1e-6)
    s.almost(corner, 1.0, "the opposite corner (24, 24) is open", tol=1e-6)
    s.finish()
