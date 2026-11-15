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
