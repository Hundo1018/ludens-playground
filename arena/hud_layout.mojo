"""What the HUD shows for a game state, as a `DrawList` of rectangles in pixels (origin top-left).

Score, spheres, time and a health bar in the corner; a banner when the game is won, lost or paused; the controls along the
bottom. No device here: `app/hud.mojo` turns the list into triangles."""
from arena.arena import Arena, STATUS_PLAYING, STATUS_WON, STATUS_LOST, N_ITEMS, MAX_HEALTH
from ui.draw import Color, DrawList
from ui.font import draw_text, text_width
from ui.geom import Rect

comptime PANEL = Color(0.05, 0.06, 0.1, 0.9)
comptime WHITE = Color(1.0, 1.0, 1.0, 1.0)
comptime GOLD = Color(1.0, 0.82, 0.15, 1.0)
comptime RED = Color(0.9, 0.2, 0.25, 1.0)
comptime GREEN = Color(0.35, 0.85, 0.45, 1.0)
comptime BAR_BACK = Color(0.25, 0.1, 0.12, 1.0)


def _centered(mut dl: DrawList, cx: Float32, y: Float32, s: String, scale: Float32, c: Color):
    draw_text(dl, cx - text_width(s, scale) * 0.5, y, s, scale, c)


def dot_scale(height: Float32) -> Float32:
    """A whole number of pixels per dot, about 1/200 of the window height, at least 2."""
    var s = Float32(Int(height / 200.0))
    return max(s, 2.0)


def build_hud(a: Arena, width: Float32, height: Float32) raises -> DrawList:
    var dl = DrawList()
    var s = dot_scale(height)
    var pad = 4.0 * s

    # corner panel: score, spheres, time, health
    var pw = 44.0 * s
    var ph = 38.0 * s
    dl.fill(Rect(pad, pad, pw, ph), PANEL)
    draw_text(dl, pad + 2 * s, pad + 2 * s, "SCORE " + String(a.score), s, WHITE)
    draw_text(dl, pad + 2 * s, pad + 11 * s, "SPHERES " + String(a.collected()) + "/" + String(N_ITEMS), s, GOLD)
    var left = a.seconds_left()
    draw_text(dl, pad + 2 * s, pad + 20 * s, "TIME " + String(left), s, WHITE if left > 10 else RED)
    var bar_w = pw - 4.0 * s
    dl.fill(Rect(pad + 2 * s, pad + 29 * s, bar_w, 6 * s), BAR_BACK)
    var frac = Float32(max(a.health(), 0)) / Float32(MAX_HEALTH)
    if frac > 0:
        dl.fill(Rect(pad + 2 * s, pad + 29 * s, bar_w * frac, 6 * s), GREEN if frac > 0.5 else RED)

    # the controls along the bottom
    var hint = "WASD MOVE   SPACE JUMP   DRAG MOUSE LOOK   P PAUSE   R RESTART"
    var hw = text_width(hint, s) + 4 * s
    dl.fill(Rect(width * 0.5 - hw * 0.5, height - 12 * s, hw, 9 * s), PANEL)
    _centered(dl, width * 0.5, height - 11 * s, hint, s, WHITE)

    # a banner over the middle
    var title = String()
    var sub = String()
    var tc = WHITE
    if a.status() == STATUS_WON:
        title = "YOU WIN"
        sub = "SCORE " + String(a.score) + "   PRESS R TO PLAY AGAIN"
        tc = GOLD
    elif a.status() == STATUS_LOST:
        title = "GAME OVER"
        sub = ("TIME IS UP" if a.health() > 0 else "CAUGHT") + "   PRESS R TO TRY AGAIN"
        tc = RED
    elif a.paused():
        title = "PAUSED"
        sub = "PRESS P TO CONTINUE"
    if title.byte_length() > 0:
        var bs = s * 3.0
        var bw = max(text_width(title, bs), text_width(sub, s)) + 16 * s
        var bh = 7 * bs + 7 * s + 14 * s
        var bx = width * 0.5 - bw * 0.5
        var by = height * 0.5 - bh * 0.5
        dl.fill(Rect(bx, by, bw, bh), PANEL)
        _centered(dl, width * 0.5, by + 5 * s, title, bs, tc)
        _centered(dl, width * 0.5, by + 5 * s + 7 * bs + 4 * s, sub, s, WHITE)
    return dl^
