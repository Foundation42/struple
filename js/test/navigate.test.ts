import { test } from "node:test";
import assert from "node:assert/strict";
import { pack, encode, view, View, MapView, Reader } from "../src/index.ts";

function intOf(bytes: Uint8Array): bigint {
  const e = new Reader(bytes).next();
  if (!e || e.kind !== "int") throw new Error("not int");
  return e.value;
}
function strOf(bytes: Uint8Array): string {
  const e = new Reader(bytes).next();
  if (!e || e.kind !== "string") throw new Error("not string");
  return e.value;
}
const hex = (b: Uint8Array) => [...b].map((x) => x.toString(16).padStart(2, "0")).join("");

test("navigate: stream ops", () => {
  const buf = pack("users", 12345n, true, [1n, 2n, 3n]);
  const v = view(buf);
  assert.equal(v.count(), 4);
  assert.equal(strOf(v.at(0)!), "users");
  assert.equal(intOf(v.at(1)!), 12345n);
  assert.equal(v.at(4), null);
  assert.equal(hex(v.head()!), hex(v.at(0)!));
  assert.equal(new View(v.tail()).count(), 3);
  assert.equal(new View(v.nthRest(2)).count(), 2);
  const tk = v.take(2);
  assert.equal(new View(tk).count(), 2);
  assert.equal(hex(tk), hex(buf.subarray(0, tk.length)));
});

test("navigate: predicates + container descent", () => {
  assert.ok(view(encode("x")).isString());
  assert.ok(view(encode(5n)).isInt() && view(encode(5n)).isNumber());
  assert.ok(view(encode(1.5)).isFloat() && !view(encode(1.5)).isInt());
  assert.ok(view(encode(null)).isNil());
  assert.ok(view(encode(true)).isBool());

  const v = view(pack([10n, 20n]));
  assert.ok(v.isArray() && v.isContainer());
  assert.equal(v.count(), 1);
  const inner = view(v.containedItems()!);
  assert.equal(inner.count(), 2);
  assert.equal(intOf(inner.at(0)!), 10n);
  assert.equal(intOf(inner.at(1)!), 20n);
});

test("navigate: map lookup", () => {
  const v = view(encode(new Map<unknown, unknown>([["c", 3n], ["a", 1n], ["b", 2n]])));
  assert.ok(v.isMap());
  const m = new MapView(v.containedItems()!);
  assert.equal(m.count(), 3);
  assert.equal(intOf(m.get(encode("b"))!), 2n);
  assert.equal(m.get(encode("z")), null);
  assert.equal(m.get(encode("aa")), null);
  assert.deepEqual([...m.entries()].map(([k]) => strOf(k)), ["a", "b", "c"]);
});
