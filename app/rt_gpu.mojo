"""Ray tracing on the GPU (plan W10, first part): the hub's BVH flattened into storage, and a compute shader that traces
one ray per invocation, nearest hit, against it.

The arithmetic matches ludens-core's CPU path (geometry/ray.mojo ray_aabb and spatial/bvh.mojo raycast): slab test from
t = 0 to the current best, a leaf is taken when its entry t is no greater than the best, and the nearest leaf wins.
The check that the two agree is tests/rt_native.mojo: hit flags equal, t within 1e-3 for every ray.

Node layout (three vec4 per node): (min.xyz, left), (max.xyz, right), (proxy, 0, 0, 0). A leaf has left < 0. The root is
node 0. Rays: two vec4 per ray: (origin.xyz, max_t), (dir.xyz, 0). Results: one vec4 per ray: (hit, t, proxy, 0).
"""
from wgpu import (
    WGPUBufferUsage, WGPUShaderStage, WGPUBufferBindingType, WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout,
    WGPUSamplerBindingLayout, WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout, WGPUBindGroupEntry,
    WGPUMapMode,
)
from wgpu._ffi.nulls import null_opaque
from wgpu.bind_group import BindGroupLayout, BindGroup
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.pipeline import ComputePipeline
from spatial.bvh import BVH

comptime RT_CS = """
@group(0) @binding(0) var<storage, read> nodes : array<vec4<f32>>;
@group(0) @binding(1) var<storage, read> rays : array<vec4<f32>>;
@group(0) @binding(2) var<storage, read_write> hits : array<vec4<f32>>;

// Entry t of the ray into the box, or -1 for a miss. Starts at 0 and ends at tmax, as ray_aabb does.
fn slab(o: vec3<f32>, d: vec3<f32>, bmin: vec3<f32>, bmax: vec3<f32>, tmax: f32) -> f32 {
  var t0 = 0.0;
  var t1 = tmax;
  for (var a = 0; a < 3; a = a + 1) {
    var da = d[a];
    if abs(da) < 1e-9 {
      if o[a] < bmin[a] || o[a] > bmax[a] {
        return -1.0;
      }
    } else {
      let inv = 1.0 / da;
      var ta = (bmin[a] - o[a]) * inv;
      var tb = (bmax[a] - o[a]) * inv;
      if ta > tb {
        let tmp = ta;
        ta = tb;
        tb = tmp;
      }
      t0 = max(t0, ta);
      t1 = min(t1, tb);
    }
  }
  if t0 <= t1 {
    return t0;
  }
  return -1.0;
}

@compute @workgroup_size(64)
fn rt_cs(@builtin(global_invocation_id) gid : vec3<u32>) {
  let r = gid.x;
  if r >= arrayLength(&hits) {
    return;
  }
  let o = rays[2u * r].xyz;
  let tmax = rays[2u * r].w;
  let d = rays[2u * r + 1u].xyz;
  var best = tmax;
  var best_proxy = -1.0;
  var found = 0.0;
  var stack : array<i32, 64>;
  var sp = 1;
  stack[0] = 0;
  loop {
    if sp == 0 {
      break;
    }
    sp = sp - 1;
    let n = u32(stack[sp]);
    let a = nodes[3u * n];
    let b = nodes[3u * n + 1u];
    let t = slab(o, d, a.xyz, b.xyz, best);
    if t < 0.0 {
      continue;
    }
    let left = i32(a.w);
    if left < 0 {
      if t <= best {
        best = t;
        best_proxy = nodes[3u * n + 2u].x;
        found = 1.0;
      }
      continue;
    }
    stack[sp] = left;
    sp = sp + 1;
    stack[sp] = i32(b.w);
    sp = sp + 1;
  }
  hits[r] = vec4<f32>(found, best, best_proxy, 0.0);
}
"""


def _storage(binding: UInt32, readonly: Bool) -> WGPUBindGroupLayoutEntry:
    var kind = WGPUBufferBindingType.ReadOnlyStorage if readonly else WGPUBufferBindingType.Storage
    return WGPUBindGroupLayoutEntry(
        null_opaque(), binding, WGPUShaderStage.COMPUTE.value, UInt32(0),
        WGPUBufferBindingLayout(null_opaque(), kind, UInt32(0), UInt64(0)),
        WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
        WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
        WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
    )


def _entry(binding: UInt32, buffer: Buffer, bytes: UInt64) -> WGPUBindGroupEntry:
    return WGPUBindGroupEntry(null_opaque(), binding, buffer.handle().raw, UInt64(0), bytes, null_opaque(), null_opaque())


