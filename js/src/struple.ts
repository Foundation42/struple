// struple — streaming, lexicographically-ordered tuple packing (TypeScript).
//
// The encoded bytes are directly memcmp-comparable: compare(pack(a), pack(b))
// matches the semantic order of a and b. This is a faithful port of the Zig
// reference; the conformance corpus (conformance/vectors.json) pins byte
// identity across languages.
//
// Written in erasable TypeScript so Node >= 23.6 runs it with no build step.

/** One-byte type codes. Their order is the cross-type sort order. */
export const TypeCode = {
  terminator: 0x00,
  nil: 0x01,
  undef: 0x02,
  boolFalse: 0x05,
  boolTrue: 0x06,
  intNegBig: 0x0f,
  intZero: 0x20,
  intPosBig: 0x31,
  float32: 0x34,
  float64: 0x35,
  decimal: 0x38,
  timestamp: 0x40,
  uuid: 0x44,
  string: 0x48,
  bytes: 0x49,
  array: 0x50,
  map: 0x52,
  set: 0x54,
} as const;

const T = TypeCode;
const MASK64 = 0xffffffffffffffffn;
const SIGN64 = 0x8000000000000000n;
// The fixed integer slots span the i128 range; values beyond use the big-int codes.
const I128_MAX = (1n << 127n) - 1n;
const I128_MIN = -(1n << 127n);

export type Value =
  | null
  | undefined
  | boolean
  | bigint
  | number
  | string
  | Uint8Array
  | Date
  | Value[]
  | Set<Value>
  | Map<Value, Value>
  | { [key: string]: Value };

export type Element =
  | { kind: "nil" }
  | { kind: "undef" }
  | { kind: "bool"; value: boolean }
  | { kind: "int"; value: bigint }
  | { kind: "float32"; value: number }
  | { kind: "float64"; value: number }
  | { kind: "timestamp"; micros: bigint }
  | { kind: "uuid"; value: Uint8Array }
  | { kind: "string"; value: string }
  | { kind: "bytes"; value: Uint8Array }
  | { kind: "array"; body: Uint8Array }
  | { kind: "map"; body: Uint8Array }
  | { kind: "set"; body: Uint8Array };

const utf8Encode = new TextEncoder();
const utf8Decode = new TextDecoder();

// ---------------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------------

export class Writer {
  buf: number[] = [];

  bytes(): Uint8Array {
    return Uint8Array.from(this.buf);
  }

  appendNil(): this {
    this.buf.push(T.nil);
    return this;
  }
  appendUndefined(): this {
    this.buf.push(T.undef);
    return this;
  }
  appendBool(v: boolean): this {
    this.buf.push(v ? T.boolTrue : T.boolFalse);
    return this;
  }
  appendInt(v: bigint): this {
    appendInteger(this.buf, v);
    return this;
  }
  appendFloat64(v: number): this {
    appendFloat64Into(this.buf, v);
    return this;
  }
  appendFloat32(v: number): this {
    appendFloat32Into(this.buf, v);
    return this;
  }
  appendTimestamp(micros: bigint): this {
    appendTimestampInto(this.buf, micros);
    return this;
  }
  appendUuid(u: Uint8Array): this {
    appendUuidInto(this.buf, u);
    return this;
  }
  appendString(s: string): this {
    writeFramed(this.buf, T.string, utf8Encode.encode(s));
    return this;
  }
  appendBytes(b: Uint8Array): this {
    writeFramed(this.buf, T.bytes, b);
    return this;
  }
  appendArray(child: Uint8Array): this {
    writeFramed(this.buf, T.array, child);
    return this;
  }
  appendMap(entries: Array<[Uint8Array, Uint8Array]>): this {
    appendMapInto(this.buf, entries);
    return this;
  }
  appendSet(elements: Uint8Array[]): this {
    appendSetInto(this.buf, elements);
    return this;
  }
  append(value: Value): this {
    appendValue(this.buf, value);
    return this;
  }
}

