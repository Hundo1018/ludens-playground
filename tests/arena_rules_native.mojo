"""The arena game (ludens-engine sample game), played by scripts: no window, no GPU, no sound.
Native only. `pixi run -e wasm test-game`.

What a person does is an `Intent` per frame, so a test can play the whole game: walk to the spheres along the
navmesh, stand still and get caught, pause, jump. The checks are the rules of the game and its determinism."""
from arena.arena import (
    Arena, DT, STATUS_PLAYING, STATUS_WON, STATUS_LOST, N_ITEMS, MAX_HEALTH, TIME_LIMIT_TICKS,
    CUE_PICKUP, CUE_HIT, CUE_JUMP, CUE_WIN, CUE_LOSE, CUE_RAIN,
)
from game.intent import Intent
from geometry.vec import Real, Vec3
from nav.path import PolyFunnel
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


def run(mut a: Arena, intent: Intent, frames: Int) raises:
    for _ in range(frames):
        a.update(intent, FRAME)


def dist2(a: Vec3, b: Vec3) -> Real:
    var dx = a[0] - b[0]
    var dz = a[2] - b[2]
    return sqrt(dx * dx + dz * dz)


struct Bot:
    """Plays like a person who knows the map: walk the navmesh path to the nearest sphere, then the next."""

    var corners: List[Vec3]
    var at: Int
    var age: Int

    def __init__(out self):
        self.corners = List[Vec3]()
        self.at = 0
        self.age = 1000

    def pick(self, a: Arena) raises -> Int:
        var best = -1
        var best_d = Real(1e9)
        var pp = a.player_pos()
        for i in range(len(a.items)):
            if a.item_taken[i]:
                continue
            var d = dist2(pp, a.items[i])
            if d < best_d:
                best_d = d
                best = i
        return best

    def intent(mut self, a: Arena) raises -> Intent:
        var i = self.pick(a)
        if i < 0:
            return Intent.idle()
        var pp = a.player_pos()
        if self.age >= 20:
            var pf = PolyFunnel()
            var p = pf.find(a.mesh, Vec3(pp[0], 0.0, pp[2], 0.0), Vec3(a.items[i][0], 0.0, a.items[i][2], 0.0))
            self.corners = p.points.copy()
            self.at = 1 if len(self.corners) > 1 else 0
            self.age = 0
        self.age += 1
        var to = a.items[i]
        if len(self.corners) > 0:
            while self.at < len(self.corners) - 1 and dist2(pp, self.corners[self.at]) < 0.6:
                self.at += 1
            to = self.corners[self.at]
        var dx = to[0] - pp[0]
        var dz = to[2] - pp[2]
        var l = sqrt(dx * dx + dz * dz)
        if l < 0.01:
            return Intent.idle()
        # yaw stays 0: the camera looks along -z, so forward is -z and right is +x
        return Intent(-dz / l, dx / l, 0, 0, False, False, False)


def play_bot(mut a: Arena, max_frames: Int) raises -> Int:
    var bot = Bot()
    var n = 0
    while a.status() == STATUS_PLAYING and n < max_frames:
        a.update(bot.intent(a), FRAME)
        n += 1
    return n


def count_cue(cues: List[Int], cue: Int) -> Int:
    var n = 0
    for c in cues:
        if c == cue:
            n += 1
    return n


comptime ARENA_POLYS = 116
comptime ARENA_AREA_CM2 = 14365000


