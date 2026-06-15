/* struple core codec — a faithful port of the Zig reference. */
#include "struple.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* Type codes. Their order is the cross-type sort order. */
#define TERMINATOR 0x00
#define NIL 0x01
#define UNDEF 0x02
#define BOOL_FALSE 0x05
#define BOOL_TRUE 0x06
#define INT_NEG_BIG 0x0f
#define INT_ZERO 0x20
#define INT_POS_BIG 0x31
#define FLOAT32 0x34
#define FLOAT64 0x35
#define TIMESTAMP 0x40
#define STRING 0x48
#define BYTES 0x49
#define ARRAY 0x50
#define MAP 0x52
#define SET 0x54

#define SIGN64 0x8000000000000000ULL
#define SIGN32 0x80000000u

/* ------------------------------------------------------------------ writer */

void struple_writer_init(struple_writer *w) {
    w->data = NULL;
    w->len = 0;
    w->cap = 0;
}

void struple_writer_free(struple_writer *w) {
    free(w->data);
    w->data = NULL;
    w->len = 0;
    w->cap = 0;
}

void struple_writer_reset(struple_writer *w) {
    w->len = 0;
}

static void sw_reserve(struple_writer *w, size_t extra) {
    if (w->len + extra > w->cap) {
        size_t cap = w->cap ? w->cap : 64;
        while (cap < w->len + extra) cap *= 2;
        w->data = (uint8_t *)realloc(w->data, cap);
        w->cap = cap;
    }
}

static void sw_push(struple_writer *w, uint8_t b) {
    sw_reserve(w, 1);
    w->data[w->len++] = b;
}

static void sw_append(struple_writer *w, const uint8_t *p, size_t n) {
    sw_reserve(w, n);
    memcpy(w->data + w->len, p, n);
    w->len += n;
}

void struple_writer_append(struple_writer *w, const uint8_t *data, size_t len) {
    sw_append(w, data, len);
}

/* ------------------------------------------------------------------ helpers */

static uint64_t be_to_u64(const uint8_t *p, size_t n) {
    uint64_t v = 0;
    for (size_t i = 0; i < n; i++) v = (v << 8) | p[i];
    return v;
}

static size_t u64_to_be(uint64_t mag, uint8_t *out) {
    if (mag == 0) return 0;
    uint8_t tmp[8];
    size_t n = 0;
    while (mag) {
        tmp[n++] = (uint8_t)(mag & 0xff);
        mag >>= 8;
    }
    for (size_t i = 0; i < n; i++) out[i] = tmp[n - 1 - i];
    return n;
}

static size_t byte_len(uint64_t x) {
    size_t n = 0;
    while (x) {
        n++;
        x >>= 8;
    }
    return n;
}

static void push_be(struple_writer *w, uint64_t value, size_t n) {
    for (size_t i = n; i-- > 0;) sw_push(w, (uint8_t)((value >> (8 * i)) & 0xff));
}

static void write_escaped(struple_writer *w, const uint8_t *content, size_t len) {
    for (size_t i = 0; i < len; i++) {
        sw_push(w, content[i]);
        if (content[i] == 0x00) sw_push(w, 0xff);
    }
}

static void write_framed(struple_writer *w, uint8_t type_code, const uint8_t *content, size_t len) {
    sw_push(w, type_code);
    write_escaped(w, content, len);
    sw_push(w, TERMINATOR);
}

