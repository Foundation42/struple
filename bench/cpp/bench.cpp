// struple reference benchmark (C++17).
//
// Mirrors bench/zig/bench.zig and bench/js/bench.ts: encode (build a framed
// stream from prepared in-memory records) and decode (walk the whole stream,
// descending and un-escaping every container body and touching every scalar)
// throughput for the seven shared workloads — four realistic streaming shapes
// (stock quotes, geospatial points, tweets, blockchain transactions) plus three
// structural micro-benchmarks (an integer stream, a string stream, a nested
// document).
//
// The native records are parsed from bench/data/<name>.json once (setup,
// untimed) with a tiny tokenizer for the simple array-of-typed-strings shape;
// the encoder then rebuilds the bytes with the same appendX sequence the Zig and
// JS references use. Byte-identity is verified against bench/payloads.json
// (sha256 — a self-contained implementation below) before any throughput figure
// is reported.
//
// Methodology (per (payload, op)): 5 warm-up runs, auto-calibrate the iteration
// count to a ~100 ms trial, then 9 trials — the MEDIAN ns/op is reported. A
// global volatile checksum sink consumes every result so the optimizer can't
// elide the work. Steady-state buffers retain capacity. Single-threaded.
//
// Zero dependencies beyond the C++17 standard library and cpp/include/struple.
//
// Build & run (from repo root /home/chrisbe/dev/struple):
//   g++ -std=c++17 -O2 -Icpp/include -o bench/cpp/bench bench/cpp/bench.cpp
//   ./bench/cpp/bench
// (paths to bench/payloads.json and bench/data/*.json are resolved relative to
//  the repo root, so run from there; or pass the repo root as argv[1].)

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "struple.hpp"

using struple::Bytes;
using struple::Reader;
using struple::Writer;
using struple::Kind;

// ---------------------------------------------------------------------------
// DCE sink — every measured op folds something into this so the optimizer must
// actually perform the work. A volatile u64 accumulator mirrors the Zig
// `g_sink: u64` (wrapping add) exactly.
// ---------------------------------------------------------------------------
static volatile uint64_t g_sink = 0;
static inline void sink(uint64_t v) { g_sink = g_sink + v; }

// ---------------------------------------------------------------------------
// A minimal SHA-256 (FIPS 180-4) — self-contained so sha256_ok is real.
// ---------------------------------------------------------------------------
namespace sha256 {
struct Ctx {
    uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                     0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    uint64_t len = 0;
    uint8_t buf[64];
    size_t buflen = 0;
};
static inline uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }
static void block(Ctx& c, const uint8_t* p) {
    static const uint32_t k[64] = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = (uint32_t(p[i * 4]) << 24) | (uint32_t(p[i * 4 + 1]) << 16) |
               (uint32_t(p[i * 4 + 2]) << 8) | uint32_t(p[i * 4 + 3]);
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = c.h[0], b = c.h[1], cc = c.h[2], d = c.h[3], e = c.h[4], f = c.h[5], g = c.h[6], h = c.h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t1 = h + S1 + ch + k[i] + w[i];
        uint32_t S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        uint32_t maj = (a & b) ^ (a & cc) ^ (b & cc);
        uint32_t t2 = S0 + maj;
        h = g; g = f; f = e; e = d + t1; d = cc; cc = b; b = a; a = t1 + t2;
    }
    c.h[0] += a; c.h[1] += b; c.h[2] += cc; c.h[3] += d;
    c.h[4] += e; c.h[5] += f; c.h[6] += g; c.h[7] += h;
}
static void update(Ctx& c, const uint8_t* data, size_t n) {
    c.len += n;
    while (n) {
        size_t take = 64 - c.buflen;
        if (take > n) take = n;
        std::memcpy(c.buf + c.buflen, data, take);
        c.buflen += take;
        data += take;
        n -= take;
        if (c.buflen == 64) { block(c, c.buf); c.buflen = 0; }
    }
}
static std::string hex(Ctx c) {
    uint64_t bits = c.len * 8;
    uint8_t pad = 0x80;
    update(c, &pad, 1);
    uint8_t zero = 0;
    while (c.buflen != 56) update(c, &zero, 1);
    uint8_t lenbytes[8];
    for (int i = 0; i < 8; i++) lenbytes[i] = uint8_t(bits >> (8 * (7 - i)));
    update(c, lenbytes, 8);
    static const char* hx = "0123456789abcdef";
    std::string out;
    out.reserve(64);
    for (int i = 0; i < 8; i++)
        for (int j = 3; j >= 0; j--) {
            uint8_t byte = uint8_t(c.h[i] >> (8 * j));
            out.push_back(hx[byte >> 4]);
            out.push_back(hx[byte & 0xf]);
        }
    return out;
}
static std::string of(const Bytes& b) {
    Ctx c;
    update(c, b.data(), b.size());
    return hex(c);
}
}  // namespace sha256

