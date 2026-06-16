// struple reference benchmark (TypeScript / Node).
//
// Mirrors bench/zig/bench.zig: encode (build a framed stream from prepared
// in-memory records) and decode (walk the whole stream, descending and
// un-escaping every container body and touching every scalar) throughput for
// the seven shared workloads — four realistic streaming shapes (stock quotes,
// geospatial points, tweets, blockchain transactions) plus three structural
// micro-benchmarks (an integer stream, a string stream, a nested document).
//
// The native records are parsed from bench/data/<name>.json once (setup,
// untimed); the encoder then rebuilds the bytes with the same appendX sequence
// the Zig reference uses. Byte-identity is verified against bench/payloads.json
// (sha256) before any throughput figure is reported.
//
// Methodology (per (payload, op)): 5 warm-up runs, auto-calibrate the iteration
// count to a ~100 ms trial, then 9 trials — the MEDIAN ns/op is reported. A
// global checksum sink consumes every result so the JIT can't elide the work.
// Steady-state buffers retain capacity. Single-threaded.
//
// Zero dependencies beyond Node builtins (node:fs, node:crypto, JSON,
// process.hrtime.bigint). Requires Node >= 23.6 (erasable TS, no build step).
//
// Run:  node --experimental-strip-types bench/js/bench.ts
//   (Node >= 23.6 strips types natively; on 23.6 you may need the flag, on
//    >= 24 plain `node bench/js/bench.ts` works. From repo root or anywhere —
//    paths are resolved relative to this file.)

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { Writer, Reader, type Element } from "../../js/src/index.ts";

const here = dirname(fileURLToPath(import.meta.url));
const benchDir = join(here, "..");
const dataDir = join(benchDir, "data");
const resultsDir = join(benchDir, "results");

// ---------------------------------------------------------------------------
// DCE sink — every measured op folds something into this so the JIT must
// actually perform the work. A BigInt accumulator (wrapped to 64 bits) mirrors
// the Zig `g_sink: u64` exactly.
// ---------------------------------------------------------------------------
const MASK64 = (1n << 64n) - 1n;
let gSink = 0n;
function sink(v: bigint): void {
  gSink = (gSink + v) & MASK64;
}

// ---------------------------------------------------------------------------
// Native record shapes (parsed once from the shared JSON data).
// ---------------------------------------------------------------------------

interface Dec {
  digits: number[]; // coefficient digits, MSD-first, each 0–9
  exp: number;
}
interface Quote {
  symbol: string;
  bid: Dec;
  ask: Dec;
  last: number; // f64
  volume: bigint;
  ts: bigint; // µs since epoch
}
interface Geo {
  lat: number;
  lon: number;
  elevation: number;
  name: string;
  ts: bigint;
}
interface Tweet {
  id: bigint; // u64
  user: string;
  text: string;
  createdAt: bigint;
  likes: bigint;
  retweets: bigint;
}
interface Tx {
  height: bigint;
  txHash: Uint8Array; // 32 bytes
  from: Uint8Array; // 20 bytes
  to: Uint8Array; // 20 bytes
  value: bigint; // wei (both the i128 fixed path and the big-int path reduce to a bigint)
  gas: bigint;
  nonce: bigint;
  ts: bigint;
}
interface Nested {
  uid: bigint;
  name: string;
  active: boolean;
  scores: [bigint, bigint, bigint];
}

type PKind = "quotes" | "geo" | "tweets" | "txs" | "ints" | "strings" | "nested";

interface Data {
  quotes: Quote[];
  geo: Geo[];
  tweets: Tweet[];
  txs: Tx[];
  ints: bigint[];
  strings: string[];
  nested: Nested[];
}

interface PayloadMeta {
  kind: PKind;
  name: string;
  category: string;
}

const payloads: PayloadMeta[] = [
  { kind: "quotes", name: "stock_quotes", category: "streaming" },
  { kind: "geo", name: "geo_points", category: "streaming" },
  { kind: "tweets", name: "tweets", category: "streaming" },
  { kind: "txs", name: "blockchain_txs", category: "streaming" },
  { kind: "ints", name: "int_stream", category: "structural" },
  { kind: "strings", name: "string_stream", category: "structural" },
  { kind: "nested", name: "nested_doc", category: "structural" },
];

