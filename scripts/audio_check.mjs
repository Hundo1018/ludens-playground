// The zone goal sound (plan W8): the four CC0 effects load, the audio context starts on a key press, reaching a goal starts
// the goal sound once, and the worklet pulls mixed frames from the host. Headless Chrome, software WebGPU, and
// --autoplay-policy so the context may run without a real user gesture in the headless browser.
// usage: node scripts/audio_check.mjs <chrome> <url> [timeout_s]
// Checks: four sounds registered; the audio context starts; a goal starts one sound; frames are rendered for the worklet.
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [chrome, url, timeoutS = '300'] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'audio-check-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--autoplay-policy=no-user-gesture-required',
  '--window-size=960,600', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const problems = [];
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('audio-check: timed out'); done(1); }, Number(timeoutS) * 1000);
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
const host = (fn, ...args) => js(`window.host.x.${fn}(window.host.app${args.map((a) => ', ' + a).join('')})`);

await send('Runtime.enable');
await send('Page.enable');
await send('Page.navigate', { url: url + '?notown' });
for (let i = 0; i < 900; i++) { if ((await js('window.host && window.host.assets')) >= 5 && (await js('window.host.frames')) >= 10 && (await js('window.host.sounds')) >= 4) break; await sleep(100); }
const err0 = await js('window.host && window.host.error');
need(!err0, `the page starts without error (${err0 || 'none'})`);
need((await js('window.host.sounds')) === 4, `the four CC0 effects are registered on the host's audio scene (${await js('window.host.sounds')})`);
need((await host('playground_host_audio_played')) === 0, 'no sound has played before a goal');

// a key press starts the audio context (the page's gesture path)
await js(`window.dispatchEvent(new KeyboardEvent('keydown', { code: 'KeyP', bubbles: true }))`);
await js(`window.dispatchEvent(new KeyboardEvent('keyup', { code: 'KeyP', bubbles: true }))`);
for (let i = 0; i < 40; i++) { if (await js('!!window.host.audioCtx')) break; await sleep(100); }
need(await js('!!window.host.audioCtx'), 'a key press starts the audio context');

// reach the quarry goal: one goal sound
await host('playground_host_frontier_teleport', 112, -112);
for (let i = 0; i < 40; i++) { if ((await host('playground_host_audio_played')) >= 1) break; await sleep(100); }
need((await host('playground_host_audio_played')) === 1, `reaching a goal starts the goal sound once (played ${await host('playground_host_audio_played')})`);

// the worklet pulls frames: the host renders for it
for (let i = 0; i < 40; i++) { if ((await host('playground_host_audio_rendered')) > 4096) break; await sleep(100); }
need((await host('playground_host_audio_rendered')) > 4096, `the host renders mixed frames for the worklet (${await host('playground_host_audio_rendered')} frames)`);
console.log(`worklet played ${await js('window.host.audioPlayed')} frames, underruns ${await js('window.host.audioUnderruns')}`);

// the goal sound is played once: teleporting back to the same goal does not start it again
await host('playground_host_frontier_teleport', 0, 0);
await host('playground_host_frontier_teleport', 112, -112);
await sleep(800);
need((await host('playground_host_audio_played')) === 1, 'a goal reached again does not start its sound again');
need((await js('window.host.error')) === '', 'no page error');
console.log(problems.length ? `audio-check: FAIL\n  ${problems.join('\n  ')}` : 'audio-check: PASS');
done(problems.length ? 1 : 0);