// ---------------------------------------------------------------------------
// Tiny JSON tokenizer for the SIMPLE shared-data shape: arrays of arrays of
// quoted strings (the structural payloads are a flat array of strings). Handles
// only `[` `]` `,` and `"`-quoted strings with \" \\ and \uXXXX escapes.
// ---------------------------------------------------------------------------
namespace tinyjson {

struct Parser {
    const char* p;
    const char* end;
    explicit Parser(const std::string& s) : p(s.data()), end(s.data() + s.size()) {}

    void skip_ws() {
        while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
    }
    char peek() {
        skip_ws();
        return p < end ? *p : '\0';
    }
    void expect(char c) {
        skip_ws();
        if (p >= end || *p != c) throw std::runtime_error("tinyjson: expected a token");
        p++;
    }

    // Parse a "..."-quoted string, applying escapes; appends UTF-8 to `out`.
    void parse_string(std::string& out) {
        skip_ws();
        if (p >= end || *p != '"') throw std::runtime_error("tinyjson: expected string");
        p++;
        while (p < end && *p != '"') {
            char c = *p++;
            if (c != '\\') {
                out.push_back(c);
                continue;
            }
            if (p >= end) throw std::runtime_error("tinyjson: dangling escape");
            char e = *p++;
            switch (e) {
                case '"': out.push_back('"'); break;
                case '\\': out.push_back('\\'); break;
                case '/': out.push_back('/'); break;
                case 'b': out.push_back('\b'); break;
                case 'f': out.push_back('\f'); break;
                case 'n': out.push_back('\n'); break;
                case 'r': out.push_back('\r'); break;
                case 't': out.push_back('\t'); break;
                case 'u': {
                    if (p + 4 > end) throw std::runtime_error("tinyjson: short \\u");
                    unsigned cp = 0;
                    for (int i = 0; i < 4; i++) {
                        char h = *p++;
                        cp <<= 4;
                        if (h >= '0' && h <= '9') cp |= unsigned(h - '0');
                        else if (h >= 'a' && h <= 'f') cp |= unsigned(h - 'a' + 10);
                        else if (h >= 'A' && h <= 'F') cp |= unsigned(h - 'A' + 10);
                        else throw std::runtime_error("tinyjson: bad hex");
                    }
                    // The shared data never emits surrogate pairs (all escapes are
                    // control chars < 0x20, per the Zig emitter), so a plain
                    // BMP-codepoint -> UTF-8 expansion is exact here.
                    if (cp < 0x80) {
                        out.push_back(char(cp));
                    } else if (cp < 0x800) {
                        out.push_back(char(0xc0 | (cp >> 6)));
                        out.push_back(char(0x80 | (cp & 0x3f)));
                    } else {
                        out.push_back(char(0xe0 | (cp >> 12)));
                        out.push_back(char(0x80 | ((cp >> 6) & 0x3f)));
                        out.push_back(char(0x80 | (cp & 0x3f)));
                    }
                    break;
                }
                default: throw std::runtime_error("tinyjson: bad escape");
            }
        }
        if (p >= end) throw std::runtime_error("tinyjson: unterminated string");
        p++;  // closing quote
    }

