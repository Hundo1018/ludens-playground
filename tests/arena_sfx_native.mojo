"""The sound effects (game/sfx.mojo): silence with no cue, sound with one, every cue ends, the output stays inside
[-1, 1], and the same cues give the same samples. Native only: `pixi run -e wasm test-game`."""
from arena.arena import CUE_PICKUP, CUE_HIT, CUE_JUMP, CUE_WIN, CUE_LOSE, CUE_RAIN
from arena.sfx import Sfx, cue_seconds, cue_clip, CUE_COUNT
from std.math import sqrt

comptime RATE = 48000


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


def rms(pcm: List[Float32]) -> Float64:
    var s = 0.0
    for v in pcm:
        s += Float64(v) * Float64(v)
    return sqrt(s / Float64(max(len(pcm), 1)))


def peak(pcm: List[Float32]) -> Float64:
    var p = 0.0
    for v in pcm:
        p = max(p, abs(Float64(v)))
    return p


def checksum(pcm: List[Float32]) -> UInt64:
    var h = UInt64(1469598103934665603)
    for v in pcm:
        h = (h ^ UInt64(Int(Float64(v) * 1000000.0) + 2000000)) * 1099511628211
    return h


def main() raises:
    var c = Check()
    var pcm = List[Float32]()

    var quiet = Sfx(RATE)
    quiet.render(pcm, 480)
    c.ok(len(pcm) == 960 and peak(pcm) == 0.0, "no cue, silence (" + String(len(pcm)) + " floats)")

    var cues = [CUE_PICKUP, CUE_HIT, CUE_JUMP, CUE_WIN, CUE_LOSE, CUE_RAIN]
    var names = ["pickup", "hit", "jump", "win", "lose", "rain"]
    for k in range(len(cues)):
        var s = Sfx(RATE)
        s.trigger(cues[k])
        s.render(pcm, 2400)
        var r = rms(pcm)
        var p = peak(pcm)
        c.ok(r > 0.02 and p <= 1.0, names[k] + " makes sound: rms " + String(r) + ", peak " + String(p))
        var after = Int(cue_seconds(cues[k]) * Float64(RATE)) + 100
        s.render(pcm, after)
        c.ok(s.busy() == 0, names[k] + " ends after " + String(cue_seconds(cues[k])) + " s")

    # all voices at once, with the same cue many times over: still limited
    var loud = Sfx(RATE)
    for _ in range(20):
        loud.trigger(CUE_HIT)
    loud.render(pcm, 4800)
    c.ok(peak(pcm) <= 1.0 and loud.busy() <= 8, "20 hits at once stay inside [-1, 1] with at most 8 voices")

    # determinism
    var a = Sfx(RATE)
    var b = Sfx(RATE)
    var pa = List[Float32]()
    var pb = List[Float32]()
    for _ in range(3):
        a.trigger(CUE_PICKUP)
        b.trigger(CUE_PICKUP)
        a.trigger(CUE_HIT)
        b.trigger(CUE_HIT)
        a.render(pa, 3000)
        b.render(pb, 3000)
    c.ok(checksum(pa) == checksum(pb), "the same cues at the same times give the same samples (" + String(checksum(pa)) + ")")
    var d = Sfx(RATE)
    d.trigger(CUE_PICKUP)
    var pd = List[Float32]()
    d.render(pd, 3000)
    c.ok(checksum(pd) != checksum(pa), "different cues give different samples")

    # clips: what the shell registers with the audio scene, one per cue
    var clips_ok = True
    for cue in range(1, CUE_COUNT + 1):
        var clip = cue_clip(cue, RATE)
        var want = (Int(cue_seconds(cue) * Float64(RATE)) + 1) * 2
        var tail = abs(Float64(clip[len(clip) - 1]))
        if len(clip) != want or rms(clip) < 0.02 or peak(clip) > 1.0 or tail > 0.001:
            clips_ok = False
            print("  clip", cue, "length", len(clip), "want", want, "rms", rms(clip), "last sample", tail)
    c.ok(clips_ok and CUE_COUNT == len(cues), "every cue renders to a clip of its own length that is audible and ends in silence")
    c.ok(checksum(cue_clip(CUE_PICKUP, RATE)) == checksum(cue_clip(CUE_PICKUP, RATE)), "a cue's clip is the same every time")
    c.ok(len(cue_clip(99, RATE)) == 2 and peak(cue_clip(99, RATE)) == 0.0, "an unknown cue is one silent frame")

    print("arena_sfx:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("arena_sfx: " + String(c.failed) + " checks failed")
