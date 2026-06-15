/* struple — streaming, lexicographically-ordered tuple packing (C).
 *
 * Encoded bytes are directly memcmp-comparable: struple_compare(encode(a), ...)
 * matches the semantic order of the values. A faithful port of the Zig
 * reference; the conformance corpus (conformance/vectors.json) pins byte
 * identity across languages.
 *
 * No dependencies (C11). Integers up to 64 bits are first-class; larger ones go
 * through the (sign, big-endian magnitude bytes) API, so no bignum library is
 * required. */
#ifndef STRUPLE_H
#define STRUPLE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Writer: builds an encoded buffer ---- */

typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
} struple_writer;

void struple_writer_init(struple_writer *w);
void struple_writer_free(struple_writer *w);
void struple_writer_reset(struple_writer *w);
static inline const uint8_t *struple_writer_data(const struple_writer *w) { return w->data; }
static inline size_t struple_writer_len(const struple_writer *w) { return w->len; }

/* Append raw bytes (e.g. when a writer is used to hold JSON text). */
void struple_writer_append(struple_writer *w, const uint8_t *data, size_t len);

void struple_append_nil(struple_writer *w);
void struple_append_undefined(struple_writer *w);
void struple_append_bool(struple_writer *w, bool v);
void struple_append_int(struple_writer *w, int64_t v);
void struple_append_uint(struple_writer *w, uint64_t v);
/* `magnitude` is big-endian; leading zeros are trimmed. */
void struple_append_big_int(struple_writer *w, bool negative, const uint8_t *magnitude, size_t mag_len);
void struple_append_f32(struple_writer *w, float v);
void struple_append_f64(struple_writer *w, double v);
void struple_append_timestamp(struple_writer *w, int64_t micros);
/* `uuid16` points to 16 raw bytes (network/big-endian order). */
void struple_append_uuid(struple_writer *w, const uint8_t *uuid16);
void struple_append_string(struple_writer *w, const char *s, size_t len);
void struple_append_bytes(struple_writer *w, const uint8_t *b, size_t len);
/* `child` is the encoded element stream of a nested tuple. */
void struple_append_array(struple_writer *w, const uint8_t *child, size_t child_len);

typedef struct {
    const uint8_t *ptr;
    size_t len;
} struple_bytes;

typedef struct {
    struple_bytes key;
    struple_bytes value;
} struple_kv;

/* Pre-encoded entries/elements; sorted (and de-duplicated, for sets) into
 * canonical order. The arrays are reordered in place. */
void struple_append_map(struple_writer *w, struple_kv *entries, size_t count);
void struple_append_set(struple_writer *w, struple_bytes *elements, size_t count);

/* ---- Reader: streams elements back out ---- */

typedef enum {
    STRUPLE_NIL,
    STRUPLE_UNDEF,
    STRUPLE_BOOL,
    STRUPLE_INT,        /* fits int64_t */
    STRUPLE_BIGINT,     /* sign + big-endian magnitude in `data` */
    STRUPLE_F32,
    STRUPLE_F64,
    STRUPLE_TIMESTAMP,  /* int_val = microseconds since the Unix epoch */
    STRUPLE_UUID,       /* `data` = 16 raw bytes */
    STRUPLE_STRING,     /* `data` = UTF-8 (NUL-terminated past data_len) */
    STRUPLE_BYTES,
    STRUPLE_ARRAY,      /* `data` = un-escaped child stream */
    STRUPLE_MAP,
    STRUPLE_SET
} struple_kind;

typedef struct {
    struple_kind kind;
    bool bool_val;
    bool big_negative;
    int64_t int_val;
    float f32_val;
    double f64_val;
    const uint8_t *data; /* STRING/BYTES/ARRAY/MAP/SET/BIGINT — valid until the next next() call */
    size_t data_len;
} struple_element;

typedef struct {
    const uint8_t *buf;
    size_t len;
    size_t pos;
    uint8_t *scratch;
    size_t scratch_cap;
} struple_reader;

void struple_reader_init(struple_reader *r, const uint8_t *buf, size_t len);
void struple_reader_free(struple_reader *r);
/* Returns 1 and fills *out for the next element, 0 at end of stream, -1 on error. */
int struple_reader_next(struple_reader *r, struple_element *out);

