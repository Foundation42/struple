/* JSON <-> struple, mirroring the Zig reference. Self-contained. */
#include "struple.h"
#include "struple_json.h"

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------- JSON parser */

typedef struct {
    const char *b;
    size_t i, n;
} P;

static void skip_ws(P *p) {
    while (p->i < p->n) {
        char c = p->b[p->i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') p->i++;
        else break;
    }
}

static bool lit(P *p, const char *s) {
    size_t l = strlen(s);
    if (p->i + l <= p->n && memcmp(p->b + p->i, s, l) == 0) {
        p->i += l;
        return true;
    }
    return false;
}

static int hex4(P *p, unsigned *out) {
    if (p->i + 4 > p->n) return -1;
    unsigned v = 0;
    for (int k = 0; k < 4; k++) {
        char c = p->b[p->i++];
        v <<= 4;
        if (c >= '0' && c <= '9') v |= (unsigned)(c - '0');
        else if (c >= 'a' && c <= 'f') v |= (unsigned)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v |= (unsigned)(c - 'A' + 10);
        else return -1;
    }
    *out = v;
    return 0;
}

static int utf8_encode(unsigned cp, char *out) {
    if (cp < 0x80) {
        out[0] = (char)cp;
        return 1;
    }
    if (cp < 0x800) {
        out[0] = (char)(0xc0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3f));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = (char)(0xe0 | (cp >> 12));
        out[1] = (char)(0x80 | ((cp >> 6) & 0x3f));
        out[2] = (char)(0x80 | (cp & 0x3f));
        return 3;
    }
    out[0] = (char)(0xf0 | (cp >> 18));
    out[1] = (char)(0x80 | ((cp >> 12) & 0x3f));
    out[2] = (char)(0x80 | ((cp >> 6) & 0x3f));
    out[3] = (char)(0x80 | (cp & 0x3f));
    return 4;
}

static char *parse_string_raw(P *p) {
    p->i++; /* opening quote */
    char *buf = NULL;
    size_t len = 0, cap = 0;
#define ENSURE(extra)                                       \
    do {                                                    \
        if (len + (extra) > cap) {                          \
            cap = cap ? cap * 2 : 16;                        \
            while (cap < len + (extra)) cap *= 2;            \
            buf = (char *)realloc(buf, cap);                \
        }                                                   \
    } while (0)
    while (p->i < p->n) {
        unsigned char c = (unsigned char)p->b[p->i++];
        if (c == '"') {
            ENSURE(1);
            buf[len] = 0;
            return buf;
        }
        if (c == '\\') {
            if (p->i >= p->n) {
                free(buf);
                return NULL;
            }
            char e = p->b[p->i++];
            char ch = 0;
            switch (e) {
                case '"': ch = '"'; break;
                case '\\': ch = '\\'; break;
                case '/': ch = '/'; break;
                case 'n': ch = '\n'; break;
                case 't': ch = '\t'; break;
                case 'r': ch = '\r'; break;
                case 'b': ch = 0x08; break;
                case 'f': ch = 0x0c; break;
                case 'u': {
                    unsigned cp;
                    if (hex4(p, &cp) != 0) {
                        free(buf);
                        return NULL;
                    }
                    if (cp >= 0xd800 && cp <= 0xdbff) {
                        /* High surrogate: MUST be immediately followed by a
                         * \uXXXX low surrogate (0xdc00–0xdfff). A high with no
                         * following escape, or one whose escape is not a low
                         * surrogate, is invalid Unicode — reject (Item 4). */
                        if (p->i + 1 < p->n && p->b[p->i] == '\\' && p->b[p->i + 1] == 'u') {
                            p->i += 2;
                            unsigned lo;
                            if (hex4(p, &lo) != 0) {
                                free(buf);
                                return NULL;
                            }
                            if (lo < 0xdc00 || lo > 0xdfff) {
                                free(buf);
                                return NULL;
                            }
                            cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                        } else {
                            free(buf);
                            return NULL;
                        }
                    } else if (cp >= 0xdc00 && cp <= 0xdfff) {
                        /* Lone low surrogate with no preceding high — invalid
                         * Unicode; reject (Item 4). */
                        free(buf);
                        return NULL;
                    }
                    char u8[4];
                    int ul = utf8_encode(cp, u8);
                    ENSURE((size_t)ul);
                    for (int k = 0; k < ul; k++) buf[len++] = u8[k];
                    continue;
                }
                default: free(buf); return NULL;
            }
            ENSURE(1);
            buf[len++] = ch;
            continue;
        }
        ENSURE(1);
        buf[len++] = (char)c;
    }
    free(buf);
    return NULL;
#undef ENSURE
}

