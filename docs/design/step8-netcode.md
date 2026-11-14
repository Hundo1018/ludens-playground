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

## Status (2026-11-14)

Built:

- `app/net_frontier.mojo`: `FrontierSim` implements ludens-core's `NetSim`: N players on the floor, positions in integer
  millimetres (exact on native and wasm), FNV hash, byte save and load. `run_session` runs one server and N clients over
  `SimLink`s (up and down), as ludens-core's own test does.
- `TargetRing` and `shot_hits`: a lag-compensated shot tested at the tick the shooter saw. It raises when that tick has
  left the ring.
- `tests/frontier_net_native.mojo`: 7/7. A clean link (latency 3) and a bad one (latency 4, jitter 3, 10 % loss) both
  reach tick 120 on every client and equal the reference run's hash on every client and the server. Shot checks: a shot
  at tick 4 hits, the same shot at tick 10 misses, tick 2 (left the ring) is refused.
- Page: `playground_host_net_check` runs the lossy session in wasm and returns the reference hash modulo 1000000007;
  `host_check` compares it with native: 765407476 on both.

Deviations from the plan text:

- Lag compensation is `shot_hits` in the playground, not the engine's `rewind_ray_cast`. That function needs a
  `ContactScene6` of colliders; the Frontier's world has positions only. The history ring and the raise-when-evicted rule
  are the same idea.
- The page runs the session as a check, with no on-screen netcode. The client's view on the page is not wired to the
  crowd or the players yet. That is the next step after this one.

Not done: the Frontier's `NetSim` is positions only (no movement rules beyond the clamp, no hits in the session, no crowd
or characters in the state). The crowd from step 7 is not part of the networked state.

## Lag-compensated shots over the link (added 2026-11-14)

- `run_shot_session` runs the same server and three clients over the lossy links (latency 4, jitter 3, 10 % loss). The
  server records every player's position on every tick into a `TargetRing` (capacity 64). Client 0 shoots at player 1
  from its own position on the first frame where it shows an older tick (`seen`) and player 1 has moved away since.
- Measured (one run, seed 2026): client 0 showed tick 15 while the server was at 23. Player 1 was 1250 mm ahead at tick 15
  and 2500 mm ahead at tick 23; the reach is 1875 mm. The compensated shot (origin and target at tick 15) hits; the same
  shot at tick 23 misses.
- The earlier shot checks in `tests/frontier_net_native.mojo` (tick 4 hits, tick 10 misses, tick 2 refused) use a ring
  filled by hand, so they test `shot_hits` alone. The session checks are the ones that depend on latency.
- On the clean link the scripted motion never gives a frame where player 1 moves away from client 0 between the two
  ticks, so that check was dropped rather than tuned.
