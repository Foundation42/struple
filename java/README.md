# struple — Java

A pure, **zero-dependency** Java port of [struple](../README.md): streaming,
lexicographically-ordered tuple packing. Byte-identical to the Zig reference and
the other five language ports, driven by the shared
[`conformance/`](../conformance) corpus.

Requires **JDK 26** (`javac` / `java` on PATH). No Maven/Gradle, no JUnit — the
test runners are plain `main()` methods, exactly like the C and C++ ports.

## Build & test

```sh
cd java
./run-tests.sh
```

`run-tests.sh` compiles every source + test (`javac -d build`) and runs the two
conformance runners, which read `../conformance/*.json`, print a summary, and
exit nonzero on any failure:

```
TestConformance: json encode 35 decode 35 | build 25 transcode 25 | semantic 41 | 0 failures
TestStruple: 156 checks | 0 failures
```

- **`struple.TestConformance`** — the shared corpus: all 60 vectors in both
  directions (`fromJson`/`toJson` for the 35 JSON entries, `encode(build(op))` /
  `transcode(bytes)` for the 25 build entries) plus the 41 semantic-order pairs.
- **`struple.TestStruple`** — golden + round-trip checks (decimal, uuid, integer)
  and the navigation surface (View / MapView / IndexedMap), mirroring
  `src/tests.zig`.

## API

Package `struple`. Everything is in four files, zero dependencies (a tiny JSON
parser + serializer is hand-rolled — Java has no stdlib JSON).

### Codec — `Struple`

```java
import struple.Struple;
import struple.Struple.Packer;
import struple.Struple.Reader;
import struple.Struple.Element;

byte[] key = new Packer()
    .appendString("users")
    .appendInt(12345)
    .appendString("alice")
    .appendBool(true)
    .bytes();                       // memcmp-orderable bytes

Reader r = new Reader(key);
Element e;
while ((e = r.next()) != null) {
    switch (e.kind) {
        case STRING  -> use(e.string());
        case INT     -> use(e.intValue());   // java.math.BigInteger
        case BOOLEAN -> use(e.boolValue());
        default      -> {}
    }
}

Struple.compare(keyA, keyB);        // -1 / 0 / 1 — that's the comparator
```

`Packer` methods: `appendNil`, `appendUndefined`, `appendBool`, `appendInt`,
`appendBigInteger` (`java.math.BigInteger`; i128 fixed slots vs big-int codes),
`appendBigInt(negative, magnitudeBe)`, `appendFloat32`, `appendFloat64`,
`appendDecimal(BigDecimal)` / `appendDecimal(negative, digits, exp)` /
`appendDecimalString`, `appendTimestamp` (µs since epoch), `appendUuid`
(`byte[16]` or `java.util.UUID`), `appendString`, `appendBytes`, `appendArray`,
`appendMap` (canonical key-sorted), `appendSet` (canonical sorted + deduped).

Decimals map natively to/from `java.math.BigDecimal` (`Decimal.toBigDecimal()`),
and integers/big-ints to `java.math.BigInteger`.

### JSON — `Json`

```java
byte[] key   = Json.fromJson("{\"id\":12345,\"name\":\"alice\"}");
String json  = Json.toJson(key);    // {"id":12345,"name":"alice"}
```

Big integers stay lossless (integer tokens parse to `BigInteger`); non-integer
JSON numbers become float64; objects become canonical (key-sorted) maps. The
`toJson` text is byte-identical to the corpus (float text matches
ECMAScript `Number.prototype.toString`). `Json.parse` exposes the generic value
model for tooling.

### Navigation — `Navigate`

```java
import struple.Navigate;
import struple.Navigate.View;
import struple.Navigate.MapView;
import struple.Navigate.IndexedMap;

View v = Navigate.view(key);
v.count(); v.at(2); v.head(); v.tail(); v.nthRest(2); v.take(2);
v.headType(); v.isString(); v.isMap(); v.isNumber(); v.isDecimal();
byte[] inner = v.containedItems();          // un-escaped inner stream

MapView m = new MapView(inner);
m.get(encodedKey);                          // ordered scan, early-exit
IndexedMap im = m.indexed();                // O(log n) get, O(1) at
```

### Semantic order — `Semantic`

```java
Semantic.semanticOrder(a, b);   // value order: int 5 == float 5.0 (-1/0/1)
Semantic.semanticEqual(a, b);
```

Exact cross-representation number comparison (int / big-int / float32 / float64 /
decimal unified) via `BigDecimal`/`BigInteger` — `int 2^53+1 > float 2^53`,
`decimal 0.1 < float 0.1`, `-0.0 == 0`, NaN greatest. Class order: nil < undef <
bool < number < timestamp < uuid < string < bytes < array < map < set; containers
recurse.

## License

Apache-2.0 — see [../LICENSE](../LICENSE). Copyright 2026 Christian Beaumont.
