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
