/* Codec unit tests. */
#include "struple.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

static char *hexenc(const uint8_t *data, size_t len) {
    char *s = (char *)malloc(len * 2 + 1);
    for (size_t i = 0; i < len; i++) sprintf(s + i * 2, "%02x", data[i]);
    s[len * 2] = 0;
    return s;
}

#define ENC_CHECK(appends, expect)                                              \
    do {                                                                        \
        struple_writer w;                                                       \
        struple_writer_init(&w);                                                \
        appends;                                                                \
        char *h = hexenc(w.data, w.len);                                        \
        if (strcmp(h, expect) != 0) {                                           \
            fprintf(stderr, "FAIL %s: got %s want %s\n", #appends, h, expect);  \
            failures++;                                                         \
        }                                                                       \
        free(h);                                                                \
        struple_writer_free(&w);                                               \
    } while (0)

#define CHECK(cond, msg)                            \
    do {                                            \
        if (!(cond)) {                              \
            fprintf(stderr, "FAIL %s\n", msg);      \
            failures++;                              \
        }                                           \
    } while (0)

static void enc(struple_writer *w, int64_t v) {
    struple_writer_init(w);
    struple_append_int(w, v);
}

static int less(int64_t a, int64_t b) {
    struple_writer wa, wb;
    enc(&wa, a);
    enc(&wb, b);
    int c = struple_compare(wa.data, wa.len, wb.data, wb.len);
    struple_writer_free(&wa);
    struple_writer_free(&wb);
    return c < 0;
}

int main(void) {
    /* golden bytes */
    ENC_CHECK(struple_append_nil(&w), "01");
    ENC_CHECK(struple_append_bool(&w, true), "06");
    ENC_CHECK(struple_append_int(&w, 0), "20");
    ENC_CHECK(struple_append_int(&w, 255), "21ff");
    ENC_CHECK(struple_append_int(&w, 256), "220100");
    ENC_CHECK(struple_append_int(&w, -1), "1fff");
    ENC_CHECK(struple_append_int(&w, -100), "1f9c");
    ENC_CHECK(struple_append_string(&w, "app", 3), "4861707000");
    {
        /* wide integers now use the fixed slots (the i128 range) */
        uint8_t p64[9] = {1, 0, 0, 0, 0, 0, 0, 0, 0}; /* 2^64 */
        ENC_CHECK(struple_append_big_int(&w, false, p64, 9), "29010000000000000000");
        uint8_t imax[16] = {0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
        ENC_CHECK(struple_append_big_int(&w, false, imax, 16), "307fffffffffffffffffffffffffffffff"); /* i128 max */
        uint8_t p127[16] = {0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}; /* 2^127 */
        ENC_CHECK(struple_append_big_int(&w, true, p127, 16), "1080000000000000000000000000000000");   /* i128 min */
        ENC_CHECK(struple_append_big_int(&w, false, p127, 16), "31011080000000000000000000000000000000"); /* first big-int */
    }
    {
        uint8_t u[16] = {0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4, 0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00};
        ENC_CHECK(struple_append_uuid(&w, u), "44550e8400e29b41d4a716446655440000");
    }

    /* int round-trip */
    int64_t cases[] = {0, 1, -1, 255, 256, -256, -257, INT64_MAX, INT64_MIN, 1LL << 40, -(1LL << 40), 1LL << 56};
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        struple_writer w;
        enc(&w, cases[i]);
        struple_reader r;
        struple_reader_init(&r, w.data, w.len);
        struple_element e;
        int rc = struple_reader_next(&r, &e);
        if (rc != 1 || e.kind != STRUPLE_INT || e.int_val != cases[i]) {
            fprintf(stderr, "FAIL round-trip %lld\n", (long long)cases[i]);
            failures++;
        }
        struple_reader_free(&r);
        struple_writer_free(&w);
    }

    /* ordering */
    {
        struple_writer a, b;
        struple_writer_init(&a);
        struple_append_string(&a, "app", 3);
        struple_writer_init(&b);
        struple_append_string(&b, "apple", 5);
        if (struple_compare(a.data, a.len, b.data, b.len) >= 0) {
            fprintf(stderr, "FAIL app < apple\n");
            failures++;
        }
        struple_writer_free(&a);
        struple_writer_free(&b);
    }
    if (!less(-256, -100) || !less(-100, -1) || !less(-1, 0) || !less(0, 1) || !less(255, 256)) {
        fprintf(stderr, "FAIL integer ordering\n");
        failures++;
    }

    /* map canonicalization: insertion order does not affect bytes */
    {
        struple_writer ka, va, kb, vb;
        struple_writer_init(&ka);
        struple_append_string(&ka, "a", 1);
        struple_writer_init(&va);
        struple_append_int(&va, 1);
        struple_writer_init(&kb);
        struple_append_string(&kb, "b", 1);
        struple_writer_init(&vb);
        struple_append_int(&vb, 2);

        struple_kv e1[2] = {{{kb.data, kb.len}, {vb.data, vb.len}}, {{ka.data, ka.len}, {va.data, va.len}}};
        struple_kv e2[2] = {{{ka.data, ka.len}, {va.data, va.len}}, {{kb.data, kb.len}, {vb.data, vb.len}}};
        struple_writer m1, m2;
        struple_writer_init(&m1);
        struple_append_map(&m1, e1, 2);
        struple_writer_init(&m2);
        struple_append_map(&m2, e2, 2);
        if (m1.len != m2.len || memcmp(m1.data, m2.data, m1.len) != 0) {
            fprintf(stderr, "FAIL map canonicalization\n");
            failures++;
        }
        struple_writer_free(&ka);
        struple_writer_free(&va);
        struple_writer_free(&kb);
        struple_writer_free(&vb);
        struple_writer_free(&m1);
        struple_writer_free(&m2);
    }

    /* float ordering + round-trip */
    {
        double fs[] = {-1.0 / 0.0, -1.5, -1.0, 0.0, 1.0, 1.5, 1.0 / 0.0};
        struple_writer prev;
        struple_writer_init(&prev);
        for (size_t i = 0; i < sizeof fs / sizeof fs[0]; i++) {
            struple_writer cur;
            struple_writer_init(&cur);
            struple_append_f64(&cur, fs[i]);
            if (i > 0 && struple_compare(prev.data, prev.len, cur.data, cur.len) >= 0) {
                fprintf(stderr, "FAIL float order at %zu\n", i);
                failures++;
            }
            struple_writer_free(&prev);
            prev = cur;
        }
        struple_writer_free(&prev);

        struple_writer w;
        struple_writer_init(&w);
        struple_append_f64(&w, 0.1);
        struple_reader r;
        struple_reader_init(&r, w.data, w.len);
        struple_element e;
        struple_reader_next(&r, &e);
        if (e.kind != STRUPLE_F64 || e.f64_val != 0.1) {
            fprintf(stderr, "FAIL float round-trip\n");
            failures++;
        }
        struple_reader_free(&r);
        struple_writer_free(&w);
    }

    /* navigation */
    {
        struple_writer p, child;
        struple_writer_init(&p);
        struple_append_string(&p, "users", 5);
        struple_append_int(&p, 12345);
        struple_append_bool(&p, true);
        struple_writer_init(&child);
        struple_append_int(&child, 1);
        struple_append_int(&child, 2);
        struple_append_int(&child, 3);
        struple_append_array(&p, child.data, child.len);

        struple_view v = {p.data, p.len};
        CHECK(struple_view_count(v) == 4, "nav count");
        CHECK(struple_view_is_string(v), "nav is_string");

        struple_view e1;
        struple_view_at(v, 1, &e1);
        struple_reader r1;
        struple_reader_init(&r1, e1.bytes, e1.len);
        struple_element ev;
        struple_reader_next(&r1, &ev);
        CHECK(ev.kind == STRUPLE_INT && ev.int_val == 12345, "nav at(1)");
        struple_reader_free(&r1);

        CHECK(struple_view_count(struple_view_tail(v)) == 3, "nav tail");
        CHECK(struple_view_count(struple_view_take(v, 2)) == 2, "nav take");

        struple_view arr;
        struple_view_at(v, 3, &arr);
        CHECK(struple_view_is_array(arr) && struple_view_is_container(arr), "nav is_array");
        struple_writer inner;
        struple_writer_init(&inner);
        struple_view_contained_items(arr, &inner);
        struple_view iv = {inner.data, inner.len};
        CHECK(struple_view_count(iv) == 3, "nav contained_items");

        struple_writer_free(&inner);
        struple_writer_free(&child);
        struple_writer_free(&p);
    }

    /* map navigation */
    {
        struple_writer ka, va, kb, vb, kc, vc, kz, mp, minner;
        struple_writer_init(&ka); struple_append_string(&ka, "a", 1);
        struple_writer_init(&va); struple_append_int(&va, 1);
        struple_writer_init(&kb); struple_append_string(&kb, "b", 1);
        struple_writer_init(&vb); struple_append_int(&vb, 2);
        struple_writer_init(&kc); struple_append_string(&kc, "c", 1);
        struple_writer_init(&vc); struple_append_int(&vc, 3);
        struple_kv entries[3] = {
            {{kc.data, kc.len}, {vc.data, vc.len}},
            {{ka.data, ka.len}, {va.data, va.len}},
            {{kb.data, kb.len}, {vb.data, vb.len}},
        };
        struple_writer_init(&mp);
        struple_append_map(&mp, entries, 3);
        struple_view mv = {mp.data, mp.len};
        CHECK(struple_view_is_map(mv), "nav is_map");
        struple_writer_init(&minner);
        struple_view_contained_items(mv, &minner);
        struple_map m = {minner.data, minner.len};
        CHECK(struple_map_count(m) == 3, "map count");

        struple_view got;
        if (struple_map_get(m, kb.data, kb.len, &got) == 1) {
            struple_reader r;
            struple_reader_init(&r, got.bytes, got.len);
            struple_element e;
            struple_reader_next(&r, &e);
            CHECK(e.int_val == 2, "map get value");
            struple_reader_free(&r);
        } else {
            CHECK(0, "map get hit");
        }
        struple_writer_init(&kz); struple_append_string(&kz, "z", 1);
        struple_view dummy;
        CHECK(struple_map_get(m, kz.data, kz.len, &dummy) == 0, "map get miss");

        struple_writer_free(&ka); struple_writer_free(&va);
        struple_writer_free(&kb); struple_writer_free(&vb);
        struple_writer_free(&kc); struple_writer_free(&vc);
        struple_writer_free(&kz); struple_writer_free(&mp); struple_writer_free(&minner);
    }

    /* indexed map (O(log n) get, positional at) */
    {
        /* eight entries "a".."h" -> 1..8, fed out of order so canonicalization sorts them */
        const char *order = "hcagdfbe";
        struple_writer kw[8], vw[8];
        struple_kv entries[8];
        for (int i = 0; i < 8; i++) {
            struple_writer_init(&kw[i]);
            struple_append_string(&kw[i], &order[i], 1);
            struple_writer_init(&vw[i]);
            struple_append_int(&vw[i], i + 1); /* value = insertion index + 1 */
            entries[i].key = (struple_bytes){kw[i].data, kw[i].len};
            entries[i].value = (struple_bytes){vw[i].data, vw[i].len};
        }
        struple_writer mp, minner;
        struple_writer_init(&mp);
        struple_append_map(&mp, entries, 8); /* sorts the entries array in place */
        struple_view mv = {mp.data, mp.len};
        struple_writer_init(&minner);
        struple_view_contained_items(mv, &minner);
        struple_map m = {minner.data, minner.len};

        struple_indexed_map im;
        CHECK(struple_indexed_map_init(&im, minner.data, minner.len) == 0, "indexed init");
        CHECK(struple_indexed_map_count(&im) == 8, "indexed count");

        /* at() walks canonical (sorted) order: a,b,c,...,h */
        for (int i = 0; i < 8; i++) {
            struple_indexed_entry e;
            CHECK(struple_indexed_map_at(&im, (size_t)i, &e) == 1, "indexed at in range");
            struple_reader r;
            struple_reader_init(&r, e.key, e.key_len);
            struple_element el;
            struple_reader_next(&r, &el);
            CHECK(el.kind == STRUPLE_STRING && el.data_len == 1 && el.data[0] == (uint8_t)('a' + i),
                  "indexed at sorted key");
            struple_reader_free(&r);
        }
        struple_indexed_entry oob;
        CHECK(struple_indexed_map_at(&im, 8, &oob) == 0, "indexed at out of range");

        /* get() binary-searches; agrees with the linear map get on every key */
        for (int i = 0; i < 8; i++) {
            char ch = (char)('a' + i);
            struple_writer kq;
            struple_writer_init(&kq);
            struple_append_string(&kq, &ch, 1);
            struple_view linear, indexed;
            int lr = struple_map_get(m, kq.data, kq.len, &linear);
            int ir = struple_indexed_map_get(&im, kq.data, kq.len, &indexed);
            CHECK(lr == 1 && ir == 1, "indexed get hit");
            CHECK(lr == ir &&
                  struple_compare(linear.bytes, linear.len, indexed.bytes, indexed.len) == 0,
                  "indexed get agrees with linear get");
            struple_writer_free(&kq);
        }

        /* "e" was inserted 8th (value 8) but sits at sorted position 4 — get still finds it */
        {
            struple_writer ke;
            struple_writer_init(&ke);
            struple_append_string(&ke, "e", 1);
            size_t idx;
            CHECK(struple_indexed_map_find(&im, ke.data, ke.len, &idx) == 1 && idx == 4,
                  "indexed find(e)==4");
            struple_view got;
            CHECK(struple_indexed_map_get(&im, ke.data, ke.len, &got) == 1, "indexed get(e) hit");
            struple_reader r;
            struple_reader_init(&r, got.bytes, got.len);
            struple_element el;
            struple_reader_next(&r, &el);
            CHECK(el.kind == STRUPLE_INT && el.int_val == 8, "indexed get(e)==8");
            struple_reader_free(&r);
            struple_writer_free(&ke);
        }

        /* misses: before, between, and after the key range */
        {
            const char *misses[3] = {"A", "cc", "z"}; /* below "a", between c/d, above "h" */
            size_t mlen[3] = {1, 2, 1};
            for (int i = 0; i < 3; i++) {
                struple_writer km;
                struple_writer_init(&km);
                struple_append_string(&km, misses[i], mlen[i]);
                struple_view got;
                size_t idx;
                CHECK(struple_indexed_map_get(&im, km.data, km.len, &got) == 0, "indexed get miss");
                CHECK(struple_indexed_map_find(&im, km.data, km.len, &idx) == 0, "indexed find miss");
                struple_writer_free(&km);
            }
        }

        /* find at the ends */
        {
            struple_writer ka, kh;
            struple_writer_init(&ka);
            struple_append_string(&ka, "a", 1);
            struple_writer_init(&kh);
            struple_append_string(&kh, "h", 1);
            size_t idx;
            CHECK(struple_indexed_map_find(&im, ka.data, ka.len, &idx) == 1 && idx == 0,
                  "indexed find(a)==0");
            CHECK(struple_indexed_map_find(&im, kh.data, kh.len, &idx) == 1 && idx == 7,
                  "indexed find(h)==7");
            struple_writer_free(&ka);
            struple_writer_free(&kh);
        }

        struple_indexed_map_free(&im);
        for (int i = 0; i < 8; i++) {
            struple_writer_free(&kw[i]);
            struple_writer_free(&vw[i]);
        }
        struple_writer_free(&mp);
        struple_writer_free(&minner);
    }

    if (failures == 0)
        printf("test_struple: all checks passed\n");
    else
        printf("test_struple: %d failures\n", failures);
    return failures ? 1 : 0;
}
