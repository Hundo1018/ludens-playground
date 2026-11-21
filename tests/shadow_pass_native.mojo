# tier: unit
"""Step 5 shadow depth pass (docs/PLAN.md), native: a unit box at the origin drawn into a 64x64 depth texture from an
orthographic light that maps z to [0, 1] (z' = 0.5 z + 0.5). The box's near face is at z = -0.5, so the depth at its
centre is 0.25; an open texel stays at the clear value 1.0. A compute shader reads both texels with textureLoad and the
test checks them: the box texel is nearer than the open one, and the open one is cleared.
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
@group(0) @binding(0) var shadow : texture_depth_2d;
@group(0) @binding(1) var<storage, read_write> outv : array<f32>;

@compute @workgroup_size(1)
fn main() {
  outv[0] = textureLoad(shadow, vec2<i32>(32, 32), 0);
  outv[1] = textureLoad(shadow, vec2<i32>(2, 2), 0);
}
"""


def main() raises:
    var s = Suite("shadow_pass_native")
    var instance = Instance()
    var device = instance.request_adapter().request_device()

    # The depth texture the shadow pass writes and the read pass samples.
    var depth_tex = device.create_texture(
        UInt32(64), UInt32(64), UInt32(1), WGPUTextureFormat.Depth32Float,
        WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING,
        dimension=2, mip_level_count=1, label="shadow_map",
    )
    var depth_view = depth_tex.create_view_default()
    var depth_view_keep = depth_tex.create_view_default()

    # One unit box, registered as mesh 0.
    print('stage: device ok', flush=True)
    var registry = MeshRegistry()
    print('m1 registry made', flush=True)
    var cube = unit_cube_arrays()
    print('m2 cube made', flush=True)
    var mid = registry.add_static(cube[0].copy(), cube[1].copy(), cube[2].copy(), cube[3].copy())
    print('m3 mesh added', flush=True)
    var items = List[DrawItem]()
    # half 1.0 scales the unit cube (half-extent 0.5) to a box of half-extent 0.5, centred at the origin.
    items.append(DrawItem(0, Vec3(0.0, 0.0, 0.0, 0.0), 0.0, 0.0, 0.0, 1.0, Vec3(1.0, 1.0, 1.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), mid))

    print('m4 item added', flush=True)
    # Orthographic light: x and y untouched, z' = 0.5 z + 0.5. Column-major: column 2 holds (0, 0, 0.5, 0) and column 3
    # holds (0, 0, 0.5, 1).
    var vp: List[Float32] = [
        Float32(1.0), Float32(0.0), Float32(0.0), Float32(0.0),
        Float32(0.0), Float32(1.0), Float32(0.0), Float32(0.0),
        Float32(0.0), Float32(0.0), Float32(0.5), Float32(0.0),
        Float32(0.0), Float32(0.0), Float32(0.5), Float32(1.0),
    ]

    print('stage: registry ok', flush=True)
    var shadow = ShadowPass(device, WGPUTextureFormat.Depth32Float)
    print('stage: shadow init ok', flush=True)
    shadow.draw(device, items, registry, vp, depth_view^, List[Float32]())

    print('stage: shadow draw ok', flush=True)
    # Read pass: two texels, the box's centre and an open corner.
    var out = device.create_buffer(UInt64(8), WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_SRC, label="shadow_read_out")
    var readback = device.create_buffer(UInt64(8), WGPUBufferUsage.MAP_READ | WGPUBufferUsage.COPY_DST, label="shadow_read_map")
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
    var pl = device.create_pipeline_layout(bgl, "read_layout")
    var shader = device.create_shader_module_wgsl(READ_CS, "read_cs")
    var pipeline = device.create_compute_pipeline(shader, "main", pl, "read_pipe")
    var bg_entries: List[WGPUBindGroupEntry] = [
        WGPUBindGroupEntry(null_opaque(), UInt32(0), null_opaque(), UInt64(0), UInt64(0), null_opaque(), depth_view_keep.handle().raw),
        WGPUBindGroupEntry(null_opaque(), UInt32(1), out.handle().raw, UInt64(0), UInt64(8), null_opaque(), null_opaque()),
    ]
    var bg = device.create_bind_group(bgl, bg_entries, "read_group")
    # Mojo destroys a value after its last use: keep the view past the bind group call.
    _ = depth_view_keep.handle().raw

    var enc = device.create_command_encoder("read_enc")
    var cpass = enc.begin_compute_pass("read_pass")
    cpass.set_pipeline(pipeline)
    cpass.set_bind_group(UInt32(0), bg)
    cpass.dispatch_workgroups(UInt32(1))
    cpass^.end()
    enc.copy_buffer_to_buffer(out, UInt64(0), readback, UInt64(0), UInt64(8))
    print('stage: read recorded', flush=True)
    var cmd = enc^.finish("shadow_test_cmd")
    device.queue_submit(cmd)
    var request = readback.map_async(WGPUMapMode.READ, UInt64(0), UInt64(8))
    while not request.ready():
        _ = device.poll(True)
    var raw = request.take()
    var f = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(raw))
    var box = Float64(f[0])
    var open = Float64(f[1])
    readback.unmap()
    print("shadow depth: box centre", box, ", open corner", open)
    s.check(box > 0.2 and box < 0.3, "the box centre is at its near face, depth 0.25 (got " + String(box) + ")")
    s.almost(open, 1.0, "the open corner keeps the clear depth 1.0", tol=1e-6)
    s.finish()
