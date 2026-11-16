# Audit B3: the hub floor's ambient-occlusion grid (app/host.mojo's W10 term: the pillars of the hub, AO_N x AO_N cells).
# The grid (ludens-engine's app/ao_bake.mojo) is pinned to what the playground's own app/ao_grid.mojo produced before the bake moved to
# ludens-engine (app/ao_bake.mojo): a hash of every cell's bits, the open-cell count and the minimum.
from harness.runner import Suite
from frontier.world import Frontier
from app.hub_ao import hub_ao_boxes, AO_N, AO_X0, AO_SIZE
from app.ao_bake import ao_bake

comptime WANT_HASH = 661581298
comptime WANT_OPEN = 1444
comptime WANT_MIN_PERMILLE = 300


def main() raises:
    var s = Suite("ao_native")
    var f = Frontier()
    var cells = ao_bake(hub_ao_boxes(f), AO_N, AO_X0, AO_X0, AO_SIZE)
    var h = 0
    var open = 0
    var lo = Float32(2.0)
    for c in cells:
        h = (h * 31 + Int(c * Float32(1e6))) % 1000000007
        if c == Float32(1.0):
            open += 1
        lo = min(lo, c)
    var lo_pm = Int(lo * Float32(1000.0) + Float32(0.5))
    print("AO grid", len(cells), "cells: hash", h, "open", open, "min", lo_pm, "permille")
    s.check(len(cells) == AO_N * AO_N, "AO_N x AO_N cells")
    s.check(h == WANT_HASH, "cell hash " + String(h) + " == " + String(WANT_HASH))
    s.check(open == WANT_OPEN and lo_pm == WANT_MIN_PERMILLE, "open cells " + String(open) + ", min " + String(lo_pm) + " permille")
    s.finish()
