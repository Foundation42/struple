// JSON <-> struple conversion.
//
//   fromJson: JSON text  -> struple encoding (one element for the root value)
//   toJson:   struple bytes -> JSON text (renders the first element)
//
// JSON type mapping:
//   null              <-> nil
//   true / false      <-> bool
//   integer number    <-> integer (arbitrary precision — big JSON ints are kept
//                          losslessly, unlike a Double round-trip)
//   fractional number <-> float64
//   string            <-> string
//   array             <-> array
//   object            <-> map  (canonical: keys come back sorted)
//
// struple types with no JSON equivalent degrade on `toJson`: undefined -> null,
// decimal -> number (exact decimal literal), timestamp -> number (µs),
// uuid -> hyphenated string, bytes -> base64 string, set -> array.
//
// The parser is hand-rolled (no Foundation): integer number tokens are kept as
// text and converted to a byte-magnitude big int, so values a Double would
// corrupt round-trip losslessly.

// MARK: - Public API

/// Parse JSON text and return its struple encoding.
public func fromJson(_ text: String) throws -> [UInt8] {
    let v = try parseJSON(text)
    var w = Writer()
    encodeJSON(&w, v)
    return w.bytes
}

/// Render a struple encoding's first element as canonical JSON text.
public func toJson(_ encoded: [UInt8]) throws -> String {
    var r = Reader(encoded)
    guard let e = try r.next() else { return "null" }
    var out: [UInt8] = []
    try renderJSON(&out, e, 0)
    return String(decoding: out, as: UTF8.self)
}

// MARK: - JSON value model

enum JSONValue {
    case null
    case bool(Bool)
    case int(Int64)
    case bigInt(String)  // exact decimal text (with optional leading sign)
    case float(Double)
    case str(String)
    case array([JSONValue])
    case object([(String, JSONValue)])
}

// MARK: - JSON -> struple

func encodeJSON(_ w: inout Writer, _ v: JSONValue) {
    switch v {
    case .null: w.appendNil()
    case .bool(let b): w.appendBool(b)
    case .int(let n): w.appendInt(n)
    case .bigInt(let text):
        var digits = Substring(text)
        var negative = false
        if digits.first == "-" {
            negative = true
            digits = digits.dropFirst()
        } else if digits.first == "+" {
            digits = digits.dropFirst()
        }
        let mag = decimalToMagnitude(Array(digits.utf8))
        w.appendBigInt(negative: negative, magnitude: mag)
    case .float(let f): w.appendF64(f)
    case .str(let s): w.appendString(s)
    case .array(let items):
        var child = Writer()
        for item in items { encodeJSON(&child, item) }
        w.appendArray(child.bytes)
    case .object(let members):
        var entries: [([UInt8], [UInt8])] = []
        for (key, val) in members {
            var kw = Writer()
            kw.appendString(key)
            var vw = Writer()
            encodeJSON(&vw, val)
            entries.append((kw.bytes, vw.bytes))
        }
        w.appendMap(entries)
    }
}

// MARK: - struple -> JSON

// `depth` is the container nesting level of the element being rendered (0 at the
// root, +1 per array/map/set descent). Bounding it rejects hostile deeply-nested
// input before the recursion overflows the stack (Item 5).
func renderJSON(_ out: inout [UInt8], _ e: Element, _ depth: Int) throws {
    if depth > maxDepth { throw StrupleError.nestingTooDeep }
    switch e {
    case .nil_, .undef:
        out.append(contentsOf: Array("null".utf8))
    case .boolean(let b):
        out.append(contentsOf: Array((b ? "true" : "false").utf8))
    case .int(let v):
        out.append(contentsOf: Array(String(v).utf8))
    case .bigInt(let bi):
        if bi.negative { out.append(UInt8(ascii: "-")) }
        out.append(contentsOf: magnitudeToDecimal(bi.magnitude))
    case .float32(let f):
        renderFloat(&out, Double(f))
    case .float64(let f):
        renderFloat(&out, f)
    case .decimal(let d):
        renderDecimal(&out, d)
    case .timestamp(let t):
        out.append(contentsOf: Array(String(t).utf8))
    case .uuid(let u):
        renderString(&out, renderUUID(u))
    case .string(let framed):
        renderStringBytes(&out, unescape(framed))
    case .bytes(let framed):
        renderString(&out, base64Std(unescape(framed)))
    case .array(let framed), .set(let framed):
        try renderArray(&out, framed, depth)
    case .map(let framed):
        try renderMap(&out, framed, depth)
    }
}

