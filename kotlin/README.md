# struple — Kotlin/JVM

A pure, **zero-dependency** Kotlin/JVM port of [struple](../README.md):
streaming, lexicographically-ordered tuple packing. The encoded bytes are
directly `memcmp`-comparable, byte-identical to the Zig / TypeScript / Python /
Rust / C / C++ implementations, and verified against the shared conformance
corpus.

No Gradle, no JUnit — same zero-infra style as the C and C++ ports. Compiles
with `kotlinc` straight to a runnable jar.

## Quick start

```kotlin
import struple.*

val key = pack("users", 12345L, "alice", true)   // ByteArray — memcmp-orderable
order(keyA, keyB)                                  // -1 / 0 / 1  ==  value order

val r = reader(key)
while (true) { val e = r.next() ?: break /* e: Element.Str / Element.Int / … */ }

val bytes = fromJson("""{"id":12345,"name":"alice"}""")
val json  = toJson(bytes)                          // {"id":12345,"name":"alice"}
```

## Unpacking

Encoded bytes aren't opaque — read the fields back out, no schema required. The
same forms work in every port:

```kotlin
val key = pack("users", 12345L, "alice", true)        // [table, id, name, active]

// 1. Whole-tuple unpack — decode every field at once; pick by position
val fields = buildList { val r = reader(key); while (true) add(r.next() ?: break) }
val name = (fields[2] as Element.Str).value           // "alice"

// 2. Streaming read loop — advance one element at a time, stop early
val r = reader(key)
while (true) { val e = r.next() ?: break; if (e is Element.Int) break /* id=12345 */ }

// 3. Type dispatch — when() over the Element sealed class; recurse into containers
when (val e = reader(key).next()) {
    is Element.Str     -> e.value                      // "users"
    is Element.Int     -> e.value                      // BigInteger
    is Element.MapElem -> MapView(e.inner)             // descend into a nested map
    else -> {}
}

// 4. Random access — count / head / tail / at(i) without decoding everything
val v = view(key)
v.count(); v.head(); v.tail()                          // 4 / "users" elem / rest
val active = (reader(v.at(3)!!).next() as Element.Bool).value   // true

// 5. Container descent — step into a nested map's inner stream
val m = fromJson("""{"id":12345,"name":"alice"}""")
val inner = view(m).containedItems()!!                 // un-escaped [k][v]… stream

// 6. Map lookup by key — MapView.get (linear) or IndexedMap (O(log n) get/find)
val hit = MapView(inner).get(encode("name"))!!         // value bytes for "name"
(reader(hit).next() as Element.Str).value              // "alice"
val im = IndexedMap(inner)
im.find(encode("name")); im.at(1); im.get(encode("name"))
```

## Run the tests

```sh
cd kotlin
./run-tests.sh            # uses $HOME/kotlin-dist/kotlinc/bin/kotlinc (override with $KOTLINC)
```

This compiles `src/*.kt` + `test/*.kt` into one runtime jar and runs two plain
`main()` runners (CWD must be `kotlin/` so the relative `../conformance` paths
resolve). Each prints a summary and exits nonzero on any failure:

- `TestConformanceKt` — every vector in `../conformance/vectors.json` both
  directions (`fromJson`/`toJson` for JSON entries, `encode(build(op))` /
  `transcode` for build entries, with a build-op interpreter mirroring the Zig
  generator), plus every `../conformance/semantic_vectors.json` pair.
- `TestStrupleKt` — navigation / `IndexedMap` behavior (mirrors `src/tests.zig`)
  plus golden / round-trip decimal / uuid / int checks.

## Public API (package `struple`)

Encoding:

```kotlin
val key = pack("users", 12345L, "alice", true)   // memcmp-orderable bytes
val one = encode(BigDecimal("12.345"))            // single value

val w = Writer()
w.appendString("users").appendInt(12345L).appendBool(true)
w.appendDecimal(BigDecimal("1.5"))                // or appendDecimal(negative, digits, exp)
w.appendDecimalString("-0.001")
w.appendUuid(java.util.UUID.randomUUID())         // or a 16-byte ByteArray
w.appendTimestamp(micros)
val bytes = w.bytes()
```

`Writer` exposes the full explicit surface: `appendNil`, `appendUndefined`,
`appendBool`, `appendInt` (`Long` or `BigInteger` — the i128 fixed slots vs
big-int codes are chosen automatically), `appendFloat32`, `appendFloat64`,
`appendDecimal` / `appendDecimalString`, `appendTimestamp`, `appendUuid`,
`appendString`, `appendBytes`, `appendArray`, `appendMap`, `appendSet`,
`append(Any?)`. Maps are canonical (key-sorted); sets are sorted and de-duped.

Decoding (streaming, `Element` sealed class):

```kotlin
val r = reader(key)
while (true) {
    when (val e = r.next() ?: break) {
        is Element.Str -> e.value
        is Element.Int -> e.value          // BigInteger
        is Element.Dec -> e.value          // BigDecimal
        is Element.Float64 -> e.value
        else -> {}
    }
}
transcode(bytes)                            // decode + re-encode (round-trip check)
order(a, b)                                 // raw memcmp order: -1 / 0 / 1
```

JSON (hand-rolled, zero-dep parser + serializer; big integers lossless):

```kotlin
val k = fromJson("""{"id":12345,"name":"alice"}""")  // canonical key-sorted map
val j = toJson(k)                                     // {"id":12345,"name":"alice"}
```

Navigation (zero-copy `View` over a stream; `MapView` / `IndexedMap` over a
map's inner stream):

```kotlin
val v = view(key)
v.count(); v.at(2); v.head(); v.tail(); v.nthRest(2); v.take(2)
v.headType(); v.isString(); v.isNumber(); v.isMap()        // predicates
val inner = v.containedItems()                            // descend into a container
val m = MapView(inner!!)
m.get(encode("name")); m.entries()
val im = IndexedMap(inner)                                // O(log n) get, O(1) at
im.get(encode("name")); im.at(0); im.find(encode("name"))
```

Semantic (value-based) ordering — int / big-int / float32 / float64 / decimal
all compared by exact mathematical value:

```kotlin
order(a, b)            // raw byte order:  int 5 < float 5.0
semanticOrder(a, b)    // value order:     int 5 == float 5.0   (-1 / 0 / 1)
semanticEqual(a, b)
```

## Notes

- Integers are first-class `BigInteger`; the codec picks the i128 fixed slots vs
  the bracketing big-int codes automatically (canonical).
- Decimals map natively to `java.math.BigDecimal`
  (`unscaledValue()`/`scale()` ≈ the (coefficient, exp) wire model).
- Semantic exactness uses `BigDecimal` as the JVM equivalent of Python's
  `Fraction`: a finite double's true value is `BigDecimal(double)`, so
  cross-representation comparisons are exact with no precision loss.
- `toJson` renders shortest round-trip floats via `Double.toString` (stripping a
  trailing `.0` on integral values to match the reference).
