// The step-7 crowd in a Worker (plan W11): the worker's crowd (crowd/crowd.wasm, app/crowd_host.mojo) and the page's host crowd
// (app/host.mojo playground_host_crowd_hash_after) take the same steps over the same pillars, so their hashes must be equal.
// Headless Chrome, software WebGPU. The worker is a module worker started on the page.
// usage: node scripts/crowd_worker_check.mjs <chrome> <url> [timeout_s]
// Checks: the worker starts and steps; its hash equals the host's for 64 members over 300 ticks; for 200 members too.
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [chrome, url, timeoutS = '300'] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'crowd-worker-check-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=960,600', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const problems = [];
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('crowd-worker-check: timed out'); done(1); }, Number(timeoutS) * 1000);
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

await send('Runtime.enable');
await send('Page.enable');
await send('Page.navigate', { url: url + '?notown&nonetview' });
for (let i = 0; i < 900; i++) { if ((await js('window.host && window.host.assets')) >= 5 && (await js('window.host.frames')) >= 10) break; await sleep(100); }
need(!(await js('window.host.error')), 'the page starts without error');

// the pillars, read from the host: the worker gets the same boxes
const boxes = await js(`(() => { const x = window.host.x, app = window.host.app; const n = x.playground_host_pillar_count(app); const out = []; for (let i = 0; i < n; i++) for (let k = 0; k < 6; k++) out.push(x.playground_host_pillar(app, i, k)); return out; })()`);
need(boxes.length >= 6, `the pillars are read from the host (${boxes.length / 6} boxes)`);

// the worker, started on the page
await js(`(() => { window.__cw = new Worker('./crowd.worker.mjs', { type: 'module' }); window.__cwq = {}; window.__cw.onmessage = (e) => { window.__cwq[e.data.id] = e.data; }; return true; })()`);
let nextId = 1;
const workerCall = async (msg, transfer = false) => {
  const mid = nextId++;
  await js(`window.__cw.postMessage(${JSON.stringify({ ...msg, id: mid })})`);
  for (let i = 0; i < 1200; i++) {
    const r = await js(`window.__cwq[${mid}] || null`);
    if (r) return r;
    await sleep(50);
  }
  return { ok: false, error: 'no reply' };
};

for (const n of [64, 200]) {
  const hostHash = await js(`window.host.x.playground_host_crowd_hash_after(window.host.app, ${n}, 300)`);
  const init = await workerCall({ op: 'init', n, boxes });
  need(init.ok, `the worker starts a crowd of ${n} (${init.error || 'ok'})`);
  const run = await workerCall({ op: 'run', ticks: 300 });
  need(run.ok, `the worker steps 300 ticks (${run.error || 'ok'})`);
  need(run.ok && run.hash === hostHash, `worker and host agree for ${n} members over 300 ticks (worker ${run.hash}, host ${hostHash})`);
  console.log(`  worker stepped ${n} members x 300 ticks in ${run.ms ? run.ms.toFixed(1) : '?'} ms`);
}
{ const pageErr = await js('window.host.error'); need(pageErr === '', `no page error (${pageErr || 'none'})`); }
console.log(problems.length ? `crowd-worker-check: FAIL\n  ${problems.join('\n  ')}` : 'crowd-worker-check: PASS');
done(problems.length ? 1 : 0);
