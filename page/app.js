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
const atPoint = params.has("at") ? params.get("at").split(",").map(Number) : null; // ?at=x,z (visual checks)
const stats = (window.host = { frames: 0, error: "", frameMs: 0, app: 0n, rt: null, x: null, assets: 0 });

// The page's converted assets, by file name: the kind playground_host_asset expects (see app/host.mojo).
const ASSET_KIND = { "CesiumMan.lcharacter": 1, "Fox.lcharacter": 2, "concrete_wall_003.ltexture": 3, "rocks_ground_01.ltexture": 4, "fox_base.ltexture": 5,
  // V1-V3: kind 10 + L is a texture for layer L (frontier/world.mojo LAYER_*)
  "cesium_base.ltexture": 14, "medieval_blocks_02.ltexture": 15, "castle_brick_07.ltexture": 16, "plastered_wall_02.ltexture": 17,
  "brown_planks_03.ltexture": 18, "bark_brown_02.ltexture": 19, "hessian_230.ltexture": 20, "rusty_metal_02.ltexture": 21 };

// Each entry of index.json is fetched, checked against its sha256 by the engine's loader, copied into wasm memory,
// handed to the host, and freed once the call has returned (the host copies the bytes).
async function loadAssets(rt, x, app) {
  const index = await fetch("./assets/index.json").then((r) => {
    if (!r.ok) throw new Error("assets/index.json: HTTP " + r.status);
    return r.json();
  });
  for (const [name, meta] of Object.entries(index)) {
    if (name.endsWith(".lsound")) continue; // sounds go to the audio scene (loadSounds)
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
  stats.assetsDone = true;
}

// W11: the crowd in a Worker. The page sends the pillar boxes once; each frame it asks the worker for one step and its rows,
// and feeds the rows to the host (playground_host_crowd_feed). One request at a time: a frame with no reply reuses the last rows.
let crowdWorker = null;
async function startCrowdWorker(rt, x, app, n) {
  const cnt = x.playground_host_pillar_count(app);
  const boxes = [];
  for (let i = 0; i < cnt; i++) for (let k = 0; k < 6; k++) boxes.push(x.playground_host_pillar(app, i, k));
  const w = new Worker("./crowd.worker.mjs", { type: "module" });
  let nextId = 1;
  const pending = new Map();
  w.onmessage = (e) => { const r = pending.get(e.data.id); if (r) { pending.delete(e.data.id); r(e.data); } };
  const call = (msg, transfer) => new Promise((resolve) => { const id = nextId++; pending.set(id, resolve); w.postMessage({ ...msg, id }, transfer || []); });
  const init = await call({ op: "init", n, boxes });
  if (!init.ok) throw new Error("crowd worker: " + init.error);
  x.playground_host_crowd_ext(app, 1);
  crowdWorker = { call, busy: false, n, rt, x, app };
  stats.crowdWorker = true;
}
function crowdWorkerFrame() {
  if (!crowdWorker || crowdWorker.busy) return;
  const { call, rt, x, app, n } = crowdWorker;
  crowdWorker.busy = true;
  call({ op: "run", ticks: 1 }).then(() => call({ op: "rows" })).then((r) => {
    if (!r.ok) throw new Error("crowd worker rows: " + r.error);
    const f = new Float32Array(r.rows);
    const s = stageAsset(rt, new Uint8Array(f.buffer));
    try { x.playground_host_crowd_feed(app, BigInt(s.ptr), n); } finally { s.free(); }
    stats.crowdRows = (stats.crowdRows || 0) + 1;
  }).catch((e) => { stats.error = "crowd worker: " + String(e); }).finally(() => { crowdWorker.busy = false; });
}
// W8: the four sounds. Each .lsound (scripts/convert_wav.py: "LSND", version, header length, JSON header, int16 mono
// frames) is decoded to stereo f32 and registered on the host's audio scene. The first is the menu select, the second the
// coin cluster, which plays when a zone goal is reached (GOAL_SOUND).
const SOUNDS = ["sfx_menu_select1.lsound", "sfx_coin_cluster1.lsound", "sfx_damage_hit1.lsound", "sfx_sounds_powerup1.lsound"];
const GOAL_SOUND = 1;
function lsoundToStereo(bytes) {
  const magic = String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3]);
  if (magic !== "LSND") throw new Error("not an .lsound file");
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const off = 12 + dv.getUint32(8, true);
  const n = (bytes.byteLength - off) >> 1;
  const out = new Float32Array(n * 2);
  for (let i = 0; i < n; i++) {
    const v = dv.getInt16(off + 2 * i, true) / 32768;
    out[2 * i] = v;
    out[2 * i + 1] = v;
  }
  return out;
}
async function loadSounds(rt, x, app, index) {
  if (x.playground_host_audio_init(app) !== 0) throw new Error("playground_host_audio_init failed");
  const ids = [];
  for (const name of SOUNDS) {
    const meta = index[name];
    if (!meta) throw new Error("sound missing from assets/index.json: " + name);
    const url = new URL("./assets/" + name, location.href).href;
    const bytes = await loadAsset(url, meta.sha256, { maxBytes: 4 * 1024 * 1024 });
    const pcm = lsoundToStereo(bytes);
    const s = stageAsset(rt, new Uint8Array(pcm.buffer));
    let id;
    try { id = x.playground_host_audio_clip(app, BigInt(s.ptr), pcm.length / 2); } finally { s.free(); }
    if (id < 0) throw new Error("playground_host_audio_clip failed for " + name);
    ids.push(id);
    stats.sounds = (stats.sounds || 0) + 1;
  }
  x.playground_host_audio_goal(app, ids[GOAL_SOUND]);
}

