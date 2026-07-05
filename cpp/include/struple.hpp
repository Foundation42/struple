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
#include <cmath>
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
                  INT_NEG_BIG = 0x0f, INT_NEG_MIN = 0x10, INT_NEG_MAX = 0x1f, INT_ZERO = 0x20,
                  INT_POS_MIN = 0x21, INT_POS_MAX = 0x30, INT_POS_BIG = 0x31, FLOAT32 = 0x34,
                  FLOAT64 = 0x35, DECIMAL = 0x38, TIMESTAMP = 0x40, UUID = 0x44, STRING = 0x48,
                  BYTES = 0x49, ARRAY = 0x50, MAP = 0x52, SET = 0x54;
}

// Leading marker inside a decimal payload, isolating the three sign groups so
// memcmp keeps negative < zero < positive. For negatives the rest of the payload
// is bit-complemented, so a larger magnitude sorts earlier.
namespace dec_sign {
constexpr uint8_t NEG = 0x01, ZERO = 0x02, POS = 0x03;
}

namespace detail {
constexpr uint64_t SIGN64 = 0x8000000000000000ull;
constexpr uint32_t SIGN32 = 0x80000000u;

// Maximum container/JSON nesting depth accepted by the recursive walks (JSON
// parse, JSON render, semantic compare). Bounds stack use so hostile deeply-
// nested input is rejected (throwing struple::Error) instead of overflowing the
// stack (Item 5). Mirrors the Zig reference's struple.max_depth; no real value
// nests anywhere near this deep. Depth is 0 at the top level, +1 per container
// descent, and a walk is rejected once depth exceeds MAX_DEPTH.
constexpr size_t MAX_DEPTH = 256;

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
    // Bulk-copy the runs between 0x00 bytes; the escape-free case is one insert.
    size_t i = 0;
    while (i < n) {
        size_t start = i;
        while (i < n && c[i] != 0) i++;
        b.insert(b.end(), c + start, c + i);
        if (i < n) { b.push_back(0x00); b.push_back(0xff); i++; }
    }
}

inline void write_framed(Bytes& b, uint8_t type_code, const uint8_t* c, size_t n) {
    b.push_back(type_code);
    write_escaped(b, c, n);
    b.push_back(tc::TERMINATOR);
}

// Does this value (sign + trimmed big-endian magnitude) fit the i128 range
// [-2^127, 2^127-1]? Below 16 bytes always; at 16 bytes the top byte decides.
inline bool fits_fixed(bool neg, const uint8_t* mag, size_t mlen) {
    if (mlen < 16) return true;
    if (mlen > 16) return false;
    if (mag[0] < 0x80) return true;  // |value| < 2^127
    if (!neg) return false;          // positive >= 2^127 -> big-int
    if (mag[0] != 0x80) return false;
    for (size_t i = 1; i < 16; i++)
        if (mag[i] != 0) return false;  // only exactly -2^127 still fits
    return true;
}

