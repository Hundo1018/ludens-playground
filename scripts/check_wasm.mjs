// Run the package's wasm module under node and compare every value with the native build's output, which the
// caller produces from the same sources (scripts/check_parity.sh). No hashes are written down here: a pin bump
// changes them, and the comparison must not need a manual update.
// usage: node scripts/check_wasm.mjs <host.mjs> <playground.wasm> <native-output.txt>
import { readFileSync } from "node:fs";
const [hostPath, wasmPath, nativePath] = process.argv.slice(2);
const { instantiate } = await import(hostPath);
const m = await instantiate(readFileSync(wasmPath), { libs: [] });
// native lines look like: "native frames N <hash>" or "native frontier frames N <hash> bodies <n>"
const native = readFileSync(nativePath, "utf8").split("\n").filter((l) => l.startsWith("native"));
if (native.length === 0) { console.log("FAIL no native lines"); process.exit(1); }
let ok = true;
for (const line of native) {
  const t = line.split(" ");
  const frames = Number(t[t.indexOf("frames") + 1]);
  let got;
  if (t[1] === "frontier") {
    const hash = String(BigInt.asUintN(64, m.exports.playground_frontier_hash(frames)));
    const bodies = String(m.exports.playground_frontier_bodies(frames));
    got = `native frontier frames ${frames} ${hash} bodies ${bodies}`;
  } else {
    got = `native frames ${frames} ${String(BigInt.asUintN(64, m.exports.playground_arena_hash(frames)))}`;
  }
  const pass = got === line;
  ok &&= pass;
  console.log(`${pass ? "PASS" : "FAIL"} ${line}${pass ? "" : `  (wasm: ${got})`}`);
}
if (!ok) process.exit(1);
console.log("check_wasm: PASS");
