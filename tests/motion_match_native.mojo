# M6 (design 1.9), over the CMU subject-07 trials the page plays: a query built from database row k returns k, at
# distance 0, for 20 rows spread over every clip. Also the facing and speed checks per trial. Run natively by
# scripts/test_frontier_native.sh on build/assets/converted/CesiumMan.lcharacter (kinds 101 walk, 102 slow walk, 103 brisk).
from harness.runner import Suite
from frontier_assets import parse_character
from app.motion_match import build_match, m6_rows, m6_hash, m6_hash_of
from geometry.vec import Real


def read_file(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def main() raises:
    var s = Suite("motion_match_native")
    var c = parse_character(read_file("build/assets/converted/CesiumMan.lcharacter"), 101)
    s.check(len(c.motion) == 3, "three CMU trials in the character: " + String(len(c.motion)))
    var m = build_match(c, c.motion)
    var total = m.rows()
    var frame_counts = List[Int]()
    for clip in c.motion:
        frame_counts.append(len(clip) // (10 * c.joint_count))
    s.check(total == frame_counts[0] + frame_counts[1] + frame_counts[2], "one row per frame of every clip: " + String(total) + " rows")
    s.check(m.db.dim == 24 and len(m.db.feats) == total * 24, "database: 24 columns")

    # M6: query rows spread over the clips; each must return itself at distance 0.
    var all_ok = True
    var rows = m6_rows(total)
    for row in rows:
        var probe = m.probe_row(row)
        var hit = m.nearest(probe)
        var dist = Float64(0)
        for d in range(24):
            var e = m.db.feats[hit * 24 + d] - probe[d]
            dist += Float64(e * e)
        if hit != row or dist != 0.0:
            all_ok = False
            print("M6 miss: row", row, "hit", hit, "distance", dist)
    s.check(all_ok, "M6: 20 rows over all clips, each query returns its own row at distance 0")

    # The trials are ordered by speed: slow walk below the walk, brisk walk above it.
    var first = 0
    var u_mean = List[Float64]()
    var v_abs = List[Float64]()
    var row0 = 0
    for i in range(3):
        var uu = Float64(0)
        var vv = Float64(0)
        for f in range(frame_counts[i]):
            var raw = m.raw_row(row0 + f)
            uu += Float64(raw[10])
            vv += Float64(raw[11])
        u_mean.append(uu / Float64(frame_counts[i]))
        v_abs.append(abs(vv / Float64(frame_counts[i])))
        print("trial", i, "frames", frame_counts[i], "mean hip u", u_mean[i], "v", v_abs[i], "min ground", m.tracks[i].min_ground)
        row0 += frame_counts[i]
    s.check(u_mean[0] > 0.8 and u_mean[0] < 2.0, "walk: forward speed 0.8 to 2.0 m/s (" + String(u_mean[0]) + ")")
    s.check(u_mean[1] < u_mean[0], "slow walk is slower than the walk (" + String(u_mean[1]) + " < " + String(u_mean[0]) + ")")
    s.check(u_mean[2] > u_mean[0], "brisk walk is faster than the walk (" + String(u_mean[2]) + " > " + String(u_mean[0]) + ")")
    for i in range(3):
        s.check(v_abs[i] < 0.2 * u_mean[i], "trial " + String(i) + ": sideways drift is small against forward speed")
        s.check(Float64(m.tracks[i].min_ground) > 0.05, "trial " + String(i) + ": the facing's ground projection never collapses")

    var raised = False
    try:
        _ = m.nearest(List[Real]())
    except:
        raised = True
    s.check(raised, "a probe of the wrong length is refused")

    var got = m6_hash(m)
    var hits = List[Int]()
    for r in rows:
        hits.append(r)
    var want = m6_hash_of(hits)
    print("M6 hash", got, "expected", want)
    s.check(got == want, "M6 hash: the matched rows are the query rows (the value native and wasm must print)")
    s.finish()
