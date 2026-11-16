# Engine audit: what the playground writes that the engine should provide (2026-11-16)

The playground is the engine's showcase. Every piece below is code the game carries today; the question for each is
whether ludens-core or ludens-engine already has it (then the game should call it), whether the engine lacks it (then it
moves there with an API a second game can use), or whether it is the game's own (then it stays). Line counts are of the
game's code at `main` after the V chain (#92-#95).

## A. The engine already has it; the game wrote its own

| # | Game code | Lines | Engine API that exists | Action |
|---|---|---|---|---|
| A1 | camp rope: 12 capsules on ball joints (`frontier/world.mojo` ROPE_*, `_build_camp`) | ~41 | `physics.rope.Rope` (XPBD, catenary parity test, `attach` to a scene body, `tie` load path, `break_tension`), stepped on `EmbedWorld.scene` | migrate now |
| A2 | knocked-down figure laid out by hand on CesiumMan's joints (`knock_down`) | ~45 | `gameplay.skin_link.fit_bone_boxes` / `fit_bone_capsules` (bodies fitted from the skin weights) | not migrated: the fit is one box per bone (19 for CesiumMan), the figure is 6 bodies over joint groups, and `knock_down` has no mesh data; the missing API is on ludens-engine #74 |
| A3 | `nav_boxes.mojo` (box obstacles as navmesh triangles) | 39 | the engine's own `game/arena.mojo` has the same `_tri` / `_nav_box`, private | move to a public helper (core `nav`), both use it |
| A4 | `Lcg` in `frontier/world.mojo` | ~18 | `scheduler.rng.Pcg32` | record only: switching changes every generated position, which every check's coordinates depend on |
| A5 | town clip switches jump (`town_motion.mojo`) | - | `procedural.inertialize.Inertializer` (17.64), a standalone struct a matcher can drive; `anim_state`'s `TRANS_INERTIAL` is tied to its own state machine | use it (second round, see Status) |

## B. The engine lacks it; it moves there

| # | Game code | Lines | Owner | Evidence / issue | Action |
|---|---|---|---|---|---|
| B1 | shadow depth pass (`app/shadow_pass.mojo`) | 436 | ludens-engine `app/` | the mesh pass owns the shadow map and its sampling, the pass that fills it is the game's | migrate now |
| B2 | textured primitives: the unit sphere (`app/meshes.mojo`), `_meshify`, the missing-layer fallback and layer table (`app/host.mojo`) | ~86 | ludens-engine `render3d` | `ArenaRenderer` draws material > 0 only for mesh items; a textured box or sphere needs the game to turn it into one | migrate now |
| B3 | AO bake (`app/ao_grid.mojo` CPU, `app/rt_gpu.mojo` GPU trace) | 277 | ludens-engine `app/` | `MeshPass.set_ao` takes a grid, nothing makes one | issue |
| B4 | asset formats and pose palettes (`app/frontier_assets.mojo`: `.lcharacter`, `.ltexture`, `locals_at`, `strip_root_xz`, `pose_palette_clip`) and the converters (`scripts/convert_glb.py`, `convert_texture.py`, `extract_glb_texture.py`, `retarget.py`, `convert_amc.py`, `convert_wav.py`, `motion_fk.py`, `convert_font.py`) | 230 Mojo + 2029 Python | ludens-engine | the engine's page loader (`loadAsset`) checks hashes but reads no format | issue (large, mechanical) |
| B5 | crowd pose table and tiers (`app/host.mojo`) | ~57 | ludens-engine render | ludens-engine #71 | issue exists |
| B6 | pose-level two-bone IK, pelvis drop (`app/foot_ik.mojo`) | 192 | ludens-core `procedural.ik` | ludens-engine #76 | migrate the pose step now (`two_bone_pose`) |
| B7 | ragdoll in an `EmbedWorld`, skinned to its bodies (`app/rag_skin.mojo`) | 99 | ludens-core `embed` / `gameplay.ragdoll` | ludens-engine #74 | issue exists |
| B8 | fractured world as a net state: quantised poses, the scratch-world fixed point (`app/net_fracture.mojo` FractureSim) | ~180 | ludens-core `embed` | ludens-engine #75 | issue exists |
| B9 | motion matching on a skinned character: trajectory features, the per-agent controller (`app/motion_match.mojo`, `app/town_motion.mojo`) | 420 | ludens-core `procedural.anim_graph` | `MotionDB` stores and searches rows only | issue |
| B10 | visual-test modes: colour-only items magenta, sky mask (`flatmark`, `skymark` in `app/host.mojo`) | ~16 | ludens-engine render | the renderer is where "untextured" and "sky" are known | issue |
| B11 | HUD lines from the host; a dynamic mesh for cloth (the banner drawn as boxes) | - | ludens-engine | #72, #73 | issues exist |