// W8: the audio context starts on the first key or pointer event (browsers allow sound only after a gesture). The worklet
// asks for blocks; the page renders them from the host's mix and posts them back (the page has no SharedArrayBuffer).
let audioStarted = false;
async function ensureAudio(rt, x, app) {
  if (audioStarted) return;
  audioStarted = true;
  // The scene is made here too (idempotent): a key can come before loadSounds, which waits for every texture; the
  // worklet's first top-up would otherwise find no scene and fail (the mix is silent until the clips arrive).
  if (x.playground_host_audio_init(app) !== 0) throw new Error("playground_host_audio_init failed");
  const ctx = new AudioContext({ sampleRate: 48000 });
  await ctx.audioWorklet.addModule("./worklet.js");
  const node = new AudioWorkletNode(ctx, "ring-player", { outputChannelCount: [2], processorOptions: { capacity: 8192 } });
  const BLOCK = 128, TARGET = 4096;
  const scratch = rt.alloc(BLOCK * 2 * 4);
  let sent = 0;
  const topUp = (played) => {
    const blocks = Math.floor((TARGET - (sent - played)) / BLOCK);
    if (blocks <= 0) return;
    const out = new Float32Array(blocks * BLOCK * 2);
    for (let b = 0; b < blocks; b++) {
      if (x.playground_host_audio_render(app, BigInt(scratch), BLOCK) !== 0) throw new Error("playground_host_audio_render failed");
      out.set(rt.f32(scratch, BLOCK * 2), b * BLOCK * 2);
    }
    sent += blocks * BLOCK;
    node.port.postMessage(out, [out.buffer]);
  };
  node.port.onmessage = (e) => {
    try { stats.audioPlayed = e.data.played; stats.audioUnderruns = e.data.underruns; topUp(e.data.played); } catch (err) { stats.error = String(err); }
  };
  node.connect(ctx.destination);
  topUp(0);
  stats.audioCtx = ctx;
  await ctx.resume();
}

// GLFW codes for the keys the Frontier uses (the same numbers the engine's keys table gives).
const KEYS = { KeyW: 87, KeyA: 65, KeyS: 83, KeyD: 68, Space: 32, KeyP: 80, KeyR: 82, Escape: 256,
               ArrowRight: 262, ArrowLeft: 263, ArrowDown: 264, ArrowUp: 265 };