/* mag: normalized big-endian magnitude (non-empty, no leading zeros). */
static void append_magnitude(struple_writer *w, bool negative, const uint8_t *mag, size_t mag_len) {
    if (mag_len <= 8) {
        if (negative) {
            uint64_t m = be_to_u64(mag, mag_len);
            uint64_t pos_val = m - 1;
            size_t n = byte_len(pos_val);
            if (n == 0) n = 1;
            sw_push(w, (uint8_t)(INT_ZERO - n));
            uint64_t payload = (n == 8) ? ((uint64_t)0 - m) : ((1ULL << (8 * n)) - m);
            push_be(w, payload, n);
        } else {
            sw_push(w, (uint8_t)(INT_ZERO + mag_len));
            sw_append(w, mag, mag_len);
        }
        return;
    }
    /* arbitrary precision: [m][n][magnitude], complemented for negatives */
    sw_push(w, negative ? INT_NEG_BIG : INT_POS_BIG);
    size_t n = mag_len;
    size_t m = byte_len((uint64_t)n);
    if (m == 0) m = 1;
    sw_push(w, negative ? (uint8_t)~(uint8_t)m : (uint8_t)m);
    for (size_t i = m; i-- > 0;) {
        uint8_t b = (uint8_t)((n >> (8 * i)) & 0xff);
        sw_push(w, negative ? (uint8_t)~b : b);
    }
    for (size_t i = 0; i < mag_len; i++) sw_push(w, negative ? (uint8_t)~mag[i] : mag[i]);
}

/* ------------------------------------------------------------------ append */

void struple_append_nil(struple_writer *w) { sw_push(w, NIL); }
void struple_append_undefined(struple_writer *w) { sw_push(w, UNDEF); }
void struple_append_bool(struple_writer *w, bool v) { sw_push(w, v ? BOOL_TRUE : BOOL_FALSE); }

void struple_append_int(struple_writer *w, int64_t v) {
    if (v == 0) {
        sw_push(w, INT_ZERO);
        return;
    }
    bool negative = v < 0;
    uint64_t mag = negative ? (~(uint64_t)v + 1) : (uint64_t)v;
    uint8_t buf[8];
    size_t n = u64_to_be(mag, buf);
    append_magnitude(w, negative, buf, n);
}

void struple_append_uint(struple_writer *w, uint64_t v) {
    if (v == 0) {
        sw_push(w, INT_ZERO);
        return;
    }
    uint8_t buf[8];
    size_t n = u64_to_be(v, buf);
    append_magnitude(w, false, buf, n);
}

void struple_append_big_int(struple_writer *w, bool negative, const uint8_t *mag, size_t mag_len) {
    while (mag_len > 0 && mag[0] == 0) {
        mag++;
        mag_len--;
    }
    if (mag_len == 0) {
        sw_push(w, INT_ZERO);
        return;
    }
    append_magnitude(w, negative, mag, mag_len);
}

void struple_append_f64(struple_writer *w, double v) {
    uint64_t bits;
    if (isnan(v)) {
        bits = 0x7ff8000000000000ULL;
    } else {
        double vv = (v == 0.0) ? 0.0 : v; /* squash -0.0 */
        memcpy(&bits, &vv, sizeof bits);
    }
    bits = (bits & SIGN64) ? ~bits : (bits ^ SIGN64);
    sw_push(w, FLOAT64);
    for (int i = 7; i >= 0; i--) sw_push(w, (uint8_t)((bits >> (8 * i)) & 0xff));
}

void struple_append_f32(struple_writer *w, float v) {
    uint32_t bits;
    if (isnan(v)) {
        bits = 0x7fc00000u;
    } else {
        float vv = (v == 0.0f) ? 0.0f : v;
        memcpy(&bits, &vv, sizeof bits);
    }
    bits = (bits & SIGN32) ? ~bits : (bits ^ SIGN32);
    sw_push(w, FLOAT32);
    for (int i = 3; i >= 0; i--) sw_push(w, (uint8_t)((bits >> (8 * i)) & 0xff));
}

void struple_append_timestamp(struple_writer *w, int64_t micros) {
    uint64_t u = (uint64_t)micros ^ SIGN64;
    sw_push(w, TIMESTAMP);
    for (int i = 7; i >= 0; i--) sw_push(w, (uint8_t)((u >> (8 * i)) & 0xff));
}

void struple_append_string(struple_writer *w, const char *s, size_t len) {
    write_framed(w, STRING, (const uint8_t *)s, len);
}
void struple_append_bytes(struple_writer *w, const uint8_t *b, size_t len) {
    write_framed(w, BYTES, b, len);
}
void struple_append_array(struple_writer *w, const uint8_t *child, size_t child_len) {
    write_framed(w, ARRAY, child, child_len);
}