/** Pack one or more values into a single memcmp-orderable buffer. */
export function pack(...values: Value[]): Uint8Array {
  const w = new Writer();
  for (const v of values) w.append(v);
  return w.bytes();
}

/** Encode a single value. */
export function encode(value: Value): Uint8Array {
  const buf: number[] = [];
  appendValue(buf, value);
  return Uint8Array.from(buf);
}

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

export class Reader {
  buf: Uint8Array;
  pos: number;

  constructor(buf: Uint8Array, pos = 0) {
    this.buf = buf;
    this.pos = pos;
  }

  done(): boolean {
    return this.pos >= this.buf.length;
  }

  next(): Element | null {
    if (this.pos >= this.buf.length) return null;
    const t = this.buf[this.pos++];
    switch (t) {
      case T.nil:
        return { kind: "nil" };
      case T.undef:
        return { kind: "undef" };
      case T.boolFalse:
        return { kind: "bool", value: false };
      case T.boolTrue:
        return { kind: "bool", value: true };
      case T.intZero:
        return { kind: "int", value: 0n };
      case T.intNegBig:
      case T.intPosBig:
        return this.readBigInt(t);
      case T.float32:
        return { kind: "float32", value: decodeFloat32(this.take(4)) };
      case T.float64:
        return { kind: "float64", value: decodeFloat64(this.take(8)) };
      case T.timestamp:
        return this.readTimestamp();
      case T.uuid:
        return { kind: "uuid", value: this.take(16).slice() };
      case T.string:
        return { kind: "string", value: utf8Decode.decode(unescape(this.takeFramed())) };
      case T.bytes:
        return { kind: "bytes", value: unescape(this.takeFramed()) };
      case T.array:
        return { kind: "array", body: unescape(this.takeFramed()) };
      case T.map:
        return { kind: "map", body: unescape(this.takeFramed()) };
      case T.set:
        return { kind: "set", body: unescape(this.takeFramed()) };
      default:
        if ((t >= 0x10 && t <= 0x1f) || (t >= 0x21 && t <= 0x30)) return this.readFixedInt(t);
        throw new Error(`struple: invalid type code 0x${t.toString(16)}`);
    }
  }

  /** The next element's type code without consuming it (null at end). */
  peekType(): number | null {
    return this.pos < this.buf.length ? this.buf[this.pos] : null;
  }

  /** The remaining unread bytes (a valid struple stream). */
  rest(): Uint8Array {
    return this.buf.subarray(this.pos);
  }

  /** The next element's raw bytes (a zero-copy view), advancing the cursor. */
  nextView(): Uint8Array | null {
    const start = this.pos;
    if (this.next() === null) return null;
    return this.buf.subarray(start, this.pos);
  }

  /** Advance past the next element; false at end of stream. */
  skip(): boolean {
    return this.nextView() !== null;
  }

  take(n: number): Uint8Array {
    if (this.pos + n > this.buf.length) throw new Error("struple: truncated");
    const s = this.buf.subarray(this.pos, this.pos + n);
    this.pos += n;
    return s;
  }

  takeFramed(): Uint8Array {
    const start = this.pos;
    let i = this.pos;
    while (i < this.buf.length) {
      if (this.buf[i] === 0x00) {
        if (i + 1 < this.buf.length && this.buf[i + 1] === 0xff) {
          i += 2;
          continue;
        }
        const slice = this.buf.subarray(start, i);
        this.pos = i + 1;
        return slice;
      }
      i++;
    }
    throw new Error("struple: truncated (unterminated framed value)");
  }

  readFixedInt(t: number): Element {
    const positive = t > T.intZero;
    const n = positive ? t - T.intZero : T.intZero - t;
    const payload = this.take(n);
    // The widest (16-byte) slots can address values outside i128; a canonical
    // encoder uses the big-int codes for those, so reject them here.
    if (n === 16 && ((positive && payload[0] >= 0x80) || (!positive && payload[0] < 0x80)))
      throw new Error("struple: non-canonical 16-byte integer");
    let raw = 0n;
    for (const b of payload) raw = (raw << 8n) | BigInt(b);
    return { kind: "int", value: positive ? raw : raw - (1n << BigInt(8 * n)) };
  }

