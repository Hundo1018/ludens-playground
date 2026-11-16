# Engine audit: what the playground writes that the engine should provide (2026-11-16)

The playground is the engine's showcase. Every piece below is code the game carries today; the question for each is
whether ludens-core or ludens-engine already has it (then the game should call it), whether the engine lacks it (then it
moves there with an API a second game can use), or whether it is the game's own (then it stays). Line counts are of the
game's code at `main` after the V chain (#92-#95).

## A. The engine already has it; the game wrote its own

| # | Game code | Lines | Engine API that exists | Action |
|---|---|---|---|---|
| A1 | camp rope: 12 capsules on ball joints (`frontier/world.mojo` ROPE_*, `_build_camp`) | ~41 | `physics.rope.Rope` (XPBD, catenary parity test, `attach` to a scene body, `tie` load path, `break_tension`), stepped on `EmbedWorld.scene` | migrate now |
| A2 | knocked-down figure laid out by hand on CesiumMan's joints (`knock_down`) | ~45 | `gameplay.skin_link.fit_bone_boxes` / `fit_bone_capsules` (bodies fitted from the skin weights) | migrate now |
| A3 | `nav_boxes.mojo` (box obstacles as navmesh triangles) | 39 | the engine's own `game/arena.mojo` has the same `_tri` / `_nav_box`, private | move to a public helper (core `nav`), both use it |
| A4 | `Lcg` in `frontier/world.mojo` | ~18 | `scheduler.rng.Pcg32` | record only: switching changes every generated position, which every check's coordinates depend on |
| A5 | town clip switches jump (`town_motion.mojo`) | - | `procedural.anim_state` inertial transitions (`TRANS_INERTIAL`) | issue: blend the motion-matching switch |

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
pipeline. This round migrates A1, A2, A3, B1, B2 and the pose step of B6 (about 750 lines); the rest has an issue. The
status column below is updated as each PR lands.

| Item | PR | Status |
|---|---|---|
| A1 rope | | |
| A2 fitted ragdoll bodies | | |
| A3 nav box helper | | |
| B1 shadow pass | | |
| B2 textured primitives | | |
| B6 two_bone_pose | | |
