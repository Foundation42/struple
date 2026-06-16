# struple — C# / .NET

A pure, **zero-dependency** (BCL-only) C# port of [struple](../README.md):
streaming, lexicographically-ordered tuple packing. Byte-identical to the Zig
reference and the other language ports, driven by the shared
[`conformance/`](../conformance) corpus.

Requires the **.NET 10 SDK**. Target framework `net10.0`. No NuGet packages —
only `System.*` (notably `System.Numerics.BigInteger`). A tiny JSON parser +
serializer is hand-rolled so number tokens keep full precision (no
`System.Text.Json`).

## Build & test

```sh
cd csharp
./run-tests.sh
```

`run-tests.sh` runs `dotnet run -c Release --project test`, which reads
`../conformance/*.json`, prints a summary, and exits nonzero on any failure:

```
Conformance: json encode 35 decode 35 | build 25 transcode 25 | semantic 41 | 0 failures
Behavioral: complete (0 failures so far)
TOTAL: 304 checks | 0 failures
```

The runner does two things:

- **Conformance** — the shared corpus: all 60 vectors in both directions
  (`FromJson`/`ToJson` for the 35 JSON entries, `encode(build(op))` /
  `transcode(bytes)` for the 25 build entries) plus the 41 semantic-order pairs.
  The build-op interpreter mirrors the Zig generator's `buildInto`.
- **Behavioral** — golden + round-trip checks (decimal, uuid, integer) and the
  navigation surface (View / MapView / IndexedMap), mirroring `src/tests.zig`.

## API

Namespace `Struple`. Four files, zero dependencies: `Struple.cs` (codec),
`Json.cs`, `Navigate.cs`, `Semantic.cs`.

### Codec — `Struple`

```csharp
using Struple;

byte[] key = new Struple.Packer()
    .AppendString("users")
    .AppendInt(12345)
    .AppendString("alice")
    .AppendBool(true)
    .Bytes();                       // memcmp-orderable bytes

var r = new Struple.Reader(key);
Struple.Element? e;
while ((e = r.Next()) != null)
{
    switch (e.Kind)
    {
        case Struple.Kind.String:  Use(e.StringValue); break;
        case Struple.Kind.Int:     Use(e.IntValue); break;   // System.Numerics.BigInteger
        case Struple.Kind.Boolean: Use(e.BoolValue); break;
    }
}

Struple.Compare(keyA, keyB);        // -1 / 0 / 1 — that's the comparator
```

`Packer` methods: `AppendNil`, `AppendUndefined`, `AppendBool`, `AppendInt`,
`AppendBigInteger` (`System.Numerics.BigInteger`; i128 fixed slots vs big-int
codes), `AppendBigInt(negative, magnitudeBe)`, `AppendFloat32`, `AppendFloat64`,
`AppendDecimal(decimal)` / `AppendDecimal(negative, digits, exp)` /
`AppendDecimalString`, `AppendTimestamp` (µs since epoch), `AppendUuid`
(`byte[16]` or `System.Guid`), `AppendString`, `AppendBytes`, `AppendArray`,
`AppendMap` (canonical key-sorted), `AppendSet` (canonical sorted + deduped).

Integers/big-ints map to `System.Numerics.BigInteger`. Decimals carry an exact
`(negative, coefficient digits, exponent)` model — the BCL `decimal` is only
28–29 digits, so the coefficient is kept as digits / `BigInteger`, not a native
`decimal`. `AppendDecimal(decimal)` accepts a native `decimal` for convenience.

### JSON — `Json`

```csharp
byte[] key  = Json.FromJson("{\"id\":12345,\"name\":\"alice\"}");
string json = Json.ToJson(key);     // {"id":12345,"name":"alice"}
```

Big integers stay lossless (integer tokens parse to `BigInteger`); non-integer
JSON numbers become float64; objects become canonical (key-sorted) maps. The
`ToJson` text is byte-identical to the corpus (float text matches ECMAScript
`Number.prototype.toString`). `Json.Parse` exposes the generic value model for
tooling.

### Navigation — `Navigate`

```csharp
using Struple;

var v = Navigate.NewView(key);
v.Count(); v.At(2); v.Head(); v.Tail(); v.NthRest(2); v.Take(2);
v.HeadType(); v.IsString(); v.IsMap(); v.IsNumber(); v.IsDecimal();
byte[] inner = v.ContainedItems();          // un-escaped inner stream

var m = new Navigate.MapView(inner);
m.Get(encodedKey);                          // ordered scan, early-exit
var im = m.Indexed();                        // O(log n) Get, O(1) At
```

### Semantic order — `Semantic`

```csharp
Semantic.SemanticOrder(a, b);   // value order: int 5 == float 5.0 (-1/0/1)
Semantic.SemanticEqual(a, b);
```

Exact cross-representation number comparison (int / big-int / float32 / float64 /
decimal unified). The BCL has no `BigDecimal`/`BigRational`, so each finite number
is an exact rational (`BigInteger` numerator/denominator) — a double's exact value
is `mantissa·2^exp`, a struple decimal is `coefficient·10^exp` — and they compare
by cross-multiplication. So `int 2^53+1 > float 2^53`, `decimal 0.1 < float 0.1`,
`decimal 2.5 == float 2.5`, `-0.0 == 0`, NaN greatest. Class order: nil < undef <
bool < number < timestamp < uuid < string < bytes < array < map < set; containers
recurse.

## License

Apache-2.0 — see [../LICENSE](../LICENSE). Copyright 2026 Christian Beaumont.
