// W6 guard rule in the browser: a player placed in the town square, a few metres from the guard, is touched by it once,
// is sent back to the hub (the player at the origin), and is not touched again while it stays there.
// usage: node scripts/guard_check.mjs <chrome> <url> [timeout_s=300]
// The town steps with the simulation (frame), so the page could also be offscreen; this check keeps the canvas path.
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [chrome, url, timeoutS = '300'] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'guard-check-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=1280,720', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const problems = [];
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('guard-check: timed out'); done(1); }, Number(timeoutS) * 1000);
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
// the contact comes within a few seconds: the guard starts 6 m from the player, inside the square
let c = 0;
for (let i = 0; i < 150 && c === 0; i++) { await sleep(200); c = await contacts(); }
need(c === 1, `the guard touches the player once (contacts ${c})`);
await sleep(300);
const [px, pz] = await player();
need(Math.hypot(px, pz) < 1.0, `the player is back at the hub, not in the square (${px.toFixed(1)}, ${pz.toFixed(1)})`);
await sleep(5000);
need((await contacts()) === 1, 'the guard does not touch the player again while it stays at the hub');
console.log(problems.length ? `guard-check: FAIL\n  ${problems.join('\n  ')}` : 'guard-check: PASS');
done(problems.length ? 1 : 0);
