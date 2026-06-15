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
                        if (p->i + 1 < p->n && p->b[p->i] == '\\' && p->b[p->i + 1] == 'u') {
                            p->i += 2;
                            unsigned lo;
                            if (hex4(p, &lo) != 0) {
                                free(buf);
                                return NULL;
                            }
                            cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                        } else {
                            free(buf);
                            return NULL;
                        }
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

static int parse_value(P *p, sj_value *out);

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
    while (p->i < p->n && p->b[p->i] >= '0' && p->b[p->i] <= '9') p->i++;
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
        out->kind = SJ_FLOAT;
        out->float_val = strtod(tok, NULL);
        free(tok);
    } else {
        out->kind = SJ_INT;
        out->str = tok;
    }
    return 0;
}

static int parse_array(P *p, sj_value *out) {
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
        if (parse_value(p, &items[count]) != 0) goto fail;
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

static int parse_object(P *p, sj_value *out) {
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
        if (parse_value(p, &vals[count]) != 0) {
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

static int parse_value(P *p, sj_value *out) {
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
    if (c == '[') return parse_array(p, out);
    if (c == '{') return parse_object(p, out);
    if (c == '-' || (c >= '0' && c <= '9')) return parse_number(p, out);
    return -1;
}

sj_value *struple_json_parse(const char *text, size_t len) {
    P p = {text, 0, len};
    sj_value *v = (sj_value *)malloc(sizeof(sj_value));
    if (parse_value(&p, v) != 0) {
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

static void render_float(struple_writer *out, double f) {
    if (!isfinite(f)) {
        jw(out, "null");
        return;
    }
    char tmp[40];
    /* shortest %g that round-trips */
    for (int prec = 1; prec <= 17; prec++) {
        snprintf(tmp, sizeof tmp, "%.*g", prec, f);
        if (strtod(tmp, NULL) == f) break;
    }
    jw(out, tmp);
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

static int render(struple_writer *out, const struple_element *e);

static int render_array(struple_writer *out, const uint8_t *body, size_t blen) {
    struple_reader r;
    struple_reader_init(&r, body, blen);
    jc(out, '[');
    struple_element e;
    int rc;
    bool first = true;
    while ((rc = struple_reader_next(&r, &e)) == 1) {
        if (!first) jc(out, ',');
        first = false;
        if (render(out, &e) != 0) {
            struple_reader_free(&r);
            return -1;
        }
    }
    struple_reader_free(&r);
    if (rc < 0) return -1;
    jc(out, ']');
    return 0;
}

static int render_map(struple_writer *out, const uint8_t *body, size_t blen) {
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
            render(&tmp, &k);
            render_string(out, tmp.data, tmp.len);
            struple_writer_free(&tmp);
        }
        jc(out, ':');
        if (struple_reader_next(&r, &v) != 1) {
            struple_reader_free(&r);
            return -1;
        }
        if (render(out, &v) != 0) {
            struple_reader_free(&r);
            return -1;
        }
    }
    struple_reader_free(&r);
    if (rc < 0) return -1;
    jc(out, '}');
    return 0;
}

static int render(struple_writer *out, const struple_element *e) {
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
        case STRUPLE_STRING: render_string(out, e->data, e->data_len); return 0;
        case STRUPLE_BYTES: {
            char *b = base64(e->data, e->data_len);
            render_string(out, (const uint8_t *)b, strlen(b));
            free(b);
            return 0;
        }
        case STRUPLE_ARRAY:
        case STRUPLE_SET: return render_array(out, e->data, e->data_len);
        case STRUPLE_MAP: return render_map(out, e->data, e->data_len);
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
        result = render(out, &e);
    }
    struple_reader_free(&r);
    return result;
}
