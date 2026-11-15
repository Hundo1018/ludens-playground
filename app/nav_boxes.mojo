"""Navmesh input shared by the town and the crowd: triangles for a floor and for a box as an obstacle.

A box is outward-facing triangles: its side faces are steep, so the navmesh treats it as an obstacle. The construction is
the same as game/arena.mojo's _nav_box.
"""
from geometry.vec import Real, Vec3


def tri(mut verts: List[Vec3], mut tris: List[Int], a: Vec3, b: Vec3, c: Vec3):
    var n = len(verts)
    verts.append(a)
    verts.append(b)
    verts.append(c)
    tris.append(n)
    tris.append(n + 1)
    tris.append(n + 2)


def nav_box(mut verts: List[Vec3], mut tris: List[Int], c: Vec3, h: Vec3):
    """A box as outward-facing triangles: its side faces are steep, so the navmesh treats it as an obstacle.
    The same construction as game/arena.mojo's _nav_box."""
    var x0 = c[0] - h[0]
    var x1 = c[0] + h[0]
    var y0 = c[1] - h[1]
    var y1 = c[1] + h[1]
    var z0 = c[2] - h[2]
    var z1 = c[2] + h[2]
    tri(verts, tris, Vec3(x0, y0, z0, 0.0), Vec3(x0, y1, z0, 0.0), Vec3(x0, y0, z1, 0.0))
    tri(verts, tris, Vec3(x0, y0, z1, 0.0), Vec3(x0, y1, z0, 0.0), Vec3(x0, y1, z1, 0.0))
    tri(verts, tris, Vec3(x1, y0, z0, 0.0), Vec3(x1, y0, z1, 0.0), Vec3(x1, y1, z0, 0.0))
    tri(verts, tris, Vec3(x1, y0, z1, 0.0), Vec3(x1, y1, z1, 0.0), Vec3(x1, y1, z0, 0.0))
    tri(verts, tris, Vec3(x0, y0, z0, 0.0), Vec3(x1, y0, z0, 0.0), Vec3(x0, y1, z0, 0.0))
    tri(verts, tris, Vec3(x1, y0, z0, 0.0), Vec3(x1, y1, z0, 0.0), Vec3(x0, y1, z0, 0.0))
    tri(verts, tris, Vec3(x0, y0, z1, 0.0), Vec3(x0, y1, z1, 0.0), Vec3(x1, y0, z1, 0.0))
    tri(verts, tris, Vec3(x1, y0, z1, 0.0), Vec3(x0, y1, z1, 0.0), Vec3(x1, y1, z1, 0.0))
    tri(verts, tris, Vec3(x0, y1, z0, 0.0), Vec3(x0, y1, z1, 0.0), Vec3(x1, y1, z0, 0.0))
    tri(verts, tris, Vec3(x1, y1, z0, 0.0), Vec3(x0, y1, z1, 0.0), Vec3(x1, y1, z1, 0.0))
    tri(verts, tris, Vec3(x0, y0, z0, 0.0), Vec3(x1, y0, z0, 0.0), Vec3(x0, y0, z1, 0.0))
    tri(verts, tris, Vec3(x1, y0, z0, 0.0), Vec3(x1, y0, z1, 0.0), Vec3(x0, y0, z1, 0.0))
