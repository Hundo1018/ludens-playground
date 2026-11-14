// Step 7 measurement (docs/design/step7-crowd.md): median frame time of the Frontier with n extra skinned CesiumMan. The page
// draws to the canvas (no ?offscreen), so the time includes the GPU work
// instances, headless Chrome (SwiftShader), canvas 1280 x 720, a fresh page for each n. Prints a markdown table and the
// largest n whose median stays under 16.7 ms. A count the engine's palette limit refuses is reported as such.
// usage: node scripts/crowd_bench.mjs <chrome> <base-url> <counts, comma-separated> [samples=60]
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { writeFileSync } from 'node:fs';
import { png } from './frame_png.mjs';

const [chrome, base, countsArg, samplesArg = '60'] = process.argv.slice(2);
const counts = countsArg.split(',').map(Number);
const samples = Number(samplesArg);
const profile = mkdtempSync(join(tmpdir(), 'crowd-bench-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=1280,760', '--disable-gpu-vsync', '--disable-frame-rate-limit', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const finish = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
const port = await new Promise((res) => { let b = ''; proc.stderr.on('data', (d) => { b += d; const m = b.match(/DevTools listening on ws:\/\/[^:]+:(\d+)\//); if (m) res(m[1]); }); });
const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r));
let id = 0; const pending = new Map();
ws.addEventListener('message', (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result ?? m.error); pending.delete(m.id); } });
const send = (method, params = {}) => new Promise((r) => { pending.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });
const js = async (expression) => (await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }))?.result?.value;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
await send('Runtime.enable');
await send('Page.enable');
const median = (xs) => { const s = [...xs].sort((a, b) => a - b); return s[Math.floor(s.length / 2)]; };
const rows = [];
let budget = 0;
for (const n of counts) {
  const mode = process.env.NO_BENCH ? '?offscreen' : '?offscreen&bench=1';
  await send('Page.navigate', { url: `${base}${mode}&w=1280&h=720&crowd=${n}` });
  let ready = false;
  for (let i = 0; i < 600; i++) {
    const st = await js('({ frames: window.host && window.host.frames, assets: window.host && window.host.assets, error: window.host && window.host.error })');
    if (st && st.error) { rows.push({ n, status: `refused: ${st.error}` }); ready = null; break; }
    if (st && st.assets === 3 && st.frames >= 10) { ready = true; break; }
    await sleep(100);
  }
  if (ready === null) continue;
  if (!ready) { rows.push({ n, status: 'page not ready' }); continue; }
  // one sample per rendered frame: the wall-clock gap between consecutive frame-counter changes (includes the GPU work,
  // which host_frame's own timer does not wait for)
  const ms = [];
  let last = await js('window.host.frames');
  let lastT = await js('performance.now()');
  while (ms.length < samples) {
    await sleep(4);
    const cur = await js('({ frames: window.host.frames, t: performance.now(), error: window.host.error })');
    if (cur.error) { rows.push({ n, status: `error: ${cur.error}` }); break; }
    if (cur.frames !== last) { ms.push(cur.t - lastT); last = cur.frames; lastT = cur.t; }
  }
  if (ms.length < samples) continue;
  if (process.env.SHOT_PREFIX) {
    // the host's own frame readback (the CDP screenshot does not show WebGPU canvases): one frame, as host_check takes it
    const r = await js(`(async () => {
      const h = window.host, x = h.x, app = h.app, c = document.querySelector('canvas');
      x.playground_host_request_capture(app);
      for (let i = 0; i < 900 && x.playground_host_capture_ptr(app) === 0n; i++) await new Promise((r) => requestAnimationFrame(r));
      const p = x.playground_host_capture_ptr(app); if (p === 0n) return null;
      const pitch = x.playground_host_capture_pitch(app), w = c.width, hgt = c.height;
      const d = h.rt.bytes(p, pitch * hgt).slice();
      x.playground_host_capture_release(app);
      let bin = ''; for (let i = 0; i < d.length; i += 8192) bin += String.fromCharCode(...d.subarray(i, i + 8192));
      return { w, h: hgt, pitch, b64: btoa(bin) };
    })()`);
    if (!r) console.log(`frame ${n}: capture did not complete`);
    if (r) {
      const bytes = Buffer.from(r.b64, 'base64'); const rgba = new Uint8Array(r.w * r.h * 4);
      for (let y = 0; y < r.h; y++) for (let xx = 0; xx < r.w; xx++) {
        const o = y * r.pitch + xx * 4, q = (y * r.w + xx) * 4;
        rgba[q] = bytes[o]; rgba[q + 1] = bytes[o + 1]; rgba[q + 2] = bytes[o + 2]; rgba[q + 3] = 255;
      }
      writeFileSync(`${process.env.SHOT_PREFIX}-${n}.png`, png(r.w, r.h, rgba));
      const colours = new Set();
      for (let q = 0; q < rgba.length; q += 4) colours.add((rgba[q] >> 3) << 10 | (rgba[q + 1] >> 3) << 5 | rgba[q + 2] >> 3);
      console.log(`frame ${n}: captured, ${colours.size} colours`);
    }
  }
  const med = median(ms);
  rows.push({ n, status: 'ok', median: med, p90: [...ms].sort((a, b) => a - b)[Math.floor(samples * 0.9)] });
  if (med < 16.7) budget = Math.max(budget, n);
}
console.log('| instances (extra) | median frame ms | p90 ms | status |');
console.log('|---:|---:|---:|---|');
for (const r of rows) console.log(`| ${r.n} | ${r.status === 'ok' ? r.median.toFixed(2) : '-'} | ${r.status === 'ok' ? r.p90.toFixed(2) : '-'} | ${r.status} |`);
console.log(`largest count with median under 16.7 ms: ${budget}`);
finish(0);
