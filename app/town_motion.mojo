"""Reference baseline E1 (original stage 4, motion matching): the town's CesiumMan characters pick their clip and frame by
motion matching on their own velocity.

The database is app/motion_match.mojo's MotionMatch (ludens-core MotionDB rows, the playground's 24-value features) over
CesiumMan's retargeted CMU clips: the four walks, the slow walk, the brisk walk and the run (kinds 101-105 and 107). The
walk-with-turns clip (kind 106) is left out: its hip turns, and the town turns the drawn model itself.

Each agent plays its clip forward at the clip's rate. Every QUERY_TICKS ticks (staggered by agent) it builds a probe from
its current frame's feature, with the hip velocity and the trajectory replaced by what its velocity says: moving straight
ahead at its speed, facing ahead, for the next 1 s. The nearest row in the database becomes the agent's clip and frame when
it is another clip or more than SWITCH_FRAMES frames away, and its distance to the probe is below KEEP_RATIO of the
current row's (a switch): without that margin, agents jumped frames on about half their queries. The drawn model is turned about +Y so the clip
frame's facing points along the agent's velocity; an agent standing still keeps its last heading.
"""
from std.math import sqrt, atan2, sin, cos
from geometry.vec import Real, Vec2, Vec3
from frontier_assets import Character
from app.motion_match import MotionMatch, build_match, DIM

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
    var mm: MotionMatch
    var kinds: List[Int]  # per database clip: its index in Character.motion
    var offset: List[Int]  # per database clip: its first row
    var frames: List[Int]  # per database clip: its frame count
    var fps: Real
    var clip: List[Int]  # per agent: database clip
    var frame: List[Real]  # per agent: fractional frame
    var heading: List[Real]  # per agent: the last yaw of its velocity (radians about +Y; 0 faces +Z)
    var switches: Int
    var ticks: Int

    def __init__(out self, c: Character, agents: Int) raises:
        self.kinds = town_kinds(c)
        var clips = List[List[Float32]]()
        for k in self.kinds:
            clips.append(c.motion[k].copy())
        self.mm = build_match(c, clips)
        self.offset = List[Int]()
        self.frames = List[Int]()
        var row = 0
        for i in range(len(self.mm.tracks)):
            self.offset.append(row)
            self.frames.append(self.mm.tracks[i].frames)
            row += self.mm.tracks[i].frames
        self.fps = Real(c.fps)
        self.clip = List[Int]()
        self.frame = List[Real]()
        self.heading = List[Real]()
        for a in range(agents):
            self.clip.append(0)
            self.frame.append(Real((7 * a) % self.frames[0]))
            self.heading.append(Real(0))
        self.switches = 0
        self.ticks = 0

    def probe(self, a: Int, speed: Real) -> List[Real]:
        """Agent a's query: its current frame's feet, then moving straight ahead at `speed` for the next second."""
        var raw = self.mm.raw_row(self.offset[self.clip[a]] + Int(self.frame[a]))
        raw[10] = speed
        raw[11] = Real(0)
        var horizons = List[Real]()
        horizons.append(Real(0.33))
        horizons.append(Real(0.67))
        horizons.append(Real(1.0))
        for h in range(3):
            raw[12 + 4 * h] = speed * horizons[h]
            raw[13 + 4 * h] = Real(0)
            raw[14 + 4 * h] = Real(1)
            raw[15 + 4 * h] = Real(0)
        var out = List[Real]()
        for d in range(DIM):
            out.append(raw[d] / self.mm.scale[d])
        return out^

    def match(self, speed: Real, a: Int) raises -> Int:
        """The nearest database row for agent a moving at `speed`."""
        return self.mm.nearest(self.probe(a, speed))

    def distance(self, probe: List[Real], row: Int) -> Real:
        var d = Real(0)
        for k in range(DIM):
            var e = self.mm.db.feats[row * DIM + k] - probe[k]
            d += e * e
        return d

    def step(mut self, dt: Real, vel: List[Vec2]) raises:
        self.ticks += 1
        for a in range(len(self.clip)):
            var f = self.frame[a] + dt * self.fps
            var n = Real(self.frames[self.clip[a]])
            while f >= n:
                f -= n
            self.frame[a] = f
            var vx = vel[a][0]
            var vz = vel[a][1]
            var speed = sqrt(vx * vx + vz * vz)
            if speed > Real(0.2):
                self.heading[a] = atan2(vx, vz)
            if (self.ticks + a) % QUERY_TICKS == 0:
                var probe = self.probe(a, speed)
                var row = self.mm.nearest(probe)
                var nc = self.mm.db.clip_of[row]
                var nf = self.mm.frame_of[row]
                var cur = self.offset[self.clip[a]] + Int(self.frame[a])
                var better = self.distance(probe, row) < KEEP_RATIO * self.distance(probe, cur)
                if better and (nc != self.clip[a] or abs(Real(nf) - self.frame[a]) > Real(SWITCH_FRAMES)):
                    self.clip[a] = nc
                    self.frame[a] = Real(nf)
                    self.switches += 1

    def kind(self, a: Int) -> Int:
        """Agent a's clip as an index into Character.motion."""
        return self.kinds[self.clip[a]]

    def frame_index(self, a: Int) -> Int:
        return Int(self.frame[a])

    def yaw(self, a: Int) -> Real:
        """The turn about +Y that points agent a's clip frame's facing along its heading."""
        ref t = self.mm.tracks[self.clip[a]]
        var f = Int(self.frame[a])
        var clip_yaw = atan2(t.facing[2 * f], t.facing[2 * f + 1])
        return self.heading[a] - clip_yaw
