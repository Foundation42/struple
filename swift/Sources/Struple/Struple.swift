// struple — streaming, lexicographically-ordered tuple packing for Swift.
//
// A `struple` value is a stream of self-delimiting, typed elements packed into a
// byte buffer. The defining property:
//
//     compare(pack(a), pack(b)) == the semantic order of a and b
//
// i.e. the raw encoded bytes are directly `memcmp`-comparable — drop two packed
// tuples into any byte-ordered store and they sort correctly with no custom
// comparator. This is the FoundationDB tuple idea, rebuilt clean in Swift.
//
// The wire format covers the union of the Python and JavaScript data models:
// nil, undefined, bool, arbitrary-precision integers, float32/64, decimal,
// timestamp, UUID, string, bytes, array, map and set. It is byte-identical to
// the Zig reference and the other eight implementations, all driven by the
// shared conformance corpus.
//
// This file has ZERO dependencies (no Foundation). Swift 6's native `Int128` /
// `UInt128` cover the fixed integer range; everything beyond i128 (big integers,
// the decimal coefficient, exact decimal-vs-float comparison) is hand-rolled on
// byte-magnitude arithmetic, exactly as in the C/C++/Rust/Zig references.

// MARK: - Type codes

/// One-byte type tags. The numeric values are load-bearing: their order *is* the
/// cross-type sort order. Gaps are reserved for the future tower (float128,
/// date/time-only, intervals, ...).
public enum TypeCode {
    public static let terminator: UInt8 = 0x00  // framing sentinel; never a type

    public static let nilCode: UInt8 = 0x01  // null (Python None / JS null)
    public static let undef: UInt8 = 0x02  // JS undefined

    public static let boolFalse: UInt8 = 0x05
    public static let boolTrue: UInt8 = 0x06

    // Integers.
    public static let intNegBig: UInt8 = 0x0F  // arbitrary-precision negative (beyond i128)
    public static let intNegMin: UInt8 = 0x10  // widest fixed negative (16-byte magnitude)
    public static let intNegMax: UInt8 = 0x1F  // 1-byte fixed negative
    public static let intZero: UInt8 = 0x20
    public static let intPosMin: UInt8 = 0x21  // 1-byte fixed positive
    public static let intPosMax: UInt8 = 0x30  // widest fixed positive (16-byte magnitude)
    public static let intPosBig: UInt8 = 0x31  // arbitrary-precision positive (beyond i128)

    public static let float32: UInt8 = 0x34
    public static let float64: UInt8 = 0x35

    public static let decimal: UInt8 = 0x38  // arbitrary-precision base-10 number

    public static let timestamp: UInt8 = 0x40

    public static let uuid: UInt8 = 0x44  // 16-byte fixed payload (no framing)

    public static let string: UInt8 = 0x48
    public static let bytes: UInt8 = 0x49

    public static let array: UInt8 = 0x50
    public static let map: UInt8 = 0x52
    public static let set: UInt8 = 0x54
}

/// Companion byte written after a literal 0x00 inside variable-length payloads.
let escapeByte: UInt8 = 0xFF

// Leading marker inside a decimal payload, isolating the three sign groups so
// `memcmp` keeps `negative < zero < positive`. For negatives the rest of the
// payload is bit-complemented, so a larger magnitude sorts earlier.
let decSignNeg: UInt8 = 0x01
let decSignZero: UInt8 = 0x02
let decSignPos: UInt8 = 0x03

// MARK: - Errors

public enum StrupleError: Error, Equatable {
    case truncated
    case invalidType
    case unsupportedType
    case invalidDecimal
    case invalidNumber
    case malformedMap
}

// MARK: - Decoded element view

public enum Kind: Sendable {
    case nil_
    case undef
    case boolean
    case int
    case bigInt
    case float32
    case float64
    case decimal
    case timestamp
    case uuid
    case string
    case bytes
    case array
    case map
    case set
}

