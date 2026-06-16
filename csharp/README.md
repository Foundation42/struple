# struple — C# / .NET

A pure, **zero-dependency** (BCL-only) C# port of [struple](../README.md):
streaming, lexicographically-ordered tuple packing. Byte-identical to the Zig
reference and the other language ports, driven by the shared
[`conformance/`](../conformance) corpus.

Requires the **.NET 10 SDK**. Target framework `net10.0`. No NuGet packages —
only `System.*` (notably `System.Numerics.BigInteger`). A tiny JSON parser +
serializer is hand-rolled so number tokens keep full precision (no
`System.Text.Json`).

## Quick start

```csharp
using Struple;

byte[] key = new Struple.Packer()
    .AppendString("users").AppendInt(12345).AppendBool(true)
    .Bytes();                          // memcmp-orderable bytes
Struple.Compare(keyA, keyB);           // -1 / 0 / 1  ==  value order

byte[] k = Json.FromJson("{\"id\":12345,\"name\":\"alice\"}");
string j = Json.ToJson(k);             // {"id":12345,"name":"alice"}
```

## Unpacking

Encoded bytes aren't opaque — read the fields back out, no schema required. The
same forms work in every port:

```csharp
byte[] key = new Struple.Packer()
    .AppendString("users").AppendInt(12345).AppendString("alice").AppendBool(true)
    .Bytes();                                          // [table, id, name, active]

// 1. Whole-tuple unpack — no batch decoder; drain the Reader, pick by position.
var fields = new List<Struple.Element>();
var rd = new Struple.Reader(key);
Struple.Element? el;
while ((el = rd.Next()) != null) fields.Add(el);
string table = fields[0].StringValue;                  // "users"  (IntValue is BigInteger)

// 2. Streaming read loop — advance one element at a time, stop early.
var r = new Struple.Reader(key);
Struple.Element? e;
while ((e = r.Next()) != null)
    if (e.Kind == Struple.Kind.Int) { var id = e.IntValue; break; }   // 12345

// 3. Type dispatch — switch on each element's Kind; recurse into containers.
void Walk(byte[] buf) {
    var rr = new Struple.Reader(buf);
    for (Struple.Element? x; (x = rr.Next()) != null; )
        switch (x.Kind) {
            case Struple.Kind.String:  Use(x.StringValue); break;
            case Struple.Kind.Int:     Use(x.IntValue); break;         // BigInteger
            case Struple.Kind.Boolean: Use(x.BoolValue); break;
            case Struple.Kind.Array:
            case Struple.Kind.Map:
            case Struple.Kind.Set:     Walk(x.Inner); break;           // descend
        }
}

// 4. Random access — Count / Head / Tail / At(i) without decoding everything.
var v = Navigate.NewView(key);
int n = v.Count();                                     // 4
string name = new Struple.Reader(v.At(2)!).Next()!.StringValue;        // "alice"

// 5. Container descent — step into a nested map/array's inner stream.
byte[] mapKey = Json.FromJson("{\"id\":12345,\"name\":\"alice\"}");
byte[] inner = Navigate.NewView(mapKey).ContainedItems()!;            // map body

// 6. Map lookup by key — MapView.Get (linear) or IndexedMap (O(log n) Get/Find).
var mv = new Navigate.MapView(inner);
byte[] probe = new Struple.Packer().AppendString("name").Bytes();
byte[]? val = mv.Get(probe);                           // or mv.Indexed().Get(probe)
string alice = new Struple.Reader(val!).Next()!.StringValue;          // "alice"
```

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