/// Render a float as ECMAScript `Number::toString` — the shortest decimal that
/// round-trips to the same f64, formatted per the ECMA-262 fixed/exponential
/// rules. This is the pinned cross-language float text format (Item 3). f32 is
/// rendered by its exact f64 value: callers promote Float -> Double first.
func renderFloat(_ out: inout [UInt8], _ f: Double) {
    if !f.isFinite {
        out.append(contentsOf: Array("null".utf8))  // JSON has no inf/nan
        return
    }
    if f == 0 {
        out.append(UInt8(ascii: "0"))  // +0.0 and -0.0 both render "0"
        return
    }
    // Swift's Double.description is the shortest round-trip decimal, but in Swift
    // notation (`0.1`, `1e-07`, `1.0e+300`). Parse it into the shortest significant
    // digits + the ECMA integer-part digit count `n`, then re-emit per ECMA-262.
    var s = Substring(String(f))
    if s.first == "-" {
        out.append(UInt8(ascii: "-"))
        s = s.dropFirst()
    }
    // Split off a scientific exponent, if any (`e±dd`).
    var exp = 0
    if let ePos = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        exp = Int(s[s.index(after: ePos)...]) ?? 0
        s = s[..<ePos]
    }
    // Strip the decimal point, tracking the fractional digit count.
    var fracCount = 0
    var digits: [UInt8] = []
    var sawPoint = false
    for c in s.utf8 {
        if c == UInt8(ascii: ".") {
            sawPoint = true
        } else {
            digits.append(c)
            if sawPoint { fracCount += 1 }
        }
    }
    // value = digits(as integer) · 10^q. Normalize the digit string by dropping
    // trailing zeros (each raises q) and then leading zeros (value unchanged); the
    // ECMA integer-part count is then n = k + q.
    var q = exp - fracCount
    while digits.count > 1 && digits.last == UInt8(ascii: "0") {
        digits.removeLast()
        q += 1
    }
    var lead = 0
    while lead < digits.count - 1 && digits[lead] == UInt8(ascii: "0") { lead += 1 }
    if lead > 0 { digits.removeFirst(lead) }
    writeEcmaDigits(&out, digits, digits.count + q)
}

/// Emit shortest significant `digits` as ECMAScript Number::toString, where `n` is
/// the integer-part digit count (`10^(n-1) <= |value| < 10^n`).
func writeEcmaDigits(_ out: inout [UInt8], _ digits: [UInt8], _ n: Int) {
    let k = digits.count
    if n >= 1 && n <= 21 {
        if k <= n {  // integer with trailing zeros
            out.append(contentsOf: digits)
            for _ in 0..<(n - k) { out.append(UInt8(ascii: "0")) }
        } else {  // decimal point inside the digits
            out.append(contentsOf: digits[0..<n])
            out.append(UInt8(ascii: "."))
            out.append(contentsOf: digits[n...])
        }
    } else if n <= 0 && n > -6 {  // 0.00…digits
        out.append(contentsOf: Array("0.".utf8))
        for _ in 0..<(-n) { out.append(UInt8(ascii: "0")) }
        out.append(contentsOf: digits)
    } else {  // exponential: d[.ddd]e±(n-1)
        out.append(digits[0])
        if k > 1 {
            out.append(UInt8(ascii: "."))
            out.append(contentsOf: digits[1...])
        }
        out.append(UInt8(ascii: "e"))
        let e = n - 1
        out.append(e >= 0 ? UInt8(ascii: "+") : UInt8(ascii: "-"))
        out.append(contentsOf: Array(String(abs(e)).utf8))
    }
}

func renderArray(_ out: inout [UInt8], _ framed: ArraySlice<UInt8>, _ depth: Int) throws {
    let content = unescape(framed)
    var r = Reader(content)
    out.append(UInt8(ascii: "["))
    var first = true
    while let e = try r.next() {
        if !first { out.append(UInt8(ascii: ",")) }
        first = false
        try renderJSON(&out, e, depth + 1)
    }
    out.append(UInt8(ascii: "]"))
}

func renderMap(_ out: inout [UInt8], _ framed: ArraySlice<UInt8>, _ depth: Int) throws {
    let content = unescape(framed)
    var r = Reader(content)
    out.append(UInt8(ascii: "{"))
    var first = true
    while let k = try r.next() {
        guard let v = try r.next() else { throw StrupleError.malformedMap }
        if !first { out.append(UInt8(ascii: ",")) }
        first = false
        // JSON keys must be strings.
        switch k {
        case .string(let kf):
            renderStringBytes(&out, unescape(kf))
        default:
            // Non-string key: render its JSON and quote the result.
            var tmp: [UInt8] = []
            try renderJSON(&tmp, k, depth + 1)
            renderStringBytes(&out, tmp)
        }
        out.append(UInt8(ascii: ":"))
        try renderJSON(&out, v, depth + 1)
    }
    out.append(UInt8(ascii: "}"))
}

