# Step 5: rendering (design)

This note governs `docs/PLAN.md` step 5. The work spans three repositories:
- **ludens-engine** (render passes).
- **ludens-playground** (converters and content).
- **ludens-core** (the CPU skinning reference, pinned by the engine).

## Layer 1 (for opus): decisions and interfaces

### 1.1 Goal and non-goals

**Goal.** The Frontier hub shows:
- CesiumMan playing clip 0, skinned on the GPU.
- Fox playing "Walk".
- Static props drawn as indexed meshes.
- The ground and box buildings textured with `concrete_wall_008` through triplanar mapping.

The existing spheres and boxes still draw exactly as before.

**Non-goals:** shadows, GI, ray tracing, LOD, per-cell mesh streaming, normal maps, sRGB and tone mapping, animation blending (step 6), and crowd instancing (step 7). The palette layout below is chosen so that step 7 can reuse it.

### 1.2 Where code goes

- **ludens-engine `app/`:**
  - `mesh_pass.mojo`: the registry and pass A.
  - `skin_pass.mojo`: pass B.
  - `texture_pass.mojo`: pass C.
  - Store WGSL the way `render3d.mojo` already does.
- **ludens-playground:**
  - Converter v2 in `scripts/convert_glb.py`.
  - New `scripts/convert_texture.py`.
  - Asset step in `build_page.sh`.
  - Load calls in `page/app.js`.
  - Frontier placement.
- **ludens-core:** no change expected. `geometry/skinning` is the CPU reference if its signature fits (U1).

### 1.3 Scene interface

- `DrawItem` gains three fields:
  - `mesh_id: Int`, default -1, meaning the existing primitive path.
  - `pose_id: Int`, default -1, meaning static.
  - `material: Int`, default 0, meaning colour only.
- Existing producers set none of these, so their command stream stays identical.
- `GameMode` does not change in step 5.
- The host sets palettes through the renderer before drawing: `MeshPass.set_palette(slot, palette)`.
- `pose_id` indexes those slots.
- Step 6 may move poses into `GameMode`.

### 1.4 File formats

**`.lcharacter` v2.** Mojo reads only the binary directory and never parses JSON.

```
"LCHR" u32 version=2 u32 blob_count
blob_count x (u32 kind, u32 offset, u32 bytes)
u32 json_len  JSON (tools only, space-padded)
blobs, each starting on a 16-byte boundary
```

Blob kinds:

| Kind | Contents |
|---|---|
| 1 | positions, f32x3 |
| 2 | normals, f32x3 |
| 3 | uv, f32x2 |
| 4 | joints, u16x4 |
| 5 | weights, f32x4 |
| 6 | indices, u32 |
| 7 | inverse bind, f32x16 per joint, column-major |
| 8 | rest pose, f32x10 per joint: T3, R4 (x,y,z,w), S3 |
| 9 | parents, i32 per joint, -1 for a root |
| 10 | root_transform, f32x16 column-major |
| 100+k | clip k, f32 frames x joints x 10, at the fps given in the JSON (30) |

- For a clip, `frames = bytes / (joints*40)`.
- `root_transform` is the product of the global transforms of the root joint's non-joint ancestors. It is identity if there are none.
- In glTF, joint globals include those ancestors, and v1 dropped them.

**`.ltexture` v1.**

```
"LTEX" u32 version=1 u32 width u32 height u32 levels
```

- Levels follow, largest first, each rgba8 and tightly packed, each starting on a 16-byte boundary.
- There is no JSON in this format.

**Reader rule for any file:** copy every blob into its own buffer before upload. Never alias a typed array onto the file buffer at a blob offset.

### 1.5 GPU layout

Vertex buffers are non-interleaved, one per blob.

| Pipeline | Slot | Content | Format | Stride |
|---|---|---|---|---|
| static | 0 | position | float32x3 | 12 |
| static | 1 | normal | float32x3 | 12 |
| static | 2 | uv | float32x2 | 8 |
| static | 3 | instance: matrix (4 x float32x4) + colour float32x4 + uint32x4 (material, layer, palette base, 0) | | 96 |
| skinned | 0–2 | as static | | |
| skinned | 3 | joints | uint16x4 | 8 |
| skinned | 4 | weights | float32x4 | 16 |
| skinned | 5 | instance, as static slot 3 | | 96 |

