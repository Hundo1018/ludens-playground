// Reference baseline B1 (original stage 2: a destructible wall and a jointed machine). The quarry's fractured wall stands on
// the ground; when the player comes within 20 m a 2000 kg bob on a 9 m hinge is released level with its pivot and swings into
// the wall. Headless Chrome on a software WebGPU adapter. Frontier stats: 11 fragments loose, 12 fragments the wall was cut
// into, 14 fracture events since the start, 16 the bob's z in millimetres (frontier/world.mojo).
// usage: node scripts/physics_check.mjs <chrome> <url> [timeout_s]
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [chrome, url, timeoutS = '240'] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'physics-check-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=960,600', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const problems = [];
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('physics-check: timed out'); done(1); }, Number(timeoutS) * 1000);
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
const stat = (which) => js(`window.host.x.playground_host_frontier_stat(window.host.app, ${which})`);

await send('Runtime.enable');
await send('Page.enable');
await send('Page.navigate', { url: url + '?notown' });
for (let i = 0; i < 900; i++) { if ((await js('window.host && window.host.assets')) >= 5 && (await js('window.host.frames')) >= 10) break; await sleep(100); }
const err = await js('window.host && window.host.error');
need(!err, `the page starts without error (${err || 'none'})`);
const fragments0 = await stat(12);
need(fragments0 === 0, `the wall is not there before the player comes near (${fragments0} fragments)`);
const events0 = await stat(14);
need(events0 === 0, `no fracture event before the player comes near (${events0})`);
// the player walks to 18 m from the wall: the wall and the pendulum are added
await js(`window.host.x.playground_host_frontier_teleport(window.host.app, 100, -110)`);
let bobZ0 = -1;
for (let i = 0; i < 80 && bobZ0 === -1; i++) { await sleep(50); bobZ0 = await stat(16); }
need(bobZ0 !== -1, `the pendulum exists once the player is near (bob z ${bobZ0} mm)`);
const eventsEarly = await stat(14);
need(eventsEarly === 0, `the wall stands by itself before the bob reaches it (${eventsEarly} events)`);
let events = 0;
for (let i = 0; i < 120 && events === 0; i++) { await sleep(250); events = await stat(14); }
const bobZ1 = await stat(16);
const fragments = await stat(12);
console.log(`bob z ${bobZ0} -> ${bobZ1} mm; ${events} fracture events; fragments ${fragments}, loose ${await stat(11)}`);
need(Math.abs(bobZ1 - bobZ0) > 3000, `the bob swings toward the wall (z ${bobZ0} -> ${bobZ1} mm)`);
need(events > 0, `the bob breaks the wall: a fracture event (${events})`);
need(fragments > 1, `the wall is cut into fragments (${fragments})`);
{ const pageErr = await js('window.host.error'); need(pageErr === '', `no page error (${pageErr || 'none'})`); }
console.log(problems.length ? `physics-check: FAIL\n  ${problems.join('\n  ')}` : 'physics-check: PASS');
done(problems.length ? 1 : 0);
