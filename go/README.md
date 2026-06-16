# struple (Go)

A pure-Go implementation of [struple](../README.md) — streaming,
lexicographically-ordered tuple packing whose encoded bytes are directly
`bytes.Compare`-comparable. Byte-identical to the Zig reference (verified against
[`../conformance/vectors.json`](../conformance/vectors.json) and
[`../conformance/semantic_vectors.json`](../conformance/semantic_vectors.json)).

**Zero dependencies** — stdlib only (`math/big` for arbitrary-precision integers
and exact decimal/float comparison; a hand-rolled JSON codec, so even the
conformance tests read the corpus without `encoding/json`).

```go
import "github.com/Foundation42/struple/go"

w := struple.NewWriter()
w.AppendString("users")
w.AppendInt(12345)
w.AppendString("alice")
w.AppendBool(true)
key := w.Bytes() // []byte — bytes.Compare(a, b) sorts like the values

r := struple.NewReader(key)
for {
    e, ok, err := r.Next()
    if err != nil || !ok {
        break
    }
    _ = e // e.Kind, e.Int, e.Bool, e.Body, ...
}

bytes, _ := struple.FromJson(`{"id":12345,"name":"alice"}`)
js, _ := struple.ToJson(bytes) // {"id":12345,"name":"alice"}
```

## Unpacking

Encoded bytes aren't opaque — read the fields back out, no schema required. The
same forms work in every port:

```go
key := w.Bytes() // from the quick-start: [table, id, name, active]

// 1. Whole-tuple unpack — decode every field at once; pick by position.
var fields []struple.Element
for r := struple.NewReader(key); ; {
	e, ok, err := r.Next()
	if err != nil || !ok {
		break
	}
	fields = append(fields, e)
}
table := string(struple.Unescape(fields[0].Body)) // "users"

// 2. Streaming read loop — advance one element at a time, stop early.
for r := struple.NewReader(key); ; {
	e, ok, _ := r.Next()
	if !ok {
		break
	}
	if e.Kind == struple.KindInt { // .Int = 12345, then stop
		break
	}
}

// 3. Type dispatch — switch on each element's kind; recurse into containers.
switch e := fields[2]; e.Kind {
case struple.KindString:
	_ = string(struple.Unescape(e.Body)) // "alice"
case struple.KindArray, struple.KindMap:
	// inner, _, _ := struple.NewView(view).ContainedItems(); recurse
}

// 4. Random access — Count / Head / Tail / At(i) without decoding everything.
v := struple.NewView(key)
n, _ := v.Count()          // 4
nameBytes, _, _ := v.At(2) // encoded "alice", zero-copy sub-view

// 5. Container descent — step into a nested map/array's inner stream.
m, _ := struple.FromJson(`{"id":12345,"name":"alice"}`)
inner, _, _ := struple.NewView(m).ContainedItems()

// 6. Map lookup by key — MapView.Get (linear) or IndexedMap (O(log n) Get/Find).
nameKey := struple.NewWriter()
nameKey.AppendString("name")
val, ok, _ := struple.NewMapView(inner).Get(nameKey.Bytes()) // ok; val => "alice"
im, _ := struple.NewIndexedMap(inner)
val2, found := im.Get(nameKey.Bytes()) // O(log n) binary search; same value
```

## Type mapping

| struple type | Go (Writer method → decoded `Element`) |
|---|---|
| nil / undefined | `AppendNil` / `AppendUndefined` → `KindNil` / `KindUndefined` |
| bool | `AppendBool` → `KindBool` (`.Bool`) |
| integer (i128 range) | `AppendInt` / `AppendUint` → `KindInt` (`.Int *big.Int`) |
| integer (arbitrary) | `AppendBigIntValue` / `AppendBigInt(neg, magBE)` → `KindBigInt` (`.Int`) |
| float32 / float64 | `AppendF32` / `AppendF64` → `KindFloat32` / `KindFloat64` |
| decimal | `AppendDecimal` / `AppendDecimalString` → `KindDecimal` (`.Decimal`) |
| timestamp | `AppendTimestamp(int64 µs)` → `KindTimestamp` (`.Timestamp`) |
| uuid | `AppendUUID([16]byte)` → `KindUUID` (`.UUID`) |
| string / bytes | `AppendString` / `AppendBytes` → `KindString` / `KindBytes` (`.Body`, framed) |
| array | `AppendArray(child)` → `KindArray` (`.Body`) |
| map | `AppendMap([][2][]byte)` → `KindMap` (canonical, key-sorted) |
| set | `AppendSet([][]byte)` → `KindSet` (sorted, de-duped) |

Integers are arbitrary-precision via `math/big.Int`; values within the i128
range use the fixed-width type codes, larger ones the big-int codes, with no
external bignum dependency. `FromJson` keeps integer tokens lossless (parsing to
`int64`, falling back to a big-integer when they overflow) and non-integer
numbers become float64.

## API surface

- **Codec:** `Writer` (`NewWriter`, the `Append*` methods, `Bytes`, `Reset`),
  `Reader` (`NewReader`, `Next`, `NextView`, `Skip`, `PeekType`, `Rest`, `Done`),
  `Element` / `Kind` / `Decimal`, `Compare`, `Transcode`, `Unescape`.
- **JSON:** `FromJson`, `ToJson`.
- **Navigation:** `View` (`Count`, `At`, `Head`, `Tail`, `NthRest`, `Take`,
  `HeadType`, the `Is*` predicates, `ContainerBody`, `ContainedItems`),
  `MapView` (`Count`, `Get`, `Iterator`, `Indexed`), `IndexedMap` (`NewIndexedMap`,
  `Count`, `At`, `Get`, `Find`, `Iterator`).
- **Semantic:** `SemanticOrder`, `SemanticEqual` — value-based ordering that
  unifies int / big-int / float32 / float64 / decimal into one number class,
  compared exactly via `math/big.Rat`.

## Test

```
go test ./...   # codec/navigation unit tests + the full conformance corpus
gofmt -l .      # lists nothing
```