static int cmp_bytes(const struple_bytes *a, const struple_bytes *b) {
    size_t n = a->len < b->len ? a->len : b->len;
    int c = n ? memcmp(a->ptr, b->ptr, n) : 0;
    if (c != 0) return c < 0 ? -1 : 1;
    if (a->len < b->len) return -1;
    if (a->len > b->len) return 1;
    return 0;
}

static int kv_cmp(const void *x, const void *y) {
    return cmp_bytes(&((const struple_kv *)x)->key, &((const struple_kv *)y)->key);
}
static int sb_cmp(const void *x, const void *y) {
    return cmp_bytes((const struple_bytes *)x, (const struple_bytes *)y);
}

void struple_append_map(struple_writer *w, struple_kv *entries, size_t count) {
    qsort(entries, count, sizeof(struple_kv), kv_cmp);
    sw_push(w, MAP);
    for (size_t i = 0; i < count; i++) {
        write_escaped(w, entries[i].key.ptr, entries[i].key.len);
        write_escaped(w, entries[i].value.ptr, entries[i].value.len);
    }
    sw_push(w, TERMINATOR);
}

void struple_append_set(struple_writer *w, struple_bytes *elems, size_t count) {
    qsort(elems, count, sizeof(struple_bytes), sb_cmp);
    sw_push(w, SET);
    for (size_t i = 0; i < count; i++) {
        if (i > 0 && cmp_bytes(&elems[i - 1], &elems[i]) == 0) continue;
        write_escaped(w, elems[i].ptr, elems[i].len);
    }
    sw_push(w, TERMINATOR);
}

/* ------------------------------------------------------------------ reader */

void struple_reader_init(struple_reader *r, const uint8_t *buf, size_t len) {
    r->buf = buf;
    r->len = len;
    r->pos = 0;
    r->scratch = NULL;
    r->scratch_cap = 0;
}

void struple_reader_free(struple_reader *r) {
    free(r->scratch);
    r->scratch = NULL;
    r->scratch_cap = 0;
}

static uint8_t *r_scratch(struple_reader *r, size_t needed) {
    if (r->scratch_cap < needed) {
        size_t cap = r->scratch_cap ? r->scratch_cap : 32;
        while (cap < needed) cap *= 2;
        uint8_t *p = (uint8_t *)realloc(r->scratch, cap);
        if (!p) return NULL;
        r->scratch = p;
        r->scratch_cap = cap;
    }
    return r->scratch;
}

static const uint8_t *take(struple_reader *r, size_t n) {
    if (r->pos + n > r->len) return NULL;
    const uint8_t *p = r->buf + r->pos;
    r->pos += n;
    return p;
}

static const uint8_t *take_framed(struple_reader *r, size_t *out_len) {
    size_t start = r->pos, i = r->pos;
    while (i < r->len) {
        if (r->buf[i] == 0x00) {
            if (i + 1 < r->len && r->buf[i + 1] == 0xff) {
                i += 2;
                continue;
            }
            *out_len = i - start;
            r->pos = i + 1;
            return r->buf + start;
        }
        i++;
    }
    return NULL;
}

static int unescape_to_scratch(struple_reader *r, const uint8_t *framed, size_t flen,
                               const uint8_t **out, size_t *out_len) {
    size_t ulen = 0;
    for (size_t i = 0; i < flen; i++) {
        ulen++;
        if (framed[i] == 0x00) i++;
    }
    uint8_t *s = r_scratch(r, ulen + 1);
    if (!s) return -1;
    size_t w = 0;
    for (size_t i = 0; i < flen; i++) {
        s[w++] = framed[i];
        if (framed[i] == 0x00) i++;
    }
    s[w] = 0; /* NUL-terminate for string convenience */
    *out = s;
    *out_len = w;
    return 0;
}

