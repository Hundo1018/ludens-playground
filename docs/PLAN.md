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
- Open: the Frontier **page** here (today it exists only in the engine, which still serves `?frontier`); engine #59 removes
  that copy and must not merge before the page exists here.

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
