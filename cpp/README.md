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
