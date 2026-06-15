// struple — streaming, lexicographically-ordered tuple packing (C++, header-only).
//
// Encoded bytes are directly comparable: struple::compare(encode(a), encode(b))
// (and std::vector<uint8_t>'s own operator<) matches the semantic order of the
// values. A faithful port of the Zig reference; the conformance corpus
// (conformance/vectors.json) pins byte identity across languages.
//
// Header-only, C++17, no dependencies. Integers up to 64 bits are first-class;
// larger ones use BigInt (sign + big-endian magnitude bytes), so no bignum
// library is required.
#ifndef STRUPLE_HPP
#define STRUPLE_HPP

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace struple {

using Bytes = std::vector<uint8_t>;

struct Error : std::runtime_error {
    using std::runtime_error::runtime_error;
};

namespace tc {
constexpr uint8_t TERMINATOR = 0x00, NIL = 0x01, UNDEF = 0x02, BOOL_FALSE = 0x05, BOOL_TRUE = 0x06,
                  INT_NEG_BIG = 0x0f, INT_ZERO = 0x20, INT_POS_BIG = 0x31, FLOAT32 = 0x34,
                  FLOAT64 = 0x35, TIMESTAMP = 0x40, STRING = 0x48, BYTES = 0x49, ARRAY = 0x50,
                  MAP = 0x52, SET = 0x54;
}

namespace detail {
constexpr uint64_t SIGN64 = 0x8000000000000000ull;
constexpr uint32_t SIGN32 = 0x80000000u;

inline size_t byte_len(uint64_t x) {
    size_t n = 0;
    while (x) { n++; x >>= 8; }
    return n;
}

inline uint64_t be_to_u64(const uint8_t* p, size_t n) {
    uint64_t v = 0;
    for (size_t i = 0; i < n; i++) v = (v << 8) | p[i];
    return v;
}

inline size_t u64_to_be(uint64_t mag, uint8_t* out) {
    if (!mag) return 0;
    uint8_t t[8];
    size_t n = 0;
    while (mag) { t[n++] = uint8_t(mag & 0xff); mag >>= 8; }
    for (size_t i = 0; i < n; i++) out[i] = t[n - 1 - i];
    return n;
}

inline void push_be(Bytes& b, uint64_t v, size_t n) {
    for (size_t i = n; i-- > 0;) b.push_back(uint8_t((v >> (8 * i)) & 0xff));
}

inline void write_escaped(Bytes& b, const uint8_t* c, size_t n) {
    for (size_t i = 0; i < n; i++) {
        b.push_back(c[i]);
        if (c[i] == 0) b.push_back(0xff);
    }
}

inline void write_framed(Bytes& b, uint8_t type_code, const uint8_t* c, size_t n) {
    b.push_back(type_code);
    write_escaped(b, c, n);
    b.push_back(tc::TERMINATOR);
}

// mag: normalized big-endian magnitude (non-empty, no leading zeros).
inline void append_magnitude(Bytes& b, bool neg, const uint8_t* mag, size_t mlen) {
    if (mlen <= 8) {
        if (neg) {
            uint64_t m = be_to_u64(mag, mlen);
            uint64_t pos_val = m - 1;
            size_t n = byte_len(pos_val);
            if (n == 0) n = 1;
            b.push_back(uint8_t(tc::INT_ZERO - n));
            uint64_t payload = (n == 8) ? (uint64_t(0) - m) : ((1ull << (8 * n)) - m);
            push_be(b, payload, n);
        } else {
            b.push_back(uint8_t(tc::INT_ZERO + mlen));
            b.insert(b.end(), mag, mag + mlen);
        }
        return;
    }
    b.push_back(neg ? tc::INT_NEG_BIG : tc::INT_POS_BIG);
    size_t n = mlen;
    size_t m = byte_len(uint64_t(n));
    if (m == 0) m = 1;
    b.push_back(neg ? uint8_t(~uint8_t(m)) : uint8_t(m));
    for (size_t i = m; i-- > 0;) {
        uint8_t bb = uint8_t((n >> (8 * i)) & 0xff);
        b.push_back(neg ? uint8_t(~bb) : bb);
    }
    for (size_t i = 0; i < mlen; i++) b.push_back(neg ? uint8_t(~mag[i]) : mag[i]);
}

inline void append_integer(Bytes& b, int64_t v) {
    if (v == 0) { b.push_back(tc::INT_ZERO); return; }
    bool neg = v < 0;
    uint64_t mag = neg ? (~uint64_t(v) + 1) : uint64_t(v);
    uint8_t buf[8];
    size_t n = u64_to_be(mag, buf);
    append_magnitude(b, neg, buf, n);
}

inline void append_big(Bytes& b, bool neg, const uint8_t* mag, size_t mlen) {
    while (mlen > 0 && mag[0] == 0) { mag++; mlen--; }
    if (mlen == 0) { b.push_back(tc::INT_ZERO); return; }
    append_magnitude(b, neg, mag, mlen);
}

inline Bytes unescape(const uint8_t* framed, size_t flen) {
    Bytes out;
    out.reserve(flen);
    for (size_t i = 0; i < flen; i++) {
        out.push_back(framed[i]);
        if (framed[i] == 0) i++;
    }
    return out;
}
}  // namespace detail

// ----------------------------------------------------------------- Writer

class Writer {
    Bytes buf_;

public:
    const Bytes& bytes() const { return buf_; }
    Bytes take() { return std::move(buf_); }
    void clear() { buf_.clear(); }

    Writer& append_nil() { buf_.push_back(tc::NIL); return *this; }
    Writer& append_undefined() { buf_.push_back(tc::UNDEF); return *this; }
    Writer& append_bool(bool v) { buf_.push_back(v ? tc::BOOL_TRUE : tc::BOOL_FALSE); return *this; }
    Writer& append_int(int64_t v) { detail::append_integer(buf_, v); return *this; }
    Writer& append_uint(uint64_t v) {
        if (v == 0) { buf_.push_back(tc::INT_ZERO); return *this; }
        uint8_t buf[8];
        size_t n = detail::u64_to_be(v, buf);
        detail::append_magnitude(buf_, false, buf, n);
        return *this;
    }
    Writer& append_big_int(bool negative, const uint8_t* mag, size_t len) {
        detail::append_big(buf_, negative, mag, len);
        return *this;
    }
    Writer& append_big_int(bool negative, const Bytes& mag) {
        return append_big_int(negative, mag.data(), mag.size());
    }

    Writer& append_f64(double v) {
        uint64_t bits;
        if (v != v) {
            bits = 0x7ff8000000000000ull;
        } else {
            double vv = (v == 0.0) ? 0.0 : v;
            std::memcpy(&bits, &vv, sizeof bits);
        }
        bits = (bits & detail::SIGN64) ? ~bits : (bits ^ detail::SIGN64);
        buf_.push_back(tc::FLOAT64);
        detail::push_be(buf_, bits, 8);
        return *this;
    }
    Writer& append_f32(float v) {
        uint32_t bits;
        if (v != v) {
            bits = 0x7fc00000u;
        } else {
            float vv = (v == 0.0f) ? 0.0f : v;
            std::memcpy(&bits, &vv, sizeof bits);
        }
        bits = (bits & detail::SIGN32) ? ~bits : (bits ^ detail::SIGN32);
        buf_.push_back(tc::FLOAT32);
        for (int i = 3; i >= 0; i--) buf_.push_back(uint8_t((bits >> (8 * i)) & 0xff));
        return *this;
    }
    Writer& append_timestamp(int64_t micros) {
        uint64_t u = uint64_t(micros) ^ detail::SIGN64;
        buf_.push_back(tc::TIMESTAMP);
        detail::push_be(buf_, u, 8);
        return *this;
    }
    Writer& append_string(std::string_view s) {
        detail::write_framed(buf_, tc::STRING, reinterpret_cast<const uint8_t*>(s.data()), s.size());
        return *this;
    }
    Writer& append_bytes(const uint8_t* b, size_t len) {
        detail::write_framed(buf_, tc::BYTES, b, len);
        return *this;
    }
    Writer& append_bytes(const Bytes& b) { return append_bytes(b.data(), b.size()); }
    Writer& append_array(const uint8_t* child, size_t len) {
        detail::write_framed(buf_, tc::ARRAY, child, len);
        return *this;
    }
    Writer& append_array(const Bytes& child) { return append_array(child.data(), child.size()); }
    // Frame an already-encoded map/set body (used by transcode).
    Writer& append_map_body(const Bytes& body) {
        detail::write_framed(buf_, tc::MAP, body.data(), body.size());
        return *this;
    }
    Writer& append_set_body(const Bytes& body) {
        detail::write_framed(buf_, tc::SET, body.data(), body.size());
        return *this;
    }

    Writer& append_map(std::vector<std::pair<Bytes, Bytes>> entries) {
        std::sort(entries.begin(), entries.end(),
                  [](const auto& a, const auto& b) { return a.first < b.first; });
        buf_.push_back(tc::MAP);
        for (auto& [k, v] : entries) {
            detail::write_escaped(buf_, k.data(), k.size());
            detail::write_escaped(buf_, v.data(), v.size());
        }
        buf_.push_back(tc::TERMINATOR);
        return *this;
    }
    Writer& append_set(std::vector<Bytes> elems) {
        std::sort(elems.begin(), elems.end());
        buf_.push_back(tc::SET);
        const Bytes* prev = nullptr;
        for (auto& e : elems) {
            if (prev && *prev == e) continue;
            detail::write_escaped(buf_, e.data(), e.size());
            prev = &e;
        }
        buf_.push_back(tc::TERMINATOR);
        return *this;
    }

    // ergonomic overloads
    Writer& append(std::nullptr_t) { return append_nil(); }
    Writer& append(bool v) { return append_bool(v); }
    Writer& append(int64_t v) { return append_int(v); }
    Writer& append(int v) { return append_int(v); }
    Writer& append(double v) { return append_f64(v); }
    Writer& append(std::string_view v) { return append_string(v); }
    Writer& append(const char* v) { return append_string(v); }
};

template <typename... Ts>
inline Bytes pack(Ts&&... vs) {
    Writer w;
    (w.append(std::forward<Ts>(vs)), ...);
    return w.take();
}

// ----------------------------------------------------------------- Reader

enum class Kind { Nil, Undefined, Bool, Int, BigInt, F32, F64, Timestamp, String, Bytes, Array, Map, Set };

struct Element {
    Kind kind{};
    bool boolean = false;
    int64_t integer = 0;       // Int, Timestamp (micros)
    bool big_negative = false; // BigInt sign
    float f32 = 0;
    double f64 = 0;
    std::string str;           // String
    Bytes data;                // Bytes; BigInt magnitude; Array/Map/Set body
};

class Reader {
    const uint8_t* buf_;
    size_t len_;
    size_t pos_ = 0;

public:
    Reader(const uint8_t* buf, size_t len) : buf_(buf), len_(len) {}
    explicit Reader(const Bytes& v) : buf_(v.data()), len_(v.size()) {}

    bool done() const { return pos_ >= len_; }

    std::optional<Element> next() {
        if (pos_ >= len_) return std::nullopt;
        uint8_t t = buf_[pos_++];
        Element e;
        switch (t) {
            case tc::NIL: e.kind = Kind::Nil; return e;
            case tc::UNDEF: e.kind = Kind::Undefined; return e;
            case tc::BOOL_FALSE: e.kind = Kind::Bool; e.boolean = false; return e;
            case tc::BOOL_TRUE: e.kind = Kind::Bool; e.boolean = true; return e;
            case tc::INT_ZERO: e.kind = Kind::Int; e.integer = 0; return e;
            case tc::INT_NEG_BIG:
            case tc::INT_POS_BIG: read_big_int(t, e); return e;
            case tc::FLOAT32: { uint32_t b = uint32_t(detail::be_to_u64(take(4), 4)); b = (b & detail::SIGN32) ? (b ^ detail::SIGN32) : ~b; std::memcpy(&e.f32, &b, 4); e.kind = Kind::F32; return e; }
            case tc::FLOAT64: { uint64_t b = detail::be_to_u64(take(8), 8); b = (b & detail::SIGN64) ? (b ^ detail::SIGN64) : ~b; std::memcpy(&e.f64, &b, 8); e.kind = Kind::F64; return e; }
            case tc::TIMESTAMP: { uint64_t b = detail::be_to_u64(take(8), 8) ^ detail::SIGN64; e.kind = Kind::Timestamp; e.integer = int64_t(b); return e; }
            case tc::STRING: { Bytes u = take_framed(); e.kind = Kind::String; e.str.assign(reinterpret_cast<const char*>(u.data()), u.size()); return e; }
            case tc::BYTES: e.kind = Kind::Bytes; e.data = take_framed(); return e;
            case tc::ARRAY: e.kind = Kind::Array; e.data = take_framed(); return e;
            case tc::MAP: e.kind = Kind::Map; e.data = take_framed(); return e;
            case tc::SET: e.kind = Kind::Set; e.data = take_framed(); return e;
            default:
                if ((t >= 0x10 && t <= 0x1f) || (t >= 0x21 && t <= 0x30)) {
                    read_fixed_int(t, e);
                    return e;
                }
                throw Error("struple: invalid type code");
        }
    }

private:
    const uint8_t* take(size_t n) {
        if (pos_ + n > len_) throw Error("struple: truncated");
        const uint8_t* p = buf_ + pos_;
        pos_ += n;
        return p;
    }

    Bytes take_framed() {
        size_t start = pos_, i = pos_;
        while (i < len_) {
            if (buf_[i] == 0) {
                if (i + 1 < len_ && buf_[i + 1] == 0xff) { i += 2; continue; }
                Bytes out = detail::unescape(buf_ + start, i - start);
                pos_ = i + 1;
                return out;
            }
            i++;
        }
        throw Error("struple: truncated (unterminated framed value)");
    }

    void read_fixed_int(uint8_t t, Element& e) {
        size_t n = (t < tc::INT_ZERO) ? size_t(tc::INT_ZERO - t) : size_t(t - tc::INT_ZERO);
        if (n > 8) throw Error("struple: unsupported integer width");
        const uint8_t* p = take(n);
        uint64_t raw = detail::be_to_u64(p, n);
        if (t > tc::INT_ZERO) {
            if (raw <= uint64_t(INT64_MAX)) { e.kind = Kind::Int; e.integer = int64_t(raw); }
            else { e.kind = Kind::BigInt; e.big_negative = false; e.data.assign(p, p + n); }
            return;
        }
        if (n < 8) {
            uint64_t m = (1ull << (8 * n)) - raw;
            e.kind = Kind::Int;
            e.integer = -int64_t(m);
            return;
        }
        if (raw == 0) {
            e.kind = Kind::BigInt;
            e.big_negative = true;
            e.data = {1, 0, 0, 0, 0, 0, 0, 0, 0};
            return;
        }
        uint64_t m = uint64_t(0) - raw;
        if (m <= uint64_t(INT64_MAX) + 1) {
            e.kind = Kind::Int;
            e.integer = (m == uint64_t(INT64_MAX) + 1) ? INT64_MIN : -int64_t(m);
        } else {
            uint8_t buf[8];
            size_t mn = detail::u64_to_be(m, buf);
            e.kind = Kind::BigInt;
            e.big_negative = true;
            e.data.assign(buf, buf + mn);
        }
    }

    void read_big_int(uint8_t t, Element& e) {
        bool neg = (t == tc::INT_NEG_BIG);
        auto comp = [neg](uint8_t b) { return neg ? uint8_t(~b) : b; };
        size_t m = comp(take(1)[0]);
        const uint8_t* nb = take(m);
        size_t n = 0;
        for (size_t i = 0; i < m; i++) n = (n << 8) | comp(nb[i]);
        const uint8_t* mag = take(n);
        e.kind = Kind::BigInt;
        e.big_negative = neg;
        e.data.resize(n);
        for (size_t i = 0; i < n; i++) e.data[i] = comp(mag[i]);
    }
};

// --------------------------------------------------------- transcode / order

inline void append_element(Writer& w, const Element& e) {
    switch (e.kind) {
        case Kind::Nil: w.append_nil(); break;
        case Kind::Undefined: w.append_undefined(); break;
        case Kind::Bool: w.append_bool(e.boolean); break;
        case Kind::Int: w.append_int(e.integer); break;
        case Kind::BigInt: w.append_big_int(e.big_negative, e.data); break;
        case Kind::F32: w.append_f32(e.f32); break;
        case Kind::F64: w.append_f64(e.f64); break;
        case Kind::Timestamp: w.append_timestamp(e.integer); break;
        case Kind::String: w.append_string(e.str); break;
        case Kind::Bytes: w.append_bytes(e.data); break;
        case Kind::Array: w.append_array(e.data); break;
        case Kind::Map: w.append_map_body(e.data); break;
        case Kind::Set: w.append_set_body(e.data); break;
    }
}

inline Bytes transcode(const uint8_t* buf, size_t len) {
    Reader r(buf, len);
    Writer w;
    while (auto e = r.next()) append_element(w, *e);
    return w.take();
}
inline Bytes transcode(const Bytes& v) { return transcode(v.data(), v.size()); }

// Lexicographic comparison: -1/0/1. (Bytes' own operator< orders this way too.)
inline int compare(const uint8_t* a, size_t alen, const uint8_t* b, size_t blen) {
    size_t n = alen < blen ? alen : blen;
    int c = n ? std::memcmp(a, b, n) : 0;
    if (c != 0) return c < 0 ? -1 : 1;
    if (alen < blen) return -1;
    if (alen > blen) return 1;
    return 0;
}
inline int compare(const Bytes& a, const Bytes& b) { return compare(a.data(), a.size(), b.data(), b.size()); }

}  // namespace struple

#endif  // STRUPLE_HPP