/// A decoded element. For `string`/`bytes`/`array`/`map`/`set` the slice points
/// into the source buffer and is the *framed* payload (literal `0x00` still
/// appears as `0x00 0xFF`); when it contains no `0x00` it is already the literal
/// content. Use `unescape(...)`, then a child `Reader` for containers.
public enum Element {
    case nil_
    case undef
    case boolean(Bool)
    case int(Int128)  // fixed-width integers (the i128 range)
    case bigInt(BigInt)  // arbitrary-precision integers (beyond i128)
    case float32(Float)
    case float64(Double)
    case decimal(Decimal)  // arbitrary-precision base-10 number
    case timestamp(Int64)  // microseconds since the Unix epoch, UTC
    case uuid([UInt8])  // 128-bit identifier (16 raw bytes, big-endian/network order)
    case string(ArraySlice<UInt8>)
    case bytes(ArraySlice<UInt8>)
    case array(ArraySlice<UInt8>)
    case map(ArraySlice<UInt8>)
    case set(ArraySlice<UInt8>)

    public var kind: Kind {
        switch self {
        case .nil_: return .nil_
        case .undef: return .undef
        case .boolean: return .boolean
        case .int: return .int
        case .bigInt: return .bigInt
        case .float32: return .float32
        case .float64: return .float64
        case .decimal: return .decimal
        case .timestamp: return .timestamp
        case .uuid: return .uuid
        case .string: return .string
        case .bytes: return .bytes
        case .array: return .array
        case .map: return .map
        case .set: return .set
        }
    }
}

/// View of an arbitrary-precision integer that did not fit the fixed path.
public struct BigInt {
    public let negative: Bool
    /// Big-endian magnitude bytes *as stored* — complemented iff `negative`.
    public let magStored: [UInt8]

    public init(negative: Bool, magStored: [UInt8]) {
        self.negative = negative
        self.magStored = magStored
    }

    /// The normalized big-endian magnitude (un-complemented).
    public var magnitude: [UInt8] {
        negative ? magStored.map { ~$0 } : magStored
    }
}

/// A decoded decimal: value = `(-1)^negative · coefficient · 10^exponent`, with
/// the coefficient's significant digits carried base-100 packed (two per byte).
/// `adjExp` is the adjusted exponent (the power of ten of the most-significant
/// digit, the `E` in `0.d₁d₂… · 10^E`); the zero value has an empty coefficient.
public struct Decimal {
    public let negative: Bool
    public let adjExp: Int64
    /// Base-100 packed digit bytes *as stored* — each pair is `value+1` (1–100),
    /// and bit-complemented when `negative`. Empty for the canonical zero.
    public let coeffStored: [UInt8]

    public init(negative: Bool, adjExp: Int64, coeffStored: [UInt8]) {
        self.negative = negative
        self.adjExp = adjExp
        self.coeffStored = coeffStored
    }

    public var isZero: Bool { coeffStored.isEmpty }

    /// Number of significant decimal digits in the coefficient.
    public var digitCount: Int {
        if coeffStored.isEmpty { return 0 }
        let last = coeffStored[coeffStored.count - 1]
        let pair = (negative ? ~last : last) &- 1
        // An odd digit count pads the final pair's low digit with a (canonical) zero.
        return coeffStored.count * 2 - (pair % 10 == 0 ? 1 : 0)
    }

    /// The power of ten applied to the integer coefficient: `value = ±coefficient · 10^exponent`.
    public var exponent: Int64 {
        adjExp - Int64(digitCount)
    }

    /// The coefficient's decimal digits (each 0–9, most-significant first).
    public var coefficientDigits: [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(coeffStored.count * 2)
        for (idx, raw) in coeffStored.enumerated() {
            let pair = (negative ? ~raw : raw) &- 1
            out.append(pair / 10)
            let lo = pair % 10
            let isLast = idx + 1 == coeffStored.count
            if !(isLast && lo == 0) {  // skip only the synthetic trailing pad
                out.append(lo)
            }
        }
        return out
    }
}

// MARK: - Writer (Packer) — builds an encoded tuple

public struct Writer {
    public private(set) var buffer: [UInt8] = []

    public init() {}

    /// The encoded bytes — memcmp-comparable.
    public var bytes: [UInt8] { buffer }

    public mutating func reset() { buffer.removeAll(keepingCapacity: true) }

    public mutating func appendNil() { buffer.append(TypeCode.nilCode) }

    public mutating func appendUndefined() { buffer.append(TypeCode.undef) }

