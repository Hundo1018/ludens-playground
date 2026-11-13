#!/usr/bin/env bash
# Export the pinned revs in deps.lock into build/deps/<name> (a clean tree, whatever branch the sibling
# checkout is on). A sibling checkout is used if present; otherwise the rev is fetched from GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."
while read -r name path rev; do
  case "$name" in ''|'#'*) continue ;; esac
  dst="build/deps/$name"
  if [ -f "$dst/.rev" ] && [ "$(cat "$dst/.rev")" = "$rev" ]; then continue; fi
  rm -rf "$dst"; mkdir -p "$dst"
  if git -C "$path" cat-file -e "$rev^{commit}" 2>/dev/null; then
    git -C "$path" archive "$rev" | tar -x -C "$dst"
  else
    git clone -q "https://github.com/Hundo1018/$name" "$dst.git" && git -C "$dst.git" archive "$rev" | tar -x -C "$dst" && rm -rf "$dst.git"
  fi
  echo "$rev" > "$dst/.rev"
  echo "deps: $name @ $rev"
done < deps.lock
# wgpu-mojo's manifest may still list its own runtime shim, which duplicates ludens-wasm-rt's runtime and
# breaks the combined link. Drop it from the exported copy. Remove once wgpu-mojo's manifest is clean.
if grep -q 'wasm_rt\.c' build/deps/wgpu-mojo/wasm.toml; then sed -i '/^c_sources/d' build/deps/wgpu-mojo/wasm.toml; fi
