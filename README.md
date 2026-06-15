# struple

**Streaming, lexicographically-ordered tuple packing for Zig.**

A `struple` is a sequence of typed values packed into a byte buffer such that the
**raw bytes are directly `memcmp`-comparable**:

```
std.mem.order(u8, pack(a), pack(b))  ==  the semantic order of a and b
```

Pack a tuple, use the bytes as a key in any byte-ordered store (RocksDB, LMDB,
sled, a sorted array) and it sorts correctly with **no custom comparator**. The
encoding is also **self-delimiting** — you can stream values back out without
storing any external lengths. This is the FoundationDB tuple idea, rebuilt clean
in Zig.

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

// stream it back
var r = struple.reader(key);
while (try r.next()) |elem| switch (elem) {
    .string => |s| { ... },
    .int    => |v| { ... },     // i128
    .boolean=> |b| { ... },
    else => {},
};

// ordering is just memcmp
std.mem.order(u8, key_a, key_b);   // .lt / .eq / .gt
```

`Packer.append` dispatches on the Zig type at comptime; or call the explicit
methods (`appendInt`, `appendUint`, `appendF32`, `appendF64`, `appendString`,
`appendBytes`, `appendBool`, `appendNil`, `appendTuple`).

Build:

```
zig build test     # run the suite
zig build run      # run the demo
```

## v1 types

`nil`, `bool`, integers (full `i64` / `u64` range), `f32`, `f64`, `string`
(UTF-8), `bytes`, and nested `tuple`. The encoding reserves type-code space for
the rest of the "tower" (UUID, decimals, `i128`, maps, vectors, sets, …).

## Wire format

Every element is `[type code][payload]`. Type codes are assigned so the type
byte alone gives the cross-type order:

```
nil < false < true < negative ints < zero < positive ints
    < float32 < float64 < string < bytes < tuple
```

| type        | code        | payload |
|-------------|-------------|---------|
| terminator  | `0x00`      | (framing sentinel, never an element) |
| nil         | `0x01`      | — |
| false/true  | `0x02`/`0x03` | — |
| negative int| `0x10–0x1F` | big-endian excess form, width in the code |
| zero        | `0x20`      | — |
| positive int| `0x21–0x30` | big-endian magnitude, width in the code |
| float32     | `0x31`      | 4 bytes, order-transformed |
| float64     | `0x32`      | 8 bytes, order-transformed |
| string      | `0x40`      | bytes, `0x00`-terminated, `0x00→0x00 0xFF` |
| bytes       | `0x41`      | bytes, `0x00`-terminated, `0x00→0x00 0xFF` |
| tuple       | `0x60`      | child encoding, `0x00`-terminated, escaped |

(v1 emits integer widths 1–8; the outer slots `0x10–0x17` / `0x29–0x30` are
reserved for a future `i128`. `0x33–0x3F`, `0x42–0x5F`, `0x61+` are reserved.)

**Integers.** Width is carried by the type code, so cross-width order is free
(more magnitude → more bytes → a larger/smaller code). Payloads are big-endian.
Negatives are stored in *excess* form (`value + 2^(8·width)`), which is the
byte-complement of the magnitude — that is what makes `-256 < -100 < -1` sort
correctly within a width band.

**Floats.** The IEEE-754 total-ordering transform: flip the sign bit for
positives, flip all bits for negatives, store big-endian. `-0.0` is squashed to
`+0.0`; `NaN` is canonicalized and sorts above `+inf`.

**Variable-length (string / bytes / tuple).** Terminated by `0x00`, with any
real `0x00` escaped as `0x00 0xFF`. Because `0x00` is below every content byte, a
shorter value sorts before a longer one that extends it (`"app" < "apple"`). For
strings/bytes/tuples the decoded slice points into the source buffer and is the
*framed* payload; when it contains no `0x00` it is already the literal content
(the common case), otherwise use `unescapeAlloc` / `unescapeInto`.

## A note on numbers across representations

Because type codes dominate `memcmp`, an integer and a float never interleave by
magnitude — `int 1000000` sorts below `float 0.5`. Comparing numbers across
representations (e.g. `int 5` vs `double 5.0`) is the job of a **semantic
comparator**, which is intentionally out of scope for v1 and planned as a
follow-on.
