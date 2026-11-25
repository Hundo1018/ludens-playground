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
# step 8, second module: the range server (server.wasm) and the Worker that runs it; net_session.mjs is the page's driver
bash scripts/build_server.sh
cp build/server/server.wasm page/net_server.worker.mjs page/net_session.mjs "$OUT/"
bash scripts/build_crowd.sh && mkdir -p "$OUT/crowd" && cp build/crowd/crowd.wasm "$OUT/crowd/" && cp page/crowd.worker.mjs "$OUT/"  # W11: the crowd in a Worker
cp build/deps/ludens-engine/shell/web/assets.mjs "$OUT/"  # the engine's loader: sha256 check, size cap, copy into wasm
# the engine's virtual pad (TypeScript): types stripped with node, as the engine's own build_web.py does
for ts in vpad vpad_view; do
  node --input-type=module -e "import {stripTypeScriptTypes as s} from 'node:module';import fs from 'node:fs';fs.writeFileSync(process.argv[2], s(fs.readFileSync(process.argv[1], 'utf8')))" \
    build/deps/ludens-engine/shell/web/$ts.ts "$OUT/$ts.js"
done
# assets: fetched and verified against the manifest, converted to the engine's binary formats, then indexed
python3 scripts/fetch_assets.py
CONV=build/assets/converted
EA=build/deps/ludens-engine/scripts/assets  # the engine's asset converters (ludens-engine#12)
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
python3 $EA/convert_glb.py build/assets/src/Fox.glb "$CONV/Fox.lcharacter"
python3 $EA/convert_texture.py build/assets/src/concrete_wall_003_diff_1k.jpg "$CONV/concrete_wall_003.ltexture"
python3 $EA/convert_texture.py build/assets/src/rocks_ground_01_diff_1k.jpg "$CONV/rocks_ground_01.ltexture"
python3 $EA/extract_glb_texture.py build/assets/src/Fox.glb 0 "$CONV/fox_base.png"
python3 $EA/convert_texture.py "$CONV/fox_base.png" "$CONV/fox_base.ltexture"
# V1: CesiumMan's own base colour (its GLB embeds one JPEG, material 0); V2-V3: Poly Haven CC0 textures (assets/manifest.toml)
python3 $EA/extract_glb_texture.py build/assets/src/CesiumMan.glb 0 "$CONV/cesium_base.png"
python3 $EA/convert_texture.py "$CONV/cesium_base.png" "$CONV/cesium_base.ltexture"
LAYER_TEX="medieval_blocks_02 castle_brick_07 plastered_wall_02 brown_planks_03 bark_brown_02 hessian_230 rusty_metal_02"
for t in $LAYER_TEX; do python3 $EA/convert_texture.py "build/assets/src/${t}_diff_1k.jpg" "$CONV/$t.ltexture"; done
# W8: four CC0 effects from the archive in the manifest (sound_essential_retro_512), converted to 48 kHz mono .lsound
SND="The Essential Retro Video Game Sound Effects Collection [512 sounds] By Juhani Junkala/General Sounds"
python3 $EA/convert_wav.py build/assets/src/essential_retro_512.zip "$SND/Menu Sounds/sfx_menu_select1.wav" "$CONV/sfx_menu_select1.lsound"
python3 $EA/convert_wav.py build/assets/src/essential_retro_512.zip "$SND/Coins/sfx_coin_cluster1.wav" "$CONV/sfx_coin_cluster1.lsound"
python3 $EA/convert_wav.py build/assets/src/essential_retro_512.zip "$SND/Simple Damage Sounds/sfx_damage_hit1.wav" "$CONV/sfx_damage_hit1.lsound"
python3 $EA/convert_wav.py build/assets/src/essential_retro_512.zip "$SND/Positive Sounds/sfx_sounds_powerup1.wav" "$CONV/sfx_sounds_powerup1.lsound"
# the page ships these; nothing else in the converted directory
for f in CesiumMan.lcharacter Fox.lcharacter concrete_wall_003.ltexture rocks_ground_01.ltexture fox_base.ltexture cesium_base.ltexture $(for t in $LAYER_TEX; do echo $t.ltexture; done) sfx_menu_select1.lsound sfx_coin_cluster1.lsound sfx_damage_hit1.lsound sfx_sounds_powerup1.lsound; do cp "$CONV/$f" "$OUT/assets/"; done
cp build/deps/ludens-engine/shell/web/worklet.js "$OUT/"  # the engine's AudioWorklet ring player (W8)
python3 scripts/write_index.py "$OUT/assets" "$OUT/assets/index.json"
python3 scripts/write_credits_html.py assets/CREDITS.md "$OUT/credits.html"
WGPU=build/deps/wgpu-mojo
cp "$WGPU/web/webgpu_host.mjs" "$WGPU/web/webgpu_impl.mjs" "$WGPU/web/webgpu_runtime.mjs" "$WGPU/web/webgpu_layout.json" "$OUT/"
cp "$WGPU/scripts/webgpu_enum_strings.json" "$OUT/"
cp "$(python3 -c 'import ludens_wasm_rt; print(ludens_wasm_rt.HOST_MJS)')" "$OUT/host.mjs"
# the visual showcase (scripts/build_showcase.sh) as build/page/showcase/
bash scripts/build_showcase.sh && rm -rf "$OUT/showcase" && cp -r build/showcase "$OUT/showcase"
echo "build_page: $OUT ($(ls "$OUT" | wc -l) files)"
