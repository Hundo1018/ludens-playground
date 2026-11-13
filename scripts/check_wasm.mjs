// Run the playground's wasm module under node and check its numbers against the native build's.
// usage: node scripts/check_wasm.mjs <host.mjs> <playground.wasm>
import { readFileSync } from "node:fs";
const [hostPath, wasmPath] = process.argv.slice(2);
const { instantiate } = await import(hostPath);
const m = await instantiate(readFileSync(wasmPath), { libs: [] });
// expected: the native target's output for the same sources (frames 1..3)
const expected = ["12217565312237657556", "5883669775744707594", "3942389195991980829"];
let ok = true;
for (const [i, want] of expected.entries()) {
  const got = String(BigInt.asUintN(64, m.exports.playground_arena_hash(i + 1)));
  const pass = got === want;
  ok &&= pass;
  console.log(`${pass ? "PASS" : "FAIL"} playground_arena_hash(${i + 1}) = ${got}${pass ? "" : ` (want ${want})`}`);
}
if (!ok) process.exit(1);
console.log("check_wasm: PASS");
