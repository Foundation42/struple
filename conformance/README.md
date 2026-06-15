# struple conformance corpus

`vectors.json` is the language-neutral contract that every struple implementation
(Zig, TypeScript, Python, …) must satisfy. It is generated from the Zig reference
with `zig build vectors` — **do not edit by hand**.

Each entry is:

```json
{ "json": "<canonical JSON text>", "bytes": "<lowercase hex of the encoding>" }
```

`json` is stored as a **string** (the exact canonical text) so the contract is
unambiguous regardless of how a consumer parses numbers. A conforming
implementation must pass, for every vector:

| direction | check |
|---|---|
| encode | `fromJson(json)` equals `bytes` (byte-for-byte) |
| decode | `toJson(bytes)` equals `json` (string-for-string) |

Both directions are exact equality — the Zig reference and the TypeScript port
agree on every byte, including float rendering.

## Coverage

null, booleans, integers across every width band (including arbitrary-precision
values a JS `f64` round-trip would corrupt), non-integer floats, strings
(including prefix pairs that exercise lexicographic ordering, and escapes),
arrays, and objects.

Floats are non-integer-valued so their canonical text keeps a decimal point and
round-trips as a float (an integer-valued float would render as integer text).

Still to add: typed vectors for the non-JSON struple types (timestamp, bytes,
set, undefined) with a language-neutral build descriptor.
