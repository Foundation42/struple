/* struple reference benchmark (C11).
 *
 * Mirrors bench/zig/bench.zig and bench/js/bench.ts: encode (build a framed
 * stream from prepared in-memory records) and decode (walk the whole stream,
 * descending and un-escaping every container body and touching every scalar)
 * throughput for the seven shared workloads — four realistic streaming shapes
 * (stock quotes, geospatial points, tweets, blockchain transactions) plus three
 * structural micro-benchmarks (an integer stream, a string stream, a nested
 * document).
 *
 * The native records are parsed from bench/data/<name>.json once (setup,
 * untimed); the encoder then rebuilds the bytes with the same appendX sequence
 * the Zig reference uses. Byte-identity is verified against bench/payloads.json
 * (sha256) before any throughput figure is reported.
 *
 * Methodology (per (payload, op)): 5 warm-up runs, auto-calibrate the iteration
 * count to a ~100 ms trial, then 9 trials — the MEDIAN ns/op is reported. A
 * global volatile checksum sink consumes every result so the optimizer can't
 * elide the work. Steady-state buffers retain capacity. Single-threaded.
 *
 * Zero dependencies beyond libc + the struple codec. Paths are resolved
 * relative to the repo root (the directory two levels up from this file, or the
 * cwd if that fails). C has no stdlib JSON, so a tiny tokenizer handles the
 * shared data files (arrays of "-quoted strings only).
 *
 * Build + run (from repo root):
 *   cc -std=c11 -O3 -Wall -Wextra -o bench/c/bench \
 *       bench/c/bench.c c/struple.c c/struple_json.c -Ic -lm && bench/c/bench
 */

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include "struple.h"

/* ------------------------------------------------------------------ paths */

/* Repo root is the directory two levels above this source file. Resolved at
 * compile time from __FILE__ when it is an absolute path; otherwise the cwd. */
static char g_root[4096];

static void resolve_root(const char *argv0) {
    (void)argv0;
    const char *file = __FILE__; /* expected: <root>/bench/c/bench.c */
    if (file[0] == '/') {
        /* strip "/bench/c/bench.c" → three path segments. */
        size_t n = strlen(file);
        int slashes = 0;
        size_t cut = n;
        for (size_t i = n; i-- > 0;) {
            if (file[i] == '/') {
                slashes++;
                if (slashes == 3) {
                    cut = i;
                    break;
                }
            }
        }
        if (slashes >= 3 && cut < sizeof g_root) {
            memcpy(g_root, file, cut);
            g_root[cut] = 0;
            return;
        }
    }
    g_root[0] = '.';
    g_root[1] = 0;
}

static char *path_join(const char *rel) {
    static char buf[4096];
    snprintf(buf, sizeof buf, "%s/%s", g_root, rel);
    return buf;
}

/* ------------------------------------------------------------------ sink */

/* Volatile DCE sink — every measured op folds something into this so the
 * optimizer must actually perform the work. Wrapping u64 mirrors the Zig
 * `g_sink: u64` / JS BigInt-mod-2^64 accumulator. */
static volatile uint64_t g_sink = 0;
static inline void sink(uint64_t v) { g_sink += v; }

/* ------------------------------------------------------------------ file io */

static char *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "cannot open %s\n", path);
        exit(1);
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = (char *)malloc((size_t)sz + 1);
    if (!buf) {
        exit(1);
    }
    size_t got = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    buf[got] = 0;
    if (out_len) *out_len = got;
    return buf;
}

/* ----------------------------------------------------------- tiny tokenizer */

/* The shared data files are arrays of typed strings: only `[` `]` `,` and
 * "-quoted strings (with \" \\ \uXXXX escapes — although the corpus only ever
 * uses \" \\ in practice). All values are strings, so a tokenizer that pulls
 * out the next quoted string (handling escapes into a decoded buffer) and the
 * structural brackets is all we need. */

typedef struct {
    const char *s;
    size_t pos;
    size_t len;
} tok;

static void tok_init(tok *t, const char *s, size_t len) {
    t->s = s;
    t->pos = 0;
    t->len = len;
}

static void tok_skip_ws(tok *t) {
    while (t->pos < t->len) {
        char c = t->s[t->pos];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') t->pos++;
        else break;
    }
}

/* Peek the next non-ws structural char (or 0 at end). */
static char tok_peek(tok *t) {
    tok_skip_ws(t);
    return t->pos < t->len ? t->s[t->pos] : 0;
}

static char tok_take(tok *t) {
    tok_skip_ws(t);
    return t->pos < t->len ? t->s[t->pos++] : 0;
}

