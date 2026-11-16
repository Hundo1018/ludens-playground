# Reference baselines (2026-11-15)

The user chose three games as the reference for the Frontier: Assassin's Creed Unity, Red Dead Redemption 2 and
Battlefield 1. Each line below takes one thing those games are known for, states the source, and turns it into a check that
runs on this page. Where a source gives no number, the check uses the original Frontier plan's acceptance
(`docs/frontier_plan.md` in ludens-engine) and says so. Engine features come first: the redo uses what ludens-core already
has (cloth, rope, joints, ragdoll, behavior tree, perception, IK, motion matching) instead of the workarounds of the review
work order.

## Sources

- AC Unity, GDC 2015, "Massive Crowd on Assassin's Creed Unity: AI Recycling" (Francois Cournoyer): a pool of 40 full AIs
  and 120 high-resolution models, the rest of the crowd low-resolution, up to 10,000 NPCs on screen; NPCs move between the
  levels without the player seeing it. https://www.gdcvault.com/play/1022141/Massive-Crowd-on-Assassin-s
- AC Unity, crowd size from press: 5,000 or more on screen, against about 200 in earlier games.
  https://www.gamespot.com/articles/assassins-creed-unity-can-support-crowds-of-30-000/1100-6421542/
- RDR2, Rockstar's technology director: Euphoria is used for physics-based reactions of people and animals.
  https://wccftech.com/rockstar-euphoria-evolved-rdr2/
- Battlefield 1: 64-player matches with large-scale environmental destruction on Frostbite.
  https://www.dsogaming.com/news/battlefield-1-server-browser-confirmed-conquest-mode-returns-64-player-matches-vehicle-details
- No source found gives Battlefield 1's destruction replication internals; the check below states its own rule.

## Baselines and checks

| Ref | Game feature | Engine features | Check on this page |
|---|---|---|---|
| A | AC Unity: 40 full AIs, 120 high-res models, the rest low-res | `ecs.World` crowd, `nav.crowd` ORCA, shared pose table for the far tier | Per-tier counts exported: near at most 40, mid at most 120, far the rest. At least 2,000 members drawn on the page; frame time measured in the same session with the crowd off and on. Worker and page hashes equal. |
| A2 | AC Unity: NPCs move between levels unseen | tier change by distance with hysteresis | A member that crosses a tier boundary keeps its position (no jump larger than one step). |
| B1 | Original stage 2: destructible wall and a jointed machine | `EmbedWorld.add_hinge_joint`, `add_fracture_box` | A pendulum on a hinge swings into the quarry wall; fragments go from 0 to more than 0 after the hit. |
| B2 | Original stage 2: rope | `EmbedWorld` capsules with ball or distance joints | Rope length stays within 5 % of its rest length over 600 ticks. |
| B3 | Original stage 2: cloth flag | `physics.cloth.MeshCloth` | The flag's free corner moves more than 0.1 m from its rest position under gravity; the pinned edge stays within 1 mm. |
| B4 | RDR2: physics-based reactions | `gameplay.ragdoll.Ragdoll` | A guard contact turns the guard into a ragdoll; its root height drops by more than 0.5 m within 2 s. |
| C | Battlefield 1: destruction synchronized across players | `SnapshotServer` / `SnapshotClient`, fracture events | At 4-tick latency, the fragment-state hash on the server and both clients is equal once the fragments settle. |
| D1 | AC Unity crowd events, RDR2 residents | `ai.bt.BehaviorTree` | Residents run a behavior tree; the count of state transitions is exported and is more than 0 over 600 ticks. |
| D2 | Guard sight | `ai.perception.Perception` | The guard detects a player inside its view cone with line of sight and not a player behind it. |
| E1 | Motion matching (original stage 4) | `MotionDB`, the code of `motion_match_native` | The protagonist's chosen clip index changes with its speed on the page. |
| E2 | Foot IK (original stage 4) | `procedural.ik.two_bone` | Foot height error on a slope stays under a stated bound. |

Each item is one PR with a browser check that runs three times in CI. A check of something stepped in the draw path does not
use `?offscreen`.

## Results (2026-11-16)

| Ref | PR | Status | Measured | Deviation / engine issue |
|---|---|---|---|---|
| A | #82 | met for counts; frame time not comparable to AC Unity | 2,000 members drawn: tiers 40 / 120 / 1,840, palette 3,886 of 4,096 matrices, none dropped. Step-7 bench (12 samples, town off): 0 members 171.5 ms, 2,000 on the main thread 1,441.8 ms, 2,000 in the worker 1,620.0 ms (about 0.64 ms per member, against about 4.5 ms before the tiers). | The engine limits were raised (ludens-engine #70); the shared pose table is the playground's (ludens-engine #71). W11's frame-time item stays NOT MET (`docs/PLAN.md`). |
| A2 | none | not done | A tier change by distance has no hysteresis and no position check yet. | |
| B1 | #83, count fixed in #87 | met | A 2,000 kg bob on a 9 m hinge: the standing wall makes 0 events alone, 22 with the bob (native, counted per tick); the page: 15 events, 40 fragments. A 500 kg bob makes 0. | #87: the event count summed a list that grows within a frame; the 3,693 first reported was that bug. |
| B2 | #84 | met | Rope length 1,015 to 1,029 permille of rest; the end swings 2,251 mm. | |
| B3 | #84 | met | The banner's free corner moves 3,433 mm; the pinned edge 0 µm. | A cloth cell is drawn as a thin box: there is no dynamic mesh (ludens-engine #73). |
| B4 | #86 | met | After the guard's contact the figure's pelvis goes from 962 to 993 mm down to 194 to 195 mm within about 0.7 s (three runs). | A six-body figure on `EmbedWorld` ball joints, not `gameplay.ragdoll` (ludens-engine #74). The town now steps with the simulation, not the draw. |
| C | #88 | met | Latency 4, and latency 4 / jitter 3 / 10 % loss: the server's and both clients' read-back hashes are equal at tick 240; the fragment hash is unchanged over the last 30 ticks; 73 events; 40 of 40 fragments moved on every peer; 45,158 bytes over the break against 2,048 settled. Native and page wasm agree. | The state is quantised fragment poses, not `EmbedWorld.save` (refused with a fracture; ludens-engine #75); rotations go through `teleport` on a scratch world so the read-back matches. Clients display only. |
| D1 | #85 | met | 62 transitions over 1,200 ticks (native); 25 on the page; a resident next to the player watches. | |
| D2 | #85 | met | The guard sees a player 12 m ahead and not 12 m behind; on the page it sees the player in the square. | |
| E1 | #89 | in review | Probes match walks up to 2.5 m/s and the run from 3.0 m/s. On the page the guard is on the run in 122 to 124 samples above 5 m/s and on a walk below 1.5 m/s; the 24 residents stay on walks. | Applied to the town's CesiumMen; the protagonist is the Fox, which has no CMU clips. No idle clip. |
| E2 | #90 | in review | The slow walk on a 20 degree ramp: worst ankle error 0.13 to 0.14 mm with IK, 91.7 to 93 mm without (native and page). | `foot_plant` and `two_bone` give positions; turning them into joint rotations is the playground's (ludens-engine #76). |

Not met against the games themselves: AC Unity's thousands of NPCs at playable frame rates (A's frame time on SwiftShader is
over a second at 2,000 members), and A2.