func renderString(_ out: inout [UInt8], _ s: String) {
    renderStringBytes(&out, Array(s.utf8))
}

func renderStringBytes(_ out: inout [UInt8], _ s: [UInt8]) {
    let hexDigits = Array("0123456789abcdef".utf8)
    out.append(UInt8(ascii: "\""))
    for c in s {
        switch c {
        case UInt8(ascii: "\""): out.append(contentsOf: Array("\\\"".utf8))
        case UInt8(ascii: "\\"): out.append(contentsOf: Array("\\\\".utf8))
        case 0x0A: out.append(contentsOf: Array("\\n".utf8))
        case 0x0D: out.append(contentsOf: Array("\\r".utf8))
        case 0x09: out.append(contentsOf: Array("\\t".utf8))
        case 0x08: out.append(contentsOf: Array("\\b".utf8))
        case 0x0C: out.append(contentsOf: Array("\\f".utf8))
        default:
            if c < 0x20 {
                out.append(UInt8(ascii: "\\"))
                out.append(UInt8(ascii: "u"))
                out.append(UInt8(ascii: "0"))
                out.append(UInt8(ascii: "0"))
                out.append(hexDigits[Int(c >> 4)])
                out.append(hexDigits[Int(c & 0x0F)])
            } else {
                out.append(c)
            }
        }
    }
    out.append(UInt8(ascii: "\""))
}

func renderUUID(_ u: [UInt8]) -> String {
    let hexDigits = Array("0123456789abcdef".utf8)
    var b: [UInt8] = []
    for (i, x) in u.enumerated() {
        if i == 4 || i == 6 || i == 8 || i == 10 { b.append(UInt8(ascii: "-")) }
        b.append(hexDigits[Int(x >> 4)])
        b.append(hexDigits[Int(x & 0x0F)])
    }
    return String(decoding: b, as: UTF8.self)
}

/// Render a decimal as an exact JSON number literal. Plain notation for ordinary
/// scales; a scientific fallback past the pad threshold keeps a huge (i32-bounded)
/// exponent from emitting gigabytes of zeros (Item 2).
func renderDecimal(_ out: inout [UInt8], _ d: Decimal) {
    if d.isZero {
        out.append(UInt8(ascii: "0"))
        return
    }
    let digs = d.coefficientDigits  // 0–9 values, most-significant first
    let k = Int64(digs.count)
    let exp10 = d.exponent  // value = C · 10^exp10

    if d.negative { out.append(UInt8(ascii: "-")) }

    // Plain notation would pad this many zeros; past the threshold, render in
    // scientific notation so a huge (i32-bounded) exponent can't emit gigabytes.
    let maxPlainPad: Int64 = 40
    let pad: Int64
    if exp10 >= 0 {
        pad = exp10
    } else {
        let pp = k + exp10
        pad = pp > 0 ? 0 : -pp
    }
    if pad > maxPlainPad {
        // d1[.d2…dk]e±E, where E = exp10 + k − 1 (the power of ten of the MSD).
        out.append(UInt8(ascii: "0") + digs[0])
        if digs.count > 1 {
            out.append(UInt8(ascii: "."))
            for dd in digs[1...] { out.append(UInt8(ascii: "0") + dd) }
        }
        let sciExp = exp10 + k - 1
        out.append(UInt8(ascii: "e"))
        out.append(sciExp >= 0 ? UInt8(ascii: "+") : UInt8(ascii: "-"))
        out.append(contentsOf: Array(String(abs(sciExp)).utf8))
        return
    }

    if exp10 >= 0 {
        for dd in digs { out.append(UInt8(ascii: "0") + dd) }
        var z: Int64 = 0
        while z < exp10 {
            out.append(UInt8(ascii: "0"))
            z += 1
        }
        return
    }
    let pointPos = k + exp10  // number of integer-part digits
    if pointPos > 0 {
        let pp = Int(pointPos)
        for dd in digs[0..<pp] { out.append(UInt8(ascii: "0") + dd) }
        out.append(UInt8(ascii: "."))
        for dd in digs[pp...] { out.append(UInt8(ascii: "0") + dd) }
    } else {
        out.append(contentsOf: Array("0.".utf8))
        var z = pointPos
        while z < 0 {
            out.append(UInt8(ascii: "0"))
            z += 1
        }
        for dd in digs { out.append(UInt8(ascii: "0") + dd) }
    }
}

