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
# W10: the GPU ray trace over the hub's BVH agrees with the CPU raycast (hit flags and distances)
# W6: one goal per zone at its fast-travel point, each counted once
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/rt_native.mojo --target native -o build/rt_native
build/rt_native
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/goals_native.mojo --target native -o build/goals_native
build/goals_native
# W7: the quarry wall falls and breaks; the scenario that does not break is checked too
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/quarry_native.mojo --target native -o build/quarry_native
build/quarry_native
# B1: a 2000 kg pendulum on a hinge breaks the standing wall; the wall alone does not break
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/pendulum_native.mojo --target native -o build/pendulum_native
build/pendulum_native
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
# audit A3: the town's and the crowd's navmeshes are unchanged by building their input with ludens-core's nav.nav_input
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/navmesh_native.mojo --target native -o build/navmesh_native
build/navmesh_native
# Reference baseline E1: the town's characters pick walk or run by motion matching on their speed.
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/town_motion_native.mojo --target native -o build/town_motion_native
build/town_motion_native
# audit B9: motion matching on ludens-core decides exactly what the playground's own code did (state hash, switches, M6)
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/mm_parity_native.mojo --target native -o build/mm_parity_native
build/mm_parity_native
# Reference baseline E2: CesiumMan's feet on a 20 degree slope with two_bone and foot_plant.
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/foot_ik_native.mojo --target native -o build/foot_ik_native
build/foot_ik_native
# V5: CesiumMan skinned to the knocked-down figure's bodies stays on them as it falls.
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/rag_skin_native.mojo --target native -o build/rag_skin_native
build/rag_skin_native
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
# Reference baseline C: a fractured wall's destruction served by SnapshotServer to two clients, hashes equal.
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web \
  -I build/deps/ludens-engine -I . -I app \
  tests/net_fracture_native.mojo --target native -o build/net_fracture_native
build/net_fracture_native
