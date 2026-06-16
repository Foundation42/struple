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

## Unpacking

Encoded bytes aren't opaque — read the fields back out, no schema required. The
same forms work in every port:

```c
/* 1. Whole-tuple read — pull every field out (streaming, since C has no list type) */
struple_reader r; struple_reader_init(&r, buf, len);
struple_element e;
while (struple_reader_next(&r, &e) == 1)        /* 1/0/-1 */
    switch (e.kind) { case STRUPLE_STRING: use(e.data, e.data_len); break;
                      case STRUPLE_INT: use_int(e.int_val); break; default: ; }

/* 2. Streaming read loop — advance one element at a time, stop early */
struple_reader_init(&r, buf, len);
while (struple_reader_next(&r, &e) == 1)
    if (e.kind == STRUPLE_INT) break;           /* found it — stop walking */

/* 3. Type dispatch — switch on each element's type code; recurse into containers */
if (e.kind == STRUPLE_MAP || e.kind == STRUPLE_ARRAY || e.kind == STRUPLE_SET) {
    struple_view child = { e.data, e.data_len }; /* e.data = inner stream */
    walk(child);                                 /* recurse into the container */
}

/* 4. Random access — count / head / tail / at(i) without decoding everything */
struple_view v = { buf, len }, head, third, rest = struple_view_tail(v);
long n = struple_view_count(v);                  /* 4 */
struple_view_head(v, &head);                     /* = at(0) */
struple_view_at(v, 2, &third);                   /* the i-th field, zero-copy */

/* 5. Container descent — step into a nested map/array's inner stream */
struple_writer inner; struple_writer_init(&inner);
struple_view_contained_items(v, &inner);         /* un-escaped child bytes */
struple_view iv = { inner.data, inner.len };

/* 6. Map lookup by key — linear get, or the O(log n) indexed variant */
struple_map m = { inner.data, inner.len };       /* inner = map body from (5) */
struple_writer key; struple_writer_init(&key);
struple_append_string(&key, "name", 4);          /* keys are encoded too */
struple_view got;
struple_map_get(m, key.data, key.len, &got);     /* 1 found → got = "alice" */
struple_indexed_map im;                          /* many lookups? build an index */
struple_indexed_map_init(&im, inner.data, inner.len);
struple_indexed_map_get(&im, key.data, key.len, &got); /* O(log n) binary search */
```

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