static int read_fixed_int(struple_reader *r, uint8_t t, struple_element *out) {
    size_t n = (t < INT_ZERO) ? (size_t)(INT_ZERO - t) : (size_t)(t - INT_ZERO);
    if (n > 8) return -1;
    const uint8_t *p = take(r, n);
    if (!p) return -1;
    uint64_t raw = be_to_u64(p, n);
    if (t > INT_ZERO) {
        if (raw <= (uint64_t)INT64_MAX) {
            out->kind = STRUPLE_INT;
            out->int_val = (int64_t)raw;
        } else {
            out->kind = STRUPLE_BIGINT;
            out->big_negative = false;
            out->data = p;
            out->data_len = n;
        }
        return 0;
    }
    /* negative: |value| = 2^(8n) - raw */
    if (n < 8) {
        uint64_t m = (1ULL << (8 * n)) - raw;
        out->kind = STRUPLE_INT;
        out->int_val = -(int64_t)m;
        return 0;
    }
    if (raw == 0) { /* |value| = 2^64 (only from malformed fixed input) */
        uint8_t *s = r_scratch(r, 9);
        if (!s) return -1;
        s[0] = 1;
        memset(s + 1, 0, 8);
        out->kind = STRUPLE_BIGINT;
        out->big_negative = true;
        out->data = s;
        out->data_len = 9;
        return 0;
    }
    uint64_t m = (uint64_t)0 - raw; /* 2^64 - raw */
    if (m <= (uint64_t)INT64_MAX + 1) {
        out->kind = STRUPLE_INT;
        out->int_val = (m == (uint64_t)INT64_MAX + 1) ? INT64_MIN : -(int64_t)m;
    } else {
        uint8_t buf[8];
        size_t mn = u64_to_be(m, buf);
        uint8_t *s = r_scratch(r, mn);
        if (!s) return -1;
        memcpy(s, buf, mn);
        out->kind = STRUPLE_BIGINT;
        out->big_negative = true;
        out->data = s;
        out->data_len = mn;
    }
    return 0;
}

static int read_big_int(struple_reader *r, uint8_t t, struple_element *out) {
    bool negative = (t == INT_NEG_BIG);
    const uint8_t *p = take(r, 1);
    if (!p) return -1;
    size_t m = negative ? (uint8_t)~p[0] : p[0];
    const uint8_t *nb = take(r, m);
    if (!nb) return -1;
    size_t n = 0;
    for (size_t i = 0; i < m; i++) {
        uint8_t b = negative ? (uint8_t)~nb[i] : nb[i];
        n = (n << 8) | b;
    }
    const uint8_t *mag = take(r, n);
    if (!mag && n) return -1;
    out->kind = STRUPLE_BIGINT;
    out->big_negative = negative;
    if (negative) {
        uint8_t *s = r_scratch(r, n ? n : 1);
        if (!s) return -1;
        for (size_t i = 0; i < n; i++) s[i] = (uint8_t)~mag[i];
        out->data = s;
        out->data_len = n;
    } else {
        out->data = mag;
        out->data_len = n;
    }
    return 0;
}

static int read_f64(struple_reader *r, struple_element *out) {
    const uint8_t *p = take(r, 8);
    if (!p) return -1;
    uint64_t bits = be_to_u64(p, 8);
    bits = (bits & SIGN64) ? (bits ^ SIGN64) : ~bits;
    memcpy(&out->f64_val, &bits, sizeof bits);
    out->kind = STRUPLE_F64;
    return 0;
}

static int read_f32(struple_reader *r, struple_element *out) {
    const uint8_t *p = take(r, 4);
    if (!p) return -1;
    uint32_t bits = (uint32_t)be_to_u64(p, 4);
    bits = (bits & SIGN32) ? (bits ^ SIGN32) : ~bits;
    memcpy(&out->f32_val, &bits, sizeof bits);
    out->kind = STRUPLE_F32;
    return 0;
}

static int read_timestamp(struple_reader *r, struple_element *out) {
    const uint8_t *p = take(r, 8);
    if (!p) return -1;
    uint64_t raw = be_to_u64(p, 8) ^ SIGN64;
    out->kind = STRUPLE_TIMESTAMP;
    out->int_val = (int64_t)raw;
    return 0;
}

