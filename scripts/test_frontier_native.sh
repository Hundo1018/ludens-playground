#!/usr/bin/env bash
# The playground's native checks (B1 on the CPU; B3 when a GPU adapter is present, required with --require-gpu).
#   bash scripts/test_frontier_native.sh [--require-gpu]     (run from the engine's wasm environment)
# Needs build/assets/converted/ (scripts/build_page.sh makes it). Builds build/frontier_native from tests/frontier_native.mojo.
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