/* Cursor extensions (the TupleStreamReader surface). */
int struple_reader_peek_type(const struple_reader *r); /* type byte, or -1 at end */
const uint8_t *struple_reader_rest(const struple_reader *r, size_t *out_len);
/* The next element's raw bytes (a view into the buffer); 1/0/-1 like next(). */
int struple_reader_next_view(struple_reader *r, const uint8_t **out_ptr, size_t *out_len);
int struple_reader_skip(struple_reader *r); /* 1 advanced, 0 at end, -1 error */

/* ---- Navigation: a zero-copy view over a buffer (a stream of elements) ---- */

typedef struct {
    const uint8_t *bytes;
    size_t len;
} struple_view;

long struple_view_count(struple_view v); /* element count, or -1 on error */
int struple_view_at(struple_view v, size_t index, struple_view *out);  /* 1 found, 0 out of range, -1 error */
int struple_view_head(struple_view v, struple_view *out);              /* = at(0) */
struple_view struple_view_tail(struple_view v);                        /* everything after the first element */
struple_view struple_view_nth_rest(struple_view v, size_t n);          /* drop n elements */
struple_view struple_view_take(struple_view v, size_t n);              /* first n elements */
int struple_view_head_type(struple_view v);                            /* type byte, or -1 if empty */

bool struple_view_is_nil(struple_view v);
bool struple_view_is_undefined(struple_view v);
bool struple_view_is_bool(struple_view v);
bool struple_view_is_int(struple_view v);
bool struple_view_is_float(struple_view v);
bool struple_view_is_number(struple_view v);
bool struple_view_is_timestamp(struple_view v);
bool struple_view_is_uuid(struple_view v);
bool struple_view_is_string(struple_view v);
bool struple_view_is_bytes(struple_view v);
bool struple_view_is_array(struple_view v);
bool struple_view_is_map(struple_view v);
bool struple_view_is_set(struple_view v);
bool struple_view_is_container(struple_view v);

/* Append the container's inner element stream (un-escaped) to `out`.
 * 1 if the head is a container, 0 if not, -1 on error. */
int struple_view_contained_items(struple_view v, struple_writer *out);

/* ---- Map navigation (over a map's inner stream, from contained_items) ---- */

typedef struct {
    const uint8_t *inner;
    size_t len;
} struple_map;

long struple_map_count(struple_map m);
/* Look up an encoded key; 1 found (fills *out), 0 not found, -1 error. */
int struple_map_get(struple_map m, const uint8_t *key, size_t keylen, struple_view *out);

typedef struct {
    struple_reader r;
} struple_map_iter;

struple_map_iter struple_map_iterator(struple_map m);
int struple_map_next(struple_map_iter *it, struple_view *key, struple_view *value); /* 1/0/-1 */

/* ---- ordering / round-trip ---- */

/* Lexicographic byte comparison: -1, 0, or 1. */
int struple_compare(const uint8_t *a, size_t alen, const uint8_t *b, size_t blen);

/* Semantic (value-based) comparison: numbers compare by exact mathematical
 * value, so int 5 == float 5.0 (and large integers compare against floats with
 * no precision loss). Sets *order to -1/0/1; returns 0 on success, -1 on
 * malformed input or out-of-memory. */
int struple_semantic_order(const uint8_t *a, size_t alen, const uint8_t *b, size_t blen, int *order);

/* Decode every element and re-encode it into `out` (validates the decoder).
 * Returns 0 on success, -1 on error. */
int struple_transcode(const uint8_t *buf, size_t len, struple_writer *out);

/* ---- JSON convenience (see struple_json.c) ---- */

/* Parse JSON text into a struple encoding in `out`. Returns 0 on success, -1 on
 * parse/encode error. Integer tokens up to int64/uint64 are first-class; larger
 * integers stay lossless via arbitrary-precision magnitude bytes. */
int struple_from_json(const char *text, size_t len, struple_writer *out);

/* Render the first element of `buf` as canonical JSON text into `out` (the
 * bytes are UTF-8 text). Returns 0 on success, -1 on error. */
int struple_to_json(const uint8_t *buf, size_t len, struple_writer *out);

#ifdef __cplusplus
}
#endif

#endif /* STRUPLE_H */