    std::string parse_string() {
        std::string s;
        parse_string(s);
        return s;
    }
};

// Parse a flat array of strings: ["a","b",...]
std::vector<std::string> parse_string_array(const std::string& text) {
    Parser ps(text);
    std::vector<std::string> out;
    ps.expect('[');
    if (ps.peek() == ']') { ps.p++; return out; }
    for (;;) {
        out.push_back(ps.parse_string());
        char c = ps.peek();
        if (c == ',') { ps.p++; continue; }
        if (c == ']') { ps.p++; break; }
        throw std::runtime_error("tinyjson: expected , or ]");
    }
    return out;
}

// Parse an array of rows, where each row is an array of strings:
// [["a","b"],["c","d"],...]
std::vector<std::vector<std::string>> parse_rows(const std::string& text) {
    Parser ps(text);
    std::vector<std::vector<std::string>> out;
    ps.expect('[');
    if (ps.peek() == ']') { ps.p++; return out; }
    for (;;) {
        ps.expect('[');
        std::vector<std::string> row;
        if (ps.peek() != ']') {
            for (;;) {
                row.push_back(ps.parse_string());
                char c = ps.peek();
                if (c == ',') { ps.p++; continue; }
                if (c == ']') break;
                throw std::runtime_error("tinyjson: expected , or ] in row");
            }
        }
        ps.expect(']');
        out.push_back(std::move(row));
        char c = ps.peek();
        if (c == ',') { ps.p++; continue; }
        if (c == ']') { ps.p++; break; }
        throw std::runtime_error("tinyjson: expected , or ] between rows");
    }
    return out;
}

}  // namespace tinyjson

// ---------------------------------------------------------------------------
// Numeric parsing helpers — the shared data fields are all typed strings.
// ---------------------------------------------------------------------------

// decimal int64 string -> int64 (exact; the data fits i64 for these fields).
static int64_t parse_i64(const std::string& s) {
    int64_t v = 0;
    size_t i = 0;
    bool neg = false;
    if (i < s.size() && (s[i] == '+' || s[i] == '-')) { neg = s[i] == '-'; i++; }
    for (; i < s.size(); i++) v = v * 10 + (s[i] - '0');
    return neg ? -v : v;
}

// decimal u64 string -> u64 (exact for values up to 2^64-1, e.g. tweet ids).
static uint64_t parse_u64(const std::string& s) {
    uint64_t v = 0;
    for (char c : s) v = v * 10 + uint64_t(c - '0');
    return v;
}

