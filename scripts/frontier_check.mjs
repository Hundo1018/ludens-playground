// Walk the Frontier world on the playground page (frontier/world.mojo) in headless Chrome on a software WebGPU adapter.
// Ported from the engine's scripts/frontier_check.mjs (removed in the engine's #59, "the Frontier moves out to
// ludens-playground"). The world's numbers come from playground_host_frontier_stat, the fast-travel point from
// playground_host_frontier_teleport, and the frames from playground_host_request_capture.
// usage: node scripts/frontier_check.mjs <chrome> <url> <out-prefix> [timeout_s]
// Checks: only part of the map is loaded at the start, walking loads and unloads cells while the number in the scene stays
// bounded, each zone is reached, culling drops items, and the picture changes. Writes <out-prefix>_<zone>.png and prints
// the frame times.
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { deflateSync } from 'node:zlib';

const [chrome, url, prefix, timeoutS = '240'] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'frontier-check-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=960,600', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('frontier-check: timed out'); done(1); }, Number(timeoutS) * 1000);
const port = await new Promise((res) => { let b = ''; proc.stderr.on('data', (d) => { b += d; const m = b.match(/DevTools listening on ws:\/\/[^:]+:(\d+)\//); if (m) res(m[1]); }); });
// about:blank first, then Page.navigate: /json/new?<url> drops everything after an '&' in <url>.
const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r));
let id = 0; const pending = new Map();
const problems = [];
const need = (cond, what) => { console.log(`  [${cond ? 'PASS' : 'FAIL'}] ${what}`); if (!cond) problems.push(what); };
ws.addEventListener('message', (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result ?? m.error); pending.delete(m.id); }
  if (m.method === 'Runtime.consoleAPICalled') {
    const text = m.params.args.map((a) => a.value ?? a.description).join(' ');
    console.log('console:', text.slice(0, 600));
    if (/wgpu uncaptured error|playground_host_frontier|mapAsync refused/.test(text)) problems.push('browser console: ' + text.split('\n')[0]);
  }
  if (m.method === 'Runtime.exceptionThrown') { console.log('exception:', m.params.exceptionDetails.exception?.description); problems.push('page exception'); }
});
const send = (method, params = {}) => new Promise((r) => { pending.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });
const js = async (expression) => (await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }))?.result?.value;
await send('Runtime.enable');
await send('Page.enable');
await send('Page.navigate', { url });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const key = (type, code) => js(`window.dispatchEvent(new KeyboardEvent('${type}', { code: '${code}', bubbles: true }))`);
const STAT_NAMES = ['cells', 'cellsTotal', 'bodies', 'bodiesTotal', 'drawn', 'culled', 'loads', 'unloads', 'zone', 'tick'];
const stat = async () => {
  const vals = await js(`[${STAT_NAMES.map((_, i) => `window.host.x.playground_host_frontier_stat(window.host.app, ${i})`).join(', ')}]`);
  if (!vals || vals.some((v) => v < 0)) return null;
  const o = {}; STAT_NAMES.forEach((n, i) => { o[n] = vals[i]; });
  o.frameMs = await js('window.host.frameMs');
  return o;
};
const frames = (n) => js(`(async () => { for (let i = 0; i < ${n}; i++) await new Promise((r) => requestAnimationFrame(r)); })()`);

