// The WebAssembly core against the native command: every deck given is
// translated by both, and the text and the error count must be the same.
// node tools/wasm_check.mjs zig-out/bin/sprack.wasm zig-out/bin/sprack FROM TO deck...
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const [wasmPath, native, from, to, ...decks] = process.argv.slice(2);
const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath));
const x = instance.exports;
const enc = new TextEncoder(), dec = new TextDecoder();

function put(s) {
  const b = enc.encode(s), p = x.sprack_alloc(b.length || 1);
  new Uint8Array(x.memory.buffer, p, b.length).set(b);
  return [p, b.length];
}
function out(which) {
  const lenp = x.sprack_alloc(4);
  const p = x.sprack_out(which, lenp);
  const n = new Uint32Array(x.memory.buffer, lenp, 1)[0];
  const s = dec.decode(new Uint8Array(x.memory.buffer, p, n));
  x.sprack_free(lenp, 4);
  return s;
}
function translate(text) {
  const args = [from, to, text].map(put);
  const rc = x.sprack_translate(...args.flat());
  for (const [p, n] of args) x.sprack_free(p, n || 1);
  if (rc !== 0) throw new Error(rc === 1 ? out(2) : "out of memory");
  return [out(0), JSON.parse(out(1))];
}

if (x.sprack_info() !== 0 || !JSON.parse(out(0)).dialects.includes(to)) throw new Error("info");
let same = 0, differ = 0;
for (const deck of decks) {
  const text = readFileSync(deck, "latin1");
  const [w] = translate(text);
  let n;
  try { n = execFileSync(native, ["translate", "--from", from, "--to", to, deck], { stdio: ["ignore", "pipe", "ignore"], maxBuffer: 1 << 30 }).toString("latin1"); }
  catch (e) { n = e.stdout.toString("latin1"); }
  if (w === n) same++; else { differ++; if (differ <= 5) console.log("DIFFER", deck); }
}
console.log(`${same} same, ${differ} differ`);
process.exit(differ ? 1 : 0);
