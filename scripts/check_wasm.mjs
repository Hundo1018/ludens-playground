// Run the playground's wasm module under node and check its numbers against the native build's.
// usage: node scripts/check_wasm.mjs <host.mjs> <playground.wasm>
import { readFileSync } from "node:fs";
const [hostPath, wasmPath] = process.argv.slice(2);
const { instantiate } = await import(hostPath);
const m = await instantiate(readFileSync(wasmPath), { libs: [] });
// expected: the native target's output for the same sources (frames 1..3)
const expected = {
  arena: ["12217565312237657556", "5883669775744707594", "3942389195991980829"],
  frontier: ["12382180788556832807", "11744582151253365717", "1702746564582479634"],
};
let ok = true;
const check = (label, got, want) => {
  const pass = got === want;
  ok &&= pass;
  console.log(`${pass ? "PASS" : "FAIL"} ${label} = ${got}${pass ? "" : ` (want ${want})`}`);
};
for (const [i, want] of expected.arena.entries()) {
  check(`playground_arena_hash(${i + 1})`, String(BigInt.asUintN(64, m.exports.playground_arena_hash(i + 1))), want);
}
for (const [i, want] of expected.frontier.entries()) {
  check(`playground_frontier_hash(${i + 1})`, String(BigInt.asUintN(64, m.exports.playground_frontier_hash(i + 1))), want);
  check(`playground_frontier_bodies(${i + 1})`, String(m.exports.playground_frontier_bodies(i + 1)), "112");
}
if (!ok) process.exit(1);
console.log("check_wasm: PASS");
