// The Frontier page in headless Chrome (software WebGPU): frames draw, the scene reacts to keys, no page error.
// usage: node scripts/host_check.mjs <chrome> <url> <out-prefix> [timeout_s]
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { deflateSync } from 'node:zlib';

const [chrome, url, prefix, timeoutS = '150'] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'host-check-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=960,600', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('host_check: timed out'); done(1); }, Number(timeoutS) * 1000);
const port = await new Promise((res) => { let b = ''; proc.stderr.on('data', (d) => { b += d; const m = b.match(/DevTools listening on ws:\/\/[^:]+:(\d+)\//); if (m) res(m[1]); }); });
const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r));
let id = 0; const pending = new Map(); const problems = [];
const need = (cond, what) => { console.log(`  [${cond ? 'PASS' : 'FAIL'}] ${what}`); if (!cond) problems.push(what); };
ws.addEventListener('message', (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result ?? m.error); pending.delete(m.id); }
  if (m.method === 'Runtime.consoleAPICalled') console.log('console:', m.params.args.map((a) => a.value ?? a.description).join(' ').slice(0, 300));
  if (m.method === 'Runtime.exceptionThrown') { console.log('exception:', m.params.exceptionDetails.exception?.description); problems.push('page exception'); }
});
const send = (method, params = {}) => new Promise((r) => { pending.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });
const js = async (expression) => (await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }))?.result?.value;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
await send('Runtime.enable');
await send('Page.enable');
await send('Page.navigate', { url });
const key = (type, code) => js(`window.dispatchEvent(new KeyboardEvent('${type}', { code: '${code}', bubbles: true }))`);

