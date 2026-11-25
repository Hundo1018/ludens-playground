# ludens-playground

The showcase sample for the Ludens engine: **Ludens Frontier**, a streamed world that plays in the browser (GitHub Pages).

This repository is a *consumer* of the engine. The engine's game seam (`game/mode.mojo`, `GameMode`) is what this package
runs games through; the engine supplies the game, this package decides the exports the page can call.

## Visual showcase

`showcase/` and `app/showcase_host.mojo`: one small scene with the engine's picture features on at once, at
`<site>/showcase/` (page: `page/showcase/`). Bodies fall onto a ramp and a pile (ludens-core rigid bodies) and every hard
impact throws sparks; two rows of PBR spheres go from smooth to rough (gold metal, red plastic); three coloured point
lights circle the pile and four glowing posts feed the bloom; smoke, embers and dust are particle emitters; the HUD is in
Traditional Chinese, drawn from the engine's SDF font (NotoSansTC, SIL OFL 1.1).

| key | switch |
|---|---|
| 1 | MSAA 4x (the renderer is rebuilt with 1 or 4 samples) |
| 2 | FXAA (off at the start: after MSAA it is not an improvement, see ludens-engine `docs/rendering-tier1.md`) |
| 3 / 4 | bloom / colour-grading LUT |
| 5 / 6 / 7 | sun shadow / seven point lights / particles |
| Space, R, H | drop ten bodies, start over, hide the HUD; a left-button drag turns the camera |

    bash scripts/build_showcase.sh                                        # build/showcase/
    bash scripts/test_native.sh tests/showcase_native.mojo                # the scene without a GPU; prints its hash
    node scripts/showcase_check.mjs <chrome> <url>/index.html?offscreen <out-prefix> 900 <native hash>
    node scripts/showcase_record.mjs <chrome> "<url>/index.html?offscreen&nohud&w=640&h=360" build/rec 90 15
    python3 scripts/frames_to_gif.py build/rec build/showcase.gif --fps 15

## Build and check

Run from the engine's wasm environment (it provides `ludens_wasm_rt`):

    bash scripts/build_wasm.sh              # build/playground.wasm
    node scripts/check_wasm.mjs <host.mjs> build/playground.wasm

`<host.mjs>` is `ludens_wasm_rt.HOST_MJS`. The check compares against the native target's output for the same sources, which
is the point: the same numbers on both targets.

## Tests

    bash scripts/test_native.sh tests/frontier_world.mojo   # the streamed world: 26 checks

## Status

- Working: an outside package builds a wasm module with its own `@export`s over the engine's seam (`app/main.mojo`).
- The streamed world (`frontier/`, moved from ludens-engine): its logic, HUD and wrapper, with a native test (26 checks) and wasm exports (`playground_frontier_hash`, `playground_frontier_bodies`), numbers equal on both targets.
- Not yet: the page for the Frontier, the browser check, the asset pipeline.

See `docs/frontier_plan.md` and `docs/asset-policy.md`.

## Licence

Code: see `LICENSE` (to come; awaiting a decision). Assets: per-asset, see `assets/CREDITS.md` (to come).
