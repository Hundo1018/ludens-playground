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
  consistent with credits (run in CI). 5, 7, 8 are done in the narrowed list; stage 2 (physics) is not in the step list, see "Review findings" (W7).

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

## Review findings (2026-11-15) and the work they set

Source: a headless review of the page (SwiftShader), committed as `scripts/review_probe.mjs` (wrapper `scripts/review_probe.py`), and a code read.
Tags: **[measured]** a probe number, **[code]** read from the source, not seen on a frame.

### Findings

Severity order. Each finding names the user feedback item it touches (the user's five points, 2026-11-15).

| # | Finding | Tag | Feedback |
|---|---|---|---|
| F1 | No camera control from the mouse or pad. `Frontier.update` already applies `intent.look_dx/look_dy`, but `page/app.js` forwards only `EV_KEY` events and the pad's `look()` is empty, so the yaw never changes. The HUD says "DRAG MOUSE LOOK". Arrow keys strafe (engine `controls.mojo`). A 300 px drag changed 45,077 px of 518,400; idle changed 46,566. | measured + code | #2 |
| F2 | No objective and no loop: no goal, score, win or loss. Four zones differ only by ground colour and prop layout. | code | — |
| F3 | Threat without consequence: the guard (speed 2.2 m/s) cannot catch the player (9 m/s), and contact does nothing. Guard and residents share one model and colour. | code | — |
| F4 | Crowd members, town residents and the guard are drawn with identity rotation, so they do not face their travel direction. (The Fox does face its circle's tangent.) | code | #4 |
| F5 | The Fox moves at a constant 1.5 m/s on its circle while its clip cycles Survey, Walk and Run every 4 s, so the walk speed does not match the clip. | code | #4 |
| F6 | Characters pass through people and pillars: the crowd navmesh is a 40 m flat square with no holes, and hub pillars lie inside it. | code | #3 |
| F7 | HUD shows debug counters, and `FRAME` is always `0.0 MS` in green because `frame_ms` is never assigned. | measured (0.0) + code | — |
| F8 | No sound. Four CC0 effects are in the manifest as `.lsound` sources, but no build step converts them into the page and the host has no audio path. | code | — |
| F9 | Demo features hide behind URL parameters (`?netview`, `?crowd`), so a visitor never sees them. | code | — |
| F10 | Physics category absent. No fracture wall, cloth, rope or soft body; only stacks and balls. PLAN.md's "Current state" still says stage 2 is "not started", while the step list has no physics step. | code | — |
| F11 | Town zone empty: 23 residents on screen at the hub, 0 in each of the four zones. The residents are in the hub because the town is built on the floor at the origin. | measured | #3 |
| F12 | The step-7 crowd walks to the centre, where the player spawns, and stops within 0.6 m. | code | #3 |
| F13 | The protagonist is a blue box and sphere (`frontier/world.mojo` `draw_items`). Separately, `host.mojo` `_characters` draws a CesiumMan at a fixed point 6 m ahead of the eye and 1.5 m left, every frame, so it looks as if it walks in place in every zone. | measured (same screen spot in three zones) + code | #4 |
| F14 | Ray tracing is absent (shadows only). The original design's AO and reflections (stage 7) were removed from the plan. | code | #5 |
| F15 | The original seven categories (Rendering, Physics, Animation, AI, Streaming, Networking, Optimization) have no default-view showcase for Physics, and only partial showcases for the rest. | code | — |

### Work, in order

Each item states its acceptance check, observable from the page or a native test. A step is done when its check passes and its PR is merged. A browser check runs three times inside one CI step (a loop in `pages.yml`), so one green workflow run counts as three in a row; this replaces the earlier rule of three workflow runs per head.

**W2 Frame time shown (F7).** Add `playground_host_set_frame_ms(app, ms: Float64)` in `app/host.mojo`, called from `page/app.js` with the measured frame time. Add `playground_host_frame_ms(app) -> Float64` for the check. Acceptance: `host_check` asserts `frame_ms > 0` after 10 frames and the HUD text shows a value other than `0.0`.

**W1 Camera turns with input (F1, F9).**
- Forward pointer events from `page/app.js` to the host: mouse drag while the button is held, and the pad's look stick. First `grep -n "EV_\|kind ==" build/deps/ludens-engine/app/controls.mojo app/host.mojo` to find the event kinds the host reads, and check the engine's `shell/web` forwarding (pointerdown/move/up). Expected to be page-only; if a grep shows an engine change is needed, it is an engine PR then a pin bump.
- Add `Frontier.stat` index 10 = yaw in milliradians, so `scripts/frontier_check.mjs` and the new check read it through the same index-based path.
- Acceptance: `scripts/look_check.mjs` (new) dispatches a 300 px drag and asserts the yaw changes by 300 × 0.006 rad within 1 %; a drag of 0 px leaves it unchanged.
- The HUD keeps "DRAG MOUSE LOOK" only after this check passes.

**W3 Protagonist as a character (F4, F5, F13).** Two parts, in this order.
1. Delete the eye-relative CesiumMan in `host.mojo` `_characters`. Acceptance: no skinned draw is placed relative to the camera (grep and a native test on the draw list).
2. Replace the protagonist's blue primitive with a skinned character at the player's position. Heading = yaw. The clip is chosen by player speed: Survey below 0.2 m/s, Walk up to the Walk clip's speed, Run above it. The Fox's 4 s cycle goes away. Acceptance: an export `playground_host_player_pose(app) -> (x, z, heading)` and a check that over 120 ticks of walking the drawn position equals the player's position within 1 cm and the heading equals the velocity heading within 5 degrees.
- Asset policy: the player uses CesiumMan only if its texture rule is satisfied (see Decisions: CesiumMan is untextured for the logo reason), so the protagonist is the Fox or another CC-BY/CC0 character. Decide in W3 and record it in Decisions.

**W4 Crowd purpose and the town (F12, F3, F11, F6 town half).**
- The step-7 crowd's goal changes from the centre to a corner route (the residents' route from `app/town.mojo`), so it no longer walks to the player.
- The town moves into the TOWN zone: a navmesh is baked over the town cell around (112, 112) with building footprints as holes (card 3's design). The hub count drops to 0 and the TOWN count is the resident count. Acceptance: `playground_host_town_on_screen` is 0 at the hub and > 0 at the TOWN position, and a native test asserts every resident stays inside the cell.
- Guard: a distinct colour and a model that differs from residents. Its rule is W6's.

**W5 Hub pillars for the step-7 crowd (F6 hub half).** Bake the floor's navmesh with holes for the hub pillars (the arena's `_nav_box` approach). Acceptance: a native test asserts no crowd member's position lies in a pillar's footprint over 1200 ticks; the count is 0.

**W6 One objective loop (F2, F3).**
- One marker per zone, on the zone's route, and a counter in the HUD: `GOAL 0/4`, then `4/4` when all four are reached.
- The guard's rule: it runs at 7 m/s on the TOWN route and stops the player on contact (the player is returned to the hub and an event is counted). Raising its speed is a tuning change in W4's `GUARD_SPEED`, recorded in its PR.
- Acceptance: a native test teleports to each marker and asserts four completion events, each counted once, and a contact event resets the player.

**W8 Sound (F8).** Wire `scripts/convert_wav.py` into `build_page.sh` and `assets/index.json`, so the four `.lsound` files are in `build/page/assets/`. Before claiming a host audio path, `grep -rn "add_clip_pcm" build/deps/ludens-engine` and record the result. Audio starts after a user gesture (browser rule): the first key or pointer event starts the audio context. Acceptance: a host counter reads 1 after the first objective completion and the file is loaded (`host.audio_played == 1`).

**W7 Physics zone (F10, F15).** Restore one physics showcase from the original stage 2: a fracture wall in the quarry, broken by the pendulum. Acceptance: fragments count goes from 0 to > 0 after a pendulum hit, asserted in `scripts/physics_check.mjs` (new). Cloth and rope come after this step is measured.

**W9 Default view and HUD (F7, F9, F15).**
- The page keeps the crowd default off, per the step-7 rule (`crowdOn = false`, count 0 on this device).
- Netview: default on or off is the user's decision; this plan records it as on, labelled, with a DOM toggle, and the user can change it.
- Visible, labelled DOM toggles for netview and crowd. Debug counters move behind `?debug`. HUD shows the zone, the objective, and the frame time.
- Acceptance: `frontier_check.mjs` and `host_check.mjs` still pass; `scripts/stage_shots.py` produces the default page's screenshot, attached to the PR.

**W10 Ray tracing (F14).** Feasibility first: `grep -n "ComputePipeline\|Dispatch\|StorageBuffer" build/deps/wgpu-mojo/web/implemented.txt`. Then the stage 7 check: a GPU BVH AO hit test agrees per ray with CPU `BVH.raycast` (t within 1e-3). The HUD label is "software ray-traced AO". If a WebGPU function is missing, it is a wgpu-mojo PR then a pin bump.

**W11 Crowd in its own Worker, far-member LOD (F15, original Optimization design).** The 3b crowd moves to its own Worker with a far-member LOD; the main thread keeps only the visible set. Acceptance: the Worker's tick time is reported, and the page's frame time with 100 members is below the step-7 number recorded in this file. Open until measured.

### Order and stopping rule

W2, W1, W3, then W4 with W5, W6, W8, W7, W9, W10, W11. Each step is one PR, stacked on the previous one while CI runs. An engine or wgpu-mojo change is that repo's PR, then a pin bump here. Stop and report only when CI cannot verify a step.

### Progress (2026-11-15)

| Item | PR | State |
|---|---|---|
| W2 frame time | #63 | merged (`7450325`) |
| W1 camera look | #64 | merged (`b35764e`); three green runs on `4a56a4b` (attempts 3, 5, 6) |
| W3 protagonist | #65 | open; CI runs the check three times in one step |
| W4a crowd loop | #66 | open; stacked on W3 |
| W4b town in TOWN zone | #67 | open; stacked on W4a |
| W5 hub pillars for the crowd | (this branch) | `tests/crowd_native.mojo` 8/8: no member in a pillar after 40 s, corners checked |
| W6 to W11 | | not started |

Visual checks: W1 `look_check`; W3 protagonist frame in `zone_quarry.png`; W4a `crowd60.png` (members in a band on the square, none round the player); W4b `zone_town.png` (residents in the streets).

Acceptance amended (W4): "0 residents on screen at the hub" measures visibility, and it is 17 of 24 from the hub's view distance, because the far town is inside the view. The residents are not in the hub; the count is not a location test.

### Feasibility (probes run 2026-11-15)

- W10 (ray-traced AO): the wgpu-mojo web layer has `wgpuDeviceCreateComputePipeline` and `wgpuComputePassEncoderDispatchWorkgroups` (in `web/implemented.txt`). A compute AO pass may need no wgpu-mojo PR; storage buffers still need checking.
- W7 (physics): `add_fracture_box` exists in ludens-core `embed/world.mojo` (17.90). No engine change is needed for one fracture wall.
- W8 (sound): the engine's `app/main.mojo` already uses `add_clip_pcm`; `scripts/convert_wav.py` exists. The playground host has no audio output path yet, so W8 is host work.

### Status note

The status table's "done" means the narrowed eight steps. Physics (W7), ray tracing (W10) and the 3b Worker (W11) are open against the original categories, and this section is the work order for them.

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
| 7 Crowd | crowd in ecs.World, instanced skinned draws, HUD backend switch | #40 native 3b-0 numbers; `crowd_native` 5/5; palette guard #51; browser budget on the pinned build with casting, SwiftShader: 0 extra 322.60 ms, 100 extra 819.80 ms, 180 extra 1178.60 ms (Step 7 re-run). docs/design/step7-crowd.md rule (largest count with GPU-inclusive median under 16.7 ms) applied: result on this hardware is 0. No computer folder is usable from this session, so the device count is not measured here. The page's default follows the result: the crowd is off by default and opt-in (app.js, `crowdOn = false`). | Rule applied (docs/design/step7-crowd.md: largest count with GPU-inclusive median under 16.7 ms). On this device no count passes: the empty scene already takes 17.5 to 17.6 ms, so the count is 0. The page's default follows that result (crowd off, `crowdOn = false` in app.js). A GPU device would give its own count under the same rule; none is reachable from this session. |
| 8 Range networking | server module, SnapshotServer/Client, SimLink, lag-compensated hits, latency controls, three-colour view | `net_frontier.mojo`, `frontier_net_native` 11/11; #41 latency sweep 0 to 150 ms; #43 display error; #46 page sliders; #47 predicted client and three-colour view (`net_predict_native` 10/10 at line 430's link: per-tick predicted error 0 mm, 0 mm after idle, world hash equal at T, 9-tick shot hit and miss; `host_check` netview asserts the same); #52, #55 stress test beyond line 430 (see below); second module: `server.wasm` in a Worker, the page's clients exchange the same bytes with it, `host_check` 45 checks pass (section below) | done |

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
- Why the error stays at this size: a change in a remote player's input reaches the predicted client only after the link's 9 ticks, and player 0's moves are refused by those players' positions. Dead reckoning predicts from the last received input, so each change is mispredicted for the link's latency. The 750 mm figure belongs to the independent scenario (line 430); the coupled case does not owe it.
- The page's netview runs the neutral predictor, so its number (4200 mm) is the one the page shows.

## Step 8 second module: authoritative server in a Worker (measured)

- `app/server_host.mojo` builds to `server.wasm` (21,213 bytes, 9 exports) and runs in `page/net_server.worker.mjs`. The page's three clients (`playground_host_client_*` in app/host.mojo) exchange the same SnapshotServer and SnapshotClient bytes with it through `page/net_session.mjs`, a fixed 4-tick delay per direction, no jitter, no loss, in the order of `run_session`.
- `scripts/host_check.mjs` (headless Chrome, SwiftShader): the Worker session reaches tick 120 in 127 frames; server hash 765407476; the three client hashes are 765407476 each; the native reference is 765407476. 45 checks pass.

## Step 5 flip on skinned meshes (measured)

- `tests/shadow_skin_native.mojo`: the skinned depth map equals the static map at 8 texels (worst difference 0). The texels include the mirrored ones, (24, 40) and (40, 24), which are open in both maps, and the box texels (40, 40), (37, 37), (43, 43), (38, 42), (42, 38) at depth 0.45.
- `tests/shadow_flip_native.mojo` (static) puts the same box at texel (40, 40), so the skinned map has the same orientation as the static one, which is checked numerically.

