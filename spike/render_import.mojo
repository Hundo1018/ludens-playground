# Spike: can an outside package use the engine's renderer modules unchanged (app/render3d.mojo, app/hud.mojo)?
from render3d import ArenaRenderer
from hud import Hud
from game.arena_mode import ArenaMode
from game.intent import Intent


def main() raises:
    var a = ArenaMode()
    a.step(Intent.idle(), 1.0 / 60.0)
    print("imports resolve; scene items:", len(a.scene()), "hud commands:", len(a.hud(960.0, 540.0, 0.0).cmds))
