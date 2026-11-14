"""The playground's binary assets, read in wasm (step 5 PR D): .lcharacter v2 (LCHR) and .ltexture (LTEX v1).

Both are written by scripts/convert_glb.py and scripts/convert_texture.py. The page copies each file into wasm memory,
and playground_host_asset hands the bytes here; this module copies what it needs, so the page may free its buffer when
the call returns. Counts come from blob sizes, so no JSON is parsed here; the one thing read from the JSON header is
fps.

Blob kinds (convert_glb.py): 1 positions f32x3, 2 normals f32x3, 3 uv f32x2, 4 joints u16x4, 5 weights f32x4,
6 indices u32, 7 inverse bind f32x16 (column-major), 8 rest f32x10 (T3 R4 S3, quaternion x y z w), 9 parents i32,
10 root transform f32x16 (column-major), 100 + k clip k (f32x10 per joint per frame)."""
from geometry.mat import Mat4
from geometry.quat import Quat
from geometry.vec import Real
from app.skin_pass import build_palette_root, palette_to_mats


@fieldwise_init
struct Character(Copyable, Movable):
    """One character, as the host needs it: the skinned mesh, the skin, the rest pose and one clip."""

    var positions: List[Float32]
    var normals: List[Float32]
    var uv: List[Float32]
    var joints: List[UInt16]
    var weights: List[Float32]
    var indices: List[UInt32]
    var ibm: List[Float32]  # 16 per joint, column-major
    var rest: List[Float32]  # 10 per joint: translation, quaternion x y z w, scale
    var parents: List[Int]
    var root: List[Float32]  # 16, column-major
    var clip: List[Float32]  # 10 per joint per frame
    var frames: Int
    var joint_count: Int
    var fps: Int


def _u32(b: List[UInt8], off: Int) raises -> UInt32:
    if off + 4 > len(b):
        raise Error("asset: read past the end")
    return UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)


def _floats(b: List[UInt8], off: Int, n: Int) raises -> List[Float32]:
    """n little-endian f32 from byte offset off (the blobs are 16-byte aligned, so the reads are aligned)."""
    if off + 4 * n > len(b):
        raise Error("asset: a float blob runs past the end")
    var p = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(b.unsafe_ptr()) + off)
    var out = List[Float32]()
    for i in range(n):
        out.append(p[i])
    return out^


def _blob(b: List[UInt8], kind: Int) raises -> Tuple[Int, Int]:
    """(offset, bytes) of the blob with this kind, from the directory after the 12-byte header."""
    if len(b) < 12 or b[0] != UInt8(76) or b[1] != UInt8(67) or b[2] != UInt8(72) or b[3] != UInt8(82):
        raise Error("lcharacter: bad magic (want LCHR)")
    var count = Int(_u32(b, 8))
    for i in range(count):
        var at = 12 + 12 * i
        if Int(_u32(b, at)) == kind:
            return (Int(_u32(b, at + 4)), Int(_u32(b, at + 8)))
    raise Error("lcharacter: no blob of kind " + String(kind))


def _fps(b: List[UInt8]) raises -> Int:
    """The "fps" number of the JSON header, found by its key (the header is written with no spaces)."""
    var count = Int(_u32(b, 8))
    var hpos = 12 + 12 * count
    var hlen = Int(_u32(b, hpos))
    var kb = "\"fps\":".as_bytes()
    var klen = len(kb)
    var start = hpos + 4
    for at in range(start, start + hlen - klen):
        var hit = True
        for k in range(klen):
            if b[at + k] != kb[k]:
                hit = False
                break
        if hit:
            var v = 0
            var i = at + klen
            while i < start + hlen and b[i] >= UInt8(48) and b[i] <= UInt8(57):
                v = v * 10 + Int(b[i]) - 48
                i += 1
            return v
    raise Error("lcharacter: no fps in the header")


