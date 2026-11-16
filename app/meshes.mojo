"""V2: a unit sphere for the mesh pass (diameter 1, like the unit cube's side), so a textured sphere is drawn as a mesh
item scaled by its half extents times 2. Positions, normals, uv and indices in add_static's layout."""
from std.math import sin, cos


def unit_sphere_arrays(segments: Int = 24, rings: Int = 16) -> Tuple[List[Float32], List[Float32], List[Float32], List[UInt32]]:
    var pos = List[Float32]()
    var nrm = List[Float32]()
    var uv = List[Float32]()
    var idx = List[UInt32]()
    comptime PI = 3.141592653589793
    for r in range(rings + 1):
        var v = Float64(r) / Float64(rings)
        var phi = v * PI
        for s in range(segments + 1):
            var u = Float64(s) / Float64(segments)
            var th = u * 2.0 * PI
            var x = sin(phi) * cos(th)
            var y = cos(phi)
            var z = sin(phi) * sin(th)
            pos.append(Float32(0.5 * x))
            pos.append(Float32(0.5 * y))
            pos.append(Float32(0.5 * z))
            nrm.append(Float32(x))
            nrm.append(Float32(y))
            nrm.append(Float32(z))
            uv.append(Float32(u))
            uv.append(Float32(v))
    var row = segments + 1
    for r in range(rings):
        for s in range(segments):
            var a = UInt32(r * row + s)
            var b = UInt32((r + 1) * row + s)
            idx.append(a)
            idx.append(a + 1)
            idx.append(b)
            idx.append(b)
            idx.append(a + 1)
            idx.append(b + 1)
    return (pos^, nrm^, uv^, idx^)