static int parse_value(P *p, sj_value *out, int depth);

static void free_internals(sj_value *v) {
    switch (v->kind) {
        case SJ_STRING:
        case SJ_INT:
            free(v->str);
            break;
        case SJ_ARRAY:
            for (size_t i = 0; i < v->count; i++) free_internals(&v->items[i]);
            free(v->items);
            break;
        case SJ_OBJECT:
            for (size_t i = 0; i < v->pairs; i++) {
                free(v->keys[i]);
                free_internals(&v->vals[i]);
            }
            free(v->keys);
            free(v->vals);
            break;
        default:
            break;
    }
}

static int parse_number(P *p, sj_value *out) {
    size_t start = p->i;
    if (p->b[p->i] == '-') p->i++;
    size_t int_start = p->i;
    while (p->i < p->n && p->b[p->i] >= '0' && p->b[p->i] <= '9') p->i++;
    /* A JSON number must have at least one integer digit; a bare sign ("-") or
     * a sign followed by a non-digit token (e.g. "-Infinity") is rejected here
     * rather than coerced to 0 (Item 4). */
    if (p->i == int_start) return -1;
    bool is_float = false;
    if (p->i < p->n && p->b[p->i] == '.') {
        is_float = true;
        p->i++;
        while (p->i < p->n && p->b[p->i] >= '0' && p->b[p->i] <= '9') p->i++;
    }
    if (p->i < p->n && (p->b[p->i] == 'e' || p->b[p->i] == 'E')) {
        is_float = true;
        p->i++;
        if (p->i < p->n && (p->b[p->i] == '+' || p->b[p->i] == '-')) p->i++;
        while (p->i < p->n && p->b[p->i] >= '0' && p->b[p->i] <= '9') p->i++;
    }
    size_t tlen = p->i - start;
    char *tok = (char *)malloc(tlen + 1);
    memcpy(tok, p->b + start, tlen);
    tok[tlen] = 0;
    if (is_float) {
        double d = strtod(tok, NULL);
        free(tok);
        /* A number that overflows f64 to ±infinity (e.g. 1e999) must be
         * rejected, not encoded as an infinity (Item 4). */
        if (!isfinite(d)) return -1;
        out->kind = SJ_FLOAT;
        out->float_val = d;
    } else {
        out->kind = SJ_INT;
        out->str = tok;
    }
    return 0;
}

static int parse_array(P *p, sj_value *out, int depth) {
    /* `depth` is this array's nesting level (1 for a top-level array). Reject
     * hostile deep nesting before recursing, so the parse aborts instead of
     * overflowing the stack (Item 5). */
    if (depth > STRUPLE_MAX_DEPTH) return -1;
    p->i++; /* [ */
    sj_value *items = NULL;
    size_t count = 0, cap = 0;
    skip_ws(p);
    if (p->i < p->n && p->b[p->i] == ']') {
        p->i++;
        out->kind = SJ_ARRAY;
        return 0;
    }
    for (;;) {
        if (count + 1 > cap) {
            cap = cap ? cap * 2 : 4;
            items = (sj_value *)realloc(items, cap * sizeof(sj_value));
        }
        if (parse_value(p, &items[count], depth) != 0) goto fail;
        count++;
        skip_ws(p);
        if (p->i >= p->n) goto fail;
        char c = p->b[p->i++];
        if (c == ',') continue;
        if (c == ']') break;
        goto fail;
    }
    out->kind = SJ_ARRAY;
    out->items = items;
    out->count = count;
    return 0;
fail:
    for (size_t i = 0; i < count; i++) free_internals(&items[i]);
    free(items);
    return -1;
}