func base64Std(_ data: [UInt8]) -> String {
    let t = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    var out: [UInt8] = []
    var i = 0
    while i < data.count {
        let b0 = UInt32(data[i])
        var b1: UInt32 = 0
        var b2: UInt32 = 0
        var n = 1
        if i + 1 < data.count {
            b1 = UInt32(data[i + 1])
            n = 2
        }
        if i + 2 < data.count {
            b2 = UInt32(data[i + 2])
            n = 3
        }
        let v = (b0 << 16) | (b1 << 8) | b2
        out.append(t[Int((v >> 18) & 63)])
        out.append(t[Int((v >> 12) & 63)])
        out.append(n > 1 ? t[Int((v >> 6) & 63)] : UInt8(ascii: "="))
        out.append(n > 2 ? t[Int(v & 63)] : UInt8(ascii: "="))
        i += 3
    }
    return String(decoding: out, as: UTF8.self)
}

// MARK: - Arbitrary-precision decimal <-> big-endian magnitude bytes

/// Decimal ASCII digits -> normalized big-endian magnitude bytes.
func decimalToMagnitude(_ digits: [UInt8]) -> [UInt8] {
    var bytes: [UInt8] = []  // big-endian, no leading zeros
    for ch in digits {
        // bytes = bytes * 10 + digit
        var carry = UInt16(ch - UInt8(ascii: "0"))
        var i = bytes.count
        while i > 0 {
            i -= 1
            let v = UInt16(bytes[i]) * 10 + carry
            bytes[i] = UInt8(v & 0xFF)
            carry = v >> 8
        }
        while carry > 0 {
            bytes.insert(UInt8(carry & 0xFF), at: 0)
            carry >>= 8
        }
    }
    return bytes
}

/// Normalized big-endian magnitude bytes -> decimal ASCII digits.
func magnitudeToDecimal(_ mag: [UInt8]) -> [UInt8] {
    if mag.isEmpty { return Array("0".utf8) }
    var work = mag
    var digits: [UInt8] = []
    var start = 0
    while start < work.count {
        var rem: UInt16 = 0
        var i = start
        while i < work.count {
            let cur = (rem << 8) | UInt16(work[i])
            work[i] = UInt8(cur / 10)
            rem = cur % 10
            i += 1
        }
        digits.append(UInt8(rem) + UInt8(ascii: "0"))
        while start < work.count && work[start] == 0 { start += 1 }
    }
    return digits.reversed()
}

// MARK: - A small JSON parser (no dependencies)

func parseJSON(_ s: String) throws -> JSONValue {
    var p = JSONParser(Array(s.utf8))
    let v = try p.value(0)
    p.skipWS()
    if !p.atEnd { throw StrupleError.invalidNumber }  // trailing data
    return v
}

struct JSONParser {
    let b: [UInt8]
    var i = 0

    init(_ b: [UInt8]) { self.b = b }

    var atEnd: Bool { i >= b.count }

    func peek() -> UInt8? { i < b.count ? b[i] : nil }

