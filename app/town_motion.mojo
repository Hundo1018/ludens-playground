"""Reference baseline E1 (original stage 4, motion matching): the town's CesiumMan characters pick their clip and frame by
motion matching on their own velocity, with ludens-core's procedural.motion_match.MotionMatcher (ROADMAP 17.92).

The database is app/motion_match.mojo's build_match (CesiumMan's feet, hip and facing as ludens-core MotionTracks) over
CesiumMan's retargeted CMU clips: the four walks, the slow walk, the brisk walk and the run (kinds 101-105 and 107). The
walk-with-turns clip (kind 106) is left out: its hip turns, and the town turns the drawn model itself.

The matcher's settings are the playground's: every QUERY_TICKS ticks (staggered by agent) an agent probes with its
current frame's feet and moving straight ahead at its own speed; the nearest row is taken when its distance is below
KEEP_RATIO of the current row's and it is another clip or more than SWITCH_FRAMES frames away (without that margin,
agents jumped frames on about half their queries). The drawn model is turned about +Y so the clip frame's facing points
along the agent's velocity; an agent standing still keeps its last heading.
"""
from geometry.vec import Real, Vec2
from app.assets import Character
from app.motion_match import build_match
from procedural.motion_match import MotionMatcher, MotionSwitch

comptime QUERY_TICKS = 10
comptime SWITCH_FRAMES = 3
comptime KEEP_RATIO = Real(0.8)  # switch only when the best row's distance is below 0.8 of the current row's
comptime RUN_KIND = 6  # index into Character.motion of the run (kind 107)


def town_kinds(c: Character) -> List[Int]:
    """The motion indices the town matches over: 0-4 and 6 (kinds 101-105, 107), those the character has."""
    var out = List[Int]()
    for k in [0, 1, 2, 3, 4, 6]:
        if k < len(c.motion):
            out.append(k)
    return out^


struct TownMotion(Movable):
    var m: MotionMatcher
    var kinds: List[Int]  # per database clip: its index in Character.motion
    var fps: Real
    var switches: Int
    var last: List[MotionSwitch]  # the switches of the latest step

    def __init__(out self, c: Character, agents: Int) raises:
        self.kinds = town_kinds(c)
        var clips = List[List[Float32]]()
        for k in self.kinds:
            clips.append(c.motion[k].copy())
        self.m = MotionMatcher(build_match(c, clips), agents, QUERY_TICKS, SWITCH_FRAMES, KEEP_RATIO)
        var first = self.m.mm.tracks[0].frames
        for a in range(agents):
            self.m.place(a, 0, Real((7 * a) % first))
        self.fps = Real(c.fps)
        self.switches = 0
        self.last = List[MotionSwitch]()

    def agents(self) -> Int:
        return self.m.agents()

    def match(self, speed: Real, a: Int) raises -> Int:
        """The nearest database row for agent a moving at `speed`."""
        return self.m.match(a, speed)

    def step(mut self, dt: Real, vel: List[Vec2]) raises:
        self.last = self.m.step(dt, vel)
        self.switches = self.m.switches

    def kind(self, a: Int) -> Int:
        """Agent a's clip as an index into Character.motion."""
        return self.kinds[self.m.clip[a]]

    def frame_index(self, a: Int) -> Int:
        return self.m.frame_index(a)

    def yaw(self, a: Int) -> Real:
        """The turn about +Y that points agent a's clip frame's facing along its heading."""
        return self.m.yaw(a)
