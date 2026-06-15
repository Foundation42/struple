# struple conformance corpus

`vectors.json` is the language-neutral contract that every struple implementation
(Zig, Python, JavaScript, …) must satisfy. It is generated from the Zig reference
with `zig build vectors` — **do not edit by hand**.

Each entry is:

```json
{ "value": <canonical JSON value>, "bytes": "<lowercase hex of the encoding>" }
```

A conforming implementation must pass, for every vector:

| direction | check |
|---|---|
| encode | `fromJson(value)` equals `bytes` (byte-for-byte) |
| decode | `toJson(bytes)` equals `value` (canonical JSON) |

`value` is always in **canonical** form — object keys sorted, numbers
normalized — so both directions are exact equality, not just semantic
equivalence.

## Coverage

The current corpus covers the JSON-expressible type space: null, booleans,
integers across every width band (including arbitrary-precision values that a
JS `f64` round-trip would corrupt), floats, strings (including prefix pairs that
exercise lexicographic ordering, and escapes), arrays, and objects.

Still to add: typed vectors for the non-JSON struple types (timestamp, bytes,
set, undefined) with a language-neutral build descriptor.
