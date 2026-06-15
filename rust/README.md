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
