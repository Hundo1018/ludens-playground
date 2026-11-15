"""Ambient occlusion over the hub's floor (plan W10, the visible term): an AO grid of the hub's pillars, traced on the CPU
with ludens-core's BVH.raycast (the same BVH and arithmetic the GPU trace of app/rt_gpu.mojo is checked against).

Why the CPU: the GPU trace reads its result back with a blocking device poll, which the web target does not have
(wgpu-mojo: wgpuDevicePoll is native-only). The page would need an async readback to trace on the GPU. The grid is
filled once, on the first frame, so the CPU cost is paid once.

Each cell of the grid is a floor point 0.05 m up. From it, AO_RAYS rays go up over the hemisphere (cosine-weighted, a
fixed set of directions so the grid is the same on every run). A ray that hits a pillar within AO_REACH metres occludes;
the cell's value is 1 minus AO_STRENGTH times the occluded fraction. The engine multiplies the lit colour by the value
(MeshPass.set_ao).
"""
from std.math import cos, sin
from geometry.vec import Real, Vec3
from geometry.aabb import AABB
from geometry.ray import Ray
from spatial.bvh import BVH
from frontier.world import StaticBox

comptime AO_N = 40  # cells per side
comptime AO_X0 = Float32(-20.0)  # the grid's west and south edge, metres
comptime AO_SIZE = Float32(40.0)  # the grid's extent, metres
comptime AO_RAYS = 16  # rays per cell
comptime AO_REACH = 4.0  # a hit nearer than this occludes
comptime AO_STRENGTH = 0.7  # a fully occluded cell is 1 - 0.7 = 0.3


def ao_grid(boxes: List[StaticBox]) raises -> List[Float32]:
    """The AO_N by AO_N cells, row-major by z, each 1 open to 0.3 occluded."""
    var bvh_boxes = List[AABB[3]]()
    var proxies = List[Int]()
    for i in range(len(boxes)):
        var b = boxes[i]
        bvh_boxes.append(AABB[3](b.c - b.h, b.c + b.h))
        proxies.append(i)
    var bvh = BVH[3]()
    bvh.build_boxes(bvh_boxes, proxies, sah=True)

    var cell = AO_SIZE / Float32(AO_N)
    var cells = List[Float32]()
    for iz in range(AO_N):
        for ix in range(AO_N):
            var x = AO_X0 + (Float32(ix) + 0.5) * cell
            var z = AO_X0 + (Float32(iz) + 0.5) * cell
            var occluded = 0
            for k in range(AO_RAYS):
                # cosine-weighted hemisphere: elevation from the sample index, azimuth from the golden angle
                var u = (Float32(k) + 0.5) / Float32(AO_RAYS)
                var r = (1.0 - u) ** Float32(0.5)
                var phi = Float32(k) * Float32(2.399963)
                var d = Vec3(Real(Float64(r * cos(phi))), Real(Float64(u ** Float32(0.5))), Real(Float64(r * sin(phi))), Real(0))
                var o = Vec3(Real(Float64(x)), Real(0.05), Real(Float64(z)), Real(0))
                if bvh.raycast(Ray[3](o, d, Real(AO_REACH))).hit:
                    occluded += 1
            cells.append(1.0 - Float32(AO_STRENGTH) * Float32(occluded) / Float32(AO_RAYS))
    return cells^
