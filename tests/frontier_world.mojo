"""The Frontier world (game/frontier.mojo), played by scripts: no window, no GPU.
Native only. `pixi run -e wasm test-game`.

Checks streaming (cells and bodies enter and leave the scene as the player moves, and a body comes back where it
was left), frustum culling (nothing visible is dropped, and something is), and determinism."""
from frontier.world import (
    Frontier, zone_of, zone_name, ZONE_HUB, ZONE_QUARRY, ZONE_CAMP, ZONE_TOWN, ZONE_TRAINING,
    STAT_CELLS_LOADED, STAT_CELLS_TOTAL, STAT_BODIES_LIVE, STAT_BODIES_TOTAL, STAT_DRAWN, STAT_CULLED,
    STAT_LOADS, STAT_UNLOADS, STAT_ZONE, LOAD_R, CELL,
)
from embed.world import pack_body
from game.intent import Intent
from gameplay.large_world import WorldPos
from geometry.vec import Real, Vec3
from std.math import sqrt

comptime FRAME = 1.0 / 60.0


struct Check:
    var passed: Int
    var failed: Int

    def __init__(out self):
        self.passed = 0
        self.failed = 0

    def ok(mut self, cond: Bool, label: String):
        if cond:
            self.passed += 1
            print("  [PASS]", label)
        else:
            self.failed += 1
            print("  [FAIL]", label)


def run(mut f: Frontier, intent: Intent, frames: Int) raises:
    for _ in range(frames):
        f.update(intent, FRAME)


