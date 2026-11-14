"""The Frontier world as a `GameMode`: a wrapper over `game/frontier.mojo`, with no behaviour of its own."""
from game.arena import DrawItem
from frontier.world import Frontier
from frontier.hud import build_frontier_hud
from game.intent import Intent
from game.mode import GameMode
from procedural.camera_math import CameraPose
from ui.draw import DrawList


struct FrontierMode(GameMode):
    var world: Frontier

    def __init__(out self) raises:
        self.world = Frontier()

    def __init__(out self, *, deinit move: Self):
        self.world = move.world^

    def step(mut self, intent: Intent, frame_dt: Float64) raises:
        self.world.update(intent, frame_dt)

    def scene(mut self) raises -> List[DrawItem]:
        return self.world.draw_items()

    def camera(self) -> CameraPose:
        return self.world.cam.copy()

    def cues(mut self) -> List[Int]:
        return List[Int]()

    def hud(self, width: Float32, height: Float32, frame_ms: Float32) raises -> DrawList:
        return build_frontier_hud(self.world, width, height, frame_ms)

    def hash(self) -> UInt64:
        return self.world.hash()
