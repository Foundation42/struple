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
#define DECIMAL 0x38
#define TIMESTAMP 0x40

/* Leading marker inside a decimal payload, isolating the three sign groups so
 * memcmp keeps negative < zero < positive. For negatives the rest of the payload
 * is bit-complemented, so a larger magnitude sorts earlier. */
#define DEC_SIGN_NEG 0x01
#define DEC_SIGN_ZERO 0x02
#define DEC_SIGN_POS 0x03
#define UUID 0x44
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

static void write_escaped(struple_writer *w, const uint8_t *content, size_t len) {
    /* Bulk-copy the runs between 0x00 bytes; the escape-free case is one memcpy. */
    static const uint8_t esc[2] = { 0x00, 0xff };
    size_t i = 0;
    while (i < len) {
        size_t start = i;
        while (i < len && content[i] != 0x00) i++;
        sw_append(w, content + start, i - start);
        if (i < len) {
            sw_append(w, esc, 2);
            i++;
        }
    }
}

static void write_framed(struple_writer *w, uint8_t type_code, const uint8_t *content, size_t len) {
    sw_push(w, type_code);
    write_escaped(w, content, len);
    sw_push(w, TERMINATOR);
}

/* Does this value (sign + trimmed big-endian magnitude) fit the i128 range
 * [-2^127, 2^127-1]? Below 16 bytes always; at 16 bytes the top byte decides. */
static bool fits_fixed(bool negative, const uint8_t *mag, size_t mag_len) {
    if (mag_len < 16) return true;
    if (mag_len > 16) return false;
    if (mag[0] < 0x80) return true; /* |value| < 2^127 */
    if (!negative) return false;    /* positive >= 2^127 -> big-int */
    if (mag[0] != 0x80) return false;
    for (size_t i = 1; i < 16; i++)
        if (mag[i] != 0) return false; /* only exactly -2^127 still fits */
    return true;
}

