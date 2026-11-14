# M6 (design 1.9): a query built from database frame k returns k, for 20 values of k, at distance 0. Run natively by
# scripts/test_frontier_native.sh on build/assets/converted/CesiumMan.lcharacter, clip 101: the CMU walk the page plays.
from std.sys import argv
from harness.runner import Suite
from frontier_assets import parse_character
from app.motion_match import build_match, m6_frames, m6_hash, m6_hash_of
from geometry.vec import Real


def read_file(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def main() raises:
    var s = Suite("motion_match_native")
    var c = parse_character(read_file("build/assets/converted/CesiumMan.lcharacter"), 101)  # the CMU walk, as the page plays it (host.mojo)
    var m = build_match(c)
    var frames = m.track.frames
    s.check(frames >= 20, "clip has at least 20 frames: " + String(frames))
    s.check(m.db.dim == 24 and len(m.db.feats) == frames * 24, "database: 24 columns, one row per clip frame")

    var sorted_ok = True
    var ks = List[Int]()
    for i in range(20):
        ks.append(i * frames // 20)
    for k in ks:
        var probe = m.probe(k)
        var hit = m.nearest(probe)
        var dist = Float64(0)
        for d in range(24):
            var e = m.db.feats[hit * 24 + d] - probe[d]
            dist += Float64(e * e)
        var same_frame = hit == k and m.db.clip_of[hit] == 0
        if not same_frame or dist != 0.0:
            sorted_ok = False
            print("M6 miss: k", k, "hit", hit, "distance", dist)
    s.check(sorted_ok, "M6: 20 frames, each query returns its own frame at distance 0")

    var raised = False
    try:
        _ = m.nearest(List[Real]())
    except:
        raised = True
    s.check(raised, "a probe of the wrong length is refused")

    # Facing diagnostics (before the checks that depend on them): the ground projection of the hip's local z, and the
    # mean hip velocity in the facing frame (u along the facing, |v| across it).
    print("facing: min ground projection length", m.track.min_ground, "frames", frames)
    var uu = Float64(0)
    var vv = Float64(0)
    var rows = 0
    for f in range(frames):
        var raw = m.raw(f)
        uu += Float64(raw[10])
        vv += Float64(raw[11])
        rows += 1
    print("facing: mean hip velocity u", uu / Float64(rows), "v", vv / Float64(rows))
    # the toes lie ahead of the hip along the facing (raw[0] and raw[5] are the two toes' u), on average over the clip
    var toe_u = Float64(0)
    for f in range(frames):
        var raw2 = m.raw(f)
        toe_u += Float64(raw2[0]) + Float64(raw2[5])
    s.check(toe_u / Float64(2 * frames) > 0.0, "facing: the toes lie ahead of the hip on average (" + String(toe_u / Float64(2 * frames)) + " m)")
    var u_mean = uu / Float64(rows)
    var v_mean = vv / Float64(rows)
    s.check(u_mean > 0.8 and u_mean < 2.0, "walk: the hip moves forward 0.8 to 2.0 m/s in the facing frame (" + String(u_mean) + ")")
    s.check(abs(v_mean) < 0.2 * u_mean, "walk: sideways drift is small against forward speed (" + String(v_mean) + ")")
    s.check(Float64(m.track.min_ground) > 0.05, "facing: the hip's ground projection never collapses (min " + String(m.track.min_ground) + " m)")
    var got = m6_hash(m)
    var want = m6_hash_of(m6_frames(frames))
    print("M6 hash", got, "expected", want)
    s.check(got == want, "M6 hash: the 20 matched indices are the 20 query frames (the value native and wasm must print)")

    s.finish()