// mag: normalized big-endian magnitude (non-empty, no leading zeros).
inline void append_magnitude(Bytes& b, bool neg, const uint8_t* mag, size_t mlen) {
    // The fixed slots span the whole i128 range (1–16 byte magnitudes).
    if (fits_fixed(neg, mag, mlen)) {
        if (!neg) {
            b.push_back(uint8_t(tc::INT_ZERO + mlen));
            b.insert(b.end(), mag, mag + mlen);
            return;
        }
        // Negative excess form = ~(magnitude - 1) over n bytes, where n is the
        // byte length of (magnitude - 1). Pure byte math — no 128-bit type.
        uint8_t pv[16];
        std::memcpy(pv, mag, mlen);
        for (size_t i = mlen; i-- > 0;) {
            if (pv[i]-- != 0) break;  // borrow only while a byte was 0x00
        }
        size_t start = 0;
        while (start + 1 < mlen && pv[start] == 0) start++;  // trim pos_val
        size_t n = mlen - start;
        b.push_back(uint8_t(tc::INT_ZERO - n));
        for (size_t i = start; i < mlen; i++) b.push_back(uint8_t(~pv[i]));
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

// Append an arbitrary-precision decimal `(-1)^neg · C · 10^exp`, where `digits`
// are the coefficient `C`'s decimal digits (each 0–9, most-significant first).
// Canonicalized on the way in: leading/trailing zeros are stripped and any
// all-zero coefficient collapses to the single zero form.
inline void append_decimal(Bytes& b, bool neg, const uint8_t* digits, size_t dlen, int64_t exp) {
    size_t lead = 0;
    while (lead < dlen && digits[lead] == 0) lead++;
    const uint8_t* sig = digits + lead;
    size_t slen = dlen - lead;

    b.push_back(tc::DECIMAL);
    if (slen == 0) {  // canonical zero — one form regardless of scale
        b.push_back(dec_sign::ZERO);
        return;
    }

    // Adjusted exponent: place value of the most-significant digit (0.d…·10^E).
    // Computed wide (128-bit) then bounded to i32 so it round-trips through decode's
    // i32 cap and downstream exponent math never overflows (Item 2).
    __int128 adj_exp_wide = (__int128)(int64_t)slen + exp;
    if (adj_exp_wide > INT32_MAX || adj_exp_wide < INT32_MIN)
        throw Error("struple: decimal exponent out of range");
    int64_t adj_exp = int64_t(adj_exp_wide);
    // Trailing zeros change neither the value nor E, so drop them for storage.
    size_t end = slen;
    while (end > 0 && sig[end - 1] == 0) end--;

    // Order-bearing tail: [E as a struple int][base-100 digits][terminator].
    Bytes tail;
    append_integer(tail, adj_exp);
    for (size_t i = 0; i < end; i += 2) {
        unsigned hi = sig[i];
        unsigned lo = (i + 1 < end) ? sig[i + 1] : 0;  // pad odd tail with 0
        tail.push_back(uint8_t(hi * 10 + lo + 1));      // pair 0–99 -> byte 1–100
    }
    tail.push_back(tc::TERMINATOR);

    b.push_back(neg ? dec_sign::NEG : dec_sign::POS);
    for (uint8_t x : tail) b.push_back(neg ? uint8_t(~x) : x);
}

// Parse a decimal from text: `[+/-] digits [. digits] [ (e|E) [+/-] digits ]`.
inline void append_decimal_string(Bytes& b, std::string_view s) {
    size_t i = 0;
    bool neg = false;
    if (i < s.size() && (s[i] == '+' || s[i] == '-')) {
        neg = s[i] == '-';
        i++;
    }
    std::vector<uint8_t> digits;
    int64_t exp = 0;
    bool seen_point = false;
    bool any = false;
    for (; i < s.size(); i++) {
        char c = s[i];
        if (c == '.') {
            if (seen_point) throw Error("struple: invalid decimal");
            seen_point = true;
            continue;
        }
        if (c == 'e' || c == 'E') break;
        if (c < '0' || c > '9') throw Error("struple: invalid decimal");
        digits.push_back(uint8_t(c - '0'));
        if (seen_point) exp -= 1;
        any = true;
    }
    if (!any) throw Error("struple: invalid decimal");
    if (i < s.size() && (s[i] == 'e' || s[i] == 'E')) {
        i++;
        int64_t esign = 1;
        if (i < s.size() && (s[i] == '+' || s[i] == '-')) {
            if (s[i] == '-') esign = -1;
            i++;
        }
        int64_t ev = 0;
        bool edig = false;
        for (; i < s.size(); i++) {
            if (s[i] < '0' || s[i] > '9') throw Error("struple: invalid decimal");
            ev = ev * 10 + (s[i] - '0');
            // Cap the running exponent so the accumulator can't overflow i64 (Item 2);
            // an exponent magnitude past i32 is far beyond any real decimal.
            if (ev > int64_t(INT32_MAX)) throw Error("struple: invalid decimal");
            edig = true;
        }
        if (!edig) throw Error("struple: invalid decimal");
        exp += esign * ev;
    }
    // Reject an exponent magnitude outside i32 before the (already i32-bounded)
    // adjusted-exponent check in append_decimal (Item 2).
    if (exp > int64_t(INT32_MAX) || exp < int64_t(INT32_MIN)) throw Error("struple: invalid decimal");
    append_decimal(b, neg, digits.data(), digits.size(), exp);
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
    // Append a decimal `(-1)^negative · C · 10^exp`, where `digits` are the
    // coefficient `C`'s decimal digits (each 0–9, most-significant first).
    Writer& append_decimal(bool negative, const uint8_t* digits, size_t len, int64_t exp) {
        detail::append_decimal(buf_, negative, digits, len, exp);
        return *this;
    }
    Writer& append_decimal(bool negative, const Bytes& digits, int64_t exp) {
        return append_decimal(negative, digits.data(), digits.size(), exp);
    }
    // Append a decimal parsed from text, e.g. "12.345", "-0.5", "1e-9".
    Writer& appendDecimalString(std::string_view s) {
        detail::append_decimal_string(buf_, s);
        return *this;
    }
    Writer& append_timestamp(int64_t micros) {
        uint64_t u = uint64_t(micros) ^ detail::SIGN64;
        buf_.push_back(tc::TIMESTAMP);
        detail::push_be(buf_, u, 8);
        return *this;
    }
    // `uuid16` points to 16 raw bytes (network/big-endian order).
    Writer& append_uuid(const uint8_t* uuid16) {
        buf_.push_back(tc::UUID);
        buf_.insert(buf_.end(), uuid16, uuid16 + 16);
        return *this;
    }
    Writer& append_uuid(const Bytes& u) { return append_uuid(u.data()); }
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

enum class Kind { Nil, Undefined, Bool, Int, BigInt, F32, F64, Decimal, Timestamp, Uuid, String, Bytes, Array, Map, Set };

struct Element {
    Kind kind{};
    bool boolean = false;
    int64_t integer = 0;       // Int, Timestamp (micros)
    bool big_negative = false; // BigInt sign; Decimal sign
    float f32 = 0;
    double f64 = 0;
    std::string str;           // String
    Bytes data;                // Bytes; BigInt magnitude; Array/Map/Set body;
                               //   Decimal coefficient digits (each 0–9, MSD first)
    int64_t dec_exp = 0;       // Decimal: power of ten, value = ±(C·10^dec_exp)

    // Decimal helpers (the coefficient digits live in `data`; zero has none).
    bool decIsZero() const { return data.empty(); }
};

/// A non-owning byte span — a sub-view of a buffer.
struct Slice {
    const uint8_t* data = nullptr;
    size_t size = 0;
    bool empty() const { return size == 0; }
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
            case tc::DECIMAL: read_decimal(e); return e;
            case tc::TIMESTAMP: { uint64_t b = detail::be_to_u64(take(8), 8) ^ detail::SIGN64; e.kind = Kind::Timestamp; e.integer = int64_t(b); return e; }
            case tc::UUID: { const uint8_t* p = take(16); e.kind = Kind::Uuid; e.data.assign(p, p + 16); return e; }
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

    /// The next element's type code without consuming it.
    std::optional<uint8_t> peekType() const {
        return pos_ < len_ ? std::optional<uint8_t>(buf_[pos_]) : std::nullopt;
    }
    /// The remaining unread bytes.
    Slice rest() const {
        return Slice{buf_ + pos_, len_ - pos_};
    }
    /// The next element's raw bytes (a zero-copy view), advancing the cursor.
    std::optional<Slice> nextView() {
        size_t start = pos_;
        if (!consume()) return std::nullopt;
        return Slice{buf_ + start, pos_ - start};
    }
    /// Advance past the next element; false at end of stream.
    bool skip() {
        return nextView().has_value();
    }

private:
    const uint8_t* take(size_t n) {
        // Guard as `n > remaining`, never `pos_ + n > len_`: the addition overflows
        // size_t for an attacker-supplied n and wraps past the check. pos_ <= len_ holds.
        if (n > len_ - pos_) throw Error("struple: truncated");
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

    void skip_framed() {
        size_t i = pos_;
        while (i < len_) {
            if (buf_[i] == 0) {
                if (i + 1 < len_ && buf_[i + 1] == 0xff) { i += 2; continue; }
                pos_ = i + 1;
                return;
            }
            i++;
        }
        throw Error("struple: truncated (unterminated framed value)");
    }

    // Advance past one element without decoding (no allocation). False at end.
    bool consume() {
        if (pos_ >= len_) return false;
        uint8_t t = buf_[pos_++];
        switch (t) {
            case tc::NIL:
            case tc::UNDEF:
            case tc::BOOL_FALSE:
            case tc::BOOL_TRUE:
            case tc::INT_ZERO:
                break;
            case tc::INT_NEG_BIG:
            case tc::INT_POS_BIG: {
                bool neg = (t == tc::INT_NEG_BIG);
                auto comp = [neg](uint8_t b) { return neg ? uint8_t(~b) : b; };
                size_t m = comp(take(1)[0]);
                if (m > 8) throw Error("struple: big-int length-of-length too large");
                const uint8_t* nb = take(m);
                size_t n = 0;
                for (size_t i = 0; i < m; i++) n = (n << 8) | comp(nb[i]);
                take(n);
                break;
            }
            case tc::FLOAT32: take(4); break;
            case tc::FLOAT64:
            case tc::TIMESTAMP: take(8); break;
            case tc::DECIMAL: skip_decimal(); break;
            case tc::UUID: take(16); break;
            case tc::STRING:
            case tc::BYTES:
            case tc::ARRAY:
            case tc::MAP:
            case tc::SET: skip_framed(); break;
            default:
                if ((t >= 0x10 && t <= 0x1f) || (t >= 0x21 && t <= 0x30)) {
                    size_t n = (t < tc::INT_ZERO) ? size_t(tc::INT_ZERO - t) : size_t(t - tc::INT_ZERO);
                    take(n);
                } else {
                    throw Error("struple: invalid type code");
                }
        }
        return true;
    }

    void read_fixed_int(uint8_t t, Element& e) {
        bool positive = t > tc::INT_ZERO;
        size_t n = positive ? size_t(t - tc::INT_ZERO) : size_t(tc::INT_ZERO - t);
        const uint8_t* p = take(n);
        // The widest (16-byte) slots can address values outside i128; a canonical
        // encoder uses the big-int codes for those, so reject them here.
        if (n == 16 && ((positive && p[0] >= 0x80) || (!positive && p[0] < 0x80)))
            throw Error("struple: non-canonical 16-byte integer");

        if (n <= 8) {
            uint64_t raw = detail::be_to_u64(p, n);
            if (positive) {
                if (raw <= uint64_t(INT64_MAX)) { e.kind = Kind::Int; e.integer = int64_t(raw); }
                else { e.kind = Kind::BigInt; e.big_negative = false; e.data.assign(p, p + n); }
                return;
            }
            if (n < 8) { e.kind = Kind::Int; e.integer = -int64_t((1ull << (8 * n)) - raw); return; }
            if (raw == 0) { e.kind = Kind::BigInt; e.big_negative = true; e.data = {1, 0, 0, 0, 0, 0, 0, 0, 0}; return; }
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
            return;
        }

        // n in 9..16: the value exceeds int64, so it is always a big-int element.
        e.kind = Kind::BigInt;
        if (positive) { e.big_negative = false; e.data.assign(p, p + n); return; }
        // negative: magnitude = 2^(8n) - excess = (~excess) + 1, computed in bytes
        e.big_negative = true;
        e.data.resize(n);
        unsigned carry = 1;
        for (size_t i = n; i-- > 0;) {
            unsigned v = unsigned(uint8_t(~p[i])) + carry;
            e.data[i] = uint8_t(v & 0xff);
            carry = v >> 8;
        }
        size_t start = 0;
        while (start + 1 < n && e.data[start] == 0) start++;  // trim leading zeros
        if (start) e.data.erase(e.data.begin(), e.data.begin() + long(start));
    }

    void read_big_int(uint8_t t, Element& e) {
        bool neg = (t == tc::INT_NEG_BIG);
        auto comp = [neg](uint8_t b) { return neg ? uint8_t(~b) : b; };
        size_t m = comp(take(1)[0]);
        if (m > 8) throw Error("struple: big-int length-of-length too large");
        const uint8_t* nb = take(m);
        size_t n = 0;
        for (size_t i = 0; i < m; i++) n = (n << 8) | comp(nb[i]);
        const uint8_t* mag = take(n);
        e.kind = Kind::BigInt;
        e.big_negative = neg;
        e.data.resize(n);
        for (size_t i = 0; i < n; i++) e.data[i] = comp(mag[i]);
    }

    // Read the embedded exponent (a struple integer), un-complementing each byte
    // for negatives. Big-int exponent codes are rejected (beyond any real use).
    int64_t read_dec_exponent(bool complement) {
        auto comp = [complement](uint8_t b) { return complement ? uint8_t(~b) : b; };
        uint8_t tb = comp(take(1)[0]);
        if (tb == tc::INT_ZERO) return 0;
        if ((tb >= tc::INT_NEG_MIN && tb <= tc::INT_NEG_MAX) ||
            (tb >= tc::INT_POS_MIN && tb <= tc::INT_POS_MAX)) {
            bool positive = tb > tc::INT_ZERO;
            size_t n = positive ? size_t(tb - tc::INT_ZERO) : size_t(tc::INT_ZERO - tb);
            const uint8_t* p = take(n);
            uint8_t tmp[16];
            for (size_t k = 0; k < n; k++) tmp[k] = comp(p[k]);
            if (n == 16 && ((positive && tmp[0] >= 0x80) || (!positive && tmp[0] < 0x80)))
                throw Error("struple: non-canonical decimal exponent");
            // n <= 8 always here for any realistic exponent; reject wider as out of i64.
            if (n > 8) throw Error("struple: decimal exponent out of range");
            uint64_t raw = detail::be_to_u64(tmp, n);
            int64_t value;
            if (positive) {
                if (raw > uint64_t(INT64_MAX)) throw Error("struple: decimal exponent out of range");
                value = int64_t(raw);
            } else if (n == 8) {
                // negative excess form over 8 bytes: value = raw - 2^64
                uint64_t m = uint64_t(0) - raw;  // magnitude
                if (m > uint64_t(INT64_MAX) + 1) throw Error("struple: decimal exponent out of range");
                value = (m == uint64_t(INT64_MAX) + 1) ? INT64_MIN : -int64_t(m);
            } else {
                // negative excess form over n<8 bytes: value = raw - 2^(8n)
                value = -int64_t((uint64_t(1) << (8 * n)) - raw);
            }
            // Bound the adjusted exponent to i32 (Item 2): keeps `exponent()`
            // (= adj_exp − digitCount) from underflowing i64 and downstream exponent
            // math (toJson pad, semantic scaling) from overflowing. A larger stored
            // exponent is malformed — rejecting it here also stops the decode/skip
            // DoS where a 2^31-scaled magnitude would be materialized.
            if (value > INT32_MAX || value < INT32_MIN)
                throw Error("struple: decimal exponent out of range");
            return value;
        }
        throw Error("struple: invalid decimal exponent");
    }

    void read_decimal(Element& e) {
        e.kind = Kind::Decimal;
        uint8_t sign = take(1)[0];
        if (sign == dec_sign::ZERO) {
            e.big_negative = false;
            e.dec_exp = 0;
            e.data.clear();  // canonical zero — no coefficient digits
            return;
        }
        if (sign != dec_sign::NEG && sign != dec_sign::POS)
            throw Error("struple: invalid decimal sign");
        bool neg = (sign == dec_sign::NEG);
        e.big_negative = neg;
        int64_t adj_exp = read_dec_exponent(neg);

        // Digit bytes are 1–100 (positive) or their complement (negative), and never
        // collide with the terminator (0x00, or 0xFF when complemented).
        uint8_t term = neg ? 0xff : 0x00;
        size_t start = pos_, i = pos_;
        while (i < len_ && buf_[i] != term) i++;
        if (i >= len_) throw Error("struple: truncated decimal");
        if (i == start) throw Error("struple: empty decimal coefficient");
        pos_ = i + 1;  // consume the terminator

        // Unpack base-100 pairs into individual digits (0–9, MSD first). An odd
        // digit count padded its final pair's low digit with a (canonical) zero.
        e.data.clear();
        e.data.reserve((i - start) * 2);
        for (size_t k = start; k < i; k++) {
            uint8_t pair = uint8_t((neg ? uint8_t(~buf_[k]) : buf_[k]) - 1);  // 0–99
            e.data.push_back(uint8_t(pair / 10));
            uint8_t lo = uint8_t(pair % 10);
            bool is_last = (k + 1 == i);
            if (!(is_last && lo == 0)) e.data.push_back(lo);  // skip synthetic trailing pad
        }
        // exponent = adjusted exponent - significant digit count (value = C·10^exp).
        e.dec_exp = adj_exp - int64_t(e.data.size());
    }

    void skip_decimal() {
        uint8_t sign = take(1)[0];
        if (sign == dec_sign::ZERO) return;
        if (sign != dec_sign::NEG && sign != dec_sign::POS)
            throw Error("struple: invalid decimal sign");
        bool neg = (sign == dec_sign::NEG);
        read_dec_exponent(neg);
        uint8_t term = neg ? 0xff : 0x00;
        size_t i = pos_;
        while (i < len_ && buf_[i] != term) i++;
        if (i >= len_) throw Error("struple: truncated decimal");
        pos_ = i + 1;
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
        case Kind::Decimal: w.append_decimal(e.big_negative, e.data, e.dec_exp); break;
        case Kind::Timestamp: w.append_timestamp(e.integer); break;
        case Kind::Uuid: w.append_uuid(e.data.data()); break;
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

// --------------------------------------------------------------- navigation

/// Zero-copy navigation over a struple buffer (a stream of elements). Every
/// result is a sub-view that is itself a valid struple buffer.
class View {
    const uint8_t* bytes_;
    size_t len_;

public:
    View(const uint8_t* bytes, size_t len) : bytes_(bytes), len_(len) {}
    View(const Bytes& b) : bytes_(b.data()), len_(b.size()) {}
    View(Slice s) : bytes_(s.data), len_(s.size) {}

    const uint8_t* data() const { return bytes_; }
    size_t size() const { return len_; }
    Reader reader() const { return Reader(bytes_, len_); }

    size_t count() const {
        Reader r = reader();
        size_t n = 0;
        while (r.skip()) n++;
        return n;
    }
    std::optional<View> at(size_t index) const {
        Reader r = reader();
        size_t i = 0;
        while (auto v = r.nextView()) {
            if (i == index) return View(*v);
            i++;
        }
        return std::nullopt;
    }
    std::optional<View> head() const { return at(0); }
    View tail() const {
        Reader r = reader();
        r.nextView();
        return View(r.rest());
    }
    View nthRest(size_t n) const {
        Reader r = reader();
        for (size_t i = 0; i < n; i++)
            if (!r.skip()) break;
        return View(r.rest());
    }
    View take(size_t n) const {
        Reader r = reader();
        for (size_t i = 0; i < n; i++)
            if (!r.skip()) break;
        return View(bytes_, len_ - r.rest().size);
    }
    std::optional<uint8_t> headType() const {
        return len_ > 0 ? std::optional<uint8_t>(bytes_[0]) : std::nullopt;
    }

    bool isNil() const { return headType() == tc::NIL; }
    bool isUndefined() const { return headType() == tc::UNDEF; }
    bool isBool() const {
        auto t = headType();
        return t == tc::BOOL_FALSE || t == tc::BOOL_TRUE;
    }
    bool isInt() const {
        auto t = headType();
        if (!t) return false;
        uint8_t x = *t;
        return x == tc::INT_ZERO || x == tc::INT_NEG_BIG || x == tc::INT_POS_BIG || (x >= 0x10 && x <= 0x1f) || (x >= 0x21 && x <= 0x30);
    }
    bool isFloat() const {
        auto t = headType();
        return t == tc::FLOAT32 || t == tc::FLOAT64;
    }
    bool isDecimal() const { return headType() == tc::DECIMAL; }
    bool isNumber() const { return isInt() || isFloat() || isDecimal(); }
    bool isTimestamp() const { return headType() == tc::TIMESTAMP; }
    bool isUuid() const { return headType() == tc::UUID; }
    bool isString() const { return headType() == tc::STRING; }
    bool isBytes() const { return headType() == tc::BYTES; }
    bool isArray() const { return headType() == tc::ARRAY; }
    bool isMap() const { return headType() == tc::MAP; }
    bool isSet() const { return headType() == tc::SET; }
    bool isContainer() const {
        auto t = headType();
        return t == tc::ARRAY || t == tc::MAP || t == tc::SET;
    }

    /// The container's inner element stream (un-escaped, owned), or nullopt.
    std::optional<Bytes> containedItems() const {
        if (!isContainer()) return std::nullopt;
        Reader r = reader();
        auto e = r.next();
        if (!e) return std::nullopt;
        if (e->kind == Kind::Array || e->kind == Kind::Map || e->kind == Kind::Set) return e->data;
        return std::nullopt;
    }
};

inline View view(const Bytes& b) { return View(b); }
inline View view(const uint8_t* bytes, size_t len) { return View(bytes, len); }

/// Reads key/value pairs from a map's inner stream (from View::containedItems).
/// Keys are canonical (sorted), so `get` early-exits.
class MapView {
    const uint8_t* inner_;
    size_t len_;

public:
    MapView(const uint8_t* inner, size_t len) : inner_(inner), len_(len) {}
    MapView(const Bytes& b) : inner_(b.data()), len_(b.size()) {}
    MapView(Slice s) : inner_(s.data), len_(s.size) {}

    size_t count() const { return View(inner_, len_).count() / 2; }

    struct Entry {
        Slice key;
        Slice value;
    };
    class Iterator {
        Reader r;

    public:
        Iterator(const uint8_t* b, size_t l) : r(b, l) {}
        std::optional<Entry> next() {
            auto k = r.nextView();
            if (!k) return std::nullopt;
            auto v = r.nextView();
            if (!v) throw Error("struple: malformed map");
            return Entry{*k, *v};
        }
    };
    Iterator iterator() const { return Iterator(inner_, len_); }

    /// Look up the value bytes for an encoded key (e.g. `encode_string`).
    std::optional<Slice> get(const uint8_t* key, size_t keylen) const {
        Iterator it(inner_, len_);
        while (auto e = it.next()) {
            int c = compare(e->key.data, e->key.size, key, keylen);
            if (c == 0) return e->value;
            if (c > 0) return std::nullopt;
        }
        return std::nullopt;
    }
    std::optional<Slice> get(const Bytes& key) const { return get(key.data(), key.size()); }

    /// Materialize a random-access index for O(log n) `get` and O(1) `at` (see
    /// `IndexedMap`). One O(n) pass; the entry slices borrow this map's inner
    /// stream, so keep it alive for the index's lifetime.
    class IndexedMap indexed() const;
};

/// A map's entries materialized into a random-access index. Building it is one
/// O(n) pass over the inner stream; thereafter `get` is an O(log n) binary search
/// (canonical key order means a key memcmp *is* the sort order) and `at` is O(1).
///
/// Use `MapView` directly for a single lookup (zero-alloc); reach for `IndexedMap`
/// when you do many lookups, or need positional access, on the same map. The entry
/// slices borrow the inner stream, so keep it alive for the index's lifetime.
class IndexedMap {
    std::vector<MapView::Entry> entries_;

public:
    using Entry = MapView::Entry;

    /// Build the index from a map's *inner* stream (the un-escaped body from
    /// `View::containedItems`). Keep `inner` alive for the index's lifetime.
    IndexedMap(const uint8_t* inner, size_t len) {
        MapView::Iterator it(inner, len);
        while (auto e = it.next()) entries_.push_back(*e);
    }
    IndexedMap(const Bytes& b) : IndexedMap(b.data(), b.size()) {}
    IndexedMap(Slice s) : IndexedMap(s.data, s.size) {}
    IndexedMap(const MapView& m) : IndexedMap(m.indexed()) {}

    /// Number of entries — O(1).
    size_t count() const { return entries_.size(); }
    size_t size() const { return entries_.size(); }

    /// The entry at `index` in canonical (sorted) order — O(1); nullopt if out of range.
    std::optional<Entry> at(size_t index) const {
        if (index < entries_.size()) return entries_[index];
        return std::nullopt;
    }

    /// The index of `key` in canonical order, or nullopt — O(log n) binary search.
    std::optional<size_t> find(const uint8_t* key, size_t keylen) const {
        size_t lo = 0, hi = entries_.size();
        while (lo < hi) {
            size_t mid = lo + (hi - lo) / 2;
            int c = compare(entries_[mid].key.data, entries_[mid].key.size, key, keylen);
            if (c == 0) return mid;
            if (c < 0) lo = mid + 1;
            else hi = mid;
        }
        return std::nullopt;
    }
    std::optional<size_t> find(const Bytes& key) const { return find(key.data(), key.size()); }

    /// Look up the value bytes for an encoded key — O(log n). Nullopt if absent.
    std::optional<Slice> get(const uint8_t* key, size_t keylen) const {
        if (auto i = find(key, keylen)) return entries_[*i].value;
        return std::nullopt;
    }
    std::optional<Slice> get(const Bytes& key) const { return get(key.data(), key.size()); }

    /// Entries in canonical (sorted) order.
    const std::vector<Entry>& entries() const { return entries_; }
    std::vector<Entry>::const_iterator begin() const { return entries_.begin(); }
    std::vector<Entry>::const_iterator end() const { return entries_.end(); }
};

inline IndexedMap MapView::indexed() const { return IndexedMap(inner_, len_); }

// --------------------------------------------------------- semantic ordering

inline int semanticOrder(const uint8_t* a, size_t alen, const uint8_t* b, size_t blen);

namespace detail {

// Depth-bounded element-by-element semantic compare over two encoded streams.
// Bounds recursion into nested containers so hostile deeply-nested input is
// rejected (throwing struple::Error) rather than overflowing the stack (Item 5);
// depth 0 at the top level, +1 per container descent.
inline int sem_order_depth(const uint8_t* a, size_t alen, const uint8_t* b, size_t blen, size_t depth);

inline int sem_class_rank(Kind k) {
    switch (k) {
        case Kind::Nil: return 0;
        case Kind::Undefined: return 1;
        case Kind::Bool: return 2;
        case Kind::Int:
        case Kind::BigInt:
        case Kind::F32:
        case Kind::F64:
        case Kind::Decimal: return 3;  // unified "number" class
        case Kind::Timestamp: return 4;
        case Kind::Uuid: return 5;
        case Kind::String: return 6;
        case Kind::Bytes: return 7;
        case Kind::Array: return 8;
        case Kind::Map: return 9;
        case Kind::Set: return 10;
    }
    return 0;
}

inline int sem_dcmp(double x, double y) { return (x > y) - (x < y); }
inline int sem_sign(double f) { return (f > 0) - (f < 0); }

inline int sem_cmp_lex(const uint8_t* a, size_t al, const uint8_t* b, size_t bl) {
    size_t n = al < bl ? al : bl;
    int c = n ? std::memcmp(a, b, n) : 0;
    if (c) return c < 0 ? -1 : 1;
    return (al > bl) - (al < bl);
}

inline int sem_cmp_mag(const uint8_t* a, size_t al, const uint8_t* b, size_t bl) {
    while (al && a[0] == 0) { a++; al--; }
    while (bl && b[0] == 0) { b++; bl--; }
    if (al != bl) return al < bl ? -1 : 1;
    int c = al ? std::memcmp(a, b, al) : 0;
    return c < 0 ? -1 : (c > 0 ? 1 : 0);
}

inline void sem_decompose(double g, uint64_t& mant, int& exp) {
    uint64_t bits;
    std::memcpy(&bits, &g, 8);
    int raw = int((bits >> 52) & 0x7ff);
    uint64_t frac = bits & 0xfffffffffffffull;
    if (raw == 0) {
        mant = frac;
        exp = -1074;
    } else {
        mant = (1ull << 52) | frac;
        exp = raw - 1075;
    }
}

inline Bytes sem_shl(const uint8_t* src, size_t slen, size_t bits) {
    size_t byte_shift = bits / 8;
    int bit_shift = int(bits % 8);
    Bytes out(slen + 1 + byte_shift, 0);
    unsigned carry = 0;
    for (size_t i = slen; i-- > 0;) {
        unsigned cur = (unsigned(src[i]) << bit_shift) | carry;
        out[i + 1] = uint8_t(cur & 0xff);
        carry = cur >> 8;
    }
    out[0] = uint8_t(carry);
    return out;
}

inline int sem_u64_scaled(uint64_t N, uint64_t mant, int exp) {
    if (exp >= 0) {
        if (exp >= 64 || mant > (UINT64_MAX >> exp)) return -1; // mant<<exp > N
        uint64_t B = mant << exp;
        return (N > B) - (N < B);
    }
    int s = -exp;
    if (s >= 64 || N > (UINT64_MAX >> s)) return 1; // N<<s > mant
    uint64_t A = N << s;
    return (A > mant) - (A < mant);
}

inline int sem_mag_scaled(const uint8_t* mag, size_t mlen, uint64_t mant, int exp) {
    uint8_t mb[8];
    for (int i = 0; i < 8; i++) mb[i] = uint8_t(mant >> (8 * (7 - i)));
    if (exp >= 0) {
        Bytes s = sem_shl(mb, 8, size_t(exp));
        return sem_cmp_mag(mag, mlen, s.data(), s.size());
    }
    Bytes s = sem_shl(mag, mlen, size_t(-exp));
    return sem_cmp_mag(s.data(), s.size(), mb, 8);
}

inline int sem_i64_float(int64_t value, double f) {
    if (value == 0) return -sem_sign(f);
    if (value >= -(1ll << 53) && value <= (1ll << 53)) return sem_dcmp(double(value), f);
    int si = value > 0 ? 1 : -1;
    int sf = sem_sign(f);
    if (si != sf) return (si > sf) - (si < sf);
    uint64_t N = value < 0 ? (~uint64_t(value) + 1) : uint64_t(value);
    uint64_t mant;
    int exp;
    sem_decompose(std::fabs(f), mant, exp);
    int c = sem_u64_scaled(N, mant, exp);
    return si < 0 ? -c : c;
}

inline int sem_bigint_float(bool neg, const uint8_t* mag, size_t mlen, double f) {
    int si = neg ? -1 : 1;
    int sf = sem_sign(f);
    if (si != sf) return (si > sf) - (si < sf);
    uint64_t mant;
    int exp;
    sem_decompose(std::fabs(f), mant, exp);
    int c = sem_mag_scaled(mag, mlen, mant, exp);
    return si < 0 ? -c : c;
}

// -- decimal vs the rest of the number class ---------------------------------

// `mag · m` (small m) as new big-endian bytes, trimmed. Pre-trimmed input plus
// front-inserted carries never yield a leading zero.
inline Bytes sem_mul_small(const Bytes& mag, unsigned m) {
    Bytes out = mag;
    uint32_t carry = 0;
    for (size_t i = out.size(); i-- > 0;) {
        uint32_t v = uint32_t(out[i]) * m + carry;
        out[i] = uint8_t(v & 0xff);
        carry = v >> 8;
    }
    while (carry) {
        out.insert(out.begin(), uint8_t(carry & 0xff));
        carry >>= 8;
    }
    return out;
}

inline Bytes sem_mul_pow(const Bytes& mag, unsigned base, size_t k) {
    Bytes cur = mag;
    for (size_t j = 0; j < k; j++) cur = sem_mul_small(cur, base);
    return cur;
}
inline Bytes sem_mul_pow10(const Bytes& mag, size_t k) { return sem_mul_pow(mag, 10, k); }
inline Bytes sem_mul_pow5(const Bytes& mag, size_t k) { return sem_mul_pow(mag, 5, k); }

// Decimal digits (each 0–9, MSD first) -> big-endian base-256 magnitude.
inline Bytes sem_dec_digits_to_mag(const Bytes& digits) {
    Bytes bytes;
    for (uint8_t dch : digits) {  // already 0–9
        uint16_t carry = dch;
        for (size_t i = bytes.size(); i-- > 0;) {
            uint16_t v = uint16_t(bytes[i]) * 10 + carry;
            bytes[i] = uint8_t(v & 0xff);
            carry = v >> 8;
        }
        while (carry) {
            bytes.insert(bytes.begin(), uint8_t(carry & 0xff));
            carry >>= 8;
        }
    }
    return bytes;
}

// An exact base-10 value `sign · mag · 10^exp10` (mag big-endian; empty == 0).
struct B10 {
    int sign;
    Bytes mag;
    int64_t exp10;
};

inline bool sem_is_exact(const Element& e) {
    return e.kind == Kind::Int || e.kind == Kind::BigInt || e.kind == Kind::Decimal;
}

// Decompose an int / big-int / decimal into its exact base-10 value.
inline B10 sem_num_to_b10(const Element& e) {
    if (e.kind == Kind::Int) {
        if (e.integer == 0) return {0, Bytes{}, 0};
        uint64_t N = e.integer < 0 ? (~uint64_t(e.integer) + 1) : uint64_t(e.integer);
        uint8_t buf[8];
        size_t n = u64_to_be(N, buf);
        return {e.integer < 0 ? -1 : 1, Bytes(buf, buf + n), 0};
    }
    if (e.kind == Kind::BigInt) {
        return {e.big_negative ? -1 : 1, e.data, 0};  // data already un-complemented
    }
    // Decimal: data holds the coefficient digits (0–9, MSD first); empty == zero.
    if (e.decIsZero()) return {0, Bytes{}, 0};
    return {e.big_negative ? -1 : 1, sem_dec_digits_to_mag(e.data), e.dec_exp};
}

// Bounds on the base-10 order of magnitude of a nonzero `mag · 10^exp10` value:
// returns {lo, hi} with `|value| ∈ [10^lo, 10^hi)`. Uses byte-length bounds on the
// base-256 magnitude (256^(n-1) ≥ 10^(2(n-1)), 256^n < 10^(3n)). Lets the
// comparators reject a far-apart pair without materializing a magnitude scaled by
// an i32-sized exponent (Item 2 DoS short-circuit).
struct B10Bounds {
    int64_t lo, hi;
};
inline B10Bounds sem_b10_oom_bounds(const B10& v) {
    size_t s = 0;
    while (s < v.mag.size() && v.mag[s] == 0) s++;
    int64_t na = int64_t(v.mag.size() - s);  // ≥ 1 for a nonzero value
    return {v.exp10 + 2 * na - 2, v.exp10 + 3 * na};
}

// Compare two same-sign, nonzero base-10 magnitudes (mag · 10^exp10), exactly.
inline int sem_cmp_b10_mag(const B10& a, const B10& b) {
    // If the orders of magnitude are disjoint, decide by them — no scaling. When
    // they overlap, |a.exp10 − b.exp10| is bounded by the digit counts, so the exact
    // scaling below is cheap (never proportional to the raw exponent) (Item 2).
    B10Bounds ba = sem_b10_oom_bounds(a);
    B10Bounds bb = sem_b10_oom_bounds(b);
    if (ba.hi <= bb.lo) return -1;
    if (bb.hi <= ba.lo) return 1;
    int64_t e = a.exp10 < b.exp10 ? a.exp10 : b.exp10;
    Bytes sa = sem_mul_pow10(a.mag, size_t(a.exp10 - e));
    Bytes sb = sem_mul_pow10(b.mag, size_t(b.exp10 - e));
    return sem_cmp_mag(sa.data(), sa.size(), sb.data(), sb.size());
}

// Compare `mag · 10^exp10` to `mant · 2^e2` (both > 0), exactly. Splits 10^exp10
// into 2^exp10 · 5^exp10 and scales both sides up to integers before comparing.
inline int sem_cmp_b10_mag_to_float(const Bytes& mag, int64_t exp10, uint64_t mant, int e2) {
    int64_t a_pow2 = std::max<int64_t>(0, std::max<int64_t>(-exp10, -int64_t(e2)));  // common 2^
    int64_t b_pow5 = std::max<int64_t>(0, -exp10);                                    // common 5^

    // LHS' = mag · 5^(exp10 + b_pow5) · 2^(exp10 + a_pow2)
    Bytes lhs = sem_mul_pow5(mag, size_t(exp10 + b_pow5));
    lhs = sem_shl(lhs.data(), lhs.size(), size_t(exp10 + a_pow2));

    // RHS' = mant · 5^(b_pow5) · 2^(e2 + a_pow2)
    uint8_t mb[8];
    for (int i = 0; i < 8; i++) mb[i] = uint8_t(mant >> (8 * (7 - i)));
    Bytes mant_bytes(mb, mb + 8);
    while (mant_bytes.size() > 1 && mant_bytes[0] == 0) mant_bytes.erase(mant_bytes.begin());
    Bytes rhs = sem_mul_pow5(mant_bytes, size_t(b_pow5));
    rhs = sem_shl(rhs.data(), rhs.size(), size_t(e2 + a_pow2));

    return sem_cmp_mag(lhs.data(), lhs.size(), rhs.data(), rhs.size());
}

inline int sem_cmp_b10_float(const B10& v, double f) {
    int sf = sem_sign(f);
    if (v.sign != sf) return (v.sign > sf) - (v.sign < sf);
    if (v.sign == 0) return 0;  // both zero
    // Any finite nonzero f64 has |f| ∈ (10^-324, 10^309). If the exact value's order
    // of magnitude is clear of that window, decide without scaling — this is what
    // stops a huge decimal exponent from driving a 2^31-iteration scale (Item 2).
    B10Bounds bnd = sem_b10_oom_bounds(v);
    int c;
    if (bnd.lo >= 310) {
        c = 1;
    } else if (bnd.hi <= -325) {
        c = -1;
    } else {
        uint64_t mant;
        int exp;
        sem_decompose(std::fabs(f), mant, exp);
        c = sem_cmp_b10_mag_to_float(v.mag, v.exp10, mant, exp);
    }
    return v.sign < 0 ? -c : c;
}

// Compare two finite numbers when at least one side is a decimal.
inline int sem_cmp_with_decimal(const Element& a, const Element& b);

inline bool sem_is_int(const Element& e) { return e.kind == Kind::Int || e.kind == Kind::BigInt; }
inline double sem_float(const Element& e) { return e.kind == Kind::F32 ? double(e.f32) : e.f64; }
inline int sem_int_sign(const Element& e) {
    if (e.kind == Kind::Int) return (e.integer > 0) - (e.integer < 0);
    return e.big_negative ? -1 : 1;
}
inline int sem_num_class(const Element& e) {
    if (sem_is_int(e) || e.kind == Kind::Decimal) return 1;  // exact values are finite
    double f = sem_float(e);
    if (std::isnan(f)) return 3;
    if (std::isinf(f)) return f > 0 ? 2 : 0;
    return 1;
}

inline int sem_int_finite(const Element& e, double f) {
    if (e.kind == Kind::Int) return sem_i64_float(e.integer, f);
    return sem_bigint_float(e.big_negative, e.data.data(), e.data.size(), f);
}

inline int sem_int_int(const Element& a, const Element& b) {
    if (a.kind == Kind::Int && b.kind == Kind::Int) return (a.integer > b.integer) - (a.integer < b.integer);
    int sa = sem_int_sign(a), sb = sem_int_sign(b);
    if (sa != sb) return (sa > sb) - (sa < sb);
    bool ab = a.kind == Kind::BigInt, bb = b.kind == Kind::BigInt;
    if (ab != bb) {
        if (sa > 0) return ab ? 1 : -1;
        return ab ? -1 : 1;
    }
    int c = sem_cmp_mag(a.data.data(), a.data.size(), b.data.data(), b.data.size());
    return sa < 0 ? -c : c;
}

inline int sem_numbers(const Element& a, const Element& b) {
    int ca = sem_num_class(a), cb = sem_num_class(b);
    if (ca != cb) return (ca > cb) - (ca < cb);
    if (ca != 1) return 0;
    if (a.kind == Kind::Decimal || b.kind == Kind::Decimal) return sem_cmp_with_decimal(a, b);
    bool ai = sem_is_int(a), bi = sem_is_int(b);
    if (ai && bi) return sem_int_int(a, b);
    if (!ai && !bi) return sem_dcmp(sem_float(a), sem_float(b));
    if (ai) return sem_int_finite(a, sem_float(b));
    return -sem_int_finite(b, sem_float(a));
}

inline int sem_cmp_with_decimal(const Element& a, const Element& b) {
    if (sem_is_exact(a) && sem_is_exact(b)) {
        B10 va = sem_num_to_b10(a);
        B10 vb = sem_num_to_b10(b);
        if (va.sign != vb.sign) return (va.sign > vb.sign) - (va.sign < vb.sign);
        if (va.sign == 0) return 0;
        int c = sem_cmp_b10_mag(va, vb);
        return va.sign < 0 ? -c : c;
    }
    // exactly one side is a finite float
    if (sem_is_exact(a)) return sem_cmp_b10_float(sem_num_to_b10(a), sem_float(b));
    return -sem_cmp_b10_float(sem_num_to_b10(b), sem_float(a));
}

inline int sem_elements(const Element& a, const Element& b, size_t depth) {
    int ra = sem_class_rank(a.kind), rb = sem_class_rank(b.kind);
    if (ra != rb) return (ra > rb) - (ra < rb);
    switch (a.kind) {
        case Kind::Nil:
        case Kind::Undefined: return 0;
        case Kind::Bool: return int(a.boolean) - int(b.boolean);
        case Kind::Int:
        case Kind::BigInt:
        case Kind::F32:
        case Kind::F64:
        case Kind::Decimal: return sem_numbers(a, b);
        case Kind::Timestamp: return (a.integer > b.integer) - (a.integer < b.integer);
        case Kind::Uuid:
        case Kind::String:
        case Kind::Bytes: return sem_cmp_lex(a.data.data(), a.data.size(), b.data.data(), b.data.size());
        case Kind::Array:
        case Kind::Map:
        case Kind::Set:
            // e.data is the already-unescaped inner stream; descend one level.
            return sem_order_depth(a.data.data(), a.data.size(), b.data.data(), b.data.size(), depth + 1);
    }
    return 0;
}

inline int sem_order_depth(const uint8_t* a, size_t alen, const uint8_t* b, size_t blen, size_t depth) {
    if (depth > MAX_DEPTH) throw Error("struple: nesting too deep");
    Reader ra(a, alen), rb(b, blen);
    for (;;) {
        auto ea = ra.next();
        auto eb = rb.next();
        if (!ea && !eb) return 0;
        if (!ea) return -1;
        if (!eb) return 1;
        int c = sem_elements(*ea, *eb, depth);
        if (c != 0) return c;
    }
}

}  // namespace detail

/// Compare two encoded streams by *value*: int 5 == float 5.0, exact across all
/// representations. Returns -1/0/1. NaN sorts greatest; -0.0 == 0; containers
/// recurse. Throws struple::Error on malformed input.
inline int semanticOrder(const uint8_t* a, size_t alen, const uint8_t* b, size_t blen) {
    return detail::sem_order_depth(a, alen, b, blen, 0);
}
inline int semanticOrder(const Bytes& a, const Bytes& b) {
    return semanticOrder(a.data(), a.size(), b.data(), b.size());
}
inline bool semanticEqual(const Bytes& a, const Bytes& b) { return semanticOrder(a, b) == 0; }

}  // namespace struple

#endif  // STRUPLE_HPP