int struple_reader_next(struple_reader *r, struple_element *out) {
    if (r->pos >= r->len) return 0;
    uint8_t t = r->buf[r->pos++];
    memset(out, 0, sizeof *out);
    switch (t) {
        case NIL: out->kind = STRUPLE_NIL; return 1;
        case UNDEF: out->kind = STRUPLE_UNDEF; return 1;
        case BOOL_FALSE: out->kind = STRUPLE_BOOL; out->bool_val = false; return 1;
        case BOOL_TRUE: out->kind = STRUPLE_BOOL; out->bool_val = true; return 1;
        case INT_ZERO: out->kind = STRUPLE_INT; out->int_val = 0; return 1;
        case INT_NEG_BIG:
        case INT_POS_BIG: return read_big_int(r, t, out) == 0 ? 1 : -1;
        case FLOAT32: return read_f32(r, out) == 0 ? 1 : -1;
        case FLOAT64: return read_f64(r, out) == 0 ? 1 : -1;
        case TIMESTAMP: return read_timestamp(r, out) == 0 ? 1 : -1;
        case STRING:
        case BYTES:
        case ARRAY:
        case MAP:
        case SET: {
            size_t flen;
            const uint8_t *framed = take_framed(r, &flen);
            if (!framed) return -1;
            const uint8_t *u;
            size_t ulen;
            if (unescape_to_scratch(r, framed, flen, &u, &ulen) != 0) return -1;
            out->data = u;
            out->data_len = ulen;
            out->kind = (t == STRING)  ? STRUPLE_STRING
                        : (t == BYTES) ? STRUPLE_BYTES
                        : (t == ARRAY) ? STRUPLE_ARRAY
                        : (t == MAP)   ? STRUPLE_MAP
                                       : STRUPLE_SET;
            return 1;
        }
        default:
            if ((t >= 0x10 && t <= 0x1f) || (t >= 0x21 && t <= 0x30))
                return read_fixed_int(r, t, out) == 0 ? 1 : -1;
            return -1;
    }
}

/* ------------------------------------------------------------ transcode/cmp */

static void append_element(struple_writer *w, const struple_element *e) {
    switch (e->kind) {
        case STRUPLE_NIL: struple_append_nil(w); break;
        case STRUPLE_UNDEF: struple_append_undefined(w); break;
        case STRUPLE_BOOL: struple_append_bool(w, e->bool_val); break;
        case STRUPLE_INT: struple_append_int(w, e->int_val); break;
        case STRUPLE_BIGINT: struple_append_big_int(w, e->big_negative, e->data, e->data_len); break;
        case STRUPLE_F32: struple_append_f32(w, e->f32_val); break;
        case STRUPLE_F64: struple_append_f64(w, e->f64_val); break;
        case STRUPLE_TIMESTAMP: struple_append_timestamp(w, e->int_val); break;
        case STRUPLE_STRING: struple_append_string(w, (const char *)e->data, e->data_len); break;
        case STRUPLE_BYTES: struple_append_bytes(w, e->data, e->data_len); break;
        case STRUPLE_ARRAY: write_framed(w, ARRAY, e->data, e->data_len); break;
        case STRUPLE_MAP: write_framed(w, MAP, e->data, e->data_len); break;
        case STRUPLE_SET: write_framed(w, SET, e->data, e->data_len); break;
    }
}

int struple_transcode(const uint8_t *buf, size_t len, struple_writer *out) {
    struple_reader r;
    struple_reader_init(&r, buf, len);
    struple_element e;
    int rc;
    while ((rc = struple_reader_next(&r, &e)) == 1) append_element(out, &e);
    struple_reader_free(&r);
    return rc == 0 ? 0 : -1;
}

int struple_compare(const uint8_t *a, size_t alen, const uint8_t *b, size_t blen) {
    size_t n = alen < blen ? alen : blen;
    int c = n ? memcmp(a, b, n) : 0;
    if (c != 0) return c < 0 ? -1 : 1;
    if (alen < blen) return -1;
    if (alen > blen) return 1;
    return 0;
}

/* ------------------------------------------------------------ navigation */