function png(w, h, rgba) {
  const crcT = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
  const crc = (b) => { let c = 0xffffffff; for (const x of b) c = crcT[(c ^ x) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (t, d) => { const b = Buffer.alloc(12 + d.length); b.writeUInt32BE(d.length, 0); b.write(t, 4); d.copy(b, 8); b.writeUInt32BE(crc(b.subarray(4, 8 + d.length)), 8 + d.length); return b; };
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) { raw[y * (w * 4 + 1)] = 0; Buffer.from(rgba.buffer, rgba.byteOffset + y * w * 4, w * 4).copy(raw, y * (w * 4 + 1) + 1); }
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}
const GRAB = `(async () => {
  const s = window.host, x = s.x, app = s.app, c = document.querySelector('canvas');
  x.playground_host_request_capture(app);
  for (let i = 0; i < 900 && x.playground_host_capture_ptr(app) === 0n; i++) await new Promise((r) => requestAnimationFrame(r));
  const p = x.playground_host_capture_ptr(app); if (p === 0n) return null;
  const pitch = x.playground_host_capture_pitch(app), w = c.width, h = c.height;
  const d = s.rt.bytes(p, pitch * h).slice(); x.playground_host_capture_release(app);
  let bin = ''; for (let i = 0; i < d.length; i += 8192) bin += String.fromCharCode(...d.subarray(i, i + 8192));
  return { w, h, pitch, b64: btoa(bin) };
})()`;
const shots = {};
async function shot(name) {
  const r = await js(GRAB);
  if (!r) { problems.push(`${name}: capture never completed`); return; }
  const bytes = Buffer.from(r.b64, 'base64'); const rgba = new Uint8Array(r.w * r.h * 4);
  for (let y = 0; y < r.h; y++) for (let xx = 0; xx < r.w; xx++) {
    const o = y * r.pitch + xx * 4, q = (y * r.w + xx) * 4;
    rgba[q] = bytes[o]; rgba[q + 1] = bytes[o + 1]; rgba[q + 2] = bytes[o + 2]; rgba[q + 3] = 255;
  }
  writeFileSync(`${prefix}_${name}.png`, png(r.w, r.h, rgba));
  const colours = new Set();
  for (let q = 0; q < rgba.length; q += 4) colours.add((rgba[q] >> 3) << 10 | (rgba[q + 1] >> 3) << 5 | rgba[q + 2] >> 3);
  shots[name] = rgba;
  need(colours.size >= 30, `${name}: the frame shows a scene (${colours.size} colours)`);  // a cleared frame has one
}
const differ = (a, b) => { let n = 0; for (let q = 0; q < a.length; q += 4) if (Math.abs(a[q] - b[q]) + Math.abs(a[q + 1] - b[q + 1]) + Math.abs(a[q + 2] - b[q + 2]) > 30) n++; return n; };

for (let i = 0; i < 240; i++) { if ((await js('window.host && window.host.frames')) > 10 && (await stat())) break; await sleep(250); }
console.log('frames', await js('window.host && window.host.frames'), 'error', await js('window.host && window.host.error'));
await js(`(() => { const o = GPUBuffer.prototype.mapAsync; GPUBuffer.prototype.mapAsync = function (...a) {
  return o.apply(this, a).catch((e) => { console.log('mapAsync refused: ' + e + ' (buffer ' + this.size + ' bytes, usage ' + this.usage + ', ' + this.mapState + ')'); throw e; }); }; })()`);
const s0 = await stat();
need((await js('location.search')).includes('offscreen'), 'the page was opened with its whole query string');
need(!!s0, 'the page publishes the world\'s numbers');
if (!s0) done(1);
console.log('start:', JSON.stringify(s0));
need(s0.cellsTotal === 256 && s0.cells > 4 && s0.cells < 40, `part of the map is loaded: ${s0.cells} of ${s0.cellsTotal} cells`);
need(s0.bodies > 0 && s0.bodies * 5 < s0.bodiesTotal, `${s0.bodies} of ${s0.bodiesTotal} props are in the scene`);
need(s0.zone === 0, 'the player starts in the hub');
await shot('hub');
const sd = await stat();
need(sd.culled > 0 && sd.drawn > 10, `culling: ${sd.drawn} drawn, ${sd.culled} culled`);

// walk: W held (yaw 0 looks along -z)
await key('keydown', 'KeyW');
let peak = 0; const times = [];
for (let i = 0; i < 16; i++) { await sleep(500); const s = await stat(); peak = Math.max(peak, s.bodies); times.push(s.frameMs); }
await key('keyup', 'KeyW');
const s1 = await stat();
console.log('walked:', JSON.stringify(s1));
need(s1.tick > s0.tick + 60, `the world ticked (${s1.tick - s0.tick} ticks)`);
need(s1.loads > s0.loads, `walking loaded cells (${s0.loads} -> ${s1.loads})`);
need(peak * 4 < s1.bodiesTotal, `the scene stayed small while walking (peak ${peak} props)`);
await shot('walked');
if (shots.hub && shots.walked) { const n = differ(shots.hub, shots.walked); need(n > 5000, `walking changed the picture (${n} pixels)`); }

// each zone, by fast travel; cells behind are unloaded
const ZONES = [['quarry', 112, -112, 1], ['camp', -112, -112, 2], ['town', 112, 112, 3], ['training', -112, 112, 4]];
for (const [name, x, z, zone] of ZONES) {
  const rc = await js(`window.host.x.playground_host_frontier_teleport(window.host.app, ${x}, ${z})`);
  await frames(20);
  const s = await stat();
  console.log(`${name}:`, JSON.stringify(s));
  need(rc === 0 && s.zone === zone, `${name}: the player is in zone ${zone}`);
  need(s.cells > 4 && s.cells < 40 && s.bodies * 4 < s.bodiesTotal, `${name}: ${s.cells} cells and ${s.bodies} props loaded`);
  need(s.drawn > 10 && s.culled > 0, `${name}: ${s.drawn} drawn, ${s.culled} culled`);
  await shot(name);
}
const s2 = await stat();
need(s2.unloads > 10, `cells left behind were unloaded (${s2.unloads} unloads)`);
if (shots.quarry && shots.town) { const n = differ(shots.quarry, shots.town); need(n > 5000, `the zones look different (${n} pixels between quarry and town)`); }
times.sort((a, b) => a - b);
console.log(`frame time while walking, captures off (median ${times[times.length >> 1].toFixed(2)} ms, max ${times[times.length - 1].toFixed(2)} ms)`);
{ const pageErr = await js('window.host.error'); need(pageErr === '', `no page error (${pageErr || 'none'})`); }

console.log(problems.length ? `frontier-check: FAIL\n  ${problems.join('\n  ')}` : 'frontier-check: PASS');
done(problems.length ? 1 : 0);
