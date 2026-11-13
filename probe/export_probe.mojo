# Feasibility probe: an outside package exports its own wasm entry points, over the engine's game seam.
from game.arena_mode import ArenaMode
from game.intent import Intent


@export
def playground_arena_hash(frames: Int32) abi("C") -> UInt64:
    """Run the arena for `frames` frames with no input and return its hash: a value the page can check."""
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


def main() raises:
    for f in range(1, 4):
        print("native frames", f, playground_arena_hash(Int32(f)))