// ---------------------------------------------------------------------------
// Parsing helpers — the shared data fields are all typed strings (so any JSON
// library reads them identically across languages). See bench/README.md.
// ---------------------------------------------------------------------------

// 16 hex digits of the IEEE-754 bits (big-endian) → JS number (DataView).
const f64View = new DataView(new ArrayBuffer(8));
function f64FromHex(hex: string): number {
  f64View.setBigUint64(0, BigInt("0x" + hex), false);
  return f64View.getFloat64(0, false);
}

// digit string "12345" → [1,2,3,4,5]
function digitsFromStr(s: string): number[] {
  const out = new Array<number>(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i) - 48;
  return out;
}

// hex string (even length) → bytes
function bytesFromHex(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

// big-endian hex magnitude → bigint (both the `big` and `fix` blockchain paths
// reduce to this: `appendInt(bigint)` routes magnitudes within i128 through the
// fixed slots and magnitudes beyond i128 through the big-int codes, byte-for-
// byte identical to the Zig appendI128 / appendBigInt split).
function bigFromHex(hex: string): bigint {
  return hex.length === 0 ? 0n : BigInt("0x" + hex);
}

function readData(): Data {
  const load = (name: string): any =>
    JSON.parse(readFileSync(join(dataDir, name + ".json"), "utf8"));

  const quotesRaw = load("stock_quotes") as string[][];
  const quotes: Quote[] = quotesRaw.map((r) => ({
    symbol: r[0],
    bid: { digits: digitsFromStr(r[1]), exp: parseInt(r[2], 10) },
    ask: { digits: digitsFromStr(r[3]), exp: parseInt(r[4], 10) },
    last: f64FromHex(r[5]),
    volume: BigInt(r[6]),
    ts: BigInt(r[7]),
  }));

  const geoRaw = load("geo_points") as string[][];
  const geo: Geo[] = geoRaw.map((r) => ({
    lat: f64FromHex(r[0]),
    lon: f64FromHex(r[1]),
    elevation: f64FromHex(r[2]),
    name: r[3],
    ts: BigInt(r[4]),
  }));

  const tweetsRaw = load("tweets") as string[][];
  const tweets: Tweet[] = tweetsRaw.map((r) => ({
    id: BigInt(r[0]),
    user: r[1],
    text: r[2],
    createdAt: BigInt(r[3]),
    likes: BigInt(r[4]),
    retweets: BigInt(r[5]),
  }));

  const txsRaw = load("blockchain_txs") as string[][];
  const txs: Tx[] = txsRaw.map((r) => ({
    height: BigInt(r[0]),
    txHash: bytesFromHex(r[1]),
    from: bytesFromHex(r[2]),
    to: bytesFromHex(r[3]),
    // r[4] is "big" | "fix"; r[5] is the big-endian hex magnitude. Both collapse
    // to a bigint for appendInt.
    value: bigFromHex(r[5]),
    gas: BigInt(r[6]),
    nonce: BigInt(r[7]),
    ts: BigInt(r[8]),
  }));

  const intsRaw = load("int_stream") as string[];
  const ints: bigint[] = intsRaw.map((s) => BigInt(s));

  const strings = load("string_stream") as string[];

  const nestedRaw = load("nested_doc") as string[][];
  const nested: Nested[] = nestedRaw.map((r) => ({
    active: r[0] === "1",
    uid: BigInt(r[1]),
    name: r[2],
    scores: [BigInt(r[3]), BigInt(r[4]), BigInt(r[5])],
  }));

  return { quotes, geo, tweets, txs, ints, strings, nested };
}

// ---------------------------------------------------------------------------
// Encoders — one per payload kind. `out` is reset by the caller each iteration;
// a single reused `scratch` Writer frames one record at a time (its backing
// array is truncated, not reallocated, so it retains capacity at steady state).
// Mirrors encodeOnce in bench/zig/bench.zig.
// ---------------------------------------------------------------------------

// Pre-encoded constant keys for the nested-doc map (the keys never change; the
// Zig harness re-encodes them per record from an arena, but the keys are
// invariant, so caching them is byte-identical and avoids needless work).
const KEY_ACTIVE = encodeString("active");
const KEY_SCORES = encodeString("scores");
const KEY_USER = encodeString("user");
const KEY_ID = encodeString("id");
const KEY_NAME = encodeString("name");

function encodeString(s: string): Uint8Array {
  return new Writer().appendString(s).bytes();
}
function encodeInt(v: bigint): Uint8Array {
  return new Writer().appendInt(v).bytes();
}
function encodeBool(v: boolean): Uint8Array {
  return new Writer().appendBool(v).bytes();
}

// Reuse a Writer by truncating its backing array (retains V8 capacity).
function reset(w: Writer): void {
  w.buf.length = 0;
}

function encodeOnce(kind: PKind, d: Data, out: Writer, scratch: Writer): void {
  switch (kind) {
    case "quotes":
      for (const q of d.quotes) {
        reset(scratch);
        scratch.appendString(q.symbol);
        scratch.appendDecimal(false, q.bid.digits, q.bid.exp);
        scratch.appendDecimal(false, q.ask.digits, q.ask.exp);
        scratch.appendFloat64(q.last);
        scratch.appendInt(q.volume);
        scratch.appendTimestamp(q.ts);
        out.appendArray(scratch.bytes());
      }
      break;
    case "geo":
      for (const g of d.geo) {
        reset(scratch);
        scratch.appendFloat64(g.lat);
        scratch.appendFloat64(g.lon);
        scratch.appendFloat64(g.elevation);
        scratch.appendString(g.name);
        scratch.appendTimestamp(g.ts);
        out.appendArray(scratch.bytes());
      }
      break;
    case "tweets":
      for (const t of d.tweets) {
        reset(scratch);
        scratch.appendInt(t.id); // u64 id; appendInt(bigint) == appendUint here (positive)
        scratch.appendString(t.user);
        scratch.appendString(t.text);
        scratch.appendTimestamp(t.createdAt);
        scratch.appendInt(t.likes);
        scratch.appendInt(t.retweets);
        out.appendArray(scratch.bytes());
      }
      break;
    case "txs":
      for (const x of d.txs) {
        reset(scratch);
        scratch.appendInt(x.height);
        scratch.appendBytes(x.txHash);
        scratch.appendBytes(x.from);
        scratch.appendBytes(x.to);
        scratch.appendInt(x.value); // big-int or i128 fixed path, chosen by magnitude
        scratch.appendInt(x.gas);
        scratch.appendInt(x.nonce);
        scratch.appendTimestamp(x.ts);
        out.appendArray(scratch.bytes());
      }
      break;
    case "ints":
      for (const v of d.ints) out.appendInt(v);
      break;
    case "strings":
      for (const s of d.strings) out.appendString(s);
      break;
    case "nested":
      for (const n of d.nested) {
        // user sub-map { id, name }
        const user = new Writer()
          .appendMap([
            [KEY_ID, encodeInt(n.uid)],
            [KEY_NAME, encodeString(n.name)],
          ])
          .bytes();
        // scores array [s0, s1, s2]
        const scoresInner = new Writer();
        scoresInner.appendInt(n.scores[0]);
        scoresInner.appendInt(n.scores[1]);
        scoresInner.appendInt(n.scores[2]);
        const scoresArr = new Writer().appendArray(scoresInner.bytes()).bytes();
        // top-level map (appendMap sorts by encoded key, so order here is free)
        out.appendMap([
          [KEY_ACTIVE, encodeBool(n.active)],
          [KEY_SCORES, scoresArr],
          [KEY_USER, user],
        ]);
      }
      break;
  }
}

function recordCount(kind: PKind, d: Data): number {
  switch (kind) {
    case "quotes": return d.quotes.length;
    case "geo": return d.geo.length;
    case "tweets": return d.tweets.length;
    case "txs": return d.txs.length;
    case "ints": return d.ints.length;
    case "strings": return d.strings.length;
    case "nested": return d.nested.length;
  }
}

// ---------------------------------------------------------------------------
// Decode — recursive walk that touches every value, unescaping container bodies
// (the realistic cost of the memcmp-orderable framing). The Reader already
// unescapes each container body in a single pass (see Reader.next →
// unescape(takeFramed())), so descending recursively into the body view does
// the realistic work without a redundant pre-scan.
// ---------------------------------------------------------------------------

function walk(buf: Uint8Array): void {
  const r = new Reader(buf);
  let el: Element | null;
  while ((el = r.next()) !== null) {
    switch (el.kind) {
      case "nil":
      case "undef":
        break;
      case "bool":
        sink(el.value ? 1n : 0n);
        break;
      case "int":
        sink(BigInt.asUintN(64, el.value));
        break;
      case "float32":
        f64View.setFloat32(0, el.value, false);
        sink(BigInt(f64View.getUint32(0, false)));
        break;
      case "float64":
        f64View.setFloat64(0, el.value, false);
        sink(f64View.getBigUint64(0, false));
        break;
      case "decimal":
        sink(BigInt(el.digits.length) + BigInt.asUintN(64, BigInt(el.exp + el.digits.length)));
        break;
      case "timestamp":
        sink(BigInt.asUintN(64, el.micros));
        break;
      case "uuid":
        sink(BigInt(el.value[0]));
        break;
      case "string": {
        const len = el.value.length;
        sink(BigInt(len));
        if (len > 0) sink(BigInt(el.value.charCodeAt(0)));
        break;
      }
      case "bytes": {
        const len = el.value.length;
        sink(BigInt(len));
        if (len > 0) sink(BigInt(el.value[0]));
        break;
      }
      case "array":
      case "map":
      case "set":
        walk(el.body);
        break;
    }
  }
}

// ---------------------------------------------------------------------------
// Timing.
// ---------------------------------------------------------------------------

interface Stats {
  nsPerOp: number;
  bytes: number;
  records: number;
}

function mbPerSec(s: Stats): number {
  return (s.bytes / s.nsPerOp) * 1000.0; // bytes/ns → MB/s
}
function mRecPerSec(s: Stats): number {
  return (s.records / s.nsPerOp) * 1000.0; // rec/ns → Mrec/s
}

const TARGET_TRIAL_NS = 100_000_000n; // ~100 ms
const N_TRIALS = 9;
const N_WARMUP = 5;

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[sorted.length >> 1];
}