    public mutating func appendBool(_ value: Bool) {
        buffer.append(value ? TypeCode.boolTrue : TypeCode.boolFalse)
    }

    public mutating func appendInt(_ value: Int64) {
        appendI128(Int128(value))
    }

    public mutating func appendUInt(_ value: UInt64) {
        if value == 0 {
            buffer.append(TypeCode.intZero)
        } else {
            encodePositive(UInt128(value))
        }
    }

    /// Encode any i128. Values in the i128 range always use the fixed slots, so
    /// this writes straight to the buffer with no intermediate magnitude array.
    public mutating func appendI128(_ value: Int128) {
        if value == 0 {
            buffer.append(TypeCode.intZero)
            return
        }
        let negative = value < 0
        let bits = UInt128(bitPattern: value)
        let mag: UInt128 = negative ? (~bits &+ 1) : bits  // two's-complement magnitude
        if negative { encodeNegative(mag) } else { encodePositive(mag) }
    }

    /// Encode an arbitrary-precision integer given its sign and big-endian
    /// magnitude bytes (leading zeros are trimmed). Routes through the fixed path
    /// when the value fits i128 (1–16 byte magnitudes), else the big-int codes.
    public mutating func appendBigInt(negative: Bool, magnitude magnitudeBE: [UInt8]) {
        var mag = magnitudeBE[...]
        while mag.count > 0 && mag.first == 0 { mag = mag.dropFirst() }
        if mag.isEmpty {
            buffer.append(TypeCode.intZero)
            return
        }
        if fitsFixed(negative: negative, mag: mag) {
            let value = readBigEndianU128(mag)
            if negative { encodeNegative(value) } else { encodePositive(value) }
            return
        }
        buffer.append(negative ? TypeCode.intNegBig : TypeCode.intPosBig)
        writeBigIntFields(Array(mag), complement: negative)
    }

    public mutating func appendF32(_ value: Float) {
        var buf = [UInt8](repeating: 0, count: 4)
        let bits = orderableF32Bits(value)
        buf[0] = UInt8((bits >> 24) & 0xFF)
        buf[1] = UInt8((bits >> 16) & 0xFF)
        buf[2] = UInt8((bits >> 8) & 0xFF)
        buf[3] = UInt8(bits & 0xFF)
        buffer.append(TypeCode.float32)
        buffer.append(contentsOf: buf)
    }

