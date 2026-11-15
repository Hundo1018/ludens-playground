// The range server (plan step 8, second module): server.wasm (app/server_host.mojo) runs in this Worker. The page's
// clients send their bytes here and take the snapshot bytes back; the link delay is applied on the page (net_session.mjs).
import { instantiate } from "./host.mjs";

let rt = null;
let handle = 0n;

const reply = (id, body, transfer) => postMessage({ id, ...body }, transfer ?? []);

// one request per message: { id, op, ... }; every reply carries the id it answers
self.onmessage = async (e) => {
  const m = e.data;
  try {
    if (m.op === "init") {
      rt = await instantiate(m.bytes, { libs: [] });
      handle = rt.exports.playground_server_new(m.players);
      if (handle === 0n) throw new Error("playground_server_new refused " + m.players + " players");
      return reply(m.id, { ok: true });
    }
    const x = rt.exports;
    if (m.op === "receive") {
      const p = rt.alloc(m.data.length);
      rt.put(p, m.data);
      const r = x.playground_server_receive(handle, m.from, p, m.data.length);
      rt.free(p);
      return reply(m.id, { ok: r === 0, code: r });
    }
    if (m.op === "update") {
      const r = x.playground_server_update(handle, m.target);
      return reply(m.id, { ok: r === 0, code: r, tick: x.playground_server_tick(handle) });
    }
    if (m.op === "outgoing") {
      const n = x.playground_server_outgoing(handle, m.to);
      const data = rt.bytes(x.playground_server_out_ptr(handle), n).slice();
      return reply(m.id, { data }, [data.buffer]);
    }
    if (m.op === "state") {
      return reply(m.id, { ok: true, tick: x.playground_server_tick(handle), hash: x.playground_server_hash(handle) });
    }
    throw new Error("unknown op " + m.op);
  } catch (err) {
    reply(m.id, { ok: false, error: String((err && err.message) || err) });
  }
};
