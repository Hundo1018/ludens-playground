# M6 (design 1.9), over the CMU trials the page plays: a query built from database row k returns k, at distance 0, for
# 20 rows spread over every clip. Also the facing, speed and turn checks per trial. Run natively by
# scripts/test_frontier_native.sh on build/assets/converted/CesiumMan.lcharacter. Clips: 101 walk 07_01, 102 slow walk
# 07_04, 103 brisk walk 07_12 (subject 07); 104 walk 38_01, 105 walk 38_02, 106 walk with turns 38_04 (subject 38).
from std.math import atan2
from harness.runner import Suite
from frontier_assets import parse_character
from app.motion_match import build_match, m6_rows, m6_hash, m6_hash_of
from geometry.vec import Real

comptime PI = 3.141592653589793


def read_file(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def main() raises:
    var s = Suite("motion_match_native")
    var c = parse_character(read_file("build/assets/converted/CesiumMan.lcharacter"), 101)
    s.check(len(c.motion) == 6, "six CMU trials in the character: " + String(len(c.motion)))
    var m = build_match(c, c.motion)
    var total = m.rows()
    var frame_counts = List[Int]()
    var total_frames = 0
    for clip in c.motion:
        var n = len(clip) // (10 * c.joint_count)
        frame_counts.append(n)
        total_frames += n
    s.check(total == total_frames, "one row per frame of every clip: " + String(total) + " rows")
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

    # Per trial: forward speed (mean hip u), sideways drift (|mean v|) and the mean turning rate (mean |heading change|
    # per second, from the facing of each frame).
    var u_mean = List[Float64]()
    var v_abs = List[Float64]()
    var turn_rate = List[Float64]()
    var row0 = 0
    for i in range(6):
        var uu = Float64(0)
        var vv = Float64(0)
        for f in range(frame_counts[i]):
            var raw = m.raw_row(row0 + f)
            uu += Float64(raw[10])
            vv += Float64(raw[11])
        var nf = frame_counts[i]
        u_mean.append(uu / Float64(nf))
        v_abs.append(abs(vv / Float64(nf)))
        var fa = m.tracks[i].facing.copy()
        # Turning rate over a one-second window W (or the clip, if shorter): mean |heading(f+W) - heading(f)| divided by
        # W / fps. A per-frame difference counts each stride's hip sway; over one second the sway cancels.
        var fps = Float64(c.fps)
        var w = min(30, nf - 1)
        var turned = Float64(0)
        for f in range(nf - w):
            var a0 = atan2(Float64(fa[2 * f + 1]), Float64(fa[2 * f]))
            var a1 = atan2(Float64(fa[2 * (f + w) + 1]), Float64(fa[2 * (f + w)]))
            var d = a1 - a0
            while d > PI:
                d -= 2 * PI
            while d < -PI:
                d += 2 * PI
            turned += abs(d)
        turn_rate.append(turned / Float64(nf - w) / (Float64(w) / fps))
        # diagnostic: net heading change from the first frame to the last (a loop clip should be near zero)
        var net = atan2(Float64(fa[2 * (nf - 1) + 1]), Float64(fa[2 * (nf - 1)])) - atan2(Float64(fa[1]), Float64(fa[0]))
        while net > PI:
            net -= 2 * PI
        while net < -PI:
            net += 2 * PI
        print("net heading change first to last (rad)", net)
        print("trial", i, "frames", nf, "mean hip u", u_mean[i], "|v|", v_abs[i], "turn rate (rad/s)", turn_rate[i], "min ground", m.tracks[i].min_ground)
        row0 += nf

    # Straight walks: 07 walk (101) 0.8 to 2.0 m/s; the slow walk is slower, the brisk walk faster; 38 walks forward.
    s.check(u_mean[0] > 0.8 and u_mean[0] < 2.0, "walk 07_01: forward speed 0.8 to 2.0 m/s (" + String(u_mean[0]) + ")")
    s.check(u_mean[1] < u_mean[0], "slow walk is slower than the walk (" + String(u_mean[1]) + " < " + String(u_mean[0]) + ")")
    s.check(u_mean[2] > u_mean[0], "brisk walk is faster than the walk (" + String(u_mean[2]) + " > " + String(u_mean[0]) + ")")
    for i in [3, 4]:
        s.check(u_mean[i] > 0.5 and u_mean[i] < 2.5, "subject 38 walk " + String(i) + ": forward speed 0.5 to 2.5 m/s (" + String(u_mean[i]) + ")")
    for i in range(5):
        s.check(v_abs[i] < 0.2 * u_mean[i], "trial " + String(i) + ": sideways drift is small against forward speed")
    for i in range(6):
        s.check(Float64(m.tracks[i].min_ground) > 0.05, "trial " + String(i) + ": the facing's ground projection never collapses")

    # The turn check: the turn trial turns at least 3x as fast as the fastest straight walk.
    var straight = Float64(0)
    for i in [0, 1, 2, 3, 4]:
        if turn_rate[i] > straight:
            straight = turn_rate[i]
    s.check(turn_rate[5] >= 3.0 * straight, "turn trial 38_04 turns at least 3x the straight walks (" + String(turn_rate[5]) + " vs " + String(straight) + " rad/s)")

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
