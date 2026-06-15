//! struple — streaming, lexicographically-ordered tuple packing.
//!
//! Encoded bytes are directly comparable: `compare(&encode(a), &encode(b))` (and
//! plain slice ordering / `sort`) matches the semantic order of the values. Drop
//! a packed key into any byte-ordered store and it sorts correctly with no custom
//! comparator. Byte-identical to the Zig reference, verified against
//! `conformance/vectors.json`.
//!
//! ```
//! use struple::{pack, unpack, compare, Value};
//!
//! let key = pack(&[Value::Str("users".into()), Value::Int(12345), Value::Bool(true)]);
//! assert_eq!(unpack(&key).unwrap()[1], Value::Int(12345));
//! ```
//!
//! Zero dependencies, including the `json` module (`from_json` / `to_json`).

mod codec;
pub mod json;

pub use codec::{
    compare, encode, pack, transcode, unpack, view, Element, EntryIter, Error, MapView, Reader,
    Value, View, Writer,
};
