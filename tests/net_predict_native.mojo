# tier: unit
"""Step 8 prediction-error bound (docs/frontier_plan.md line 430), natively: SimLink(9, 2, 0.0, 55) (about 150 ms, no
loss), 600 ticks, the walk stops at tick 540. Per snapshot tick, the predicted client's player-0 x must be within
750 mm of the server's truth at the same tick; after 60 idle ticks within 10 mm; player 0's tick, x and z equal the
truth at T. The shown client must trail the predicted sim by more than 500 mm (it is behind by the link's delay).
The measured numbers are printed, not tuned to the bound.
"""
from harness.runner import Suite
from app.net_predict import run_predict, PREDICT_T, PREDICT_SEED
from geometry.vec import Real


def main() raises:
    var s = Suite("net_predict_native")
    var r = run_predict(9, 2, Real(0.0), PREDICT_SEED, PREDICT_T)
    print("predict: frames", len(r.frames), "ticks checked", r.ticks_checked)
    print("predict: worst per-tick error (mm)", r.worst_predicted_mm, " after idle (mm)", r.worst_idle_mm)
    print("predict: worst shown lag (mm)", r.worst_lag_mm)
    s.check(r.ticks_checked >= 500, "the predicted and truth positions are compared on at least 500 ticks")
    s.check(r.worst_predicted_mm < 750, "per-tick predicted error under 750 mm (got " + String(r.worst_predicted_mm) + ")")
    s.check(r.worst_idle_mm < 10, "predicted error under 10 mm after 60 idle ticks (got " + String(r.worst_idle_mm) + ")")
    s.check(r.p0_equal_at_end, "player 0 equal to the truth at T (tick, x and z)")
    s.check(r.worst_lag_mm > 500, "the shown client trails the predicted sim (lag over 500 mm)")
    s.finish()
