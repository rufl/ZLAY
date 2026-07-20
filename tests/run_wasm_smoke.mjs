import { readFile } from "node:fs/promises";

const wasmPath = process.argv[2];
if (!wasmPath) throw new Error("expected WebAssembly module path");

const bytes = await readFile(wasmPath);
const { instance } = await WebAssembly.instantiate(bytes, {});
const smoke = instance.exports.zlay_renderer_smoke;
if (typeof smoke !== "function") throw new Error("missing zlay_renderer_smoke export");

const expected = 0x5a1a110e;
const first = smoke() >>> 0;
const second = smoke() >>> 0;
if (first !== expected || second !== expected) {
  throw new Error(
    `wasm renderer smoke mismatch: expected 0x${expected.toString(16)}, got 0x${first.toString(16)} and 0x${second.toString(16)}`,
  );
}

process.stderr.write(`wasm-renderer-smoke 0x${first.toString(16).padStart(8, "0")}\n`);
