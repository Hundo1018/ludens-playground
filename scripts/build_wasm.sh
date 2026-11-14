#!/usr/bin/env bash
# Build the playground as one wasm64 module: app/main.mojo + the engine's game seam + ludens-core + wgpu-mojo + miniaudio-mojo.
#   bash scripts/build_wasm.sh [out.wasm]      (default build/playground.wasm)
# Libraries come from the revs pinned in deps.lock (scripts/deps.sh). Run it in the engine's wasm environment
# (ludens-engine's `pixi run -e wasm ...`), which provides ludens_wasm_rt.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/deps.sh
ENGINE=build/deps/ludens-core
WGPU=build/deps/wgpu-mojo
MA=build/deps/miniaudio-mojo
SHELL_=build/deps/ludens-engine
OUT="${1:-build/playground.wasm}"
mkdir -p build

python3 -m ludens_wasm_rt.build_wasm \
  --lib "$ENGINE" --lib "$WGPU" --lib "$MA" --lib "$SHELL_" --lib . \
  -I "$ENGINE" -I "$WGPU" -I "$MA" -I "$MA/examples/web" -I "$SHELL_" -I . \
  app/main.mojo -o "$OUT" --export 'playground_*'