def main() raises:
    var c = Check()

    # zones
    c.ok(zone_of(0, 0) == ZONE_HUB and zone_of(100, -100) == ZONE_QUARRY and zone_of(-100, -100) == ZONE_CAMP
         and zone_of(100, 100) == ZONE_TOWN and zone_of(-100, 100) == ZONE_TRAINING, "the hub and the four quadrants")
    c.ok(zone_name(ZONE_TOWN) == "TOWN", "zones have names")

    # at the start only the neighbourhood is in the scene
    var f = Frontier()
    var total_cells = f.stat(STAT_CELLS_TOTAL)
    var total_bodies = f.stat(STAT_BODIES_TOTAL)
    var cells0 = f.stat(STAT_CELLS_LOADED)
    var live0 = f.stat(STAT_BODIES_LIVE)
    print("  cells", cells0, "/", total_cells, " bodies", live0, "/", total_bodies)
    c.ok(total_cells == 256 and total_bodies > 1500, "256 cells, more than 1500 props in the whole map (" + String(total_bodies) + ")")
    c.ok(cells0 > 4 and cells0 < 40, "a few cells are loaded at the start (" + String(cells0) + ")")
    c.ok(live0 > 0 and live0 * 5 < total_bodies, "less than a fifth of the props are in the scene (" + String(live0) + ")")
    c.ok(f.stat(STAT_ZONE) == ZONE_HUB, "the player starts in the hub")

    # every loaded cell is within reach, every cell within reach is loaded
    var p = f.player_pos()
    var reach_ok = True
    var here0 = WorldPos(Float64(p[0]), Float64(p[1]), Float64(p[2]))
    for k in f.part.loaded:
        if f.part._cell_dist(k, here0) > LOAD_R:
            reach_ok = False
    c.ok(reach_ok, "every loaded cell is within the load radius")

    # the player settles on the ground
    run(f, Intent.idle(), 60)
    c.ok(abs(f.player_pos()[1] - 1.0) < 0.25, "the player stands on the ground (y " + String(f.player_pos()[1]) + ")")

    # walk east and north (yaw 0 looks along -z; right is +x): into the quarry
    var walk = Intent(1, 1, 0, 0, False, False, False)
    var max_live = 0
    for _ in range(20):
        run(f, walk, 60)
        max_live = max(max_live, f.stat(STAT_BODIES_LIVE))
    var q = f.player_pos()
    print("  after 20 s: at", q[0], q[2], " cells", f.stat(STAT_CELLS_LOADED), " live", f.stat(STAT_BODIES_LIVE), " loads", f.loads, " unloads", f.unloads)
    c.ok(q[0] > 60 and q[2] < -60, "20 s of walking took the player far (" + String(q[0]) + ", " + String(q[2]) + ")")
    c.ok(f.stat(STAT_ZONE) == ZONE_QUARRY, "into the quarry")
    c.ok(f.stat(STAT_UNLOADS) > 5 and f.stat(STAT_LOADS) > cells0 + 5, "cells were unloaded behind and loaded ahead")
    c.ok(f.stat(STAT_CELLS_LOADED) < 40, "the number of loaded cells stays bounded (" + String(f.stat(STAT_CELLS_LOADED)) + ")")
    c.ok(max_live * 4 < total_bodies, "the scene never held a quarter of the props (peak " + String(max_live) + ")")

    # a dynamic body comes back where it was left
    var pick = -1
    for i in range(len(f.part.specs)):
        if f.part.live[i] and not f.part.specs[i].is_static:
            pick = i
            break
    c.ok(pick >= 0, "a dynamic prop is in the scene")
    if pick >= 0:
        run(f, Intent.idle(), 120)  # let the stacks settle
        var before = f.world.state(pack_body(f.part.body_of[pick])).pos
        var here = f.player_pos()
        f.teleport(-200.0, 200.0)
        c.ok(not f.part.live[pick], "after leaving, the prop is out of the scene")
        c.ok(f.stat(STAT_ZONE) == ZONE_TRAINING, "the far corner is the training zone")
        run(f, Intent.idle(), 30)
        f.teleport(here[0], here[2])
        c.ok(f.part.live[pick], "after coming back, it is in the scene again")
        var after = f.world.state(pack_body(f.part.body_of[pick])).pos
        var d = after - before
        var moved = sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2])
        c.ok(moved < 0.02, "at the pose it was left in (moved " + String(moved) + " m)")

    # culling: with it on, fewer items; nothing in front of the camera is lost
    f.teleport(112.0, 112.0)  # a street crossing in the town: buildings all around
    run(f, Intent.idle(), 30)
    f.culling = False
    var all = f.draw_items()
    var n_all = len(all)
    f.culling = True
    var seen = f.draw_items()
    var n_seen = len(seen)
    print("  town: loaded items", n_all, " drawn", n_seen, " culled", f.culled)
    c.ok(n_seen < n_all and n_seen > 10, "culling drops some of the loaded items (" + String(n_seen) + " of " + String(n_all) + ")")
    c.ok(n_seen + f.culled == n_all, "drawn + culled = everything loaded")
    c.ok(f.stat(STAT_DRAWN) == n_seen and f.stat(STAT_CULLED) == f.culled, "the stats report the same numbers")
    # every item whose centre is in front of the camera, near its axis, was kept
    var fwd = f.cam.forward()
    var pp = f.player_pos()
    var cd = f.cam.position - pp
    var cam_dist = sqrt(cd[0] * cd[0] + cd[1] * cd[1] + cd[2] * cd[2])
    c.ok(cam_dist > 4.0, "the camera is behind the player, not inside it (" + String(cam_dist) + " m)")
    var lost = 0
    var in_front = 0
    for it in all:
        var d = it.pos - f.cam.position
        var along = d[0] * fwd[0] + d[1] * fwd[1] + d[2] * fwd[2]
        var dist = sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2])
        if along > 1.0 and along > 0.95 * dist:
            in_front += 1
            var found = False
            for s in seen:
                if s.pos[0] == it.pos[0] and s.pos[1] == it.pos[1] and s.pos[2] == it.pos[2]:
                    found = True
            if not found:
                lost += 1
    c.ok(in_front > 3 and lost == 0, "nothing straight ahead was culled (" + String(in_front) + " items ahead)")
    # turning round shows a different set
    run(f, Intent(0, 0, 520, 0, False, False, False), 1)  # about 180 degrees
    run(f, Intent.idle(), 30)
    var back = f.draw_items()
    var same = 0
    for a in back:
        for b in seen:
            if a.pos[0] == b.pos[0] and a.pos[2] == b.pos[2] and a.half[0] == b.half[0]:
                same += 1
                break
    c.ok(same * 2 < len(back), "looking the other way draws mostly other items (" + String(same) + " of " + String(len(back)) + " in common)")

    # determinism
    var a = Frontier()
    var b = Frontier()
    for i in range(600):
        var it = Intent(1, Real(0.5) if i > 200 else Real(0), 0.5, 0, i % 97 == 0, False, False)
        a.update(it, FRAME)
        b.update(it, FRAME)
    c.ok(a.hash() == b.hash() and a.loads > 0, "two runs with the same input have the same hash")
    var other = Frontier()
    run(other, Intent(1, 0, 0, 0, False, False, False), 600)
    c.ok(other.hash() != a.hash(), "a different input gives a different hash")

    print("frontier:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("frontier: failed checks")