    public mutating func appendF64(_ value: Double) {
        let bits = orderableF64Bits(value)
        buffer.append(TypeCode.float64)
        for i in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8((bits >> UInt64(i)) & 0xFF))
        }
    }

    /// Append an arbitrary-precision decimal `(-1)^negative · C · 10^exp`, where
    /// `digits` are the coefficient `C`'s decimal digits (each 0–9, MSD first).
    /// Canonicalized on the way in: leading/trailing zeros stripped, any all-zero
    /// coefficient collapses to the single zero form.
    public mutating func appendDecimal(negative: Bool, digits: [UInt8], exp: Int32) {
        var lead = 0
        while lead < digits.count && digits[lead] == 0 { lead += 1 }
        let sig = Array(digits[lead...])

        buffer.append(TypeCode.decimal)
        if sig.isEmpty {  // canonical zero — one form regardless of scale
            buffer.append(decSignZero)
            return
        }

        // Adjusted exponent: place value of the most-significant digit (0.d…·10^E).
        // Trailing zeros change neither the value nor E, so drop them for storage.
        let adjExp = Int128(sig.count) + Int128(exp)
        var end = sig.count
        while end > 0 && sig[end - 1] == 0 { end -= 1 }
        let store = Array(sig[0..<end])

        // Order-bearing tail: [E as a struple int][base-100 digits][terminator].
        var tail: [UInt8] = []
        encodeFixedInt(into: &tail, value: adjExp)
        var i = 0
        while i < store.count {
            let hi = UInt16(store[i])
            let lo: UInt16 = i + 1 < store.count ? UInt16(store[i + 1]) : 0  // pad odd tail
            tail.append(UInt8(hi * 10 + lo + 1))  // pair 0–99 -> byte 1–100
            i += 2
        }
        tail.append(TypeCode.terminator)

        buffer.append(negative ? decSignNeg : decSignPos)
        for b in tail { buffer.append(negative ? ~b : b) }
    }

    /// Append a decimal parsed from text: `[+/-] digits [. digits] [ (e|E) [+/-] digits ]`.
    public mutating func appendDecimalString(_ s: String) throws {
        let chars = Array(s.utf8)
        var i = 0
        var negative = false
        if i < chars.count && (chars[i] == UInt8(ascii: "+") || chars[i] == UInt8(ascii: "-")) {
            negative = chars[i] == UInt8(ascii: "-")
            i += 1
        }
        var digits: [UInt8] = []
        var exp: Int32 = 0
        var seenPoint = false
        var any = false
        while i < chars.count {
            let c = chars[i]
            if c == UInt8(ascii: ".") {
                if seenPoint { throw StrupleError.invalidDecimal }
                seenPoint = true
                i += 1
                continue
            }
            if c == UInt8(ascii: "e") || c == UInt8(ascii: "E") { break }
            if c < UInt8(ascii: "0") || c > UInt8(ascii: "9") { throw StrupleError.invalidDecimal }
            digits.append(c - UInt8(ascii: "0"))
            if seenPoint { exp -= 1 }
            any = true
            i += 1
        }
        if !any { throw StrupleError.invalidDecimal }
        if i < chars.count && (chars[i] == UInt8(ascii: "e") || chars[i] == UInt8(ascii: "E")) {
            i += 1
            var esign: Int32 = 1
            if i < chars.count && (chars[i] == UInt8(ascii: "+") || chars[i] == UInt8(ascii: "-")) {
                if chars[i] == UInt8(ascii: "-") { esign = -1 }
                i += 1
            }
            var ev: Int32 = 0
            var edig = false
            while i < chars.count {
                if chars[i] < UInt8(ascii: "0") || chars[i] > UInt8(ascii: "9") {
                    throw StrupleError.invalidDecimal
                }
                ev = ev * 10 + Int32(chars[i] - UInt8(ascii: "0"))
                edig = true
                i += 1
            }
            if !edig { throw StrupleError.invalidDecimal }
            exp += esign * ev
        }
        appendDecimal(negative: negative, digits: digits, exp: exp)
    }

    /// Microseconds since the Unix epoch, UTC.
    public mutating func appendTimestamp(_ micros: Int64) {
        // Flip the sign bit so two's-complement order matches unsigned byte order.
        let raw = UInt64(bitPattern: micros) ^ (UInt64(1) << 63)
        buffer.append(TypeCode.timestamp)
        for i in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8((raw >> UInt64(i)) & 0xFF))
        }
    }

    /// A 128-bit UUID, stored as its 16 raw bytes (network/big-endian order).
    public mutating func appendUuid(_ value: [UInt8]) {
        precondition(value.count == 16, "uuid must be 16 bytes")
        buffer.append(TypeCode.uuid)
        buffer.append(contentsOf: value)
    }

    public mutating func appendString(_ value: String) {
        writeFramed(TypeCode.string, Array(value.utf8))
    }

    public mutating func appendStringBytes(_ value: [UInt8]) {
        writeFramed(TypeCode.string, value)
    }

    public mutating func appendBytes(_ value: [UInt8]) {
        writeFramed(TypeCode.bytes, value)
    }

    /// Append a nested array. `child` is the encoded element stream of another tuple.
    public mutating func appendArray(_ child: [UInt8]) {
        writeFramed(TypeCode.array, child)
    }

    /// Append a map. `entries` is a list of `(keyEncoding, valueEncoding)` pairs;
    /// they are sorted by key into canonical order. (Duplicate keys are the
    /// caller's responsibility.)
    public mutating func appendMap(_ entries: [([UInt8], [UInt8])]) {
        let sorted = entries.sorted { lexLess($0.0, $1.0) }
        buffer.append(TypeCode.map)
        for (k, v) in sorted {
            writeEscaped(k)
            writeEscaped(v)
        }
        buffer.append(TypeCode.terminator)
    }

    /// Append a set. `elements` (each an element encoding) are sorted and
    /// de-duplicated into canonical order.
    public mutating func appendSet(_ elements: [[UInt8]]) {
        let sorted = elements.sorted { lexLess($0, $1) }
        buffer.append(TypeCode.set)
        var prev: [UInt8]? = nil
        for e in sorted {
            if let p = prev, p == e { continue }  // skip duplicate
            writeEscaped(e)
            prev = e
        }
        buffer.append(TypeCode.terminator)
    }

    // MARK: Writer internals

    private mutating func encodeFixedInt(into list: inout [UInt8], value: Int128) {
        if value == 0 {
            list.append(TypeCode.intZero)
        } else if value > 0 {
            encodePositiveInto(&list, UInt128(value))
        } else {
            encodeNegativeInto(&list, UInt128(-value))
        }
    }

    private mutating func encodePositive(_ magnitude: UInt128) {
        encodePositiveInto(&buffer, magnitude)
    }

    private func encodePositiveInto(_ list: inout [UInt8], _ magnitude: UInt128) {
        let n = byteLen(magnitude)
        list.append(TypeCode.intZero + UInt8(n))
        appendBigEndianU128(&list, magnitude, n)
    }

    private mutating func encodeNegative(_ magnitude: UInt128) {
        encodeNegativeInto(&buffer, magnitude)
    }

    private func encodeNegativeInto(_ list: inout [UInt8], _ magnitude: UInt128) {
        let posVal = magnitude - 1
        var n = byteLen(posVal)
        if n == 0 { n = 1 }
        list.append(TypeCode.intZero - UInt8(n))
        // Excess form: store 2^(8n) - magnitude. The low n bytes of the wrapping
        // negation give exactly that (and avoid overflow at n == 16).
        appendBigEndianU128(&list, 0 &- magnitude, n)
    }

    private mutating func writeBigIntFields(_ mag: [UInt8], complement: Bool) {
        let n = mag.count
        let m = byteLenInt(n)
        buffer.append(complement ? ~UInt8(m) : UInt8(m))
        var i = m
        while i > 0 {
            i -= 1
            let b = UInt8((n >> (i * 8)) & 0xFF)
            buffer.append(complement ? ~b : b)
        }
        for b in mag { buffer.append(complement ? ~b : b) }
    }

    private mutating func writeEscaped(_ content: [UInt8]) {
        // Bulk-copy the runs between 0x00 bytes; the escape-free case is one append.
        var i = 0
        let n = content.count
        while i < n {
            let start = i
            while i < n && content[i] != 0x00 { i += 1 }
            buffer.append(contentsOf: content[start..<i])
            if i < n {
                buffer.append(0x00)
                buffer.append(escapeByte)
                i += 1
            }
        }
    }

    private mutating func writeFramed(_ typeCode: UInt8, _ content: [UInt8]) {
        buffer.append(typeCode)
        writeEscaped(content)
        buffer.append(TypeCode.terminator)
    }
}