// 16-hex IEEE-754 bits (big-endian) -> double.
static double f64_from_hex(const std::string& hex) {
    uint64_t bits = 0;
    for (char c : hex) {
        bits <<= 4;
        if (c >= '0' && c <= '9') bits |= uint64_t(c - '0');
        else if (c >= 'a' && c <= 'f') bits |= uint64_t(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') bits |= uint64_t(c - 'A' + 10);
    }
    double d;
    std::memcpy(&d, &bits, 8);
    return d;
}

static inline uint8_t hex_nibble(char c) {
    if (c >= '0' && c <= '9') return uint8_t(c - '0');
    if (c >= 'a' && c <= 'f') return uint8_t(c - 'a' + 10);
    return uint8_t(c - 'A' + 10);
}

// even-length hex string -> bytes.
static Bytes bytes_from_hex(const std::string& hex) {
    Bytes out(hex.size() / 2);
    for (size_t i = 0; i < out.size(); i++)
        out[i] = uint8_t((hex_nibble(hex[i * 2]) << 4) | hex_nibble(hex[i * 2 + 1]));
    return out;
}

// digit string "12345" -> [1,2,3,4,5]
static Bytes digits_from_str(const std::string& s) {
    Bytes out(s.size());
    for (size_t i = 0; i < s.size(); i++) out[i] = uint8_t(s[i] - '0');
    return out;
}

// ---------------------------------------------------------------------------
// Native record shapes (parsed once from the shared JSON data).
// ---------------------------------------------------------------------------

struct Dec {
    Bytes digits;  // coefficient digits, MSD-first, each 0–9
    int64_t exp;
};
struct Quote {
    std::string symbol;
    Dec bid, ask;
    double last;
    int64_t volume;
    int64_t ts;
};
struct Geo {
    double lat, lon, elevation;
    std::string name;
    int64_t ts;
};
struct Tweet {
    uint64_t id;  // u64
    std::string user, text;
    int64_t created_at, likes, retweets;
};
struct Tx {
    int64_t height;
    Bytes tx_hash, from, to;
    Bytes value_mag;  // big-endian magnitude of the wei value (both fix & big paths)
    int64_t gas, nonce, ts;
};
struct Nested {
    int64_t uid;
    std::string name;
    bool active;
    int64_t scores[3];
};

struct Data {
    std::vector<Quote> quotes;
    std::vector<Geo> geo;
    std::vector<Tweet> tweets;
    std::vector<Tx> txs;
    std::vector<int64_t> ints;
    std::vector<std::string> strings;
    std::vector<Nested> nested;
};

enum class PKind { Quotes, Geo, Tweets, Txs, Ints, Strings, Nested };

struct PayloadMeta {
    PKind kind;
    const char* name;
    const char* category;
};

static const std::array<PayloadMeta, 7> payloads = {{
    {PKind::Quotes, "stock_quotes", "streaming"},
    {PKind::Geo, "geo_points", "streaming"},
    {PKind::Tweets, "tweets", "streaming"},
    {PKind::Txs, "blockchain_txs", "streaming"},
    {PKind::Ints, "int_stream", "structural"},
    {PKind::Strings, "string_stream", "structural"},
    {PKind::Nested, "nested_doc", "structural"},
}};

// ---------------------------------------------------------------------------
// Data loading.
// ---------------------------------------------------------------------------

static std::string read_file(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("cannot open " + path);
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

static Data read_data(const std::string& data_dir) {
    auto load = [&](const char* name) {
        return read_file(data_dir + "/" + name + std::string(".json"));
    };

    Data d;

    {
        auto rows = tinyjson::parse_rows(load("stock_quotes"));
        d.quotes.reserve(rows.size());
        for (auto& r : rows) {
            Quote q;
            q.symbol = r[0];
            q.bid = {digits_from_str(r[1]), parse_i64(r[2])};
            q.ask = {digits_from_str(r[3]), parse_i64(r[4])};
            q.last = f64_from_hex(r[5]);
            q.volume = parse_i64(r[6]);
            q.ts = parse_i64(r[7]);
            d.quotes.push_back(std::move(q));
        }
    }
    {
        auto rows = tinyjson::parse_rows(load("geo_points"));
        d.geo.reserve(rows.size());
        for (auto& r : rows) {
            Geo g;
            g.lat = f64_from_hex(r[0]);
            g.lon = f64_from_hex(r[1]);
            g.elevation = f64_from_hex(r[2]);
            g.name = r[3];
            g.ts = parse_i64(r[4]);
            d.geo.push_back(std::move(g));
        }
    }
    {
        auto rows = tinyjson::parse_rows(load("tweets"));
        d.tweets.reserve(rows.size());
        for (auto& r : rows) {
            Tweet t;
            t.id = parse_u64(r[0]);
            t.user = r[1];
            t.text = r[2];
            t.created_at = parse_i64(r[3]);
            t.likes = parse_i64(r[4]);
            t.retweets = parse_i64(r[5]);
            d.tweets.push_back(std::move(t));
        }
    }
    {
        auto rows = tinyjson::parse_rows(load("blockchain_txs"));
        d.txs.reserve(rows.size());
        for (auto& r : rows) {
            Tx x;
            x.height = parse_i64(r[0]);
            x.tx_hash = bytes_from_hex(r[1]);
            x.from = bytes_from_hex(r[2]);
            x.to = bytes_from_hex(r[3]);
            // r[4] is "big"|"fix"; r[5] is the big-endian hex magnitude. Both
            // collapse to a sign+magnitude big-int append (the codec routes
            // i128-range magnitudes through the fixed slots and wider ones
            // through the big-int codes — byte-identical to the Zig
            // appendI128 / appendBigInt split).
            x.value_mag = bytes_from_hex(r[5]);
            x.gas = parse_i64(r[6]);
            x.nonce = parse_i64(r[7]);
            x.ts = parse_i64(r[8]);
            d.txs.push_back(std::move(x));
        }
    }
    {
        auto arr = tinyjson::parse_string_array(load("int_stream"));
        d.ints.reserve(arr.size());
        for (auto& s : arr) d.ints.push_back(parse_i64(s));
    }
    {
        d.strings = tinyjson::parse_string_array(load("string_stream"));
    }
    {
        auto rows = tinyjson::parse_rows(load("nested_doc"));
        d.nested.reserve(rows.size());
        for (auto& r : rows) {
            Nested n;
            n.active = r[0] == "1";
            n.uid = parse_i64(r[1]);
            n.name = r[2];
            n.scores[0] = parse_i64(r[3]);
            n.scores[1] = parse_i64(r[4]);
            n.scores[2] = parse_i64(r[5]);
            d.nested.push_back(std::move(n));
        }
    }
    return d;
}

// ---------------------------------------------------------------------------
// Encoders — one per payload kind. `out` is reset by the caller each iteration;
// a single reused `scratch` Writer frames one record at a time. Mirrors
// encodeOnce in bench/zig/bench.zig (and the JS port).
// ---------------------------------------------------------------------------

// Pre-encoded constant keys for the nested-doc map (the keys never change; the
// Zig harness re-encodes them per record from an arena, but the keys are
// invariant, so caching them is byte-identical and avoids needless work — the
// same simplification the JS port uses).
static const Bytes KEY_ACTIVE = []() { Writer w; w.append_string("active"); return w.take(); }();
static const Bytes KEY_SCORES = []() { Writer w; w.append_string("scores"); return w.take(); }();
static const Bytes KEY_USER = []() { Writer w; w.append_string("user"); return w.take(); }();
static const Bytes KEY_ID = []() { Writer w; w.append_string("id"); return w.take(); }();
static const Bytes KEY_NAME = []() { Writer w; w.append_string("name"); return w.take(); }();

static inline Bytes enc_int(int64_t v) { Writer w; w.append_int(v); return w.take(); }
static inline Bytes enc_str(const std::string& s) { Writer w; w.append_string(s); return w.take(); }
static inline Bytes enc_bool(bool v) { Writer w; w.append_bool(v); return w.take(); }

static void encode_once(PKind kind, const Data& d, Writer& out, Writer& scratch) {
    switch (kind) {
        case PKind::Quotes:
            for (const auto& q : d.quotes) {
                scratch.clear();
                scratch.append_string(q.symbol);
                scratch.append_decimal(false, q.bid.digits, q.bid.exp);
                scratch.append_decimal(false, q.ask.digits, q.ask.exp);
                scratch.append_f64(q.last);
                scratch.append_int(q.volume);
                scratch.append_timestamp(q.ts);
                out.append_array(scratch.bytes());
            }
            break;
        case PKind::Geo:
            for (const auto& g : d.geo) {
                scratch.clear();
                scratch.append_f64(g.lat);
                scratch.append_f64(g.lon);
                scratch.append_f64(g.elevation);
                scratch.append_string(g.name);
                scratch.append_timestamp(g.ts);
                out.append_array(scratch.bytes());
            }
            break;
        case PKind::Tweets:
            for (const auto& t : d.tweets) {
                scratch.clear();
                scratch.append_uint(t.id);  // u64 id (exceeds i64); positive magnitude path
                scratch.append_string(t.user);
                scratch.append_string(t.text);
                scratch.append_timestamp(t.created_at);
                scratch.append_int(t.likes);
                scratch.append_int(t.retweets);
                out.append_array(scratch.bytes());
            }
            break;
        case PKind::Txs:
            for (const auto& x : d.txs) {
                scratch.clear();
                scratch.append_int(x.height);
                scratch.append_bytes(x.tx_hash);
                scratch.append_bytes(x.from);
                scratch.append_bytes(x.to);
                // sign+magnitude path: i128-range -> fixed slots, wider -> big-int
                scratch.append_big_int(false, x.value_mag);
                scratch.append_int(x.gas);
                scratch.append_int(x.nonce);
                scratch.append_timestamp(x.ts);
                out.append_array(scratch.bytes());
            }
            break;
        case PKind::Ints:
            for (int64_t v : d.ints) out.append_int(v);
            break;
        case PKind::Strings:
            for (const auto& s : d.strings) out.append_string(s);
            break;
        case PKind::Nested:
            for (const auto& n : d.nested) {
                // user sub-map { id, name }
                Writer userw;
                userw.append_map({{KEY_ID, enc_int(n.uid)}, {KEY_NAME, enc_str(n.name)}});
                Bytes user = userw.take();
                // scores array [s0, s1, s2]
                Writer scores_inner;
                scores_inner.append_int(n.scores[0]);
                scores_inner.append_int(n.scores[1]);
                scores_inner.append_int(n.scores[2]);
                Writer scores_arr;
                scores_arr.append_array(scores_inner.bytes());
                Bytes scores = scores_arr.take();
                // top-level map (append_map sorts by encoded key, so order is free)
                out.append_map({{KEY_ACTIVE, enc_bool(n.active)},
                                {KEY_SCORES, scores},
                                {KEY_USER, user}});
            }
            break;
    }
}

static size_t record_count(PKind kind, const Data& d) {
    switch (kind) {
        case PKind::Quotes: return d.quotes.size();
        case PKind::Geo: return d.geo.size();
        case PKind::Tweets: return d.tweets.size();
        case PKind::Txs: return d.txs.size();
        case PKind::Ints: return d.ints.size();
        case PKind::Strings: return d.strings.size();
        case PKind::Nested: return d.nested.size();
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Decode — recursive walk that touches every value, unescaping container bodies
// (the realistic cost of the memcmp-orderable framing). Reader::next already
// unescapes each container body in a single pass into e.data, so descending
// recursively into the body does the realistic work.
// ---------------------------------------------------------------------------

static void walk(const uint8_t* buf, size_t len) {
    Reader r(buf, len);
    while (auto opt = r.next()) {
        const struple::Element& e = *opt;
        switch (e.kind) {
            case Kind::Nil:
            case Kind::Undefined:
                break;
            case Kind::Bool:
                sink(e.boolean ? 1 : 0);
                break;
            case Kind::Int:
                sink(uint64_t(e.integer));
                break;
            case Kind::BigInt:
                sink(e.data.size());
                break;
            case Kind::F32: {
                uint32_t b;
                std::memcpy(&b, &e.f32, 4);
                sink(b);
                break;
            }
            case Kind::F64: {
                uint64_t b;
                std::memcpy(&b, &e.f64, 8);
                sink(b);
                break;
            }
            case Kind::Decimal:
                sink(e.data.size() + uint64_t(e.dec_exp + int64_t(e.data.size())));
                break;
            case Kind::Timestamp:
                sink(uint64_t(e.integer));
                break;
            case Kind::Uuid:
                sink(e.data.empty() ? 0 : e.data[0]);
                break;
            case Kind::String:
                sink(e.str.size());
                if (!e.str.empty()) sink(uint8_t(e.str[0]));
                break;
            case Kind::Bytes:
                sink(e.data.size());
                if (!e.data.empty()) sink(e.data[0]);
                break;
            case Kind::Array:
            case Kind::Map:
            case Kind::Set:
                walk(e.data.data(), e.data.size());
                break;
        }
    }
}

// ---------------------------------------------------------------------------
// Timing.
// ---------------------------------------------------------------------------

struct Stats {
    double ns_per_op;
    size_t bytes;
    size_t records;
    double mb_per_sec() const { return (double(bytes) / ns_per_op) * 1000.0; }
    double mrec_per_sec() const { return (double(records) / ns_per_op) * 1000.0; }
};

static const uint64_t TARGET_TRIAL_NS = 100'000'000ull;  // ~100 ms
static const int N_TRIALS = 9;
static const int N_WARMUP = 5;

static double median(std::vector<double> v) {
    std::sort(v.begin(), v.end());
    return v[v.size() / 2];
}

using clock_t_ = std::chrono::steady_clock;
static inline uint64_t now_ns() {
    return uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
                        clock_t_::now().time_since_epoch())
                        .count());
}

static Bytes build_canonical(PKind kind, const Data& d) {
    Writer out, scratch;
    encode_once(kind, d, out, scratch);
    return out.take();
}

static Stats bench_encode(PKind kind, const Data& d, size_t canonical_len) {
    Writer out, scratch;
    auto run_once = [&]() {
        out.clear();
        encode_once(kind, d, out, scratch);
        sink(out.bytes().size());
    };

    for (int i = 0; i < N_WARMUP; i++) run_once();

    uint64_t t0 = now_ns();
    run_once();
    uint64_t one = now_ns() - t0;
    if (one == 0) one = 1;
    size_t iters = TARGET_TRIAL_NS / one;
    if (iters < 1) iters = 1;

    std::vector<double> trials(N_TRIALS);
    for (int t = 0; t < N_TRIALS; t++) {
        uint64_t s = now_ns();
        for (size_t j = 0; j < iters; j++) run_once();
        uint64_t dt = now_ns() - s;
        trials[t] = double(dt) / double(iters);
    }
    return {median(trials), canonical_len, record_count(kind, d)};
}

static Stats bench_decode(PKind kind, const Data& d, const Bytes& bytes) {
    auto run_once = [&]() { walk(bytes.data(), bytes.size()); };

    for (int i = 0; i < N_WARMUP; i++) run_once();

    uint64_t t0 = now_ns();
    run_once();
    uint64_t one = now_ns() - t0;
    if (one == 0) one = 1;
    size_t iters = TARGET_TRIAL_NS / one;
    if (iters < 1) iters = 1;

    std::vector<double> trials(N_TRIALS);
    for (int t = 0; t < N_TRIALS; t++) {
        uint64_t s = now_ns();
        for (size_t j = 0; j < iters; j++) run_once();
        uint64_t dt = now_ns() - s;
        trials[t] = double(dt) / double(iters);
    }
    return {median(trials), bytes.size(), record_count(kind, d)};
}

// ---------------------------------------------------------------------------
// Host label.
// ---------------------------------------------------------------------------

static std::string host_label() {
    try {
        std::ifstream f("/proc/cpuinfo");
        std::string line;
        while (std::getline(f, line)) {
            if (line.rfind("model name", 0) == 0) {
                size_t c = line.find(':');
                if (c != std::string::npos) {
                    std::string v = line.substr(c + 1);
                    size_t b = v.find_first_not_of(" \t");
                    size_t e = v.find_last_not_of(" \t\r\n");
                    if (b != std::string::npos) return v.substr(b, e - b + 1);
                }
            }
        }
    } catch (...) {
    }
    return "unknown";
}

// ---------------------------------------------------------------------------
// Manifest parsing (just the fields we need: name, byte_len, sha256). A tiny
// scanner, not a general JSON parser.
// ---------------------------------------------------------------------------

struct Expected {
    size_t byte_len;
    std::string sha256;
};

static std::string scan_string_field(const std::string& text, size_t obj_start, const char* key) {
    std::string needle = std::string("\"") + key + "\"";
    size_t k = text.find(needle, obj_start);
    if (k == std::string::npos) return "";
    size_t q = text.find('"', text.find(':', k));
    size_t q2 = text.find('"', q + 1);
    return text.substr(q + 1, q2 - q - 1);
}
static size_t scan_int_field(const std::string& text, size_t obj_start, const char* key) {
    std::string needle = std::string("\"") + key + "\"";
    size_t k = text.find(needle, obj_start);
    if (k == std::string::npos) return 0;
    size_t c = text.find(':', k) + 1;
    while (c < text.size() && (text[c] == ' ' || text[c] == '\t')) c++;
    return size_t(std::strtoull(text.c_str() + c, nullptr, 10));
}

static std::vector<std::pair<std::string, Expected>> read_manifest(const std::string& path) {
    std::string text = read_file(path);
    std::vector<std::pair<std::string, Expected>> out;
    size_t pos = 0;
    for (;;) {
        size_t k = text.find("\"name\"", pos);
        if (k == std::string::npos) break;
        std::string name = scan_string_field(text, k, "name");
        Expected e;
        e.byte_len = scan_int_field(text, k, "byte_len");
        e.sha256 = scan_string_field(text, k, "sha256");
        out.emplace_back(name, e);
        pos = k + 6;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Main.
// ---------------------------------------------------------------------------

static std::string round2(double x) {
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.2f", x);
    // strip an integer-looking trailing ".00"? Keep two decimals for clarity;
    // JSON tolerates trailing zeros and the JS port also rounds to 2dp.
    return std::string(buf);
}

int main(int argc, char** argv) {
    std::string repo_root = (argc > 1) ? argv[1] : ".";
    std::string bench_dir = repo_root + "/bench";
    std::string data_dir = bench_dir + "/data";
    std::string results_dir = bench_dir + "/results";

    auto manifest = read_manifest(bench_dir + "/payloads.json");
    auto expected_of = [&](const std::string& name) -> const Expected* {
        for (auto& p : manifest)
            if (p.first == name) return &p.second;
        return nullptr;
    };

    Data data = read_data(data_dir);

    std::printf("struple benchmark (C++17, -O2, single-threaded)\n\n");

    struct Row {
        std::string name;
        double enc_mrec, enc_mb, dec_mrec, dec_mb;
        bool sha_ok;
        size_t records;
    };
    std::vector<Row> rows;
    bool all_ok = true;
    size_t total_bytes = 0;

    for (const auto& meta : payloads) {
        Bytes bytes = build_canonical(meta.kind, data);
        total_bytes += bytes.size();

        const Expected* exp = expected_of(meta.name);
        std::string sha = sha256::of(bytes);
        bool sha_ok = exp && sha == exp->sha256 && bytes.size() == exp->byte_len;

        if (!sha_ok) {
            all_ok = false;
            std::fprintf(stderr,
                         "\nBYTE MISMATCH for %s:\n  produced byte_len=%zu sha256=%s\n"
                         "  expected byte_len=%zu sha256=%s\n"
                         "This is a contract bug — STOPPING (no throughput reported for this payload).\n",
                         meta.name, bytes.size(), sha.c_str(),
                         exp ? exp->byte_len : 0, exp ? exp->sha256.c_str() : "(missing)");
            rows.push_back({meta.name, 0, 0, 0, 0, false, record_count(meta.kind, data)});
            continue;
        }

        Stats enc = bench_encode(meta.kind, data, bytes.size());
        Stats dec = bench_decode(meta.kind, data, bytes);

        rows.push_back({meta.name, enc.mrec_per_sec(), enc.mb_per_sec(),
                        dec.mrec_per_sec(), dec.mb_per_sec(), true, enc.records});

        std::printf("  %-16s %6zu rec   enc %7.2f Mrec/s %6.0f MB/s   dec %7.2f Mrec/s %6.0f MB/s   sha %s\n",
                    meta.name, enc.records, enc.mrec_per_sec(), enc.mb_per_sec(),
                    dec.mrec_per_sec(), dec.mb_per_sec(), sha_ok ? "ok" : "FAIL");
    }

    std::string host = host_label();

    // Write bench/results/cpp.json (README format).
    {
        std::string out = "{\n  \"lang\": \"C++\",\n  \"host\": \"" + host + "\",\n  \"payloads\": {\n";
        for (size_t i = 0; i < rows.size(); i++) {
            const Row& r = rows[i];
            out += "    \"" + r.name + "\": {\n";
            out += "      \"enc_mrec_s\": " + round2(r.enc_mrec) + ",\n";
            out += "      \"enc_mb_s\": " + round2(r.enc_mb) + ",\n";
            out += "      \"dec_mrec_s\": " + round2(r.dec_mrec) + ",\n";
            out += "      \"dec_mb_s\": " + round2(r.dec_mb) + ",\n";
            out += std::string("      \"sha256_ok\": ") + (r.sha_ok ? "true" : "false") + "\n";
            out += std::string("    }") + (i + 1 == rows.size() ? "" : ",") + "\n";
        }
        out += "  }\n}\n";

        std::ofstream rf(results_dir + "/cpp.json", std::ios::binary);
        if (!rf) {
            std::fprintf(stderr, "warning: could not open %s/cpp.json for writing\n", results_dir.c_str());
        } else {
            rf.write(out.data(), std::streamsize(out.size()));
        }
    }

    std::printf("\nHost: %s · Total corpus: %.1f KB · Wrote %s/cpp.json\n",
                host.c_str(), double(total_bytes) / 1024.0, results_dir.c_str());
    std::printf("(sink %llx)\n", (unsigned long long)g_sink);

    if (!all_ok) {
        std::fprintf(stderr, "\nOne or more payloads failed byte-identity — see above.\n");
        return 1;
    }
    return 0;
}
