"""The camera view (game/camera_view.mojo): what lands where on screen, and the chase camera of a played game.
Native only: `pixi run -e wasm test-game`."""
from arena.arena import Arena, DT
from game.camera_view import View
from game.intent import Intent
from geometry.quat import Quat
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose


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
    # at the origin, identity rotation: looks along -z, +x is right, +y is up; 90 degree vertical field of view
    var cam = CameraPose(Vec3(0.0, 0.0, 0.0, 0.0), Quat(0.0, 0.0, 0.0, 1.0), 1.5707963, 2.0, 0.1, 100.0)
    var v = View(cam, 2.0)
    var ahead = v.project(Vec3(0.0, 0.0, -10.0, 0.0))
    c.ok(abs(ahead.x) < 1e-4 and abs(ahead.y) < 1e-4 and ahead.w > 9.9 and ahead.on_screen(), "a point straight ahead lands in the centre")
    var right = v.project(Vec3(5.0, 0.0, -10.0, 0.0))
    c.ok(right.x / right.w > 0.24 and right.x / right.w < 0.26, "5 m right at 10 m with aspect 2 and a 90 degree field: x = 0.25 (" + String(right.x / right.w) + ")")
    var up = v.project(Vec3(0.0, 5.0, -10.0, 0.0))
    c.ok(up.y / up.w > 0.49 and up.y / up.w < 0.51, "5 m up at 10 m: y = 0.5 (" + String(up.y / up.w) + ")")
    c.ok(not v.project(Vec3(0.0, 0.0, 10.0, 0.0)).on_screen(), "a point behind the camera is not on screen")
    c.ok(not v.project(Vec3(0.0, 0.0, -200.0, 0.0)).on_screen(), "a point beyond the far plane is not on screen")
    c.ok(not v.project(Vec3(50.0, 0.0, -10.0, 0.0)).on_screen(), "a point far to the side is not on screen")
    var nearp = v.project(Vec3(0.0, 0.0, -0.1, 0.0))
    var farp = v.project(Vec3(0.0, 0.0, -100.0, 0.0))
    c.ok(abs(nearp.z) < 1e-4 and abs(farp.z - farp.w) < 1e-3, "the near plane maps to z = 0 and the far plane to z = w")

    # the chase camera of a real game sees the player near the centre of the screen
    var a = Arena()
    for _ in range(120):
        a.update(Intent.idle(), 1.0 / 60.0)
    var view = View(a.cam, 1.78)
    var p = view.project(a.player_pos())
    c.ok(p.on_screen() and abs(p.x / p.w) < 0.3, "the player is on screen, near the middle (x = " + String(p.x / p.w) + ", y = " + String(p.y / p.w) + ")")
    var seen = 0
    for it in a.draw_items():
        if view.project(it.pos).on_screen():
            seen += 1
    c.ok(seen >= 5, String(seen) + " of the items are on screen from the start")

    print("arena_camera:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("arena_camera: " + String(c.failed) + " checks failed")
