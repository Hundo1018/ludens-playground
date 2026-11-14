# Third-party components

This package's code is MIT (see `LICENSE`). It builds against and ships parts of the components below; each keeps its own licence.

## Software (linked into the wasm module)

| Component | Licence | Where it comes from |
|---|---|---|
| ludens-engine (game seam, arena) | MIT | `deps.lock`: `ludens-engine` |
| ludens-core (simulation) | MIT or Apache-2.0 (dual) | `deps.lock`: `ludens-core` |
| wgpu-mojo (GPU) | Apache-2.0 | `deps.lock`: `wgpu-mojo` |
| miniaudio-mojo (audio) | Apache-2.0 | `deps.lock`: `miniaudio-mojo` |

The Apache-2.0 licence text is in each component's repository (`LICENSE`). A distributed build includes the notices those licences require.

## Assets (listed in `assets/CREDITS.md`, generated from `assets/manifest.toml`)

- Creative Commons CC0 1.0: no attribution required; credited anyway where the source is known.
- Creative Commons Attribution 4.0 (CC-BY 4.0): attribution required; `assets/CREDITS.md` names the author, the source and the licence.
- SIL Open Font License 1.1: the font's copyright and licence text are included with the font data.

Assets used, and what each is, are listed in `assets/CREDITS.md` once the asset pipeline lands.
