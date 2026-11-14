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
