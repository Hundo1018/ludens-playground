# Step 7: crowd (2026-11-14)

Source: `docs/PLAN.md` step 7 ("Entities through `ecs.World`, flow field for movement, instanced skinned draws, HUD switch
between backends. Count from a measured budget, not a promise.").

## Built

- Entities: `app/crowd.mojo`. Members are ecs entities (`CrowdPos`, `CrowdPhase`) in a `SparseSetBackend` world and a
  `NaiveBackend` world. The live one is stepped and drawn; the HUD switch rebuilds the other from it.
- Movement: the engine's `FlowField` (ludens-core `nav/path.mojo`) over a navmesh baked from the arena's floor (the arena's
  bake settings), goal at the centre; members stop within 0.6 m. One `FlowField.build` per crowd.
- Instanced skinned draws: one CesiumMan instance per member, each at its own clip phase; one palette per member in the
  palette buffer (`skin_draw.mojo`).
- HUD (page): a crowd button adds 64 members or removes them (off by default); a backend button flips the live backend.
- `tests/crowd_native.mojo`: 5/5. Members walk toward the goal (mean distance drops by over 1 m in 300 ticks); the two
  backends agree exactly after 300 ticks; a switch at tick 150 leaves the result unchanged.
- `host_check`: a 20-member crowd is built, the switch goes naive then sparse-set, and the crowd is removed.

## Frame-time measurement

`scripts/crowd_bench.mjs`: headless Chrome, SwiftShader (software), canvas 1280 x 720, `?offscreen&bench=1`, and the
frame rate uncapped (`--disable-gpu-vsync --disable-frame-rate-limit`). The bench mode draws the whole scene into an
offscreen target every frame, with no readback. A sample is the wall-clock gap between consecutive frame-counter changes,
60 samples per count.

| extra members | median frame ms | p90 ms |
|---:|---:|---:|
| 0 | 17.20 | 19.60 |
| 213 | 17.50 | 20.60 |

What these numbers are, and are not:

- They are the draw-mode frame interval. They are not verified to include the GPU's execution of the frame. The
  submission returns before the software rasteriser runs, so the interval may not wait for the draw.
- A synchronous measurement was tried (`SYNC=1`: each sample is a capture that waits for the frame's GPU completion). It
  gave a median of 641.50 ms (p90 3053.40 ms) at 0 members, and the capture for 213 members never completed. So the
  readback path cannot time a frame on this machine, and the synchronous numbers measure the readback, not the draw.
- Therefore: the frame interval is 17.2 ms at 0 members and 17.5 ms at 213. Whether the crowd's cost is +0.3 ms, as the
  interval suggests, is not established. No budget is established on this machine. Earlier conclusions drawn from these
  intervals ("the scene is over budget", "no count passes") are withdrawn as measured results.

## Earlier numbers that are not valid

An earlier table (median 16.4 to 17.0 ms, budget 160) was taken with the frame rate held at the display's 60 Hz clock, and
without the scene drawing: those frames were not GPU-bound. The vsync-capped medians cannot separate counts, and the
budget derived from them was a post-hoc choice. Both are withdrawn. The uncapped table above replaces them.

Frame-rate flags: `--disable-gpu-vsync --disable-frame-rate-limit` took the baseline from 16.7 ms to 6 ms in the
non-drawing mode, so they do lift the cap. In the drawing mode the base scene is what dominates.

## Not measured

- A GPU-inclusive frame time. The synchronous readback path cannot time a frame here (see above), and there is no GPU
  on this machine or in CI. This is blocked by the environment: a GPU-timed measurement needs a runner with a GPU and a
  timestamp or completion query the page can read.

## Open decisions

- Whether the crowd should use a GPU-side flow field or stay on the CPU: the CPU part is ECS plus the palette builds, and
  its cost is not separated from the scene in the measurement above.
