#!/usr/bin/env bash
# The package's parity check: native and wasm must print the same numbers.
#   bash scripts/check_parity.sh <host.mjs>      (host.mjs = ludens_wasm_rt.HOST_MJS, from the engine's wasm env)
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${1:?usage: check_parity.sh <host.mjs>}"
bash scripts/build_wasm.sh build/playground.wasm
python3 -m ludens_wasm_rt.build_wasm \
  --lib build/deps/ludens-core --lib build/deps/wgpu-mojo --lib build/deps/miniaudio-mojo --lib build/deps/ludens-engine --lib . \
  -I build/deps/ludens-core -I build/deps/wgpu-mojo -I build/deps/miniaudio-mojo -I build/deps/miniaudio-mojo/examples/web -I build/deps/ludens-engine -I . \
  app/main.mojo --target native -o build/playground_native
build/playground_native > build/native.txt
node scripts/check_wasm.mjs "$HOST" build/playground.wasm build/native.txt
