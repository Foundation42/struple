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
