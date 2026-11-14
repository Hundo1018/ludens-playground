// The Frontier page: loads the playground's wasm host with the engine's JavaScript runtime and runs one frame per
// animation frame. Plain JavaScript on purpose: the page has no build step of its own.
import { instantiate } from "./host.mjs";
import { createImports as wgpuImports } from "./webgpu_host.mjs";
import { Runtime } from "./webgpu_runtime.mjs";
import { loadAsset, stageAsset } from "./assets.mjs";

const params = new URLSearchParams(location.search);
const canvas = document.getElementById("canvas");
const stats = (window.host = { frames: 0, error: "", frameMs: 0, app: 0n, rt: null, x: null, assets: 0 });

// The page's converted assets, by file name: the kind playground_host_asset expects (see app/host.mojo).
const ASSET_KIND = { "CesiumMan.lcharacter": 1, "Fox.lcharacter": 2, "concrete_wall_008.ltexture": 3 };

// Each entry of index.json is fetched, checked against its sha256 by the engine's loader, copied into wasm memory,
// handed to the host, and freed once the call has returned (the host copies the bytes).
async function loadAssets(rt, x, app) {
  const index = await fetch("./assets/index.json").then((r) => {
    if (!r.ok) throw new Error("assets/index.json: HTTP " + r.status);
    return r.json();
  });
  for (const [name, meta] of Object.entries(index)) {
    const kind = ASSET_KIND[name];
    if (kind === undefined) throw new Error("no host kind for asset " + name);
    const url = new URL("./assets/" + name, location.href).href; // loadAsset takes an http(s) URL
    const bytes = await loadAsset(url, meta.sha256, { maxBytes: 16 * 1024 * 1024 });
    const s = stageAsset(rt, bytes);
    let rc;
    try { rc = x.playground_host_asset(app, kind, BigInt(s.ptr), BigInt(s.len)); } finally { s.free(); }
    if (rc !== 0) throw new Error("playground_host_asset failed for " + name);
    stats.assets++;
  }
}

// GLFW codes for the keys the Frontier uses (the same numbers the engine's keys table gives).
const KEYS = { KeyW: 87, KeyA: 65, KeyS: 83, KeyD: 68, Space: 32, KeyP: 80, KeyR: 82, Escape: 256,
               ArrowRight: 262, ArrowLeft: 263, ArrowDown: 264, ArrowUp: 265 };
const EV_KEY = 1, ACTION_RELEASE = 0, ACTION_PRESS = 1, ACTION_REPEAT = 2;

async function boot() {
  const [layout, enums, bytes] = await Promise.all([
    fetch("./webgpu_layout.json").then((r) => r.json()),
    fetch("./webgpu_enum_strings.json").then((r) => r.json()),
    fetch("./host.wasm").then((r) => r.arrayBuffer()),
  ]);
  const wrt = new Runtime(layout, enums);
  const rt = await instantiate(bytes, { libs: [() => ({ env: wgpuImports(wrt) })] });
  wrt.attach(rt);
  const x = rt.exports;
  stats.rt = rt; stats.x = x;
  const [sel, len] = rt.str_in("#" + canvas.id);
  const app = x.playground_host_init(sel, len, canvas.width, canvas.height);
  if (app === 0n) throw new Error("playground_host_init failed");
  stats.app = app;
  loadAssets(rt, x, app).catch((e) => { stats.error = "assets: " + String(e); });
  if (params.has("offscreen")) x.playground_host_offscreen(app, 1); // headless checks: never draw to the canvas

  const key = (e, action) => {
    const code = KEYS[e.code];
    if (code === undefined) return;
    if (code === 32 || (code >= 262 && code <= 265)) e.preventDefault();
    x.playground_host_input(app, EV_KEY, code, action === ACTION_PRESS && e.repeat ? ACTION_REPEAT : action, 0, 0, 0);
  };
  addEventListener("keydown", (e) => key(e, ACTION_PRESS));
  addEventListener("keyup", (e) => key(e, ACTION_RELEASE));
  addEventListener("blur", () => x.playground_host_release_input(app));

  let last = performance.now();
  const frame = (now) => {
    try {
      const dt = Math.min(Math.max((now - last) / 1000, 0), 0.1); last = now;
      const t0 = performance.now();
      const r = x.playground_host_frame(app, dt);
      stats.frameMs = performance.now() - t0;
      if (r < 0) throw new Error("playground_host_frame returned " + r);
      if (r === 1) stats.frames++;
      requestAnimationFrame(frame);
    } catch (e) { stats.error = String(e); }
  };
  requestAnimationFrame(frame);
}

boot().catch((e) => { stats.error = String(e); document.getElementById("log").textContent = String(e); });
