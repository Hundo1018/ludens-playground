# Plan stage 3 (card 3) and W4: the town in the TOWN zone, its navmesh holes from the frontier's own buildings. Checks: the
# four route corners are on the mesh (Town raises otherwise); at least 12 of 24 residents reach a corner within 1200 ticks;
# no resident stands inside a building over the run; minimum pairwise separation stays above -0.05 m; the guard closes on
# a player standing in the square within 60 ticks.
from harness.runner import Suite
from geometry.vec import Real, Vec3
from frontier.world import Frontier, StaticBox
from app.town import Town, RESIDENTS, corner, inside_square


def inside_a_building(p: Vec3, boxes: List[StaticBox]) -> Bool:
    for b in boxes:
        if abs(p[0] - b.c[0]) < b.h[0] and abs(p[2] - b.c[2]) < b.h[2]:
            return True
    return False


def main() raises:
    var s = Suite("town_native")
    var dt = Real(1.0 / 60.0)
    var f = Frontier()
    var boxes = f.static_boxes(96.0, 96.0, 160.0, 160.0, 1.0)
    s.check(len(boxes) >= 8, "the frontier has the town's buildings in the square: " + String(len(boxes)) + " boxes")

    # the four corners lie in the street gaps: no building contains them
    var corners_free = True
    for i in range(4):
        if inside_a_building(corner(i), boxes):
            corners_free = False
    s.check(corners_free, "the four route corners are outside every building")

    var player = Vec3(128.0, 0.0, 112.0, 0.0)  # on the street between corners 0 and 1, inside the square
    var t = Town(boxes)
    var reached = List[Bool]()
    for _ in range(RESIDENTS):
        reached.append(False)
    var worst = Real(1e30)
    var inside_count = 0
    var guard0 = t.guard_distance(player)
    var guard60 = guard0
    for tick in range(1200):
        t.step(dt, player)
        for k in range(RESIDENTS):
            if t.crowd.arrived[k]:
                reached[k] = True
        if tick % 10 == 0:
            var sep = t.crowd.min_separation()
            if sep < worst:
                worst = sep
            for k in range(RESIDENTS):
                if inside_a_building(t.crowd.pos[k], boxes):
                    inside_count += 1
        if tick == 59:
            guard60 = t.guard_distance(player)

    var n = 0
    for k in range(RESIDENTS):
        if reached[k]:
            n += 1
    s.check(n >= 12, "at least 12 of 24 residents reach a corner within 1200 ticks: " + String(n) + " did")
    s.check(inside_count == 0, "no resident stands inside a building over the run (samples inside: " + String(inside_count) + ")")
    s.check(worst > Real(-0.05), "minimum pairwise separation stays above -0.05 m over the run: " + String(worst) + " m")
    s.check(inside_square(player), "the test player stands in the square")
    s.check(guard60 < guard0, "the guard closes on the still player within 60 ticks: " + String(guard0) + " m -> " + String(guard60) + " m")
    var guard_end = t.guard_distance(player)
    s.check(guard_end < Real(1.0), "the guard reaches a still player within the contact distance (1 m) after 1200 ticks: " + String(guard_end) + " m")
    # D1: the residents' behavior tree changes actions over the run (walk, next corner, watch)
    print("behavior tree transitions over 1200 ticks:", t.bt.transitions)
    s.check(t.bt.transitions > RESIDENTS, "the residents' behavior trees change action over the run: " + String(t.bt.transitions) + " transitions")
    # D1: a player standing on a resident puts it in the watch branch
    var tw = Town(boxes)
    var near_player = tw.crowd.pos[0]
    for _ in range(5):
        tw.step(dt, near_player)
    s.check(tw.watching() >= 1, "a player next to a resident makes it stop and watch: " + String(tw.watching()) + " watching")
    # D2: the guard's cone and line of sight
    var tp = Town(boxes)
    var at = corner(0)
    var ahead = tp.look(at, Vec3(1.0, 0.0, 0.0, 0.0), at + Vec3(12.0, 0.0, 0.0, 0.0))
    var behind = tp.look(at, Vec3(1.0, 0.0, 0.0, 0.0), at - Vec3(12.0, 0.0, 0.0, 0.0))
    print("guard at corner 0 facing +x: player 12 m ahead seen", ahead, "; 12 m behind seen", behind)
    s.check(ahead, "the guard sees a player 12 m ahead along the street")
    s.check(not behind, "the guard does not see a player 12 m behind it")
    s.finish()