// MARK: - Reader — streams elements back out

public struct Reader {
    public let buf: [UInt8]
    public private(set) var pos: Int

    public init(_ buf: [UInt8]) {
        self.buf = buf
        self.pos = 0
    }

    public init(_ slice: ArraySlice<UInt8>) {
        self.buf = Array(slice)
        self.pos = 0
    }

    public var done: Bool { pos >= buf.count }

    public mutating func next() throws -> Element? {
        if pos >= buf.count { return nil }
        let typeCode = buf[pos]
        pos += 1

        switch typeCode {
        case TypeCode.nilCode: return .nil_
        case TypeCode.undef: return .undef
        case TypeCode.boolFalse: return .boolean(false)
        case TypeCode.boolTrue: return .boolean(true)
        case TypeCode.intZero: return .int(0)
        case 0x10...0x1F, 0x21...0x30:
            let positive = typeCode > TypeCode.intZero
            let n = positive ? Int(typeCode - TypeCode.intZero) : Int(TypeCode.intZero - typeCode)
            let payload = try take(n)
            // The widest (16-byte) slots can address values outside i128; a
            // canonical encoder uses the big-int codes for those, so a fixed
            // 16-byte payload whose value escapes i128 is malformed.
            if n == 16
                && ((positive && payload.first! >= 0x80) || (!positive && payload.first! < 0x80))
            {
                throw StrupleError.invalidType
            }
            return .int(decodeIntPayload(positive: positive, payload: payload))
        case TypeCode.intNegBig, TypeCode.intPosBig:
            let negative = typeCode == TypeCode.intNegBig
            let m = Int(decodeByte(try take(1).first!, negative))
            var n = 0
            for b in try take(m) { n = (n << 8) | Int(decodeByte(b, negative)) }
            let mag = try take(n)
            return .bigInt(BigInt(negative: negative, magStored: Array(mag)))
        case TypeCode.float32:
            return .float32(decodeF32(try take(4)))
        case TypeCode.float64:
            return .float64(decodeF64(try take(8)))
        case TypeCode.decimal:
            return .decimal(try takeDecimal())
        case TypeCode.timestamp:
            let raw = readBigEndianU64(try take(8))
            return .timestamp(Int64(bitPattern: raw ^ (UInt64(1) << 63)))
        case TypeCode.uuid:
            return .uuid(Array(try take(16)))
        case TypeCode.string: return .string(try takeFramed())
        case TypeCode.bytes: return .bytes(try takeFramed())
        case TypeCode.array: return .array(try takeFramed())
        case TypeCode.map: return .map(try takeFramed())
        case TypeCode.set: return .set(try takeFramed())
        default: throw StrupleError.invalidType
        }
    }

