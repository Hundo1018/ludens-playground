// Camera look on the Frontier page (plan W1): a mouse drag with the left button held turns the camera, a move without
// the button does not. Headless Chrome on a software WebGPU adapter; the yaw is read from the Frontier stat index 10
// (frontier/world.mojo STAT_YAW_MRAD, milliradians).
// usage: node scripts/look_check.mjs <chrome> <url> [timeout_s]
// Checks: a 300 px drag turns the yaw by 300 * 0.006 rad within 10 % (frontier/world.mojo update); a move with no button
// held leaves the yaw unchanged to within 1 mrad.
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [chrome, url, timeoutS = '240'] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'look-check-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=960,600', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const problems = [];
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('look-check: timed out'); done(1); }, Number(timeoutS) * 1000);
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
await send('Page.navigate', { url: url + '?offscreen' });
for (let i = 0; i < 900; i++) { if ((await js('window.host && window.host.assets')) >= 5 && (await js('window.host.frames')) >= 10) break; await sleep(100); }
const err = await js('window.host && window.host.error');
need(!err, `the page starts without error (${err || 'none'})`);
const yaw = () => js('window.host.x.playground_host_frontier_stat(window.host.app, 10)');
const settle = async () => { const a = await yaw(); await sleep(400); return (await yaw()) - a; };

const rect = await js(`(() => { const r = document.querySelector('canvas').getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; })()`);
const cx = rect[0] + rect[2] / 2, cy = rect[1] + rect[3] / 2;

// no button: a move leaves the yaw alone
await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: cx, y: cy });
const y0 = await yaw();
for (let k = 1; k <= 20; k++) { await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: cx + k * 15, y: cy, button: 'none' }); await sleep(30); }
await sleep(400);
const idleMove = Math.abs((await yaw()) - y0);
console.log(`move without a button: yaw changed by ${idleMove} mrad`);
need(idleMove <= 1, 'a move with no button held does not turn the camera');

// left button held: 300 px drag. A real pointer moves to the press point before it presses; the check does the same.
await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: cx, y: cy, button: 'none' });
await sleep(100);
await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: cx, y: cy, button: 'left', buttons: 1, clickCount: 1 });
await sleep(100);
const y1 = await yaw();
for (let k = 1; k <= 20; k++) { await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: cx + k * 15, y: cy, button: 'left', buttons: 1 }); await sleep(30); }
await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: cx + 300, y: cy, button: 'left', clickCount: 1 });
await sleep(600);
const turned = y1 - (await yaw());
const expected = 300 * 6; // 300 px at 0.006 rad per px, in mrad (the yaw decreases as the drag moves right)
console.log(`300 px drag with the left button: yaw changed by ${turned} mrad (expected about ${expected})`);
need(Math.abs(turned - expected) <= expected * 0.1, `a 300 px drag turns the camera by 300 * 0.006 rad within 10 % (${turned} mrad)`);

// after release: a move does not turn it
const y2 = await yaw();
for (let k = 1; k <= 10; k++) { await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: cx + 300 + k * 15, y: cy, button: 'none' }); await sleep(30); }
await sleep(400);
need(Math.abs((await yaw()) - y2) <= 1, 'after the button is released, a move does not turn the camera');

{ const pageErr = await js('window.host.error'); need(pageErr === '', `no page error (${pageErr || 'none'})`); }
console.log(problems.length ? `look-check: FAIL\n  ${problems.join('\n  ')}` : 'look-check: PASS');
done(problems.length ? 1 : 0);
