# tier: unit
"""Step 5 mesh pass with the shadow factor (docs/PLAN.md), native: the engine's MeshPass builds its pipeline with the
shadow bindings (depth texture, comparison sampler, light uniform) and accepts a light matrix. This compiles the new
fragment shader through wgpu and checks the set_shadow argument contract. Rendering through it is checked on the page.
"""
from harness.runner import Suite
from wgpu import Instance, WGPUTextureFormat
from app.textures import TextureArray
from app.mesh_pass import MeshPass
from app.render_res import RenderResources


def main() raises:
    var s = Suite("mesh_shadow_native")
    var instance = Instance()
    var device = instance.request_adapter().request_device()
    var tex = TextureArray(device, UInt32(2))
    var res = RenderResources(device)
    var mesh = MeshPass(device, WGPUTextureFormat.RGBA8Unorm, WGPUTextureFormat.Depth32Float, tex, res)
    print("mesh pass built with the shadow bindings", flush=True)
    var identity: List[Float32] = [
        Float32(1.0), Float32(0.0), Float32(0.0), Float32(0.0),
        Float32(0.0), Float32(1.0), Float32(0.0), Float32(0.0),
        Float32(0.0), Float32(0.0), Float32(1.0), Float32(0.0),
        Float32(0.0), Float32(0.0), Float32(0.0), Float32(1.0),
    ]
    var short: List[Float32] = [Float32(1.0), Float32(0.0)]
    var rejected = False
    try:
        res.set_shadow(device, short, True)
    except:
        rejected = True
    s.check(rejected, "set_shadow rejects a matrix that is not 16 floats")
    res.set_shadow(device, identity, True)
    res.set_shadow(device, identity, False)
    s.check(True, "set_shadow accepts a 16-float light matrix, on and off")
    s.finish()