    /// The type code of the next element without consuming it (nil at end).
    public var peekType: UInt8? { pos < buf.count ? buf[pos] : nil }

    /// The remaining unread bytes (a valid struple stream).
    public var rest: ArraySlice<UInt8> { buf[pos...] }

    /// The next element's raw bytes (a zero-copy view, itself a valid one-element
    /// struple buffer), advancing the cursor. nil at end of stream.
    public mutating func nextView() throws -> ArraySlice<UInt8>? {
        let start = pos
        if try next() == nil { return nil }
        return buf[start..<pos]
    }

    /// Advance past the next element; returns false at end of stream.
    @discardableResult
    public mutating func skip() throws -> Bool {
        return try nextView() != nil
    }

    private mutating func takeDecimal() throws -> Decimal {
        let sign = try take(1).first!
        if sign == decSignZero {
            return Decimal(negative: false, adjExp: 0, coeffStored: [])
        }
        if sign != decSignNeg && sign != decSignPos { throw StrupleError.invalidType }
        let negative = sign == decSignNeg
        let adjExp = try readDecExponent(complement: negative)
        // Digit bytes are 1–100 (positive) or their complement (negative), and
        // never collide with the terminator (0x00, or 0xFF when complemented).
        let term: UInt8 = negative ? 0xFF : 0x00
        let start = pos
        var i = pos
        while i < buf.count && buf[i] != term { i += 1 }
        if i >= buf.count { throw StrupleError.truncated }
        if i == start { throw StrupleError.invalidType }  // a nonzero decimal must carry digits
        pos = i + 1  // consume the terminator
        return Decimal(negative: negative, adjExp: adjExp, coeffStored: Array(buf[start..<i]))
    }

    /// Read the embedded exponent (a struple integer), un-complementing each byte
    /// for negatives. Big-int exponent codes are rejected (far beyond any real use).
    private mutating func readDecExponent(complement: Bool) throws -> Int64 {
        let tb = decodeByte(try take(1).first!, complement)
        if tb == TypeCode.intZero { return 0 }
        if (tb >= TypeCode.intNegMin && tb <= TypeCode.intNegMax)
            || (tb >= TypeCode.intPosMin && tb <= TypeCode.intPosMax)
        {
            let positive = tb > TypeCode.intZero
            let n = positive ? Int(tb - TypeCode.intZero) : Int(TypeCode.intZero - tb)
            var tmp = [UInt8](repeating: 0, count: 16)
            let raw = try take(n)
            for (k, b) in raw.enumerated() { tmp[k] = decodeByte(b, complement) }
            if n == 16 && ((positive && tmp[0] >= 0x80) || (!positive && tmp[0] < 0x80)) {
                throw StrupleError.invalidType
            }
            let v = decodeIntPayload(positive: positive, payload: tmp[0..<n])
            if v > Int128(Int64.max) || v < Int128(Int64.min) { throw StrupleError.invalidType }
            return Int64(v)
        }
        throw StrupleError.invalidType
    }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        if pos + n > buf.count { throw StrupleError.truncated }
        let slice = buf[pos..<pos + n]
        pos += n
        return slice
    }

    private mutating func takeFramed() throws -> ArraySlice<UInt8> {
        let start = pos
        var i = pos
        while i < buf.count {
            if buf[i] == 0x00 {
                if i + 1 < buf.count && buf[i + 1] == escapeByte {
                    i += 2  // escaped literal 0x00
                    continue
                }
                pos = i + 1  // consume terminator
                return buf[start..<i]
            }
            i += 1
        }
        throw StrupleError.truncated
    }
}