def main() raises:
    var c = Check()

    # --- standing: the player settles at the ride height, the game is on --------------------------------
    var a = Arena()
    # the navmesh baked from the floor and the two walls (game/arena.mojo _make_mesh): pinned to the values measured before
    # its input was built with ludens-core's nav.nav_input, whose box sides face outward (the old _nav_box's faced in)
    var area_cm2 = Int(a.mesh.walkable_area() * Real(10000.0) + Real(0.5))
    c.ok(a.mesh.poly_count() == ARENA_POLYS and area_cm2 == ARENA_AREA_CM2, "the arena navmesh: " + String(a.mesh.poly_count()) + " polygons, " + String(area_cm2) + " cm2 (pinned " + String(ARENA_POLYS) + ", " + String(ARENA_AREA_CM2) + ")")
    c.ok(a.status() == STATUS_PLAYING and a.health() == MAX_HEALTH and a.collected() == 0, "a new game: playing, full health, nothing collected")
    run(a, Intent.idle(), 120)
    var y = a.player_pos()[1]
    c.ok(abs(y - 1.0) < 0.02, "the player settles at the ride height 1.0 m (" + String(y) + ")")
    c.ok(len(a.draw_items()) > 20, "there is something to draw: " + String(len(a.draw_items())) + " items")

    # --- walking and jumping ----------------------------------------------------------------------------
    var w = Arena()
    w.chasers_on = False
    run(w, Intent.idle(), 60)
    var x0 = w.player_pos()[0]
    run(w, Intent(0, 1, 0, 0, False, False, False), 60)  # right for one second
    var moved = w.player_pos()[0] - x0
    c.ok(moved > 4.0 and moved < 5.6, "one second to the right moves about 5.5 m (" + String(moved) + ")")
    var jy = w.player_pos()[1]
    w.update(Intent(0, 0, 0, 0, True, False, False), FRAME)
    var top = jy
    for _ in range(50):
        w.update(Intent.idle(), FRAME)
        top = max(top, w.player_pos()[1])
    c.ok(top - jy > 0.8, "a jump lifts the player " + String(top - jy) + " m")
    c.ok(count_cue(w.take_cues(), CUE_JUMP) == 1, "one jump, one cue (the edge is used once per frame)")

    # --- the chasers come for a player who stands still -------------------------------------------------
    var h = Arena()
    var d0 = dist2(h.player_pos(), h.world.state(h.chaser_h[0]).pos)
    run(h, Intent.idle(), 360)
    var d1 = dist2(h.player_pos(), h.world.state(h.chaser_h[0]).pos)
    c.ok(d1 < d0 - 8.0, "a chaser closes in on a player who stands still: " + String(d0) + " m -> " + String(d1) + " m in 6 s")
    run(h, Intent.idle(), 60 * 40)
    c.ok(h.status() == STATUS_LOST and h.health() <= 0, "standing still loses: health " + String(h.health()) + " after " + String(h.hits) + " hits")
    c.ok(h.hits >= MAX_HEALTH // 25 and h.hits <= MAX_HEALTH // 25, "it takes exactly 4 hits to lose (" + String(h.hits) + ")")
    var gap_ok = len(h.hit_ticks) >= 2
    var min_gap = 1000000
    for k in range(1, len(h.hit_ticks)):
        min_gap = min(min_gap, h.hit_ticks[k] - h.hit_ticks[k - 1])
    gap_ok = gap_ok and min_gap >= 60
    c.ok(gap_ok, "the immunity effect spaces the hits at least 1 s (60 ticks) apart: shortest gap " + String(min_gap) + " ticks")
    var cues = h.take_cues()
    c.ok(count_cue(cues, CUE_LOSE) == 1 and count_cue(cues, CUE_HIT) == h.hits, "a hit cue per hit and one lose cue")

    # --- the clock --------------------------------------------------------------------------------------
    var t = Arena()
    t.chasers_on = False
    run(t, Intent.idle(), TIME_LIMIT_TICKS - 30)
    c.ok(t.status() == STATUS_PLAYING and t.seconds_left() == 0, "just before the end the game is still on")
    run(t, Intent.idle(), 60)
    c.ok(t.status() == STATUS_LOST and t.health() == MAX_HEALTH, "time up loses with full health")

    # --- pause ------------------------------------------------------------------------------------------
    var p = Arena()
    run(p, Intent.idle(), 30)
    var tick = p.tick
    p.update(Intent(0, 0, 0, 0, False, True, False), FRAME)
    c.ok(p.paused(), "pause pauses")
    run(p, Intent.idle(), 120)
    c.ok(p.tick == tick, "no tick passes while paused")
    p.update(Intent(0, 0, 0, 0, False, True, False), FRAME)
    run(p, Intent.idle(), 10)
    c.ok(not p.paused() and p.tick > tick, "pause again resumes")

    # --- winning: collect the 8 spheres ----------------------------------------------------------------
    var g = Arena()
    g.chasers_on = False
    var frames = play_bot(g, 60 * 80)
    c.ok(g.status() == STATUS_WON, "walking the navmesh to each sphere wins (after " + String(Real(frames) / 60.0) + " s, " + String(g.collected()) + " / " + String(N_ITEMS) + ")")
    c.ok(g.collected() == N_ITEMS and g.score >= 800, "score " + String(g.score) + ": 100 a sphere plus 10 a second left")
    var gcues = g.take_cues()
    c.ok(count_cue(gcues, CUE_PICKUP) == N_ITEMS and count_cue(gcues, CUE_WIN) == 1, "a cue per sphere and one win cue")
    c.ok(count_cue(gcues, CUE_RAIN) == 1 and g.sheet.get("rain_on") == 1, "the event sheet rained crates after the 4th sphere (its counter reads " + String(g.sheet.get("collected")) + ": it sees a pickup one tick later)")

    # --- difficulty: the same bot with the chasers and the bar on, over several runs of the same game --------------------
    var wins = 0
    var total_hits = 0
    var best = 0
    for run_no in range(3):
        var d = Arena()
        for _ in range(run_no * 7):  # a different start moment each run: the chasers are in a different place
            d.update(Intent.idle(), FRAME)
        var fr = play_bot(d, 60 * 85)
        total_hits += d.hits
        if d.status() == STATUS_WON:
            wins += 1
            best = max(best, d.score)
        print("  run", run_no, ": status", d.status(), "collected", d.collected(), "hits", d.hits, "after", Real(fr) / 60.0, "s")
    c.ok(total_hits > 0, "the chasers and the bar do hit a bot that walks past them (" + String(total_hits) + " hits in 3 runs)")
    print("  info: bot wins", wins, "of 3 with chasers on")

    # --- determinism: the same play gives the same hash ------------------------------------------------
    var r1 = Arena()
    r1.chasers_on = False
    _ = play_bot(r1, 60 * 30)
    var r2 = Arena()
    r2.chasers_on = False
    _ = play_bot(r2, 60 * 30)
    c.ok(r1.hash() == r2.hash(), "the same script twice gives the same hash " + String(r1.hash()))
    var r3 = Arena()
    r3.chasers_on = False
    _ = play_bot(r3, 60 * 20)
    c.ok(r1.hash() != r3.hash(), "a different run gives a different hash")
    var s1 = Arena()
    var s2 = Arena()
    run(s1, Intent(0, 1, 0, 0, False, False, False), 240)
    run(s2, Intent(0, 1, 0, 0, False, False, False), 240)
    c.ok(s1.hash() == s2.hash(), "with the chasers on, two runs still agree")

    # --- the world round trip: save, run on, load, same state -------------------------------------------
    var q = Arena()
    q.chasers_on = False
    run(q, Intent(0, 1, 0, 0, False, False, False), 90)
    var snap = q.world.save()
    var before = q.world.hash()
    run(q, Intent(1, 0, 0, 0, False, False, False), 90)
    c.ok(q.world.hash() != before, "the world moved on after the save")
    q.world.load(snap)
    c.ok(q.world.hash() == before, "loading the save brings back the same world hash")

    # --- the camera ------------------------------------------------------------------------------------
    var cam = Arena()
    run(cam, Intent.idle(), 60)
    var cd = dist2(cam.cam.position, cam.player_pos())
    c.ok(cam.cam.position[1] > cam.player_pos()[1] and cd > 3.0 and cd < 7.5, "the chase camera sits behind and above the player, " + String(cd) + " m away")

    print("arena:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("arena: " + String(c.failed) + " checks failed")
