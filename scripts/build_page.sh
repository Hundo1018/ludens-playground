#!/usr/bin/env bash
# The Frontier page: build/page/ holds the wasm host, the engine's JavaScript runtime at the pinned rev, and page/.
#   bash scripts/build_page.sh          (run from the engine's wasm environment)
# Serve build/page/ with any static server; it needs no COOP/COEP headers (no shared memory).
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/deps.sh
OUT=build/page
rm -rf "$OUT" build/page-build && mkdir -p "$OUT" build/page-build
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I build/deps/ludens-engine/app -I . -I app \
  app/host.mojo -o build/page-build/host.wasm --export 'playground_host_*'
# the compiler writes its intermediates (.ll, .bc, .o) next to the output: keep them out of the uploaded page
cp build/page-build/host.wasm "$OUT/host.wasm"
cp page/index.html page/app.js "$OUT/"
cp build/deps/ludens-engine/shell/web/assets.mjs "$OUT/"  # the engine's loader: sha256 check, size cap, copy into wasm
# the engine's virtual pad (TypeScript): types stripped with node, as the engine's own build_web.py does
for ts in vpad vpad_view; do
  node --input-type=module -e "import {stripTypeScriptTypes as s} from 'node:module';import fs from 'node:fs';fs.writeFileSync(process.argv[2], s(fs.readFileSync(process.argv[1], 'utf8')))" \
    build/deps/ludens-engine/shell/web/$ts.ts "$OUT/$ts.js"
done
# assets: fetched and verified against the manifest, converted to the engine's binary formats, then indexed
python3 scripts/fetch_assets.py
CONV=build/assets/converted
rm -rf "$CONV" && mkdir -p "$CONV" "$OUT/assets"
# CesiumMan carries the rest clip (kind 100), three CMU subject-07 trials retargeted in place: walk (101, step 6.2), slow
# walk (102), brisk walk (103), and three subject-38 trials for the matching database only (104 walk, 105 walk, 106 walk
# with turns; db mode, no loop window). The slow walk uses the seam criterion for its loop window (retarget.py, step 6.3).
python3 scripts/retarget.py --clips "$CONV/CesiumMan.lcharacter" build/assets/src/CesiumMan.glb build/assets/src/07.asf \
  "cmu07_walk=build/assets/src/07_01.amc" "cmu07_slow_walk=build/assets/src/07_04.amc:100:260:r" "cmu07_brisk_walk=build/assets/src/07_12.amc" \
  "cmu38_walk=build/assets/src/38_01.amc:80:1000:db@build/assets/src/38.asf" "cmu38_walk2=build/assets/src/38_02.amc:80:1000:db@build/assets/src/38.asf" "cmu38_walk_turns=build/assets/src/38_04.amc:80:1000:db@build/assets/src/38.asf" \
  "cmu16_run=build/assets/src/16_55.amc:60:360:db@build/assets/src/16.asf"
python3 scripts/retarget.py --check-clips "$CONV/CesiumMan.lcharacter" build/assets/src/CesiumMan.glb build/assets/src/07.asf \
  "cmu07_walk=build/assets/src/07_01.amc" "cmu07_slow_walk=build/assets/src/07_04.amc:100:260:r" "cmu07_brisk_walk=build/assets/src/07_12.amc" \
  "cmu38_walk=build/assets/src/38_01.amc:80:1000:db@build/assets/src/38.asf" "cmu38_walk2=build/assets/src/38_02.amc:80:1000:db@build/assets/src/38.asf" "cmu38_walk_turns=build/assets/src/38_04.amc:80:1000:db@build/assets/src/38.asf" \
  "cmu16_run=build/assets/src/16_55.amc:60:360:db@build/assets/src/16.asf"
python3 scripts/convert_glb.py build/assets/src/Fox.glb "$CONV/Fox.lcharacter"
python3 scripts/convert_texture.py build/assets/src/concrete_wall_008_diff_1k.jpg "$CONV/concrete_wall_008.ltexture"
# the page ships these three; nothing else in the converted directory
for f in CesiumMan.lcharacter Fox.lcharacter concrete_wall_008.ltexture; do cp "$CONV/$f" "$OUT/assets/"; done
python3 scripts/write_index.py "$OUT/assets" "$OUT/assets/index.json"
python3 scripts/write_credits_html.py assets/CREDITS.md "$OUT/credits.html"
WGPU=build/deps/wgpu-mojo
cp "$WGPU/web/webgpu_host.mjs" "$WGPU/web/webgpu_impl.mjs" "$WGPU/web/webgpu_runtime.mjs" "$WGPU/web/webgpu_layout.json" "$OUT/"
cp "$WGPU/scripts/webgpu_enum_strings.json" "$OUT/"
cp "$(python3 -c 'import ludens_wasm_rt; print(ludens_wasm_rt.HOST_MJS)')" "$OUT/host.mjs"
echo "build_page: $OUT ($(ls "$OUT" | wc -l) files)"