@inline(__always)
func decodeByte(_ b: UInt8, _ complemented: Bool) -> UInt8 {
    complemented ? ~b : b
}

// MARK: - Ordering (ordering IS memcmp)

/// Lexicographic byte order: -1, 0, or 1.
public func compare(_ a: [UInt8], _ b: [UInt8]) -> Int {
    lexCompare(a[...], b[...])
}

func lexCompare(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Int {
    var ia = a.startIndex
    var ib = b.startIndex
    while ia < a.endIndex && ib < b.endIndex {
        let x = a[ia], y = b[ib]
        if x != y { return x < y ? -1 : 1 }
        ia += 1
        ib += 1
    }
    if a.count == b.count { return 0 }
    return a.count < b.count ? -1 : 1
}

func lexLess(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    lexCompare(a[...], b[...]) < 0
}

// MARK: - Escaping helpers for variable-length payloads

public func hasEscapes(_ framed: ArraySlice<UInt8>) -> Bool {
    framed.contains(0x00)
}

public func unescape(_ framed: ArraySlice<UInt8>) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(framed.count)
    var i = framed.startIndex
    while i < framed.endIndex {
        out.append(framed[i])
        if framed[i] == 0x00 { i += 1 }
        i += 1
    }
    return out
}

public func unescape(_ framed: [UInt8]) -> [UInt8] { unescape(framed[...]) }

// MARK: - Integer decode helpers

func decodeIntPayload(positive: Bool, payload: ArraySlice<UInt8>) -> Int128 {
    let raw = readBigEndianU128(payload)
    if positive { return Int128(raw) }
    if payload.count == 16 { return Int128(bitPattern: raw) }  // raw - 2^128 via two's complement
    let span: UInt128 = UInt128(1) << (payload.count * 8)
    return Int128(raw) - Int128(span)
}

/// Does this value (sign + trimmed big-endian magnitude) fit the fixed path, i.e.
/// the i128 range [-2^127, 2^127-1]?
func fitsFixed(negative: Bool, mag: ArraySlice<UInt8>) -> Bool {
    if mag.count < 16 { return true }
    if mag.count > 16 { return false }
    let top = mag.first!
    if top < 0x80 { return true }  // |value| < 2^127
    if !negative { return false }  // positive >= 2^127 -> big-int
    if top != 0x80 { return false }  // magnitude > 2^127 -> big-int
    for b in mag.dropFirst() where b != 0 { return false }  // only exactly 2^127 (-2^127) fits
    return true
}

func byteLen(_ x: UInt128) -> Int {
    if x == 0 { return 0 }
    let bits = 128 - x.leadingZeroBitCount
    return (bits + 7) / 8
}

func byteLenInt(_ x: Int) -> Int {
    if x == 0 { return 0 }
    let bits = Int.bitWidth - x.leadingZeroBitCount
    return (bits + 7) / 8
}

func appendBigEndianU128(_ list: inout [UInt8], _ value: UInt128, _ n: Int) {
    var i = n
    while i > 0 {
        i -= 1
        list.append(UInt8((value >> (i * 8)) & 0xFF))
    }
}

func writeBigEndianU128(_ buf: inout [UInt8], _ off: Int, _ value: UInt128, _ n: Int) {
    for k in 0..<n {
        buf[off + k] = UInt8((value >> ((n - 1 - k) * 8)) & 0xFF)
    }
}

func readBigEndianU128(_ payload: ArraySlice<UInt8>) -> UInt128 {
    var v: UInt128 = 0
    for b in payload { v = (v << 8) | UInt128(b) }
    return v
}

func readBigEndianU64(_ payload: ArraySlice<UInt8>) -> UInt64 {
    var v: UInt64 = 0
    for b in payload { v = (v << 8) | UInt64(b) }
    return v
}

