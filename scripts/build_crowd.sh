#!/usr/bin/env bash
# The step-7 crowd as its own wasm module (plan W11): app/crowd_host.mojo -> build/crowd/crowd.wasm.
# Run from the engine's wasm environment, like build_page.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/deps.sh
OUT=build/crowd
rm -rf "$OUT" && mkdir -p "$OUT"
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I build/deps/ludens-engine/app -I . -I app \
  app/crowd_host.mojo -o "$OUT/crowd.wasm" --export 'playground_crowd_*'
