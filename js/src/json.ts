// JSON <-> struple, mirroring the Zig reference.
//
//   fromJson: JSON text  -> struple encoding (one element for the root value)
//   toJson:   struple bytes -> canonical JSON text
//
// Integer JSON numbers are kept at arbitrary precision (a big integer that a
// native JSON.parse -> f64 would corrupt round-trips losslessly). Objects encode
// to canonical (key-sorted) maps.

import { Writer, Reader, type Element, MAX_DEPTH } from "./struple.ts";

/** Parse JSON text and return its struple encoding. */
export function fromJson(text: string): Uint8Array {
  // Reject hostile deeply-nested JSON before parsing: the native JSON.parse
  // recurses in V8 and throws a native RangeError ("Maximum call stack size
  // exceeded") on deep input. This linear bracket-depth pre-scan bounds both
  // that recursion and encodeJson below, surfacing the port's own Error (Item 5).
  checkJsonDepth(text);
  const w = new Writer();
  encodeJson(w, parseJsonPreservingBigInts(text), 0);
  return w.bytes();
}

/** Scan JSON text and reject if `[`/`{` nesting exceeds MAX_DEPTH. Brackets
 *  inside string literals (and after `\`) don't count. */
function checkJsonDepth(text: string): void {
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (c === "\\") escaped = true;
      else if (c === '"') inString = false;
      continue;
    }
    if (c === '"') inString = true;
    else if (c === "[" || c === "{") {
      depth++;
      if (depth > MAX_DEPTH) throw new Error("struple: nesting too deep");
    } else if (c === "]" || c === "}") {
      if (depth > 0) depth--;
    }
  }
}

/** Render a struple encoding's first element as canonical JSON text. */
export function toJson(bytes: Uint8Array): string {
  const e = new Reader(bytes).next();
  return e === null ? "null" : renderElement(e, 0);
}

// JSON.parse with the source-access reviver: integer-valued number tokens become
// BigInt (lossless); fractional/exponent tokens stay as Number (f64).
function parseJsonPreservingBigInts(text: string): unknown {
  return JSON.parse(text, function (_key, value, context?: { source?: string }) {
    if (typeof value === "number" && context && typeof context.source === "string" && !/[.eE]/.test(context.source)) {
      return BigInt(context.source);
    }
    return value;
  });
}

function encodeJson(w: Writer, value: unknown, depth: number): void {
  // Defense in depth: bound the struple-build recursion too, so even a value
  // tree that slipped past checkJsonDepth can't overflow the stack (Item 5).
  if (depth > MAX_DEPTH) throw new Error("struple: nesting too deep");
  if (value === null) {
    w.appendNil();
    return;
  }
  switch (typeof value) {
    case "boolean":
      w.appendBool(value);
      return;
    case "bigint":
      w.appendInt(value); // integer tokens
      return;
    case "number":
      w.appendFloat64(value); // fractional/exponent tokens
      return;
    case "string":
      w.appendString(value);
      return;
    case "object": {
      if (Array.isArray(value)) {
        const child = new Writer();
        for (const item of value) encodeJson(child, item, depth + 1);
        w.appendArray(child.bytes());
        return;
      }
      const obj = value as { [key: string]: unknown };
      const entries: Array<[Uint8Array, Uint8Array]> = [];
      for (const key of Object.keys(obj)) {
        const kp = new Writer();
        kp.appendString(key);
        const vp = new Writer();
        encodeJson(vp, obj[key], depth + 1);
        entries.push([kp.bytes(), vp.bytes()]);
      }
      w.appendMap(entries);
      return;
    }
  }
  throw new Error(`struple/json: cannot encode value of type ${typeof value}`);
}

function renderElement(e: Element, depth: number): string {
  // Bound recursion into nested containers so hostile deeply-nested input is
  // rejected rather than overflowing the stack (Item 5).
  if (depth > MAX_DEPTH) throw new Error("struple: nesting too deep");
  switch (e.kind) {
    case "nil":
    case "undef":
      return "null";
    case "bool":
      return e.value ? "true" : "false";
    case "int":
      return e.value.toString();
    case "float32":
    case "float64":
      return Number.isFinite(e.value) ? e.value.toString() : "null";
    case "decimal":
      return renderDecimal(e);
    case "timestamp":
      return e.micros.toString();
    case "uuid":
      return JSON.stringify(toUuidString(e.value));
    case "string":
      return JSON.stringify(e.value);
    case "bytes":
      return JSON.stringify(toBase64(e.value));
    case "array":
    case "set":
      return renderArray(e.body, depth);
    case "map":
      return renderMap(e.body, depth);
  }
}

function renderArray(body: Uint8Array, depth: number): string {
  const r = new Reader(body);
  const parts: string[] = [];
  let e: Element | null;
  while ((e = r.next()) !== null) parts.push(renderElement(e, depth + 1));
  return "[" + parts.join(",") + "]";
}

function renderMap(body: Uint8Array, depth: number): string {
  const r = new Reader(body);
  const parts: string[] = [];
  let k: Element | null;
  while ((k = r.next()) !== null) {
    const v = r.next();
    if (v === null) throw new Error("struple/json: malformed map");
    const key = k.kind === "string" ? JSON.stringify(k.value) : JSON.stringify(renderElement(k, depth + 1));
    parts.push(key + ":" + renderElement(v, depth + 1));
  }
  return "{" + parts.join(",") + "}";
}

// Render a decimal as an exact JSON number literal (plain notation, no exponent).
// One-way: fromJson never produces decimals (non-integer JSON numbers stay float64).
function renderDecimal(d: { negative: boolean; digits: number[]; exp: number }): string {
  if (d.digits.length === 0) return "0";
  const k = d.digits.length;
  const sign = d.negative ? "-" : "";
  const ds = d.digits.join("");
  if (d.exp >= 0) return sign + ds + "0".repeat(d.exp);
  const pointPos = k + d.exp; // number of integer-part digits
  if (pointPos > 0) return sign + ds.slice(0, pointPos) + "." + ds.slice(pointPos);
  return sign + "0." + "0".repeat(-pointPos) + ds;
}

function toUuidString(u: Uint8Array): string {
  let s = "";
  for (let i = 0; i < u.length; i++) {
    if (i === 4 || i === 6 || i === 8 || i === 10) s += "-";
    s += u[i].toString(16).padStart(2, "0");
  }
  return s;
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}
