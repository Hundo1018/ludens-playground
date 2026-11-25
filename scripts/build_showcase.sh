#!/usr/bin/env bash
# The visual showcase page: build/showcase/ holds showcase.wasm (app/showcase_host.mojo), page/showcase/, the engine's
# JavaScript runtime and asset loader at the pinned revs, and the engine's CJK SDF font with its licence.
#   bash scripts/build_showcase.sh          (run from the engine's wasm environment)
# Serve build/showcase/ with any static server; it needs no COOP/COEP headers. build_page.sh copies it to build/page/showcase/.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/deps.sh
OUT=build/showcase
rm -rf "$OUT" build/showcase-build && mkdir -p "$OUT/assets" build/showcase-build
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I build/deps/ludens-engine/app -I . -I app \
  app/showcase_host.mojo -o build/showcase-build/showcase.wasm --export 'showcase_*'
cp build/showcase-build/showcase.wasm "$OUT/"
cp page/showcase/index.html page/showcase/showcase.js "$OUT/"
cp build/deps/ludens-engine/shell/web/assets.mjs build/deps/ludens-engine/shell/web/view_refs.mjs "$OUT/"
FONTS=build/deps/ludens-engine/assets/fonts
cp "$FONTS/NotoSansTC-Regular-24.lfont" "$OUT/assets/"
cp "$FONTS/OFL.txt" "$OUT/"
python3 scripts/write_index.py "$OUT/assets" "$OUT/assets/index.json"
WGPU=build/deps/wgpu-mojo
cp "$WGPU/web/webgpu_host.mjs" "$WGPU/web/webgpu_impl.mjs" "$WGPU/web/webgpu_runtime.mjs" "$WGPU/web/webgpu_layout.json" "$OUT/"
cp "$WGPU/scripts/webgpu_enum_strings.json" "$OUT/"
cp "$(python3 -c 'import ludens_wasm_rt; print(ludens_wasm_rt.HOST_MJS)')" "$OUT/host.mjs"
echo "build_showcase: $OUT ($(ls "$OUT" | wc -l) files)"