/* Compute the byte length of the element at `pos` without decoding (no scratch).
 * Returns 1 and sets *out, 0 at end, -1 on malformed input. */
static int element_span(const uint8_t *buf, size_t len, size_t pos, size_t *out) {
    if (pos >= len) return 0;
    uint8_t t = buf[pos];
    size_t p = pos + 1;
    if (t == NIL || t == UNDEF || t == BOOL_FALSE || t == BOOL_TRUE || t == INT_ZERO) {
        /* no payload */
    } else if ((t >= 0x10 && t <= 0x1f) || (t >= 0x21 && t <= 0x30)) {
        size_t n = (t < INT_ZERO) ? (size_t)(INT_ZERO - t) : (size_t)(t - INT_ZERO);
        if (n > 8) return -1;
        p += n;
    } else if (t == INT_NEG_BIG || t == INT_POS_BIG) {
        bool neg = (t == INT_NEG_BIG);
        if (p >= len) return -1;
        size_t m = neg ? (uint8_t)~buf[p] : buf[p];
        p++;
        if (p + m > len) return -1;
        size_t n = 0;
        for (size_t i = 0; i < m; i++) {
            uint8_t b = neg ? (uint8_t)~buf[p + i] : buf[p + i];
            n = (n << 8) | b;
        }
        p += m + n;
    } else if (t == FLOAT32) {
        p += 4;
    } else if (t == FLOAT64 || t == TIMESTAMP) {
        p += 8;
    } else if (t == STRING || t == BYTES || t == ARRAY || t == MAP || t == SET) {
        size_t i = p;
        for (;;) {
            if (i >= len) return -1;
            if (buf[i] == 0x00) {
                if (i + 1 < len && buf[i + 1] == 0xff) {
                    i += 2;
                    continue;
                }
                p = i + 1;
                break;
            }
            i++;
        }
    } else {
        return -1;
    }
    if (p > len) return -1;
    *out = p - pos;
    return 1;
}

int struple_reader_peek_type(const struple_reader *r) {
    return r->pos < r->len ? r->buf[r->pos] : -1;
}

const uint8_t *struple_reader_rest(const struple_reader *r, size_t *out_len) {
    *out_len = r->len - r->pos;
    return r->buf + r->pos;
}

int struple_reader_next_view(struple_reader *r, const uint8_t **out_ptr, size_t *out_len) {
    size_t span;
    int rc = element_span(r->buf, r->len, r->pos, &span);
    if (rc != 1) return rc;
    *out_ptr = r->buf + r->pos;
    *out_len = span;
    r->pos += span;
    return 1;
}

int struple_reader_skip(struple_reader *r) {
    const uint8_t *p;
    size_t l;
    return struple_reader_next_view(r, &p, &l);
}

long struple_view_count(struple_view v) {
    struple_reader r;
    struple_reader_init(&r, v.bytes, v.len);
    long n = 0;
    int rc;
    while ((rc = struple_reader_skip(&r)) == 1) n++;
    return rc == 0 ? n : -1;
}

int struple_view_at(struple_view v, size_t index, struple_view *out) {
    struple_reader r;
    struple_reader_init(&r, v.bytes, v.len);
    size_t i = 0;
    const uint8_t *p;
    size_t l;
    int rc;
    while ((rc = struple_reader_next_view(&r, &p, &l)) == 1) {
        if (i == index) {
            out->bytes = p;
            out->len = l;
            return 1;
        }
        i++;
    }
    return rc;
}

int struple_view_head(struple_view v, struple_view *out) {
    return struple_view_at(v, 0, out);
}

struple_view struple_view_tail(struple_view v) {
    struple_reader r;
    struple_reader_init(&r, v.bytes, v.len);
    const uint8_t *p;
    size_t l;
    struple_reader_next_view(&r, &p, &l);
    struple_view out = {r.buf + r.pos, r.len - r.pos};
    return out;
}

struple_view struple_view_nth_rest(struple_view v, size_t n) {
    struple_reader r;
    struple_reader_init(&r, v.bytes, v.len);
    for (size_t i = 0; i < n; i++) {
        if (struple_reader_skip(&r) != 1) break;
    }
    struple_view out = {r.buf + r.pos, r.len - r.pos};
    return out;
}

