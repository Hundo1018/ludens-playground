// Reference baseline E1 (motion matching): the town's CesiumMan characters pick their clip by motion matching on their
// velocity (app/town_motion.mojo). Sampled every 150 ms for 20 s with the player in the square (?at=112,142): the guard,
// moving at its 7 m/s, is on the run (kind 107) in some sample above 5 m/s and on a walk in some sample below 1.5 m/s (it
// slows at corners); the 24 residents (1.4 m/s) are on walks; clips switch.
// usage: node scripts/town_motion_check.mjs <chrome> <url> [timeout_s=300]
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [chrome, url, timeoutS = '300'] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'town-motion-check-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=1280,720', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const problems = [];
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('town-motion-check: timed out'); done(1); }, Number(timeoutS) * 1000);
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
const tm = (k) => js(`window.host.x.playground_host_town_motion(window.host.app, ${k})`);
for (let i = 0; i < 100 && (await tm(0)) < 0; i++) await sleep(100);
let fastRun = 0, fastOther = 0, slowWalk = 0, slowRun = 0, minWalks = 99, maxRunRes = 0;
const samples = [];
for (let i = 0; i < 133; i++) {
  await sleep(150);
  const v = await tm(4), kind = await tm(0), walks = await tm(1), runs = await tm(2);
  samples.push(`${v}/${kind}`);
  if (v > 5000) { if (kind === 107) fastRun++; else fastOther++; }
  if (v < 1500) { if (kind === 107) slowRun++; else slowWalk++; }
  minWalks = Math.min(minWalks, walks); maxRunRes = Math.max(maxRunRes, runs);
}
console.log('guard mm/s / clip kind:', samples.join(' '));
const switches = await tm(3);
console.log(`guard above 5 m/s: run ${fastRun}, other ${fastOther}; below 1.5 m/s: walk ${slowWalk}, run ${slowRun}; residents on walks at least ${minWalks}, on the run at most ${maxRunRes}; switches ${switches}`);
need(fastRun > 0, `the guard is on the run while above 5 m/s (${fastRun} samples; ${fastOther} on another clip)`);
need(slowWalk > 0, `the guard is on a walk while below 1.5 m/s (${slowWalk} samples; ${slowRun} on the run)`);
need(minWalks >= 20 && maxRunRes === 0, `the residents (1.4 m/s) stay on walks: at least ${minWalks} of 24 on walks, at most ${maxRunRes} on the run`);
need(switches > 0, `clips switch (${switches})`);
console.log(problems.length ? `town-motion-check: FAIL\n  ${problems.join('\n  ')}` : 'town-motion-check: PASS');
done(problems.length ? 1 : 0);
