# struple (Python)

A pure-Python implementation of [struple](../README.md) — streaming,
lexicographically-ordered tuple packing whose encoded bytes are directly
comparable. Byte-identical to the Zig reference (verified against
[`../conformance/vectors.json`](../conformance/vectors.json)).

Pure stdlib, no dependencies. Python ≥ 3.9.

```python
from struple import pack, unpack, compare, from_json, to_json

key = pack("users", 12345, "alice", True)   # bytes, lexicographically orderable
sorted([key_a, key_b])                        # plain bytes order == value order
unpack(key)                                   # ["users", 12345, "alice", True]

# JSON in / JSON out — big integers stay lossless
data = from_json('{"id":12345,"name":"alice"}')
to_json(data)  # {"id":12345,"name":"alice"}
```

Encoded keys are ordinary `bytes`, so `a < b`, `sorted(...)`, and any byte-ordered
store compare them correctly with no custom comparator. `compare(a, b)` returns
`-1/0/1` for parity with the other languages.

## Unpacking

Encoded bytes aren't opaque — read the fields back out, no schema required. The
same forms work in every port:

```python
from struple import pack, unpack, encode, Reader, view, MapView, IndexedMap

key = pack("users", 12345, "alice", True)            # [table, id, name, active]

# 1. Whole-tuple unpack — decode every field at once; pick by position
table, id, name, active = unpack(key)                # "users", 12345, "alice", True

# 2. Streaming read loop — advance one element at a time, stop early
r = Reader(key)
while (e := r.next()) is not None:                    # e is (kind, value)
    kind, value = e
    if kind == "string" and value == "alice":
        break

# 3. Type dispatch — branch on each element's kind; recurse into containers
def walk(buf):
    r = Reader(buf)
    while (e := r.next()) is not None:
        kind, value = e
        walk(value) if kind in ("array", "map", "set") else print(kind, value)

# 4. Random access — count / head / tail / at(i) without decoding everything
v = view(key)
v.count()                                            # 4
unpack(v.head()), unpack(v.at(2))                    # ["users"], ["alice"]

# 5. Container descent — step into a nested map/array's inner stream
m = pack({"id": 12345, "name": "alice"})
inner = view(m).contained_items()                    # the map's inner element stream

# 6. Map lookup by key — MapView.get (linear) or IndexedMap (O(log n) get/find)
unpack(MapView(inner).get(encode("name")))           # ["alice"]
idx = IndexedMap(inner)                              # one O(n) pass, then O(log n)
unpack(idx.get(encode("name"))), idx.find(encode("name"))   # ["alice"], 1
```

## Value mapping

| Python | struple |
|---|---|
| `None` | nil |
| `bool` | bool |
| `int` | integer (arbitrary precision) |
| `float` | float64 |
| `str` | string |
| `bytes` / `bytearray` | bytes |
| `list` / `tuple` | array |
| `dict` | map (canonical, key-sorted) |
| `set` / `frozenset` | set (sorted, de-duped) |
| `datetime` | timestamp |

`from_json` relies on `json.loads`, which already yields arbitrary-precision
`int` for integer tokens and `float` for fractional ones — so big integers stay
lossless with no special handling.

## Test

```
python3 -m unittest discover -s tests -t .   # includes the conformance corpus
```
