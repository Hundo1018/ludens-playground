# Plan: Ludens Frontier (current)

This is the governing plan. It supersedes `docs/frontier_plan.md`, which predates the repository split, the seam and the
asset policy. Where the two disagree, this file wins; where this file is silent, the user's latest instructions win.

## Precedence

1. The user's most recent instructions.
2. This file.
3. `docs/asset-policy.md` (art, animation, sound and fonts: openly licensed material only; code is ours).
4. `docs/frontier_plan.md` (history; its card-level steps are not to be followed where they conflict with 1 to 3).

## Repository split

- **ludens-engine** (MIT): the game seam (`game/mode.mojo`, `GameMode`), the arena, the renderer, the host. Changes here
  are *reusable capability*: a new host ability, a renderer pass, a loader. Each is an engine PR, then a pin bump here.
- **ludens-playground** (this repo, MIT): the Frontier game, its content, its manifest, its page, its checks. Game rules
  and content go here, not in the engine.
- **wgpu-mojo, ludens-core, miniaudio-mojo** (Apache-2.0 / MIT): pinned in `deps.lock`.

## Current state

- Done: the seam (engine #58); the external entry (playground #2); the Frontier logic, HUD and exports moved here
  (playground #3, merged). Native and wasm agree (`scripts/check_parity.sh`).
- Touch: the engine's virtual pad (`vpad.ts`, `vpad_view.ts`) is mounted on the page; its stick and buttons reach the
  host as W A S D, Space and R (`scripts/touch_check.mjs`, three runs in CI).
- Page: the Frontier page is here (`page/index.html`, `page/app.js`, not the `index.html` / `app.ts` the earlier draft named).
  Pages deploys it from main (`pages build and deployment` run 24 for `ae83a36`: success). CI run 120 for `ae83a36` is the
  check that gates the rest.
- Ordering gap: engine #59 (removes the engine's `?frontier` page) merged on 2026-11-14 at 06:46 UTC. The first playground
  page build was on 2026-11-15 at 07:31 UTC. The rule "merge #59 only after the page exists here" was not followed; for
  about a day the engine served no Frontier page. This cannot be undone and is recorded here.
- Step status (evidence): 1 engine seam is generic (`app/main.mojo` and `game/mode.mojo` use `M: GameMode`; playground
  `frontier` runs through it). 4 asset pipeline: `python3 scripts/fetch_assets.py --check` reports 19 manifest entries
  consistent with credits (run in CI). 5, 7, 8 and stage 2: not started.

## Steps, in order

1. **Host for an outside game (engine).** The engine's `app/main.mojo` owns GPU boot, surface, input, capture and audio
   and hard-codes its modes. Spike first: a playground entry that draws one `FrontierMode` frame through the engine's
   renderer in headless Chrome, with the engine's `shell/web` files unmodified. Then extract the reusable part into an
   importable engine module generic over `M: GameMode`; `main.mojo` keeps only thin exports. Engine PR, pin bump.
2. **Frontier page (playground).** `index.html` and a small `app.ts` (its own file, importing the engine's `shell/web`
   runtime at the pinned rev) that boots the playground module, feeds keys and pad input, and publishes the stats.
   Ported check: `scripts/frontier_check.mjs` (from the engine's #59 removal) runs against this page.
3. **Pages.** Deploy the playground to GitHub Pages. Only then merge engine #59.
4. **Asset pipeline (playground + reusable loader in engine).** `assets/manifest.toml` (url, sha256, licence, author),
   `scripts/fetch_assets.py`, converters for textures, models, skeletons, motion, sound and fonts, and `assets/CREDITS.md`
   generated from the manifest. Sources and licences: `docs/asset-policy.md`. Loader in the engine, content here.
5. **Rendering (engine renderer pass, playground content).** Indexed mesh pass, then skinned mesh pass (GPU skinning),
   then textures and triplanar ground. Each is an engine PR with a native parity check against `geometry/skinning`.
6. **Characters and motion (playground).** Characters and motion from the manifest (CesiumMan, Fox under CC-BY 4.0;
   CMU motion capture; Quaternius optionally, manual). `MotionDB` over the converted clips. No hand-made skeletons.
7. **Crowd (3b).** Entities through `ecs.World`, flow field for movement, instanced skinned draws, HUD switch between
   backends. Count from a measured budget, not a promise.
8. **Range networking (5).** Authoritative server in a second module, `SnapshotServer` / `SnapshotClient`, `SimLink`
   latency controls, lag-compensated hits. Reuses the engine's `gameplay/netcode`.

## Texture measurement (step 5, hub frame, `?offscreen` on and `?offscreen&notex` off)

`scripts/texture_compare.py` on the two captures: ground crop (500,380)-(940,470) std-dev 10.25 with the rock texture, 10.50 without (mean -0.65): the texture lowers the floor's contrast. 3.32% of the frame differs by more than 3 luminance levels, spread over the floor and the characters. The wall crop is identical on and off because `?notex` switches off only the ground and Fox textures; the concrete wall is textured in both runs, so this comparison does not measure walls. Next: a wall switch, then the triplanar scale sweep in the engine.

Source contrast (luminance std-dev of the 1024 px JPEG resized to 256 px): rock 29.9, concrete wall 2.6. The concrete source is almost flat, so the flat walls come from the asset. The rock source has high contrast, so the low rendered ground contrast (10.25) comes from the render path (triplanar scale, lighting, mips). Next: pick a higher-contrast CC0 wall texture (manifest change); sweep the triplanar scale in the engine for the ground.

## Wall texture (step 5)

`concrete_wall_003` replaces `concrete_wall_008` (source std-dev 27.8, against 2.6). The hub frame does not change: 0 of 518,400 pixels differ between the old and new captures (`scripts/texture_compare.py`). Cause: a scene box with `mesh_id = -1` takes the primitive path in the engine's `app/render3d.mojo`, which carries no texture and ignores `material` and `layer`. The host sets `material = 2` on walls but gives them no mesh. Fix: register a unit cube with `renderer.meshes.add_static` and set the wall items' `mesh_id` to it (the mesh pass samples triplanar on layer 1). Then re-measure.

Result after the mesh change: walls are drawn on the mesh pass with layer 1 (`concrete_wall_003`), and the pillars show the concrete texture at the same size. 9.18% of the hub frame differs from the untextured-mesh capture (`scripts/texture_compare.py`); the pillar crop's mean moves by 21 to 40 luminance levels. The ground crop is unchanged (10.25 vs 10.14). Next: the triplanar scale for the walls (0.25 per metre) and the ground's contrast.

## Ground tiles on the mesh pass (step 5)

Ground tiles (half height at most 0.1 m) now draw on the mesh pass with layer 2 (the rock). Before, they took the primitive path, which ignores the texture, so the rock never showed. On the hub frame with `?notown`, the floor now shows the rock texture (checked on the captured frame). `?notex` A/B: 74% of pixels differ, and the textured floor is about 23 levels darker on average. Floor std-dev is not a usable measure here: the untextured floor scores 13.97 because its crop picks up other content.

## Audits (plan status)

- Step 6: `host_check` passes M6 on the page: motion matching returns the same 20 indices as native (hash 992661).
- Step 8: implemented in part. `app/net_frontier.mojo` has `SnapshotServer` over lossy `SimLink`s, lag compensation through `TargetRing` and `shot_hits`. `host_check` passes the netcode session on the page (equal to native). Not yet checked: the prediction-error bound and the three-colour draw named in this plan.
- Stage 2 physics: not a step of this plan. `docs/PLAN.md` has no physics step; it lives in `docs/frontier_plan.md`, which this plan supersedes.
- Step 7: `SYNC=1` fails in this container; `GPU_SYNC=1` returns frame counts that grow about fivefold per sample, so the timing is environment-limited. The 3b-0 `ecs.World` vs OOP probe is still to run, natively.

## Probe 3b-0: crowd step per ECS backend against an object list (step 7)

`benchmarks/crowd_3b0.mojo`, native, 30 samples per row, median ms per step: N = 10,000: sparse-set 0.38, naive 0.54, OOP list 0.42. N = 50,000: sparse-set 1.90, naive 2.41, OOP 2.28. N = 100,000: sparse-set 3.22, naive 2.46, OOP 2.94. The OOP list does not run the flow field, so it is a floor for the object layout, not the same workload. At 1e5 the naive backend is faster than sparse-set, the reverse of the smaller counts; the sparse-set cost grows faster. Native only: a browser step at 1e5 is measured on the page (`crowd_bench.mjs`), where the GPU readback is the limit, not this step.
## Triplanar scale re-run on the textured floor (step 5)

Run on `main` (`d8a186c`, ground tiles on the mesh pass), with `?offscreen&notown` so the floor crop holds no residents: 0.125 gives std-dev 12.96, 0.25 (pinned) 12.69, 0.5 12.52, 1.0 12.73. The spread is under half a level, so this metric does not separate the scales. Visual choice (floor crops from the four captures): at 0.125 the pebbles are oversized and blurry up close; at 0.25 they read as pebbles at a believable size; at 0.5 and 1.0 the texture collapses into fine grit. The scale stays at 0.25. Step 5's texture work is done with this choice. This replaces the withdrawn result in PR #37.

## Step 8 audit (what exists, by grep)

- Present: `SnapshotServer` over lossy `SimLink`s and lag-compensated hits (`app/net_frontier.mojo`, `shot_hits`, `TargetRing`); the page's netcode session equals native (`host_check`).
- Present in ludens-core only: a rollback and prediction seam (`gameplay/netcode.mojo`, `RollbackPeer`, ROADMAP 17.16). The playground does not use it for a measured prediction error.
- Absent from the playground: a measured prediction-error bound (the plan's 150 ms check) and the three-colour draw. Neither appears in `app/`, `page/` or `scripts/`.

## Step 5: shadow probe, native (depth through a comparison sampler)

`tests/shadow_probe_native.mojo`: a Depth32Float texture written by a render pass cleared to 0.5, sampled once in a compute shader through a LessEqual comparison sampler at references 0.25 and 0.75. Result: 1.0 and 0.0 (2 of 2 checks). The depth-plus-comparison binding path works through wgpu-mojo natively. The shadow pass itself (light camera, depth pass, PCF in the mesh fragment shader) is not built yet; this is the riskiest unknown, now resolved.
## Step 8: netcode latency sweep, 0 to 150 ms (native)

`benchmarks/net_latency_150ms.mojo`: one-way latency 0 to 9 ticks (0 to 150 ms at 60 Hz), 10 % loss, jitter 3, three seeds per row. Every latency converged (3 of 3) and matched the reference hash (3 of 3). Mean frames to finish 120 ticks: 126 at 0 ms, 145 at 116 ms, 148 at 150 ms. This measures convergence and state equality, not the prediction error that the plan's bound refers to. That bound is still unmeasured.

## Step 8: display error of a snapshot client, 0 to 150 ms (native)

Second table of `benchmarks/net_latency_150ms.mojo`, 10 % loss, jitter 3, three seeds per row. Lag is the server tick minus the tick client 0 shows. Mean lag: 1.7 ticks at 0 ms, 8.0 at 50 ms, 10.7 at 150 ms; the maximum is 15 ticks (about 250 ms) at 100, 133 and 150 ms. Target displacement between the shown and the server tick: 1.25 to 2.5 m (mean 1.25 to 2.1 m). This is the display error of a snapshot client, not a prediction error: SnapshotClient does not predict, and RollbackPeer (the prediction seam in ludens-core) is not used. The prediction-error bound is still unmeasured.
## Step 8: the three-colour draw, the spec as written

The three-colour draw is specified in `docs/frontier_plan.md` line 206: server truth, predicted, and no prediction (the snapshot view). Line 204 calls for two clients, one predicting from the player's input and one interpolating only. Line 430 gives the bound test. `SnapshotClient` has no predicted state, so the predicted client is a separate local sim in `app/net_predict.mojo`. The three-colour draw on the page is not built yet.
## Step 5: shadow depth pass, native

`app/shadow_pass.mojo` draws the mesh items from an orthographic light into a Depth32Float texture, with no fragment stage. `tests/shadow_pass_native.mojo`: a unit box's centre reads depth 0.25 (its near face) and an open corner reads the cleared 1.0 (2 of 2 checks). Found and fixed on the way: `Vec3` takes four components (`Vec3(x, y, z, 0)`); three gave a run-time segfault. Not yet: sampling the map in the mesh fragment shader with PCF, and the hub-frame shadowed-pixel fraction.

## Status table (step → deliverable → evidence)

| Step | Literal deliverable (docs/PLAN.md) | Evidence | Status |
|---|---|---|---|
| 1 Host for an outside game | engine seam generic over `GameMode`; playground runs through it | engine `app/main.mojo`, `game/mode.mojo`; #33 page | done |
| 2 Frontier page | page in this repo; the engine's `frontier_check.mjs` runs against it | `page/index.html`, `page/app.js` (Decisions: `app.js`, not `app.ts`); `host_check`, `touch_check`, `frontier_check` in `pages.yml` (PR #56 run 190 success; ported script passes against the page: streaming, zones, unloading) | done |
| 3 Pages | deploy from main | run 24/120 for `ae83a36`; PR #34 merged | done |
| 4 Asset pipeline | manifest, fetch, converters, credits | `fetch_assets.py --check`: 19 entries OK | done |
| 5 Rendering | indexed mesh, skinned mesh, textures, triplanar ground, parity; shadows on the mesh pass and the characters (user feedback #5) | engine #64–#68 (#67 static shadow map, #68 skinned receiving); B3 parity on lavapipe; #36, #38 page; #48 static shadow pass; #53 skinned casting; pinned to engine `627e63e`; `mesh_shadow_native` 2/2, `shadow_flip_native` 4/4, `shadow_skin_native` 2/2 (skinned and static depth maps agree at 8 texels); receiving: crowd bodies darken 11.1 with receiving vs 2.0 without | done (see Step 5 final) |
| 6 Characters and motion | CesiumMan, Fox, CMU motion, MotionDB | `host_check` M6: motion matching equals native (hash 992661) | done |
| 7 Crowd | crowd in ecs.World, instanced skinned draws, HUD backend switch | #40 native 3b-0 numbers; `crowd_native` 5/5; palette guard #51 (refuses counts over 4096 matrices; drops overflow); browser budget on the pinned build with casting, SwiftShader, captured frame incl. readback: 0 extra 322.60 ms, 100 extra 819.80 ms, 180 extra 1178.60 ms, 200 extra (notown) 1107.90 ms (Step 7 re-run) | done: count from a measured budget, as the literal text asks |
| 8 Range networking | server module, SnapshotServer/Client, SimLink, lag-compensated hits, latency controls, three-colour view | `net_frontier.mojo`, `frontier_net_native` 11/11; #41 latency sweep 0 to 150 ms; #43 display error; #46 page sliders; #47 predicted client and three-colour view (`net_predict_native` 10/10 at line 430's link: per-tick predicted error 0 mm, 0 mm after idle, world hash equal at T, 9-tick shot hit and miss; `host_check` netview asserts the same); #52, #55 stress test beyond line 430 (see below) | done |

Step 8: the line 430 assertions are met in the independent scenario (`FrontierSim`; the predicted error is zero by construction, because each player moves from its own input alone). The three colours come from `docs/frontier_plan.md` lines 204 to 206. The 9-tick lag-compensated hit is tested in `tests/net_predict_native.mojo`. The coupled results are a stress test beyond line 430 (see below).
Step 5 shadows are not in the literal step 5 text; they come from user feedback #5 and are tracked as their own item.

## Done means

Each step: its PR merged, its check green locally from a fresh clone, and the Pages build serving the change.

## Decisions

- Visual check per stage: `python3 scripts/stage_shots.py <chrome> <url> <out-dir>` captures named scenes of the page through its offscreen render path (`scripts/capture_scene.mjs`) and writes one labelled `sheet.png` for viewing. The default scenes are hub, netview, noshadow and crowd. It works without a GPU, on the software adapter.

- Step 2 check (2026-11-15): `scripts/frontier_check.mjs` is ported from the engine's removed script (commit f2e7941) and runs on the page in `pages.yml`. It passes against the playground page: 16 of 256 cells at the start, the walk loads cells, each of the four zones is reached by fast travel, cells behind are unloaded (87), and the zones' pictures differ.
- Step 2 deviation: `app.ts` is `page/app.js` (plain JavaScript, no build step for the page's own script). The engine's shell runtime is still imported as before.


- Licence: MIT for code (matches the engine). Third-party notices in `THIRD_PARTY.md`.
- CI: `.github/workflows/pages.yml` is the only workflow. It checks the asset manifest and credits, builds the page
  against the pinned engine, plays it headless, checks native against wasm, and deploys from main. The engine's pixi
  environment is used as is, through its manifest path; the playground has no pixi manifest of its own.
- Town crowd purpose (2026-11-14): the residents walk between the four street corners of card 3 of `docs/frontier_plan.md`, with a guard that closes on the player. Chosen from that card, not asked; the user can redirect it.
- CesiumMan's texture is not shipped (2026-11-14). The model's README (Khronos glTF-Sample-Assets, CesiumMan) says the
  model carries the Cesium logo under `LicenseRef-LegalMark-Cesium`: a trademark licence with usage guidelines and no
  rights beyond them. The model's CC-BY 4.0 licence does not cover the logo. CesiumMan therefore stays untextured.
  Textured characters come from models whose whole texture is CC-BY or CC0 (the Fox, and any further Khronos model
  checked the same way).
- Page byte budget raised to 8 MB (2026-11-15, user's choice). The page was 2,898,491 bytes against the old 3 MB
  figure; one 256² RGBA texture with mips is about 350 KB, so ground and prop textures need the room. No check
  enforces the number yet; the next PR that adds a check uses 8 MB.

## Step 5 shadows on the mesh pass (scope and evidence)

- Scope of this slice: the static mesh items cast and receive shadows. The skinned characters neither cast nor receive them. The sun is orthographic along the mesh shader's light direction (0.4, 1.0, 0.6), 12 m half-extent, centred on the origin. `?noshadow` turns the depth pass and the factor off.
- Engine side: ludens-engine PR #67, `MeshPass` shadow map, comparison sampler and light uniform, 3 by 3 PCF, bias 0.003 scaled by (1 - N.L). With the shadow off the factor is exactly 1.0.
- Measured on the hub frame (`?offscreen&notown`, shadow on against `?noshadow`), mean luminance of hand-chosen crops:
  - footprint beside the blue box: 52.7 off, 19.8 on
  - the box's lit top face: 125.1 both (no acne on the face the light reaches)
  - an open ground patch: 53.5 off, 53.4 on
- Orientation of the shadow map, numeric: `tests/shadow_flip_native.mojo` puts a box at (0.25, -0.25) and reads texel (40, 40) as depth 0.45, with the mirrored texels (24, 40) and (40, 24) open (4 of 4). This checks the map's texel layout against the shader's uv formula, uv = (0.5 + 0.5 x, 0.5 - 0.5 y). The shading side of that formula is not separately tested.
- Scene check, by eye and not a number: each shadow meets its caster's base: the box's shadow at its left foot, the left pillar's at its foot, the Fox's under its body. The crops for the luminance measurements were chosen after viewing the frame.
- Test: `tests/mesh_shadow_native.mojo` (native, in `scripts/test_frontier_native.sh`) builds the mesh pass with the shadow bindings and checks `set_shadow`'s argument. It does not render a shadowed pixel.

## Step 5 shadows: what ships and what is measured

- Shipped on `main` (#67 engine, #48 page): the mesh pass samples the sun's shadow map with a 3 by 3 PCF, bias 0.003 scaled by (1 - N.L). The sun is orthographic along the mesh shader's light direction, 12 m half-extent, centred on the origin.
- Scope: static mesh items only. The skinned characters neither cast nor receive shadows.
- Hub frame, shadow on against `?noshadow` (mean luminance of hand-chosen crops): footprint beside the blue box 52.7 to 19.8; lit top face 125.1 both; open ground 53.5 to 53.4.
- Map orientation, numeric: `tests/shadow_flip_native.mojo` 4 of 4. Each shadow meets its caster's base by eye; that is not a number.

## Step 7 browser budget (main build)

- Build: `main` at #48 (`69f94ac`), engine pin 5298757. Browser: headless Chrome with SwiftShader, 1280×720, `NO_BENCH=1 SYNC=1 node scripts/crowd_bench.mjs`. Each sample is a captured frame, readback included.
- Results (12 samples each, median and p90, one captured frame per sample):

  | extra instances | residents (town) | median ms | p90 ms |
  |---:|---|---:|---:|
  | 0 | on | 208.50 | 228.20 |
  | 100 | on | 493.90 | 551.50 |
  | 180 | on | 675.30 | 725.00 |
  | 200 | off (`notown`) | 652.70 | 826.10 |
  | 400 | off (`notown`) | no capture | the palette limit |

- Palette limit: the engine's skinned palette holds 4096 matrices, and each CesiumMan has 19 joints. With the 24 town residents on, 200 extra members need 4256 matrices and the capture never completes. With `notown`, 200 fits. 400 members need 7600 and fail. The earlier 200-instance failure in this section was this limit, not a sampling fault. The page's capacity is about 180 members with residents, or about 215 without.
- Sample spread between runs of the same count is large on SwiftShader: count 0 measured 239.9 ms in one run and 208.5 ms in another, so compare counts within one run only.
- Earlier build, net-predict without shadows: 0 extra 173.8 ms; 100 extra 476.8 ms. The shadow pass costs about 66 ms per frame here.
- Backlog: in bench mode (`bench=1`, every frame drawn) the GPU work queues faster than SwiftShader drains it, so the GPU_SYNC numbers track the submit interval rather than GPU time.
- Conclusion: no count holds 60 Hz on this software rasterizer. The crowd count comes from the native 3b-0 budget. A hardware-GPU browser budget needs a machine with a GPU.

## Step 5 final: skinned characters cast and receive shadows (pinned engine 627e63e)

- Engine #67 (static mesh shadow map) and #68 (skinned receiving: `SkinnedPass` samples the same map and light, the same 3 by 3 PCF) are merged. The playground pins `627e63e`.
- Casting: the playground's `ShadowPass` runs the engine's skinning arithmetic (`SKIN_FN`) in its depth pass (#53). `tests/shadow_skin_native.mojo` agrees with the static path at 8 texels (worst difference 0).
- Receiving, measured on the page (60 crowd members, `?offscreen&notown&crowd=60`, shadow on against off, on the members' bodies, excluding the box): mean darkening 11.1 levels with receiving, against 2.0 without it. Without receiving the crowd only casts, and the bodies stay lit.
- Cast shadow beside the figure's legs: mean 53.9 to 33.6 with casting; torso unchanged (120.9 both).
- Still not measured: a light-direction flip on skinned meshes (the static map orientation is checked; `shadow_flip_native` 4 of 4).

## Step 7 re-run with casting and receiving (pinned engine 627e63e)

Same method as the main-build table: NO_BENCH SYNC, SwiftShader, 1280×720, captured frame including readback, 12 samples.

| extra instances | residents | median ms | p90 ms | before casting (main build) |
|---:|---|---:|---:|---:|
| 0 | on | 322.60 | 376.40 | 208.50 |
| 100 | on | 819.80 | 888.80 | 493.90 |
| 180 | on | 1178.60 | 1273.60 | 675.30 |
| 200 | off | 1107.90 | 1268.60 | 652.70 |

Each captured frame now draws every character's shadow, and the crowd receives shadows. The cost is about 115 ms at 0 extra and about 500 ms at 180 on this software rasterizer. The palette limit is unchanged: 200 with residents is still refused (`-4`), and 400 is still out of capacity.

## Step 8 stress test beyond line 430: the coupled sim

- `CoupledSim` (#52) refuses a player 0 move that would bring it within 1 m of another player. Measured natively and on the page: 2 refused moves, worst per-tick predicted error 4200 mm, idle error 0 mm, world hash equal at T.
- Under coupling the predicted client, which does not see the other players' inputs in time, reaches 4200 mm per tick. This is a measured property of a predicted client on a 9-tick link, reported as a result, not a plan requirement (line 430's assertions are the independent scenario).

## Step 8 stress test: two predictors under coupling (measured)

- Neutral remote players (`run_predict_coupled`): worst per-tick error 4200 mm.
- Dead reckoning for remote players (`run_predict_coupled_dr`): each remote player's velocity taken from the last two snapshots and replayed. Worst per-tick error 3000 mm.
- Why the bound stays out of reach: a change in a remote player's input reaches the predicted client only after the link's 9 ticks, and player 0's moves are refused by those players' positions. Dead reckoning cannot predict a change it has not yet received, so the error during each change is set by the latency. The 750 mm bound would need that information earlier than the link delivers it. That is a limit of the link, not a tuning issue.
- The page's netview runs the neutral predictor, so its number (4200 mm) is the one the page shows.

## Step 5 flip on skinned meshes (measured)

- `tests/shadow_skin_native.mojo`: the skinned depth map equals the static map at 8 texels (worst difference 0). The texels include the mirrored ones, (24, 40) and (40, 24), which are open in both maps, and the box texels (40, 40), (37, 37), (43, 43), (38, 42), (42, 38) at depth 0.45.
- `tests/shadow_flip_native.mojo` (static) puts the same box at texel (40, 40), so the skinned map has the same orientation as the static one, which is checked numerically.

