#!/usr/bin/env bash
# Build and run a native test of this package, through the engine's native target (same manifest as the wasm build).
#   bash scripts/test_native.sh tests/frontier_world.mojo
# Run it from the engine's wasm environment, like build_wasm.sh. The engine's static archives are needed; see build_wasm.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/deps.sh
python3 scripts/native_libs.py
ENGINE=build/deps/ludens-core
WGPU=build/deps/wgpu-mojo
MA=build/deps/miniaudio-mojo
SHELL_=build/deps/ludens-engine
TEST="${1:?usage: test_native.sh tests/<file>.mojo}"
NAME="$(basename "$TEST" .mojo)"
python3 -m ludens_wasm_rt.build_wasm \
  --lib "$ENGINE" --lib "$WGPU" --lib "$MA" --lib "$SHELL_" --lib . \
  -I "$ENGINE" -I "$WGPU" -I "$MA" -I "$MA/examples/web" -I "$SHELL_" -I . \
  "$TEST" --target native -o "build/$NAME"
"build/$NAME"