static int parse_object(P *p, sj_value *out, int depth) {
    if (depth > STRUPLE_MAX_DEPTH) return -1;
    p->i++; /* { */
    char **keys = NULL;
    sj_value *vals = NULL;
    size_t count = 0, cap = 0;
    skip_ws(p);
    if (p->i < p->n && p->b[p->i] == '}') {
        p->i++;
        out->kind = SJ_OBJECT;
        return 0;
    }
    for (;;) {
        skip_ws(p);
        if (p->i >= p->n || p->b[p->i] != '"') goto fail;
        char *key = parse_string_raw(p);
        if (!key) goto fail;
        /* A struple map is canonical and cannot hold two entries for one key.
         * Reject an object with a duplicate key at this nesting level (Item 4). */
        for (size_t k = 0; k < count; k++) {
            if (strcmp(keys[k], key) == 0) {
                free(key);
                goto fail;
            }
        }
        skip_ws(p);
        if (p->i >= p->n || p->b[p->i] != ':') {
            free(key);
            goto fail;
        }
        p->i++;
        if (count + 1 > cap) {
            cap = cap ? cap * 2 : 4;
            keys = (char **)realloc(keys, cap * sizeof(char *));
            vals = (sj_value *)realloc(vals, cap * sizeof(sj_value));
        }
        keys[count] = key;
        if (parse_value(p, &vals[count], depth) != 0) {
            free(key);
            goto fail;
        }
        count++;
        skip_ws(p);
        if (p->i >= p->n) goto fail;
        char c = p->b[p->i++];
        if (c == ',') continue;
        if (c == '}') break;
        goto fail;
    }
    out->kind = SJ_OBJECT;
    out->keys = keys;
    out->vals = vals;
    out->pairs = count;
    return 0;
fail:
    for (size_t i = 0; i < count; i++) {
        free(keys[i]);
        free_internals(&vals[i]);
    }
    free(keys);
    free(vals);
    return -1;
}

static int parse_value(P *p, sj_value *out, int depth) {
    memset(out, 0, sizeof *out);
    skip_ws(p);
    if (p->i >= p->n) return -1;
    char c = p->b[p->i];
    if (c == 'n') return lit(p, "null") ? (out->kind = SJ_NULL, 0) : -1;
    if (c == 't') return lit(p, "true") ? (out->kind = SJ_BOOL, out->bool_val = true, 0) : -1;
    if (c == 'f') return lit(p, "false") ? (out->kind = SJ_BOOL, out->bool_val = false, 0) : -1;
    if (c == '"') {
        char *s = parse_string_raw(p);
        if (!s) return -1;
        out->kind = SJ_STRING;
        out->str = s;
        return 0;
    }
    /* Descending into a container: its nesting level is depth + 1. */
    if (c == '[') return parse_array(p, out, depth + 1);
    if (c == '{') return parse_object(p, out, depth + 1);
    if (c == '-' || (c >= '0' && c <= '9')) return parse_number(p, out);
    return -1;
}

sj_value *struple_json_parse(const char *text, size_t len) {
    P p = {text, 0, len};
    sj_value *v = (sj_value *)malloc(sizeof(sj_value));
    if (parse_value(&p, v, 0) != 0) {
        free(v);
        return NULL;
    }
    skip_ws(&p);
    if (p.i != p.n) {
        struple_json_free(v);
        return NULL;
    }
    return v;
}

void struple_json_free(sj_value *v) {
    if (!v) return;
    free_internals(v);
    free(v);
}

/* ------------------------------------------- arbitrary-precision decimal <-> */

static void decimal_to_magnitude(const char *digits, size_t n, uint8_t **out, size_t *out_len) {
    uint8_t *buf = NULL;
    size_t len = 0, cap = 0;
    for (size_t k = 0; k < n; k++) {
        if (digits[k] < '0' || digits[k] > '9') continue;
        unsigned carry = (unsigned)(digits[k] - '0');
        for (size_t i = len; i-- > 0;) {
            unsigned v = (unsigned)buf[i] * 10 + carry;
            buf[i] = (uint8_t)(v & 0xff);
            carry = v >> 8;
        }
        while (carry) {
            if (len + 1 > cap) {
                cap = cap ? cap * 2 : 16;
                buf = (uint8_t *)realloc(buf, cap);
            }
            memmove(buf + 1, buf, len);
            buf[0] = (uint8_t)(carry & 0xff);
            len++;
            carry >>= 8;
        }
    }
    *out = buf;
    *out_len = len;
}

