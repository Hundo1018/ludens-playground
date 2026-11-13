# ludens-playground

The showcase sample for the Ludens engine: **Ludens Frontier**, a streamed world that plays in the browser (GitHub Pages).

This repository is a *consumer* of the engine, not part of it. It reaches the engine only through the packages pinned in
`deps.lock` (simulation core `ludens-core`, GPU `wgpu-mojo`, audio `miniaudio-mojo`), so anything it needs that the engine
does not offer is an engine change, not a workaround here.

## Status

Bootstrap only. The plan lives in `docs/frontier_plan.md`: three levels of detail (goals, work lists, step-by-step
instructions), with the stage order and the asset policy.

The first stage (streaming world, culling, HUD) currently sits in ludens-engine as `game/frontier.mojo` and is to be moved
here once the engine offers the interface it needs (a registered game mode, a renderer the game can drive, input
without the engine's own app state).

## Assets

Only openly licensed material: CC0 or CC-BY. Each asset is listed with its URL, licence and sha256 in `assets/manifest.toml`
(to come), and `assets/CREDITS.md` is generated from that list. Code is ours; art, animation, sound and fonts are not
made here.

## Licence

Code: see `LICENSE` (to come). Assets: per-asset, see `assets/CREDITS.md`.