  readBigInt(t: number): Element {
    const negative = t === T.intNegBig;
    const comp = (b: number): number => (negative ? ~b & 0xff : b);
    const m = comp(this.take(1)[0]);
    let n = 0;
    for (const b of this.take(m)) n = (n << 8) | comp(b);
    let mag = 0n;
    for (const b of this.take(n)) mag = (mag << 8n) | BigInt(comp(b));
    return { kind: "int", value: negative ? -mag : mag };
  }

  readTimestamp(): Element {
    const bytes = this.take(8);
    const dv = new DataView(bytes.buffer, bytes.byteOffset, 8);
    const raw = dv.getBigUint64(0, false) ^ SIGN64;
    return { kind: "timestamp", micros: BigInt.asIntN(64, raw) };
  }
}

/** Decode a whole stream into native values. */
export function unpack(bytes: Uint8Array): Value[] {
  const r = new Reader(bytes);
  const out: Value[] = [];
  let e: Element | null;
  while ((e = r.next()) !== null) out.push(elementToValue(e));
  return out;
}

function elementToValue(e: Element): Value {
  switch (e.kind) {
    case "nil":
      return null;
    case "undef":
      return undefined;
    case "bool":
      return e.value;
    case "int":
      return e.value;
    case "float32":
    case "float64":
      return e.value;
    case "timestamp":
      return new Date(Number(e.micros / 1000n));
    case "uuid":
      return e.value;
    case "string":
      return e.value;
    case "bytes":
      return e.value;
    case "array":
      return unpack(e.body);
    case "set":
      return new Set(unpack(e.body));
    case "map": {
      const m = new Map<Value, Value>();
      const r = new Reader(e.body);
      let k: Element | null;
      while ((k = r.next()) !== null) {
        const v = r.next();
        if (v === null) throw new Error("struple: malformed map");
        m.set(elementToValue(k), elementToValue(v));
      }
      return m;
    }
  }
}

/** Decode every element and re-encode it. The output equals the input for any
 *  canonical buffer — a full round-trip validation of the decoder (and a way to
 *  re-canonicalize a buffer from another encoder). */
export function transcode(bytes: Uint8Array): Uint8Array {
  const r = new Reader(bytes);
  const out: number[] = [];
  let e: Element | null;
  while ((e = r.next()) !== null) appendElement(out, e);
  return Uint8Array.from(out);
}

function appendElement(out: number[], e: Element): void {
  switch (e.kind) {
    case "nil":
      out.push(T.nil);
      break;
    case "undef":
      out.push(T.undef);
      break;
    case "bool":
      out.push(e.value ? T.boolTrue : T.boolFalse);
      break;
    case "int":
      appendInteger(out, e.value);
      break;
    case "float32":
      appendFloat32Into(out, e.value);
      break;
    case "float64":
      appendFloat64Into(out, e.value);
      break;
    case "timestamp":
      appendTimestampInto(out, e.micros);
      break;
    case "uuid":
      appendUuidInto(out, e.value);
      break;
    case "string":
      writeFramed(out, T.string, utf8Encode.encode(e.value));
      break;
    case "bytes":
      writeFramed(out, T.bytes, e.value);
      break;
    case "array":
      writeFramed(out, T.array, e.body);
      break;
    case "map":
      writeFramed(out, T.map, e.body);
      break;
    case "set":
      writeFramed(out, T.set, e.body);
      break;
  }
}

// ---------------------------------------------------------------------------
// Ordering
// ---------------------------------------------------------------------------

