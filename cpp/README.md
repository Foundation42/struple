# struple (C++)

A header-only C++17 implementation of [struple](../README.md) — streaming,
lexicographically-ordered tuple packing whose encoded bytes are directly
comparable. Byte-identical to the Zig reference (verified against
[`../conformance/vectors.json`](../conformance/vectors.json)), clean under
`-Wall -Wextra` + AddressSanitizer/UBSan.

**Header-only, no dependencies** — including the JSON module. Just add
`cpp/include` to your include path. Integers up to 64 bits are first-class;
larger ones use `BigInt` (sign + big-endian magnitude bytes), so no bignum
library is required.

```cpp
#include <struple.hpp>
#include <struple_json.hpp>
using namespace struple;

Bytes key = pack("users", int64_t(12345), true);   // memcmp-orderable
// Bytes is std::vector<uint8_t>, whose operator< already orders like the values;
// struple::compare(a, b) returns -1/0/1 for parity.

Reader r(key);
while (auto e = r.next()) {
    switch (e->kind) {
        case Kind::String: /* e->str */ break;
        case Kind::Int:    /* e->integer */ break;
        default: break;
    }
}

Bytes bytes = from_json(R"({"id":12345,"name":"alice"})");
std::string text = to_json(bytes);   // {"id":12345,"name":"alice"}
```

## Unpacking

Encoded bytes aren't opaque — read the fields back out, no schema required. The
same forms work in every port:

```cpp
Bytes key = pack("users", int64_t(12345), "alice", true);   // [table, id, name, active]

// 1. Whole-tuple unpack — no separate unpack(): a View decodes every field by
//    position; at(i) yields a sub-View you read with a one-element Reader.
View t(key);
Reader(t.at(2)->data(), t.at(2)->size()).next()->str;       // "alice"

// 2. Streaming read loop — advance one element at a time, stop early.
Reader r(key);
while (auto e = r.next()) if (e->kind == Kind::Int && e->integer == 12345) break;

// 3. Type dispatch — switch on each element's kind; recurse into containers.
Reader r2(key);
while (auto e = r2.next()) switch (e->kind) {
    case Kind::String: /* e->str */ break;
    case Kind::Int:    /* e->integer */ break;
    case Kind::Array: case Kind::Map: case Kind::Set: { Reader inner(e->data); /* … */ } break;
    default: break;
}

// 4. Random access — count / head / tail / at(i) without decoding everything.
t.count();          // 4
t.head()->isString();   // "users"
t.tail().count();   // 3   (drop the head)
t.at(3)->isBool();  // active

// 5. Container descent — step into a nested map/array's inner stream.
Writer mw; mw.append_map({{pack("id"), pack(int64_t(12345))}, {pack("name"), pack("alice")}});
Bytes mapbuf = mw.take();
std::optional<Bytes> inner = View(mapbuf).containedItems();  // un-escaped key/value stream

// 6. Map lookup by key — MapView::get (linear) or IndexedMap (O(log n) get/find).
MapView m(*inner);
std::optional<Slice> v = m.get(pack("name"));                // encode the key with pack(…)
Reader(v->data, v->size).next()->str;                        // "alice"
IndexedMap im(*inner);
im.find(pack("name"));  // index in canonical order;  im.get(pack("name")) → value bytes
```

`Reader::next()` returns `std::optional<Element>`; malformed input throws
`struple::Error`. Decoded data is owned by the `Element` (RAII — no lifetime
caveats). Maps and sets are written canonically (sorted; sets de-duplicated) via
`Writer::append_map` / `append_set`.

## Element kinds

| `Kind` | struple type |
|---|---|
| `Nil` / `Undefined` | nil / undefined |
| `Bool` | bool |
| `Int` (`integer`) | integer (fits int64) |
| `BigInt` (`big_negative`, `data`) | integer beyond int64 |
| `F32` / `F64` | float32 / float64 |
| `Timestamp` (`integer` µs) | timestamp |
| `String` (`str`) / `Bytes` (`data`) | string / bytes |
| `Array` / `Map` / `Set` (`data` = child stream) | array / map / set |

## Test

```
make test     # codec unit tests + the conformance corpus
```