function buildCanonical(kind: PKind, d: Data): Uint8Array {
  const out = new Writer();
  const scratch = new Writer();
  encodeOnce(kind, d, out, scratch);
  return out.bytes();
}

function benchEncode(kind: PKind, d: Data, canonicalLen: number): Stats {
  const out = new Writer();
  const scratch = new Writer();
  const runOnce = (): void => {
    reset(out);
    encodeOnce(kind, d, out, scratch);
    sink(BigInt(out.buf.length));
  };

  for (let i = 0; i < N_WARMUP; i++) runOnce();

  let t0 = process.hrtime.bigint();
  runOnce();
  const one = process.hrtime.bigint() - t0;
  const iters = Number(one <= 0n ? TARGET_TRIAL_NS : TARGET_TRIAL_NS / one);
  const n = Math.max(1, iters);

  const trials = new Array<number>(N_TRIALS);
  for (let t = 0; t < N_TRIALS; t++) {
    t0 = process.hrtime.bigint();
    for (let j = 0; j < n; j++) runOnce();
    const dt = process.hrtime.bigint() - t0;
    trials[t] = Number(dt) / n;
  }
  return { nsPerOp: median(trials), bytes: canonicalLen, records: recordCount(kind, d) };
}

function benchDecode(kind: PKind, d: Data, bytes: Uint8Array): Stats {
  const runOnce = (): void => walk(bytes);

  for (let i = 0; i < N_WARMUP; i++) runOnce();

  let t0 = process.hrtime.bigint();
  runOnce();
  const one = process.hrtime.bigint() - t0;
  const iters = Number(one <= 0n ? TARGET_TRIAL_NS : TARGET_TRIAL_NS / one);
  const n = Math.max(1, iters);

  const trials = new Array<number>(N_TRIALS);
  for (let t = 0; t < N_TRIALS; t++) {
    t0 = process.hrtime.bigint();
    for (let j = 0; j < n; j++) runOnce();
    const dt = process.hrtime.bigint() - t0;
    trials[t] = Number(dt) / n;
  }
  return { nsPerOp: median(trials), bytes: bytes.length, records: recordCount(kind, d) };
}

