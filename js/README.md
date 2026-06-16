# struple (TypeScript)

A pure-TypeScript implementation of [struple](../README.md) — streaming,
lexicographically-ordered tuple packing whose encoded bytes are directly
`memcmp`-comparable. Byte-identical to the Zig reference (verified against
[`../conformance/vectors.json`](../conformance/vectors.json)).

Zero dependencies, erasable TypeScript — Node ≥ 23.6 runs it with no build step.

```ts
import { pack, unpack, compare, fromJson, toJson } from "struple";

const key = pack("users", 12345n, "alice", true);  // Uint8Array, memcmp-orderable
compare(keyA, keyB);                                 // < 0 | 0 | > 0  ==  value order
unpack(key);                                         // ["users", 12345n, "alice", true]

// JSON in / JSON out — big integers stay lossless
const bytes = fromJson('{"id":12345,"name":"alice"}');
toJson(bytes); // {"id":12345,"name":"alice"}
```

## Unpacking

Encoded bytes aren't opaque — read the fields back out, no schema required. The
same forms work in every port:

```ts
import { pack, unpack, encode, view, Reader, MapView, IndexedMap } from "struple";

const key = pack("users", 12345n, "alice", true); // [table, id, name, active]

// 1. Whole-tuple unpack — decode every field at once; pick by position
const [table, id, name, active] = unpack(key);    // "users", 12345n, "alice", true

// 2. Streaming read loop — advance one element at a time, stop early
const r = new Reader(key);
for (let e = r.next(); e !== null; e = r.next()) if (e.kind === "string") break;

// 3. Type dispatch — branch on each element's kind; recurse into containers
const e = new Reader(key).next()!;                 // { kind: "string", value: "users" }
if (e.kind === "int") e.value;                     // bigint
else if (e.kind === "map") unpack(e.body);         // descend the inner stream

// 4. Random access — count / head / tail / at(i) without decoding everything
const v = view(key);
v.count();                                         // 4
unpack(v.at(2)!);                                  // ["alice"]  (just field 2)

// 5. Container descent — step into a nested map/array's inner stream
const inner = view(pack({ id: 12345n, name: "alice" })).containedItems()!;

// 6. Map lookup by key — MapView.get (linear) or IndexedMap (O(log n) get/find)
unpack(new MapView(inner).get(encode("name"))!);   // ["alice"]
const ix = new IndexedMap(inner);
unpack(ix.get(encode("name"))!);                   // ["alice"];  ix.find(...) -> 1
```

## Value mapping

| JS | struple |
|---|---|
| `null` / `undefined` | nil / undefined |
| `boolean` | bool |
| `bigint` | integer (arbitrary precision) |
| `number` | integer if integral, else float64 |
| `string` | string |
| `Uint8Array` | bytes |
| `Array` | array |
| `Map` / plain object | map (canonical, key-sorted) |
| `Set` | set (sorted, de-duped) |
| `Date` | timestamp |

`fromJson` instead classifies numbers by their JSON token — an integer token
becomes an arbitrary-precision integer (lossless), a fractional/exponent token a
float64.

## Test

```
npm test          # node --test, includes the conformance corpus
```
