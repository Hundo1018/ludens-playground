"""What the HUD shows for the Frontier world, as a `DrawList` in pixels (origin top-left): where the player is, what the
streaming and the culling are doing, and what the frame cost. The numbers are `Frontier.stat` values, the same ones the
page publishes for the automated check. No device here."""
from frontier.world import (
    Frontier, zone_name, STAT_CELLS_LOADED, STAT_CELLS_TOTAL, STAT_BODIES_LIVE, STAT_BODIES_TOTAL, STAT_DRAWN, STAT_CULLED,
    STAT_LOADS, STAT_UNLOADS, STAT_ZONE,
)
from game.hud_layout import dot_scale, PANEL, WHITE, GOLD, GREEN, RED
from ui.draw import DrawList
from ui.font import draw_text, text_width
from ui.geom import Rect


def build_frontier_hud(f: Frontier, width: Float32, height: Float32, frame_ms: Float32) raises -> DrawList:
    """`frame_ms` is the CPU time the page measured around the previous frame (0 when it has not said)."""
    var dl = DrawList()
    var s = dot_scale(height)
    var pad = 4.0 * s
    var lines = List[String]()
    lines.append("ZONE " + zone_name(f.stat(STAT_ZONE)))
    lines.append("CELLS " + String(f.stat(STAT_CELLS_LOADED)) + "/" + String(f.stat(STAT_CELLS_TOTAL)))
    lines.append("BODIES " + String(f.stat(STAT_BODIES_LIVE)) + "/" + String(f.stat(STAT_BODIES_TOTAL)))
    lines.append("DRAWN " + String(f.stat(STAT_DRAWN)) + " CULLED " + String(f.stat(STAT_CULLED)))
    lines.append("LOADS " + String(f.stat(STAT_LOADS)) + " UNLOADS " + String(f.stat(STAT_UNLOADS)))
    var tenths = Int(frame_ms * 10.0)
    lines.append("FRAME " + String(tenths // 10) + "." + String(tenths % 10) + " MS")
    var pw = Float32(0)
    for l in lines:
        pw = max(pw, text_width(l, s))
    pw += 4.0 * s
    dl.fill(Rect(pad, pad, pw, Float32(len(lines)) * 9.0 * s + 3.0 * s), PANEL)
    for i in range(len(lines)):
        var c = WHITE
        if i == 0:
            c = GOLD
        elif i == len(lines) - 1:
            c = GREEN if frame_ms < 16.7 else RED
        draw_text(dl, pad + 2 * s, pad + 2 * s + Float32(i) * 9.0 * s, lines[i], s, c)
    var hint = "WASD MOVE   SPACE JUMP   DRAG MOUSE LOOK   R BACK TO THE HUB"
    var hw = text_width(hint, s) + 4 * s
    dl.fill(Rect(width * 0.5 - hw * 0.5, height - 12 * s, hw, 9 * s), PANEL)
    draw_text(dl, width * 0.5 - text_width(hint, s) * 0.5, height - 11 * s, hint, s, WHITE)
    return dl^