- The instance slot uses step mode "instance".
- The index buffer is uint32.
- The skinned pipeline uses 11 vertex attributes and 6 vertex buffers. The WebGPU defaults allow 16 attributes and 8 buffers.
- `writeBuffer` sizes must be multiples of 4. Every blob above already is.

### 1.6 Math conventions

- Matrices are column-major on the GPU side. The inverse bind matrices and `root_transform` are glTF column-major, so upload them as they are. WGSL `mat4x4<f32>` is also column-major.
- Quaternions in files are glTF (x, y, z, w). There is one conversion function, `quat_from_gltf`, into the engine or core quaternion type.
- The test for that function: (0, 0.7071068, 0, 0.7071068) rotates (1,0,0) to (0,0,-1), within 1e-6.
- The palette is computed on the CPU each frame, with one formula for every joint:
  - `palette[i] = root_transform · local_chain[i] · IBM[i]`, where `local_chain[i]` is the product of the joint's local transforms from the skeleton root down to the joint.
  - Correction (PR 0, measured): the exported IBMs exclude the non-joint ancestors, so `root_transform` must multiply every joint, not only the root. The earlier root-only formula gave a rest-pose error of 0.74 on CesiumMan. With the formula above, rest skinning maps `p` to `root_transform · p` with error 4.4e-7.
  - Parents must come before children. Assert this.
- The GPU only computes `Σ_k w_k · (palette[j_k] · v)` for k = 0..3.

### 1.7 Skinning

- One WGSL source string, `SKIN_FN`, defines `skin_position(p, n, joints, weights, base)`.
- That string is included in two places: the skinned vertex shader, and a compute shader `skin_cs` with workgroup size 64. The compute shader writes skinned positions as `array<vec4<f32>>` for readback.
- Palettes live in one read-only storage buffer, `array<mat4x4<f32>>`, shared by every skinned instance in the frame. Each instance's base index is in its instance data.
- Step 5 capacity: 64 instances x 64 joints (256 KB).
- If storage buffers are not available in the vertex stage (U3), fall back to a uniform buffer: 64 joints, one draw per instance.
- **Seam:** `trait Skinning` with `fn skin(mut self, mesh_id, palette) raises -> List[Float32]`. It has two implementations, `CpuSkinning` and `GpuSkinning` (the compute path plus readback).
- The parity test is `test_skinning_parity`.
- Normals use the same palette. Non-uniform scale is not supported in step 5.
- Check this in PR 0: every clip's S channel is within 1e-5 of 1. Correction (PR 0, measured): the source animation data deviates by up to 1.3e-6, so 1e-6 is too strict; 1e-5 still rejects non-uniform scale.

### 1.8 Textures and triplanar

- **Texture:** `texture_2d_array`, rgba8unorm (not sRGB in step 5), 256x256, 9 mip levels.
  - Layer 0 is white and is generated in code.
  - Layer 1 is `concrete_wall_008`.
  - Upload with `queue.writeTexture` per level. `writeTexture` has no 256-byte row alignment rule. Do not use `copyBufferToTexture`, which does.
- **Samplers:**
  - The main sampler is linear/linear/linear with repeat.
  - Tests use a second sampler with nearest filtering and no mip filtering.
- **Materials:**
  - 0: colour only (the old look).
  - 1: mesh uv plus a layer.
  - 2: triplanar plus a layer, with weights `|n|^4` normalised.
  - The per-axis uv for material 2 is `world.zy`, `world.xz`, `world.xy`, times 0.25 per metre.
- A flat ground plane alone does not test the triplanar blend, because it reduces to planar XZ. The check must use a vertical box face.
- CesiumMan's own texture stays out. The Cesium logo has its own licence (see the manifest note).

### 1.9 Unchanged behaviour

- Items with `mesh_id = -1` take the old path.
- These must pass unchanged:
  - Engine `build-pages --check` (game-shot, touch-check), `game-parity`, and the existing `test-game` counts (arena 27, arena_controls 7, arena_camera 9, arena_sfx 19, arena_hud 7, arena_input 9, game_mode 8).
  - Playground `host_check`.
  - Playground parity hashes for arena frames 1–3: 12217565312237657556, 5883669775744707594, 3942389195991980829.
  - Playground parity hashes for Frontier frames 1–3: 12382180788556832807, 11744582151253365717, 1702746564582479634.
