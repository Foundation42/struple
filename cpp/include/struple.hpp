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
                  INT_NEG_BIG = 0x0f, INT_ZERO = 0x20, INT_POS_BIG = 0x31, FLOAT32 = 0x34,
                  FLOAT64 = 0x35, TIMESTAMP = 0x40, UUID = 0x44, STRING = 0x48, BYTES = 0x49,
                  ARRAY = 0x50, MAP = 0x52, SET = 0x54;
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

enum class Kind { Nil, Undefined, Bool, Int, BigInt, F32, F64, Timestamp, Uuid, String, Bytes, Array, Map, Set };

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
                const uint8_t* nb = take(m);
                size_t n = 0;
                for (size_t i = 0; i < m; i++) n = (n << 8) | comp(nb[i]);
                take(n);
                break;
            }
            case tc::FLOAT32: take(4); break;
            case tc::FLOAT64:
            case tc::TIMESTAMP: take(8); break;
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
    bool isNumber() const { return isInt() || isFloat(); }
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
};

// --------------------------------------------------------- semantic ordering

inline int semanticOrder(const uint8_t* a, size_t alen, const uint8_t* b, size_t blen);

namespace detail {

inline int sem_class_rank(Kind k) {
    switch (k) {
        case Kind::Nil: return 0;
        case Kind::Undefined: return 1;
        case Kind::Bool: return 2;
        case Kind::Int:
        case Kind::BigInt:
        case Kind::F32:
        case Kind::F64: return 3;
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

inline bool sem_is_int(const Element& e) { return e.kind == Kind::Int || e.kind == Kind::BigInt; }
inline double sem_float(const Element& e) { return e.kind == Kind::F32 ? double(e.f32) : e.f64; }
inline int sem_int_sign(const Element& e) {
    if (e.kind == Kind::Int) return (e.integer > 0) - (e.integer < 0);
    return e.big_negative ? -1 : 1;
}
inline int sem_num_class(const Element& e) {
    if (sem_is_int(e)) return 1;
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
    bool ai = sem_is_int(a), bi = sem_is_int(b);
    if (ai && bi) return sem_int_int(a, b);
    if (!ai && !bi) return sem_dcmp(sem_float(a), sem_float(b));
    if (ai) return sem_int_finite(a, sem_float(b));
    return -sem_int_finite(b, sem_float(a));
}

inline int sem_elements(const Element& a, const Element& b) {
    int ra = sem_class_rank(a.kind), rb = sem_class_rank(b.kind);
    if (ra != rb) return (ra > rb) - (ra < rb);
    switch (a.kind) {
        case Kind::Nil:
        case Kind::Undefined: return 0;
        case Kind::Bool: return int(a.boolean) - int(b.boolean);
        case Kind::Int:
        case Kind::BigInt:
        case Kind::F32:
        case Kind::F64: return sem_numbers(a, b);
        case Kind::Timestamp: return (a.integer > b.integer) - (a.integer < b.integer);
        case Kind::Uuid:
        case Kind::String:
        case Kind::Bytes: return sem_cmp_lex(a.data.data(), a.data.size(), b.data.data(), b.data.size());
        case Kind::Array:
        case Kind::Map:
        case Kind::Set:
            return struple::semanticOrder(a.data.data(), a.data.size(), b.data.data(), b.data.size());
    }
    return 0;
}

}  // namespace detail

/// Compare two encoded streams by *value*: int 5 == float 5.0, exact across all
/// representations. Returns -1/0/1. NaN sorts greatest; -0.0 == 0; containers
/// recurse. Throws struple::Error on malformed input.
inline int semanticOrder(const uint8_t* a, size_t alen, const uint8_t* b, size_t blen) {
    Reader ra(a, alen), rb(b, blen);
    for (;;) {
        auto ea = ra.next();
        auto eb = rb.next();
        if (!ea && !eb) return 0;
        if (!ea) return -1;
        if (!eb) return 1;
        int c = detail::sem_elements(*ea, *eb);
        if (c != 0) return c;
    }
}
inline int semanticOrder(const Bytes& a, const Bytes& b) {
    return semanticOrder(a.data(), a.size(), b.data(), b.size());
}
inline bool semanticEqual(const Bytes& a, const Bytes& b) { return semanticOrder(a, b) == 0; }

}  // namespace struple

#endif  // STRUPLE_HPP
