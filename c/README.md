# struple (C)

A pure-C11 implementation of [struple](../README.md) — streaming,
lexicographically-ordered tuple packing whose encoded bytes are directly
`memcmp`-comparable. Byte-identical to the Zig reference (verified against
[`../conformance/vectors.json`](../conformance/vectors.json)), and clean under
`-Wall -Wextra` + AddressSanitizer/UBSan.

**No dependencies** — including a small built-in JSON parser, so
`struple_from_json` / `struple_to_json` need no external library. Integers up to
64 bits are first-class; larger ones use the `(sign, big-endian magnitude bytes)`
API, so no bignum library is required.

```c
#include "struple.h"

struple_writer w;
struple_writer_init(&w);
struple_append_string(&w, "users", 5);
struple_append_int(&w, 12345);
struple_append_bool(&w, true);
/* w.data / w.len — memcmp-orderable */

struple_reader r;
struple_reader_init(&r, w.data, w.len);
struple_element e;
while (struple_reader_next(&r, &e) == 1) {
    switch (e.kind) {
        case STRUPLE_STRING: /* e.data, e.data_len */ break;
        case STRUPLE_INT:    /* e.int_val */ break;
        default: break;
    }
}
struple_reader_free(&r);
struple_writer_free(&w);
```

Keys are ordinary byte buffers, so `memcmp` (or `struple_compare`) orders them
like the values — no custom comparator.

## Element kinds

| `struple_kind` | struple type |
|---|---|
| `STRUPLE_NIL` / `STRUPLE_UNDEF` | nil / undefined |
| `STRUPLE_BOOL` | bool |
| `STRUPLE_INT` (`int_val`) | integer (fits int64) |
| `STRUPLE_BIGINT` (`big_negative`, `data`/`data_len`) | integer beyond int64 |
| `STRUPLE_F32` / `STRUPLE_F64` | float32 / float64 |
| `STRUPLE_TIMESTAMP` (`int_val` µs) | timestamp |
| `STRUPLE_STRING` / `STRUPLE_BYTES` | string / bytes |
| `STRUPLE_ARRAY` / `STRUPLE_MAP` / `STRUPLE_SET` | array / map / set (`data` = child stream) |

For `STRING`/`BYTES`/`ARRAY`/`MAP`/`SET`/`BIGINT`, `e.data` points into a
reader-owned buffer valid until the next `struple_reader_next` call — copy it if
you need it longer. Maps and sets are written canonically (sorted; sets
de-duplicated) via `struple_append_map` / `struple_append_set`.

## Test

```
make test     # codec unit tests + the conformance corpus
```
