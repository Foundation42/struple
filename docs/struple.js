// struple — browser demo codec (plain ES module, no dependencies).
//
// This mirrors the wire format for the interactive demo. The authoritative,
// conformance-tested implementations live in the repo (Zig, TypeScript, Python,
// Rust, C, C++). A golden self-check at the bottom guards against drift.

const T = {
  terminator: 0x00, nil: 0x01, undef: 0x02, boolFalse: 0x05, boolTrue: 0x06,
  intNegBig: 0x0f, intZero: 0x20, intPosBig: 0x31, float32: 0x34, float64: 0x35,
  timestamp: 0x40, string: 0x48, bytes: 0x49, array: 0x50, map: 0x52, set: 0x54,
};
const MASK64 = 0xffffffffffffffffn;
const SIGN64 = 0x8000000000000000n;
// The fixed integer slots span the i128 range; values beyond use the big-int codes.
const I128_MAX = (1n << 127n) - 1n;
const I128_MIN = -(1n << 127n);

const TYPE_NAME = {
  0x01: "nil", 0x02: "undefined", 0x05: "false", 0x06: "true", 0x20: "int 0",
  0x0f: "big −int", 0x31: "big +int", 0x34: "float32", 0x35: "float64",
  0x40: "timestamp", 0x44: "uuid", 0x48: "string", 0x49: "bytes", 0x50: "array", 0x52: "map", 0x54: "set",
};
export function typeName(b) {
  if (TYPE_NAME[b]) return TYPE_NAME[b];
  if (b >= 0x10 && b <= 0x1f) return "−int";
  if (b >= 0x21 && b <= 0x30) return "+int";
  return "?";
}

function bigIntToBytes(mag) {
  const out = [];
  let v = mag;
  while (v > 0n) { out.push(Number(v & 0xffn)); v >>= 8n; }
  out.reverse();
  return out;
}
const byteLenBig = (x) => (x === 0n ? 0 : Math.ceil(x.toString(2).length / 8));
const byteLenNum = (n) => { let m = 0, t = n; while (t > 0) { m++; t = Math.floor(t / 256); } return m; };
function pushBE(buf, value, n) {
  for (let i = n - 1; i >= 0; i--) buf.push(Number((value >> BigInt(8 * i)) & 0xffn));
}
const utf8 = (s) => [...new TextEncoder().encode(s)];

function appendInteger(buf, value) {
  if (value === 0n) { buf.push(T.intZero); return; }
  const neg = value < 0n;
  const mag = neg ? -value : value;
  if (value >= I128_MIN && value <= I128_MAX) {
    if (neg) {
      const pv = mag - 1n;
      let n = byteLenBig(pv); if (n === 0) n = 1;
      buf.push(T.intZero - n);
      pushBE(buf, (1n << BigInt(8 * n)) - mag, n);
    } else {
      const mb = bigIntToBytes(mag);
      buf.push(T.intZero + mb.length);
      for (const b of mb) buf.push(b);
    }
    return;
  }
  const mb = bigIntToBytes(mag);
  buf.push(neg ? T.intNegBig : T.intPosBig);
  const n = mb.length, m = byteLenNum(n);
  const comp = (b) => (neg ? ~b & 0xff : b);
  buf.push(comp(m));
  for (let i = m - 1; i >= 0; i--) buf.push(comp((n >>> (8 * i)) & 0xff));
  for (const b of mb) buf.push(comp(b));
}

function appendFloat64(buf, value) {
  let bits;
  if (Number.isNaN(value)) bits = 0x7ff8000000000000n;
  else { const dv = new DataView(new ArrayBuffer(8)); dv.setFloat64(0, value === 0 ? 0 : value, false); bits = dv.getBigUint64(0, false); }
  bits = (bits & SIGN64) ? (~bits & MASK64) : (bits ^ SIGN64);
  buf.push(T.float64);
  pushBE(buf, bits, 8);
}

function writeEscaped(buf, content) {
  for (const b of content) { buf.push(b); if (b === 0) buf.push(0xff); }
}
function writeFramed(buf, tc, content) {
  buf.push(tc); writeEscaped(buf, content); buf.push(0);
}
export function compareBytes(a, b) {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) if (a[i] !== b[i]) return a[i] - b[i];
  return a.length - b.length;
}

function appendValue(buf, v) {
  if (v === null || v === undefined) { buf.push(v === undefined ? T.undef : T.nil); return; }
  switch (typeof v) {
    case "boolean": buf.push(v ? T.boolTrue : T.boolFalse); return;
    case "bigint": appendInteger(buf, v); return;
    case "number": Number.isInteger(v) ? appendInteger(buf, BigInt(v)) : appendFloat64(buf, v); return;
    case "string": writeFramed(buf, T.string, utf8(v)); return;
    case "object": {
      if (Array.isArray(v)) { const c = []; for (const it of v) appendValue(c, it); writeFramed(buf, T.array, c); return; }
      const entries = Object.keys(v).map((k) => { const kb = []; appendValue(kb, k); const vb = []; appendValue(vb, v[k]); return [kb, vb]; });
      entries.sort((x, y) => compareBytes(x[0], y[0]));
      buf.push(T.map);
      for (const [k, val] of entries) { writeEscaped(buf, k); writeEscaped(buf, val); }
      buf.push(0);
      return;
    }
  }
  throw new Error("unsupported value");
}

/** Parse a JSON value into the tuple's elements (array -> its items; else a 1-tuple).
 *  Integer tokens become BigInt (lossless) via the JSON.parse source reviver. */
export function parseTuple(text) {
  const reviver = (_k, val, ctx) =>
    (typeof val === "number" && ctx && typeof ctx.source === "string" && !/[.eE]/.test(ctx.source))
      ? BigInt(ctx.source) : val;
  let parsed;
  try { parsed = JSON.parse(text, reviver); }
  catch { parsed = JSON.parse(text); } // older browsers: no source access
  return Array.isArray(parsed) ? parsed : [parsed];
}

function describe(v) {
  if (v === null) return "nil";
  if (v === undefined) return "undefined";
  if (typeof v === "boolean") return String(v);
  if (typeof v === "bigint") return `int ${v}`;
  if (typeof v === "number") return Number.isInteger(v) ? `int ${v}` : `float ${v}`;
  if (typeof v === "string") return `"${v}"`;
  if (Array.isArray(v)) return "array";
  return "map";
}

/** Encode a list of elements, returning bytes and per-element segments. */
export function analyze(values) {
  const bytes = [];
  const segs = [];
  for (const v of values) {
    const start = bytes.length;
    appendValue(bytes, v);
    segs.push({ start, len: bytes.length - start, label: describe(v) });
  }
  return { bytes, segs };
}

/** Encode a list of elements to a flat byte array (for comparison). */
export function pack(values) {
  const bytes = [];
  for (const v of values) appendValue(bytes, v);
  return bytes;
}

export const hex = (bytes) => bytes.map((b) => b.toString(16).padStart(2, "0")).join(" ");

// ---- drift guard: a few golden vectors from the conformance corpus ----
const GOLDEN = { '"app"': "4861707000", "12345": "223039", "-42": "1fd6", "true": "06", "null": "01", "256": "220100", "18446744073709551616": "29010000000000000000" };
for (const [t, want] of Object.entries(GOLDEN)) {
  const got = analyze(parseTuple(t)).bytes.map((b) => b.toString(16).padStart(2, "0")).join("");
  if (got !== want) console.error(`struple demo drift: ${t} -> ${got}, expected ${want}`);
}
