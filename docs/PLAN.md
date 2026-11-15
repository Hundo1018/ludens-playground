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

## Triplanar scale re-run on the textured floor (step 5)

Run on `main` (`d8a186c`, ground tiles on the mesh pass), with `?offscreen&notown` so the floor crop holds no residents: 0.125 gives std-dev 12.96, 0.25 (pinned) 12.69, 0.5 12.52, 1.0 12.73. The spread is under half a level, so this metric does not separate the scales. The sweep stays at 0.25 until a visual comparison picks a value. This replaces the withdrawn result in PR #37.

## Done means

Each step: its PR merged, its check green locally from a fresh clone, and the Pages build serving the change.

## Decisions

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
