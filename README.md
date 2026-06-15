# struple

[![CI](https://github.com/Foundation42/struple/actions/workflows/ci.yml/badge.svg)](https://github.com/Foundation42/struple/actions/workflows/ci.yml)

**Streaming, lexicographically-ordered tuple packing.** One wire format, six
byte-identical implementations.

A `struple` is a sequence of typed values packed into a byte buffer such that the
**raw bytes are directly `memcmp`-comparable**:

```
std.mem.order(u8, pack(a), pack(b))  ==  the semantic order of a and b
```

Pack a tuple, use the bytes as a key in any byte-ordered store (RocksDB, LMDB,
sled, a sorted array) and it sorts correctly with **no custom comparator**.

The encoding is **streamable** (a sequence of self-delimiting elements — decode
fields one at a time as the bytes arrive, no length prefix, the opposite of a
random-access format you must load whole) and **canonical** (one value → one byte
sequence, byte-identical across all six languages). Ordered + canonical also makes
it a natural fit for **CRDTs** and content-addressed systems. This is the
FoundationDB tuple idea, rebuilt clean.

The type system covers the **union of the Python and JavaScript data models**, so
it can serve as the wire format for cross-language data exchange.

## Quick start

```zig
const struple = @import("struple");

var p = struple.Packer.init(allocator);
defer p.deinit();
try p.append("users");          // string
try p.append(@as(i64, 12345));  // integer
try p.append("alice");
try p.append(true);

const key = p.bytes();          // []const u8 — memcmp-orderable

var r = struple.reader(key);    // zero-alloc streaming decode
while (try r.next()) |elem| switch (elem) {
    .string => |s| { ... },
    .int    => |v| { ... },     // i128
    .boolean=> |b| { ... },
    else => {},
};

std.mem.order(u8, key_a, key_b);   // .lt / .eq / .gt — that's the comparator
```

`Packer.append` dispatches on the Zig type at comptime; or call the explicit
methods: `appendNil`, `appendUndefined`, `appendBool`, `appendInt`/`appendUint`/
`appendI128`/`appendBigInt`, `appendF32`/`appendF64`, `appendTimestamp`,
`appendString`, `appendBytes`, `appendArray`, `appendMap`, `appendSet`.

Build: `zig build test` · `zig build run` · `zig build vectors`.

## JSON

`fromJson` / `toJson` convert between JSON text and struple encodings. JSON
integers are kept at **arbitrary precision** (a big integer that a JS `f64` would
corrupt round-trips losslessly); objects encode to canonical (key-sorted) maps.

```zig
const key = try struple.fromJson(allocator, "{\"id\":12345,\"name\":\"alice\"}");
defer allocator.free(key);                       // memcmp-orderable bytes
const json = try struple.toJson(allocator, key); // {"id":12345,"name":"alice"}
defer allocator.free(json);
```

## Navigation

A packed buffer is a stream of elements; `View` slices and inspects it without
decoding values — zero-copy, and every result is itself a valid struple buffer,
so it composes and recurses.

```zig
const v = struple.view(key);
try v.count();                     // number of elements
(try v.at(2)).?;                   // 3rd element, a zero-copy sub-view
(try v.head()).?;  try v.tail();   // first element / everything after it
try v.nthRest(2);  try v.take(2);  // drop / keep a prefix
v.headType();  v.isString();  v.isMap();  v.isContainer();  // predicates

// descend into an array/map/set
const inner = (try v.containedItems(allocator)).?;  // un-escaped inner stream
defer allocator.free(inner);
```

Maps are canonical (key-sorted), so lookups are an ordered scan with early exit:

```zig
const m = struple.MapView.init(inner);
(try m.get(encoded_key)).?;   // value bytes for an encoded key element
var it = m.iterator();        // (key, value) views, in sorted order
```

The streaming `Reader` also gains a cursor surface: `peekType`, `nextView` (the
next element's raw bytes), `skip`, and `rest`.

*(Available in all six implementations, with idiomatic names per language —
`is_string`/`isString`, `nth_rest`/`nthRest`, etc.)*

## Conformance corpus

`conformance/vectors.json` (regenerate with `zig build vectors`) is the
language-neutral contract that every implementation must reproduce in both
directions. JSON entries (`{json, bytes}`) cover the JSON-expressible types;
build entries (`{build, bytes}`) cover the rest (undefined, float32, timestamp,
uuid, bytes, set, non-string map keys, compositions) via a small op language. See
[conformance/README.md](conformance/README.md).

## Implementations

- **Zig** (this directory) — the reference implementation + corpus generator.
- **TypeScript** ([`js/`](js/README.md)) — pure, zero-dependency port.
- **Python** ([`py/`](py/README.md)) — pure stdlib port.
- **Rust** ([`rust/`](rust/README.md)) — pure, zero-dependency crate.
- **C** ([`c/`](c/README.md)) — pure C11, zero-dependency.
- **C++** ([`cpp/`](cpp/README.md)) — header-only C++17, zero-dependency.

All six are driven by the same `vectors.json` and are verified byte-identical,
so they agree on every byte in both directions.

## Type coverage (Python + JavaScript)

| concept | Python | JavaScript | struple |
|---|---|---|---|
| null | `None` | `null` | nil |
| absent | — | `undefined` | undefined |
| boolean | `bool` | `boolean` | bool |
| integer (**unbounded**) | `int` | `BigInt` / integral `number` | int (fixed + arbitrary-precision) |
| float | `float` | `number` | float32 / float64 |
| decimal | `Decimal` | — | *(type code reserved; not yet implemented)* |
| text | `str` | `string` | string (UTF-8) |
| binary | `bytes` | `Uint8Array` | bytes |
| sequence | `list`/`tuple` | `Array` | array |
| mapping | `dict` | `Object`/`Map` | map |
| set | `set`/`frozenset` | `Set` | set |
| datetime | `datetime` | `Date` | timestamp |
| uuid | `uuid.UUID` | *(explicit)* | uuid (16 bytes) |

## Wire format

Every element is `[type code][payload]`. Type codes are assigned so the type byte
alone gives the cross-type order:

```
nil < undefined < false < true
    < negative ints < zero < positive ints
    < float32 < float64 < decimal < timestamp < uuid
    < string < bytes < array < map < set
```

| type | code | payload |
|---|---|---|
| terminator | `0x00` | framing sentinel, never an element |
| nil | `0x01` | — |
| undefined | `0x02` | — |
| false / true | `0x05` / `0x06` | — |
| int −big | `0x0F` | `[~m][~n][~magnitude]` (beyond i128) |
| int −fixed | `0x10–0x1F` | big-endian excess form, 1–16 byte width in the code |
| zero | `0x20` | — |
| int +fixed | `0x21–0x30` | big-endian magnitude, 1–16 byte width in the code |
| int +big | `0x31` | `[m][n][magnitude]` (beyond i128) |
| float32 / float64 | `0x34` / `0x35` | 4 / 8 bytes, order-transformed |
| decimal | `0x38` | *reserved* |
| timestamp | `0x40` | 8 bytes: order-preserving signed µs since Unix epoch |
| uuid | `0x44` | 16 raw bytes (no framing) |
| string / bytes | `0x48` / `0x49` | content, `0x00`-terminated, `0x00→0x00 0xFF` |
| array | `0x50` | child element stream, terminated + escaped |
| map | `0x52` | canonical (key-sorted) `[k][v]…`, terminated + escaped |
| set | `0x54` | canonical (sorted, de-duped) elements, terminated + escaped |

(`0x32–0x33`, `0x36–0x3F` (less `0x38`), `0x41–0x47` (less `0x44`), `0x4A–0x4F`,
and `0x53/0x55+` are reserved for the tower: decimal, float128, date/time-only,
intervals, …)

**Integers.** Width is carried by the type code, so cross-width order is free.
The fixed slots span 1–16 byte magnitudes — the whole **i128** range. Payloads
are big-endian, with negatives in *excess* form (`value + 2^(8·width)`) so
`-256 < -100 < -1`. Magnitudes beyond i128 use the bracketing big-int codes:
payload `[m][n][magnitude]` where `n` is the magnitude byte-count and `m` the
byte-count of `n` — order-preserving, self-delimiting, and effectively unbounded.
Negatives complement every byte so bigger magnitudes sort earlier. (`0x30 < 0x31`
and `0x0F < 0x10`, so the fixed/big-int boundary stays correctly ordered.)

**Floats.** IEEE-754 total-ordering transform: flip the sign bit for positives,
flip all bits for negatives, big-endian. `-0.0` squashes to `+0.0`; `NaN`
canonicalizes and sorts above `+inf`.

**Timestamp.** Signed µs since the Unix epoch (UTC), sign-bit-flipped to 8
order-preserving bytes — covers the full `datetime` year range at microsecond
resolution.

**UUID.** The 16 raw bytes, fixed-width (no framing or escaping). `memcmp` orders
them lexicographically, which also makes UUIDv7 (time-prefixed) sort in time
order. Python maps it to/from `uuid.UUID` natively; elsewhere it's an explicit
`appendUuid`. JSON has no UUID type, so `toJson` renders the canonical hyphenated
string (one-way — strings stay strings on the way back).

**Variable-length (string / bytes / array / map / set).** Terminated by `0x00`,
with any real `0x00` escaped as `0x00 0xFF`. Because `0x00` is below every content
byte, a shorter value sorts before a longer one that extends it (`"app" <
"apple"`). Decoded slices point into the source buffer and are *framed* (escapes
intact); when they contain no `0x00` they are already the literal content. Use
`unescapeAlloc`/`unescapeInto`, then a child `Reader` for containers.

**Maps and sets are canonical.** Entries/elements are sorted by their encoded
bytes (sets are also de-duplicated), so equal maps/sets encode identically and
compare correctly — at the cost of not preserving insertion order. If you need
exact key order (e.g. byte-faithful JSON object round-trips), represent it as an
**array of `[key, value]` pairs** instead.

## Numbers across representations — the semantic comparator

Because type codes dominate `memcmp`, the raw byte order keeps an integer and a
float from interleaving by magnitude — `int 1000000` sorts below `float 0.5`.
When you want the **value** order instead, use `semanticOrder`:

```zig
struple.order(a, b);                  // raw byte order: int 5 < float 5.0
try struple.semanticOrder(alloc, a, b); // value order:    int 5 == float 5.0
```

`semanticOrder` compares two encoded streams by mathematical value: `int`,
big-integers, `float32` and `float64` all compare by their **exact** value, with
no precision loss even where a `double` can't represent the integer (`int 2^53+1
> float 2^53`, `big-int 2^200 == float 2^200`). `NaN` sorts as the greatest
number; `-0.0 == 0.0 == int 0`. Non-numbers keep the wire family order (`nil <
bool < number < timestamp < uuid < string < bytes < array < map < set`, with all
numbers unified into one class); containers recurse element-wise.

Available in all six languages (`semanticOrder` / `semantic_order` /
`struple_semantic_order`) and pinned by `conformance/semantic_vectors.json` — a
language-neutral set of `{a, b, order}` pairs every implementation must agree on.

## License

Apache-2.0 — see [LICENSE](LICENSE). Copyright 2026 Christian Beaumont.
