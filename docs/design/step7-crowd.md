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

`scripts/crowd_bench.mjs`: headless Chrome, SwiftShader (software), canvas 1280 x 720, `?offscreen&bench=1`. The bench
mode draws the whole scene into an offscreen target every frame, with no readback. A frame's time is the wall-clock gap
between consecutive frame-counter changes, 60 samples per count.

| extra members | median frame ms | p90 ms |
|---:|---:|---:|
| 0 | 17.20 | 19.60 |
| 213 | 17.50 | 20.60 |

Reading:

- The scene without any members takes 17.2 ms per frame on this machine. That is over the 16.7 ms budget before the
  crowd is added. So under the rule "largest count whose uncapped median stays under 16.7 ms", no count passes here.
- The crowd's marginal cost is about 0.3 ms for 213 members (within the sampling noise of a 17 ms median). The ECS
  movement and the palette builds are inside these numbers.
- The 213 figure is the palette ceiling: 4096 matrices / 19 joints, so the palette, not the bench, limits the count.

## Earlier numbers that are not valid

An earlier table (median 16.4 to 17.0 ms, budget 160) was taken with the frame rate held at the display's 60 Hz clock, and
without the scene drawing: those frames were not GPU-bound. The vsync-capped medians cannot separate counts, and the
budget derived from them was a post-hoc choice. Both are withdrawn. The uncapped table above replaces them.

Frame-rate flags: `--disable-gpu-vsync --disable-frame-rate-limit` took the baseline from 16.7 ms to 6 ms in the
non-drawing mode, so they do lift the cap. In the drawing mode the base scene is what dominates.

## Not measured

- A GPU. There is no GPU on this machine or in CI. The budget for a GPU is open, and needs a runner with one. This is
  blocked by the environment, not work left to do here.
- A budget on a machine that draws the base scene under 16.7 ms.

## Open decisions

- Whether the crowd should use a GPU-side flow field or stay on the CPU: the CPU part is ECS plus the palette builds, and
  its cost is not separated from the scene in the measurement above.
