# tier: unit
"""Step 8 prediction-error bound (docs/frontier_plan.md line 430), natively: SimLink(9, 2, 0.0, 55) (about 150 ms, no
loss), 600 ticks, the walk stops at tick 540. Per tick, the predicted client's player-0 x (same sim tick as the
snapshot it is compared with) must be within 0.75 m of the server's truth; after 60 idle ticks within 0.01 m; the
predicted and truth hashes equal at T. The unpredicted client must trail: its shown tick is behind the predicted sim.
The measured numbers are printed, not tuned to the bound.
"""
from harness.runner import Suite
from app.net_predict import run_predict
from geometry.vec import Real


def main() raises:
    var s = Suite("net_predict_native")
    var r = run_predict(9, 2, Real(0.0), UInt64(55), 600)
    print("predict: frames", r.frames, "ticks checked", r.ticks_checked)
    print("predict: worst per-tick error (m)", r.worst_predicted_m, " after idle (m)", r.worst_idle_m)
    print("predict: worst unpredicted lag (m)", r.worst_unpredicted_lag_m)
    s.check(r.ticks_checked >= 500, "the predicted and truth positions are compared on at least 500 ticks")
    s.check(r.worst_predicted_m < 0.75, "per-tick predicted error under 0.75 m (got " + String(r.worst_predicted_m) + ")")
    s.check(r.worst_idle_m < 0.01, "predicted error under 0.01 m after 60 idle ticks (got " + String(r.worst_idle_m) + ")")
    s.check(r.p0_equal_at_end, "player 0 equal to the truth at T (tick, x and z)")
    s.check(r.worst_unpredicted_lag_m > 0.5, "the unpredicted client trails the predicted sim (lag over 0.5 m)")
    s.finish()
