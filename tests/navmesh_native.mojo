# Audit A3: the town's and the crowd's navmeshes, baked from boxes (app/town.mojo town_mesh, app/crowd.mojo floor_mesh).
# Their polygon counts and walkable areas are pinned to the values measured with the playground's own nav_boxes.mojo
# (before ludens-core's nav.nav_input replaced it), so a change to how the bake input is built shows up here.
from harness.runner import Suite
from geometry.vec import Real
from frontier.world import Frontier
from app.town import town_mesh
from app.crowd import floor_mesh

comptime TOWN_POLYS = 320
comptime TOWN_AREA_CM2 = 43890000
comptime CROWD_POLYS = 141
comptime CROWD_AREA_CM2 = 14972500


def main() raises:
    var s = Suite("navmesh_native")
    var f = Frontier()
    var town = town_mesh(f.static_boxes(96.0, 96.0, 160.0, 160.0, 1.0))
    var crowd = floor_mesh(f.static_boxes(-20.0, -20.0, 20.0, 20.0, 1.0))
    var ta = Int(town.walkable_area() * Real(10000.0) + Real(0.5))
    var ca = Int(crowd.walkable_area() * Real(10000.0) + Real(0.5))
    print("town navmesh:", town.poly_count(), "polygons,", ta, "cm2; crowd navmesh:", crowd.poly_count(), "polygons,", ca, "cm2")
    s.check(town.poly_count() == TOWN_POLYS, "town polygons " + String(town.poly_count()) + " == " + String(TOWN_POLYS))
    s.check(ta == TOWN_AREA_CM2, "town walkable area " + String(ta) + " cm2 == " + String(TOWN_AREA_CM2))
    s.check(crowd.poly_count() == CROWD_POLYS, "crowd polygons " + String(crowd.poly_count()) + " == " + String(CROWD_POLYS))
    s.check(ca == CROWD_AREA_CM2, "crowd walkable area " + String(ca) + " cm2 == " + String(CROWD_AREA_CM2))
    s.finish()
