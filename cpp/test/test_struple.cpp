// Codec unit tests.
#include "struple.hpp"

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
        Writer w;
        uint8_t mag[9] = {1, 0, 0, 0, 0, 0, 0, 0, 0};
        w.append_big_int(false, mag, 9);
        CHECK(hex(w.bytes()) == "310109010000000000000000", "2^64");
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

    if (fails == 0)
        std::printf("test_struple: all checks passed\n");
    else
        std::printf("test_struple: %d failures\n", fails);
    return fails ? 1 : 0;
}
