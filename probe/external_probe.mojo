# Feasibility probe: an outside package compiles against the engine's game seam without copying engine code.
from game.arena_mode import ArenaMode
from game.intent import Intent


def main() raises:
    var a = ArenaMode()
    for n in range(1, 4):
        a.step(Intent.idle(), 1.0 / 60.0)
        print("native frame", n, "hash", a.hash())