function png(w, h, rgba) {
  const crcT = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
  const crc = (b) => { let c = 0xffffffff; for (const x of b) c = crcT[(c ^ x) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (t, d) => { const b = Buffer.alloc(12 + d.length); b.writeUInt32BE(d.length, 0); b.write(t, 4); d.copy(b, 8); b.writeUInt32BE(crc(b.subarray(4, 8 + d.length)), 8 + d.length); return b; };
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) { raw[y * (w * 4 + 1)] = 0; Buffer.from(rgba.buffer, rgba.byteOffset + y * w * 4, w * 4).copy(raw, y * (w * 4 + 1) + 1); }
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}
// Ask the host for one captured frame and return its pixels (RGBA) as base64 with the size.
const GRAB = `(async () => {
  const h = window.host, x = h.x, app = h.app, c = document.querySelector('canvas');
  x.playground_host_request_capture(app);
  for (let i = 0; i < 900 && x.playground_host_capture_ptr(app) === 0n; i++) await new Promise((r) => requestAnimationFrame(r));
  const p = x.playground_host_capture_ptr(app); if (p === 0n) return null;
  const pitch = x.playground_host_capture_pitch(app), w = c.width, hgt = c.height;
  const d = h.rt.bytes(p, pitch * hgt).slice();
  x.playground_host_capture_release(app);
  let bin = ''; for (let i = 0; i < d.length; i += 8192) bin += String.fromCharCode(...d.subarray(i, i + 8192));
  return { w, h: hgt, pitch, b64: btoa(bin) };
})()`;
async function grab(name) {
  const r = await js(GRAB);
  if (!r) { problems.push(`${name}: capture never completed`); return null; }
  const bytes = Buffer.from(r.b64, 'base64'); const rgba = new Uint8Array(r.w * r.h * 4);
  for (let y = 0; y < r.h; y++) for (let xx = 0; xx < r.w; xx++) {
    const o = y * r.pitch + xx * 4, q = (y * r.w + xx) * 4;
    rgba[q] = bytes[o]; rgba[q + 1] = bytes[o + 1]; rgba[q + 2] = bytes[o + 2]; rgba[q + 3] = 255;
  }
  writeFileSync(`${prefix}_${name}.png`, png(r.w, r.h, rgba));
  const colours = new Set();
  for (let q = 0; q < rgba.length; q += 4) colours.add((rgba[q] >> 3) << 10 | (rgba[q + 1] >> 3) << 5 | rgba[q + 2] >> 3);
  need(colours.size >= 30, `${name}: the frame shows a scene (${colours.size} colours)`);
  return rgba;
}
const differ = (a, b) => { let n = 0; for (let q = 0; q < a.length; q += 4) if (Math.abs(a[q] - b[q]) + Math.abs(a[q + 1] - b[q + 1]) + Math.abs(a[q + 2] - b[q + 2]) > 30) n++; return n; };

for (let i = 0; i < 240; i++) { if ((await js('window.host && window.host.frames')) > 10) break; await sleep(250); }
console.log('frames', await js('window.host && window.host.frames'), 'error', await js('window.host && window.host.error'));
need((await js('window.host && window.host.frames')) > 10, 'the Frontier page draws frames');
const hub = await grab('hub');
await key('keydown', 'KeyW'); await key('keydown', 'KeyD');
await sleep(2500);
await key('keyup', 'KeyD'); await key('keyup', 'KeyW');
const moved = await grab('moved');
if (hub && moved) { const n = differ(hub, moved); need(n > 5000, `holding W and D changed the picture (${n} pixels)`); }
// the converted assets: both characters and the wall are on the page before the character checks
for (let i = 0; i < 400; i++) { if ((await js('window.host && window.host.assets')) >= 3) break; await sleep(100); }
need((await js('window.host && window.host.assets')) === 3, 'the page loads the three converted assets (both characters, the wall)');
// B1 (design 1.10): the rest-pose palette, applied by the CPU reference, against root_transform * p (< 1e-4)
for (const [which, name] of [[1, 'CesiumMan'], [2, 'Fox']]) {
  const err = await js(`window.host.x.playground_host_b1_check(window.host.app, ${which})`);
  console.log(`${name} rest pose: max |palette * p - root_transform * p| = ${err}`);
  need(err >= 0 && err < 1e-4, `B1: the ${name} rest pose reproduces root_transform * p (max error ${err})`);
}
// M6 (design 1.9): the 20 query frames of CesiumMan's clip return their own frames; the hash of the matched indices is
// the value tests/motion_match_native.mojo prints (437896, three CMU trials). Native and wasm must agree on it.
const M6_NATIVE_HASH = 437896;
const m6 = await js('window.host.x.playground_host_motion_hash(window.host.app)');
console.log(`M6 motion-match hash on the page: ${m6} (native ${M6_NATIVE_HASH})`);
need(m6 === M6_NATIVE_HASH, `M6: the page's motion matching returns the same 20 indices as native (hash ${m6})`);
// B3 (design 1.10): every vertex, GPU against CPU, below 1e-3 m. CesiumMan clip 0 at frames 0, 15, 30, 45, 60 and the
// Fox's Walk at 0, 11, 22. The Fox's units are centimetres; the host scales its differences to metres.
// CesiumMan's clip is the 33-frame walk (kind 101); the Fox's is its Walk clip (23 frames)
const b3Cases = [[1, 0], [1, 8], [1, 16], [1, 24], [1, 32], [2, 0], [2, 11], [2, 22]];
for (const [which, frame] of b3Cases) {
  const name = which === 1 ? 'CesiumMan' : 'Fox';
  const started = await js(`window.host.x.playground_host_b3_start(window.host.app, ${which}, ${frame})`);
  let err = -1;
  if (started === 0) {
    for (let i = 0; i < 400; i++) {
      err = await js('window.host.x.playground_host_b3_result(window.host.app)');
      if (err !== -1) break;
      await sleep(25);
    }
  }
  console.log(`B3 ${name} frame ${frame}: max |GPU - CPU| = ${err} m`);
  need(started === 0 && err >= 0 && err < 1e-3, `B3: ${name} frame ${frame}, every vertex GPU against CPU below 1e-3 m (max ${err} m)`);
}
// the characters animate with no input: the picture changes between frame 30 and frame 60
for (let i = 0; i < 600; i++) { if ((await js('window.host && window.host.frames')) >= 30) break; await sleep(100); }
const idle30 = await grab('idle30');
for (let i = 0; i < 600; i++) { if ((await js('window.host && window.host.frames')) >= 60) break; await sleep(100); }
const idle60 = await grab('idle60');
if (idle30 && idle60) { const n = differ(idle30, idle60); need(n > 500, `idle: the picture changes between frame 30 and frame 60 (${n} pixels), so the characters animate`); }
// C2, on the page: the wall texture's mip 0 and mip 4 read back from the GPU equal the converted levels exactly
const texStarted = await js('window.host.x.playground_host_texture_start(window.host.app)');
need(texStarted === 0, 'C2: the texture readback starts once the wall is on the renderer');
let texErr = -1;
for (let i = 0; i < 400; i++) {
  texErr = await js('window.host.x.playground_host_texture_result(window.host.app)');
  if (texErr !== -1) break;
  await sleep(25);
}
console.log(`wall texture readback: max channel difference from the converted levels = ${texErr}`);
need(texErr === 0, `C2: the GPU's mip 0 and mip 4 of layer 1 equal the converted levels (max difference ${texErr})`);
const pageError = await js('window.host.error');
console.log('page error:', JSON.stringify(pageError));
need(pageError === '', 'no page error');
console.log(problems.length ? `host-check: FAIL\n  ${problems.join('\n  ')}` : 'host-check: PASS');
done(problems.length ? 1 : 0);
