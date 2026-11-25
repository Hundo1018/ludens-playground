// The visual showcase page: loads showcase.wasm (app/showcase_host.mojo) with the engine's JavaScript runtime, hands it
// the engine's CJK SDF font, and runs one frame per animation frame. Plain JavaScript: the page has no build step.
import { instantiate } from "./host.mjs";
import { createImports as wgpuImports } from "./webgpu_host.mjs";
import { Runtime } from "./webgpu_runtime.mjs";
import { loadAsset, stageAsset } from "./assets.mjs";
import { withViewRefs } from "./view_refs.mjs"; // the engine's TextureView reference counts: the post stages share views

const params = new URLSearchParams(location.search);
const canvas = document.getElementById("canvas");
if (params.has("w") && params.has("h")) { canvas.width = Number(params.get("w")); canvas.height = Number(params.get("h")); }
const stats = (window.host = { frames: 0, error: "", frameMs: 0, app: 0n, rt: null, x: null, font: false, times: [], intervals: [] });

const FX = ["MSAA 4x", "FXAA", "Bloom", "LUT", "陰影", "點光源", "粒子"];
const KEYS = { Space: 32, KeyR: 82, KeyH: 72, Digit1: 49, Digit2: 50, Digit3: 51, Digit4: 52, Digit5: 53, Digit6: 54, Digit7: 55 };
const EV_KEY = 1, EV_MOUSE_BUTTON = 2, EV_CURSOR_POS = 3, ACTION_RELEASE = 0, ACTION_PRESS = 1, ACTION_REPEAT = 2;

async function boot() {
  const [layout, enums, bytes, index] = await Promise.all([
    fetch("./webgpu_layout.json").then((r) => r.json()),
    fetch("./webgpu_enum_strings.json").then((r) => r.json()),
    fetch("./showcase.wasm").then((r) => r.arrayBuffer()),
    fetch("./assets/index.json").then((r) => r.json()),
  ]);
  const wrt = new Runtime(layout, enums);
  const rt = await instantiate(bytes, { libs: [() => ({ env: withViewRefs(wgpuImports(wrt)) })] });
  wrt.attach(rt);
  const x = rt.exports;
  stats.rt = rt; stats.x = x;
  const [sel, len] = rt.str_in("#" + canvas.id);
  const app = x.showcase_init(sel, len, canvas.width, canvas.height);
  if (app === 0n) throw new Error("showcase_init failed");
  stats.app = app;
  if (params.has("offscreen")) x.showcase_offscreen(app, 1); // headless checks: never draw to the canvas
  if (params.has("nohud")) x.showcase_hud(app, 0);

  // the font: 6.5 MB, checked against its sha256 by the engine's loader, copied into wasm memory, then freed
  const fontName = "NotoSansTC-Regular-24.lfont";
  loadAsset(new URL("./assets/" + fontName, location.href).href, index[fontName].sha256, { maxBytes: 16 * 1024 * 1024 }).then((b) => {
    const s = stageAsset(rt, b);
    try { if (x.showcase_load_font(app, BigInt(s.ptr), BigInt(s.len)) !== 0) throw new Error("showcase_load_font failed"); } finally { s.free(); }
    stats.font = true;
  }).catch((e) => { stats.error = "font: " + String(e); });

  // buttons for the seven switches, the same as the keys 1 .. 7
  const bar = document.getElementById("fx");
  const buttons = FX.map((name, i) => {
    const b = document.createElement("button");
    b.type = "button";
    b.onclick = () => { x.showcase_toggle(app, i, x.showcase_fx(app, i) ? 0 : 1); };
    bar.appendChild(b);
    return b;
  });
  const label = () => FX.forEach((name, i) => { buttons[i].textContent = `${i + 1} ${name}：${x.showcase_fx(app, i) ? "開" : "關"}`; });

  const send = (kind, key, action, mods, x0, y0) => x.showcase_input(app, kind, key, action, mods, x0, y0);
  canvas.style.touchAction = "none";
  const scale = () => canvas.width / canvas.clientWidth; // the canvas may be drawn smaller than its pixel size
  canvas.addEventListener("pointermove", (e) => send(EV_CURSOR_POS, 0, 0, 0, e.offsetX * scale(), e.offsetY * scale()));
  canvas.addEventListener("pointerdown", (e) => {
    canvas.setPointerCapture(e.pointerId);
    send(EV_CURSOR_POS, 0, 0, 0, e.offsetX * scale(), e.offsetY * scale());
    send(EV_MOUSE_BUTTON, 0, ACTION_PRESS, 0, e.offsetX * scale(), e.offsetY * scale());
  });
  const up = (e) => send(EV_MOUSE_BUTTON, 0, ACTION_RELEASE, 0, e.offsetX * scale(), e.offsetY * scale());
  canvas.addEventListener("pointerup", up);
  canvas.addEventListener("pointercancel", up);
  const key = (e, action) => {
    const code = KEYS[e.code];
    if (code === undefined) return;
    if (code === 32) e.preventDefault();
    send(EV_KEY, code, action === ACTION_PRESS && e.repeat ? ACTION_REPEAT : action, 0, 0, 0);
  };
  addEventListener("keydown", (e) => key(e, ACTION_PRESS));
  addEventListener("keyup", (e) => key(e, ACTION_RELEASE));
  addEventListener("blur", () => x.showcase_release_input(app));

  let last = performance.now();
  const frame = (now) => {
    try {
      stats.intervals.push(now - last); if (stats.intervals.length > 600) stats.intervals.shift(); // the time between two frames
      const dt = Math.min(Math.max((now - last) / 1000, 0), 0.1); last = now;
      const t0 = performance.now();
      const r = x.showcase_frame(app, dt);
      stats.frameMs = performance.now() - t0;
      x.showcase_set_frame_ms(app, stats.frameMs);
      if (r < 0) throw new Error("showcase_frame returned " + r);
      if (r === 1) { stats.frames++; stats.times.push(stats.frameMs); if (stats.times.length > 600) stats.times.shift(); }
      if (stats.frames % 15 === 0) label();
      requestAnimationFrame(frame);
    } catch (e) { stats.error = String(e); document.getElementById("log").textContent = String(e); }
  };
  label();
  requestAnimationFrame(frame);
}

boot().catch((e) => { stats.error = String(e); document.getElementById("log").textContent = String(e); });