def flatten_bvh(bvh: BVH[3]) raises -> List[Float32]:
    """The BVH's nodes in breadth-first order from the root, so the root is node 0, three vec4 per node (see the module
    comment). The children are renumbered to the new order. An empty BVH flattens to nothing."""
    var out = List[Float32]()
    if bvh.root < 0:
        return out^
    var order = List[Int]()
    var new_index = List[Int]()
    for _ in range(len(bvh.nodes)):
        new_index.append(-1)
    order.append(bvh.root)
    new_index[bvh.root] = 0
    var head = 0
    while head < len(order):
        var n = bvh.nodes[order[head]]
        head += 1
        if not n.is_leaf():
            for c in [n.left, n.right]:
                if new_index[c] < 0:
                    new_index[c] = len(order)
                    order.append(c)
    for i in order:
        var n = bvh.nodes[i]
        out.append(Float32(Float64(n.box.min[0])))
        out.append(Float32(Float64(n.box.min[1])))
        out.append(Float32(Float64(n.box.min[2])))
        out.append(Float32(new_index[n.left]) if not n.is_leaf() else Float32(-1))
        out.append(Float32(Float64(n.box.max[0])))
        out.append(Float32(Float64(n.box.max[1])))
        out.append(Float32(Float64(n.box.max[2])))
        out.append(Float32(new_index[n.right]) if not n.is_leaf() else Float32(-1))
        out.append(Float32(n.proxy) if n.is_leaf() else Float32(0))
        out.append(0.0)
        out.append(0.0)
        out.append(0.0)
    return out^


struct RtTracer(Movable):
    """The compute pipeline, built once per device; buffers are made per trace (the scene changes rarely, the rays
    every call)."""

    var layout: BindGroupLayout
    var pipeline: ComputePipeline

    def __init__(out self, device: Device) raises:
        var shader = device.create_shader_module_wgsl(RT_CS, "rt")
        var entries: List[WGPUBindGroupLayoutEntry] = [
            _storage(UInt32(0), True),
            _storage(UInt32(1), True),
            _storage(UInt32(2), False),
        ]
        self.layout = device.create_bind_group_layout(entries)
        var pl = device.create_pipeline_layout(self.layout, "rt_layout")
        self.pipeline = device.create_compute_pipeline(shader, "rt_cs", pl, "rt_cs")

    def trace(self, device: Device, nodes: List[Float32], rays: List[Float32]) raises -> List[Float32]:
        """Trace every ray (rays: 8 floats each, see the module comment); returns 4 floats per ray: (hit, t, proxy, 0).
        Blocks until the GPU has finished."""
        var n_rays = len(rays) // 8
        if n_rays == 0:
            raise Error("gpu trace: no rays")
        if len(nodes) == 0 or len(nodes) % 12 != 0:
            raise Error("gpu trace: a BVH is 12 floats per node")
        var node_bytes = UInt64(len(nodes) * 4)
        var ray_bytes = UInt64(len(rays) * 4)
        var hit_bytes = UInt64(n_rays * 16)
        var nbuf = device.create_buffer(node_bytes, WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="rt_nodes")
        var rbuf = device.create_buffer(ray_bytes, WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_DST, label="rt_rays")
        var hbuf = device.create_buffer(hit_bytes, WGPUBufferUsage.STORAGE | WGPUBufferUsage.COPY_SRC, label="rt_hits")
        var readback = device.create_buffer(hit_bytes, WGPUBufferUsage.MAP_READ | WGPUBufferUsage.COPY_DST, label="rt_read")
        device.queue_write_data(nbuf, UInt64(0), nodes)
        device.queue_write_data(rbuf, UInt64(0), rays)
        var bg_entries: List[WGPUBindGroupEntry] = [
            _entry(UInt32(0), nbuf, node_bytes),
            _entry(UInt32(1), rbuf, ray_bytes),
            _entry(UInt32(2), hbuf, hit_bytes),
        ]
        var bg = device.create_bind_group(self.layout, bg_entries, "rt_group")
        # Mojo destroys a value after its last use: the buffers stay alive until the submit has taken them.
        _ = nbuf.handle().raw
        _ = rbuf.handle().raw
        _ = hbuf.handle().raw
        _ = readback.handle().raw
        var enc = device.create_command_encoder("rt_enc")
        var cpass = enc.begin_compute_pass("rt_pass")
        cpass.set_pipeline(self.pipeline)
        cpass.set_bind_group(UInt32(0), bg)
        cpass.dispatch_workgroups(UInt32((n_rays + 63) // 64))
        cpass^.end()
        enc.copy_buffer_to_buffer(hbuf, UInt64(0), readback, UInt64(0), hit_bytes)
        var cmd = enc^.finish("rt_cmd")
        device.queue_submit(cmd)
        var request = readback.map_async(WGPUMapMode.READ, UInt64(0), hit_bytes)
        while not request.ready():
            _ = device.poll(True)
        var raw = request.take()
        var f = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(raw))
        var out = List[Float32]()
        for i in range(n_rays * 4):
            out.append(f[i])
        readback.unmap()
        _ = bg^
        return out^