// ---------------------------------------------------------------------------
// Host label.
// ---------------------------------------------------------------------------

function hostLabel(): string {
  try {
    const text = readFileSync("/proc/cpuinfo", "utf8");
    for (const line of text.split("\n")) {
      if (line.startsWith("model name")) {
        const c = line.indexOf(":");
        if (c !== -1) return line.slice(c + 1).trim();
      }
    }
  } catch {
    /* fall through */
  }
  return "unknown";
}

// ---------------------------------------------------------------------------
// Main.
// ---------------------------------------------------------------------------

interface PayloadResult {
  enc_mrec_s: number;
  enc_mb_s: number;
  dec_mrec_s: number;
  dec_mb_s: number;
  sha256_ok: boolean;
}

function sha256Hex(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

function round2(x: number): number {
  return Math.round(x * 100) / 100;
}

function main(): void {
  const manifest = JSON.parse(readFileSync(join(benchDir, "payloads.json"), "utf8")) as {
    payloads: { name: string; byte_len: number; sha256: string }[];
  };
  const expected = new Map(manifest.payloads.map((p) => [p.name, p]));

  const data = readData();

  console.log("struple benchmark (TypeScript / Node " + process.version + ", single-threaded)\n");

  const out: Record<string, PayloadResult> = {};
  let allOk = true;
  let totalBytes = 0;

  for (const meta of payloads) {
    const bytes = buildCanonical(meta.kind, data);
    totalBytes += bytes.length;

    // Verify byte-identity against the manifest BEFORE measuring.
    const exp = expected.get(meta.name);
    const sha = sha256Hex(bytes);
    const shaOk = exp !== undefined && sha === exp.sha256 && bytes.length === exp.byte_len;
    if (!shaOk) {
      allOk = false;
      console.error(
        `\nBYTE MISMATCH for ${meta.name}:\n` +
          `  produced byte_len=${bytes.length} sha256=${sha}\n` +
          `  expected byte_len=${exp?.byte_len} sha256=${exp?.sha256}\n` +
          `This is a contract bug — STOPPING (no throughput reported for this payload).`,
      );
      out[meta.name] = {
        enc_mrec_s: 0,
        enc_mb_s: 0,
        dec_mrec_s: 0,
        dec_mb_s: 0,
        sha256_ok: false,
      };
      continue;
    }

    const enc = benchEncode(meta.kind, data, bytes.length);
    const dec = benchDecode(meta.kind, data, bytes);

    out[meta.name] = {
      enc_mrec_s: round2(mRecPerSec(enc)),
      enc_mb_s: round2(mbPerSec(enc)),
      dec_mrec_s: round2(mRecPerSec(dec)),
      dec_mb_s: round2(mbPerSec(dec)),
      sha256_ok: true,
    };

    console.log(
      `  ${meta.name.padEnd(16)} ${String(enc.records).padStart(6)} rec   ` +
        `enc ${mRecPerSec(enc).toFixed(2).padStart(7)} Mrec/s ${mbPerSec(enc).toFixed(0).padStart(6)} MB/s   ` +
        `dec ${mRecPerSec(dec).toFixed(2).padStart(7)} Mrec/s ${mbPerSec(dec).toFixed(0).padStart(6)} MB/s` +
        `   sha ${out[meta.name].sha256_ok ? "ok" : "FAIL"}`,
    );
  }

  const host = hostLabel();
  const result = { lang: "TypeScript", host, payloads: out };

  mkdirSync(resultsDir, { recursive: true });
  writeFileSync(join(resultsDir, "js.json"), JSON.stringify(result, null, 2) + "\n");

  console.log(
    `\nHost: ${host} · Total corpus: ${(totalBytes / 1024).toFixed(1)} KB · ` +
      `Wrote bench/results/js.json`,
  );
  console.log(`(sink ${gSink.toString(16)})`);

  if (!allOk) {
    console.error("\nOne or more payloads failed byte-identity — see above.");
    process.exit(1);
  }
}

main();
