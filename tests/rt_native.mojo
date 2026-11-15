# tier: integration  (override: needs the GPU device, like the other *_native tests)
# W10 (plan, first part): the GPU ray trace over the hub's BVH agrees with ludens-core's CPU BVH.raycast. 256 rays: 256 downward
# rays on a grid over the hub, and 128 horizontal ones at street height from the west, so some hit pillars and some miss.
# Checks: every hit flag agrees, and every hit distance agrees within 1e-3 m; the scene has hits and misses.
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.aabb import AABB
from geometry.ray import Ray
from spatial.bvh import BVH
from frontier.world import Frontier
from app.rt_gpu import RtTracer, flatten_bvh
from wgpu import Instance


def main() raises:
    var s = Suite("rt_native")
    var f = Frontier()
    var pillars = f.static_boxes(-20.0, -20.0, 20.0, 20.0, 1.0)
    var boxes = List[AABB[3]]()
    var proxies = List[Int]()
    boxes.append(AABB[3](Vec3(-20.0, -1.0, -20.0, 0.0), Vec3(20.0, 0.0, 20.0, 0.0)))
    proxies.append(0)
    for i in range(len(pillars)):
        var b = pillars[i]
        boxes.append(AABB[3](b.c - b.h, b.c + b.h))
        proxies.append(i + 1)
    var bvh = BVH[3]()
    bvh.build_boxes(boxes, proxies, sah=True)
    var nodes = flatten_bvh(bvh)

    # the rays, in both forms: CPU (origin, dir, max_t) and GPU (8 floats: origin, max_t, dir, 0)
    var rays_cpu = List[Ray[3]]()
    var rays_gpu = List[Float32]()
    for i in range(16):
        for j in range(16):
            var x = Real(-15.0 + 2.0 * Real(i))
            var z = Real(-15.0 + 2.0 * Real(j))
            var o = Vec3(x, 10.0, z, 0.0)
            var d = Vec3(0.0001, -1.0, 0.0001, 0.0)
            rays_cpu.append(Ray[3](o, d, Real(100.0)))
            _push(rays_gpu, o, Real(100.0), d)
    for i in range(16):
        for j in range(8):
            var y = Real(0.2 + 0.5 * Real(j))
            var z = Real(-15.0 + 2.0 * Real(i))
            var o = Vec3(-25.0, y, z, 0.0)
            var d = Vec3(1.0, 0.0001, 0.0001, 0.0)
            rays_cpu.append(Ray[3](o, d, Real(100.0)))
            _push(rays_gpu, o, Real(100.0), d)

    var device = Instance().request_adapter().request_device()
    var tracer = RtTracer(device)
    var gpu = tracer.trace(device, nodes, rays_gpu)

    var hits_cpu = 0
    var hits_gpu = 0
    var flags_agree = 0
    var worst = Real(0)
    for r in range(len(rays_cpu)):
        var cpu = bvh.raycast(rays_cpu[r])
        var g_hit = gpu[4 * r] > 0.5
        var g_t = Real(Float64(gpu[4 * r + 1]))
        if cpu.hit:
            hits_cpu += 1
        if g_hit:
            hits_gpu += 1
        if cpu.hit == g_hit:
            flags_agree += 1
        if cpu.hit and g_hit:
            var dt = cpu.t - g_t
            if dt < 0:
                dt = -dt
            if dt > worst:
                worst = dt
    s.check(flags_agree == len(rays_cpu), "every hit flag agrees with the CPU raycast: " + String(flags_agree) + " of " + String(len(rays_cpu)))
    s.check(worst < Real(1e-3), "every hit distance agrees within 1e-3 m: worst " + String(worst) + " m")
    s.check(hits_cpu > 0 and hits_cpu < len(rays_cpu), "the scene has hits and misses: " + String(hits_cpu) + " hit on the CPU, " + String(hits_gpu) + " on the GPU")
    s.finish()


def _push(mut out: List[Float32], o: Vec3, max_t: Real, d: Vec3):
    out.append(Float32(Float64(o[0])))
    out.append(Float32(Float64(o[1])))
    out.append(Float32(Float64(o[2])))
    out.append(Float32(Float64(max_t)))
    out.append(Float32(Float64(d[0])))
    out.append(Float32(Float64(d[1])))
    out.append(Float32(Float64(d[2])))
    out.append(0.0)
