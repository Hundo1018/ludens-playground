// Reference baseline C (Battlefield 1: destruction synchronized across players), in the page's wasm: a fractured wall on a
// SnapshotServer with two SnapshotClients (app/net_fracture.mojo). A 2000 kg crate breaks the wall on the server; the
// clients load the server's snapshots. For the baseline's link (latency 4) and the page's lossy link (latency 4, jitter 3,
// 10 % loss): both clients reach tick 240, their read-back hashes equal the server's, the fragments have settled, the wall
// broke, each client shows the server's moved fragments, and the settled snapshots cost less than the break.
// usage: node scripts/fracnet_check.mjs <chrome> <url> [timeout_s=300]
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [chrome, url, timeoutS = '300'] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'fracnet-check-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=1280,720', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const problems = [];
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('fracnet-check: timed out'); done(1); }, Number(timeoutS) * 1000);
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

await send('Runtime.enable'); await send('Page.enable');
await send('Page.navigate', { url });
for (let i = 0; i < 900; i++) { if ((await js('window.host && window.host.frames')) >= 10) break; await sleep(100); }
need(!(await js('window.host.error')), 'the page starts without error');
const stat = (k) => js(`window.host.x.playground_host_fracture_net_stat(window.host.app, ${k})`);
for (const [lat, jit, loss, name] of [[4, 0, 0, 'latency 4'], [4, 3, 100, 'latency 4, jitter 3, loss 10 %']]) {
  const t0 = Date.now();
  const r = await js(`window.host.x.playground_host_fracture_net(window.host.app, ${lat}, ${jit}, ${loss})`);
  const s = []; for (let k = 0; k <= 8; k++) s.push(await stat(k));
  console.log(`${name}: result ${r} in ${Date.now() - t0} ms; events ${s[0]}, moved ${s[1]}/${s[2]}/${s[3]}, bytes break ${s[4]}, settled ${s[5]}, frames ${s[8]}`);
  need(r === 1, `${name}: both clients reach tick 240 with hashes equal to the server's and the fragments settled (result ${r})`);
  need(s[6] === 1 && s[7] === 1, `${name}: hashes equal (${s[6]}), settled (${s[7]})`);
  need(s[0] > 0, `${name}: the wall breaks (${s[0]} fracture events)`);
  need(s[1] > 0 && s[2] === s[1] && s[3] === s[1], `${name}: each client shows the server's ${s[1]} moved fragments (${s[2]}, ${s[3]})`);
  need(s[5] < s[4], `${name}: settled snapshots cost less than the break (${s[5]} < ${s[4]} bytes)`);
}
console.log(problems.length ? `fracnet-check: FAIL\n  ${problems.join('\n  ')}` : 'fracnet-check: PASS');
done(problems.length ? 1 : 0);
