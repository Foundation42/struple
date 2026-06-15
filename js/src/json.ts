// JSON <-> struple, mirroring the Zig reference.
//
//   fromJson: JSON text  -> struple encoding (one element for the root value)
//   toJson:   struple bytes -> canonical JSON text
//
// Integer JSON numbers are kept at arbitrary precision (a big integer that a
// native JSON.parse -> f64 would corrupt round-trips losslessly). Objects encode
// to canonical (key-sorted) maps.

import { Writer, Reader, type Element } from "./struple.ts";

/** Parse JSON text and return its struple encoding. */
export function fromJson(text: string): Uint8Array {
  const w = new Writer();
  encodeJson(w, parseJsonPreservingBigInts(text));
  return w.bytes();
}

/** Render a struple encoding's first element as canonical JSON text. */
export function toJson(bytes: Uint8Array): string {
  const e = new Reader(bytes).next();
  return e === null ? "null" : renderElement(e);
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

function encodeJson(w: Writer, value: unknown): void {
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
        for (const item of value) encodeJson(child, item);
        w.appendArray(child.bytes());
        return;
      }
      const obj = value as { [key: string]: unknown };
      const entries: Array<[Uint8Array, Uint8Array]> = [];
      for (const key of Object.keys(obj)) {
        const kp = new Writer();
        kp.appendString(key);
        const vp = new Writer();
        encodeJson(vp, obj[key]);
        entries.push([kp.bytes(), vp.bytes()]);
      }
      w.appendMap(entries);
      return;
    }
  }
  throw new Error(`struple/json: cannot encode value of type ${typeof value}`);
}

function renderElement(e: Element): string {
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
    case "timestamp":
      return e.micros.toString();
    case "string":
      return JSON.stringify(e.value);
    case "bytes":
      return JSON.stringify(toBase64(e.value));
    case "array":
    case "set":
      return renderArray(e.body);
    case "map":
      return renderMap(e.body);
  }
}

function renderArray(body: Uint8Array): string {
  const r = new Reader(body);
  const parts: string[] = [];
  let e: Element | null;
  while ((e = r.next()) !== null) parts.push(renderElement(e));
  return "[" + parts.join(",") + "]";
}

function renderMap(body: Uint8Array): string {
  const r = new Reader(body);
  const parts: string[] = [];
  let k: Element | null;
  while ((k = r.next()) !== null) {
    const v = r.next();
    if (v === null) throw new Error("struple/json: malformed map");
    const key = k.kind === "string" ? JSON.stringify(k.value) : JSON.stringify(renderElement(k));
    parts.push(key + ":" + renderElement(v));
  }
  return "{" + parts.join(",") + "}";
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}
