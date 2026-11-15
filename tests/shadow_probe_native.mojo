# tier: unit
"""Step 5 shadow probe (docs/PLAN.md), native: a depth texture written by a render pass (cleared to 0.5, no geometry) is
sampled once through a comparison sampler (LessEqual) in a compute shader, with references 0.25 and 0.75. The first must
be 1.0 (0.25 <= 0.5) and the second 0.0 (0.75 > 0.5). That is the depth-plus-comparison binding path through wgpu-mojo.
"""
from harness.runner import Suite
from wgpu import (
    Instance, WGPUBufferUsage, WGPUShaderStage, WGPUBufferBindingType, WGPUBindGroupLayoutEntry,
    WGPUBufferBindingLayout, WGPUSamplerBindingLayout, WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout,
    WGPUBindGroupEntry, WGPUMapMode, WGPUTextureFormat, WGPUTextureUsage,
)
from wgpu._ffi.nulls import null_opaque
from wgpu._backend.wgpu_native.structs import WGPUColor

comptime SHADOW_CS = """
@group(0) @binding(0) var shadow : texture_depth_2d;
@group(0) @binding(1) var cmp : sampler_comparison;
@group(0) @binding(2) var<storage, read_write> outv : array<f32>;

@compute @workgroup_size(1)
fn main() {
  let uv = vec2<f32>(0.5, 0.5);
  outv[0] = textureSampleCompareLevel(shadow, cmp, uv, 0.25);
  outv[1] = textureSampleCompareLevel(shadow, cmp, uv, 0.75);
}
"""


def main() raises:
    var s = Suite("shadow_probe_native")
    var instance = Instance()
    var device = instance.request_adapter().request_device()

    # The depth texture, and a colour target only because the clear helper takes one.
    var depth_tex = device.create_texture(
        UInt32(4), UInt32(4), UInt32(1), WGPUTextureFormat.Depth32Float,
        WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING,
        dimension=2, mip_level_count=1, label="shadow_depth",
    )
    var depth_view = depth_tex.create_view_default()
    var depth_view2 = depth_tex.create_view_default()
    var color_tex = device.create_texture(
        UInt32(4), UInt32(4), UInt32(1), WGPUTextureFormat.RGBA8Unorm,
        WGPUTextureUsage.RENDER_ATTACHMENT,
        dimension=2, mip_level_count=1, label="shadow_color",
    )
    var color_view = color_tex.create_view_default()

    # A comparison sampler (LessEqual = 4) and the output buffer.
    var sampler = device.create_sampler(
        mag_filter=1, min_filter=1, mipmap_filter=1, compare=UInt32(4), label="shadow_cmp",
    )
    var out = device.create_buffer(UInt64(8), WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_SRC, label="shadow_out")
    var readback = device.create_buffer(UInt64(8), WGPUBufferUsage.MAP_READ | WGPUBufferUsage.COPY_DST, label="shadow_read")

    # Layout: texture_depth_2d (sample type Depth = 4, 2D = 2), comparison sampler (Comparison = 4), storage output.
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
            WGPUSamplerBindingLayout(null_opaque(), UInt32(4)),
            WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
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
    var pl = device.create_pipeline_layout(bgl, "shadow_layout")
    var shader = device.create_shader_module_wgsl(SHADOW_CS, "shadow_cs")
    var pipeline = device.create_compute_pipeline(shader, "main", pl, "shadow_pipe")

    var bg_entries: List[WGPUBindGroupEntry] = [
        WGPUBindGroupEntry(null_opaque(), UInt32(0), null_opaque(), UInt64(0), UInt64(0), null_opaque(), depth_view2.handle().raw),
        WGPUBindGroupEntry(null_opaque(), UInt32(1), null_opaque(), UInt64(0), UInt64(0), sampler.handle().raw, null_opaque()),
        WGPUBindGroupEntry(null_opaque(), UInt32(2), out.handle().raw, UInt64(0), UInt64(8), null_opaque(), null_opaque()),
    ]
    var bg = device.create_bind_group(bgl, bg_entries, "shadow_group")
    # Mojo destroys a value after its last use: keep the view and the sampler alive past the bind group call.
    _ = depth_view2.handle().raw
    _ = sampler.handle().raw

    # 1. Render pass: clear the depth texture to 0.5 with no geometry.
    var enc = device.create_command_encoder("shadow_enc")
    var rp = enc.begin_render_pass_clear_depth(color_view^, depth_view^, WGPUColor(0.0, 0.0, 0.0, 1.0), Float32(0.5), "shadow_clear")
    rp^.end()
    # 2. Compute pass: sample once at two references.
    var cpass = enc.begin_compute_pass("shadow_sample")
    cpass.set_pipeline(pipeline)
    cpass.set_bind_group(UInt32(0), bg)
    cpass.dispatch_workgroups(UInt32(1))
    cpass^.end()
    enc.copy_buffer_to_buffer(out, UInt64(0), readback, UInt64(0), UInt64(8))
    var cmd = enc^.finish("shadow_cmd")
    device.queue_submit(cmd)
    var request = readback.map_async(WGPUMapMode.READ, UInt64(0), UInt64(8))
    while not request.ready():
        _ = device.poll(True)
    var raw = request.take()
    var f = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(raw))
    var lit = Float64(f[0])
    var dark = Float64(f[1])
    readback.unmap()
    print("shadow probe: reference 0.25 gives", lit, ", reference 0.75 gives", dark)
    s.almost(lit, 1.0, "reference 0.25 is lit (0.25 <= 0.5 under LessEqual)", tol=1e-6)
    s.almost(dark, 0.0, "reference 0.75 is in shadow (0.75 > 0.5 under LessEqual)", tol=1e-6)
    s.finish()