/** Lexicographic byte comparison: < 0, 0, or > 0. Matches semantic order. */
export function compare(a: Uint8Array, b: Uint8Array): number {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) {
    if (a[i] !== b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

// ---------------------------------------------------------------------------
// Navigation / query
// ---------------------------------------------------------------------------

/** Zero-copy navigation over a struple buffer (a stream of elements). Every
 *  result is a sub-view that is itself a valid struple buffer. */
export class View {
  readonly bytes: Uint8Array;
  constructor(bytes: Uint8Array) {
    this.bytes = bytes;
  }
  reader(): Reader {
    return new Reader(this.bytes);
  }

  count(): number {
    const r = this.reader();
    let n = 0;
    while (r.skip()) n++;
    return n;
  }
  at(index: number): Uint8Array | null {
    const r = this.reader();
    let i = 0;
    let v: Uint8Array | null;
    while ((v = r.nextView()) !== null) {
      if (i === index) return v;
      i++;
    }
    return null;
  }
  head(): Uint8Array | null {
    return this.at(0);
  }
  tail(): Uint8Array {
    const r = this.reader();
    r.nextView();
    return r.rest();
  }
  nthRest(n: number): Uint8Array {
    const r = this.reader();
    for (let i = 0; i < n; i++) if (!r.skip()) break;
    return r.rest();
  }
  take(n: number): Uint8Array {
    const r = this.reader();
    for (let i = 0; i < n; i++) if (!r.skip()) break;
    return this.bytes.subarray(0, this.bytes.length - r.rest().length);
  }
  headType(): number | null {
    return this.bytes.length > 0 ? this.bytes[0] : null;
  }

  isNil(): boolean { return this.headType() === T.nil; }
  isUndefined(): boolean { return this.headType() === T.undef; }
  isBool(): boolean { const t = this.headType(); return t === T.boolFalse || t === T.boolTrue; }
  isInt(): boolean {
    const t = this.headType();
    return t !== null && (t === T.intZero || t === T.intNegBig || t === T.intPosBig || (t >= 0x10 && t <= 0x1f) || (t >= 0x21 && t <= 0x30));
  }
  isFloat(): boolean { const t = this.headType(); return t === T.float32 || t === T.float64; }
  isNumber(): boolean { return this.isInt() || this.isFloat(); }
  isTimestamp(): boolean { return this.headType() === T.timestamp; }
  isUuid(): boolean { return this.headType() === T.uuid; }
  isString(): boolean { return this.headType() === T.string; }
  isBytes(): boolean { return this.headType() === T.bytes; }
  isArray(): boolean { return this.headType() === T.array; }
  isMap(): boolean { return this.headType() === T.map; }
  isSet(): boolean { return this.headType() === T.set; }
  isContainer(): boolean { const t = this.headType(); return t === T.array || t === T.map || t === T.set; }

  /** The container's inner element stream (un-escaped), or null if the head
   *  isn't an array/map/set. View it, or wrap a map with MapView. */
  containedItems(): Uint8Array | null {
    if (!this.isContainer()) return null;
    const e = this.reader().next();
    if (e === null) return null;
    return e.kind === "array" || e.kind === "map" || e.kind === "set" ? e.body : null;
  }
}

export function view(bytes: Uint8Array): View {
  return new View(bytes);
}

/** Reads key/value pairs from a map's inner stream (from View.containedItems).
 *  Keys are canonical (sorted), so `get` early-exits. */
export class MapView {
  readonly inner: Uint8Array;
  constructor(inner: Uint8Array) {
    this.inner = inner;
  }
  count(): number {
    return new View(this.inner).count() / 2;
  }
  *entries(): Generator<[Uint8Array, Uint8Array]> {
    const r = new Reader(this.inner);
    let k: Uint8Array | null;
    while ((k = r.nextView()) !== null) {
      const v = r.nextView();
      if (v === null) throw new Error("struple: malformed map");
      yield [k, v];
    }
  }
  /** Look up the value bytes for an encoded key (e.g. `encode("name")`). */
  get(key: Uint8Array): Uint8Array | null {
    for (const [k, v] of this.entries()) {
      const c = compare(k, key);
      if (c === 0) return v;
      if (c > 0) return null;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Encoding internals
// ---------------------------------------------------------------------------

function appendValue(buf: number[], value: Value): void {
  if (value === null) {
    buf.push(T.nil);
    return;
  }
  if (value === undefined) {
    buf.push(T.undef);
    return;
  }
  switch (typeof value) {
    case "boolean":
      buf.push(value ? T.boolTrue : T.boolFalse);
      return;
    case "bigint":
      appendInteger(buf, value);
      return;
    case "number":
      if (Number.isInteger(value)) appendInteger(buf, BigInt(value));
      else appendFloat64Into(buf, value);
      return;
    case "string":
      writeFramed(buf, T.string, utf8Encode.encode(value));
      return;
    case "object": {
      if (value instanceof Uint8Array) {
        writeFramed(buf, T.bytes, value);
        return;
      }
      if (Array.isArray(value)) {
        const child = new Writer();
        for (const item of value) child.append(item);
        writeFramed(buf, T.array, child.bytes());
        return;
      }
      if (value instanceof Map) {
        const entries: Array<[Uint8Array, Uint8Array]> = [];
        for (const [k, v] of value) entries.push([encode(k), encode(v)]);
        appendMapInto(buf, entries);
        return;
      }
      if (value instanceof Set) {
        const elems: Uint8Array[] = [];
        for (const e of value) elems.push(encode(e));
        appendSetInto(buf, elems);
        return;
      }
      if (value instanceof Date) {
        appendTimestampInto(buf, BigInt(value.getTime()) * 1000n);
        return;
      }
      const entries: Array<[Uint8Array, Uint8Array]> = [];
      for (const k of Object.keys(value)) {
        entries.push([encode(k), encode((value as { [key: string]: Value })[k])]);
      }
      appendMapInto(buf, entries);
      return;
    }
  }
  throw new Error(`struple: cannot encode value of type ${typeof value}`);
}

function appendInteger(buf: number[], value: bigint): void {
  if (value === 0n) {
    buf.push(T.intZero);
    return;
  }
  const negative = value < 0n;
  const mag = negative ? -value : value;
  // The fixed slots span the whole i128 range (1–16 byte magnitudes).
  if (value >= I128_MIN && value <= I128_MAX) {
    if (negative) {
      const posVal = mag - 1n;
      let n = byteLenBig(posVal);
      if (n === 0) n = 1;
      buf.push(T.intZero - n);
      pushBigEndian(buf, (1n << BigInt(8 * n)) - mag, n);
    } else {
      const magBytes = bigIntToBytes(mag);
      buf.push(T.intZero + magBytes.length);
      for (const b of magBytes) buf.push(b);
    }
    return;
  }
  // arbitrary precision beyond i128: [m][n][magnitude], complemented for negatives
  const magBytes = bigIntToBytes(mag);
  buf.push(negative ? T.intNegBig : T.intPosBig);
  const n = magBytes.length;
  const m = byteLenNum(n);
  const comp = (b: number): number => (negative ? ~b & 0xff : b);
  buf.push(comp(m));
  for (let i = m - 1; i >= 0; i--) buf.push(comp((n >>> (8 * i)) & 0xff));
  for (const b of magBytes) buf.push(comp(b));
}

function appendFloat64Into(buf: number[], value: number): void {
  let bits: bigint;
  if (Number.isNaN(value)) {
    bits = 0x7ff8000000000000n;
  } else {
    const dv = new DataView(new ArrayBuffer(8));
    dv.setFloat64(0, value === 0 ? 0 : value, false); // squash -0.0
    bits = dv.getBigUint64(0, false);
  }
  bits = bits & SIGN64 ? ~bits & MASK64 : bits ^ SIGN64;
  buf.push(T.float64);
  pushBigEndian(buf, bits, 8);
}

function appendFloat32Into(buf: number[], value: number): void {
  let bits: number;
  if (Number.isNaN(value)) {
    bits = 0x7fc00000;
  } else {
    const dv = new DataView(new ArrayBuffer(4));
    dv.setFloat32(0, value === 0 ? 0 : value, false);
    bits = dv.getUint32(0, false);
  }
  bits = bits & 0x80000000 ? ~bits >>> 0 : (bits ^ 0x80000000) >>> 0;
  buf.push(T.float32, (bits >>> 24) & 0xff, (bits >>> 16) & 0xff, (bits >>> 8) & 0xff, bits & 0xff);
}

function appendTimestampInto(buf: number[], micros: bigint): void {
  buf.push(T.timestamp);
  pushBigEndian(buf, BigInt.asUintN(64, micros) ^ SIGN64, 8);
}

function appendUuidInto(buf: number[], u: Uint8Array): void {
  if (u.length !== 16) throw new Error("struple: uuid must be 16 bytes");
  buf.push(T.uuid);
  for (const b of u) buf.push(b);
}

function appendMapInto(buf: number[], entries: Array<[Uint8Array, Uint8Array]>): void {
  const sorted = [...entries].sort((x, y) => compare(x[0], y[0]));
  buf.push(T.map);
  for (const [k, v] of sorted) {
    writeEscaped(buf, k);
    writeEscaped(buf, v);
  }
  buf.push(T.terminator);
}

function appendSetInto(buf: number[], elements: Uint8Array[]): void {
  const sorted = [...elements].sort(compare);
  buf.push(T.set);
  let prev: Uint8Array | null = null;
  for (const e of sorted) {
    if (prev !== null && compare(prev, e) === 0) continue;
    writeEscaped(buf, e);
    prev = e;
  }
  buf.push(T.terminator);
}

function writeFramed(buf: number[], typeCode: number, content: Uint8Array): void {
  buf.push(typeCode);
  writeEscaped(buf, content);
  buf.push(T.terminator);
}

function writeEscaped(buf: number[], content: Uint8Array): void {
  for (let i = 0; i < content.length; i++) {
    const b = content[i];
    buf.push(b);
    if (b === 0x00) buf.push(0xff);
  }
}

function unescape(framed: Uint8Array): Uint8Array {
  if (framed.indexOf(0x00) === -1) return framed; // common case: nothing to do
  const out: number[] = [];
  for (let i = 0; i < framed.length; i++) {
    out.push(framed[i]);
    if (framed[i] === 0x00) i++; // skip the 0xff companion
  }
  return Uint8Array.from(out);
}

function decodeFloat64(bytes: Uint8Array): number {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, 8);
  let bits = dv.getBigUint64(0, false);
  bits = bits & SIGN64 ? bits ^ SIGN64 : ~bits & MASK64;
  const out = new DataView(new ArrayBuffer(8));
  out.setBigUint64(0, bits, false);
  return out.getFloat64(0, false);
}

function decodeFloat32(bytes: Uint8Array): number {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, 4);
  let bits = dv.getUint32(0, false);
  bits = bits & 0x80000000 ? (bits ^ 0x80000000) >>> 0 : ~bits >>> 0;
  const out = new DataView(new ArrayBuffer(4));
  out.setUint32(0, bits, false);
  return out.getFloat32(0, false);
}

function bigIntToBytes(mag: bigint): number[] {
  const out: number[] = [];
  let v = mag;
  while (v > 0n) {
    out.push(Number(v & 0xffn));
    v >>= 8n;
  }
  out.reverse();
  return out;
}

function pushBigEndian(buf: number[], value: bigint, n: number): void {
  for (let i = n - 1; i >= 0; i--) buf.push(Number((value >> BigInt(8 * i)) & 0xffn));
}

function byteLenBig(x: bigint): number {
  if (x === 0n) return 0;
  return Math.ceil(x.toString(2).length / 8);
}

function byteLenNum(n: number): number {
  let m = 0;
  let t = n;
  while (t > 0) {
    m++;
    t = Math.floor(t / 256);
  }
  return m;
}
