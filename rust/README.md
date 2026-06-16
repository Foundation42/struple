# struple (Rust)

A pure-Rust implementation of [struple](../README.md) — streaming,
lexicographically-ordered tuple packing whose encoded bytes are directly
comparable. Byte-identical to the Zig reference (verified against
[`../conformance/vectors.json`](../conformance/vectors.json)).

**Zero dependencies** — including the `json` module (`from_json` / `to_json`)
and even the conformance tests, which read the corpus with a small built-in JSON
parser.

```rust
use struple::{pack, unpack, compare, Value};
use struple::json::{from_json, to_json};

let key = pack(&[Value::Str("users".into()), Value::Int(12345), Value::Bool(true)]);
// key: Vec<u8> — `Vec<u8>`/`[u8]` are already `Ord`, so `a < b` and `slice::sort`
// compare them like the values; `compare(&a, &b)` is there for parity.
let values = unpack(&key).unwrap();

let bytes = from_json(r#"{"id":12345,"name":"alice"}"#).unwrap();
assert_eq!(to_json(&bytes).unwrap(), r#"{"id":12345,"name":"alice"}"#);
```

## Unpacking

Encoded bytes aren't opaque — read the fields back out, no schema required. The
same forms work in every port:

```rust
use struple::{pack, unpack, encode, view, Element, MapView, Reader, Value};

let key = pack(&[
    Value::Str("users".into()), Value::Int(12345),
    Value::Str("alice".into()), Value::Bool(true),
]); // fields: [table, id, name, active]

// 1. Whole-tuple unpack — decode every field at once; pick by position.
let fields = unpack(&key)?;
assert_eq!(fields[1], Value::Int(12345));

// 2. Streaming read loop — advance one element at a time, stop early.
let mut r = Reader::new(&key);
while let Some(el) = r.next()? {
    if let Element::Int(id) = el { assert_eq!(id, 12345); break; }
}

// 3. Type dispatch — match on each element's kind; recurse into containers.
let mut r = Reader::new(&key);
while let Some(el) = r.next()? {
    match el {
        Element::Str(s) => { /* "users" / "alice" */ }
        Element::Int(i) => assert_eq!(i, 12345),
        Element::Bool(b) => assert!(b),
        Element::Array(body) | Element::Map(body) | Element::Set(body) => {
            let mut child = Reader::new(&body); // step into the inner stream
            while let Some(_inner) = child.next()? {}
        }
        _ => {}
    }
}

// 4. Random access — count / head / tail / at(i) without decoding everything.
let v = view(&key);
assert_eq!(v.count()?, 4);
let _head = v.head()?.unwrap();              // first field's raw bytes
let _tail = v.tail()?;                        // everything after the first
let name = v.at(2)?.unwrap();                 // third field, zero-copy slice
assert_eq!(unpack(name)?[0], Value::Str("alice".into()));

// map: {"id": 12345, "name": "alice"}
let map = encode(&Value::Map(vec![
    (Value::Str("id".into()), Value::Int(12345)),
    (Value::Str("name".into()), Value::Str("alice".into())),
]));

// 5. Container descent — step into a nested map/array's inner stream.
let inner = view(&map).contained_items()?.unwrap(); // un-escaped k/v stream

// 6. Map lookup by key — MapView::get (linear) or IndexedMap (O(log n) get/find).
let mv = MapView::new(&inner);
let name_key = encode(&Value::Str("name".into()));
let got = mv.get(&name_key)?.unwrap();
assert_eq!(unpack(got)?[0], Value::Str("alice".into()));     // -> "alice"
let idx = mv.indexed()?;                                      // many lookups? index once
assert_eq!(idx.find(&name_key), Some(1));                    // O(log n) get/find/at
```

## Value mapping

| Rust | struple |
|---|---|
| `Value::Nil` / `Value::Undefined` | nil / undefined |
| `Value::Bool` | bool |
| `Value::Int(i128)` | integer |
| `Value::BigInt { negative, magnitude }` | integer beyond i128 (sign + big-endian bytes) |
| `Value::F32` / `Value::F64` | float32 / float64 |
| `Value::Timestamp(i64)` | timestamp (µs since epoch) |
| `Value::Str` | string |
| `Value::Bytes` | bytes |
| `Value::Array` | array |
| `Value::Map` | map (canonical, key-sorted) |
| `Value::Set` | set (sorted, de-duped) |

Integers up to `i128` are first-class; larger ones use `Value::BigInt` (or the
`Writer::append_big_int(negative, magnitude_be)` low-level call), so no bignum
dependency is needed. `from_json` parses integer tokens as `i128`.

## Test

```
cargo test     # codec unit tests + the conformance corpus
```
