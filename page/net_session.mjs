// The Frontier's netcode session with the server in a Worker (plan step 8, second module).
// The page holds the clients (playground_host_client_* in host.mojo); the server is net_server.worker.mjs running
// server.wasm. Each frame runs the same steps in the same order as app/net_frontier.mojo run_session: clients submit,
// clients send, the link delivers to the server, the server updates and sends, the link delivers to the clients.
// The link is a fixed delay: a message sent at frame f arrives at f + latency (no jitter, no loss), in send order.

export async function runWorkerSession(host, { serverUrl = "./server.wasm", workerUrl = "./net_server.worker.mjs",
    players = 3, T = 120, latency = 4, maxFrames = 5000 } = {}) {
  const rt = host.rt;
  const x = rt.exports;
  const worker = new Worker(workerUrl, { type: "module" });
  const pending = new Map();
  let seq = 0;
  worker.onmessage = (e) => { const done = pending.get(e.data.id); pending.delete(e.data.id); done(e.data); };
  const call = (msg, transfer) => new Promise((resolve) => {
    const id = ++seq;
    pending.set(id, resolve);
    worker.postMessage({ ...msg, id }, transfer ?? []);
  });
  try {
    const bytes = await (await fetch(serverUrl)).arrayBuffer();
    const init = await call({ op: "init", bytes, players }, [bytes]);
    if (!init.ok) throw new Error("server module: " + init.error);

    const clients = [];
    for (let p = 0; p < players; p++) {
      const h = x.playground_host_client_new(p);
      if (h === 0n) throw new Error("playground_host_client_new refused node " + p);
      clients.push(h);
    }
    // FIFO per direction: sends are made in frame order with one latency, so the queue head is the next to arrive
    const up = Array.from({ length: players }, () => []);
    const down = Array.from({ length: players }, () => []);
    const due = (q, now) => { const out = []; while (q.length && q[0].at <= now) out.push(q.shift().data); return out; };
    const allAt = () => clients.every((h) => x.playground_host_client_newest(h) >= T);

    let f = 0;
    for (; f < maxFrames; f++) {
      for (let p = 0; p < players; p++) {
        if (x.playground_host_client_newest(clients[p]) < T) x.playground_host_client_submit(clients[p], f, T);
      }
      for (let p = 0; p < players; p++) {
        const n = x.playground_host_client_outgoing(clients[p], players);
        up[p].push({ at: f + latency, data: rt.bytes(x.playground_host_client_out_ptr(clients[p]), n).slice() });
      }
      for (let p = 0; p < players; p++) {
        for (const data of due(up[p], f)) await call({ op: "receive", from: p, data });
      }
      const upd = await call({ op: "update", target: Math.min(f + 1, T) });
      if (!upd.ok) throw new Error("server update failed (code " + upd.code + ")");
      for (let p = 0; p < players; p++) {
        const out = await call({ op: "outgoing", to: p });
        down[p].push({ at: f + latency, data: out.data });
      }
      for (let p = 0; p < players; p++) {
        for (const data of due(down[p], f)) {
          const ptr = rt.alloc(data.length);
          rt.put(ptr, data);
          const r = x.playground_host_client_receive(clients[p], players, ptr, data.length);
          rt.free(ptr);
          if (r !== 0) throw new Error("client " + p + " refused a message (code " + r + ")");
        }
      }
      if (allAt()) break;
    }
    const state = await call({ op: "state" });
    return {
      ok: true,
      frames: f,
      tick: state.tick,
      serverHash: state.hash,
      clientsAtT: allAt(),
      clientTicks: clients.map((h) => x.playground_host_client_newest(h)),
      clientHashes: clients.map((h) => x.playground_host_client_hash(h)),
    };
  } finally {
    worker.terminate();
  }
}
