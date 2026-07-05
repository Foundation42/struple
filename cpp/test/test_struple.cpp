// Codec unit tests.
#include "struple.hpp"
#include "struple_json.hpp"

#include <cstdio>
#include <string>

using namespace struple;

static int fails = 0;

static std::string hex(const Bytes& b) {
    std::string s;
    char t[3];
    for (auto x : b) {
        std::snprintf(t, sizeof t, "%02x", x);
        s += t;
    }
    return s;
}

#define CHECK(cond, msg)                              \
    do {                                              \
        if (!(cond)) {                                \
            std::fprintf(stderr, "FAIL %s\n", msg);   \
            fails++;                                   \
        }                                             \
    } while (0)

int main() {
    // golden bytes
    CHECK(hex(pack(nullptr)) == "01", "nil");
    CHECK(hex(pack(true)) == "06", "true");
    CHECK(hex(pack(int64_t(0))) == "20", "zero");
    CHECK(hex(pack(int64_t(255))) == "21ff", "255");
    CHECK(hex(pack(int64_t(256))) == "220100", "256");
    CHECK(hex(pack(int64_t(-1))) == "1fff", "-1");
    CHECK(hex(pack(int64_t(-100))) == "1f9c", "-100");
    CHECK(hex(pack("app")) == "4861707000", "app");
    {
        // wide integers now use the fixed slots (the i128 range)
        Writer w;
        uint8_t p64[9] = {1, 0, 0, 0, 0, 0, 0, 0, 0}; // 2^64
        w.append_big_int(false, p64, 9);
        CHECK(hex(w.bytes()) == "29010000000000000000", "2^64");

        Writer w2;
        uint8_t imax[16] = {0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
        w2.append_big_int(false, imax, 16);
        CHECK(hex(w2.bytes()) == "307fffffffffffffffffffffffffffffff", "i128 max");

        Writer w3;
        uint8_t p127[16] = {0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}; // 2^127
        w3.append_big_int(true, p127, 16);
        CHECK(hex(w3.bytes()) == "1080000000000000000000000000000000", "i128 min");

        Writer w4;
        w4.append_big_int(false, p127, 16);
        CHECK(hex(w4.bytes()) == "31011080000000000000000000000000000000", "first big-int");
    }
    {
        Writer w;
        uint8_t u[16] = {0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4, 0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00};
        w.append_uuid(u);
        CHECK(hex(w.bytes()) == "44550e8400e29b41d4a716446655440000", "uuid");
    }

    // int round-trip
    int64_t cases[] = {0, 1, -1, 255, 256, -256, -257, INT64_MAX, INT64_MIN, 1LL << 40, -(1LL << 40), 1LL << 56};
    for (int64_t v : cases) {
        Bytes enc = pack(v);
        Reader r(enc);
        auto e = r.next();
        if (!e || e->kind != Kind::Int || e->integer != v) {
            std::fprintf(stderr, "FAIL round-trip %lld\n", (long long)v);
            fails++;
        }
    }

    // ordering
    CHECK(compare(pack("app"), pack("apple")) < 0, "app < apple");
    CHECK(pack(int64_t(-256)) < pack(int64_t(-100)), "-256 < -100");
    CHECK(pack(int64_t(-100)) < pack(int64_t(-1)), "-100 < -1");
    CHECK(pack(int64_t(0)) < pack(int64_t(1)), "0 < 1");
    CHECK(pack(int64_t(255)) < pack(int64_t(256)), "255 < 256");

    // map canonicalization: insertion order does not affect bytes
    {
        Bytes ka = pack("a"), va = pack(int64_t(1)), kb = pack("b"), vb = pack(int64_t(2));
        Writer m1, m2;
        m1.append_map({{kb, vb}, {ka, va}});
        m2.append_map({{ka, va}, {kb, vb}});
        CHECK(m1.bytes() == m2.bytes(), "map canonicalization");
    }

    // float ordering + round-trip
    {
        double fs[] = {-1.0 / 0.0, -1.5, -1.0, 0.0, 1.0, 1.5, 1.0 / 0.0};
        Bytes prev;
        for (size_t i = 0; i < sizeof fs / sizeof fs[0]; i++) {
            Writer w;
            w.append_f64(fs[i]);
            if (i > 0 && !(prev < w.bytes())) {
                std::fprintf(stderr, "FAIL float order %zu\n", i);
                fails++;
            }
            prev = w.bytes();
        }
        Writer w;
        w.append_f64(0.1);
        Reader r(w.bytes());
        auto e = r.next();
        CHECK(e && e->kind == Kind::F64 && e->f64 == 0.1, "float round-trip");
    }

    // decimal golden bytes + canonicalization
    {
        auto dec = [](const char* s) { Writer w; w.appendDecimalString(s); return hex(w.bytes()); };
        CHECK(dec("12.345") == "380321020d233300", "decimal 12.345");
        CHECK(dec("-12.345") == "3801defdf2dcccff", "decimal -12.345");
        CHECK(dec("0") == "3802", "decimal 0");
        CHECK(dec("0.0") == "3802", "decimal 0.0 canonical zero");
        CHECK(dec("100") == "380321030b00", "decimal 100");
        CHECK(dec("12.300") == dec("12.3"), "decimal trailing-zero canonicalization");
        CHECK(dec("1e-9") == "38031ff80b00", "decimal 1e-9");
    }

    // decimal round-trip (sign, coefficient digits, exponent)
    {
        Writer w;
        w.appendDecimalString("-12.345");
        Reader r(w.bytes());
        auto e = r.next();
        bool ok = e && e->kind == Kind::Decimal && e->big_negative && e->dec_exp == -3 &&
                  e->data == Bytes({1, 2, 3, 4, 5});
        CHECK(ok, "decimal round-trip -12.345");

        Writer wz;
        wz.appendDecimalString("0");
        Reader rz(wz.bytes());
        auto ez = rz.next();
        CHECK(ez && ez->kind == Kind::Decimal && ez->decIsZero(), "decimal zero round-trip");
    }

    // decimal memcmp ordering: negative < zero < positive, magnitude within sign
    {
        const char* ascending[] = {"-100", "-12.345", "-0.5", "0", "0.001", "1.5", "12.345", "100"};
        Bytes prev;
        for (size_t i = 0; i < sizeof ascending / sizeof ascending[0]; i++) {
            Writer w;
            w.appendDecimalString(ascending[i]);
            if (i > 0 && !(prev < w.bytes())) {
                std::fprintf(stderr, "FAIL decimal order at %zu (%s)\n", i, ascending[i]);
                fails++;
            }
            prev = w.bytes();
        }
    }

    // navigation
    {
        Writer child;
        child.append_int(1).append_int(2).append_int(3);
        Writer p;
        p.append_string("users").append_int(12345).append_bool(true).append_array(child.bytes());
        Bytes buf = p.take();

        View v(buf);
        CHECK(v.count() == 4, "nav count");
        CHECK(v.isString(), "nav is_string");

        auto e1 = v.at(1);
        CHECK(e1.has_value(), "nav at exists");
        if (e1) {
            Reader r(e1->data(), e1->size());
            auto el = r.next();
            CHECK(el && el->kind == Kind::Int && el->integer == 12345, "nav at(1)");
        }
        CHECK(View(v.tail()).count() == 3, "nav tail");
        CHECK(View(v.take(2)).count() == 2, "nav take");

        auto arr = v.at(3);
        CHECK(arr && arr->isArray() && arr->isContainer(), "nav is_array");
        auto inner = arr->containedItems();
        CHECK(inner.has_value(), "nav contained exists");
        if (inner) CHECK(View(*inner).count() == 3, "nav contained_items");
    }

    // map navigation
    {
        Bytes ka = pack("a"), va = pack(int64_t(1)), kb = pack("b"), vb = pack(int64_t(2)), kc = pack("c"), vc = pack(int64_t(3));
        Writer mp;
        mp.append_map({{kc, vc}, {ka, va}, {kb, vb}});
        Bytes mapbuf = mp.take();

        View mv(mapbuf);
        CHECK(mv.isMap(), "nav is_map");
        auto inner = mv.containedItems();
        CHECK(inner.has_value(), "map inner");
        if (inner) {
            MapView m(*inner);
            CHECK(m.count() == 3, "map count");
            auto got = m.get(kb);
            CHECK(got.has_value(), "map get hit");
            if (got) {
                Reader r(got->data, got->size);
                auto e = r.next();
                CHECK(e && e->integer == 2, "map get value");
            }
            CHECK(!m.get(pack("z")).has_value(), "map get miss");

            auto it = m.iterator();
            std::vector<std::string> keys;
            while (auto e = it.next()) {
                Reader r(e->key.data, e->key.size);
                keys.push_back(r.next()->str);
            }
            CHECK(keys.size() == 3 && keys[0] == "a" && keys[2] == "c", "map iterator order");
        }
    }

    // indexed map (O(log n) get, positional at)
    {
        // eight entries "a".."h" -> 1..8, fed out of order so canonicalization sorts them
        const char* keys = "hcagdfbe";
        std::vector<std::pair<Bytes, Bytes>> entries;
        for (size_t i = 0; i < 8; i++)
            entries.push_back({pack(std::string(1, keys[i])), pack(int64_t(i + 1))});
        Writer mp;
        mp.append_map(entries);
        Bytes mapbuf = mp.take();

        View mv(mapbuf);
        auto inner = mv.containedItems();
        CHECK(inner.has_value(), "idx inner");
        if (inner) {
            MapView m(*inner);
            IndexedMap im(*inner);

            CHECK(im.count() == 8, "idx count");
            CHECK(im.size() == 8, "idx size");

            // at() walks canonical (sorted) order: a,b,c,...,h
            bool at_ok = true;
            for (size_t i = 0; i < 8; i++) {
                auto e = im.at(i);
                if (!e) { at_ok = false; break; }
                Reader r(e->key.data, e->key.size);
                auto el = r.next();
                if (!el || el->kind != Kind::String || el->str != std::string(1, char('a' + i)))
                    at_ok = false;
            }
            CHECK(at_ok, "idx at sorted order");
            CHECK(!im.at(8).has_value(), "idx at out of range");

            // get() binary-searches; agrees with the linear MapView.get on every key
            bool get_ok = true;
            for (char ch = 'a'; ch <= 'h'; ch++) {
                Bytes key = pack(std::string(1, ch));
                auto want = m.get(key);
                auto got = im.get(key);
                if (!want || !got ||
                    compare(want->data, want->size, got->data, got->size) != 0)
                    get_ok = false;
            }
            CHECK(get_ok, "idx get agrees with linear");

            // "e" was inserted 8th (value 8) but sits at sorted position 4
            auto fe = im.find(pack(std::string("e")));
            CHECK(fe.has_value() && *fe == 4, "idx find e == 4");
            auto ve = im.get(pack(std::string("e")));
            CHECK(ve.has_value(), "idx get e hit");
            if (ve) {
                Reader r(ve->data, ve->size);
                auto el = r.next();
                CHECK(el && el->kind == Kind::Int && el->integer == 8, "idx get e == 8");
            }

            // misses: before, between, and after the key range
            CHECK(!im.get(pack(std::string("A"))).has_value(), "idx miss below");
            CHECK(!im.get(pack(std::string("cc"))).has_value(), "idx miss between");
            CHECK(!im.get(pack(std::string("z"))).has_value(), "idx miss above");

            auto fa = im.find(pack(std::string("a")));
            auto fh = im.find(pack(std::string("h")));
            CHECK(fa.has_value() && *fa == 0, "idx find a == 0");
            CHECK(fh.has_value() && *fh == 7, "idx find h == 7");

            // iteration yields the 8 entries in canonical order
            size_t n = 0;
            std::vector<std::string> order;
            for (const auto& e : im) {
                Reader r(e.key.data, e.key.size);
                order.push_back(r.next()->str);
                n++;
            }
            CHECK(n == 8, "idx iter count");
            CHECK(order.size() == 8 && order.front() == "a" && order.back() == "h",
                  "idx iter order");

            // the indexed() shortcut on MapView yields the same index
            IndexedMap im2 = m.indexed();
            CHECK(im2.count() == 8, "idx shortcut count");
        }
    }

    // depth cap: deeply nested input is rejected (struple::Error), not a crash.
    // Mirrors src/tests.zig "depth cap".
    {
        // from_json: a 1000-deep bracket string (> MAX_DEPTH) must throw, not SIGSEGV.
        std::string deep = std::string(1000, '[') + std::string(1000, ']');
        bool threw = false;
        try { from_json(deep); } catch (const Error&) { threw = true; }
        CHECK(threw, "depth cap: from_json 1000-deep throws");

        // Build a 300-deep nested array via the Writer (wrap the prior bytes 300x),
        // then to_json / semanticOrder must reject at the cap rather than recurse
        // to a stack overflow.
        Bytes buf;
        {
            Writer inner;
            inner.append_int(0);
            buf = inner.take();
        }
        for (int d = 0; d < 300; d++) {
            Writer p;
            p.append_array(buf);
            buf = p.take();
        }
        bool tj_threw = false;
        try { to_json(buf); } catch (const Error&) { tj_threw = true; }
        CHECK(tj_threw, "depth cap: to_json 300-deep throws");

        bool so_threw = false;
        try { semanticOrder(buf, buf); } catch (const Error&) { so_threw = true; }
        CHECK(so_threw, "depth cap: semanticOrder 300-deep throws");
    }

    if (fails == 0)
        std::printf("test_struple: all checks passed\n");
    else
        std::printf("test_struple: %d failures\n", fails);
    return fails ? 1 : 0;
}
