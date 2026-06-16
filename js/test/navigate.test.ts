import { test } from "node:test";
import assert from "node:assert/strict";
import { pack, encode, view, View, MapView, IndexedMap, Reader } from "../src/index.ts";

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

test("navigate: indexed map (O(log n) get, positional at)", () => {
  // eight entries "a".."h" -> 1..8, fed out of order so canonicalization sorts them
  const keys = ["h", "c", "a", "g", "d", "f", "b", "e"];
  const m = new Map<unknown, unknown>(keys.map((k, i) => [k, BigInt(i + 1)]));
  const v = view(encode(m));
  assert.ok(v.isMap());
  const inner = v.containedItems()!;
  const im = new IndexedMap(inner);

  assert.equal(im.count(), 8);

  // at() walks canonical (sorted) order: a,b,c,...,h
  const sorted = "abcdefgh";
  for (let i = 0; i < sorted.length; i++) {
    assert.equal(strOf(im.at(i)![0]), sorted[i]);
  }
  assert.equal(im.at(8), null); // out of range

  // get() binary-searches; agrees with the linear MapView.get on every key
  const mv = new MapView(inner);
  for (const ch of sorted) {
    const key = encode(ch);
    const want = mv.get(key)!;
    assert.equal(hex(im.get(key)!), hex(want));
  }
  // "e" was inserted 8th (value 8) but sits at sorted position 4 — get still finds it
  assert.equal(im.find(encode("e")), 4);
  assert.equal(intOf(im.get(encode("e"))!), 8n);

  // misses: before, between, and after the key range
  assert.equal(im.get(encode("A")), null); // below "a"
  assert.equal(im.get(encode("cc")), null); // between "c" and "d"
  assert.equal(im.get(encode("z")), null); // above "h"
  assert.equal(im.find(encode("a")), 0);
  assert.equal(im.find(encode("h")), 7);

  // iterator yields the same canonical order
  assert.deepEqual([...im].map(([k]) => strOf(k)), [...sorted]);
  assert.equal([...im].length, 8);

  // mapView.indexed() shortcut builds the same index
  assert.equal(mv.indexed().count(), 8);
});
