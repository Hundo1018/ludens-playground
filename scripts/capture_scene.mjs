// Capture one offscreen frame of the playground page to a PNG (the page draws only when a capture is requested, so this
// is the page's offscreen render path: the frame is rendered into an app-owned texture and read back).
// usage: node scripts/capture_scene.mjs <chrome> <url> <out.png> [timeout_s=180]
// The page is ready when the five converted assets are up and at least ten frames have run (as in host_check).
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { deflateSync } from 'node:zlib';

const [chrome, url, out, timeoutS = '180'] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'capture-scene-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=1280,760', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('capture-scene: timed out'); done(1); }, Number(timeoutS) * 1000);
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
await send('Page.navigate', { url });

function png(w, h, rgba) {
  const crcT = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
  const crc = (b) => { let c = 0xffffffff; for (const x of b) c = crcT[(c ^ x) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (t, d) => { const b = Buffer.alloc(12 + d.length); b.writeUInt32BE(d.length, 0); b.write(t, 4); d.copy(b, 8); b.writeUInt32BE(crc(b.subarray(4, 8 + d.length)), 8 + d.length); return b; };
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) { raw[y * (w * 4 + 1)] = 0; Buffer.from(rgba.buffer, rgba.byteOffset + y * w * 4, w * 4).copy(raw, y * (w * 4 + 1) + 1); }
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

for (let i = 0; i < 600; i++) { if ((await js('window.host && window.host.assets')) >= 5 && (await js('window.host.frames')) >= 10) break; await sleep(100); }
const err = await js('window.host && window.host.error');
if (err) { console.log('capture-scene: page error: ' + err); done(1); }
await sleep(1000);
const GRAB = `(async () => {
  const s = window.host, x = s.x, app = s.app, c = document.querySelector('canvas');
  x.playground_host_request_capture(app);
  for (let i = 0; i < 2000 && x.playground_host_capture_ptr(app) === 0n; i++) await new Promise((r) => requestAnimationFrame(r));
  const p = x.playground_host_capture_ptr(app); if (p === 0n) return null;
  const pitch = x.playground_host_capture_pitch(app), w = c.width, h = c.height;
  const d = s.rt.bytes(p, pitch * h).slice(); x.playground_host_capture_release(app);
  let bin = ''; for (let i = 0; i < d.length; i += 8192) bin += String.fromCharCode(...d.subarray(i, i + 8192));
  return { w, h, pitch, b64: btoa(bin) };
})()`;
const r = await js(GRAB);
if (!r) { console.log('capture-scene: capture never completed'); done(1); }
const bytes = Buffer.from(r.b64, 'base64'); const rgba = new Uint8Array(r.w * r.h * 4);
for (let y = 0; y < r.h; y++) for (let xx = 0; xx < r.w; xx++) {
  const o = y * r.pitch + xx * 4, q = (y * r.w + xx) * 4;
  rgba[q] = bytes[o]; rgba[q + 1] = bytes[o + 1]; rgba[q + 2] = bytes[o + 2]; rgba[q + 3] = 255;
}
writeFileSync(out, png(r.w, r.h, rgba));
console.log(`capture-scene: wrote ${out} (${r.w}x${r.h})`);
done(0);
