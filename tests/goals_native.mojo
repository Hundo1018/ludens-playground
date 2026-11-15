# W6 (plan): one goal per zone, at its fast-travel point. Checks: each goal is counted once, when the player comes within
# 4 m of it; visiting a goal again does not count it twice; all four are reached in one pass.
from harness.runner import Suite
from geometry.vec import Real
from frontier.world import Frontier, goal_point, GOAL_COUNT
from game.intent import Intent


def main() raises:
    var s = Suite("goals_native")
    var f = Frontier()
    s.check(f.goal_count == 0, "no goal is reached at the start")
    for i in range(GOAL_COUNT):
        var g = goal_point(i)
        f.teleport(g[0] + Real(1.0), g[2])
        f.update(Intent.idle(), 1.0 / 60.0)
        s.check(f.goal_count == i + 1, "goal " + String(i) + " is counted when the player reaches it (" + String(f.goal_count) + " of " + String(GOAL_COUNT) + ")")
    # visit the first goal again: no new count
    var g0 = goal_point(0)
    f.teleport(g0[0], g0[2])
    f.update(Intent.idle(), 1.0 / 60.0)
    s.check(f.goal_count == GOAL_COUNT, "a goal already reached is not counted again")
    s.finish()
