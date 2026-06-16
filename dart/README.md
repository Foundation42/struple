# struple (Dart)

Pure, **zero-dependency** Dart port of [struple](../README.md) — streaming,
lexicographically-ordered tuple packing. The encoded bytes are directly
`memcmp`-comparable: `compareBytes(pack(a), pack(b))` matches the semantic order
of `a` and `b`. Byte-identical to every other language port and pinned by the
shared conformance corpus (`../conformance/`).

Uses only the Dart SDK libraries (`dart:core` `BigInt`, `dart:convert`,
`dart:io`, `dart:typed_data`) — **no pub dependencies**.

## Quick start

```dart
import 'dart:convert';
import 'package:struple/struple.dart';

final w = Writer()
  ..appendString(utf8.encode('users'))
  ..appendInt(12345)
  ..appendString(utf8.encode('alice'))
  ..appendBool(true);
final key = w.bytes();              // Uint8List — memcmp-orderable

final r = Reader(key);
Element? e;
while ((e = r.next()) != null) {
  switch (e.kind) {
    case Kind.string: /* utf8.decode(unescape(e.body!)) */ break;
    case Kind.int_:   /* e.intValue! (BigInt)            */ break;
    default: break;
  }
}

compareBytes(keyA, keyB);           // -1 / 0 / 1 — that's the comparator
```

## Unpacking

Encoded bytes aren't opaque — read the fields back out, no schema required. The
same forms work in every port:

```dart
final v = View(key);                              // key = the Quick-start tuple

// 1. Whole-tuple unpack — no top-level unpack(); View picks by position.
final table = utf8.decode(unescape(Reader(v.at(0)!).next()!.body!)); // 'users'
final id    = Reader(v.at(1)!).next()!.intValue!;                    // BigInt 12345

// 2. Streaming read loop — advance one element at a time, stop early.
final r = Reader(key);
for (Element? e; (e = r.next()) != null;) {
  if (e!.kind == Kind.int_) break;                // got the id; leave rest unread
}

// 3. Type dispatch — switch on each element's kind; recurse into containers.
String show(Element e) => switch (e.kind) {
  Kind.string                => utf8.decode(unescape(e.body!)),
  Kind.int_ || Kind.bigInt   => '${e.intValue}',
  Kind.boolean               => '${e.boolValue}',
  Kind.array || Kind.map || Kind.set => '<${e.kind.name}>', // → Reader(unescape(e.body!))
  _                          => e.kind.name,
};

// 4. Random access — count / head / tail / at(i), no full decode.
v.count();                                         // 4
v.head(); v.tail();                                // element 0 view; elements 1.. stream
final name = utf8.decode(unescape(Reader(v.at(2)!).next()!.body!)); // 'alice'

// 5. Container descent — step into a nested map's inner stream.
final inner = View(mapBytes).containedItems()!;    // un-escaped {"id":..,"name":..}
final map   = MapView(inner);                       // map.count() == 2

// 6. Map lookup by key — encode the key, then MapView.get / IndexedMap.
final nameKey = (Writer()..appendString(utf8.encode('name'))).bytes();
map.get(nameKey);                                  // linear, early-exit → 'alice' bytes
map.indexed().find(nameKey);                       // IndexedMap: O(log n) get / find → 1
```

## API

- **Codec** (`lib/src/codec.dart`): `Writer` (`appendNil`, `appendUndefined`,
  `appendBool`, `appendInt`, `appendBigIntValue`, `appendBigInt`, `appendF32`,
  `appendF64`, `appendDecimal`, `appendDecimalString`, `appendTimestamp`,
  `appendUuid`, `appendString`, `appendBytes`, `appendArray`, `appendMap`,
  `appendSet`); `Reader` (`next`, `peekType`, `nextView`, `skip`, `rest`,
  `done`); `Element` / `Kind` / `Decimal`; `compare` / `compareBytes`;
  `transcode`; `unescape`; `TypeCode`; `StrupleException`.
- **JSON** (`lib/src/json.dart`): `fromJson` / `toJson`, plus `formatDouble`
  (ECMAScript-style shortest round-trip) and a hand-rolled `parseJson` that
  keeps integer tokens at arbitrary precision (so JSON ints `> 2^64` survive
  losslessly).
- **Navigation** (`lib/src/navigate.dart`): `View` (`count`, `at`, `head`,
  `tail`, `nthRest`, `take`, `headType`, `is*` predicates incl. `isDecimal` /
  `isNumber`, `containerBody`, `containedItems`); `MapView` (`count`, `get`,
  `iterator`, `indexed`); `IndexedMap` (`count`, `at`, `get`, `find`, `iterable`
  — O(log n) binary-search `get`).
- **Semantic** (`lib/src/semantic.dart`): `semanticOrder` / `semanticEqual` —
  exact cross-representation number comparison (int / big-int / float32 /
  float64 / decimal unified into one class via exact `BigInt` rationals).

## Test

```sh
cd dart
./run-tests.sh          # uses $HOME/dart-sdk/bin/dart (override with $DART)
```

`run-tests.sh` runs two plain `main()` runners that read `../conformance/*.json`
(CWD = `dart/`), print a summary, and exit nonzero on any failure:

- `bin/test_conformance.dart` — all corpus vectors in both directions
  (`fromJson`/`toJson`, `build`/`transcode`) plus every semantic pair.
- `bin/test_struple.dart` — navigation / `IndexedMap` mirror of the reference
  tests, plus golden / round-trip checks for decimal, uuid, and wide integers.

Also passes `dart analyze` with no issues.
