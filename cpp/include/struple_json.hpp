// JSON <-> struple, mirroring the Zig reference. Header-only, self-contained.
#ifndef STRUPLE_JSON_HPP
#define STRUPLE_JSON_HPP

#include "struple.hpp"

#include <charconv>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace struple {

// A parsed JSON value (also used by the conformance tests to read the corpus).
struct Json {
    enum class Kind { Null, Bool, Int, Float, Str, Array, Object };
    Kind kind = Kind::Null;
    bool b = false;
    std::string text;  // Int decimal token, or Str value
    double f = 0;
    std::vector<Json> items;                          // Array
    std::vector<std::pair<std::string, Json>> entries; // Object
};

namespace json_detail {

struct P {
    const char* b;
    size_t i, n;
};

inline void ws(P& p) {
    while (p.i < p.n) {
        char c = p.b[p.i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') p.i++;
        else break;
    }
}

inline bool lit(P& p, const char* s) {
    size_t l = std::strlen(s);
    if (p.i + l <= p.n && std::memcmp(p.b + p.i, s, l) == 0) { p.i += l; return true; }
    return false;
}

inline unsigned hex4(P& p) {
    if (p.i + 4 > p.n) throw Error("json: bad \\u escape");
    unsigned v = 0;
    for (int k = 0; k < 4; k++) {
        char c = p.b[p.i++];
        v <<= 4;
        if (c >= '0' && c <= '9') v |= unsigned(c - '0');
        else if (c >= 'a' && c <= 'f') v |= unsigned(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v |= unsigned(c - 'A' + 10);
        else throw Error("json: bad hex");
    }
    return v;
}

inline void utf8_append(std::string& s, unsigned cp) {
    if (cp < 0x80) {
        s += char(cp);
    } else if (cp < 0x800) {
        s += char(0xc0 | (cp >> 6));
        s += char(0x80 | (cp & 0x3f));
    } else if (cp < 0x10000) {
        s += char(0xe0 | (cp >> 12));
        s += char(0x80 | ((cp >> 6) & 0x3f));
        s += char(0x80 | (cp & 0x3f));
    } else {
        s += char(0xf0 | (cp >> 18));
        s += char(0x80 | ((cp >> 12) & 0x3f));
        s += char(0x80 | ((cp >> 6) & 0x3f));
        s += char(0x80 | (cp & 0x3f));
    }
}

inline std::string parse_string(P& p) {
    p.i++;  // opening quote
    std::string s;
    while (p.i < p.n) {
        unsigned char c = static_cast<unsigned char>(p.b[p.i++]);
        if (c == '"') return s;
        if (c == '\\') {
            if (p.i >= p.n) throw Error("json: bad escape");
            char e = p.b[p.i++];
            switch (e) {
                case '"': s += '"'; break;
                case '\\': s += '\\'; break;
                case '/': s += '/'; break;
                case 'n': s += '\n'; break;
                case 't': s += '\t'; break;
                case 'r': s += '\r'; break;
                case 'b': s += char(0x08); break;
                case 'f': s += char(0x0c); break;
                case 'u': {
                    unsigned cp = hex4(p);
                    if (cp >= 0xd800 && cp <= 0xdbff) {
                        if (p.i + 1 < p.n && p.b[p.i] == '\\' && p.b[p.i + 1] == 'u') {
                            p.i += 2;
                            unsigned lo = hex4(p);
                            cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                        } else {
                            throw Error("json: lone surrogate");
                        }
                    }
                    utf8_append(s, cp);
                    break;
                }
                default: throw Error("json: bad escape");
            }
        } else {
            s += char(c);
        }
    }
    throw Error("json: unterminated string");
}

inline Json parse_value(P& p);

inline Json parse_number(P& p) {
    size_t start = p.i;
    if (p.b[p.i] == '-') p.i++;
    while (p.i < p.n && p.b[p.i] >= '0' && p.b[p.i] <= '9') p.i++;
    bool is_float = false;
    if (p.i < p.n && p.b[p.i] == '.') {
        is_float = true;
        p.i++;
        while (p.i < p.n && p.b[p.i] >= '0' && p.b[p.i] <= '9') p.i++;
    }
    if (p.i < p.n && (p.b[p.i] == 'e' || p.b[p.i] == 'E')) {
        is_float = true;
        p.i++;
        if (p.i < p.n && (p.b[p.i] == '+' || p.b[p.i] == '-')) p.i++;
        while (p.i < p.n && p.b[p.i] >= '0' && p.b[p.i] <= '9') p.i++;
    }
    std::string tok(p.b + start, p.i - start);
    Json j;
    if (is_float) {
        j.kind = Json::Kind::Float;
        j.f = std::strtod(tok.c_str(), nullptr);
    } else {
        j.kind = Json::Kind::Int;
        j.text = std::move(tok);
    }
    return j;
}

inline Json parse_array(P& p) {
    p.i++;
    Json j;
    j.kind = Json::Kind::Array;
    ws(p);
    if (p.i < p.n && p.b[p.i] == ']') { p.i++; return j; }
    for (;;) {
        j.items.push_back(parse_value(p));
        ws(p);
        if (p.i >= p.n) throw Error("json: array");
        char c = p.b[p.i++];
        if (c == ',') continue;
        if (c == ']') break;
        throw Error("json: array");
    }
    return j;
}

inline Json parse_object(P& p) {
    p.i++;
    Json j;
    j.kind = Json::Kind::Object;
    ws(p);
    if (p.i < p.n && p.b[p.i] == '}') { p.i++; return j; }
    for (;;) {
        ws(p);
        if (p.i >= p.n || p.b[p.i] != '"') throw Error("json: key");
        std::string k = parse_string(p);
        ws(p);
        if (p.i >= p.n || p.b[p.i] != ':') throw Error("json: colon");
        p.i++;
        Json v = parse_value(p);
        j.entries.emplace_back(std::move(k), std::move(v));
        ws(p);
        if (p.i >= p.n) throw Error("json: object");
        char c = p.b[p.i++];
        if (c == ',') continue;
        if (c == '}') break;
        throw Error("json: object");
    }
    return j;
}

inline Json parse_value(P& p) {
    ws(p);
    if (p.i >= p.n) throw Error("json: unexpected end");
    char c = p.b[p.i];
    Json j;
    if (c == 'n') { if (!lit(p, "null")) throw Error("json"); j.kind = Json::Kind::Null; return j; }
    if (c == 't') { if (!lit(p, "true")) throw Error("json"); j.kind = Json::Kind::Bool; j.b = true; return j; }
    if (c == 'f') { if (!lit(p, "false")) throw Error("json"); j.kind = Json::Kind::Bool; j.b = false; return j; }
    if (c == '"') { j.kind = Json::Kind::Str; j.text = parse_string(p); return j; }
    if (c == '[') return parse_array(p);
    if (c == '{') return parse_object(p);
    if (c == '-' || (c >= '0' && c <= '9')) return parse_number(p);
    throw Error("json: unexpected character");
}

}  // namespace json_detail

inline Json json_parse(std::string_view text) {
    json_detail::P p{text.data(), 0, text.size()};
    Json j = json_detail::parse_value(p);
    json_detail::ws(p);
    if (p.i != p.n) throw Error("json: trailing data");
    return j;
}

// ----------------------------------------- arbitrary-precision decimal <-> bytes

inline std::string magnitude_to_decimal(const Bytes& mag) {
    if (mag.empty()) return "0";
    Bytes work = mag;
    std::string digits;
    size_t start = 0;
    while (start < work.size()) {
        unsigned rem = 0;
        for (size_t i = start; i < work.size(); i++) {
            unsigned cur = (rem << 8) | work[i];
            work[i] = uint8_t(cur / 10);
            rem = cur % 10;
        }
        digits += char('0' + rem);
        while (start < work.size() && work[start] == 0) start++;
    }
    std::reverse(digits.begin(), digits.end());
    return digits;
}

inline Bytes decimal_to_magnitude(std::string_view digits) {
    Bytes buf;
    for (char ch : digits) {
        if (ch < '0' || ch > '9') continue;
        unsigned carry = unsigned(ch - '0');
        for (size_t i = buf.size(); i-- > 0;) {
            unsigned v = unsigned(buf[i]) * 10 + carry;
            buf[i] = uint8_t(v & 0xff);
            carry = v >> 8;
        }
        while (carry) {
            buf.insert(buf.begin(), uint8_t(carry & 0xff));
            carry >>= 8;
        }
    }
    return buf;
}

// -------------------------------------------------------------------- from_json

inline void encode_int_text(Writer& w, const std::string& s) {
    int64_t iv;
    auto r1 = std::from_chars(s.data(), s.data() + s.size(), iv);
    if (r1.ec == std::errc() && r1.ptr == s.data() + s.size()) { w.append_int(iv); return; }
    if (!s.empty() && s[0] != '-') {
        uint64_t uv;
        auto r2 = std::from_chars(s.data(), s.data() + s.size(), uv);
        if (r2.ec == std::errc() && r2.ptr == s.data() + s.size()) { w.append_uint(uv); return; }
    }
    bool neg = !s.empty() && s[0] == '-';
    std::string_view digits = neg ? std::string_view(s).substr(1) : std::string_view(s);
    w.append_big_int(neg, decimal_to_magnitude(digits));
}

inline void encode_json(Writer& w, const Json& j) {
    switch (j.kind) {
        case Json::Kind::Null: w.append_nil(); break;
        case Json::Kind::Bool: w.append_bool(j.b); break;
        case Json::Kind::Int: encode_int_text(w, j.text); break;
        case Json::Kind::Float: w.append_f64(j.f); break;
        case Json::Kind::Str: w.append_string(j.text); break;
        case Json::Kind::Array: {
            Writer c;
            for (auto& it : j.items) encode_json(c, it);
            w.append_array(c.bytes());
            break;
        }
        case Json::Kind::Object: {
            std::vector<std::pair<Bytes, Bytes>> entries;
            for (auto& [k, v] : j.entries) {
                Writer kw;
                kw.append_string(k);
                Writer vw;
                encode_json(vw, v);
                entries.emplace_back(kw.take(), vw.take());
            }
            w.append_map(std::move(entries));
            break;
        }
    }
}

inline Bytes from_json(std::string_view text) {
    Writer w;
    encode_json(w, json_parse(text));
    return w.take();
}

// ---------------------------------------------------------------------- to_json

inline void render_string(std::string& out, std::string_view s) {
    out += '"';
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            case 0x08: out += "\\b"; break;
            case 0x0c: out += "\\f"; break;
            default:
                if (c < 0x20) {
                    char u[8];
                    std::snprintf(u, sizeof u, "\\u%04x", c);
                    out += u;
                } else {
                    out += char(c);
                }
        }
    }
    out += '"';
}

