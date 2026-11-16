# Reference baseline E2 (foot IK): CesiumMan's slow walk (kind 102) on a 20 degree slope rising along its heading, every
# frame, with and without app/foot_ik.mojo. Checks: without IK some foot is off the ground by more than 0.05 m (the slope
# matters); with IK every foot's error stays under 0.01 m on every frame; with IK off the palette equals the plain
# pose_palette_clip (the IK path changes nothing else).
from std.math import sqrt
from harness.runner import Suite
from frontier_assets import parse_character, pose_palette_clip
from app.foot_ik import foot_ik, Slope, _model_mats, HIP_L, KNEE_L, ANKLE_L, HIP_R, KNEE_R, ANKLE_R
from geometry.vec import Real

comptime PI = 3.141592653589793


def read_file(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def main() raises:
    var s = Suite("foot_ik_native")
    var c = parse_character(read_file("build/assets/converted/CesiumMan.lcharacter"), 101)
    ref clip = c.motion[1]
    var frames = len(clip) // (10 * c.joint_count)
    var slope = Slope(Real(20.0 * PI / 180.0), Real(0.0), Real(0.0), Real(1.0))
    var worst_ik = Real(0)
    var worst_raw = Real(0)
    var worst_drop = Real(0)
    for f in range(frames):
        var r = foot_ik(c, clip, f, slope, True)
        worst_ik = max(worst_ik, max(abs(r.err_l), abs(r.err_r)))
        worst_raw = max(worst_raw, max(abs(r.raw_l), abs(r.raw_r)))
        worst_drop = min(worst_drop, r.drop)
    print("slow walk on 20 deg,", frames, "frames: worst foot error with IK", worst_ik, "m, without", worst_raw,
          "m; deepest pelvis drop", worst_drop, "m")
    s.check(worst_raw > Real(0.05), "without IK a foot is off the slope by more than 0.05 m (" + String(worst_raw) + ")")
    s.check(worst_ik < Real(0.01), "with IK every foot is within 0.01 m of the slope on every frame (" + String(worst_ik) + ")")
    # IK off: the same palette as the plain path
    var off = foot_ik(c, clip, 5, slope, False)
    var plain = pose_palette_clip(c, clip, 5)
    var dmax = Float32(0)
    for i in range(len(plain)):
        dmax = max(dmax, abs(off.palette[i] - plain[i]))
    s.check(len(off.palette) == len(plain) and dmax < Float32(1e-5), "with IK off the palette equals pose_palette_clip (max " + String(dmax) + ")")
    s.finish()