- Characters are visual only in step 5. They have no physics bodies, so the Frontier hashes must not move.

### 1.10 Checks: what "done" means

**Engine CI uses synthetic meshes only.** That keeps it free of network access and of asset licences. **Real-asset checks run in playground CI.**

**A. Static mesh pass**
1. The draw-list hash matches between native and wasm. It is FNV-1a over `mesh_id`, instance count, index count, and the first transform rounded to 1e-4.
2. A fixed camera looks at one cube at the origin with colour (0.8, 0.2, 0.2). The centre pixel matches the expected shaded value within `shell/web/pixel_tolerance.json`, on both native and web.
3. The native and web frames agree through the existing parity harness.

**B. Skinning**
1. **Rest-pose identity.** Skinning on the CPU at the rest pose reproduces `root_transform · p` (the non-joint ancestors' Z-up to Y-up conversion), with maximum error below 1e-4. This runs first, in Python in the PR 0 selftest. It catches a wrong matrix order, quaternion order, or missing ancestor. Correction (PR 0): the first draft of this check compared against `p` itself; that is wrong for an asset whose IBMs exclude the ancestors.
2. **Engine synthetic test.** A 2-joint chain, with joint 1 rotated 90° about +Y. A vertex at (1,0,0) with weight 1 on joint 1 must land at (0,0,-1):
   - CPU within 1e-6.
   - GPU vs CPU within 1e-5.
3. **Playground real assets.** Every vertex, GPU vs CPU, maximum difference below 1e-3 m, on both native (lavapipe) and web (swiftshader):
   - CesiumMan clip 0, frames 0, 15, 30, 45 and 60.
   - Fox "Walk", frames 0, 11 and 22.

**C. Textures**
1. **Engine.** A procedural 256x256 checker, sampled with the nearest sampler at texel centres into a 256x256 rgba8unorm target and read back. Every texel equal at mip 0 and mip 4.
2. **Playground.** The same readback of layer 1 at mip 0 and mip 4, compared with Pillow's output from `convert_texture.py`. Maximum channel difference 2 or less.
3. **Triplanar.** The centre of a box's +X face equals the texel at (z, y) · 0.25, within 2.

**Benchmarks.** Record the method only, and leave every number as TBD until it is measured:
- Count skinned CesiumMan instances until a frame exceeds 16.7 ms at 1280x720, on swiftshader and on lavapipe.
- Compute skinning time in µs per 1000 vertices, against the CPU reference.

**Licence.** No CC-BY asset may appear on the live page without a visible attribution. PR D adds `credits.html`, generated from `CREDITS.md`, and a link to it from `index.html`.

### 1.11 PR sequence

The order is strict. Each PR merges green before the next one starts. Every pin bump updates `deps.lock` and `pages.yml` in the same commit.

| PR | Repo | Content |
|---|---|---|
| A0 | wgpu-mojo | `set_vertex_buffer`, `set_index_buffer`, `draw_indexed` on `FrameRenderPass` (wgpu-mojo PR #31). Must merge before A, and A's engine branch then bumps its wgpu-mojo pin. |
| 0 | playground | Converter v2, Python rest-identity check, `convert_texture.py` |
| A | engine | `DrawItem` fields, `MeshRegistry`, static pass, checks A |
| B | engine | Skinning seam, `SKIN_FN`, compute and vertex paths, checks B1–B2 |
| C | engine | Texture array, samplers, materials, triplanar, check C1 |
| D | playground | Pin bump, asset build and loading, Frontier placement, checks B3, C2, C3, credits page |

## Layer 2 (for sonnet): concrete steps

### PR 0: playground, branch `feat/assets-v2`

1. Rewrite `write` and `read_back` in `convert_glb.py` for the v2 layout in 1.4.
   - Pad the JSON with spaces so the blobs start 16-aligned.
   - Zero-pad each blob to 16 bytes.
   - Keep `read_back` able to read v1 as well.
2. Compute `root_transform`.
   - Build a child-to-parent map over all glTF nodes.
   - Walk upward from each root joint through non-joint nodes.
   - Multiply the ancestors' local matrices top-down. Use the node `matrix` if present, otherwise its TRS.
   - If two root joints have different ancestor chains, exit with an error. Step 5 supports one skeleton root.
3. Add selftest checks:
   - Every blob offset is a multiple of 16.
   - Every clip's scale is within 1e-6 of 1.
   - Rest-pose CPU skinning in pure Python, using f32-rounded inputs, has maximum error below 1e-4 against `root_transform · p`. Print the maximum error.
   - If the identity check fails, print per joint the maximum of |global(rest) − inverse(IBM)|.
4. Add `scripts/convert_texture.py`, using Pillow.
   - Arguments: `<in.jpg> <out.ltexture> [--size 256]`.
   - Convert to RGBA8 and resize with Lanczos.
   - Build the mips by repeated 2x2 box average down to 1x1.
   - Write the v1 layout from 1.4.
   - `--selftest` checks:
     - The level count equals log2(size) + 1.
     - Level 0 equals Pillow's resize.
     - Every offset is a multiple of 16.
     - The file reads back equal.
5. Manifest:
   - Add to `tex_concrete_wall_008`: `changes = "resized to 256 and mipmapped by scripts/convert_texture.py"`.
   - Update the CesiumMan and Fox `changes` text to mention v2.
   - Run `--credits`.
6. Paste every selftest output into the PR body.

### PR A: engine, branch `feat/mesh-pass`

1. Read `app/render3d.mojo` and record these in the PR body:
   - The `DrawItem` definition.
   - How WGSL is stored.
   - The depth format.
   - The render-pass structure.
   - The capture path.
2. Add the three `DrawItem` fields with defaults through `__init__` default arguments (U4). Grep every `DrawItem(` call; existing calls keep the defaults.
3. Add `MeshRegistry` with:
   - `add_static(pos, nrm, uv, idx) -> Int`
   - `add_skinned(pos, nrm, uv, joints, weights, idx) -> Int`

   Each method creates one buffer per attribute.
4. Add `MeshPass.draw(encoder, items, view_proj)`.
   - Filter items with `mesh_id >= 0`.
   - Group them by `mesh_id`.
   - Write the instance buffer once per frame.
   - Issue one `drawIndexed` per mesh, with `instanceCount` set to the group size.
   - Call it in the same render pass and depth buffer, after the existing primitives.
5. Add `mesh_draw_hash(items) -> UInt64` and expose it to wasm.
6. Tests:
   - `tests/mesh_pass.mojo` on the CPU side, added to `test-game`. It checks grouping, a hash that is stable across two runs, and that -1 items are excluded.
   - A GPU check next to the existing arena frame check in the parity job: the cube at the origin, compared through `pixel_tolerance.json`.

### PR B: engine, branch `feat/gpu-skinning`

1. Find the CPU reference in ludens-core `geometry` (U1).
   - If its signature takes positions, joints, weights and a palette, use it.
   - Otherwise write `cpu_skin` in `skin_pass.mojo`, in f32, with the k loop running 0..3 in the same order as the WGSL.
2. Add `SKIN_FN` and build the vertex and compute shaders from it.
3. Add `trait Skinning`, `CpuSkinning` and `GpuSkinning`.
   - Dispatch `ceil(n/64)` workgroups.
   - Copy the result to a map-read buffer.
   - On web, poll the way the frame capture does. Never await inside wasm (U6).
4. Add `build_palette(frame, parents, ibm, root_transform) -> List[Float32]`, with 16 floats per joint, column-major. Assert that parents come before children.
5. Add the skinned draw path in `MeshPass`:
   - The 6-buffer pipeline from 1.5.
   - A palette bind group.
   - `pose_id` mapped to a palette base.
6. Add `test_skinning_parity` for checks B1 and B2 on the synthetic chain, and register it as the pixi task `test-skinning`. It runs on native in the parity job and in headless Chrome.

### PR C: engine, branch `feat/texture-pass`

1. `TextureArray`: 256x256xN, rgba8unorm, 9 levels. Layer 0 is generated white. Add `load_layer(i, ltexture_bytes)`, which calls `writeTexture` once per level.
2. Create the main sampler and the test sampler from 1.8.
3. Branch on material in the fragment shader:
   - 0 is today's colour.
   - 1 is uv plus layer.
   - 2 is triplanar plus layer.
4. Check C1: draw a full-screen quad sampling a given layer and mip into an offscreen 256x256 target, then read it back. Do the same for the triplanar box-face case, using a procedural texture. Register the pixi task `test-texture`.

### PR D: playground, branch `feat/frontier-meshes`

1. Pin bump to PR C's merge commit, in `deps.lock` and `pages.yml`. Pin rule: if the engine's wgpu-mojo pin has moved (PR A0), the playground's wgpu-mojo pin (`deps.lock`) moves in the same commit. The playground compiles the engine's `render3d.mojo`, so a mismatch breaks its build. grep for the old wgpu-mojo SHA in both `deps.lock` and any workflow before merging.
2. In `build_page.sh`:
   - Run `fetch_assets.py`.
   - Convert CesiumMan and Fox with `convert_glb.py` (v2).
   - Convert the concrete texture with `convert_texture.py`.
   - Write `build/page/assets/*.l*` and `build/page/assets/index.json` as `{file: {sha256, bytes}}`, with each sha256 computed after conversion.
   - Generate `build/page/credits.html` from `CREDITS.md`.
3. In `page/app.js`:
   - Fetch `index.json`.
   - For each entry, call `loadAsset`, then `stageAsset`, then `playground_host_asset(app, kind, ptr, len)`.
   - Free the staged buffer after the call returns. The export copies the bytes.
   - Add a "Credits" link in `index.html`.
4. In `app/host.mojo`:
   - Read the v2 and `.ltexture` binary directories.
   - Register the meshes and the texture layer.
   - Each frame, sample clip 0 (CesiumMan) and "Walk" (Fox) by time and call `set_palette`.
   - Place the characters, then the ground and boxes with material 2, layer 1.
   - Choose the scale from the bounding box that the convert selftest prints (U10).
5. Add checks B3, C2 and C3 as playground tests run in `pages.yml`.
6. Add a `host_check` line: with input idle, the picture changes between frame 30 and frame 60. This proves the character animates.
7. List the added page bytes in the PR body. The budget is 3 MB.

## Layer 3 (for haiku): commands and checks

**General rule.** If an expected line does not appear, stop and report the full output. Do not loosen a threshold.

### PR 0

```sh
cd /home/user/ludens-playground
git fetch -q origin +refs/heads/main:refs/remotes/origin/main && git checkout -q -B feat/assets-v2 origin/main
python3 scripts/fetch_assets.py
python3 scripts/convert_glb.py --selftest build/assets/src/CesiumMan.glb
python3 scripts/convert_glb.py --selftest build/assets/src/Fox.glb
python3 scripts/convert_texture.py --selftest build/assets/src/concrete_wall_008_diff_1k.jpg
python3 scripts/fetch_assets.py --credits && python3 scripts/fetch_assets.py --check
```

Expected output:
- `fetch_assets.py`: 8 `ok` lines.
- Each `convert_glb.py` run includes the lines `PASS every blob offset is a multiple of 16` and `PASS rest-pose skinning reproduces root_transform * p (max error below 1e-4)`, and ends with `convert_glb selftest: N / N checks`.
- `convert_texture.py` ends with `convert_texture selftest: N / N checks`.
- `--check` prints `assets: 8 entries, manifest and credits OK`.

If the rest-pose identity check fails, read the per-joint diagnostic:
- Error only on the root joint means a missing ancestor transform. Fix step 2.
- Uniform error on every joint means the rest pose is not the bind pose. Build the identity check from inverse(IBM) instead, and record that in the PR body.
- Anything else: stop and report.

### PR A

```sh
cd /home/user/engine-work && git checkout -q main && git pull -q && git checkout -q -b feat/mesh-pass
grep -n "struct DrawItem" -A 25 app/*.mojo
grep -n -i "wgsl\|depth" app/render3d.mojo | head -40
pixi run -e wasm test-game
pixi run -e wasm game-parity
pixi run -e wasm build-pages --check
pixi run -e wasm check-layout
pixi run -e wasm build-wasm
```

Expected output:
- `test-game`: the seven existing counts from 1.9 unchanged, plus `mesh_pass: N / N`.
- `game-parity`: PASS.
- `build-pages --check`: game-shot PASS and touch-check PASS.
- `check-layout`: PASS.
- `build-wasm`: the export count is 29 plus the new exports.

If any existing count changes, stop. The new fields changed old behaviour.

### PR B

Run every PR A command, then:

```sh
pixi run -e wasm test-skinning
```

Expected: `test_skinning_parity: N / N`, with the maximum errors printed, on native and on web.

### PR C

Run every PR A command, then:

```sh
pixi run -e wasm test-texture
```

Expected: `N / N`.

### PR D

```sh
cd /home/user/ludens-playground
E=build/deps/ludens-engine
pixi run --manifest-path $E/pixi.toml -e wasm bash scripts/build_page.sh
ls build/page/assets
python3 -m http.server 8150 --bind 127.0.0.1 --directory build/page >/dev/null 2>&1 &
pixi run --manifest-path $E/pixi.toml -e wasm node scripts/host_check.mjs "$(which google-chrome || which chromium)" "http://127.0.0.1:8150/index.html?offscreen" build/shots/host 150
HOST="$(pixi run --manifest-path $E/pixi.toml -e wasm python3 -c 'import ludens_wasm_rt; print(ludens_wasm_rt.HOST_MJS)')"
pixi run --manifest-path $E/pixi.toml -e wasm bash scripts/check_parity.sh "$HOST"
```

Expected output:
- `ls`: `CesiumMan.lcharacter`, `Fox.lcharacter`, the concrete `.ltexture`, and `index.json`.
- `host_check`: PASS, including the new animated-character line.
- `check_parity.sh`: the 6 hashes from 1.9 unchanged, then `check_wasm: PASS`.

## Risks and open questions

Each item is UNVERIFIED and is settled by the PR named.

| ID | Question | Settled by |
|---|---|---|
| U1 | Does ludens-core `geometry/skinning` exist, and does its signature take a palette? | PR B step 1 |
| U2 | Does CesiumMan have a non-joint ancestor transform? | Answered in PR 0: yes. The Armature and Z_UP ancestors (a 90° rotation) are in `root_transform`, and the IBMs exclude them. Fox has none (identity). |
| U3 | Are read-only storage buffers available in the vertex stage on swiftshader and lavapipe? If not, use the uniform fallback. | PR B CI |
| U4 | Do defaulted `DrawItem` fields compile in Mojo 1.2 across every call site? | PR A step 2 |
| U5 | What depth format and pass structure does `render3d` use? | PR A step 1 |
| U6 | Does map-read readback from wasm work without await, through the capture-style poll? | PR B |
| U7 | Does changing `DrawItem`'s size affect the HUD or the exports? | Existing gates in PR A |
| U8 | Is the added page size within 3 MB? | PR D body |
| U5 | What depth format and pass structure does `render3d` use? | Answered: `Depth32Float`, with `begin_surface_clear_pass_depth` returning `FrameRenderPass` (wgpu-mojo). WGSL is stored as a `comptime` string in `app/render3d.mojo`. The capture path is `app_request_capture` / `app_capture_ptr`. |
| U9 | Does rgba8unorm without sRGB look darker or washed out? Accepted for step 5; revisit afterwards. | — |
| U11 | `FrameRenderPass` (what `begin_surface_clear_pass_depth` returns) had no vertex, index or indexed draws. | Settled by wgpu-mojo PR #31: `set_vertex_buffer`, `set_index_buffer` and `draw_indexed` added to `FrameRenderPass`. The web layer already implements all three (`implemented.txt`, `webgpu_impl.mjs`). |
| U10 | Character scale relative to the Frontier's metres. | Bounding box printed by the PR 0 selftest |

Do not rely on the advisor alone for the UNVERIFIED items. If a check in a PR contradicts the note, fix the note in that PR.

Steps 6–8 also get their design notes from the advisor, per the user. When step 5 is done, ask for step 6's note the same way you asked for this one.