static char *magnitude_to_decimal(const uint8_t *mag, size_t len) {
    if (len == 0) {
        char *z = (char *)malloc(2);
        z[0] = '0';
        z[1] = 0;
        return z;
    }
    uint8_t *work = (uint8_t *)malloc(len);
    memcpy(work, mag, len);
    char *digits = NULL;
    size_t dn = 0, dcap = 0;
    size_t start = 0;
    while (start < len) {
        unsigned rem = 0;
        for (size_t i = start; i < len; i++) {
            unsigned cur = (rem << 8) | work[i];
            work[i] = (uint8_t)(cur / 10);
            rem = cur % 10;
        }
        if (dn + 1 > dcap) {
            dcap = dcap ? dcap * 2 : 32;
            digits = (char *)realloc(digits, dcap);
        }
        digits[dn++] = (char)('0' + rem);
        while (start < len && work[start] == 0) start++;
    }
    free(work);
    char *out = (char *)malloc(dn + 1);
    for (size_t i = 0; i < dn; i++) out[i] = digits[dn - 1 - i];
    out[dn] = 0;
    free(digits);
    return out;
}

/* ------------------------------------------------------------------ from_json */

static void encode_int_text(struple_writer *w, const char *s) {
    char *end;
    errno = 0;
    long long ll = strtoll(s, &end, 10);
    if (errno == 0 && *end == 0) {
        struple_append_int(w, (int64_t)ll);
        return;
    }
    if (s[0] != '-') {
        errno = 0;
        unsigned long long ull = strtoull(s, &end, 10);
        if (errno == 0 && *end == 0) {
            struple_append_uint(w, (uint64_t)ull);
            return;
        }
    }
    /* arbitrary-precision big integer */
    bool negative = (s[0] == '-');
    const char *digits = negative ? s + 1 : s;
    uint8_t *mag;
    size_t mlen;
    decimal_to_magnitude(digits, strlen(digits), &mag, &mlen);
    struple_append_big_int(w, negative, mag, mlen);
    free(mag);
}

static void encode_json(struple_writer *w, const sj_value *v) {
    switch (v->kind) {
        case SJ_NULL: struple_append_nil(w); break;
        case SJ_BOOL: struple_append_bool(w, v->bool_val); break;
        case SJ_INT: encode_int_text(w, v->str); break;
        case SJ_FLOAT: struple_append_f64(w, v->float_val); break;
        case SJ_STRING: struple_append_string(w, v->str, strlen(v->str)); break;
        case SJ_ARRAY: {
            struple_writer child;
            struple_writer_init(&child);
            for (size_t i = 0; i < v->count; i++) encode_json(&child, &v->items[i]);
            struple_append_array(w, child.data, child.len);
            struple_writer_free(&child);
            break;
        }
        case SJ_OBJECT: {
            size_t np = v->pairs;
            struple_writer *kw = (struple_writer *)calloc(np ? np : 1, sizeof(struple_writer));
            struple_writer *vw = (struple_writer *)calloc(np ? np : 1, sizeof(struple_writer));
            struple_kv *entries = (struple_kv *)malloc((np ? np : 1) * sizeof(struple_kv));
            for (size_t i = 0; i < np; i++) {
                struple_writer_init(&kw[i]);
                struple_append_string(&kw[i], v->keys[i], strlen(v->keys[i]));
                struple_writer_init(&vw[i]);
                encode_json(&vw[i], &v->vals[i]);
                entries[i].key.ptr = kw[i].data;
                entries[i].key.len = kw[i].len;
                entries[i].value.ptr = vw[i].data;
                entries[i].value.len = vw[i].len;
            }
            struple_append_map(w, entries, np);
            for (size_t i = 0; i < np; i++) {
                struple_writer_free(&kw[i]);
                struple_writer_free(&vw[i]);
            }
            free(kw);
            free(vw);
            free(entries);
            break;
        }
    }
}

