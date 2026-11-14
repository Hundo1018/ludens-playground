# Step 7: crowd (planning note, 2026-11-14)

Source: `docs/PLAN.md` step 7 ("Entities through `ecs.World`, flow field for movement, instanced skinned draws, HUD switch
between backends. Count from a measured budget, not a promise.").

## What exists now (verified)

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

- CesiumMan has 19 joints, so one instance takes 19 palette matrices. The palette allows 4096 / 19 = 215 instances.
- The mesh record allows 2048 instances. The palette binds first: 215 skinned CesiumMan instances per frame.
- `skin_draw.mojo` says the palette is "64 instances x 64 joints" for the step 5 capacity. That comment is for 64 joints;
  at 19 joints the capacity is 215, not 64.

## Measurement (required before the step is done)

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