static int hex_nib(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Parse the next JSON string into a freshly malloc'd, NUL-terminated buffer
 * (the decoded UTF-8 contents). Sets *out_len to the decoded byte length. */
static char *tok_string(tok *t, size_t *out_len) {
    tok_skip_ws(t);
    if (t->pos >= t->len || t->s[t->pos] != '"') {
        fprintf(stderr, "expected string at %zu\n", t->pos);
        exit(1);
    }
    t->pos++; /* opening quote */
    size_t cap = 16, n = 0;
    char *buf = (char *)malloc(cap);
    while (t->pos < t->len) {
        char c = t->s[t->pos++];
        if (c == '"') break;
        if (c == '\\') {
            char e = t->s[t->pos++];
            switch (e) {
                case '"': c = '"'; break;
                case '\\': c = '\\'; break;
                case '/': c = '/'; break;
                case 'b': c = '\b'; break;
                case 'f': c = '\f'; break;
                case 'n': c = '\n'; break;
                case 'r': c = '\r'; break;
                case 't': c = '\t'; break;
                case 'u': {
                    int h0 = hex_nib(t->s[t->pos]);
                    int h1 = hex_nib(t->s[t->pos + 1]);
                    int h2 = hex_nib(t->s[t->pos + 2]);
                    int h3 = hex_nib(t->s[t->pos + 3]);
                    t->pos += 4;
                    unsigned cp = (unsigned)((h0 << 12) | (h1 << 8) | (h2 << 4) | h3);
                    /* Encode the code point as UTF-8 (BMP only — the corpus
                     * never produces surrogate pairs). */
                    if (cp < 0x80) {
                        if (n + 1 > cap) { cap *= 2; buf = realloc(buf, cap); }
                        buf[n++] = (char)cp;
                    } else if (cp < 0x800) {
                        if (n + 2 > cap) { cap *= 2; buf = realloc(buf, cap); }
                        buf[n++] = (char)(0xC0 | (cp >> 6));
                        buf[n++] = (char)(0x80 | (cp & 0x3F));
                    } else {
                        if (n + 3 > cap) { cap *= 2; buf = realloc(buf, cap); }
                        buf[n++] = (char)(0xE0 | (cp >> 12));
                        buf[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                        buf[n++] = (char)(0x80 | (cp & 0x3F));
                    }
                    continue;
                }
                default: c = e; break;
            }
        }
        if (n + 1 > cap) { cap *= 2; buf = realloc(buf, cap); }
        buf[n++] = c;
    }
    if (n + 1 > cap) { cap *= 2; buf = realloc(buf, cap); }
    buf[n] = 0;
    if (out_len) *out_len = n;
    return buf;
}

/* ------------------------------------------------------- field parse helpers */

/* 16 hex digits of the IEEE-754 bits (big-endian) → double. The hex string
 * spells out the 64-bit pattern MSB-first, so `bits` holds the exact integer
 * value of those bits; reinterpreting that integer as a double recovers the
 * value (matches JS DataView setBigUint64/getFloat64 with big-endian). */
static double f64_from_hex(const char *hex) {
    uint64_t bits = 0;
    for (int i = 0; i < 16; i++) {
        int v = hex_nib(hex[i]);
        bits = (bits << 4) | (uint64_t)(v < 0 ? 0 : v);
    }
    double d;
    memcpy(&d, &bits, 8);
    return d;
}

/* digit string "12345" → bytes [1,2,3,4,5]. Returns malloc'd buffer. */
static uint8_t *digits_from_str(const char *s, size_t slen, size_t *out_n) {
    uint8_t *out = (uint8_t *)malloc(slen ? slen : 1);
    for (size_t i = 0; i < slen; i++) out[i] = (uint8_t)(s[i] - '0');
    *out_n = slen;
    return out;
}

/* hex string (even length) → bytes. Returns malloc'd buffer. */
static uint8_t *bytes_from_hex(const char *hex, size_t hexlen, size_t *out_n) {
    size_t n = hexlen / 2;
    uint8_t *out = (uint8_t *)malloc(n ? n : 1);
    for (size_t i = 0; i < n; i++) {
        out[i] = (uint8_t)((hex_nib(hex[2 * i]) << 4) | hex_nib(hex[2 * i + 1]));
    }
    *out_n = n;
    return out;
}

static int64_t i64_from_str(const char *s) { return (int64_t)strtoll(s, NULL, 10); }
static uint64_t u64_from_str(const char *s) { return (uint64_t)strtoull(s, NULL, 10); }

/* --------------------------------------------------------- record structures */

typedef struct { uint8_t *digits; size_t ndigits; int32_t exp; } Dec;

typedef struct {
    char *symbol; size_t symbol_len;
    Dec bid, ask;
    double last;
    int64_t volume;
    int64_t ts;
} Quote;

typedef struct {
    double lat, lon, elevation;
    char *name; size_t name_len;
    int64_t ts;
} Geo;

typedef struct {
    uint64_t id;
    char *user; size_t user_len;
    char *text; size_t text_len;
    int64_t created_at;
    int64_t likes, retweets;
} Tweet;

typedef struct {
    int64_t height;
    uint8_t *tx_hash; size_t tx_hash_len;
    uint8_t *from; size_t from_len;
    uint8_t *to; size_t to_len;
    uint8_t *value_be; size_t value_len; /* big-endian magnitude (big or fix) */
    int64_t gas, nonce;
    int64_t ts;
} Tx;

typedef struct {
    int64_t uid;
    char *name; size_t name_len;
    bool active;
    int64_t scores[3];
} Nested;

typedef struct {
    Quote *quotes; size_t n_quotes;
    Geo *geo; size_t n_geo;
    Tweet *tweets; size_t n_tweets;
    Tx *txs; size_t n_txs;
    int64_t *ints; size_t n_ints;
    char **strings; size_t *string_lens; size_t n_strings;
    Nested *nested; size_t n_nested;
} Data;

typedef enum { K_QUOTES, K_GEO, K_TWEETS, K_TXS, K_INTS, K_STRINGS, K_NESTED } PKind;

typedef struct {
    PKind kind;
    const char *name;
    const char *category;
} PayloadMeta;

static const PayloadMeta payloads[] = {
    {K_QUOTES, "stock_quotes", "streaming"},
    {K_GEO, "geo_points", "streaming"},
    {K_TWEETS, "tweets", "streaming"},
    {K_TXS, "blockchain_txs", "streaming"},
    {K_INTS, "int_stream", "structural"},
    {K_STRINGS, "string_stream", "structural"},
    {K_NESTED, "nested_doc", "structural"},
};
#define N_PAYLOADS (sizeof payloads / sizeof payloads[0])

/* ----------------------------------------------------------- data reader */

/* Read a whole "rows" file (array of arrays). Calls `row_cb` for each inner
 * array, having advanced the tokenizer past the opening '[' of the row; the
 * callback consumes exactly the row's fields, then this function consumes the
 * closing ']' and a trailing comma if present. */

/* Each loader is bespoke (column orders differ); a small generic helper grabs
 * one quoted field. */
static char *next_field(tok *t, size_t *len) {
    return tok_string(t, len);
}

/* Count top-level rows (commas + 1) is awkward with escapes, so we parse into
 * growable arrays directly. */

static void load_stock_quotes(tok *t, Data *d) {
    size_t cap = 4096, n = 0;
    Quote *arr = (Quote *)malloc(cap * sizeof *arr);
    char c = tok_take(t); /* '[' outer */
    (void)c;
    if (tok_peek(t) == ']') { tok_take(t); d->quotes = arr; d->n_quotes = 0; return; }
    for (;;) {
        if (n + 1 > cap) { cap *= 2; arr = realloc(arr, cap * sizeof *arr); }
        tok_take(t); /* '[' row */
        Quote *q = &arr[n++];
        size_t l;
        q->symbol = next_field(t, &q->symbol_len);
        tok_take(t); /* ',' */
        char *bd = next_field(t, &l);
        q->bid.digits = digits_from_str(bd, l, &q->bid.ndigits); free(bd);
        tok_take(t);
        char *be = next_field(t, &l); q->bid.exp = (int32_t)i64_from_str(be); free(be);
        tok_take(t);
        char *ad = next_field(t, &l);
        q->ask.digits = digits_from_str(ad, l, &q->ask.ndigits); free(ad);
        tok_take(t);
        char *ae = next_field(t, &l); q->ask.exp = (int32_t)i64_from_str(ae); free(ae);
        tok_take(t);
        char *lf = next_field(t, &l); q->last = f64_from_hex(lf); free(lf);
        tok_take(t);
        char *vol = next_field(t, &l); q->volume = i64_from_str(vol); free(vol);
        tok_take(t);
        char *ts = next_field(t, &l); q->ts = i64_from_str(ts); free(ts);
        tok_take(t); /* ']' row */
        char nx = tok_take(t); /* ',' or ']' */
        if (nx == ']') break;
    }
    d->quotes = arr;
    d->n_quotes = n;
}

static void load_geo(tok *t, Data *d) {
    size_t cap = 4096, n = 0;
    Geo *arr = (Geo *)malloc(cap * sizeof *arr);
    tok_take(t);
    if (tok_peek(t) == ']') { tok_take(t); d->geo = arr; d->n_geo = 0; return; }
    for (;;) {
        if (n + 1 > cap) { cap *= 2; arr = realloc(arr, cap * sizeof *arr); }
        tok_take(t);
        Geo *g = &arr[n++];
        size_t l;
        char *la = next_field(t, &l); g->lat = f64_from_hex(la); free(la); tok_take(t);
        char *lo = next_field(t, &l); g->lon = f64_from_hex(lo); free(lo); tok_take(t);
        char *el = next_field(t, &l); g->elevation = f64_from_hex(el); free(el); tok_take(t);
        g->name = next_field(t, &g->name_len); tok_take(t);
        char *ts = next_field(t, &l); g->ts = i64_from_str(ts); free(ts);
        tok_take(t);
        char nx = tok_take(t);
        if (nx == ']') break;
    }
    d->geo = arr;
    d->n_geo = n;
}

static void load_tweets(tok *t, Data *d) {
    size_t cap = 4096, n = 0;
    Tweet *arr = (Tweet *)malloc(cap * sizeof *arr);
    tok_take(t);
    if (tok_peek(t) == ']') { tok_take(t); d->tweets = arr; d->n_tweets = 0; return; }
    for (;;) {
        if (n + 1 > cap) { cap *= 2; arr = realloc(arr, cap * sizeof *arr); }
        tok_take(t);
        Tweet *tw = &arr[n++];
        size_t l;
        char *id = next_field(t, &l); tw->id = u64_from_str(id); free(id); tok_take(t);
        tw->user = next_field(t, &tw->user_len); tok_take(t);
        tw->text = next_field(t, &tw->text_len); tok_take(t);
        char *cr = next_field(t, &l); tw->created_at = i64_from_str(cr); free(cr); tok_take(t);
        char *lk = next_field(t, &l); tw->likes = i64_from_str(lk); free(lk); tok_take(t);
        char *rt = next_field(t, &l); tw->retweets = i64_from_str(rt); free(rt);
        tok_take(t);
        char nx = tok_take(t);
        if (nx == ']') break;
    }
    d->tweets = arr;
    d->n_tweets = n;
}

static void load_txs(tok *t, Data *d) {
    size_t cap = 4096, n = 0;
    Tx *arr = (Tx *)malloc(cap * sizeof *arr);
    tok_take(t);
    if (tok_peek(t) == ']') { tok_take(t); d->txs = arr; d->n_txs = 0; return; }
    for (;;) {
        if (n + 1 > cap) { cap *= 2; arr = realloc(arr, cap * sizeof *arr); }
        tok_take(t);
        Tx *x = &arr[n++];
        size_t l;
        char *h = next_field(t, &l); x->height = i64_from_str(h); free(h); tok_take(t);
        char *hash = next_field(t, &l); x->tx_hash = bytes_from_hex(hash, l, &x->tx_hash_len); free(hash); tok_take(t);
        char *fr = next_field(t, &l); x->from = bytes_from_hex(fr, l, &x->from_len); free(fr); tok_take(t);
        char *to = next_field(t, &l); x->to = bytes_from_hex(to, l, &x->to_len); free(to); tok_take(t);
        char *kind = next_field(t, &l); free(kind); tok_take(t); /* "big"|"fix" — both → big_int by magnitude */
        char *val = next_field(t, &l); x->value_be = bytes_from_hex(val, l, &x->value_len); free(val); tok_take(t);
        char *gas = next_field(t, &l); x->gas = i64_from_str(gas); free(gas); tok_take(t);
        char *nonce = next_field(t, &l); x->nonce = i64_from_str(nonce); free(nonce); tok_take(t);
        char *ts = next_field(t, &l); x->ts = i64_from_str(ts); free(ts);
        tok_take(t);
        char nx = tok_take(t);
        if (nx == ']') break;
    }
    d->txs = arr;
    d->n_txs = n;
}

static void load_ints(tok *t, Data *d) {
    size_t cap = 65536, n = 0;
    int64_t *arr = (int64_t *)malloc(cap * sizeof *arr);
    tok_take(t); /* '[' */
    if (tok_peek(t) == ']') { tok_take(t); d->ints = arr; d->n_ints = 0; return; }
    for (;;) {
        if (n + 1 > cap) { cap *= 2; arr = realloc(arr, cap * sizeof *arr); }
        size_t l;
        char *v = next_field(t, &l);
        arr[n++] = i64_from_str(v);
        free(v);
        char nx = tok_take(t);
        if (nx == ']') break;
    }
    d->ints = arr;
    d->n_ints = n;
}

static void load_strings(tok *t, Data *d) {
    size_t cap = 32768, n = 0;
    char **arr = (char **)malloc(cap * sizeof *arr);
    size_t *lens = (size_t *)malloc(cap * sizeof *lens);
    tok_take(t);
    if (tok_peek(t) == ']') { tok_take(t); d->strings = arr; d->string_lens = lens; d->n_strings = 0; return; }
    for (;;) {
        if (n + 1 > cap) {
            cap *= 2;
            arr = realloc(arr, cap * sizeof *arr);
            lens = realloc(lens, cap * sizeof *lens);
        }
        arr[n] = next_field(t, &lens[n]);
        n++;
        char nx = tok_take(t);
        if (nx == ']') break;
    }
    d->strings = arr;
    d->string_lens = lens;
    d->n_strings = n;
}

static void load_nested(tok *t, Data *d) {
    size_t cap = 4096, n = 0;
    Nested *arr = (Nested *)malloc(cap * sizeof *arr);
    tok_take(t);
    if (tok_peek(t) == ']') { tok_take(t); d->nested = arr; d->n_nested = 0; return; }
    for (;;) {
        if (n + 1 > cap) { cap *= 2; arr = realloc(arr, cap * sizeof *arr); }
        tok_take(t);
        Nested *nn = &arr[n++];
        size_t l;
        char *ac = next_field(t, &l); nn->active = (ac[0] == '1'); free(ac); tok_take(t);
        char *uid = next_field(t, &l); nn->uid = i64_from_str(uid); free(uid); tok_take(t);
        nn->name = next_field(t, &nn->name_len); tok_take(t);
        char *s0 = next_field(t, &l); nn->scores[0] = i64_from_str(s0); free(s0); tok_take(t);
        char *s1 = next_field(t, &l); nn->scores[1] = i64_from_str(s1); free(s1); tok_take(t);
        char *s2 = next_field(t, &l); nn->scores[2] = i64_from_str(s2); free(s2);
        tok_take(t);
        char nx = tok_take(t);
        if (nx == ']') break;
    }
    d->nested = arr;
    d->n_nested = n;
}

static void read_data(Data *d) {
    memset(d, 0, sizeof *d);
    size_t len;
    char *txt;
    tok t;

    txt = read_file(path_join("bench/data/stock_quotes.json"), &len);
    tok_init(&t, txt, len); load_stock_quotes(&t, d); free(txt);

    txt = read_file(path_join("bench/data/geo_points.json"), &len);
    tok_init(&t, txt, len); load_geo(&t, d); free(txt);

    txt = read_file(path_join("bench/data/tweets.json"), &len);
    tok_init(&t, txt, len); load_tweets(&t, d); free(txt);

    txt = read_file(path_join("bench/data/blockchain_txs.json"), &len);
    tok_init(&t, txt, len); load_txs(&t, d); free(txt);

    txt = read_file(path_join("bench/data/int_stream.json"), &len);
    tok_init(&t, txt, len); load_ints(&t, d); free(txt);

    txt = read_file(path_join("bench/data/string_stream.json"), &len);
    tok_init(&t, txt, len); load_strings(&t, d); free(txt);

    txt = read_file(path_join("bench/data/nested_doc.json"), &len);
    tok_init(&t, txt, len); load_nested(&t, d); free(txt);
}

/* --------------------------------------------------------------- encoders */

/* Pre-encoded constant keys for the nested-doc map (invariant; the Zig harness
 * re-encodes them per record from an arena but the keys never change, so
 * caching them is byte-identical and avoids needless work — mirrors the JS
 * port). */
static struple_writer KEY_ACTIVE, KEY_SCORES, KEY_USER, KEY_ID, KEY_NAME;

static void enc_key(struple_writer *w, const char *s) {
    struple_writer_init(w);
    struple_append_string(w, s, strlen(s));
}

static void init_nested_keys(void) {
    enc_key(&KEY_ACTIVE, "active");
    enc_key(&KEY_SCORES, "scores");
    enc_key(&KEY_USER, "user");
    enc_key(&KEY_ID, "id");
    enc_key(&KEY_NAME, "name");
}

/* Per-record scratch writers for the nested-doc case, reused across records. */
typedef struct {
    struple_writer scratch;   /* frames one streaming record at a time */
    struple_writer v_active;  /* nested: encoded bool value */
    struple_writer v_uid;     /* nested: encoded uid int */
    struple_writer v_name;    /* nested: encoded name string */
    struple_writer user;      /* nested: encoded user sub-map */
    struple_writer scores_in; /* nested: scores inner stream */
    struple_writer scores_arr;/* nested: scores array element */
} EncScratch;

static void enc_scratch_init(EncScratch *e) {
    struple_writer_init(&e->scratch);
    struple_writer_init(&e->v_active);
    struple_writer_init(&e->v_uid);
    struple_writer_init(&e->v_name);
    struple_writer_init(&e->user);
    struple_writer_init(&e->scores_in);
    struple_writer_init(&e->scores_arr);
}

static void enc_scratch_free(EncScratch *e) {
    struple_writer_free(&e->scratch);
    struple_writer_free(&e->v_active);
    struple_writer_free(&e->v_uid);
    struple_writer_free(&e->v_name);
    struple_writer_free(&e->user);
    struple_writer_free(&e->scores_in);
    struple_writer_free(&e->scores_arr);
}

static void encode_once(PKind kind, const Data *d, struple_writer *out, EncScratch *e) {
    struple_writer *sc = &e->scratch;
    switch (kind) {
        case K_QUOTES:
            for (size_t i = 0; i < d->n_quotes; i++) {
                const Quote *q = &d->quotes[i];
                struple_writer_reset(sc);
                struple_append_string(sc, q->symbol, q->symbol_len);
                struple_append_decimal(sc, false, q->bid.digits, q->bid.ndigits, q->bid.exp);
                struple_append_decimal(sc, false, q->ask.digits, q->ask.ndigits, q->ask.exp);
                struple_append_f64(sc, q->last);
                struple_append_int(sc, q->volume);
                struple_append_timestamp(sc, q->ts);
                struple_append_array(out, sc->data, sc->len);
            }
            break;
        case K_GEO:
            for (size_t i = 0; i < d->n_geo; i++) {
                const Geo *g = &d->geo[i];
                struple_writer_reset(sc);
                struple_append_f64(sc, g->lat);
                struple_append_f64(sc, g->lon);
                struple_append_f64(sc, g->elevation);
                struple_append_string(sc, g->name, g->name_len);
                struple_append_timestamp(sc, g->ts);
                struple_append_array(out, sc->data, sc->len);
            }
            break;
        case K_TWEETS:
            for (size_t i = 0; i < d->n_tweets; i++) {
                const Tweet *t = &d->tweets[i];
                struple_writer_reset(sc);
                struple_append_uint(sc, t->id);
                struple_append_string(sc, t->user, t->user_len);
                struple_append_string(sc, t->text, t->text_len);
                struple_append_timestamp(sc, t->created_at);
                struple_append_int(sc, t->likes);
                struple_append_int(sc, t->retweets);
                struple_append_array(out, sc->data, sc->len);
            }
            break;
        case K_TXS:
            for (size_t i = 0; i < d->n_txs; i++) {
                const Tx *x = &d->txs[i];
                struple_writer_reset(sc);
                struple_append_int(sc, x->height);
                struple_append_bytes(sc, x->tx_hash, x->tx_hash_len);
                struple_append_bytes(sc, x->from, x->from_len);
                struple_append_bytes(sc, x->to, x->to_len);
                /* Single big-int entry point auto-selects the i128 fixed slots
                 * vs the arbitrary-precision big-int codes by magnitude — so
                 * the `big` and `fix` value kinds both route through here,
                 * byte-identical to the Zig appendI128 / appendBigInt split. */
                struple_append_big_int(sc, false, x->value_be, x->value_len);
                struple_append_int(sc, x->gas);
                struple_append_int(sc, x->nonce);
                struple_append_timestamp(sc, x->ts);
                struple_append_array(out, sc->data, sc->len);
            }
            break;
        case K_INTS:
            for (size_t i = 0; i < d->n_ints; i++) struple_append_int(out, d->ints[i]);
            break;
        case K_STRINGS:
            for (size_t i = 0; i < d->n_strings; i++)
                struple_append_string(out, d->strings[i], d->string_lens[i]);
            break;
        case K_NESTED:
            for (size_t i = 0; i < d->n_nested; i++) {
                const Nested *n = &d->nested[i];
                /* user sub-map { id, name } */
                struple_writer_reset(&e->v_uid);
                struple_append_int(&e->v_uid, n->uid);
                struple_writer_reset(&e->v_name);
                struple_append_string(&e->v_name, n->name, n->name_len);
                struple_kv user_entries[2] = {
                    {{KEY_ID.data, KEY_ID.len}, {e->v_uid.data, e->v_uid.len}},
                    {{KEY_NAME.data, KEY_NAME.len}, {e->v_name.data, e->v_name.len}},
                };
                struple_writer_reset(&e->user);
                struple_append_map(&e->user, user_entries, 2);
                /* scores array [s0, s1, s2] */
                struple_writer_reset(&e->scores_in);
                struple_append_int(&e->scores_in, n->scores[0]);
                struple_append_int(&e->scores_in, n->scores[1]);
                struple_append_int(&e->scores_in, n->scores[2]);
                struple_writer_reset(&e->scores_arr);
                struple_append_array(&e->scores_arr, e->scores_in.data, e->scores_in.len);
                /* top-level map (appendMap sorts by encoded key, so order is free) */
                struple_writer_reset(&e->v_active);
                struple_append_bool(&e->v_active, n->active);
                struple_kv entries[3] = {
                    {{KEY_ACTIVE.data, KEY_ACTIVE.len}, {e->v_active.data, e->v_active.len}},
                    {{KEY_SCORES.data, KEY_SCORES.len}, {e->scores_arr.data, e->scores_arr.len}},
                    {{KEY_USER.data, KEY_USER.len}, {e->user.data, e->user.len}},
                };
                struple_append_map(out, entries, 3);
            }
            break;
    }
}

static size_t record_count(PKind kind, const Data *d) {
    switch (kind) {
        case K_QUOTES: return d->n_quotes;
        case K_GEO: return d->n_geo;
        case K_TWEETS: return d->n_tweets;
        case K_TXS: return d->n_txs;
        case K_INTS: return d->n_ints;
        case K_STRINGS: return d->n_strings;
        case K_NESTED: return d->n_nested;
    }
    return 0;
}

/* --------------------------------------------------------------- decode walk */

/* Recursive walk that touches every value, descending and un-escaping every
 * container body (the realistic cost of the memcmp-orderable framing). Each
 * container body is decoded by struple_reader_next into the reader's own
 * scratch (single-pass unescape); we recurse with a fresh reader over that
 * body view. The body lives in the parent reader's scratch, which stays valid
 * for the duration of the recursive call (the parent reader is not advanced
 * during recursion). */
static void walk(const uint8_t *buf, size_t len) {
    struple_reader r;
    struple_reader_init(&r, buf, len);
    struple_element el;
    int rc;
    while ((rc = struple_reader_next(&r, &el)) == 1) {
        switch (el.kind) {
            case STRUPLE_NIL:
            case STRUPLE_UNDEF:
                break;
            case STRUPLE_BOOL:
                sink(el.bool_val ? 1u : 0u);
                break;
            case STRUPLE_INT:
                sink((uint64_t)el.int_val);
                break;
            case STRUPLE_BIGINT:
                sink(el.data_len);
                break;
            case STRUPLE_F32: {
                uint32_t b;
                memcpy(&b, &el.f32_val, 4);
                sink(b);
                break;
            }
            case STRUPLE_F64: {
                uint64_t b;
                memcpy(&b, &el.f64_val, 8);
                sink(b);
                break;
            }
            case STRUPLE_DECIMAL:
                sink(el.data_len + (uint64_t)(el.dec_exponent + (int64_t)el.data_len));
                break;
            case STRUPLE_TIMESTAMP:
                sink((uint64_t)el.int_val);
                break;
            case STRUPLE_UUID:
                sink(el.data[0]);
                break;
            case STRUPLE_STRING:
            case STRUPLE_BYTES:
                sink(el.data_len);
                if (el.data_len > 0) sink(el.data[0]);
                break;
            case STRUPLE_ARRAY:
            case STRUPLE_MAP:
            case STRUPLE_SET:
                walk(el.data, el.data_len);
                break;
        }
    }
    struple_reader_free(&r);
}

/* --------------------------------------------------------------- timing */

#define N_TRIALS 9
#define N_WARMUP 5
static const uint64_t TARGET_TRIAL_NS = 100ull * 1000ull * 1000ull; /* ~100 ms */

typedef struct {
    double ns_per_op;
    size_t bytes;
    size_t records;
} Stats;

static double mb_per_sec(Stats s) { return ((double)s.bytes / s.ns_per_op) * 1000.0; }
static double mrec_per_sec(Stats s) { return ((double)s.records / s.ns_per_op) * 1000.0; }

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static double median(double *v, size_t n) {
    qsort(v, n, sizeof *v, cmp_double);
    return v[n / 2];
}

static Stats bench_encode(PKind kind, const Data *d, size_t canonical_len) {
    struple_writer out;
    struple_writer_init(&out);
    EncScratch e;
    enc_scratch_init(&e);

    for (int i = 0; i < N_WARMUP; i++) {
        struple_writer_reset(&out);
        encode_once(kind, d, &out, &e);
        sink(out.len);
    }

    uint64_t t0 = now_ns();
    struple_writer_reset(&out);
    encode_once(kind, d, &out, &e);
    sink(out.len);
    uint64_t one = now_ns() - t0;
    if (one == 0) one = 1;
    size_t iters = (size_t)(TARGET_TRIAL_NS / one);
    if (iters < 1) iters = 1;

    double trials[N_TRIALS];
    for (int t = 0; t < N_TRIALS; t++) {
        uint64_t s = now_ns();
        for (size_t j = 0; j < iters; j++) {
            struple_writer_reset(&out);
            encode_once(kind, d, &out, &e);
            sink(out.len);
        }
        uint64_t dt = now_ns() - s;
        trials[t] = (double)dt / (double)iters;
    }

    enc_scratch_free(&e);
    struple_writer_free(&out);

    Stats st = {median(trials, N_TRIALS), canonical_len, record_count(kind, d)};
    return st;
}

static Stats bench_decode(PKind kind, const Data *d, const uint8_t *bytes, size_t len) {
    for (int i = 0; i < N_WARMUP; i++) walk(bytes, len);

    uint64_t t0 = now_ns();
    walk(bytes, len);
    uint64_t one = now_ns() - t0;
    if (one == 0) one = 1;
    size_t iters = (size_t)(TARGET_TRIAL_NS / one);
    if (iters < 1) iters = 1;

    double trials[N_TRIALS];
    for (int t = 0; t < N_TRIALS; t++) {
        uint64_t s = now_ns();
        for (size_t j = 0; j < iters; j++) walk(bytes, len);
        uint64_t dt = now_ns() - s;
        trials[t] = (double)dt / (double)iters;
    }

    Stats st = {median(trials, N_TRIALS), len, record_count(kind, d)};
    return st;
}

/* Build canonical bytes once (size, sha256, decode input). Caller frees. */
static uint8_t *build_canonical(PKind kind, const Data *d, size_t *out_len) {
    struple_writer out;
    struple_writer_init(&out);
    EncScratch e;
    enc_scratch_init(&e);
    encode_once(kind, d, &out, &e);
    enc_scratch_free(&e);
    uint8_t *copy = (uint8_t *)malloc(out.len ? out.len : 1);
    memcpy(copy, out.data, out.len);
    *out_len = out.len;
    struple_writer_free(&out);
    return copy;
}

/* --------------------------------------------------------------- sha256 */

/* Minimal, self-contained SHA-256 (FIPS 180-4). */
typedef struct {
    uint32_t h[8];
    uint64_t total;
    uint8_t block[64];
    size_t blen;
} sha256_ctx;

static uint32_t rotr32(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

static const uint32_t SHA256_K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

static void sha256_init(sha256_ctx *c) {
    static const uint32_t iv[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                   0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    memcpy(c->h, iv, sizeof iv);
    c->total = 0;
    c->blen = 0;
}

static void sha256_compress(sha256_ctx *c, const uint8_t *p) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = ((uint32_t)p[4 * i] << 24) | ((uint32_t)p[4 * i + 1] << 16) |
               ((uint32_t)p[4 * i + 2] << 8) | (uint32_t)p[4 * i + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = c->h[0], b = c->h[1], cc = c->h[2], dd = c->h[3];
    uint32_t ee = c->h[4], ff = c->h[5], gg = c->h[6], hh = c->h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t S1 = rotr32(ee, 6) ^ rotr32(ee, 11) ^ rotr32(ee, 25);
        uint32_t ch = (ee & ff) ^ (~ee & gg);
        uint32_t t1 = hh + S1 + ch + SHA256_K[i] + w[i];
        uint32_t S0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
        uint32_t maj = (a & b) ^ (a & cc) ^ (b & cc);
        uint32_t t2 = S0 + maj;
        hh = gg; gg = ff; ff = ee; ee = dd + t1;
        dd = cc; cc = b; b = a; a = t1 + t2;
    }
    c->h[0] += a; c->h[1] += b; c->h[2] += cc; c->h[3] += dd;
    c->h[4] += ee; c->h[5] += ff; c->h[6] += gg; c->h[7] += hh;
}

static void sha256_update(sha256_ctx *c, const uint8_t *data, size_t len) {
    c->total += len;
    while (len) {
        size_t take = 64 - c->blen;
        if (take > len) take = len;
        memcpy(c->block + c->blen, data, take);
        c->blen += take;
        data += take;
        len -= take;
        if (c->blen == 64) {
            sha256_compress(c, c->block);
            c->blen = 0;
        }
    }
}

static void sha256_final(sha256_ctx *c, uint8_t out[32]) {
    uint64_t bits = c->total * 8;
    uint8_t pad = 0x80;
    sha256_update(c, &pad, 1);
    uint8_t zero = 0;
    while (c->blen != 56) sha256_update(c, &zero, 1);
    uint8_t lenbuf[8];
    for (int i = 0; i < 8; i++) lenbuf[i] = (uint8_t)(bits >> (8 * (7 - i)));
    sha256_update(c, lenbuf, 8);
    for (int i = 0; i < 8; i++) {
        out[4 * i] = (uint8_t)(c->h[i] >> 24);
        out[4 * i + 1] = (uint8_t)(c->h[i] >> 16);
        out[4 * i + 2] = (uint8_t)(c->h[i] >> 8);
        out[4 * i + 3] = (uint8_t)(c->h[i]);
    }
}

static void sha256_hex(const uint8_t *data, size_t len, char out[65]) {
    sha256_ctx c;
    sha256_init(&c);
    sha256_update(&c, data, len);
    uint8_t digest[32];
    sha256_final(&c, digest);
    static const char *hexd = "0123456789abcdef";
    for (int i = 0; i < 32; i++) {
        out[2 * i] = hexd[digest[i] >> 4];
        out[2 * i + 1] = hexd[digest[i] & 0xf];
    }
    out[64] = 0;
}

/* --------------------------------------------------------------- manifest */

typedef struct {
    char name[64];
    size_t byte_len;
    char sha256[65];
} Manifest;

/* Extremely small extraction from payloads.json — find each payload by name
 * and pull its byte_len and sha256 (both follow the name within the object). */
static const char *find_after(const char *hay, const char *needle, const char *from) {
    const char *p = strstr(from, needle);
    (void)hay;
    return p;
}

static size_t load_manifest(Manifest *out, size_t max) {
    size_t len;
    char *txt = read_file(path_join("bench/payloads.json"), &len);
    size_t count = 0;
    const char *cur = txt;
    while (count < max) {
        const char *np = find_after(txt, "\"name\":", cur);
        if (!np) break;
        np = strchr(np, '"'); np = strchr(np + 1, '"'); /* skip to value-opening quote */
        np = strchr(np + 1, '"'); /* opening quote of the value */
        const char *ns = np + 1;
        const char *ne = strchr(ns, '"');
        size_t nl = (size_t)(ne - ns);
        if (nl >= sizeof out[count].name) nl = sizeof out[count].name - 1;
        memcpy(out[count].name, ns, nl);
        out[count].name[nl] = 0;

        const char *bl = strstr(ne, "\"byte_len\":");
        bl += strlen("\"byte_len\":");
        out[count].byte_len = (size_t)strtoull(bl, NULL, 10);

        const char *sh = strstr(bl, "\"sha256\":");
        sh = strchr(sh + strlen("\"sha256\":"), '"');
        const char *ss = sh + 1;
        const char *se = strchr(ss, '"');
        size_t sl = (size_t)(se - ss);
        if (sl >= sizeof out[count].sha256) sl = sizeof out[count].sha256 - 1;
        memcpy(out[count].sha256, ss, sl);
        out[count].sha256[sl] = 0;

        cur = se;
        count++;
    }
    free(txt);
    return count;
}

static const Manifest *manifest_get(const Manifest *m, size_t n, const char *name) {
    for (size_t i = 0; i < n; i++)
        if (strcmp(m[i].name, name) == 0) return &m[i];
    return NULL;
}

/* --------------------------------------------------------------- host label */

static void host_label(char *out, size_t cap) {
    FILE *f = fopen("/proc/cpuinfo", "rb");
    if (f) {
        char line[1024];
        while (fgets(line, sizeof line, f)) {
            if (strncmp(line, "model name", 10) == 0) {
                char *colon = strchr(line, ':');
                if (colon) {
                    char *s = colon + 1;
                    while (*s == ' ' || *s == '\t') s++;
                    char *e = s + strlen(s);
                    while (e > s && (e[-1] == '\n' || e[-1] == '\r' || e[-1] == ' ')) e--;
                    size_t l = (size_t)(e - s);
                    if (l >= cap) l = cap - 1;
                    memcpy(out, s, l);
                    out[l] = 0;
                    fclose(f);
                    return;
                }
            }
        }
        fclose(f);
    }
    snprintf(out, cap, "unknown");
}

/* --------------------------------------------------------------- main */

typedef struct {
    double enc_mrec_s, enc_mb_s, dec_mrec_s, dec_mb_s;
    bool sha256_ok;
} PayloadResult;

static double round2(double x) { return round(x * 100.0) / 100.0; }

int main(int argc, char **argv) {
    (void)argc;
    resolve_root(argv[0]);
    init_nested_keys();

    Manifest manifest[16];
    size_t nman = load_manifest(manifest, 16);

    Data data;
    read_data(&data);

    printf("struple benchmark (C / -O3, single-threaded)\n\n");

    PayloadResult results[N_PAYLOADS];
    bool all_ok = true;
    size_t total_bytes = 0;

    for (size_t i = 0; i < N_PAYLOADS; i++) {
        const PayloadMeta *meta = &payloads[i];
        size_t len;
        uint8_t *bytes = build_canonical(meta->kind, &data, &len);
        total_bytes += len;

        char sha[65];
        sha256_hex(bytes, len, sha);
        const Manifest *exp = manifest_get(manifest, nman, meta->name);
        bool ok = exp && strcmp(sha, exp->sha256) == 0 && len == exp->byte_len;

        if (!ok) {
            all_ok = false;
            fprintf(stderr,
                    "\nBYTE MISMATCH for %s:\n"
                    "  produced byte_len=%zu sha256=%s\n"
                    "  expected byte_len=%zu sha256=%s\n"
                    "This is a contract bug — STOPPING (no throughput reported for this payload).\n",
                    meta->name, len, sha, exp ? exp->byte_len : 0, exp ? exp->sha256 : "(missing)");
            results[i] = (PayloadResult){0, 0, 0, 0, false};
            free(bytes);
            continue;
        }

        Stats enc = bench_encode(meta->kind, &data, len);
        Stats dec = bench_decode(meta->kind, &data, bytes, len);

        results[i] = (PayloadResult){
            round2(mrec_per_sec(enc)), round2(mb_per_sec(enc)),
            round2(mrec_per_sec(dec)), round2(mb_per_sec(dec)), true};

        printf("  %-16s %6zu rec   enc %7.2f Mrec/s %6.0f MB/s   dec %7.2f Mrec/s %6.0f MB/s   sha ok\n",
               meta->name, enc.records, mrec_per_sec(enc), mb_per_sec(enc),
               mrec_per_sec(dec), mb_per_sec(dec));

        free(bytes);
    }

    char host[512];
    host_label(host, sizeof host);

    /* Write bench/results/c.json. Ensure the results dir exists (best-effort). */
    {
        char dir[4096];
        snprintf(dir, sizeof dir, "%s/bench", g_root);
        mkdir(dir, 0755);
        snprintf(dir, sizeof dir, "%s/bench/results", g_root);
        mkdir(dir, 0755);
    }

    char jpath[4096];
    snprintf(jpath, sizeof jpath, "%s/bench/results/c.json", g_root);
    FILE *jf = fopen(jpath, "wb");
    if (jf) {
        fprintf(jf, "{\n  \"lang\": \"C\",\n  \"host\": \"%s\",\n  \"payloads\": {\n", host);
        for (size_t i = 0; i < N_PAYLOADS; i++) {
            fprintf(jf,
                    "    \"%s\": {\n"
                    "      \"enc_mrec_s\": %g,\n"
                    "      \"enc_mb_s\": %g,\n"
                    "      \"dec_mrec_s\": %g,\n"
                    "      \"dec_mb_s\": %g,\n"
                    "      \"sha256_ok\": %s\n"
                    "    }%s\n",
                    payloads[i].name, results[i].enc_mrec_s, results[i].enc_mb_s,
                    results[i].dec_mrec_s, results[i].dec_mb_s,
                    results[i].sha256_ok ? "true" : "false",
                    i + 1 == N_PAYLOADS ? "" : ",");
        }
        fprintf(jf, "  }\n}\n");
        fclose(jf);
    }

    printf("\nHost: %s · Total corpus: %.1f KB · Wrote bench/results/c.json\n",
           host, (double)total_bytes / 1024.0);
    printf("(sink %llx)\n", (unsigned long long)g_sink);

    if (!all_ok) {
        fprintf(stderr, "\nOne or more payloads failed byte-identity — see above.\n");
        return 1;
    }
    return 0;
}
