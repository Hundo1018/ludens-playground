"""The HUD layout (game/hud_layout.mojo): what is on screen while playing, paused, won and lost, and that it follows the
window size. Native only: `pixi run -e wasm test-game`."""
from arena.arena import Arena, STATUS_WON, STATUS_LOST, TIME_LIMIT_TICKS
from arena.hud_layout import build_hud, dot_scale
from game.intent import Intent

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


def main() raises:
    var c = Check()
    var a = Arena()
    a.chasers_on = False
    var play = build_hud(a, 1280, 720)
    c.ok(play.count() > 150, "while playing the HUD has score, spheres, time, health and hints: " + String(play.count()) + " rectangles")
    c.ok(play.hash() == build_hud(a, 1280, 720).hash(), "the same state gives the same HUD")

    a.update(Intent(0, 0, 0, 0, False, True, False), FRAME)
    var paused = build_hud(a, 1280, 720)
    c.ok(a.paused() and paused.count() > play.count() + 20, "paused adds a banner (" + String(paused.count() - play.count()) + " more)")
    a.update(Intent(0, 0, 0, 0, False, True, False), FRAME)

    var t = Arena()
    t.chasers_on = False
    for _ in range(TIME_LIMIT_TICKS + 5):
        t.update(Intent.idle(), FRAME)
    var lost = build_hud(t, 1280, 720)
    c.ok(t.status() == STATUS_LOST and lost.count() > play.count() + 20, "game over shows a banner")
    c.ok(lost.hash() != paused.hash(), "game over and paused look different")

    c.ok(dot_scale(720) == 3 and dot_scale(1440) == 7 and dot_scale(100) == 2, "dot size follows the window height: 720 -> " + String(dot_scale(720)))
    c.ok(build_hud(a, 640, 360).hash() != build_hud(a, 1280, 720).hash(), "a smaller window lays out differently")

    print("arena_hud:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("arena_hud: " + String(c.failed) + " checks failed")