/* mag: normalized big-endian magnitude (non-empty, no leading zeros). */
static void append_magnitude(struple_writer *w, bool negative, const uint8_t *mag, size_t mag_len) {
    /* The fixed slots span the whole i128 range (1–16 byte magnitudes). */
    if (fits_fixed(negative, mag, mag_len)) {
        if (!negative) {
            sw_push(w, (uint8_t)(INT_ZERO + mag_len));
            sw_append(w, mag, mag_len);
            return;
        }
        /* Negative excess form = ~(magnitude - 1) over n bytes, where n is the
         * byte length of (magnitude - 1). Pure byte math — no 128-bit type. */
        uint8_t pv[16];
        memcpy(pv, mag, mag_len);
        for (size_t i = mag_len; i-- > 0;) {
            if (pv[i]-- != 0) break; /* borrow only while a byte was 0x00 */
        }
        size_t start = 0;
        while (start + 1 < mag_len && pv[start] == 0) start++; /* trim pos_val */
        size_t n = mag_len - start;
        sw_push(w, (uint8_t)(INT_ZERO - n));
        for (size_t i = start; i < mag_len; i++) sw_push(w, (uint8_t)~pv[i]);
        return;
    }
    /* arbitrary precision beyond i128: [m][n][magnitude], complemented for negatives */
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

void struple_append_decimal(struple_writer *w, bool negative, const uint8_t *digits, size_t ndigits, int32_t exp) {
    /* Strip leading zeros: they shift neither the value nor the adjusted exponent. */
    size_t lead = 0;
    while (lead < ndigits && digits[lead] == 0) lead++;
    const uint8_t *sig = digits + lead;
    size_t sig_len = ndigits - lead;

    sw_push(w, DECIMAL);
    if (sig_len == 0) { /* canonical zero — one form regardless of scale */
        sw_push(w, DEC_SIGN_ZERO);
        return;
    }

    /* Adjusted exponent: place value of the most-significant digit (0.d…·10^E).
     * Trailing zeros change neither the value nor E, so drop them for storage. */
    int64_t adj_exp = (int64_t)sig_len + (int64_t)exp;
    size_t end = sig_len;
    while (end > 0 && sig[end - 1] == 0) end--;

    /* Order-bearing tail: [E as a struple int][base-100 digits][terminator]. */
    struple_writer tail;
    struple_writer_init(&tail);
    /* The exponent reuses the int codec; adj_exp fits int64 (exp is int32). */
    struple_append_int(&tail, adj_exp);
    for (size_t i = 0; i < end; i += 2) {
        unsigned hi = sig[i];
        unsigned lo = (i + 1 < end) ? sig[i + 1] : 0; /* pad odd tail with 0 */
        sw_push(&tail, (uint8_t)(hi * 10 + lo + 1)); /* pair 0–99 -> byte 1–100 */
    }
    sw_push(&tail, TERMINATOR);

    sw_push(w, negative ? DEC_SIGN_NEG : DEC_SIGN_POS);
    for (size_t i = 0; i < tail.len; i++) sw_push(w, negative ? (uint8_t)~tail.data[i] : tail.data[i]);
    struple_writer_free(&tail);
}

int struple_append_decimal_string(struple_writer *w, const char *s, size_t len) {
    size_t i = 0;
    bool negative = false;
    if (i < len && (s[i] == '+' || s[i] == '-')) {
        negative = s[i] == '-';
        i++;
    }
    uint8_t *digits = NULL;
    size_t ndigits = 0, dcap = 0;
    int32_t exp = 0;
    bool seen_point = false;
    bool any = false;
    for (; i < len; i++) {
        char c = s[i];
        if (c == '.') {
            if (seen_point) {
                free(digits);
                return -1;
            }
            seen_point = true;
            continue;
        }
        if (c == 'e' || c == 'E') break;
        if (c < '0' || c > '9') {
            free(digits);
            return -1;
        }
        if (ndigits + 1 > dcap) {
            dcap = dcap ? dcap * 2 : 16;
            digits = (uint8_t *)realloc(digits, dcap);
        }
        digits[ndigits++] = (uint8_t)(c - '0');
        if (seen_point) exp -= 1;
        any = true;
    }
    if (!any) {
        free(digits);
        return -1;
    }
    if (i < len && (s[i] == 'e' || s[i] == 'E')) {
        i++;
        int32_t esign = 1;
        if (i < len && (s[i] == '+' || s[i] == '-')) {
            if (s[i] == '-') esign = -1;
            i++;
        }
        int32_t ev = 0;
        bool edig = false;
        for (; i < len; i++) {
            if (s[i] < '0' || s[i] > '9') {
                free(digits);
                return -1;
            }
            ev = ev * 10 + (s[i] - '0');
            edig = true;
        }
        if (!edig) {
            free(digits);
            return -1;
        }
        exp += esign * ev;
    }
    struple_append_decimal(w, negative, digits, ndigits, exp);
    free(digits);
    return 0;
}

void struple_append_timestamp(struple_writer *w, int64_t micros) {
    uint64_t u = (uint64_t)micros ^ SIGN64;
    sw_push(w, TIMESTAMP);
    for (int i = 7; i >= 0; i--) sw_push(w, (uint8_t)((u >> (8 * i)) & 0xff));
}

void struple_append_uuid(struple_writer *w, const uint8_t *uuid16) {
    sw_push(w, UUID);
    sw_append(w, uuid16, 16);
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
    bool positive = t > INT_ZERO;
    size_t n = positive ? (size_t)(t - INT_ZERO) : (size_t)(INT_ZERO - t);
    const uint8_t *p = take(r, n);
    if (!p) return -1;
    /* The widest (16-byte) slots can address values outside i128; a canonical
     * encoder uses the big-int codes for those, so reject them here. */
    if (n == 16 && ((positive && p[0] >= 0x80) || (!positive && p[0] < 0x80))) return -1;

    if (n <= 8) {
        uint64_t raw = be_to_u64(p, n);
        if (positive) {
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
            out->kind = STRUPLE_INT;
            out->int_val = -(int64_t)((1ULL << (8 * n)) - raw);
            return 0;
        }
        if (raw == 0) { /* |value| = 2^64 */
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

    /* n in 9..16: the value exceeds int64, so it is always a big-int element. */
    out->kind = STRUPLE_BIGINT;
    if (positive) {
        out->big_negative = false;
        out->data = p; /* payload is already the magnitude (no leading zeros) */
        out->data_len = n;
        return 0;
    }
    /* negative: magnitude = 2^(8n) - excess = (~excess) + 1, computed in bytes */
    uint8_t *s = r_scratch(r, n);
    if (!s) return -1;
    unsigned carry = 1;
    for (size_t i = n; i-- > 0;) {
        unsigned v = (unsigned)(uint8_t)~p[i] + carry;
        s[i] = (uint8_t)(v & 0xff);
        carry = v >> 8;
    }
    size_t start = 0;
    while (start + 1 < n && s[start] == 0) start++; /* trim leading zeros */
    out->big_negative = true;
    out->data = s + start;
    out->data_len = n - start;
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

/* Read the embedded exponent (a struple integer), un-complementing each byte for
 * negatives. Big-int exponent codes are rejected (far beyond any real use). Sets
 * *out_exp and returns 0, or returns -1 on a malformed/out-of-range exponent. */
static int read_dec_exponent(struple_reader *r, bool complement, int64_t *out_exp) {
    const uint8_t *tp = take(r, 1);
    if (!tp) return -1;
    uint8_t tb = complement ? (uint8_t)~tp[0] : tp[0];
    if (tb == INT_ZERO) {
        *out_exp = 0;
        return 0;
    }
    bool fixed_neg = (tb >= 0x10 && tb <= 0x1f);
    bool fixed_pos = (tb >= 0x21 && tb <= 0x30);
    if (!fixed_neg && !fixed_pos) return -1;
    bool positive = tb > INT_ZERO;
    size_t n = positive ? (size_t)(tb - INT_ZERO) : (size_t)(INT_ZERO - tb);
    const uint8_t *raw = take(r, n);
    if (!raw) return -1;
    uint8_t tmp[16];
    for (size_t i = 0; i < n; i++) tmp[i] = complement ? (uint8_t)~raw[i] : raw[i];
    if (n == 16 && ((positive && tmp[0] >= 0x80) || (!positive && tmp[0] < 0x80))) return -1;
    /* The exponent must fit i64; any payload wider than 8 bytes overflows. */
    if (n > 8) return -1;
    uint64_t mag = be_to_u64(tmp, n);
    if (positive) {
        if (mag > (uint64_t)INT64_MAX) return -1;
        *out_exp = (int64_t)mag;
        return 0;
    }
    /* negative: value = raw - 2^(8n) = -(2^(8n) - raw) */
    if (n < 8) {
        *out_exp = -(int64_t)((1ULL << (8 * n)) - mag);
        return 0;
    }
    /* n == 8: value = mag - 2^64. Reject anything below INT64_MIN. */
    uint64_t neg_mag = (uint64_t)0 - mag; /* 2^64 - mag */
    if (neg_mag > (uint64_t)INT64_MAX + 1) return -1;
    *out_exp = (neg_mag == (uint64_t)INT64_MAX + 1) ? INT64_MIN : -(int64_t)neg_mag;
    return 0;
}

static int read_decimal(struple_reader *r, struple_element *out) {
    const uint8_t *sp = take(r, 1);
    if (!sp) return -1;
    uint8_t sign = sp[0];
    if (sign == DEC_SIGN_ZERO) {
        out->kind = STRUPLE_DECIMAL;
        out->dec_negative = false;
        out->dec_exponent = 0;
        out->data = r->buf + r->pos; /* empty coefficient */
        out->data_len = 0;
        return 0;
    }
    if (sign != DEC_SIGN_NEG && sign != DEC_SIGN_POS) return -1;
    bool negative = (sign == DEC_SIGN_NEG);
    int64_t adj_exp;
    if (read_dec_exponent(r, negative, &adj_exp) != 0) return -1;

    /* Digit bytes are 1–100 (positive) or their complement (negative); they never
     * collide with the terminator (0x00, or 0xFF when complemented). */
    uint8_t term = negative ? 0xff : 0x00;
    size_t start = r->pos;
    size_t i = r->pos;
    while (i < r->len && r->buf[i] != term) i++;
    if (i >= r->len) return -1;          /* truncated: no terminator */
    if (i == start) return -1;           /* a nonzero decimal must carry digits */
    size_t nbytes = i - start;
    r->pos = i + 1;                       /* consume the terminator */

    /* Unpack base-100 pairs into 0–9 digits in the scratch buffer. */
    uint8_t *digs = r_scratch(r, nbytes * 2);
    if (!digs) return -1;
    size_t w = 0;
    for (size_t k = 0; k < nbytes; k++) {
        uint8_t raw = r->buf[start + k];
        uint8_t pair = (uint8_t)((negative ? (uint8_t)~raw : raw) - 1);
        if (pair > 99) return -1; /* invalid base-100 byte */
        digs[w++] = (uint8_t)(pair / 10);
        uint8_t lo = (uint8_t)(pair % 10);
        bool is_last = (k + 1 == nbytes);
        if (!(is_last && lo == 0)) digs[w++] = lo; /* skip only the synthetic pad */
    }

    out->kind = STRUPLE_DECIMAL;
    out->dec_negative = negative;
    /* value = ±coefficient · 10^exponent, exponent = adj_exp − digitCount. */
    out->dec_exponent = adj_exp - (int64_t)w;
    out->data = digs;
    out->data_len = w;
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
        case DECIMAL: return read_decimal(r, out) == 0 ? 1 : -1;
        case TIMESTAMP: return read_timestamp(r, out) == 0 ? 1 : -1;
        case UUID: {
            const uint8_t *p = take(r, 16);
            if (!p) return -1;
            out->kind = STRUPLE_UUID;
            out->data = p;
            out->data_len = 16;
            return 1;
        }
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
        case STRUPLE_DECIMAL:
            struple_append_decimal(w, e->dec_negative, e->data, e->data_len, (int32_t)e->dec_exponent);
            break;
        case STRUPLE_TIMESTAMP: struple_append_timestamp(w, e->int_val); break;
        case STRUPLE_UUID: struple_append_uuid(w, e->data); break;
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
    } else if (t == DECIMAL) {
        if (p >= len) return -1;
        uint8_t sign = buf[p++];
        if (sign == DEC_SIGN_ZERO) {
            /* no further payload */
        } else if (sign == DEC_SIGN_NEG || sign == DEC_SIGN_POS) {
            bool neg = (sign == DEC_SIGN_NEG);
            /* Self-delimiting exponent: one type byte, then its fixed payload. */
            if (p >= len) return -1;
            uint8_t tb = neg ? (uint8_t)~buf[p] : buf[p];
            p++;
            if (tb != INT_ZERO) {
                if ((tb >= 0x10 && tb <= 0x1f) || (tb >= 0x21 && tb <= 0x30)) {
                    size_t en = (tb < INT_ZERO) ? (size_t)(INT_ZERO - tb) : (size_t)(tb - INT_ZERO);
                    p += en;
                } else {
                    return -1;
                }
            }
            /* Scan the digit region to the terminator (0x00, or 0xFF for negatives). */
            uint8_t term = neg ? 0xff : 0x00;
            while (p < len && buf[p] != term) p++;
            if (p >= len) return -1;
            p++; /* consume the terminator */
        } else {
            return -1;
        }
    } else if (t == UUID) {
        p += 16;
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
bool struple_view_is_decimal(struple_view v) { return struple_view_head_type(v) == DECIMAL; }
bool struple_view_is_number(struple_view v) {
    return struple_view_is_int(v) || struple_view_is_float(v) || struple_view_is_decimal(v);
}
bool struple_view_is_timestamp(struple_view v) { return struple_view_head_type(v) == TIMESTAMP; }
bool struple_view_is_uuid(struple_view v) { return struple_view_head_type(v) == UUID; }
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

/* ------------------------------------------------------------ indexed map */

int struple_indexed_map_init(struple_indexed_map *out, const uint8_t *inner, size_t len) {
    out->entries = NULL;
    out->count = 0;
    struple_reader r;
    struple_reader_init(&r, inner, len);
    struple_indexed_entry *entries = NULL;
    size_t count = 0, cap = 0;
    const uint8_t *kp;
    size_t kl;
    int rc;
    while ((rc = struple_reader_next_view(&r, &kp, &kl)) == 1) {
        const uint8_t *vp;
        size_t vl;
        if (struple_reader_next_view(&r, &vp, &vl) != 1) { /* truncated: key with no value */
            free(entries);
            return -1;
        }
        if (count + 1 > cap) {
            cap = cap ? cap * 2 : 8;
            struple_indexed_entry *ne = (struple_indexed_entry *)realloc(entries, cap * sizeof *ne);
            if (!ne) {
                free(entries);
                return -1;
            }
            entries = ne;
        }
        entries[count].key = kp;
        entries[count].key_len = kl;
        entries[count].value = vp;
        entries[count].value_len = vl;
        count++;
    }
    if (rc < 0) { /* malformed element span */
        free(entries);
        return -1;
    }
    out->entries = entries;
    out->count = count;
    return 0;
}

void struple_indexed_map_free(struple_indexed_map *m) {
    free(m->entries);
    m->entries = NULL;
    m->count = 0;
}

size_t struple_indexed_map_count(const struple_indexed_map *m) {
    return m->count;
}

int struple_indexed_map_at(const struple_indexed_map *m, size_t index, struple_indexed_entry *out) {
    if (index >= m->count) return 0;
    *out = m->entries[index];
    return 1;
}

int struple_indexed_map_find(const struple_indexed_map *m, const uint8_t *key, size_t keylen, size_t *out_index) {
    size_t lo = 0, hi = m->count;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        int c = struple_compare(m->entries[mid].key, m->entries[mid].key_len, key, keylen);
        if (c == 0) {
            *out_index = mid;
            return 1;
        }
        if (c < 0) lo = mid + 1;
        else hi = mid;
    }
    return 0;
}

int struple_indexed_map_get(const struple_indexed_map *m, const uint8_t *key, size_t keylen, struple_view *out) {
    size_t i;
    if (!struple_indexed_map_find(m, key, keylen, &i)) return 0;
    out->bytes = m->entries[i].value;
    out->len = m->entries[i].value_len;
    return 1;
}

/* ------------------------------------------------------------ semantic order */

static int sem_class_rank(struple_kind k) {
    switch (k) {
        case STRUPLE_NIL: return 0;
        case STRUPLE_UNDEF: return 1;
        case STRUPLE_BOOL: return 2;
        case STRUPLE_INT:
        case STRUPLE_BIGINT:
        case STRUPLE_F32:
        case STRUPLE_F64:
        case STRUPLE_DECIMAL: return 3;
        case STRUPLE_TIMESTAMP: return 4;
        case STRUPLE_UUID: return 5;
        case STRUPLE_STRING: return 6;
        case STRUPLE_BYTES: return 7;
        case STRUPLE_ARRAY: return 8;
        case STRUPLE_MAP: return 9;
        case STRUPLE_SET: return 10;
    }
    return 0;
}

static int sem_icmp(int64_t x, int64_t y) { return (x > y) - (x < y); }
static int sem_dcmp(double x, double y) { return (x > y) - (x < y); }
static int sem_sign(double f) { return (f > 0) - (f < 0); }

static int sem_cmp_lex(const uint8_t *a, size_t al, const uint8_t *b, size_t bl) {
    size_t n = al < bl ? al : bl;
    int c = n ? memcmp(a, b, n) : 0;
    if (c) return c < 0 ? -1 : 1;
    return (al > bl) - (al < bl);
}

static int sem_cmp_mag(const uint8_t *a, size_t al, const uint8_t *b, size_t bl) {
    while (al && a[0] == 0) { a++; al--; }
    while (bl && b[0] == 0) { b++; bl--; }
    if (al != bl) return al < bl ? -1 : 1;
    int c = al ? memcmp(a, b, al) : 0;
    return c < 0 ? -1 : (c > 0 ? 1 : 0);
}

/* Decompose finite nonzero |f| into mant * 2^exp. */
static void sem_decompose(double g, uint64_t *mant, int *exp) {
    uint64_t bits;
    memcpy(&bits, &g, 8);
    int raw = (int)((bits >> 52) & 0x7ff);
    uint64_t frac = bits & 0xfffffffffffffULL;
    if (raw == 0) {
        *mant = frac;
        *exp = -1074;
    } else {
        *mant = (1ULL << 52) | frac;
        *exp = raw - 1075;
    }
}

/* src << bits, big-endian; malloc'd (caller frees), NULL on OOM. */
static uint8_t *sem_shl(const uint8_t *src, size_t slen, size_t bits, size_t *outlen) {
    size_t byte_shift = bits / 8;
    int bit_shift = (int)(bits % 8);
    size_t total = slen + 1 + byte_shift;
    uint8_t *out = (uint8_t *)calloc(total, 1);
    if (!out) return NULL;
    unsigned carry = 0;
    for (size_t i = slen; i-- > 0;) {
        unsigned cur = ((unsigned)src[i] << bit_shift) | carry;
        out[i + 1] = (uint8_t)(cur & 0xff);
        carry = cur >> 8;
    }
    out[0] = (uint8_t)carry;
    *outlen = total;
    return out;
}

static int sem_u64_scaled(uint64_t N, uint64_t mant, int exp) {
    if (exp >= 0) {
        if (exp >= 64 || mant > (UINT64_MAX >> exp)) return -1; /* mant<<exp > N */
        uint64_t B = mant << exp;
        return (N > B) - (N < B);
    }
    int s = -exp;
    if (s >= 64 || N > (UINT64_MAX >> s)) return 1; /* N<<s > mant */
    uint64_t A = N << s;
    return (A > mant) - (A < mant);
}

/* compare big-endian magnitude to mant*2^exp: -1/0/1, or -2 on OOM. */
static int sem_mag_scaled(const uint8_t *mag, size_t mlen, uint64_t mant, int exp) {
    uint8_t mb[8];
    for (int i = 0; i < 8; i++) mb[i] = (uint8_t)(mant >> (8 * (7 - i)));
    uint8_t *buf;
    size_t bl;
    int r;
    if (exp >= 0) {
        buf = sem_shl(mb, 8, (size_t)exp, &bl);
        if (!buf) return -2;
        r = sem_cmp_mag(mag, mlen, buf, bl);
    } else {
        buf = sem_shl(mag, mlen, (size_t)(-exp), &bl);
        if (!buf) return -2;
        r = sem_cmp_mag(buf, bl, mb, 8);
    }
    free(buf);
    return r;
}

static int sem_i64_float(int64_t value, double f) {
    if (value == 0) return -sem_sign(f);
    if (value >= -(1LL << 53) && value <= (1LL << 53)) return sem_dcmp((double)value, f);
    int si = value > 0 ? 1 : -1;
    int sf = sem_sign(f);
    if (si != sf) return (si > sf) - (si < sf);
    uint64_t N = value < 0 ? (~(uint64_t)value + 1) : (uint64_t)value;
    uint64_t mant;
    int exp;
    sem_decompose(fabs(f), &mant, &exp);
    int c = sem_u64_scaled(N, mant, exp);
    return si < 0 ? -c : c;
}

static int sem_bigint_float(bool neg, const uint8_t *mag, size_t mlen, double f, int *err) {
    int si = neg ? -1 : 1;
    int sf = sem_sign(f);
    if (si != sf) return (si > sf) - (si < sf);
    uint64_t mant;
    int exp;
    sem_decompose(fabs(f), &mant, &exp);
    int c = sem_mag_scaled(mag, mlen, mant, exp);
    if (c == -2) {
        *err = 1;
        return 0;
    }
    return si < 0 ? -c : c;
}

static bool sem_is_int(const struple_element *e) {
    return e->kind == STRUPLE_INT || e->kind == STRUPLE_BIGINT;
}
static double sem_float(const struple_element *e) {
    return e->kind == STRUPLE_F32 ? (double)e->f32_val : e->f64_val;
}
static int sem_int_sign(const struple_element *e) {
    if (e->kind == STRUPLE_INT) return (e->int_val > 0) - (e->int_val < 0);
    return e->big_negative ? -1 : 1;
}
static int sem_num_class(const struple_element *e) {
    if (sem_is_int(e) || e->kind == STRUPLE_DECIMAL) return 1; /* always finite */
    double f = sem_float(e);
    if (isnan(f)) return 3;
    if (isinf(f)) return f > 0 ? 2 : 0;
    return 1;
}

static int sem_int_finite(const struple_element *e, double f, int *err) {
    if (e->kind == STRUPLE_INT) return sem_i64_float(e->int_val, f);
    return sem_bigint_float(e->big_negative, e->data, e->data_len, f, err);
}

static int sem_int_int(const struple_element *a, const struple_element *b) {
    if (a->kind == STRUPLE_INT && b->kind == STRUPLE_INT) return sem_icmp(a->int_val, b->int_val);
    int sa = sem_int_sign(a), sb = sem_int_sign(b);
    if (sa != sb) return (sa > sb) - (sa < sb);
    bool ab = a->kind == STRUPLE_BIGINT, bb = b->kind == STRUPLE_BIGINT;
    if (ab != bb) {
        if (sa > 0) return ab ? 1 : -1;
        return ab ? -1 : 1;
    }
    int c = sem_cmp_mag(a->data, a->data_len, b->data, b->data_len);
    return sa < 0 ? -c : c;
}

/* ------------------------------------------------------ decimal vs the rest */

/* An exact base-10 value: sign · mag · 10^exp10 (mag big-endian, malloc'd; an
 * empty/NULL mag means 0). All helpers below work in big-endian base-256 bytes,
 * mirroring the big-int-vs-float path; no 128-bit type or bignum library. */
typedef struct {
    int sign;       /* -1, 0, +1 */
    uint8_t *mag;   /* big-endian magnitude, malloc'd (may be NULL when sign == 0) */
    size_t mlen;
    int64_t exp10;
} sem_b10;

/* Decimal digits (each 0–9, MSD first) -> big-endian base-256 magnitude. */
static uint8_t *sem_dec_digits_to_mag(const uint8_t *digits, size_t n, size_t *outlen) {
    uint8_t *buf = NULL;
    size_t len = 0, cap = 0;
    for (size_t k = 0; k < n; k++) {
        unsigned carry = digits[k]; /* 0–9 */
        for (size_t i = len; i-- > 0;) {
            unsigned v = (unsigned)buf[i] * 10 + carry;
            buf[i] = (uint8_t)(v & 0xff);
            carry = v >> 8;
        }
        while (carry) {
            if (len + 1 > cap) {
                cap = cap ? cap * 2 : 16;
                uint8_t *nb = (uint8_t *)realloc(buf, cap);
                if (!nb) { free(buf); return NULL; }
                buf = nb;
            }
            memmove(buf + 1, buf, len);
            buf[0] = (uint8_t)(carry & 0xff);
            len++;
            carry >>= 8;
        }
    }
    *outlen = len;
    /* len may be 0 only for an all-zero digit string, which never reaches here. */
    return buf ? buf : (uint8_t *)calloc(1, 1); /* non-NULL even when len == 0 */
}

/* mag · m (small m) -> new big-endian bytes (trimmed); NULL on OOM. */
static uint8_t *sem_mul_small(const uint8_t *mag, size_t mlen, uint16_t m, size_t *outlen) {
    size_t cap = mlen + 4;
    uint8_t *buf = (uint8_t *)calloc(cap ? cap : 1, 1);
    if (!buf) return NULL;
    size_t off = 4; /* leave room at the front for carry growth */
    memcpy(buf + off, mag, mlen);
    size_t len = mlen;
    uint32_t carry = 0;
    for (size_t i = off + len; i-- > off;) {
        uint32_t v = (uint32_t)buf[i] * m + carry;
        buf[i] = (uint8_t)(v & 0xff);
        carry = v >> 8;
    }
    while (carry && off > 0) {
        off--;
        buf[off] = (uint8_t)(carry & 0xff);
        len++;
        carry >>= 8;
    }
    /* Shift the result down to the buffer start. */
    if (off > 0) memmove(buf, buf + off, len);
    *outlen = len;
    return buf;
}

/* mag · base^k -> new big-endian bytes; NULL on OOM. */
static uint8_t *sem_mul_pow(const uint8_t *mag, size_t mlen, uint16_t base, size_t k, size_t *outlen) {
    uint8_t *cur = (uint8_t *)malloc(mlen ? mlen : 1);
    if (!cur) return NULL;
    memcpy(cur, mag, mlen);
    size_t curlen = mlen;
    for (size_t j = 0; j < k; j++) {
        size_t nl;
        uint8_t *nx = sem_mul_small(cur, curlen, base, &nl);
        free(cur);
        if (!nx) return NULL;
        cur = nx;
        curlen = nl;
    }
    *outlen = curlen;
    return cur;
}

static bool sem_is_exact(const struple_element *e) {
    return e->kind == STRUPLE_INT || e->kind == STRUPLE_BIGINT || e->kind == STRUPLE_DECIMAL;
}

/* Decompose an int / big-int / decimal into its exact base-10 value (allocates
 * mag). Returns 0 on success, -1 on OOM. */
static int sem_num_to_b10(const struple_element *e, sem_b10 *out) {
    out->mag = NULL;
    out->mlen = 0;
    out->exp10 = 0;
    if (e->kind == STRUPLE_INT) {
        int64_t v = e->int_val;
        if (v == 0) {
            out->sign = 0;
            return 0;
        }
        uint64_t N = v < 0 ? (~(uint64_t)v + 1) : (uint64_t)v;
        uint8_t buf[8];
        size_t n = u64_to_be(N, buf);
        out->mag = (uint8_t *)malloc(n ? n : 1);
        if (!out->mag) return -1;
        memcpy(out->mag, buf, n);
        out->mlen = n;
        out->sign = v < 0 ? -1 : 1;
        return 0;
    }
    if (e->kind == STRUPLE_BIGINT) {
        out->mag = (uint8_t *)malloc(e->data_len ? e->data_len : 1);
        if (!out->mag) return -1;
        memcpy(out->mag, e->data, e->data_len);
        out->mlen = e->data_len;
        out->sign = e->big_negative ? -1 : 1;
        return 0;
    }
    /* decimal */
    if (e->data_len == 0) { /* canonical zero */
        out->sign = 0;
        return 0;
    }
    size_t ml;
    uint8_t *mag = sem_dec_digits_to_mag(e->data, e->data_len, &ml);
    if (!mag) return -1;
    out->mag = mag;
    out->mlen = ml;
    out->sign = e->dec_negative ? -1 : 1;
    out->exp10 = e->dec_exponent;
    return 0;
}

/* Compare two same-sign, nonzero base-10 magnitudes (mag · 10^exp10). Returns
 * -1/0/1, or -2 on OOM. */
static int sem_b10_mag(const sem_b10 *a, const sem_b10 *b) {
    int64_t e = a->exp10 < b->exp10 ? a->exp10 : b->exp10;
    size_t sal, sbl;
    uint8_t *sa = sem_mul_pow(a->mag, a->mlen, 10, (size_t)(a->exp10 - e), &sal);
    if (!sa) return -2;
    uint8_t *sb = sem_mul_pow(b->mag, b->mlen, 10, (size_t)(b->exp10 - e), &sbl);
    if (!sb) { free(sa); return -2; }
    int c = sem_cmp_mag(sa, sal, sb, sbl);
    free(sa);
    free(sb);
    return c;
}

/* Compare mag · 10^exp10 to mant · 2^e2 (both > 0). Splits 10^exp10 into
 * 2^exp10 · 5^exp10 and scales both sides up to integers. -1/0/1, or -2 on OOM. */
static int sem_b10_mag_to_float(const uint8_t *mag, size_t mlen, int64_t exp10,
                                uint64_t mant, int e2) {
    int64_t a_pow2 = 0;
    if (-exp10 > a_pow2) a_pow2 = -exp10;
    if (-(int64_t)e2 > a_pow2) a_pow2 = -(int64_t)e2;
    int64_t b_pow5 = -exp10 > 0 ? -exp10 : 0;

    /* LHS' = mag · 5^(exp10 + b_pow5) · 2^(exp10 + a_pow2) */
    size_t lhs5l;
    uint8_t *lhs5 = sem_mul_pow(mag, mlen, 5, (size_t)(exp10 + b_pow5), &lhs5l);
    if (!lhs5) return -2;
    size_t lhsl;
    uint8_t *lhs = sem_shl(lhs5, lhs5l, (size_t)(exp10 + a_pow2), &lhsl);
    free(lhs5);
    if (!lhs) return -2;

    /* RHS' = mant · 5^(b_pow5) · 2^(e2 + a_pow2) */
    uint8_t mb[8];
    for (int i = 0; i < 8; i++) mb[i] = (uint8_t)(mant >> (8 * (7 - i)));
    size_t rhs5l;
    uint8_t *rhs5 = sem_mul_pow(mb, 8, 5, (size_t)b_pow5, &rhs5l);
    if (!rhs5) { free(lhs); return -2; }
    size_t rhsl;
    uint8_t *rhs = sem_shl(rhs5, rhs5l, (size_t)((int64_t)e2 + a_pow2), &rhsl);
    free(rhs5);
    if (!rhs) { free(lhs); return -2; }

    int c = sem_cmp_mag(lhs, lhsl, rhs, rhsl);
    free(lhs);
    free(rhs);
    return c;
}

/* Compare an exact base-10 value v to a finite float f. -1/0/1, or -2 on OOM. */
static int sem_b10_float(const sem_b10 *v, double f) {
    int sf = sem_sign(f);
    if (v->sign != sf) return (v->sign > sf) - (v->sign < sf);
    if (v->sign == 0) return 0; /* both zero */
    uint64_t mant;
    int exp;
    sem_decompose(fabs(f), &mant, &exp);
    int c = sem_b10_mag_to_float(v->mag, v->mlen, v->exp10, mant, exp);
    if (c == -2) return -2;
    return v->sign < 0 ? -c : c;
}

/* Compare when at least one operand is a decimal. Returns -1/0/1; sets *err on OOM. */
static int sem_with_decimal(const struple_element *a, const struple_element *b, int *err) {
    if (sem_is_exact(a) && sem_is_exact(b)) {
        sem_b10 va, vb;
        if (sem_num_to_b10(a, &va) != 0) { *err = 1; return 0; }
        if (sem_num_to_b10(b, &vb) != 0) { *err = 1; free(va.mag); return 0; }
        int result;
        if (va.sign != vb.sign) {
            result = (va.sign > vb.sign) - (va.sign < vb.sign);
        } else if (va.sign == 0) {
            result = 0;
        } else {
            int c = sem_b10_mag(&va, &vb);
            if (c == -2) { *err = 1; result = 0; }
            else result = va.sign < 0 ? -c : c;
        }
        free(va.mag);
        free(vb.mag);
        return result;
    }
    /* exactly one side is a finite float */
    if (sem_is_exact(a)) {
        sem_b10 va;
        if (sem_num_to_b10(a, &va) != 0) { *err = 1; return 0; }
        int c = sem_b10_float(&va, sem_float(b));
        free(va.mag);
        if (c == -2) { *err = 1; return 0; }
        return c;
    }
    sem_b10 vb;
    if (sem_num_to_b10(b, &vb) != 0) { *err = 1; return 0; }
    int c = sem_b10_float(&vb, sem_float(a));
    free(vb.mag);
    if (c == -2) { *err = 1; return 0; }
    return -c;
}

static int sem_numbers(const struple_element *a, const struple_element *b, int *err) {
    int ca = sem_num_class(a), cb = sem_num_class(b);
    if (ca != cb) return (ca > cb) - (ca < cb);
    if (ca != 1) return 0;
    if (a->kind == STRUPLE_DECIMAL || b->kind == STRUPLE_DECIMAL) return sem_with_decimal(a, b, err);
    bool ai = sem_is_int(a), bi = sem_is_int(b);
    if (ai && bi) return sem_int_int(a, b);
    if (!ai && !bi) return sem_dcmp(sem_float(a), sem_float(b));
    if (ai) return sem_int_finite(a, sem_float(b), err);
    return -sem_int_finite(b, sem_float(a), err);
}

static int sem_order_impl(const uint8_t *a, size_t alen, const uint8_t *b, size_t blen, int *order, int *err);

static int sem_elements(const struple_element *a, const struple_element *b, int *err) {
    int ra = sem_class_rank(a->kind), rb = sem_class_rank(b->kind);
    if (ra != rb) return (ra > rb) - (ra < rb);
    switch (a->kind) {
        case STRUPLE_NIL:
        case STRUPLE_UNDEF: return 0;
        case STRUPLE_BOOL: return (int)a->bool_val - (int)b->bool_val;
        case STRUPLE_INT:
        case STRUPLE_BIGINT:
        case STRUPLE_F32:
        case STRUPLE_F64:
        case STRUPLE_DECIMAL: return sem_numbers(a, b, err);
        case STRUPLE_TIMESTAMP: return sem_icmp(a->int_val, b->int_val);
        case STRUPLE_UUID: return sem_cmp_lex(a->data, 16, b->data, 16);
        case STRUPLE_STRING:
        case STRUPLE_BYTES: return sem_cmp_lex(a->data, a->data_len, b->data, b->data_len);
        case STRUPLE_ARRAY:
        case STRUPLE_MAP:
        case STRUPLE_SET: {
            int ord = 0;
            sem_order_impl(a->data, a->data_len, b->data, b->data_len, &ord, err);
            return ord;
        }
    }
    return 0;
}

static int sem_order_impl(const uint8_t *a, size_t alen, const uint8_t *b, size_t blen, int *order, int *err) {
    struple_reader ra, rb;
    struple_reader_init(&ra, a, alen);
    struple_reader_init(&rb, b, blen);
    struple_element ea, eb;
    *order = 0;
    for (;;) {
        int sa = struple_reader_next(&ra, &ea);
        int sb = struple_reader_next(&rb, &eb);
        if (sa < 0 || sb < 0) { *err = 1; break; }
        if (sa == 0 && sb == 0) { *order = 0; break; }
        if (sa == 0) { *order = -1; break; }
        if (sb == 0) { *order = 1; break; }
        int c = sem_elements(&ea, &eb, err);
        if (*err) break;
        if (c != 0) { *order = c < 0 ? -1 : 1; break; }
    }
    struple_reader_free(&ra);
    struple_reader_free(&rb);
    return *err ? -1 : 0;
}

int struple_semantic_order(const uint8_t *a, size_t alen, const uint8_t *b, size_t blen, int *order) {
    int err = 0;
    int ord = 0;
    sem_order_impl(a, alen, b, blen, &ord, &err);
    if (err) return -1;
    *order = ord;
    return 0;
}
