// Record the visual showcase frame by frame in headless Chrome (software WebGPU): the scene is held, stepped by exactly
// 1 / fps seconds between two captures, and each capture is written as a PNG. Software rendering is far slower than a
// GPU, so this is for a recording, not a frame rate. Turn the PNGs into an animation with scripts/frames_to_gif.py.
// usage: node scripts/showcase_record.mjs <chrome> <url> <out-dir> [frames=90] [fps=15] [warmup_s=6] [timeout_s=900]
import { spawn } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { png } from './frame_png.mjs';

const [chrome, url, outDir, framesS = '90', fpsS = '15', warmS = '6', timeoutS = '900'] = process.argv.slice(2);
mkdirSync(outDir, { recursive: true });
const profile = mkdtempSync(join(tmpdir(), 'showcase-record-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=1320,900', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('showcase_record: timed out'); done(1); }, Number(timeoutS) * 1000);
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
await send('Page.navigate', { url });
for (let i = 0; i < 480; i++) { if ((await js('window.host && window.host.frames')) > 10 && await js('window.host.font')) break; await sleep(250); }
if (!(await js('window.host && window.host.font'))) { console.log('showcase_record: the page did not start'); done(1); }
const fps = Number(fpsS);
await js(`(() => { const x = window.host.x, app = window.host.app; x.showcase_hold(app, 1); x.showcase_advance(app, ${Number(warmS)}); })()`);
const GRAB = `(async () => {
  const h = window.host, x = h.x, app = h.app, c = document.querySelector('canvas');
  x.showcase_request_capture(app);
  for (let i = 0; i < 3000 && x.showcase_capture_ptr(app) === 0n; i++) await new Promise((r) => requestAnimationFrame(r));
  const p = x.showcase_capture_ptr(app); if (p === 0n) return null;
  const pitch = x.showcase_capture_pitch(app), w = c.width, hgt = c.height;
  const d = h.rt.bytes(p, pitch * hgt).slice();
  x.showcase_capture_release(app);
  x.showcase_advance(app, ${1 / fps});
  let bin = ''; for (let i = 0; i < d.length; i += 8192) bin += String.fromCharCode(...d.subarray(i, i + 8192));
  return { w, h: hgt, pitch, b64: btoa(bin) };
})()`;
const t0 = Date.now();
for (let f = 0; f < Number(framesS); f++) {
  const r = await js(GRAB);
  if (!r) { console.log(`frame ${f}: capture never completed`); done(1); }
  const bytes = Buffer.from(r.b64, 'base64'); const rgba = new Uint8Array(r.w * r.h * 4);
  for (let y = 0; y < r.h; y++) for (let xx = 0; xx < r.w; xx++) {
    const o = y * r.pitch + xx * 4, q = (y * r.w + xx) * 4;
    rgba[q] = bytes[o]; rgba[q + 1] = bytes[o + 1]; rgba[q + 2] = bytes[o + 2]; rgba[q + 3] = 255;
  }
  writeFileSync(join(outDir, `frame_${String(f).padStart(4, '0')}.png`), png(r.w, r.h, rgba));
}
console.log(`showcase_record: ${framesS} frames at ${fps} fps of scene time in ${((Date.now() - t0) / 1000).toFixed(0)} s -> ${outDir}`);
done(0);
