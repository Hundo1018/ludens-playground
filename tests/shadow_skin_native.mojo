# tier: unit
"""Step 5 skinned shadows (docs/PLAN.md), native parity: one cube drawn into the sun's depth map twice, through the
static path and through the skinned path with an identity palette (all weight on joint 0). The skinned path runs the
engine's skinning arithmetic, so the two depth maps must agree at every texel. A joint or weight layout error would
show here and not in a luminance crop. Eight texels are compared, tolerance 1e-6: five inside the box's footprint (texel columns 37 to 43) and three open.
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
from wgpu import null_opaque

comptime READ_CS = """
@group(0) @binding(0) var a : texture_depth_2d;
@group(0) @binding(1) var b : texture_depth_2d;
@group(0) @binding(2) var<storage, read_write> outv : array<f32>;

@compute @workgroup_size(1)
fn main() {
  let pts = array<vec2<i32>, 8>(
    vec2<i32>(40, 40), vec2<i32>(37, 37), vec2<i32>(43, 43), vec2<i32>(38, 42),
    vec2<i32>(42, 38), vec2<i32>(24, 40), vec2<i32>(40, 24), vec2<i32>(10, 10));
  for (var i = 0; i < 8; i++) {
    outv[i] = textureLoad(a, pts[i], 0);
    outv[8 + i] = textureLoad(b, pts[i], 0);
  }
}
"""


def main() raises:
    var s = Suite("shadow_skin_native")
    var instance = Instance()
    var device = instance.request_adapter().request_device()
    var static_tex = device.create_texture(
        UInt32(64), UInt32(64), UInt32(1), WGPUTextureFormat.Depth32Float,
        WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING,
        dimension=2, mip_level_count=1, label="skin_test_static",
    )
    var skin_tex = device.create_texture(
        UInt32(64), UInt32(64), UInt32(1), WGPUTextureFormat.Depth32Float,
        WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING,
        dimension=2, mip_level_count=1, label="skin_test_skinned",
    )
    var static_view = static_tex.create_view_default()
    var skin_view = skin_tex.create_view_default()
    var static_view_keep = static_tex.create_view_default()
    var skin_view_keep = skin_tex.create_view_default()

    var registry = MeshRegistry()
    var cube = unit_cube_arrays()
    var mid = registry.add_static(cube[0].copy(), cube[1].copy(), cube[2].copy(), cube[3].copy())
    # the same cube as a skinned mesh: every vertex on joint 0 with weight 1
    var nverts = len(cube[0]) // 3
    var joints = List[UInt16]()
    var weights = List[Float32]()
    for _ in range(nverts):
        for k in range(4):
            joints.append(UInt16(0))
            weights.append(Float32(1.0) if k == 0 else Float32(0.0))
    var sid = registry.add_skinned(cube[0].copy(), cube[1].copy(), cube[2].copy(), joints^, weights^, cube[3].copy())

    # the box off the centre (as shadow_flip_native): texels (40, 40), depth 0.45
    var static_items = List[DrawItem]()
    static_items.append(DrawItem(0, Vec3(0.25, -0.25, 0.0, 0.0), 0.0, 0.0, 0.0, 1.0, Vec3(0.2, 0.2, 0.2, 0.0), Vec3(1.0, 1.0, 1.0, 0.0), mid))
    var skin_items = List[DrawItem]()
    skin_items.append(DrawItem(-1, Vec3(0.25, -0.25, 0.0, 0.0), 0.0, 0.0, 0.0, 1.0, Vec3(0.2, 0.2, 0.2, 0.0), Vec3(1.0, 1.0, 1.0, 0.0), sid, 0, 0, 1))
    var vp: List[Float32] = [
        Float32(1.0), Float32(0.0), Float32(0.0), Float32(0.0),
        Float32(0.0), Float32(1.0), Float32(0.0), Float32(0.0),
        Float32(0.0), Float32(0.0), Float32(0.5), Float32(0.0),
        Float32(0.0), Float32(0.0), Float32(0.5), Float32(1.0),
    ]
    # an identity palette: one matrix, column-major
    var palette: List[Float32] = [
        Float32(1.0), Float32(0.0), Float32(0.0), Float32(0.0),
        Float32(0.0), Float32(1.0), Float32(0.0), Float32(0.0),
        Float32(0.0), Float32(0.0), Float32(1.0), Float32(0.0),
        Float32(0.0), Float32(0.0), Float32(0.0), Float32(1.0),
    ]
    var shadow = ShadowPass(device, WGPUTextureFormat.Depth32Float)
    shadow.draw(device, static_items, registry, vp, static_view^, List[Float32]())
    var shadow2 = ShadowPass(device, WGPUTextureFormat.Depth32Float)
    shadow2.draw(device, skin_items, registry, vp, skin_view^, palette)

    var out = device.create_buffer(UInt64(16 * 4), WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_SRC, label="skin_out")
    var readback = device.create_buffer(UInt64(16 * 4), WGPUBufferUsage.MAP_READ | WGPUBufferUsage.COPY_DST, label="skin_map")
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
            WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
            WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
            WGPUTextureBindingLayout(null_opaque(), UInt32(4), UInt32(2), UInt32(0)),
            WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
        ),
        WGPUBindGroupLayoutEntry(
            null_opaque(), UInt32(2), WGPUShaderStage.COMPUTE.value, UInt32(0),
            WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Storage, UInt32(0), UInt64(0)),
            WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
            WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
        ),
    ]
    var bgl = device.create_bind_group_layout(entries)
    var pl = device.create_pipeline_layout(bgl, "skin_read_layout")
    var shader = device.create_shader_module_wgsl(READ_CS, "skin_read_cs")
    var pipeline = device.create_compute_pipeline(shader, "main", pl, "skin_read_pipe")
    var bg_entries: List[WGPUBindGroupEntry] = [
        WGPUBindGroupEntry(null_opaque(), UInt32(0), null_opaque(), UInt64(0), UInt64(0), null_opaque(), static_view_keep.handle().raw),
        WGPUBindGroupEntry(null_opaque(), UInt32(1), null_opaque(), UInt64(0), UInt64(0), null_opaque(), skin_view_keep.handle().raw),
        WGPUBindGroupEntry(null_opaque(), UInt32(2), out.handle().raw, UInt64(0), UInt64(16 * 4), null_opaque(), null_opaque()),
    ]
    var bg = device.create_bind_group(bgl, bg_entries, "skin_read_group")
    _ = static_view_keep.handle().raw
    _ = skin_view_keep.handle().raw
    var enc = device.create_command_encoder("skin_read_enc")
    var cpass = enc.begin_compute_pass("skin_read")
    cpass.set_pipeline(pipeline)
    cpass.set_bind_group(UInt32(0), bg)
    cpass.dispatch_workgroups(UInt32(1))
    cpass^.end()
    enc.copy_buffer_to_buffer(out, UInt64(0), readback, UInt64(0), UInt64(16 * 4))
    var cmd = enc^.finish("skin_read_cmd")
    device.queue_submit(cmd)
    var request = readback.map_async(WGPUMapMode.READ, UInt64(0), UInt64(16 * 4))
    while not request.ready():
        _ = device.poll(True)
    var raw = request.take()
    var f = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(raw))
    var worst = 0.0
    var box_texels = 0
    for i in range(8):
        var a = Float64(f[i])
        var b = Float64(f[8 + i])
        var d = abs(a - b)
        if d > worst:
            worst = d
        if a < 1.0:
            box_texels += 1
        print("texel", i, "static", a, "skinned", b)
    readback.unmap()
    s.check(box_texels >= 3, "the static map shows the box at its texels (" + String(box_texels) + " of 8 below 1.0)")
    s.check(worst < 1e-6, "skinned and static depth maps agree at 8 texels (worst difference " + String(worst) + ")")
    s.finish()
