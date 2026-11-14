# Step 8: range networking (planning note, 2026-11-14)

Source: `docs/PLAN.md` step 8 ("Authoritative server in a second module, `SnapshotServer` / `SnapshotClient`, `SimLink`
latency controls, lag-compensated hits. Reuses the engine's `gameplay/netcode`.").

## What exists now (verified, ludens-core `gameplay/netcode.mojo`)

- `SnapshotServer[S: NetSim](NetPeer)` (line 652) and `SnapshotClient[S: NetSim](NetPeer)` (line 765): snapshots are
  delta-encoded against a base (`delta_encode` line 611, `delta_decode` line 632).
- `SimLink` (line 910): the latency controls.
- `PoseRing` (line 875) and `rewind_ray_cast` (line 896): lag compensation. The server keeps a ring of poses and tests
  a hit against the pose at the shooter's time.
- `InputValidator` (line 844) and `motion_plausible` (line 866): server-side input checks.
- Also present: `LockstepPeer` (line 389), `RollbackPeer` (line 446), and `ArenaSim(NetSim)` (line 252), which is the
  existing `NetSim` implementation to copy the shape from.

## What the playground adds

- A second module (`app/net_server.mojo`, planned) holding the authoritative `SnapshotServer` for the Frontier's world,
  and a client that applies snapshots to the page's characters.
- The lag-compensated hit: `rewind_ray_cast` against `PoseRing` for the hit test.

## Open before the step starts

- The transport. ludens-core's `NetPeer` and the encode functions work on bytes; they do not open sockets. The page has
  no server in the browser. The step needs a decision: a WebSocket server outside the page (a Node process in the
  repository, or a relay), or a local two-peer harness that the test drives in one process. Decide with the advisor
  before writing code.
- The `NetSim` for the Frontier's world. `ArenaSim` is the arena's; the Frontier's simulation (crowd from step 7 plus the
  player) has no `NetSim` yet.
- `SimLink` latency: the test must inject a delay and check that the snapshot client converges. Not designed yet.

## Done means (from `docs/PLAN.md`)

Its PR merged, its check green from a fresh clone, and the Pages build serving the change. For this step the check is:
a native two-peer run converges (equal state hash at a tick), and a lag-compensated hit lands on the pose the shooter
saw, with the rewound pose checked against the recorded one.