def parse_character(b: List[UInt8], clip_kind: Int) raises -> Character:
    var pos = _blob(b, 1)
    var nv = pos[1] // 12
    var positions = _floats(b, pos[0], 3 * nv)
    var nrm = _blob(b, 2)
    var normals = _floats(b, nrm[0], 3 * nv)
    var uvb = _blob(b, 3)
    var uv = _floats(b, uvb[0], 2 * nv)
    var jb = _blob(b, 4)
    var joints = List[UInt16]()
    var jp = Pointer[UInt16, MutUntrackedOrigin](unsafe_from_address=Int(b.unsafe_ptr()) + jb[0])
    for i in range(4 * nv):
        joints.append(jp[i])
    var wb = _blob(b, 5)
    var weights = _floats(b, wb[0], 4 * nv)
    var ib = _blob(b, 6)
    var indices = List[UInt32]()
    var ip = Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=Int(b.unsafe_ptr()) + ib[0])
    for i in range(ib[1] // 4):
        indices.append(ip[i])
    var ibmb = _blob(b, 7)
    var joint_count = ibmb[1] // 64
    var ibm = _floats(b, ibmb[0], 16 * joint_count)
    var restb = _blob(b, 8)
    var rest = _floats(b, restb[0], 10 * joint_count)
    var parb = _blob(b, 9)
    var parents = List[Int]()
    var pp = Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=Int(b.unsafe_ptr()) + parb[0])
    for i in range(joint_count):
        parents.append(Int(pp[i]))
    var rootb = _blob(b, 10)
    var root = _floats(b, rootb[0], 16)
    var clipb = _blob(b, clip_kind)
    var clip = _floats(b, clipb[0], clipb[1] // 4)
    var frames = len(clip) // (10 * joint_count)
    return Character(
        positions^, normals^, uv^, joints^, weights^, indices^, ibm^, rest^, parents^, root^, clip^,
        frames, joint_count, _fps(b),
    )


def parse_ltexture(b: List[UInt8]) raises -> List[List[UInt8]]:
    """The mip levels of an LTEX v1 file, each rgba8, level 0 first."""
    if len(b) < 20 or b[0] != UInt8(76) or b[1] != UInt8(84) or b[2] != UInt8(69) or b[3] != UInt8(88):
        raise Error("ltexture: bad magic (want LTEX)")
    var w = Int(_u32(b, 8))
    var h = Int(_u32(b, 12))
    var n = Int(_u32(b, 16))
    var levels = List[List[UInt8]]()
    var pos = 20
    for level in range(n):
        pos = (pos + 15) & ~15
        var lw = max(w >> level, 1)
        var lh = max(h >> level, 1)
        var nbytes = lw * lh * 4
        if pos + nbytes > len(b):
            raise Error("ltexture: a level runs past the end")
        var lvl = List[UInt8](length=nbytes, fill=0)
        for i in range(nbytes):
            lvl[i] = b[pos + i]
        levels.append(lvl^)
        pos += nbytes
    return levels^


def trs(v: List[Float32], off: Int) -> Mat4:
    """Translation, quaternion x y z w, scale at v[off .. off+9] (the converter's rest and clip layout), as T * R * S."""
    var q = Quat(Real(Float64(v[off + 3])), Real(Float64(v[off + 4])), Real(Float64(v[off + 5])), Real(Float64(v[off + 6])))
    var m = q.to_mat4()
    for col in range(3):
        for row in range(3):
            m.set(row, col, m.get(row, col) * Real(Float64(v[off + 7 + col])))
    for row in range(3):
        m.set(row, 3, Real(Float64(v[off + row])))
    return m^


def locals_at(v: List[Float32], frame: Int, joints: Int) -> List[Mat4]:
    """One local per joint from the frame's 10 floats per joint (frame 0 of the rest list is the rest pose)."""
    var out = List[Mat4]()
    for j in range(joints):
        out.append(trs(v, (frame * joints + j) * 10))
    return out^


def pose_palette_frame(c: Character, frame: Int) raises -> List[Float32]:
    """The palette of one character at a clip frame: each joint's local from its TRS, then the inverse bind and the
    root transform (the ancestors the bind matrices exclude)."""
    var locals = locals_at(c.clip, frame, c.joint_count)
    var ibm = palette_to_mats(c.ibm)
    var root = palette_to_mats(c.root)[0].copy()
    return build_palette_root(locals, c.parents, ibm, root)


def pose_palette(c: Character, clock: Float64) raises -> List[Float32]:
    """The palette at a clock: the clip sampled at frame floor(clock * fps), looping."""
    return pose_palette_frame(c, Int(clock * Float64(c.fps)) % c.frames)


def rest_palette(c: Character) raises -> List[Float32]:
    """The palette at the rest pose (the rest TRS, no clip): B1 applies it to the rest positions."""
    var locals = locals_at(c.rest, 0, c.joint_count)
    var ibm = palette_to_mats(c.ibm)
    var root = palette_to_mats(c.root)[0].copy()
    return build_palette_root(locals, c.parents, ibm, root)