## C. The game's own (stays)

The town's behaviour-tree host and perception wiring (`app/town.mojo`), the crowd's ECS simulation and its worker
(`app/crowd.mojo`, `app/crowd_host.mojo`), the netcode harnesses (`app/net_frontier.mojo`, `app/net_predict.mojo`,
`app/server_host.mojo`), the Frontier's rules (zones, goals, the quarry, pendulum and camp layout, `frontier/world.mojo`),
the HUD text (`frontier/hud.mojo`) and the page glue (`app/host.mojo`, `page/app.js`). The visual check
(`scripts/visual_check.py`) is the game's test.

## Totals

Game Mojo that belongs in the engine: about 2,118 lines (A1-A3 125, B1-B10 1,993), plus 2,029 lines of Python asset
pipeline. This round migrated B1, B2, A1, A3 and B6; A2 did not fit the engine's API; the rest has an issue.

| Item | PR | Status | Game lines (removed / added) | Measured |
|---|---|---|---|---|
| B1 shadow pass | ludens-engine#78, #96 | done | 436 / 0 | 19 native suites (four shadow suites build against the engine's pass), 15 page checks |
| B2 textured primitives | ludens-engine#78, #96 | done | 97 / 19 (`app/meshes.mojo`, `_meshify`, cube / sphere registration, per-layer flags) | visual check: sky_grad 10.73, fog 0.053, flat 0, wall_layers 4 as before; camp floating_cols 0.4 % -> 1.1 % (bound 2 %), cause not traced |
| A1 rope | ludens-core `physics.rope` (existing), #97 | done | 38 / 44 | the rope's physics is core's now; the game gains the per-segment draw and the step call, so its lines do not shrink. Rope length over rest 1015-1029 permille -> 1000-1002, end-ball swing 2251 -> 3148 mm (two runs each) |
| A3 nav box helper | ludens-core#128, ludens-engine#83, #97 | done | playground 45 / 6 (`app/nav_boxes.mojo` deleted); engine 37 / 5 | navmeshes unchanged and pinned in tests: town 320 polygons / 4389.0 m2, crowd 141 / 1497.25 m2 (`tests/navmesh_native.mojo`), engine arena 116 / 1436.5 m2 (`tests/arena.mojo`). Found on the way: both private copies wound the box sides inward |
| B6 two_bone_pose | ludens-core#128, #97 | done | 68 / 42 (`_rot_about`, `_turn`, `_in_subtree`) | worst foot error on 20 deg over 44 frames 0.137 mm -> 0.00011 mm; CesiumMan's joint matrices are rigid (column norms within 3.6e-7 of 1), so a `Pose` holds them |
| A2 fitted ragdoll bodies | ludens-core#131 (`fit_group_boxes`) | not used | 0 | the API now fits one box per joint group, but the fitted figure sits further from the mesh than the hand layout (pelvis centre y 0.744 vs 0.65, head 1.322 vs 1.22, torso x -0.23 m), so the game keeps its layout; recorded on ludens-engine #74 |
| A4 RNG | - | record only | 0 | |
| B9 motion matching | ludens-core#129 (`procedural.motion_match`, 17.92), playground #99 | done | 291 / 56 | `tests/mm_parity_native.mojo` against the game's old matcher: switch-sequence hash 677951162, 757 switches, M6 992661, the same |
| A5 inertial blend | ludens-core 17.64 (existing), playground #100 | done (the API existed, unused) | 2 / 172 (`app/town_blend.mojo`, new behaviour) | `tests/town_blend_native.mojo`: largest per-tick joint step at a switch 476.7 -> 137.9 mm, at a loop wrap 310.2 -> 94.6 mm (bound: 2 x the ordinary p95, 146 mm); switch decisions unchanged. Known gap: a one-frame pop when the guard is knocked down mid-blend |
| B10 visual-test marks | ludens-engine#84, playground #101 | done | B10 + B3 together 300 / 32 | visual check: sky_grad 10.73, fog 0.05311, horizon row 34, flat 0, wall_layers 4, as before (the layer count now skips the sky, which the renderer recolours after it) |
| B3 AO bake | ludens-engine#85, playground #101 | done | (with B10; `app/ao_grid.mojo` 56 and `app/rt_gpu.mojo` 221 deleted) | `tests/ao_native.mojo`: grid hash 661581298, 1,444 open cells, minimum 0.300, the same; `rt_native` passes against the engine's tracer |
| B11 HUD lines | playground #101 (no engine change) | done | (in the B10 / B3 count) | the AO line comes from `FrontierMode.hud_extra`, set by the host; `GameMode.hud` already returned its `DrawList` |
| B11 banner mesh | ludens-engine#88 (`add_dynamic` / `update_dynamic`), playground #102 | done | 7 / 51 | one mesh instead of 96 cell boxes; camp_check unchanged (rope 1000-1002 permille, banner corner 3433 mm, pinned edge 0 um) |
| B5 crowd palettes | ludens-engine#87 (`PaletteTable`), #86 (`RenderCaps`), playground #103 | done | 12 / 24 | at 2000 members: 3924 -> 1207 palette matrices, tiers 40 / 120 / 1840, 0 dropped |
| B8 fracture net state | ludens-core#130 (`quantize_rotation`, 17.93), playground #103 | done | 26 / 6 (the scratch world) | 73 fracture events; snapshot bytes 45158 / 2048 and 46085 / 2014, the same. Save and load of a fractured world: ludens-core#132 |
| B7 ragdoll in an `EmbedWorld` | ludens-core#131 (`embed.ragdoll`, 17.94), playground (this PR) | done | 72 / 39 | `rag_skin_native` prints the same numbers to the last digit (pelvis joint to body 0.027036665 m standing, pelvis joint y 0.10121553 m after 2 s); ragdoll_check passes |
| B4 asset formats and converters | ludens-engine #12 (comment) | open | 0 | the largest item (230 Mojo + 2029 Python); next round |

Removed from game code this round: 684 lines in the playground (B1 436, B2 97, A1 38, A3 45, B6 68) and 37 in the
engine's `game/arena.mojo`, against 111 lines added in the playground (most of it the rope's draw and the pose
conversion). New engine API: `procedural/ik_pose.mojo` and `nav/nav_input.mojo` in ludens-core (#128), the unit sphere,
textured-primitive push and layer fallback in ludens-engine (#78).

Second round (B9, A5, B10, B3, B11, B5, B8, B7): 710 lines removed from the playground, 380 added, 172 of which are
A5's new blend. New engine API: `procedural.motion_match` (#129), `quantize_rotation` and fractured-world save / load
(#130, #132), `embed.ragdoll` and `fit_group_boxes` (#131) in ludens-core; debug views (#84), `ao_bake` (#85),
`RenderCaps` (#86), `PaletteTable` (#87) and dynamic meshes (#88) in ludens-engine. B4 is what remains.
