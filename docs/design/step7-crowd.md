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

## Frame-time measurement (GPU-inclusive, 2026-11-14)

Device: headless Chrome, SwiftShader (software Vulkan-class WebGPU), canvas 1280 x 720, frame rate uncapped
(`--disable-gpu-vsync --disable-frame-rate-limit`), the page in bench-draw mode (`?offscreen&bench=1`: the whole scene is
drawn into an offscreen target every frame, no readback).

Method (`GPU_SYNC=1` in `scripts/crowd_bench.mjs`): the WebGPU queue is reached through the page's runtime handle table
(`window.host.wrt`, handles of kind `queue`). A sample is the time between successive `GPUQueue.onSubmittedWorkDone()`
resolutions, divided by the number of frames rendered in between. A completion waits for all work queued before it, so once
the queue is saturated the sample is the GPU's time per frame.

| extra members | GPU time per frame, median (samples) |
|---:|---|
| 0 | 17.58 ms (5 samples; the earlier 5 samples gave 17.46 ms median) |
| 160 | not obtained: the frame loop stalled under GPU backpressure; no sample completed in several minutes |
| 213 | not run (depends on 160) |

Reading:

- The scene without any members takes 17.5 to 17.6 ms of GPU time per frame on this device. That is over the 16.7 ms
  budget before any member is added. The rule "largest count whose GPU-inclusive median stays under 16.7 ms" therefore
  has no passing count on this device: **no crowd budget exists on this device** (measured).
- The earlier draw-mode interval (17.2 ms at 0 members) matches this GPU time, which suggests the free-running frame interval
  was limited by the GPU, not by the display.
- The crowd's own cost is not measured. The 160-member frame does not complete a sample under this method, so no statement
  about the crowd's marginal cost is made.

## Earlier numbers that are not valid

An earlier table (median 16.4 to 17.0 ms, budget 160) was taken with the frame rate held at the display's 60 Hz clock, and
without the scene drawing: those frames were not GPU-bound. The vsync-capped medians cannot separate counts, and the
budget derived from them was a post-hoc choice. Both are withdrawn. The uncapped table above replaces them.

Frame-rate flags: `--disable-gpu-vsync --disable-frame-rate-limit` took the baseline from 16.7 ms to 6 ms in the
non-drawing mode, so they do lift the cap. In the drawing mode the base scene is what dominates.

## Not measured

- The crowd's marginal GPU cost (the 160-member frame did not complete a sample; the cause, a stall under backpressure, is
  not diagnosed).
- A real GPU. This is a software rasteriser; a GPU would be a different budget.

## Open decisions

- Whether the crowd should use a GPU-side flow field or stay on the CPU: the CPU part is ECS plus the palette builds, and
  its cost is not separated from the scene in the measurement above.
