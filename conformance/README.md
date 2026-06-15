# struple conformance corpus

`vectors.json` is the language-neutral contract that every struple implementation
(Zig, TypeScript, Python, …) must satisfy. It is generated from the Zig reference
with `zig build vectors` — **do not edit by hand**.

There are two entry shapes, distinguished by which key is present:

```json
{ "json":  "<canonical JSON text>", "bytes": "<hex>" }
{ "build": <op>,                    "bytes": "<hex>" }
```

A conforming implementation must pass, for every vector:

| entry | check | check |
|---|---|---|
| `json`  | `fromJson(json)` == `bytes` | `toJson(bytes)` == `json` |
| `build` | `encode(build(op))` == `bytes` | `transcode(bytes)` == `bytes` |

`json` is stored as a **string** (exact canonical text) so the contract is
unambiguous regardless of how a consumer parses numbers. `transcode` decodes
every element and re-encodes it, so the build-entry decode check is exact even
for types a language can't natively round-trip (Python has no `undefined`; JS
`Date` is millisecond-only).

## The build op language

JSON cannot express several struple types, so build entries use a tiny op
language. An **op** is a one-key object; integers and timestamps are decimal
strings (to stay precise and language-neutral), bytes are hex:

| op | builds |
|---|---|
| `{"nil": null}` | nil |
| `{"undef": null}` | undefined |
| `{"bool": true}` | bool |
| `{"int": "123"}` | integer |
| `{"float64": 1.5}` / `{"float32": 1.5}` | float |
| `{"timestamp": "1000000"}` | timestamp (µs since epoch) |
| `{"uuid": "550e8400e29b41d4a716446655440000"}` | uuid (16 hex bytes) |
| `{"string": "abc"}` | string |
| `{"bytes": "00ff01"}` | bytes (hex) |
| `{"array": [op, …]}` | array |
| `{"set": [op, …]}` | set |
| `{"map": [[keyOp, valOp], …]}` | map (keys may be any type) |

`build` interprets an op into a value/encoding; the interpreter is mirrored
identically in the Zig generator and every language's conformance test.

## Coverage

JSON entries: null, booleans, integers across every width band — including the
9–16 byte fixed slots and both sides of the i128 / big-int boundary (values a JS
`f64` round-trip would corrupt) — non-integer floats, strings (prefix pairs +
escapes), arrays, objects.

Build entries: undefined, float32, timestamps (incl. negative), uuid (incl. one
with embedded NULs, inside an array), bytes (incl. embedded NULs), sets
(dedup/sort), maps with non-string keys, and compositions.
