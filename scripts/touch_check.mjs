// Touch check for the Frontier page, on a phone-sized touch screen, through the DevTools protocol (Node built-ins only,
// the same way scripts/host_check.mjs drives Chrome).
//
//   node scripts/touch_check.mjs <chrome> <url> [timeout_s]
//
// The stick (bottom-left) is dragged up and right: the host must receive W and D pressed, and both released when the
// finger lifts. Jump (bottom-right) and R are tapped: each must reach the host as a press and then a release. Events
// are taken at the host's own input entry (window.host.x.playground_host_input), so the check covers pad -> host.
// Three runs in a row must pass. Prints one line per check; exits non-zero on any failure.
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [chrome, url, timeoutS = '240'] = process.argv.slice(2);
if (!chrome || !url) { console.error('usage: node scripts/touch_check.mjs <chrome> <url> [timeout_s]'); process.exit(2); }
const KEY = { W: 87, D: 68, SPACE: 32, R: 82 };
const EV_KEY = 1;
const VIEW = { width: 393, height: 851 }; // a phone in portrait

const profile = mkdtempSync(join(tmpdir(), 'touch-check-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=393,851', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const finish = (code) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(code); };
setTimeout(() => { console.log('touch-check: timed out'); finish(1); }, Number(timeoutS) * 1000);

const port = await new Promise((res) => {
  let b = '';
  proc.stderr.on('data', (d) => { b += d; const m = b.match(/DevTools listening on ws:\/\/[^:]+:(\d+)\//); if (m) res(m[1]); });
});
const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r));
let id = 0; const pending = new Map(); const pageErrors = [];
ws.addEventListener('message', (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result ?? m.error); pending.delete(m.id); }
  if (m.method === 'Runtime.exceptionThrown') pageErrors.push(m.params.exceptionDetails.exception?.description ?? 'exception');
});
const send = (method, params = {}) => new Promise((r) => { pending.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });
const js = async (expression) => (await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }))?.result?.value;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

await send('Runtime.enable');
await send('Page.enable');
await send('Emulation.setDeviceMetricsOverride', { width: VIEW.width, height: VIEW.height, deviceScaleFactor: 1, mobile: true });
await send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });
await send('Page.navigate', { url });
// The page is ready when the host has booted and drawn a few frames.
for (let i = 0; i < Number(timeoutS) * 4; i++) {
  if (await js('!!(window.host && window.host.app && window.host.frames > 2)')) break;
  await sleep(250);
}

// Log every key the host receives: the pad and the keyboard share this entry point.
await js(`(() => { window.__keys = []; const x = window.host.x; const orig = x.playground_host_input;
  x.playground_host_input = (app, kind, key, action, mods, mx, my) => {
    if (kind === ${EV_KEY}) window.__keys.push({ key, down: action === 1 || action === 2 });
    return orig(app, kind, key, action, mods, mx, my); }; })()`);

const touch = (type, points = []) => send('Input.dispatchTouchEvent',
  { type, touchPoints: points.map(([x, y], i) => ({ x, y, id: i })) });
const take = async () => js('(() => { const k = window.__keys.slice(); window.__keys.length = 0; return k; })()');
const pressed = (ev, k) => ev.some((e) => e.key === k && e.down);
const released = (ev, k) => ev.some((e) => e.key === k && !e.down);

let allOk = true;
for (let run = 1; run <= 3; run++) {
  const results = [];
  const check = (label, ok, detail = '') => {
    results.push(ok);
    console.log(`run ${run}: ${ok ? 'PASS' : 'FAIL'} ${label}${ok || !detail ? '' : ' :: ' + detail}`);
  };

  // 1. Stick, bottom-left. Start inside its zone, drag up and right, hold, then lift.
  const start = [70, VIEW.height - 90];
  await touch('touchStart', [start]);
  await sleep(50);
  await touch('touchMove', [[start[0] + 40, start[1] - 40]]);
  await sleep(50);
  await touch('touchMove', [[start[0] + 60, start[1] - 50]]);
  await sleep(100);
  const during = await take();
  check('stick drag presses D (right)', pressed(during, KEY.D), JSON.stringify(during));
  check('stick drag presses W (up)', pressed(during, KEY.W), JSON.stringify(during));
  await touch('touchEnd');
  await sleep(50);
  const afterLift = await take();
  check('lifting the stick releases D', released(afterLift, KEY.D), JSON.stringify(afterLift));
  check('lifting the stick releases W', released(afterLift, KEY.W), JSON.stringify(afterLift));

  // 2. Jump, bottom-right: 76 px, 24 px from the edges.
  await touch('touchStart', [[VIEW.width - 24 - 38, VIEW.height - 24 - 38]]);
  await sleep(50);
  await touch('touchEnd');
  await sleep(50);
  const jump = await take();
  const jd = jump.findIndex((e) => e.key === KEY.SPACE && e.down), ju = jump.findIndex((e) => e.key === KEY.SPACE && !e.down);
  check('Jump tap sends Space press, then release', jd >= 0 && ju > jd, JSON.stringify(jump));

  // 3. R, bottom-right, 56 px, 124 px from the right edge.
  await touch('touchStart', [[VIEW.width - 124 - 28, VIEW.height - 24 - 28]]);
  await sleep(50);
  await touch('touchEnd');
  await sleep(50);
  const reset = await take();
  check('R tap sends R press, then release', pressed(reset, KEY.R) && released(reset, KEY.R), JSON.stringify(reset));

  check('no page exceptions', pageErrors.length === 0, pageErrors.join(' | '));
  if (!results.every(Boolean)) allOk = false;
}
console.log(allOk ? 'touch-check: PASS (3 runs)' : 'touch-check: FAIL');
finish(allOk ? 0 : 1);