const EV_KEY = 1, EV_MOUSE_BUTTON = 2, EV_CURSOR_POS = 3, ACTION_RELEASE = 0, ACTION_PRESS = 1, ACTION_REPEAT = 2;

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
  // Camera look (W1): the engine's own forwarding (shell/web/app.ts). The pointer sends button and cursor events; a pad
  // look is a drag of a virtual cursor with the left button held, so the game reads it as a mouse drag.
  const send = (kind, key, action, mods, x0, y0) => x.playground_host_input(app, kind, key, action, mods, x0, y0);
  const BUTTON_LEFT = 0, BUTTON_RIGHT = 1, BUTTON_MIDDLE = 2;
  const DOM_TO_GLFW = [BUTTON_LEFT, BUTTON_MIDDLE, BUTTON_RIGHT]; // DOM button 0/1/2 = left/middle/right
  let vx = 0, vy = 0, turning = false;
  const padLook = (dx, dy) => {
    if (!turning) { turning = true; send(EV_MOUSE_BUTTON, BUTTON_LEFT, ACTION_PRESS, 0, vx, vy); }
    vx += dx; vy += dy;
    send(EV_CURSOR_POS, 0, 0, 0, vx, vy);
  };
  const padLookEnd = () => { if (turning) { turning = false; send(EV_MOUSE_BUTTON, BUTTON_LEFT, ACTION_RELEASE, 0, vx, vy); } };
  canvas.style.touchAction = "none"; // a drag on the canvas is input, not a page scroll
  const isTouch = (e) => e.pointerType === "touch"; // touch goes to the virtual pad
  canvas.addEventListener("pointermove", (e) => {
    if (isTouch(e)) return;
    vx = e.offsetX; vy = e.offsetY;
    send(EV_CURSOR_POS, 0, 0, 0, e.offsetX, e.offsetY);
  });
  canvas.addEventListener("pointerdown", (e) => {
    if (isTouch(e)) return;
    ensureAudio(rt, x, app).catch((err) => { stats.error = "audio: " + String(err); });
    send(EV_CURSOR_POS, 0, 0, 0, e.offsetX, e.offsetY); // the press point is where the cursor is: no jump into the drag
    vx = e.offsetX; vy = e.offsetY;
    send(EV_MOUSE_BUTTON, DOM_TO_GLFW[e.button] ?? 0, ACTION_PRESS, 0, e.offsetX, e.offsetY);
  });
  const pointerUp = (e) => {
    if (isTouch(e)) return;
    send(EV_MOUSE_BUTTON, DOM_TO_GLFW[e.button] ?? 0, ACTION_RELEASE, 0, e.offsetX, e.offsetY);
  };
  canvas.addEventListener("pointerup", pointerUp);
  canvas.addEventListener("pointercancel", pointerUp);
  // The pad shows itself on a coarse pointer (a phone); ?pad forces it on, for the headless touch check.
  stats.pad = mountVirtualPad(canvas, PAD, { key: padKey, look: padLook, lookEnd: padLookEnd }, params.has("pad"));
  loadAssets(rt, x, app).then(async () => {
    const index = await fetch("./assets/index.json").then((r) => r.json());
    await loadSounds(rt, x, app, index);
  }).catch((e) => { stats.error = "assets: " + String(e); });
  if (params.has("offscreen")) x.playground_host_offscreen(app, 1); // headless checks: never draw to the canvas
  // The town (plan stage 3): 24 residents on corner routes and a guard; ?notown leaves it out.
  if (!params.has("notown")) x.playground_host_town(app, 1);
  // The sun's shadow (plan step 5): on by default; ?noshadow turns the depth pass and the shadow factor off.
  x.playground_host_shadow(app, params.has("noshadow") ? 0 : 1);
  x.playground_host_ao(app, params.has("noao") ? 0 : 1); // W10: the occlusion term, traced over the pillars
  if (params.has("noatmo")) x.playground_host_atmo(app, 0); // V4: sky, fog and tone mapping are on by default
  // The three-colour netcode view (plan step 8): server truth, predicted and shown, drawn for player 0 on a 150 ms link.
  // The three-colour netcode view (W9): on by default, labelled, and a button turns it off (?nonetview starts it off).
  // The recorded choice is on: the view is the step-8 showcase and the visitor should see it without a URL parameter.
  let netviewOn = !params.has("nonetview");
  const netviewBtn = document.getElementById("netview");
  const setNetview = (on) => { netviewOn = on; x.playground_host_netview(app, on ? 1 : 0, 9, 2, 0); if (netviewBtn) netviewBtn.textContent = "netview: " + (on ? "on" : "off"); };
  if (netviewBtn) netviewBtn.onclick = () => setNetview(!netviewOn);
  setNetview(netviewOn);
  if (params.has("debug")) x.playground_host_debug(app, 1);
  if (params.has("notex")) x.playground_host_notex(app, 1); // debug: an untextured comparison frame
  if (params.has("bench")) x.playground_host_bench_draw(app, 1); // step 7 timing: draw every frame into the target
  if (params.has("crowd")) x.playground_host_crowd(app, Number(params.get("crowd"))); // step 7 measurement
  // W11: ?crowdworker takes the crowd's stepping off the page: a Worker (crowd.worker.mjs, crowd/crowd.wasm) steps it and
  // the page draws the rows it sends back. Without it the page steps the crowd itself.
  if (params.has("crowd") && params.has("crowdworker")) await startCrowdWorker(rt, x, app, Number(params.get("crowd")));  // the HUD's netcode check (step 8): the lossy session (latency 4, jitter 3, 10 % loss) on the page's wasm, shown as
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
  addEventListener("keydown", (e) => { key(e, ACTION_PRESS); ensureAudio(rt, x, app).catch((err) => { stats.error = "audio: " + String(err); }); });
  addEventListener("keyup", (e) => key(e, ACTION_RELEASE));
  addEventListener("blur", () => x.playground_host_release_input(app));

  let last = performance.now();
  const frame = (now) => {
    try {
      const dt = Math.min(Math.max((now - last) / 1000, 0), 0.1); last = now;
      const t0 = performance.now();
      crowdWorkerFrame();
      const r = x.playground_host_frame(app, dt);
      stats.frameMs = performance.now() - t0;
      x.playground_host_set_frame_ms(app, stats.frameMs);
      if (r < 0) throw new Error("playground_host_frame returned " + r);
      if (r === 1) stats.frames++;
      // ?at=x,z: a visual check (plan stage checks) moves the player to a point once, after ten frames
      if (atPoint && stats.frames === 10) x.playground_host_frontier_teleport(app, atPoint[0], atPoint[1]);
      requestAnimationFrame(frame);
    } catch (e) { stats.error = String(e); }
  };
  requestAnimationFrame(frame);
}

boot().catch((e) => { stats.error = String(e); document.getElementById("log").textContent = String(e); });
