# ludens-playground

The showcase sample for the Ludens engine: **Ludens Frontier**, a streamed world that plays in the browser (GitHub Pages).

This repository is a *consumer* of the engine. The engine's game seam (`game/mode.mojo`, `GameMode`) is what this package
runs games through; the engine supplies the game, this package decides the exports the page can call.

## Build and check

Run from the engine's wasm environment (it provides `ludens_wasm_rt`):

    bash scripts/build_wasm.sh              # build/playground.wasm
    node scripts/check_wasm.mjs <host.mjs> build/playground.wasm

`<host.mjs>` is `ludens_wasm_rt.HOST_MJS`. The check compares against the native target's output for the same sources, which
is the point: the same numbers on both targets.

## Status

- Working: an outside package builds a wasm module with its own `@export`s over the engine's seam (`app/main.mojo`).
- Not yet: the streamed world (`game/frontier*.mojo` still lives in ludens-engine), the asset pipeline, and the page.

See `docs/frontier_plan.md` and `docs/asset-policy.md`.

## Licence

Code: see `LICENSE` (to come; awaiting a decision). Assets: per-asset, see `assets/CREDITS.md` (to come).
