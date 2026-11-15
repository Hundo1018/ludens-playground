// Reference baselines D1 (behavior tree) and D2 (perception) in the browser. The player is placed at corner 0 of the town
// square, where residents pass. The residents run a shared behavior tree (walk to a corner, wait, next corner; stop and
// watch a player within 4 m); the guard sees through a 110-degree cone with line of sight against the buildings.
// Within 15 s: the trees make transitions, at least one resident watches, and the guard sees the player at least once.
// usage: node scripts/town_ai_check.mjs <chrome> <url> [timeout_s=300]
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [chrome, url, timeoutS = '300'] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'town-ai-check-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=1280,720', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const problems = [];
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('town-ai-check: timed out'); done(1); }, Number(timeoutS) * 1000);
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
const ai = (which) => js(`window.host.x.playground_host_town_ai(window.host.app, ${which})`);

await send('Runtime.enable'); await send('Page.enable');
await send('Page.navigate', { url });
for (let i = 0; i < 900; i++) { if ((await js('window.host && window.host.frames')) >= 30) break; await sleep(100); }
need(!(await js('window.host.error')), 'the page starts without error');
need((await ai(0)) >= 0, 'the town is on');
await js('window.host.x.playground_host_frontier_teleport(window.host.app, 112, 112)');
let watchMax = 0, seen = 0, trans = 0;
for (let i = 0; i < 60; i++) {
  await sleep(250);
  trans = await ai(0);
  watchMax = Math.max(watchMax, await ai(1));
  seen += await ai(2);
  if (trans > 0 && watchMax > 0 && seen > 0) break;
}
console.log(`behavior-tree transitions ${trans}; residents watching up to ${watchMax}; samples with the guard seeing the player ${seen}`);
need(trans > 0, `the residents' behavior trees make transitions (${trans})`);
need(watchMax > 0, `a resident near the player stops and watches (${watchMax})`);
need(seen > 0, `the guard sees the player in its cone with line of sight (${seen} samples)`);
need(!(await js('window.host.error')), 'no page error');
console.log(problems.length ? `town-ai-check: FAIL\n  ${problems.join('\n  ')}` : 'town-ai-check: PASS');
done(problems.length ? 1 : 0);
