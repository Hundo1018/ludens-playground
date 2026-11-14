# The playground's native checks, on the CPU and (with an adapter) on the GPU: B1 (rest-pose identity) and B3 (every
# vertex, GPU against CPU, below 1e-3 m) for CesiumMan's walk and the Fox's Walk, read from build/assets/converted/
# with Mojo file I/O. Run by scripts/test_frontier_native.sh. With --require-gpu a missing adapter is a failure.
from std.sys import argv
from harness.runner import Suite
from wgpu import Instance
from app.skin_gpu import GpuSkinning
from app.skin_pass import cpu_skin, palette_to_mats
from frontier_assets import Character, parse_character, pose_palette_frame, rest_palette
from geometry.mat import Mat4
from geometry.vec import Real, Vec3


def read_file(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def rest_positions(c: Character) -> List[Vec3]:
    var out = List[Vec3]()
    for v in range(len(c.positions) // 3):
        out.append(Vec3(Real(Float64(c.positions[3 * v])), Real(Float64(c.positions[3 * v + 1])), Real(Float64(c.positions[3 * v + 2])), Real(0)))
    return out^


def joint_ints(j: List[UInt16]) -> List[Int]:
    var out = List[Int]()
    for x in j:
        out.append(Int(x))
    return out^


def weights_real(w: List[Float32]) -> List[Real]:
    var out = List[Real]()
    for x in w:
        out.append(Real(Float64(x)))
    return out^


def b1(name: String, c: Character, mut s: Suite) raises:
    """The rest-pose palette through the CPU reference, against root_transform * p (the rest positions after the root)."""
    var pal = rest_palette(c)
    var rest = rest_positions(c)
    var out = List[Vec3]()
    for _ in range(len(rest)):
        out.append(Vec3(Real(0), Real(0), Real(0), Real(0)))
    cpu_skin(palette_to_mats(pal), rest, joint_ints(c.joints), weights_real(c.weights), 4, out)
    var root = palette_to_mats(c.root)[0].copy()
    var worst = 0.0
    for v in range(len(rest)):
        var want = Vec3(Real(0), Real(0), Real(0), Real(0))
        for r in range(3):
            want[r] = root.get(r, 0) * rest[v][0] + root.get(r, 1) * rest[v][1] + root.get(r, 2) * rest[v][2] + root.get(r, 3)
        for k in range(3):
            var d = Float64(out[v][k] - want[k])
            if d < 0.0:
                d = -d
            if d > worst:
                worst = d
    print("B1", name, "max error", worst)
    s.check(worst < 1e-4, "B1: " + name + " rest pose reproduces root_transform * p")


def main() raises:
    var s = Suite("frontier_native")
    var require_gpu = False
    for a in argv():
        if String(a) == "--require-gpu":
            require_gpu = True
    var cesium = parse_character(read_file("build/assets/converted/CesiumMan.lcharacter"), 100)  # its only clip: kind 100
    var fox = parse_character(read_file("build/assets/converted/Fox.lcharacter"), 101)
    b1("CesiumMan", cesium, s)
    b1("Fox", fox, s)
    try:
        var instance = Instance()
        var device = instance.request_adapter().request_device()
        print("GPU adapter present: B3 runs")
        var gpu = GpuSkinning(device)
        for f in [0, 8, 16, 24, 32]:
            var pal = pose_palette_frame(cesium, f)
            var rest = rest_positions(cesium)
            var joints = joint_ints(cesium.joints)
            var weights = weights_real(cesium.weights)
            var cpu_out = List[Vec3]()
            for _ in range(len(rest)):
                cpu_out.append(Vec3(Real(0), Real(0), Real(0), Real(0)))
            cpu_skin(palette_to_mats(pal), rest, joints, weights, 4, cpu_out)
            var job = gpu.submit(device, pal, rest, joints, weights)
            job.request.wait()
            var gpu_out = job.collect()
            var worst = 0.0
            for v in range(len(rest)):
                for k in range(3):
                    var d = Float64(cpu_out[v][k] - gpu_out[v][k])
                    if d < 0.0:
                        d = -d
                    if d > worst:
                        worst = d
            print("B3 CesiumMan frame", f, "max |GPU - CPU| (m)", worst)
            s.check(worst < 1e-3, "B3: CesiumMan walk frame " + String(f) + ", every vertex GPU against CPU below 1e-3 m")
        var fox_rest = rest_positions(fox)
        for f in [0, 11, 22]:
            var pal = pose_palette_frame(fox, f)
            var joints = joint_ints(fox.joints)
            var weights = weights_real(fox.weights)
            var cpu_out = List[Vec3]()
            for _ in range(len(fox_rest)):
                cpu_out.append(Vec3(Real(0), Real(0), Real(0), Real(0)))
            cpu_skin(palette_to_mats(pal), fox_rest, joints, weights, 4, cpu_out)
            var job = gpu.submit(device, pal, fox_rest, joints, weights)
            job.request.wait()
            var gpu_out = job.collect()
            var worst = 0.0
            for v in range(len(fox_rest)):
                for k in range(3):
                    var d = Float64(cpu_out[v][k] - gpu_out[v][k]) * 0.01
                    if d < 0.0:
                        d = -d
                    if d > worst:
                        worst = d
            print("B3 Fox frame", f, "max |GPU - CPU| (m)", worst)
            s.check(worst < 1e-3, "B3: Fox Walk frame " + String(f) + ", every vertex GPU against CPU below 1e-3 m")
    except e:
        print("no GPU adapter (" + String(e) + ")")
        if require_gpu:
            s.check(False, "B3: a GPU adapter is required (--require-gpu) and none was found")
    s.finish()
