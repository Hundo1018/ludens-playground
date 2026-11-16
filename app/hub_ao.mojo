"""W10: the hub floor's ambient-occlusion term. The grid is baked by ludens-engine's app/ao_bake.mojo (ludens-engine#79)
over the hub's pillars; this module only says which boxes and which floor square."""
from geometry.aabb import AABB
from frontier.world import Frontier

comptime AO_N = 40  # W10: the hub floor's AO grid, cells per side
comptime AO_X0 = Float32(-20.0)  # its west and south edge, metres
comptime AO_SIZE = Float32(40.0)  # its extent, metres


def hub_ao_boxes(f: Frontier) -> List[AABB[3]]:
    """The hub's static boxes (its pillars) as the AO bake's occluders."""
    var out = List[AABB[3]]()
    for b in f.static_boxes(-20.0, -20.0, 20.0, 20.0, 1.0):
        out.append(AABB[3](b.c - b.h, b.c + b.h))
    return out^
