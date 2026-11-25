// The visual showcase in headless Chrome (software WebGPU, SwiftShader): frames draw, the CJK font loads, every one of the
// seven switches changes the picture, the scene's hash equals the native one, and the frame time is measured with every
// effect on and with all off.
// usage: node scripts/showcase_check.mjs <chrome> <url> <out-prefix> [timeout_s] [native_hash]
//   url: ".../showcase/index.html?offscreen&bench" (offscreen: draw into a target, never the canvas; bench: every frame)
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { png } from './frame_png.mjs';

const [chrome, url, prefix, timeoutS = '300', nativeHash = ''] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'showcase-check-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=1320,900', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('showcase_check: timed out'); done(1); }, Number(timeoutS) * 1000);
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

const GRAB = `(async () => {
  const h = window.host, x = h.x, app = h.app, c = document.querySelector('canvas');
  x.showcase_request_capture(app);
  for (let i = 0; i < 900 && x.showcase_capture_ptr(app) === 0n; i++) await new Promise((r) => requestAnimationFrame(r));
  const p = x.showcase_capture_ptr(app); if (p === 0n) return null;
  const pitch = x.showcase_capture_pitch(app), w = c.width, hgt = c.height;
  const d = h.rt.bytes(p, pitch * hgt).slice();
  x.showcase_capture_release(app);
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
  return rgba;
}
// pixels whose summed channel difference is above 30 of 765
const differ = (a, b) => { let n = 0; for (let q = 0; q < a.length; q += 4) if (Math.abs(a[q] - b[q]) + Math.abs(a[q + 1] - b[q + 1]) + Math.abs(a[q + 2] - b[q + 2]) > 30) n++; return n; };
const colours = (a) => { const s = new Set(); for (let q = 0; q < a.length; q += 4) s.add((a[q] >> 3) << 10 | (a[q + 1] >> 3) << 5 | a[q + 2] >> 3); return s.size; };
// BigInt results come back as strings (returnByValue cannot carry a BigInt)
const x = (expr) => js(`(() => { const x = window.host.x, app = window.host.app; const v = ${expr}; return typeof v === 'bigint' ? v.toString() : v; })()`);
const stat = async (i) => Number(await x(`x.showcase_stat(app, ${i})`));

for (let i = 0; i < 480; i++) { if ((await js('window.host && window.host.frames')) > 30 && await js('window.host.font')) break; await sleep(250); }
console.log('frames', await js('window.host && window.host.frames'), 'error', await js('window.host && window.host.error'));
need((await js('window.host && window.host.frames')) > 30, 'the showcase draws frames');
need(await js('window.host.font'), 'the CJK font (NotoSansTC-Regular-24.lfont, sha256 checked) loads');
need((await js('window.host.error')) === '', 'no page error');

// the hash of the scene alone, against the native build's (tests/showcase_native.mojo prints it)
const h600 = await x("BigInt.asUintN(64, x.showcase_hash(600))");
console.log('showcase_hash(600) on wasm64:', h600);
if (nativeHash) need(h600 === nativeHash, `wasm64 hash equals native (${h600} vs ${nativeHash})`);

// Frame cost: in ?offscreen mode the host draws only when a capture is asked for, so the time from the request to the
// mapped pixels is one whole frame on the GPU (scene step, encode, the passes and stages, the HUD) plus a read-back of
// 1280 x 720 x 4 bytes. The step and encode times (CPU, inside the frame call) come from the host for the same frame.
const ROUNDTRIP = `(async (n) => {
  const h = window.host, x = h.x, app = h.app, out = [];
  for (let k = 0; k < n; k++) {
    const t0 = performance.now();
    x.showcase_request_capture(app);
    for (let i = 0; i < 900 && x.showcase_capture_ptr(app) === 0n; i++) await new Promise((r) => requestAnimationFrame(r));
    const t1 = performance.now();
    if (x.showcase_capture_ptr(app) === 0n) return null;
    x.showcase_capture_release(app);
    out.push([t1 - t0, x.showcase_timing(app, 0), x.showcase_timing(app, 1)]);
  }
  return out;
})`;
const TIMING_N = Number(process.env.SHOWCASE_TIMING_N || 5);
async function timing(label, n = TIMING_N) {
  const r = await js(`${ROUNDTRIP}(${n})`);
  if (!r) { problems.push(`${label}: timing capture never completed`); return null; }
  const col = (c) => r.map((v) => v[c]).sort((a, b) => a - b);
  const q = (a, p) => a[Math.min(a.length - 1, Math.floor(p * a.length))];
  const rt = col(0), st = col(1), dr = col(2);
  const row = { label, n: r.length, median: q(rt, 0.5), p90: q(rt, 0.9), min: rt[0], step: q(st, 0.5), draw: q(dr, 0.5),
    bodies: await stat(0), particles: await stat(1), draws: await stat(6), triangles: await stat(7) };
  console.log(`  timing ${label}: request to pixels median ${row.median.toFixed(1)} ms (min ${row.min.toFixed(1)}, p90 ${row.p90.toFixed(1)}) ` +
    `over ${row.n}; step ${row.step.toFixed(2)} ms, encode ${row.draw.toFixed(1)} ms; bodies ${row.bodies}, particles ${row.particles}, ` +
    `draw calls ${row.draws}, triangles ${row.triangles}`);
  return row;
}
const rows = [];
rows.push(await timing('all on'));
console.log('samples', await stat(5), 'drops', await stat(2), 'spark bursts', await stat(3));
need((await stat(5)) === 4, 'the renderer draws with 4 samples (MSAA)');
need((await stat(3)) > 0, `impacts started spark bursts (${await stat(3)})`);
need((await stat(1)) > 200, `particles are alive (${await stat(1)})`);

// stop the clock (frames of dt 0 only), then one picture per switch turned off, each against the full picture
await x('x.showcase_hold(app, 1)');
const base = await grab('all_on');
need(base && colours(base) >= 200, `the full picture has many colours (${base ? colours(base) : 0} of 32768 levels)`);
const NAMES = ['msaa', 'fxaa', 'bloom', 'grade', 'shadow', 'lights', 'particles'];
const changed = {};
for (let i = 0; i < NAMES.length; i++) {
  if (i === 1) continue;  // FXAA starts off: it is checked by turning it on below
  await x(`x.showcase_toggle(app, ${i}, 0)`);
  const img = await grab(`no_${NAMES[i]}`);
  await x(`x.showcase_toggle(app, ${i}, 1)`);
  if (!img || !base) continue;
  changed[NAMES[i]] = differ(base, img);
}
await x('x.showcase_toggle(app, 1, 1)');
const fxaa = await grab('fxaa_on');
await x('x.showcase_toggle(app, 1, 0)');
if (fxaa && base) changed.fxaa = differ(base, fxaa);
console.log('pixels changed against the full picture (of', base ? base.length / 4 : 0, '):', JSON.stringify(changed));
// the scene is held: two full pictures in a row must be the same
const again = await grab('all_on_again');
const outsideStats = (a, b) => { let n = 0; const w = 1280; for (let q = 0; q < a.length; q += 4) { const p = q / 4, px = p % w, py = Math.floor(p / w);
  if (px < 344 && py >= 200 && py < 272) continue; // the HUD's two stats lines change with the measured time
  if (Math.abs(a[q] - b[q]) + Math.abs(a[q + 1] - b[q + 1]) + Math.abs(a[q + 2] - b[q + 2]) > 30) n++; } return n; };
const motion = again && base ? outsideStats(base, again) : 0;
need(motion === 0, `two full pictures of the held scene are the same outside the HUD's stats lines (${motion} pixels differ)`);
for (const [k, n] of Object.entries(changed)) need(n > 200, `turning ${k} changes the picture (${n} pixels)`);

