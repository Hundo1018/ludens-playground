// Reference baselines B2 (rope) and B3 (cloth banner) in the browser: the player is placed in the camp, which builds a rope
// of 12 capsules on ball joints hanging from a beam (its end ball pushed sideways) and a cloth banner pinned to a pole in a
// wind. Over 10 s: the rope's length stays within 5 % of its rest length, the end ball swings, the banner's free corner moves
// more than 0.1 m and its pinned edge less than 1 mm. Frontier stats 17 to 20 (frontier/world.mojo).
// usage: node scripts/camp_check.mjs <chrome> <url> [timeout_s=300]
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [chrome, url, timeoutS = '300'] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'camp-check-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=1280,720', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const problems = [];
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('camp-check: timed out'); done(1); }, Number(timeoutS) * 1000);
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
const stat = (which) => js(`window.host.x.playground_host_frontier_stat(window.host.app, ${which})`);

await send('Runtime.enable'); await send('Page.enable');
await send('Page.navigate', { url });
for (let i = 0; i < 900; i++) { if ((await js('window.host && window.host.frames')) >= 30) break; await sleep(100); }
need(!(await js('window.host.error')), 'the page starts without error');
need((await stat(17)) === -1, 'no rope before the player comes near the camp');
await js('window.host.x.playground_host_frontier_teleport(window.host.app, -110, -106)');
let built = -1;
for (let i = 0; i < 100 && built === -1; i++) { await sleep(100); built = await stat(17); }
need(built !== -1, `the camp is built once the player is near (rope ${built} permille)`);
let lenMin = 1e9, lenMax = 0, swingMax = 0, cornerMax = 0, pinMax = 0;
for (let i = 0; i < 40; i++) {
  await sleep(250);
  const l = await stat(17); lenMin = Math.min(lenMin, l); lenMax = Math.max(lenMax, l);
  swingMax = Math.max(swingMax, await stat(18));
  cornerMax = Math.max(cornerMax, await stat(19));
  pinMax = Math.max(pinMax, await stat(20));
}
console.log(`rope length ${lenMin}..${lenMax} permille; end ball swing up to ${swingMax} mm; banner corner up to ${cornerMax} mm; pinned edge up to ${pinMax} um`);
need(lenMin >= 950 && lenMax <= 1050, `the rope's length stays within 5 % of its rest length (${lenMin}..${lenMax} permille)`);
need(swingMax > 300, `the rope swings: its end ball moves more than 0.3 m sideways (${swingMax} mm)`);
need(cornerMax > 100, `the banner moves: its free corner leaves its rest position by more than 0.1 m (${cornerMax} mm)`);
need(pinMax < 1000, `the banner's pinned edge stays within 1 mm (${pinMax} um)`);
need(!(await js('window.host.error')), 'no page error');
console.log(problems.length ? `camp-check: FAIL\n  ${problems.join('\n  ')}` : 'camp-check: PASS');
done(problems.length ? 1 : 0);