inline void render_float(std::string& out, double f) {
    if (!std::isfinite(f)) { out += "null"; return; }
    char buf[40];
    auto r = std::to_chars(buf, buf + sizeof buf, f);  // shortest round-trip
    out.append(buf, r.ptr);
}

inline std::string base64(const Bytes& data) {
    static const char T[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    for (size_t i = 0; i < data.size(); i += 3) {
        unsigned b0 = data[i];
        unsigned b1 = i + 1 < data.size() ? data[i + 1] : 0;
        unsigned b2 = i + 2 < data.size() ? data[i + 2] : 0;
        unsigned n = (b0 << 16) | (b1 << 8) | b2;
        out += T[(n >> 18) & 63];
        out += T[(n >> 12) & 63];
        out += (i + 1 < data.size()) ? T[(n >> 6) & 63] : '=';
        out += (i + 2 < data.size()) ? T[n & 63] : '=';
    }
    return out;
}

inline void render(std::string& out, const Element& e) {
    switch (e.kind) {
        case Kind::Nil:
        case Kind::Undefined: out += "null"; break;
        case Kind::Bool: out += e.boolean ? "true" : "false"; break;
        case Kind::Int:
        case Kind::Timestamp: out += std::to_string(e.integer); break;
        case Kind::BigInt:
            if (e.big_negative) out += '-';
            out += magnitude_to_decimal(e.data);
            break;
        case Kind::F32: render_float(out, double(e.f32)); break;
        case Kind::F64: render_float(out, e.f64); break;
        case Kind::Uuid: {
            static const char* hexd = "0123456789abcdef";
            std::string u;
            u.reserve(36);
            for (size_t i = 0; i < e.data.size(); i++) {
                if (i == 4 || i == 6 || i == 8 || i == 10) u += '-';
                u += hexd[e.data[i] >> 4];
                u += hexd[e.data[i] & 0xf];
            }
            render_string(out, u);
            break;
        }
        case Kind::String: render_string(out, e.str); break;
        case Kind::Bytes: render_string(out, base64(e.data)); break;
        case Kind::Array:
        case Kind::Set: {
            out += '[';
            Reader r(e.data);
            bool first = true;
            while (auto x = r.next()) {
                if (!first) out += ',';
                first = false;
                render(out, *x);
            }
            out += ']';
            break;
        }
        case Kind::Map: {
            out += '{';
            Reader r(e.data);
            bool first = true;
            while (auto k = r.next()) {
                auto v = r.next();
                if (!v) throw Error("json: malformed map");
                if (!first) out += ',';
                first = false;
                if (k->kind == Kind::String) {
                    render_string(out, k->str);
                } else {
                    std::string tmp;
                    render(tmp, *k);
                    render_string(out, tmp);
                }
                out += ':';
                render(out, *v);
            }
            out += '}';
            break;
        }
    }
}

inline std::string to_json(const uint8_t* buf, size_t len) {
    Reader r(buf, len);
    auto e = r.next();
    if (!e) return "null";
    std::string out;
    render(out, *e);
    return out;
}
inline std::string to_json(const Bytes& v) { return to_json(v.data(), v.size()); }

}  // namespace struple

#endif  // STRUPLE_JSON_HPP
