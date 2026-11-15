// The step-7 crowd in a Worker (plan W11): crowd/crowd.wasm (app/crowd_host.mojo) runs the same CrowdState as the page's
// host. The page sends the hub's pillar boxes once, then asks for steps and reads the rows back.
import { instantiate } from "./host.mjs";

let rt = null;
let x = null;
let handle = 0n;

self.onmessage = async (e) => {
  const { id, op } = e.data;
  try {
    if (op === "init") {
      const bytes = await (await fetch("./crowd/crowd.wasm")).arrayBuffer();
      rt = await instantiate(bytes, { libs: [] });
      x = rt.exports;
      const boxes = Float32Array.from(e.data.boxes); // 6 per box (the page sends a plain array)
      const bptr = rt.alloc(Math.max(4, boxes.byteLength));
      rt.put(bptr, new Uint8Array(boxes.buffer, boxes.byteOffset, boxes.byteLength));
      handle = x.playground_crowd_new(e.data.n, BigInt(bptr), boxes.length / 6);
      rt.free(bptr);
      if (handle === 0n) throw new Error("playground_crowd_new failed");
      postMessage({ id, ok: true });
    } else if (op === "run") {
      const t0 = performance.now();
      for (let i = 0; i < e.data.ticks; i++) {
        if (x.playground_crowd_step(handle, 1 / 60) !== 0) throw new Error("playground_crowd_step failed");
      }
      const ms = performance.now() - t0;
      postMessage({ id, ok: true, hash: x.playground_crowd_hash(handle), ms });
    } else if (op === "rows") {
      const ptr = x.playground_crowd_rows(handle);
      const count = x.playground_crowd_count(handle);
      const f = rt.f32(ptr, count * 4).slice();
      postMessage({ id, ok: true, rows: f }, [f.buffer]);
    } else {
      throw new Error("unknown op " + op);
    }
  } catch (err) {
    postMessage({ id, ok: false, error: String(err) });
  }
};
