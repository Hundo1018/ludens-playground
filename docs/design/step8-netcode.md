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

## Transport: decided (in-process)

GitHub Pages serves only static files, so no server process can run for the deployed page. ludens-core's netcode is
in-process already:

- `SimLink` (`gameplay/netcode.mojo:910`) is a deterministic in-memory delayed queue. `send(now, msg)` stores the bytes
  with an arrival tick of `now + latency + uniform[0, jitter]`, drops a message with probability `loss`, and `deliver(now)`
  returns the arrived bytes in (time, send order). The seed fixes it, so a test replays exactly.
- `NetPeer` (`gameplay/netcode.mojo:339`) works on bytes: `submit`, `outgoing(to_node)`, `receive(from_node, msg)`,
  `update(target)`. No sockets appear anywhere in it.

So the link is in-process. The "second module" of the plan is a second Mojo source module (`app/net_server.mojo`, planned)
compiled into the same `host.wasm`: the server `SnapshotServer` and the client `SnapshotClient` exchange bytes through a
`SimLink`. A Worker with its own wasm instance would add `postMessage` plumbing for no behaviour the test needs; the
server is authoritative by construction, since the client only sends inputs and applies snapshots.

## What the playground adds

- A second module (`app/net_server.mojo`, planned) holding the authoritative `SnapshotServer` for the Frontier's world,
  and a client that applies snapshots to the page's characters.
- The lag-compensated hit: `rewind_ray_cast` against `PoseRing` for the hit test.

## Open before the step starts

- The `NetSim` for the Frontier's world. `ArenaSim` is the arena's; the Frontier's simulation (crowd from step 7 plus the
  player) has no `NetSim` yet.
- `SimLink` latency: the test must inject a delay and check that the snapshot client converges. Not designed yet.

## Done means (from `docs/PLAN.md`)

Its PR merged, its check green from a fresh clone, and the Pages build serving the change. For this step the check is:
a native two-peer run converges (equal state hash at a tick), and a lag-compensated hit lands on the pose the shooter
saw, with the rewound pose checked against the recorded one.