int struple_from_json(const char *text, size_t len, struple_writer *out) {
    sj_value *v = struple_json_parse(text, len);
    if (!v) return -1;
    encode_json(out, v);
    struple_json_free(v);
    return 0;
}

/* ------------------------------------------------------------------ to_json */

static void jw(struple_writer *w, const char *s) {
    struple_writer_append(w, (const uint8_t *)s, strlen(s));
}
static void jc(struple_writer *w, char c) {
    struple_writer_append(w, (const uint8_t *)&c, 1);
}

static void render_string(struple_writer *out, const uint8_t *s, size_t len) {
    jc(out, '"');
    for (size_t i = 0; i < len; i++) {
        uint8_t c = s[i];
        switch (c) {
            case '"': jw(out, "\\\""); break;
            case '\\': jw(out, "\\\\"); break;
            case '\n': jw(out, "\\n"); break;
            case '\r': jw(out, "\\r"); break;
            case '\t': jw(out, "\\t"); break;
            case 0x08: jw(out, "\\b"); break;
            case 0x0c: jw(out, "\\f"); break;
            default:
                if (c < 0x20) {
                    char u[8];
                    snprintf(u, sizeof u, "\\u%04x", c);
                    jw(out, u);
                } else {
                    jc(out, (char)c);
                }
        }
    }
    jc(out, '"');
}

/* Emit shortest significant `digits` (k of them) as ECMAScript Number::toString,
 * where `n` is the integer-part digit count (10^(n-1) <= |value| < 10^n).
 * Mirrors the Zig reference `writeEcmaDigits`. */
static void write_ecma_digits(struple_writer *out, const char *digits, int k, int n) {
    if (n >= 1 && n <= 21) {
        if (k <= n) { /* integer with trailing zeros */
            struple_writer_append(out, (const uint8_t *)digits, (size_t)k);
            for (int z = 0; z < n - k; z++) jc(out, '0');
        } else { /* decimal point inside the digits */
            struple_writer_append(out, (const uint8_t *)digits, (size_t)n);
            jc(out, '.');
            struple_writer_append(out, (const uint8_t *)(digits + n), (size_t)(k - n));
        }
    } else if (n <= 0 && n > -6) { /* 0.00…digits */
        jw(out, "0.");
        for (int z = 0; z < -n; z++) jc(out, '0');
        struple_writer_append(out, (const uint8_t *)digits, (size_t)k);
    } else { /* exponential: d[.ddd]e±(n-1) */
        jc(out, digits[0]);
        if (k > 1) {
            jc(out, '.');
            struple_writer_append(out, (const uint8_t *)(digits + 1), (size_t)(k - 1));
        }
        jc(out, 'e');
        int e = n - 1;
        jc(out, e >= 0 ? '+' : '-');
        char eb[16];
        snprintf(eb, sizeof eb, "%d", e >= 0 ? e : -e);
        jw(out, eb);
    }
}

/* Render a float as ECMAScript `Number::toString`: the shortest decimal that
 * round-trips to the same f64, formatted per the ECMA-262 fixed/exponential
 * rules (Item 3). f32 values are widened to f64 by the caller before formatting.
 * Mirrors the Zig reference `writeFloat`. */
static void render_float(struple_writer *out, double f) {
    if (!isfinite(f)) {
        jw(out, "null"); /* JSON has no inf/nan (matches JSON.stringify) */
        return;
    }
    if (f == 0.0) {
        jc(out, '0'); /* +0.0 and -0.0 both render "0" */
        return;
    }
    /* Find the shortest scientific form that round-trips: [-]d[.ddd]e±XX. This
     * yields the shortest significant digits and the base-10 exponent of the
     * most-significant digit. */
    char tmp[64];
    for (int prec = 0; prec <= 17; prec++) {
        snprintf(tmp, sizeof tmp, "%.*e", prec, f);
        if (strtod(tmp, NULL) == f) break;
    }
    const char *s = tmp;
    if (*s == '-') {
        jc(out, '-');
        s++;
    }
    const char *epos = strchr(s, 'e');
    int exp = atoi(epos + 1);
    /* Collect the significant digits (skip the '.'). */
    char digits[32];
    int k = 0;
    for (const char *c = s; c < epos; c++) {
        if (*c != '.') digits[k++] = *c;
    }
    write_ecma_digits(out, digits, k, exp + 1);
}

