#!/usr/bin/env bash
# The playground's native checks (B1 on the CPU; B3 when a GPU adapter is present, required with --require-gpu).
#   bash scripts/test_frontier_native.sh [--require-gpu]     (run from the engine's wasm environment)
# M6 (motion matching) runs after them. Needs build/assets/converted/ (scripts/build_page.sh makes it).
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/deps.sh
bash scripts/build_wasm.sh build/frontier_wasm_for_native_libs.wasm  # builds the native static libraries (as check_parity.sh does)
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/frontier_native.mojo --target native -o build/frontier_native
build/frontier_native "$@"
# M6 (motion matching): the native indices; its hash is the value scripts/host_check.mjs checks on the page
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/motion_match_native.mojo --target native -o build/motion_match_native
build/motion_match_native
# step 8 (netcode): the Frontier's simulation over SnapshotServer / SnapshotClient through SimLink, and lag-compensated shots
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/frontier_net_native.mojo --target native -o build/frontier_net_native
build/frontier_net_native
# step 7 (crowd): ecs entities moved by the flow field; the two backends agree; a switch keeps the crowd
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/crowd_native.mojo --target native -o build/crowd_native
build/crowd_native
# plan stage 3 (card 3): the town's ORCA crowd, four corners and a guard
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/town_native.mojo --target native -o build/town_native
build/town_native
# Step 5 shadow probe: a depth texture through a comparison sampler, natively (plan step 5).
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/shadow_probe_native.mojo --target native -o build/shadow_probe_native
build/shadow_probe_native
# Step 5 shadow depth pass: a unit box drawn from an orthographic light into a depth texture (plan step 5).
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/shadow_pass_native.mojo --target native -o build/shadow_pass_native
build/shadow_pass_native
# Step 5 mesh pass with the shadow factor: the engine's shadow bindings build, and set_shadow checks its argument.
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/mesh_shadow_native.mojo --target native -o build/mesh_shadow_native
build/mesh_shadow_native
# Step 5 shadow map orientation: a box off the centre lands at its texel, and the mirrored texels stay open.
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/shadow_flip_native.mojo --target native -o build/shadow_flip_native
build/shadow_flip_native
# Step 5 skinned shadows: the skinned depth path matches the static one at an identity palette (joint and weight layout).
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/shadow_skin_native.mojo --target native -o build/shadow_skin_native
build/shadow_skin_native
# Step 8 prediction-error bound (docs/frontier_plan.md line 430): a predicted client against the server truth, natively.
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/net_predict_native.mojo --target native -o build/net_predict_native
build/net_predict_native
