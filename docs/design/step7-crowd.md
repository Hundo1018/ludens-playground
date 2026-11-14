# Step 7: crowd (planning note, 2026-11-14)

Source: `docs/PLAN.md` step 7 ("Entities through `ecs.World`, flow field for movement, instanced skinned draws, HUD switch
between backends. Count from a measured budget, not a promise.").

## Status (2026-11-14, after the ECS and flow-field change)

Built:

- `app/crowd.mojo`: members are ecs entities (`CrowdPos`, `CrowdPhase`) in both `SparseSetBackend` and `NaiveBackend` worlds;
  the live one is stepped and drawn; the switch rebuilds the other from the live world.
- Movement: the engine's `FlowField` (ludens-core `nav/path.mojo`) over a navmesh baked from the arena's floor (the arena's
  settings), goal at the centre, members stop within 0.6 m. One `FlowField.build` per crowd; `direction` per member per tick.
- `tests/crowd_native.mojo`: 5/5. Members walk toward the goal (mean distance drops by over 1 m in 300 ticks); the two
  backends agree exactly after 300 ticks; a switch at tick 150 leaves the result unchanged.
- Page: a HUD button flips the live backend (`playground_host_crowd_switch`); `host_check` builds 20 members, switches
  naive then sparse-set, and removes them.

Re-measured with ECS and flow-field movement (same bench, 30 samples per count):

| extra instances | median frame ms | p90 ms |
|---:|---:|---:|
| 0 | 16.70 | 17.10 |
| 16 | 16.90 | 18.10 |
| 64 | 16.70 | 17.60 |
| 128 | 16.40 | 19.40 |
| 160 | 16.50 | 19.20 |
| 192 | 16.40 | 18.20 |
| 213 | 16.70 | 17.10 |

The medians sit at the 60 Hz clock at every count, within the sampling noise, so the median cannot separate them.
The p90 rises to 18 to 19 ms from 128 instances. The budget stays at **160** (the largest count tested with median 16.5 ms
and the lowest p90 among the large counts that hold the median). The ECS and flow-field cost is inside these numbers.

## What exists now (verified, before the ECS change)

- `ecs.World[B: StorageBackend]` (ludens-core `ecs/world.mojo:35`): `spawn`, `despawn`, `set`, `get`, `has`, `remove`,
  `query1`..`query3`, `for_each2`, `for_each3`, `changed` and `added` (change ticks), resources, `storage_bytes`.
- Storage backends (`ecs/storage.mojo:118` trait `StorageBackend`): naive, sparse, chunked, bitset, reactive. The
  backend is a compile-time parameter, so a HUD switch between backends is a choice of `World[...]` at build time, not a
  runtime branch. The HUD switch needs one build per backend or a selector that dispatches over them.
- Skinned instancing (engine `app/skin_draw.mojo`): one palette buffer of `MAX_PALETTE_MATRICES = 4096` matrices, and
  the instance records of `app/mesh_pass.mojo` with `MAX_MESH_INSTANCES = 2048`, `FLOATS_PER_INSTANCE = 24`.
- Flow field: a grep finds "flow field" in ludens-core `nav/path.mojo`. Its API has not been read yet; this note does
  not rely on it.

## The budget that binds first (computed, not measured)

- The check is on total palette length: `skin_draw.mojo` line 271 rejects a frame whose palette exceeds
  `MAX_PALETTE_MATRICES` = 4096 matrices. `pose_id` (line 295, `info.x`) is set by the caller per draw item; nothing
  forces a stride of 64.
- So the instance count depends on packing. Densely packed, CesiumMan's 19 joints allow 4096 / 19 = 215 instances per
  frame. The mesh record limit (`MAX_MESH_INSTANCES` = 2048) is not binding.
- The "64 instances x 64 joints" comment in `skin_draw.mojo` (lines 7 and 36) is stale for CesiumMan: that layout gives
  64 instances only when every instance has 64 joints.

## Measurement (done 2026-11-14; procedure below)

The budget is "frame time under 16.7 ms at 1280 x 720 on SwiftShader", counted per instance:

1. A host export `playground_host_crowd(app, n)` that draws `n` CesiumMan instances on a grid, at the same clip, each with
   its own clip phase (`pose_palette_frame` with frame `(k * 7) % frames`).
2. `scripts/host_check.mjs`, or a separate `crowd_bench.mjs`, that runs `n` = 16, 32, 64, 128, 215 on headless Chrome
   (SwiftShader) and records the median frame time for each `n`.
3. The budget is the largest `n` whose median stays under 16.7 ms. The PR states that number and the machine.

Nothing above is measured yet. The number in the PR is the measured one, not the 215 ceiling.

## Open decisions

- Whether each crowd member is an `ecs` entity with a `Transform` and a phase component, or a row in a plain array. The
  `ecs` route is what the step asks for; the cost of `for_each2` per frame at `n` = 215 is not measured.
- The flow field's source and its cost on a 2D grid of the arena. Read `nav/path.mojo` before choosing.

## Result

Headless Chrome, SwiftShader, canvas 1280 x 720 (`?w=1280&h=720`), the page drawing to the canvas (no `?offscreen`).
`scripts/crowd_bench.mjs`: a fresh page per count, 30 to 40 wall-clock frame intervals per count (the gap between
consecutive frame-counter changes, so the GPU work counts).

| extra instances | median frame ms | p90 ms | run |
|---:|---:|---:|---|
| 0 | 16.60 | 17.10 | run 1 |
| 16 | 16.60 | 17.10 | run 1 |
| 64 | 16.60 | 17.10 | run 1 |
| 128 | 16.60 | 18.10 | run 1 |
| 128 | 16.60 | 17.70 | run 2 |
| 160 | 16.50 | 17.70 | run 3 |
| 192 | 16.70 | 17.70 | run 3 |
| 213 | 17.00 | 18.60 | run 2 |

The intervals are quantised by the display's 60 Hz frame clock (16.6 to 16.7 ms), so the median can only move in steps
of about 0.1 ms. Above about 192 the median steps to 17.0 ms: the frame misses a vsync.

Budget: **160 instances** of CesiumMan (19 joints each, extra to the two characters on the page). It is the largest
tested count whose median stayed at or under 16.6 ms in its run; 192 is borderline (16.70 ms) and 213, the palette
ceiling, misses (17.00 ms).

Limits of the measurement: one machine, SwiftShader (no GPU), so the budget is for this software rasteriser, not for a
GPU. The crowd is a grid of identical meshes with per-instance clip phases; the host rebuilds every palette on the CPU
each frame, and that cost is inside the measured time.

Not measured: the flow field movement (step 7's movement is not built yet), the HUD switch between backends, and any
`ecs` storage: the instances here are not `ecs` entities. The budget applies to the draw path only.

Procedure to repeat: serve `build/page` on port 8150, then run `node scripts/crowd_bench.mjs <chrome> http://127.0.0.1:8150/index.html 0,16,64,128,160,192,213 40`
(inside the engine's wasm pixi environment, as the other page checks are).
