"""The playground's wasm entry point: the package's own exports over the engine's game seam (game/mode.mojo).

Each `@export` below is part of this package's surface. The engine supplies the game (`game.arena_mode`); this file decides
what the page can call. Build: `scripts/build_wasm.sh`; check: `node scripts/check_wasm.mjs`."""
from frontier.mode import FrontierMode
from frontier.world import STAT_BODIES_LIVE
from game.arena_mode import ArenaMode
from game.intent import Intent


@export
def playground_arena_hash(frames: Int32) abi("C") -> UInt64:
    """Run the arena for `frames` frames with no input and return its hash, a value the page can check. 0 on failure."""
    try:
        var a = ArenaMode()
        var h = UInt64(0)
        for _ in range(Int(frames)):
            a.step(Intent.idle(), 1.0 / 60.0)
            h = a.hash()
        return h
    except e:
        print("playground_arena_hash:", e)
        return 0


@export
def playground_frontier_hash(frames: Int32) abi("C") -> UInt64:
    """Run the Frontier world for `frames` frames with no input and return its hash. 0 on failure."""
    try:
        var w = FrontierMode()
        var h = UInt64(0)
        for _ in range(Int(frames)):
            w.step(Intent.idle(), 1.0 / 60.0)
            h = w.hash()
        return h
    except e:
        print("playground_frontier_hash:", e)
        return 0


@export
def playground_frontier_bodies(frames: Int32) abi("C") -> Int32:
    """Props in the physics scene after `frames` frames: the streaming, observable without a hash."""
    try:
        var w = FrontierMode()
        for _ in range(Int(frames)):
            w.step(Intent.idle(), 1.0 / 60.0)
        return Int32(w.world.stat(STAT_BODIES_LIVE))
    except e:
        print("playground_frontier_bodies:", e)
        return -1


def main() raises:
    for f in range(1, 4):
        print("native frames", f, playground_arena_hash(Int32(f)))
        print("native frontier frames", f, playground_frontier_hash(Int32(f)), "bodies", playground_frontier_bodies(Int32(f)))
