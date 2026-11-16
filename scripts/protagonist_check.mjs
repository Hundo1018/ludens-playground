// The protagonist is a skinned character at the player's feet, facing its velocity (plan W3).
// Headless Chrome on a software WebGPU adapter. The host records, once per frame, the drawn protagonist and the player's
// own state (playground_host_protagonist), so every sample below is from one frame.
// usage: node scripts/protagonist_check.mjs <chrome> <url> [timeout_s]
// The page runs as a visitor's does (drawing every frame), not with ?offscreen, which draws only on a capture request.
// Checks: while W is held the drawn position equals the player's within 1 cm on every sample, and the drawn heading
// equals the velocity heading within 5 degrees on every sample with the player moving; after release the drawn heading
// keeps its last value (the figure does not spin while it stands still).
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [chrome, url, timeoutS = '240'] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'protagonist-check-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=960,600', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const problems = [];
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('protagonist-check: timed out'); done(1); }, Number(timeoutS) * 1000);
const need = (cond, what) => { console.log(`  [${cond ? 'PASS' : 'FAIL'}] ${what}`); if (!cond) problems.push(what); };
const port = await new Promise((res) => { let b = ''; proc.stderr.on('data', (d) => { b += d; const m = b.match(/DevTools listening on ws:\/\/[^:]+:(\d+)\//); if (m) res(m[1]); }); });
const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r));
let id = 0; const pending = new Map();
ws.addEventListener('message', (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result ?? m.error); pending.delete(m.id); } });
const send = (method, params = {}) => new Promise((r) => { pending.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });
const js = async (expression) => (await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }))?.result?.value;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const key = (type, code) => js(`window.dispatchEvent(new KeyboardEvent('${type}', { code: '${code}', bubbles: true }))`);
const prot = (which) => js(`window.host.x.playground_host_protagonist(window.host.app, ${which})`);
// all six values in one evaluation: one frame, so the drawn and the player's values are from the same moment
const snap = async () => { const v = await js('[0,1,2,3,4,5].map((i) => window.host.x.playground_host_protagonist(window.host.app, i))'); return { dx: v[0], dz: v[1], dh: v[2], px: v[3], pz: v[4], vh: v[5] }; };

await send('Runtime.enable');
await send('Page.enable');
await send('Page.navigate', { url: url + '?notown' });
for (let i = 0; i < 900; i++) { if ((await js('window.host && window.host.assets')) >= 5 && (await js('window.host.frames')) >= 10) break; await sleep(100); }
const err = await js('window.host && window.host.error');
need(!err, `the page starts without error (${err || 'none'})`);
need((await prot(2)) !== 0 || (await prot(5)) === 0, 'the protagonist is placed once the Fox is up');

await key('keydown', 'KeyW');
const walk = [];
for (let i = 0; i < 40; i++) { await sleep(75); walk.push(await snap()); }
await key('keyup', 'KeyW');
const moving = walk.filter((s) => Math.hypot(s.px - walk[0].px, s.pz - walk[0].pz) > 0.2 || Math.abs(s.vh - walk[0].vh) > 0);
need(walk[walk.length - 1].px !== walk[0].px || walk[walk.length - 1].pz !== walk[0].pz, 'the player moves while W is held');
const posErr = Math.max(...walk.map((s) => Math.hypot(s.dx - s.px, s.dz - s.pz)));
console.log(`walking: worst drawn-to-player position error ${(posErr * 1000).toFixed(2)} mm over ${walk.length} frames`);
need(posErr < 0.01, `the drawn protagonist stands on the player within 1 cm while walking (${(posErr * 1000).toFixed(2)} mm)`);
const headingErr = (s) => { let d = Math.abs(s.dh - s.vh) % (2 * Math.PI); if (d > Math.PI) d = 2 * Math.PI - d; return d; };
const fast = walk.filter((s) => Math.hypot(s.dx - walk[0].dx, s.dz - walk[0].dz) > 0.05);
const worstHeading = Math.max(...fast.map(headingErr));
console.log(`walking: worst heading error ${((worstHeading * 180) / Math.PI).toFixed(2)} degrees over ${fast.length} moving frames`);
need(fast.length > 5 && worstHeading < (5 * Math.PI) / 180, `the drawn heading equals the velocity heading within 5 degrees (${fast.length} moving frames)`);

const stopped = await snap();
await sleep(600);
const later = await snap();
need(Math.abs(later.dh - stopped.dh) < 0.01, 'after the player stops, the drawn heading keeps its last value');
{ const pageErr = await js('window.host.error'); need(pageErr === '', `no page error (${pageErr || 'none'})`); }
console.log(problems.length ? `protagonist-check: FAIL\n  ${problems.join('\n  ')}` : 'protagonist-check: PASS');
done(problems.length ? 1 : 0);