// all off: no MSAA, FXAA, bloom, grade, shadow, point lights
for (let i = 0; i < 6; i++) await x(`x.showcase_toggle(app, ${i}, 0)`);
const plain = await grab('all_off');
for (let i = 0; i < 6; i++) await x(`x.showcase_toggle(app, ${i}, ${i === 1 ? 0 : 1})`);
if (plain && base) console.log('pixels changed, all on against all off:', differ(base, plain));
await x('x.showcase_hold(app, 0)');
// SHOWCASE_TIMING_ALL=1: one row per switch turned off (about 40 s a row on SwiftShader at 1280 x 720; not in CI)
const perSwitch = process.env.SHOWCASE_TIMING_ALL ? [[0, 'MSAA off'], [2, 'bloom off'], [3, 'grade off'], [4, 'shadow off'], [5, 'point lights off'], [6, 'particles off']] : [];
for (const [i, name] of perSwitch) {
  await x(`x.showcase_toggle(app, ${i}, 0)`);
  rows.push(await timing(name));
  await x(`x.showcase_toggle(app, ${i}, 1)`);
}
for (let i = 0; i < 6; i++) await x(`x.showcase_toggle(app, ${i}, 0)`);
rows.push(await timing('all off but particles'));
for (let i = 0; i < 6; i++) await x(`x.showcase_toggle(app, ${i}, ${i === 1 ? 0 : 1})`);

console.log('\n| setting | captures | request to pixels, median ms | min | p90 | step ms (median) | encode ms (median) | bodies | particles | draw calls | triangles |');
console.log('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|');
for (const r of rows.filter(Boolean)) console.log(`| ${r.label} | ${r.n} | ${r.median.toFixed(1)} | ${r.min.toFixed(1)} | ${r.p90.toFixed(1)} | ${r.step.toFixed(2)} | ${r.draw.toFixed(1)} | ${r.bodies} | ${r.particles} | ${r.draws} | ${r.triangles} |`);
console.log(problems.length ? `showcase_check: ${problems.length} problem(s)` : 'showcase_check: all checks passed');
done(problems.length ? 1 : 0);
