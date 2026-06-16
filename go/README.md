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
