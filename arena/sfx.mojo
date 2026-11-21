"""The game's sound effects: a handful of voices synthesised in code, mixed into one stereo float buffer.

No samples and no audio library. Every voice is a function of how many samples it has played, so the same cues at the same
times always give the same bytes. The shell copies `render`'s output to the audio device."""
from arena.arena import CUE_PICKUP, CUE_HIT, CUE_JUMP, CUE_WIN, CUE_LOSE, CUE_RAIN
from geometry.trig import sin

comptime VOICES = 8
comptime CUE_COUNT = 6  # cues are numbered 1 .. CUE_COUNT (game/arena.mojo)
comptime TAU: Float64 = 6.283185307179586
comptime MASTER: Float64 = 0.6


struct Voice(Copyable, Movable):
    var cue: Int  # -1 = free
    var age: Int  # samples played
    var phase: Float64
    var noise: UInt32

    def __init__(out self):
        self.cue = -1
        self.age = 0
        self.phase = 0.0
        self.noise = 12345


def cue_seconds(cue: Int) -> Float64:
    if cue == CUE_PICKUP:
        return 0.20
    if cue == CUE_HIT:
        return 0.35
    if cue == CUE_JUMP:
        return 0.16
    if cue == CUE_WIN:
        return 0.80
    if cue == CUE_LOSE:
        return 0.90
    if cue == CUE_RAIN:
        return 0.60
    return 0.0


def _square(phase: Float64) -> Float64:
    return 1.0 if phase - Float64(Int(phase)) < 0.5 else -1.0


struct Sfx(Movable):
    var rate: Float64
    var voices: List[Voice]
    var triggered: Int

    def __init__(out self, rate: Int):
        self.rate = Float64(rate)
        self.voices = List[Voice]()
        for _ in range(VOICES):
            self.voices.append(Voice())
        self.triggered = 0

    def trigger(mut self, cue: Int):
        """Start a voice for `cue`; with all voices busy the oldest is taken over."""
        if cue_seconds(cue) <= 0.0:
            return
        var pick = 0
        var oldest = -1
        for i in range(VOICES):
            if self.voices[i].cue < 0:
                pick = i
                oldest = -2
                break
            if self.voices[i].age > oldest:
                oldest = self.voices[i].age
                pick = i
        var v = Voice()
        v.cue = cue
        v.noise = UInt32(12345 + 7919 * self.triggered)
        self.voices[pick] = v^
        self.triggered += 1

    def busy(self) -> Int:
        var n = 0
        for i in range(VOICES):
            if self.voices[i].cue >= 0:
                n += 1
        return n

    def _sample(self, mut v: Voice) -> Float64:
        var t = Float64(v.age) / self.rate
        var len = cue_seconds(v.cue)
        var env = 1.0 - t / len  # linear fade to silence
        var s = 0.0
        if v.cue == CUE_PICKUP:
            var f = 880.0 if t < 0.08 else 1320.0
            v.phase += f / self.rate
            s = _square(v.phase) * 0.5
        elif v.cue == CUE_JUMP:
            var f = 300.0 + 300.0 * (t / len)
            v.phase += f / self.rate
            s = sin(v.phase * TAU) * 0.8
        elif v.cue == CUE_HIT:
            v.noise = v.noise * 1664525 + 1013904223
            var n = Float64(Int(v.noise >> 16) & 0xFFFF) / 32768.0 - 1.0
            v.phase += 110.0 / self.rate
            s = n * 0.6 + sin(v.phase * TAU) * 0.6
        elif v.cue == CUE_RAIN:
            v.noise = v.noise * 1664525 + 1013904223
            var n = Float64(Int(v.noise >> 16) & 0xFFFF) / 32768.0 - 1.0
            v.phase += 70.0 / self.rate
            s = n * 0.35 + _square(v.phase) * 0.35
        elif v.cue == CUE_WIN:
            var notes = [523.25, 659.25, 783.99, 1046.5]
            var k = min(Int(t / 0.2), 3)
            v.phase += notes[k] / self.rate
            s = _square(v.phase) * 0.45
            env = 1.0 - t / len
        elif v.cue == CUE_LOSE:
            var f = 400.0 - 300.0 * (t / len)
            v.phase += f / self.rate
            s = _square(v.phase) * 0.5
        v.age += 1
        if Float64(v.age) / self.rate >= len:
            v.cue = -1
        return s * env

    def render(mut self, mut pcm: List[Float32], frames: Int):
        """Fill `pcm` with `frames` stereo frames (2 floats each), every active voice summed and limited to [-1, 1]."""
        pcm.resize(frames * 2, 0.0)
        for i in range(frames):
            var sum = 0.0
            for j in range(VOICES):
                if self.voices[j].cue >= 0:
                    sum += self._sample(self.voices[j])
            var out = sum * MASTER
            if out > 1.0:
                out = 1.0
            if out < -1.0:
                out = -1.0
            pcm[2 * i] = Float32(out)
            pcm[2 * i + 1] = Float32(out)


def cue_clip(cue: Int, rate: Int) -> List[Float32]:
    """One cue from start to silence as interleaved stereo samples: what a clip-based mixer registers once and plays
    on every trigger. The same samples a fresh `Sfx` renders for that cue."""
    var sfx = Sfx(rate)
    sfx.trigger(cue)
    var pcm = List[Float32]()
    sfx.render(pcm, Int(cue_seconds(cue) * Float64(rate)) + 1)
    return pcm^