// MARK: - Float encode/decode (IEEE-754 total ordering)

func orderableF32Bits(_ value: Float) -> UInt32 {
    var bits: UInt32
    if value.isNaN {
        bits = 0x7fc0_0000
    } else {
        var v = value
        if v == 0 { v = 0 }  // squash -0.0
        bits = v.bitPattern
    }
    return (bits & 0x8000_0000) != 0 ? ~bits : bits ^ 0x8000_0000
}

func orderableF64Bits(_ value: Double) -> UInt64 {
    var bits: UInt64
    if value.isNaN {
        bits = 0x7ff8_0000_0000_0000
    } else {
        var v = value
        if v == 0 { v = 0 }
        bits = v.bitPattern
    }
    return (bits & 0x8000_0000_0000_0000) != 0 ? ~bits : bits ^ 0x8000_0000_0000_0000
}

func decodeF32(_ p: ArraySlice<UInt8>) -> Float {
    var bits: UInt32 = 0
    for b in p { bits = (bits << 8) | UInt32(b) }
    bits = (bits & 0x8000_0000) != 0 ? bits ^ 0x8000_0000 : ~bits
    return Float(bitPattern: bits)
}

func decodeF64(_ p: ArraySlice<UInt8>) -> Double {
    var bits: UInt64 = 0
    for b in p { bits = (bits << 8) | UInt64(b) }
    bits = (bits & 0x8000_0000_0000_0000) != 0 ? bits ^ 0x8000_0000_0000_0000 : ~bits
    return Double(bitPattern: bits)
}

// MARK: - Transcode (decode + re-encode), used by the conformance harness

/// Decode every element and re-encode it. The build-entry decode check: exact
/// even for types a language can't natively round-trip.
public func transcode(_ encoded: [UInt8]) throws -> [UInt8] {
    var w = Writer()
    var r = Reader(encoded)
    while let e = try r.next() {
        try reencode(&w, e)
    }
    return w.bytes
}

func reencode(_ w: inout Writer, _ e: Element) throws {
    switch e {
    case .nil_: w.appendNil()
    case .undef: w.appendUndefined()
    case .boolean(let b): w.appendBool(b)
    case .int(let v): w.appendI128(v)
    case .bigInt(let bi): w.appendBigInt(negative: bi.negative, magnitude: bi.magnitude)
    case .float32(let f): w.appendF32(f)
    case .float64(let f): w.appendF64(f)
    case .decimal(let d):
        w.appendDecimal(
            negative: d.negative, digits: d.coefficientDigits, exp: Int32(d.exponent))
    case .timestamp(let t): w.appendTimestamp(t)
    case .uuid(let u): w.appendUuid(u)
    case .string(let framed): w.appendStringBytes(unescape(framed))
    case .bytes(let framed): w.appendBytes(unescape(framed))
    case .array(let framed):
        w.appendArray(try reencodeChild(framed))
    case .set(let framed):
        try reencodeSet(&w, framed)
    case .map(let framed):
        try reencodeMap(&w, framed)
    }
}

private func reencodeChild(_ framed: ArraySlice<UInt8>) throws -> [UInt8] {
    let inner = unescape(framed)
    var child = Writer()
    var r = Reader(inner)
    while let e = try r.next() { try reencode(&child, e) }
    return child.bytes
}

private func reencodeSet(_ w: inout Writer, _ framed: ArraySlice<UInt8>) throws {
    let inner = unescape(framed)
    var elems: [[UInt8]] = []
    var r = Reader(inner)
    while let e = try r.next() {
        var ep = Writer()
        try reencode(&ep, e)
        elems.append(ep.bytes)
    }
    w.appendSet(elems)
}

private func reencodeMap(_ w: inout Writer, _ framed: ArraySlice<UInt8>) throws {
    let inner = unescape(framed)
    var entries: [([UInt8], [UInt8])] = []
    var r = Reader(inner)
    while let k = try r.next() {
        guard let v = try r.next() else { throw StrupleError.malformedMap }
        var kp = Writer()
        try reencode(&kp, k)
        var vp = Writer()
        try reencode(&vp, v)
        entries.append((kp.bytes, vp.bytes))
    }
    w.appendMap(entries)
}