struple_view struple_view_take(struple_view v, size_t n) {
    struple_reader r;
    struple_reader_init(&r, v.bytes, v.len);
    for (size_t i = 0; i < n; i++) {
        if (struple_reader_skip(&r) != 1) break;
    }
    struple_view out = {v.bytes, r.pos};
    return out;
}

int struple_view_head_type(struple_view v) {
    return v.len > 0 ? v.bytes[0] : -1;
}

bool struple_view_is_nil(struple_view v) { return struple_view_head_type(v) == NIL; }
bool struple_view_is_undefined(struple_view v) { return struple_view_head_type(v) == UNDEF; }
bool struple_view_is_bool(struple_view v) {
    int t = struple_view_head_type(v);
    return t == BOOL_FALSE || t == BOOL_TRUE;
}
bool struple_view_is_int(struple_view v) {
    int t = struple_view_head_type(v);
    return t == INT_ZERO || t == INT_NEG_BIG || t == INT_POS_BIG || (t >= 0x10 && t <= 0x1f) || (t >= 0x21 && t <= 0x30);
}
bool struple_view_is_float(struple_view v) {
    int t = struple_view_head_type(v);
    return t == FLOAT32 || t == FLOAT64;
}
bool struple_view_is_number(struple_view v) { return struple_view_is_int(v) || struple_view_is_float(v); }
bool struple_view_is_timestamp(struple_view v) { return struple_view_head_type(v) == TIMESTAMP; }
bool struple_view_is_string(struple_view v) { return struple_view_head_type(v) == STRING; }
bool struple_view_is_bytes(struple_view v) { return struple_view_head_type(v) == BYTES; }
bool struple_view_is_array(struple_view v) { return struple_view_head_type(v) == ARRAY; }
bool struple_view_is_map(struple_view v) { return struple_view_head_type(v) == MAP; }
bool struple_view_is_set(struple_view v) { return struple_view_head_type(v) == SET; }
bool struple_view_is_container(struple_view v) {
    int t = struple_view_head_type(v);
    return t == ARRAY || t == MAP || t == SET;
}

int struple_view_contained_items(struple_view v, struple_writer *out) {
    struple_reader r;
    struple_reader_init(&r, v.bytes, v.len);
    struple_element e;
    int rc = struple_reader_next(&r, &e);
    int result;
    if (rc != 1) {
        result = rc == 0 ? 0 : -1;
    } else if (e.kind == STRUPLE_ARRAY || e.kind == STRUPLE_MAP || e.kind == STRUPLE_SET) {
        struple_writer_append(out, e.data, e.data_len);
        result = 1;
    } else {
        result = 0;
    }
    struple_reader_free(&r);
    return result;
}

long struple_map_count(struple_map m) {
    struple_view v = {m.inner, m.len};
    long c = struple_view_count(v);
    return c < 0 ? -1 : c / 2;
}

struple_map_iter struple_map_iterator(struple_map m) {
    struple_map_iter it;
    struple_reader_init(&it.r, m.inner, m.len);
    return it;
}

int struple_map_next(struple_map_iter *it, struple_view *key, struple_view *value) {
    const uint8_t *kp;
    size_t kl;
    int rc = struple_reader_next_view(&it->r, &kp, &kl);
    if (rc != 1) return rc;
    const uint8_t *vp;
    size_t vl;
    if (struple_reader_next_view(&it->r, &vp, &vl) != 1) return -1;
    key->bytes = kp;
    key->len = kl;
    value->bytes = vp;
    value->len = vl;
    return 1;
}

int struple_map_get(struple_map m, const uint8_t *key, size_t keylen, struple_view *out) {
    struple_map_iter it = struple_map_iterator(m);
    struple_view k, val;
    while (struple_map_next(&it, &k, &val) == 1) {
        int c = struple_compare(k.bytes, k.len, key, keylen);
        if (c == 0) {
            *out = val;
            return 1;
        }
        if (c > 0) return 0;
    }
    return 0;
}