    mutating func skipWS() {
        while let c = peek(), c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1 }
    }

    // `depth` is the container nesting level of the value about to be parsed
    // (0 at the root, +1 per array/object descent). Bounding it rejects hostile
    // deeply-nested input before the recursion overflows the stack (Item 5).
    mutating func value(_ depth: Int) throws -> JSONValue {
        if depth > maxDepth { throw StrupleError.nestingTooDeep }
        skipWS()
        guard let c = peek() else { throw StrupleError.invalidNumber }
        switch c {
        case UInt8(ascii: "n"):
            try lit("null")
            return .null
        case UInt8(ascii: "t"):
            try lit("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try lit("false")
            return .bool(false)
        case UInt8(ascii: "\""):
            return .str(try string())
        case UInt8(ascii: "["):
            return try array(depth)
        case UInt8(ascii: "{"):
            return try object(depth)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try number()
        default:
            throw StrupleError.invalidNumber
        }
    }

    mutating func lit(_ s: String) throws {
        let want = Array(s.utf8)
        if i + want.count <= b.count && Array(b[i..<i + want.count]) == want {
            i += want.count
            return
        }
        throw StrupleError.invalidNumber
    }

    mutating func string() throws -> String {
        i += 1  // opening quote
        var out: [UInt8] = []
        while true {
            guard let c = peek() else { throw StrupleError.invalidNumber }
            i += 1
            switch c {
            case UInt8(ascii: "\""):
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard let e = peek() else { throw StrupleError.invalidNumber }
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"):
                    var cp = try hex4()
                    if cp >= 0xD800 && cp <= 0xDBFF {
                        if i + 1 < b.count && b[i] == UInt8(ascii: "\\")
                            && b[i + 1] == UInt8(ascii: "u")
                        {
                            i += 2
                            let lo = try hex4()
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                        } else {
                            throw StrupleError.invalidNumber
                        }
                    }
                    appendRune(&out, cp)
                default:
                    throw StrupleError.invalidNumber
                }
            default:
                out.append(c)
            }
        }
    }

    mutating func hex4() throws -> UInt32 {
        if i + 4 > b.count { throw StrupleError.invalidNumber }
        var v: UInt32 = 0
        for k in 0..<4 {
            let ch = b[i + k]
            let d: UInt32
            switch ch {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(ch - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt32(ch - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt32(ch - UInt8(ascii: "A")) + 10
            default: throw StrupleError.invalidNumber
            }
            v = (v << 4) | d
        }
        i += 4
        return v
    }

    mutating func number() throws -> JSONValue {
        let start = i
        if let c = peek(), c == UInt8(ascii: "-") { i += 1 }
        while let c = peek(), c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") { i += 1 }
        var isFloat = false
        if let c = peek(), c == UInt8(ascii: ".") {
            isFloat = true
            i += 1
            while let c = peek(), c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") { i += 1 }
        }
        if let c = peek(), c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
            isFloat = true
            i += 1
            if let c = peek(), c == UInt8(ascii: "+") || c == UInt8(ascii: "-") { i += 1 }
            while let c = peek(), c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") { i += 1 }
        }
        let tok = String(decoding: b[start..<i], as: UTF8.self)
        if isFloat {
            guard let f = Double(tok) else { throw StrupleError.invalidNumber }
            return .float(f)
        }
        // Fall back to arbitrary precision when the value exceeds Int64.
        if let n = Int64(tok) {
            return .int(n)
        }
        return .bigInt(tok)
    }

    mutating func array(_ depth: Int) throws -> JSONValue {
        i += 1  // [
        var items: [JSONValue] = []
        skipWS()
        if let c = peek(), c == UInt8(ascii: "]") {
            i += 1
            return .array(items)
        }
        while true {
            items.append(try value(depth + 1))
            skipWS()
            guard let c = peek() else { throw StrupleError.invalidNumber }
            if c == UInt8(ascii: ",") {
                i += 1
                continue
            }
            if c == UInt8(ascii: "]") {
                i += 1
                break
            }
            throw StrupleError.invalidNumber
        }
        return .array(items)
    }

    mutating func object(_ depth: Int) throws -> JSONValue {
        i += 1  // {
        var members: [(String, JSONValue)] = []
        skipWS()
        if let c = peek(), c == UInt8(ascii: "}") {
            i += 1
            return .object(members)
        }
        while true {
            skipWS()
            guard let c = peek(), c == UInt8(ascii: "\"") else { throw StrupleError.invalidNumber }
            let key = try string()
            skipWS()
            guard let colon = peek(), colon == UInt8(ascii: ":") else {
                throw StrupleError.invalidNumber
            }
            i += 1
            let val = try value(depth + 1)
            members.append((key, val))
            skipWS()
            guard let c = peek() else { throw StrupleError.invalidNumber }
            if c == UInt8(ascii: ",") {
                i += 1
                continue
            }
            if c == UInt8(ascii: "}") {
                i += 1
                break
            }
            throw StrupleError.invalidNumber
        }
        return .object(members)
    }
}

/// Append the UTF-8 encoding of a code point.
func appendRune(_ dst: inout [UInt8], _ cp: UInt32) {
    if cp < 0x80 {
        dst.append(UInt8(cp))
    } else if cp < 0x800 {
        dst.append(UInt8(0xC0 | (cp >> 6)))
        dst.append(UInt8(0x80 | (cp & 0x3F)))
    } else if cp < 0x10000 {
        dst.append(UInt8(0xE0 | (cp >> 12)))
        dst.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        dst.append(UInt8(0x80 | (cp & 0x3F)))
    } else {
        dst.append(UInt8(0xF0 | (cp >> 18)))
        dst.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        dst.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        dst.append(UInt8(0x80 | (cp & 0x3F)))
    }
}
