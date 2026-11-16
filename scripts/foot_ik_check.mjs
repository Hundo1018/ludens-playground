// Reference baseline E2 (foot IK): two CesiumMen walk in place on 20 degree ramps in the hub, one with app/foot_ik.mojo
// (procedural.ik.two_bone) and one without. Over at least 120 drawn frames: the worst foot error with IK stays under 10 mm;
// without IK it exceeds 50 mm (the ramp matters). The page is not offscreen: the walkers are posed in the draw path.
// usage: node scripts/foot_ik_check.mjs <chrome> <url> [timeout_s=300]
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [chrome, url, timeoutS = '300'] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'foot-ik-check-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=1280,720', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const problems = [];
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('foot-ik-check: timed out'); done(1); }, Number(timeoutS) * 1000);
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
const ik = (k) => js(`window.host.x.playground_host_foot_ik(window.host.app, ${k})`);
for (let i = 0; i < 600 && (await ik(2)) < 120; i++) await sleep(100);
const [withIk, without, frames] = [await ik(0), await ik(1), await ik(2)];
console.log(`foot error over ${frames} drawn frames: with IK ${withIk} um, without ${without} um`);
need(frames >= 120, `the walkers were posed on at least 120 frames (${frames})`);
need(withIk < 10000, `with IK every foot stays within 10 mm of the ramp (${(withIk / 1000).toFixed(2)} mm)`);
need(without > 50000, `without IK a foot is off the ramp by more than 50 mm (${(without / 1000).toFixed(1)} mm)`);
console.log(problems.length ? `foot-ik-check: FAIL\n  ${problems.join('\n  ')}` : 'foot-ik-check: PASS');
done(problems.length ? 1 : 0);
