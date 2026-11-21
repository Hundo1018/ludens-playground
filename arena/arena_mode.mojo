"""The arena game as a `GameMode`: a wrapper that adds no behaviour of its own, so the arena's numbers do not change."""
from arena.arena import Arena, DrawItem
from arena.hud_layout import build_hud
from game.intent import Intent
from game.mode import GameMode
from procedural.camera_math import CameraPose
from ui.draw import DrawList


struct ArenaMode(GameMode):
    var arena: Arena

    def __init__(out self) raises:
        self.arena = Arena()

    @staticmethod
    def create() raises -> Self:
        return Self()

    def __init__(out self, *, deinit move: Self):
        self.arena = move.arena^

    def step(mut self, intent: Intent, frame_dt: Float64) raises:
        self.arena.update(intent, frame_dt)

    def scene(mut self) raises -> List[DrawItem]:
        return self.arena.draw_items()

    def camera(self) -> CameraPose:
        return self.arena.cam.copy()

    def cues(mut self) -> List[Int]:
        return self.arena.take_cues()

    def hud(self, width: Float32, height: Float32, frame_ms: Float32) raises -> DrawList:
        return build_hud(self.arena, width, height)

    def hash(self) -> UInt64:
        return self.arena.hash()
