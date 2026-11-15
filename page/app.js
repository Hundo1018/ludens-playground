// The Frontier page: loads the playground's wasm host with the engine's JavaScript runtime and runs one frame per
// animation frame. Plain JavaScript on purpose: the page has no build step of its own.
import { instantiate } from "./host.mjs";
import { createImports as wgpuImports } from "./webgpu_host.mjs";
import { Runtime } from "./webgpu_runtime.mjs";
import { loadAsset, stageAsset } from "./assets.mjs";
import { mountVirtualPad } from "./vpad_view.js";

const params = new URLSearchParams(location.search);
const canvas = document.getElementById("canvas");
// ?w=&h= sets the canvas size (the step 7 measurement is taken at 1280 x 720; the default stays as in index.html).
if (params.has("w") && params.has("h")) { canvas.width = Number(params.get("w")); canvas.height = Number(params.get("h")); }
const stats = (window.host = { frames: 0, error: "", frameMs: 0, app: 0n, rt: null, x: null, assets: 0 });

// The page's converted assets, by file name: the kind playground_host_asset expects (see app/host.mojo).
const ASSET_KIND = { "CesiumMan.lcharacter": 1, "Fox.lcharacter": 2, "concrete_wall_003.ltexture": 3, "rocks_ground_01.ltexture": 4, "fox_base.ltexture": 5 };

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
  stats.rt = rt; stats.x = x; stats.wrt = wrt; // wrt: the WebGPU runtime (its handles hold the GPUQueue)
  const [sel, len] = rt.str_in("#" + canvas.id);
  const app = x.playground_host_init(sel, len, canvas.width, canvas.height);
  if (app === 0n) throw new Error("playground_host_init failed");
  stats.app = app;
  // Touch: the engine's virtual pad. Its stick sends W A S D and its buttons send Space and R, through the same
  // host input as the keyboard, so the protagonist moves from the pad exactly as from the keys.
  const PAD = {
    sticks: [{ id: "move", radius: 64, keys: { up: 87, down: 83, left: 65, right: 68 }, at: { left: 24, bottom: 24 } }],
    buttons: [
      { id: "jump", key: 32, label: "Jump", size: 76, at: { right: 24, bottom: 24 } },
      { id: "reset", key: 82, label: "R", size: 56, at: { right: 124, bottom: 24 } },
    ],
  };
  const padKey = (code, down) => { (stats.padLog ||= []).push([code, down]); return x.playground_host_input(app, EV_KEY, code, down ? ACTION_PRESS : ACTION_RELEASE, 0, 0, 0); };
  // The pad shows itself on a coarse pointer (a phone); ?pad forces it on, for the headless touch check.
  stats.pad = mountVirtualPad(canvas, PAD, { key: padKey, look() {}, lookEnd() {} }, params.has("pad"));
  loadAssets(rt, x, app).catch((e) => { stats.error = "assets: " + String(e); });
  if (params.has("offscreen")) x.playground_host_offscreen(app, 1); // headless checks: never draw to the canvas
  // The town (plan stage 3): 24 residents on corner routes and a guard; ?notown leaves it out.
  if (!params.has("notown")) x.playground_host_town(app, 1);
  // The sun's shadow (plan step 5): on by default; ?noshadow turns the depth pass and the shadow factor off.
  x.playground_host_shadow(app, params.has("noshadow") ? 0 : 1);
  // The three-colour netcode view (plan step 8): server truth, predicted and shown, drawn for player 0 on a 150 ms link.
  if (params.has("netview")) x.playground_host_netview(app, 1, 9, 2, 0);
  if (params.has("notex")) x.playground_host_notex(app, 1); // debug: an untextured comparison frame
  if (params.has("bench")) x.playground_host_bench_draw(app, 1); // step 7 timing: draw every frame into the target
  if (params.has("crowd")) x.playground_host_crowd(app, Number(params.get("crowd"))); // step 7 measurement
  // the HUD's netcode check (step 8): the lossy session (latency 4, jitter 3, 10 % loss) on the page's wasm, shown as
  // text. The value is the reference hash (mod 1000000007); native prints the same. -1 would mean a peer did not converge.
  const netBtn = document.getElementById("net");
  const sliders = [["lat", "latv", 1], ["jit", "jitv", 1], ["los", "losv", 1]];
  for (const [id, shown] of sliders) {
    const el = document.getElementById(id);
    if (el) el.oninput = () => { const v = document.getElementById(shown); if (v) v.textContent = el.value; };
  }
  if (netBtn) netBtn.onclick = () => {
    const val = (id) => Number(document.getElementById(id) ? document.getElementById(id).value : 0);
    const code = x.playground_host_net_check(val("lat"), val("jit"), val("los") * 10);
    const out = document.getElementById("netout");
    if (out) out.textContent = code === 765407476 ? "converged (" + code + ", equal to native)" : "not converged (code " + code + ")";
  };
  // the HUD's crowd toggle (step 7): 64 ecs members walking to the centre, or none. Off by default: the measured frame
  // time on this machine is already over the 16.7 ms budget (docs/design/step7-crowd.md), so the crowd is opt-in.
  const crowdBtn = document.getElementById("crowd");
  let crowdOn = false;
  if (crowdBtn) crowdBtn.onclick = () => {
    crowdOn = !crowdOn;
    const rc = x.playground_host_crowd(app, crowdOn ? 64 : 0);
    if (rc < 0) crowdOn = false;
    crowdBtn.textContent = "crowd: " + (crowdOn ? "64" : "off");
  };
  // the HUD's backend switch (step 7): flips the live ecs backend of the crowd and relabels the button
  const backendBtn = document.getElementById("backend");
  if (backendBtn) backendBtn.onclick = () => {
    const now = x.playground_host_crowd_switch(app);
    if (now >= 0) backendBtn.textContent = "crowd backend: " + (now === 1 ? "naive" : "sparse-set");
  };

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
      x.playground_host_set_frame_ms(app, stats.frameMs);
      if (r < 0) throw new Error("playground_host_frame returned " + r);
      if (r === 1) stats.frames++;
      requestAnimationFrame(frame);
    } catch (e) { stats.error = String(e); }
  };
  requestAnimationFrame(frame);
}

boot().catch((e) => { stats.error = String(e); document.getElementById("log").textContent = String(e); });
