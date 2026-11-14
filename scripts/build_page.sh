#!/usr/bin/env bash
# The Frontier page: build/page/ holds the wasm host, the engine's JavaScript runtime at the pinned rev, and page/.
#   bash scripts/build_page.sh          (run from the engine's wasm environment)
# Serve build/page/ with any static server; it needs no COOP/COEP headers (no shared memory).
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/deps.sh
OUT=build/page
rm -rf "$OUT" && mkdir -p "$OUT"
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I build/deps/ludens-engine/app -I . \
  app/host.mojo -o "$OUT/host.wasm" --export 'playground_host_*'
cp page/index.html page/app.js "$OUT/"
WGPU=build/deps/wgpu-mojo
cp "$WGPU/web/webgpu_host.mjs" "$WGPU/web/webgpu_impl.mjs" "$WGPU/web/webgpu_runtime.mjs" "$WGPU/web/webgpu_layout.json" "$OUT/"
cp "$WGPU/scripts/webgpu_enum_strings.json" "$OUT/"
cp "$(python3 -c 'import ludens_wasm_rt; print(ludens_wasm_rt.HOST_MJS)')" "$OUT/host.mjs"
echo "build_page: $OUT ($(ls "$OUT" | wc -l) files)"