static char *base64(const uint8_t *data, size_t len) {
    static const char T[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t olen = ((len + 2) / 3) * 4;
    char *out = (char *)malloc(olen + 1);
    size_t o = 0;
    for (size_t i = 0; i < len; i += 3) {
        unsigned b0 = data[i];
        unsigned b1 = i + 1 < len ? data[i + 1] : 0;
        unsigned b2 = i + 2 < len ? data[i + 2] : 0;
        unsigned n = (b0 << 16) | (b1 << 8) | b2;
        out[o++] = T[(n >> 18) & 63];
        out[o++] = T[(n >> 12) & 63];
        out[o++] = (i + 1 < len) ? T[(n >> 6) & 63] : '=';
        out[o++] = (i + 2 < len) ? T[n & 63] : '=';
    }
    out[o] = 0;
    return out;
}

/* Render a decimal as an exact JSON number literal: plain notation, falling back
 * to scientific (`d1[.d2…dk]e±E`) once plain would pad past the threshold, so a
 * huge (i32-bounded) exponent can't emit gigabytes from a tiny input (Item 2). */
static void render_decimal(struple_writer *out, const struple_element *e) {
    const uint8_t *digs = e->data;
    size_t k = e->data_len;
    if (k == 0) { /* canonical zero */
        jc(out, '0');
        return;
    }
    int64_t kk = (int64_t)k;
    int64_t exp10 = e->dec_exponent; /* value = C · 10^exp10 */
    if (e->dec_negative) jc(out, '-');

    /* Plain notation would pad this many zeros; past the threshold, switch to
     * scientific notation. */
    const int64_t max_plain_pad = 40;
    int64_t pad;
    if (exp10 >= 0) {
        pad = exp10;
    } else {
        int64_t pp = kk + exp10;
        pad = pp > 0 ? 0 : -pp;
    }
    if (pad > max_plain_pad) {
        /* d1[.d2…dk]e±E, where E = exp10 + k − 1 (the power of ten of the MSD).
         * The exponent's sign is ALWAYS emitted (e+/e-) followed by |E|. */
        jc(out, (char)('0' + digs[0]));
        if (k > 1) {
            jc(out, '.');
            for (size_t i = 1; i < k; i++) jc(out, (char)('0' + digs[i]));
        }
        int64_t sci_exp = exp10 + kk - 1;
        jc(out, 'e');
        jc(out, sci_exp >= 0 ? '+' : '-');
        /* |sci_exp| without tripping over INT64_MIN (sci_exp = adj_exp − 1 here,
         * so it stays well inside i32, but stay overflow-safe regardless). */
        uint64_t mag = sci_exp >= 0 ? (uint64_t)sci_exp : (uint64_t)(-(sci_exp + 1)) + 1;
        char tmp[24];
        snprintf(tmp, sizeof tmp, "%llu", (unsigned long long)mag);
        jw(out, tmp);
        return;
    }

    if (exp10 >= 0) {
        for (size_t i = 0; i < k; i++) jc(out, (char)('0' + digs[i]));
        for (int64_t z = 0; z < exp10; z++) jc(out, '0');
        return;
    }
    int64_t point_pos = kk + exp10; /* number of integer-part digits */
    if (point_pos > 0) {
        size_t pp = (size_t)point_pos;
        for (size_t i = 0; i < pp; i++) jc(out, (char)('0' + digs[i]));
        jc(out, '.');
        for (size_t i = pp; i < k; i++) jc(out, (char)('0' + digs[i]));
    } else {
        jw(out, "0.");
        for (int64_t z = point_pos; z < 0; z++) jc(out, '0');
        for (size_t i = 0; i < k; i++) jc(out, (char)('0' + digs[i]));
    }
}

static int render(struple_writer *out, const struple_element *e, int depth);

static int render_array(struple_writer *out, const uint8_t *body, size_t blen, int depth) {
    struple_reader r;
    struple_reader_init(&r, body, blen);
    jc(out, '[');
    struple_element e;
    int rc;
    bool first = true;
    while ((rc = struple_reader_next(&r, &e)) == 1) {
        if (!first) jc(out, ',');
        first = false;
        if (render(out, &e, depth + 1) != 0) {
            struple_reader_free(&r);
            return -1;
        }
    }
    struple_reader_free(&r);
    if (rc < 0) return -1;
    jc(out, ']');
    return 0;
}

static int render_map(struple_writer *out, const uint8_t *body, size_t blen, int depth) {
    struple_reader r;
    struple_reader_init(&r, body, blen);
    jc(out, '{');
    struple_element k, v;
    int rc;
    bool first = true;
    while ((rc = struple_reader_next(&r, &k)) == 1) {
        if (!first) jc(out, ',');
        first = false;
        /* Render the key now: reading the value below reuses the reader's
         * scratch buffer, which would clobber the key's bytes. */
        if (k.kind == STRUPLE_STRING) {
            render_string(out, k.data, k.data_len);
        } else {
            struple_writer tmp;
            struple_writer_init(&tmp);
            if (render(&tmp, &k, depth + 1) != 0) {
                struple_writer_free(&tmp);
                struple_reader_free(&r);
                return -1;
            }
            render_string(out, tmp.data, tmp.len);
            struple_writer_free(&tmp);
        }
        jc(out, ':');
        if (struple_reader_next(&r, &v) != 1) {
            struple_reader_free(&r);
            return -1;
        }
        if (render(out, &v, depth + 1) != 0) {
            struple_reader_free(&r);
            return -1;
        }
    }
    struple_reader_free(&r);
    if (rc < 0) return -1;
    jc(out, '}');
    return 0;
}

static int render(struple_writer *out, const struple_element *e, int depth) {
    /* Bound recursion into nested containers so hostile deeply-nested input is
     * rejected rather than overflowing the stack (Item 5). */
    if (depth > STRUPLE_MAX_DEPTH) return -1;
    char tmp[32];
    switch (e->kind) {
        case STRUPLE_NIL:
        case STRUPLE_UNDEF: jw(out, "null"); return 0;
        case STRUPLE_BOOL: jw(out, e->bool_val ? "true" : "false"); return 0;
        case STRUPLE_INT:
        case STRUPLE_TIMESTAMP:
            snprintf(tmp, sizeof tmp, "%lld", (long long)e->int_val);
            jw(out, tmp);
            return 0;
        case STRUPLE_BIGINT: {
            if (e->big_negative) jc(out, '-');
            char *dec = magnitude_to_decimal(e->data, e->data_len);
            jw(out, dec);
            free(dec);
            return 0;
        }
        case STRUPLE_F32: render_float(out, (double)e->f32_val); return 0;
        case STRUPLE_F64: render_float(out, e->f64_val); return 0;
        case STRUPLE_DECIMAL: render_decimal(out, e); return 0;
        case STRUPLE_UUID: {
            static const char hexd[] = "0123456789abcdef";
            char u[37];
            size_t w = 0;
            for (size_t i = 0; i < 16; i++) {
                if (i == 4 || i == 6 || i == 8 || i == 10) u[w++] = '-';
                u[w++] = hexd[e->data[i] >> 4];
                u[w++] = hexd[e->data[i] & 0xf];
            }
            render_string(out, (const uint8_t *)u, w);
            return 0;
        }
        case STRUPLE_STRING: render_string(out, e->data, e->data_len); return 0;
        case STRUPLE_BYTES: {
            char *b = base64(e->data, e->data_len);
            render_string(out, (const uint8_t *)b, strlen(b));
            free(b);
            return 0;
        }
        case STRUPLE_ARRAY:
        case STRUPLE_SET: return render_array(out, e->data, e->data_len, depth);
        case STRUPLE_MAP: return render_map(out, e->data, e->data_len, depth);
    }
    return -1;
}

int struple_to_json(const uint8_t *buf, size_t len, struple_writer *out) {
    struple_reader r;
    struple_reader_init(&r, buf, len);
    struple_element e;
    int rc = struple_reader_next(&r, &e);
    int result;
    if (rc == 0) {
        jw(out, "null");
        result = 0;
    } else if (rc < 0) {
        result = -1;
    } else {
        result = render(out, &e, 0);
    }
    struple_reader_free(&r);
    return result;
}
