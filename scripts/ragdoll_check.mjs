// B4 (RDR2's physics reactions): when the guard touches the player it is knocked down. A figure of six bodies on ball
// joints stands where the guard was and falls under physics; the skinned guard is hidden while it lies there.
// Checks: no figure before the contact; after it the pelvis starts near 0.65 m (CesiumMan's) and is more than 0.5 m
// lower within 3 s.
// usage: node scripts/ragdoll_check.mjs <chrome> <url> [timeout_s=300]
// The page may be offscreen: the town steps with the simulation (frame), not in the draw path.
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [chrome, url, timeoutS = '300'] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'ragdoll-check-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=1280,720', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const problems = [];
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('ragdoll-check: timed out'); done(1); }, Number(timeoutS) * 1000);
const port = await new Promise((res) => { let b = ''; proc.stderr.on('data', (d) => { b += d; const m = b.match(/DevTools listening on ws:\/\/[^:]+:(\d+)\//); if (m) res(m[1]); }); });
const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r));
let id = 0; const pending = new Map();
ws.addEventListener('message', (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result ?? m.error); pending.delete(m.id); } });
const send = (method, params = {}) => new Promise((r) => { pending.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });
const js = async (expression) => (await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }))?.result?.value;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const need = (ok, label) => { console.log(`  [${ok ? 'PASS' : 'FAIL'}] ${label}`); if (!ok) problems.push(label); };
const contacts = () => js('window.host.x.playground_host_contacts(window.host.app)');
const player = async () => [await js('window.host.x.playground_host_protagonist(window.host.app, 3)'),
                            await js('window.host.x.playground_host_protagonist(window.host.app, 4)')];

await send('Runtime.enable'); await send('Page.enable');
await send('Page.navigate', { url });
for (let i = 0; i < 900; i++) { if ((await js('window.host && window.host.frames')) >= 30) break; await sleep(100); }
need(!(await js('window.host.error')), 'the page starts without error');
const pelvis = () => js('window.host.x.playground_host_frontier_stat(window.host.app, 21)');
need((await pelvis()) === -1, 'no figure before the contact');
let c = 0;
for (let i = 0; i < 300 && c === 0; i++) { await sleep(100); c = await contacts(); }
need(c >= 1, `the guard touches the player (contacts ${c})`);
let first = -1;
for (let i = 0; i < 50 && first === -1; i++) { await sleep(20); first = await pelvis(); }
need(first > 550, `the figure appears standing (CesiumMan's pelvis is at 0.65 m): pelvis ${first} mm`);
let low = first;
const samples = [];
for (let i = 0; i < 30; i++) { await sleep(100); const p = await pelvis(); samples.push(p); if (p < low) low = p; }
console.log('pelvis mm every 100 ms:', samples.join(' '));
need(first - low > 500, `the pelvis falls more than 0.5 m within 3 s: ${first} -> ${low} mm`);
need(low > -200, `the figure stays above the ground: lowest pelvis ${low} mm`);
console.log(problems.length ? `ragdoll-check: FAIL\n  ${problems.join('\n  ')}` : 'ragdoll-check: PASS');
done(problems.length ? 1 : 0);
