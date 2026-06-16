# struple (Swift)

A pure-Swift implementation of [struple](../README.md) — streaming,
lexicographically-ordered tuple packing whose encoded bytes are directly
`memcmp`-comparable. Byte-identical to the Zig reference (verified against
[`../conformance/vectors.json`](../conformance/vectors.json) and
[`../conformance/semantic_vectors.json`](../conformance/semantic_vectors.json)).

**Zero dependencies.** The `Struple` library is Foundation-free. Swift 6's native
`Int128` / `UInt128` cover the fixed integer range; everything beyond i128 (big
integers, the decimal coefficient, exact decimal-vs-float comparison) is
hand-rolled on byte-magnitude arithmetic, and the JSON codec is hand-rolled too
(so big JSON integers round-trip losslessly). Foundation is used **only** by the
test runner, to read the corpus files.

```swift
import Struple

var w = Writer()
w.appendString("users")
w.appendInt(12345)
w.appendString("alice")
w.appendBool(true)
let key = w.bytes // [UInt8] — compare(a, b) sorts like the values

var r = Reader(key)
while let e = try r.next() {
    switch e {
    case .string(let framed): _ = unescape(framed)
    case .int(let v):         _ = v
    case .boolean(let b):     _ = b
    default: break
    }
}

let bytes = try fromJson(#"{"id":12345,"name":"alice"}"#)
let json  = try toJson(bytes) // {"id":12345,"name":"alice"}
```

## Public API

- **Codec** (`Struple.swift`): `Writer` (`appendNil`, `appendUndefined`,
  `appendBool`, `appendInt`/`appendUInt`/`appendI128`/`appendBigInt`,
  `appendF32`/`appendF64`, `appendDecimal`/`appendDecimalString`,
  `appendTimestamp`, `appendUuid`, `appendString`/`appendBytes`,
  `appendArray`/`appendMap`/`appendSet`); `Reader` (streaming `next`, plus the
  cursor surface `peekType`, `nextView`, `skip`, `rest`); `Element` / `Kind`;
  `BigInt`; `Decimal`; `compare`; `unescape`; `transcode`.
- **JSON** (`Json.swift`): `fromJson`, `toJson`.
- **Navigation** (`Navigate.swift`): `View` (`count`, `at`, `head`, `tail`,
  `nthRest`, `take`, `headType`, the `is*` predicates incl. `isDecimal`/
  `isNumber`, `containerBody`, `containedItems`); `MapView` (`count`, `get`,
  iterator, `indexed`); `IndexedMap` (`count`, `at`, `get`/`find` O(log n) binary
  search, iterator).
- **Semantic** (`Semantic.swift`): `semanticOrder`, `semanticEqual` — exact
  cross-representation number comparison (int / big-int / float32 / float64 /
  decimal unified).

## Build & test

SwiftPM is broken on this host (missing `libxml2.so.2`), so verification drives
`swiftc` directly:

```sh
cd swift && ./run-tests.sh
```

It compiles the sources + the runner with `swiftc -O`, then runs the conformance
corpus (60 vectors both directions: 35 JSON + 25 build; 41 semantic pairs) plus
navigation/IndexedMap/golden round-trip checks. It prints a summary and exits
nonzero on any failure.

A [`Package.swift`](Package.swift) is provided for real consumers with a working
SwiftPM (`import Struple`).
