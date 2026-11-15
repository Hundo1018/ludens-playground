// The quarry's fractured wall breaks under a dropped weight (plan W7; the plan's pendulum cannot reach the wall, see the
// PR). Headless Chrome on a software WebGPU adapter. The fragment numbers come from the Frontier stats 11 (fragments
// loose), 12 (fragments the wall was cut into) and 14 (fracture events since the start) (frontier/world.mojo).
// usage: node scripts/physics_check.mjs <chrome> <url> [timeout_s]
// Checks: no wall before the player comes near; after the player is 17 m away the wall is released, falls 6 m and breaks.
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
// the player walks to 18 m from the wall (it is released within 20 m), and the wall falls and breaks
await js(`window.host.x.playground_host_frontier_teleport(window.host.app, 100, -110)`);  // 18 m from the wall, inside the 20 m release radius
let events = 0;
for (let i = 0; i < 120 && events === 0; i++) { await sleep(250); events = await stat(14); }
const fragments = await stat(12);
console.log(`after the wall falls: ${events} fracture events; fragments ${fragments}, loose ${await stat(11)}`);
need(fragments > 1, `the wall is cut into fragments once released (${fragments})`);
need(events > 0, `the wall falls and breaks: a fracture event (${events})`);
need((await js('window.host.error')) === '', 'no page error');
console.log(problems.length ? `physics-check: FAIL\n  ${problems.join('\n  ')}` : 'physics-check: PASS');
done(problems.length ? 1 : 0);
