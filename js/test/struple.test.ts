import { test } from "node:test";
import assert from "node:assert/strict";
import { pack, encode, unpack, compare, Writer } from "../src/index.ts";

function hex(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += b.toString(16).padStart(2, "0");
  return s;
}

function fromHex(s: string): Uint8Array {
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.slice(i * 2, i * 2 + 2), 16);
  return out;
}

test("golden bytes match the wire format", () => {
  assert.equal(hex(encode(null)), "01");
  assert.equal(hex(encode(true)), "06");
  assert.equal(hex(encode(0n)), "20");
  assert.equal(hex(encode(255n)), "21ff");
  assert.equal(hex(encode(256n)), "220100");
  assert.equal(hex(encode(-1n)), "1fff");
  assert.equal(hex(encode(-100n)), "1f9c");
  assert.equal(hex(encode("app")), "4861707000");
  // wide integers now use the fixed slots (the i128 range)
  assert.equal(hex(encode(1n << 64n)), "29010000000000000000"); // 9-byte fixed positive
  assert.equal(hex(encode((1n << 127n) - 1n)), "307fffffffffffffffffffffffffffffff"); // i128 max
  assert.equal(hex(encode(-(1n << 127n))), "1080000000000000000000000000000000"); // i128 min
  assert.equal(hex(encode(1n << 127n)), "31011080000000000000000000000000000000"); // first big-int
});

test("uuid: golden bytes and round-trip", () => {
  const u = fromHex("550e8400e29b41d4a716446655440000");
  const w = new Writer();
  w.appendUuid(u);
  assert.equal(hex(w.bytes()), "44550e8400e29b41d4a716446655440000");
  const [e] = unpack(w.bytes());
  assert.deepEqual(e, u);
});

test("integer round-trips incl. arbitrary precision", () => {
  const cases = [
    0n, 1n, -1n, 255n, 256n, -256n, -257n,
    9223372036854775807n, -9223372036854775808n,
    1n << 64n, -(1n << 64n), 10n ** 40n, -(10n ** 50n),
  ];
  for (const v of cases) {
    const [out] = unpack(encode(v));
    assert.equal(out, v, `round-trip ${v}`);
  }
});

test("ordering: app < apple, and negatives sort correctly", () => {
  assert.ok(compare(encode("app"), encode("apple")) < 0);
  assert.ok(compare(encode(-256n), encode(-100n)) < 0);
  assert.ok(compare(encode(-100n), encode(-1n)) < 0);
  assert.ok(compare(encode(-(1n << 100n)), encode(-(1n << 64n))) < 0); // big negatives
});

test("ordering: a sorted-by-value list stays sorted by bytes", () => {
  const values = [
    null, false, true,
    -(1n << 70n), -1000n, -1n, 0n, 1n, 1000n, 1n << 70n,
    "", "app", "apple", "b",
  ];
  const encoded = values.map((v) => encode(v as any));
  for (let i = 1; i < encoded.length; i++) {
    assert.ok(compare(encoded[i - 1], encoded[i]) < 0, `index ${i}`);
  }
  // shuffle + sort by bytes reproduces the original order
  const shuffled = [...encoded].reverse();
  shuffled.sort(compare);
  for (let i = 0; i < encoded.length; i++) {
    assert.equal(hex(shuffled[i]), hex(encoded[i]));
  }
});

test("containers: array, map (canonical), set (deduped)", () => {
  // array round-trip
  const arr = pack([1n, 2n, 3n]);
  const [arrOut] = unpack(arr);
  assert.deepEqual(arrOut, [1n, 2n, 3n]);

  // map canonicalization: insertion order does not affect bytes
  const m1 = encode(new Map<any, any>([["b", 2n], ["a", 1n]]));
  const m2 = encode(new Map<any, any>([["a", 1n], ["b", 2n]]));
  assert.equal(hex(m1), hex(m2));

  // set dedup + sort
  const s = encode(new Set([2n, 1n, 2n, 3n, 1n]));
  const [setOut] = unpack(s) as [Set<bigint>];
  assert.deepEqual([...setOut].sort((x, y) => Number(x - y)), [1n, 2n, 3n]);

  // array < map < set by type code
  assert.ok(compare(pack([1n]), encode(new Map([["a", 1n]]))) < 0);
  assert.ok(compare(encode(new Map([["a", 1n]])), encode(new Set([1n]))) < 0);
});

test("float total ordering", () => {
  // Encode explicitly as float64 (the generic encoder maps integer-valued
  // numbers to ints, so use the Writer directly for the whole-number cases).
  const floatBytes = (f: number): Uint8Array => new Writer().appendFloat64(f).bytes();
  const fs = [-Infinity, -1.5, -1.0, 0.0, 1.0, 1.5, Infinity];
  const enc = fs.map(floatBytes);
  for (let i = 1; i < enc.length; i++) {
    assert.ok(compare(enc[i - 1], enc[i]) < 0, `float order ${fs[i - 1]} < ${fs[i]}`);
  }

  // float64 round-trips by value
  for (const f of [-3.5, -1.0, 0.0, 0.1, 1.5, 1e300]) {
    const [out] = unpack(floatBytes(f));
    assert.equal(out, f);
  }
});
