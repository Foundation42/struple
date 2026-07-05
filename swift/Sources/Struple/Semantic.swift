// Semantic (value-based) ordering over encoded struple streams.
//
// `compare` gives the raw `memcmp` order: the type byte dominates, so an integer
// and a float never interleave by magnitude. `semanticOrder` instead compares by
// **value** — int, big-int, float32, float64 and decimal all compare by their
// exact mathematical value, so `int 5 == float 5.0`, `int 2^100 < +inf`, and
// large integers/decimals compare against floats with no precision loss.
//
// Cross-type order (when the two values aren't both numbers):
//
//     nil < undefined < bool < number < timestamp < uuid < string < bytes
//         < array < map < set
//
// NaN sorts as the greatest number (above +inf); -0.0 == 0.0 == int 0.
// Containers recurse element-wise, with a shorter value sorting before a longer
// one that extends it.
//
// Exactness without a native big integer: every cross-representation comparison
// is reduced to comparing two non-negative big-endian byte magnitudes. The
// decimal-vs-float case splits 10^e into 2^e·5^e and scales both sides up to
// integers (mirroring the Zig/Rust/C/C++ references).

// MARK: - Public API

/// Compare two encoded streams element-by-element by semantic value (-1, 0, 1).
public func semanticOrder(_ a: [UInt8], _ b: [UInt8]) throws -> Int {
    try semanticOrder(a[...], b[...], 0)
}

// `depth` is the container nesting level of the streams being compared (0 at the
// top level, +1 per container descent). Bounding it rejects hostile deeply-nested
// input before the recursion overflows the stack (Item 5).
func semanticOrder(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>, _ depth: Int) throws -> Int {
    if depth > maxDepth { throw StrupleError.nestingTooDeep }
    var ra = Reader(a)
    var rb = Reader(b)
    while true {
        let ea = try ra.next()
        let eb = try rb.next()
        if ea == nil && eb == nil { return 0 }
        if ea == nil { return -1 }  // a is a prefix of b
        if eb == nil { return 1 }
        let c = try compareElements(ea!, eb!, depth)
        if c != 0 { return c }
    }
}

/// Semantic equality — `semanticOrder(...) == 0`.
public func semanticEqual(_ a: [UInt8], _ b: [UInt8]) throws -> Bool {
    try semanticOrder(a, b) == 0
}

// MARK: - Element-level comparison

private func classRank(_ k: Kind) -> Int {
    switch k {
    case .nil_: return 0
    case .undef: return 1
    case .boolean: return 2
    case .int, .bigInt, .float32, .float64, .decimal: return 3  // unified "number" class
    case .timestamp: return 4
    case .uuid: return 5
    case .string: return 6
    case .bytes: return 7
    case .array: return 8
    case .map: return 9
    case .set: return 10
    }
}

private func cmpInt<T: Comparable>(_ a: T, _ b: T) -> Int {
    a < b ? -1 : (a > b ? 1 : 0)
}

private func compareElements(_ a: Element, _ b: Element, _ depth: Int) throws -> Int {
    let ra = classRank(a.kind)
    let rb = classRank(b.kind)
    if ra != rb { return cmpInt(ra, rb) }
    switch a {
    case .nil_, .undef:
        return 0
    case .boolean(let x):
        guard case .boolean(let y) = b else { return 0 }
        return cmpInt(x ? 1 : 0, y ? 1 : 0)
    case .int, .bigInt, .float32, .float64, .decimal:
        return try compareNumbers(a, b)
    case .timestamp(let x):
        guard case .timestamp(let y) = b else { return 0 }
        return cmpInt(x, y)
    case .uuid(let x):
        guard case .uuid(let y) = b else { return 0 }
        return lexCompare(x[...], y[...])
    // string/bytes content order == framed-byte order (the wire format is built
    // so memcmp of the framed slice already gives content order).
    case .string(let x):
        guard case .string(let y) = b else { return 0 }
        return lexCompare(x, y)
    case .bytes(let x):
        guard case .bytes(let y) = b else { return 0 }
        return lexCompare(x, y)
    case .array(let x):
        guard case .array(let y) = b else { return 0 }
        return try semanticOrderContainer(x, y, depth)
    case .set(let x):
        guard case .set(let y) = b else { return 0 }
        return try semanticOrderContainer(x, y, depth)
    case .map(let x):
        guard case .map(let y) = b else { return 0 }
        return try semanticOrderContainer(x, y, depth)
    }
}

private func semanticOrderContainer(_ fa: ArraySlice<UInt8>, _ fb: ArraySlice<UInt8>, _ depth: Int) throws -> Int {
    let ia = unescape(fa)
    let ib = unescape(fb)
    return try semanticOrder(ia[...], ib[...], depth + 1)
}

// MARK: - Numbers

// Rank within the number class: -inf < finite < +inf < NaN.
private func numClass(_ e: Element) -> Int {
    let f: Double
    switch e {
    case .int, .bigInt, .decimal: return 1  // integers and decimals are always finite
    case .float32(let x): f = Double(x)
    case .float64(let x): f = x
    default: return 1
    }
    if f.isNaN { return 3 }
    if f == .infinity { return 2 }
    if f == -.infinity { return 0 }
    return 1
}

private func compareNumbers(_ a: Element, _ b: Element) throws -> Int {
    let ca = numClass(a)
    let cb = numClass(b)
    if ca != cb { return cmpInt(ca, cb) }
    if ca != 1 { return 0 }  // both -inf, both +inf, or both NaN
    return try compareFinite(a, b)
}

private func isIntKind(_ e: Element) -> Bool {
    if case .int = e { return true }
    if case .bigInt = e { return true }
    return false
}

private func isDecimalKind(_ e: Element) -> Bool {
    if case .decimal = e { return true }
    return false
}

private func isExactKind(_ e: Element) -> Bool {
    isIntKind(e) || isDecimalKind(e)
}

private func floatVal(_ e: Element) -> Double {
    switch e {
    case .float32(let x): return Double(x)
    case .float64(let x): return x
    default: return 0
    }
}

private func compareFinite(_ a: Element, _ b: Element) throws -> Int {
    if isDecimalKind(a) || isDecimalKind(b) { return try compareWithDecimal(a, b) }
    let ai = isIntKind(a)
    let bi = isIntKind(b)
    if ai && bi { return compareIntInt(a, b) }
    if !ai && !bi { return cmpInt(floatVal(a), floatVal(b)) }  // both finite floats
    if ai { return compareIntFinite(a, floatVal(b)) }
    return -compareIntFinite(b, floatVal(a))
}

// MARK: integer vs integer

private func intSign(_ e: Element) -> Int {
    switch e {
    case .int(let v): return v > 0 ? 1 : (v < 0 ? -1 : 0)
    case .bigInt(let bi): return bi.negative ? -1 : 1  // big-ints are never zero
    default: return 0
    }
}

private func compareIntInt(_ a: Element, _ b: Element) -> Int {
    if case .int(let x) = a, case .int(let y) = b { return cmpInt(x, y) }

    let sa = intSign(a)
    let sb = intSign(b)
    if sa != sb { return cmpInt(sa, sb) }

    // Same sign. A big-int always has a larger magnitude than a fixed int.
    let ab = isBig(a)
    let bb = isBig(b)
    if ab != bb {
        let bigIsA = ab
        if sa > 0 { return bigIsA ? 1 : -1 }
        return bigIsA ? -1 : 1
    }
    // Both big-ints, same sign: compare un-complemented magnitudes.
    guard case .bigInt(let x) = a, case .bigInt(let y) = b else { return 0 }
    return compareBigMag(x, y, sa)
}

private func isBig(_ e: Element) -> Bool {
    if case .bigInt = e { return true }
    return false
}

private func compareBigMag(_ a: BigInt, _ b: BigInt, _ sign: Int) -> Int {
    var c = 0
    if a.magStored.count != b.magStored.count {
        c = cmpInt(a.magStored.count, b.magStored.count)
    } else {
        for (x, y) in zip(a.magStored, b.magStored) {
            let xb = a.negative ? ~x : x
            let yb = b.negative ? ~y : y
            if xb != yb {
                c = cmpInt(xb, yb)
                break
            }
        }
    }
    return sign < 0 ? -c : c
}

// MARK: integer vs finite float

private func compareIntFinite(_ e: Element, _ f: Double) -> Int {
    switch e {
    case .int(let v): return compareI128Finite(v, f)
    case .bigInt(let bi): return compareBigIntFinite(bi, f)
    default: return 0
    }
}

private func signRank(_ f: Double) -> Int {
    if f > 0 { return 1 }
    if f < 0 { return -1 }
    return 0  // ±0.0
}

private func compareI128Finite(_ value: Int128, _ f: Double) -> Int {
    if value == 0 { return cmpInt(0, signRank(f)) }
    // Fast path: integers that round-trip through Double exactly.
    if value >= -(Int128(1) << 53) && value <= (Int128(1) << 53) {
        return cmpInt(Double(value), f)
    }
    let signI = value > 0 ? 1 : -1
    let signF = signRank(f)
    if signI != signF { return cmpInt(signI, signF) }

    let n: UInt128 = value < 0 ? (UInt128(-(value + 1)) + 1) : UInt128(value)
    let d = decompose(abs(f))
    let c = compareU128ToScaled(n, d.mant, d.exp)
    return signI < 0 ? -c : c
}

private struct Decomposed {
    let mant: UInt64
    let exp: Int32
}

/// Decompose a finite, nonzero magnitude `g = |f|` into `mant * 2^exp`.
private func decompose(_ g: Double) -> Decomposed {
    let bits = g.bitPattern
    let rawExp = (bits >> 52) & 0x7FF
    let frac = bits & 0xF_FFFF_FFFF_FFFF
    if rawExp == 0 { return Decomposed(mant: frac, exp: -1074) }  // subnormal
    return Decomposed(mant: (UInt64(1) << 52) | frac, exp: Int32(rawExp) - 1075)
}

/// Compare a UInt128 `N` to `mant * 2^exp` (both non-negative), exactly.
private func compareU128ToScaled(_ n: UInt128, _ mant: UInt64, _ exp: Int32) -> Int {
    let maxU128 = UInt128.max
    if exp >= 0 {
        let sh = Int(exp)
        if sh >= 128 || UInt128(mant) > (maxU128 >> sh) {
            return -1  // mant<<exp overflows u128, so it exceeds N
        }
        return cmpInt(n, UInt128(mant) << sh)
    }
    let sh = Int(-exp)
    if sh >= 128 || n > (maxU128 >> sh) {
        return 1  // N<<sh overflows u128, so N exceeds mant
    }
    return cmpInt(n << sh, UInt128(mant))
}

private func compareBigIntFinite(_ bi: BigInt, _ f: Double) -> Int {
    let signI = bi.negative ? -1 : 1
    let signF = signRank(f)
    if signI != signF { return cmpInt(signI, signF) }

    let mag = bi.magnitude  // true (un-complemented) magnitude
    let d = decompose(abs(f))
    let c = compareMagToScaled(mag, d.mant, d.exp)
    return signI < 0 ? -c : c
}

/// Compare a big-endian magnitude (non-empty) to `mant * 2^exp`, exactly.
private func compareMagToScaled(_ mag: [UInt8], _ mant: UInt64, _ exp: Int32) -> Int {
    let mantBytes = trimLeadingZeros(u64ToBytes(mant))
    if exp >= 0 {
        let scaled = shiftLeftBytes(mantBytes, Int(exp))
        return compareMag(mag, scaled)
    }
    let scaled = shiftLeftBytes(mag, Int(-exp))
    return compareMag(scaled, mantBytes)
}

// MARK: - Decimal vs the rest of the number class

// An exact base-10 value `sign · mag · 10^exp10` (mag big-endian; empty == 0).
private struct B10 {
    let sign: Int
    let mag: [UInt8]
    let exp10: Int64
}

/// Decompose an int / big-int / decimal into its exact base-10 value.
private func numToB10(_ e: Element) -> B10 {
    switch e {
    case .int(let v):
        if v == 0 { return B10(sign: 0, mag: [], exp10: 0) }
        let n: UInt128 = v < 0 ? (UInt128(-(v + 1)) + 1) : UInt128(v)
        return B10(sign: v < 0 ? -1 : 1, mag: trimLeadingZeros(u128ToBytes(n)), exp10: 0)
    case .bigInt(let bi):
        return B10(sign: bi.negative ? -1 : 1, mag: bi.magnitude, exp10: 0)
    case .decimal(let d):
        if d.isZero { return B10(sign: 0, mag: [], exp10: 0) }
        let mag = decDigitsToMag(d.coefficientDigits)
        return B10(sign: d.negative ? -1 : 1, mag: mag, exp10: d.exponent)
    default:
        return B10(sign: 0, mag: [], exp10: 0)
    }
}

private func compareWithDecimal(_ a: Element, _ b: Element) throws -> Int {
    if isExactKind(a) && isExactKind(b) {
        let va = numToB10(a)
        let vb = numToB10(b)
        if va.sign != vb.sign { return cmpInt(va.sign, vb.sign) }
        if va.sign == 0 { return 0 }
        let c = compareB10Mag(va, vb)
        return va.sign < 0 ? -c : c
    }
    // exactly one side is a finite float
    if isExactKind(a) {
        let va = numToB10(a)
        return compareB10Float(va, floatVal(b))
    }
    let vb = numToB10(b)
    return -compareB10Float(vb, floatVal(a))
}

/// Bounds on the base-10 order of magnitude of a nonzero `mag · 10^exp10` value:
/// returns `(lo, hi)` with `|value| ∈ [10^lo, 10^hi)`. Uses byte-length bounds on
/// the base-256 magnitude (`256^(n-1) ≥ 10^(2(n-1))`, `256^n < 10^(3n)`). Lets the
/// comparators reject a far-apart pair without materializing a magnitude scaled by
/// an i32-sized exponent (Item 2 DoS short-circuit).
private func b10OomBounds(_ v: B10) -> (lo: Int64, hi: Int64) {
    let na = Int64(trimLeadingZeros(v.mag).count)  // ≥ 1 for a nonzero value
    return (lo: v.exp10 + 2 * na - 2, hi: v.exp10 + 3 * na)
}

/// Compare two same-sign, nonzero base-10 magnitudes (`mag · 10^exp10`), exactly.
private func compareB10Mag(_ a: B10, _ b: B10) -> Int {
    // If the orders of magnitude are disjoint, decide by them — no scaling. When
    // they overlap, `|a.exp10 − b.exp10|` is bounded by the digit counts, so the
    // exact scaling below is cheap (never proportional to the raw exponent).
    let ba = b10OomBounds(a)
    let bb = b10OomBounds(b)
    if ba.hi <= bb.lo { return -1 }
    if bb.hi <= ba.lo { return 1 }
    let e = min(a.exp10, b.exp10)
    let sa = mulPow10(a.mag, Int(a.exp10 - e))
    let sb = mulPow10(b.mag, Int(b.exp10 - e))
    return compareMag(sa, sb)
}

private func compareB10Float(_ v: B10, _ f: Double) -> Int {
    let sf = signRank(f)
    if v.sign != sf { return cmpInt(v.sign, sf) }
    if v.sign == 0 { return 0 }  // both zero
    // Any finite nonzero f64 has |f| ∈ (10^-324, 10^309). If the exact value's
    // order of magnitude is clear of that window, decide without scaling — this is
    // what stops a huge decimal exponent from driving a 2^31-iteration scale (Item 2).
    let bnd = b10OomBounds(v)
    let c: Int
    if bnd.lo >= 310 {
        c = 1
    } else if bnd.hi <= -325 {
        c = -1
    } else {
        let d = decompose(abs(f))
        c = compareB10MagToFloat(v.mag, v.exp10, d.mant, d.exp)
    }
    return v.sign < 0 ? -c : c
}

/// Compare `mag · 10^exp10` to `mant · 2^e2` (both > 0), exactly. Splits `10^exp10`
/// into `2^exp10 · 5^exp10` and scales both sides up to integers before comparing.
private func compareB10MagToFloat(
    _ mag: [UInt8], _ exp10: Int64, _ mant: UInt64, _ e2: Int32
) -> Int {
    let aPow2 = max(Int64(0), max(-exp10, -Int64(e2)))  // common 2^ multiplier
    let bPow5 = max(Int64(0), -exp10)  // common 5^ multiplier

    // LHS' = mag · 5^(exp10 + bPow5) · 2^(exp10 + aPow2)
    var lhs = mulPow5(mag, Int(exp10 + bPow5))
    lhs = shiftLeftBytes(lhs, Int(exp10 + aPow2))

    // RHS' = mant · 5^(bPow5) · 2^(e2 + aPow2)
    var rhs = mulPow5(trimLeadingZeros(u64ToBytes(mant)), Int(bPow5))
    rhs = shiftLeftBytes(rhs, Int(Int64(e2) + aPow2))

    return compareMag(lhs, rhs)
}

// MARK: - Magnitude byte helpers

private func u64ToBytes(_ v: UInt64) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 8)
    for k in 0..<8 { out[k] = UInt8((v >> ((7 - k) * 8)) & 0xFF) }
    return out
}

private func u128ToBytes(_ v: UInt128) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 16)
    for k in 0..<16 { out[k] = UInt8((v >> ((15 - k) * 8)) & 0xFF) }
    return out
}

private func trimLeadingZeros(_ b: [UInt8]) -> [UInt8] {
    var s = 0
    while s < b.count && b[s] == 0 { s += 1 }
    return Array(b[s...])
}

private func compareMag(_ a: [UInt8], _ b: [UInt8]) -> Int {
    let ta = trimLeadingZeros(a)
    let tb = trimLeadingZeros(b)
    if ta.count != tb.count { return cmpInt(ta.count, tb.count) }
    return lexCompare(ta[...], tb[...])
}

/// `src << bits` as new big-endian bytes (may carry leading zeros).
private func shiftLeftBytes(_ src: [UInt8], _ bits: Int) -> [UInt8] {
    let byteShift = bits / 8
    let bitShift = bits % 8

    // First: src << bitShift, into a buffer one byte longer (for the carry).
    var tmp = [UInt8](repeating: 0, count: src.count + 1)
    var carry: UInt16 = 0
    var i = src.count
    while i > 0 {
        i -= 1
        let cur = (UInt16(src[i]) << bitShift) | carry
        tmp[i + 1] = UInt8(cur & 0xFF)
        carry = cur >> 8
    }
    tmp[0] = UInt8(carry & 0xFF)

    // Then: append `byteShift` zero bytes at the least-significant (right) end.
    var out = tmp
    out.append(contentsOf: [UInt8](repeating: 0, count: byteShift))
    return out
}

/// Decimal digits (each 0–9, MSD first) -> big-endian base-256 magnitude.
private func decDigitsToMag(_ digits: [UInt8]) -> [UInt8] {
    var bytes: [UInt8] = []
    for dch in digits {
        var carry = UInt16(dch)  // already 0–9
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

/// `mag · m` (small `m`) as new big-endian bytes, trimmed.
private func mulSmall(_ mag: [UInt8], _ m: UInt32) -> [UInt8] {
    var bytes = mag
    var carry: UInt32 = 0
    var i = bytes.count
    while i > 0 {
        i -= 1
        let v = UInt32(bytes[i]) * m + carry
        bytes[i] = UInt8(v & 0xFF)
        carry = v >> 8
    }
    while carry > 0 {
        bytes.insert(UInt8(carry & 0xFF), at: 0)
        carry >>= 8
    }
    return bytes
}

private func mulPow(_ mag: [UInt8], _ base: UInt32, _ k: Int) -> [UInt8] {
    var cur = mag
    var j = 0
    while j < k {
        cur = mulSmall(cur, base)
        j += 1
    }
    return cur
}

private func mulPow10(_ mag: [UInt8], _ k: Int) -> [UInt8] { mulPow(mag, 10, k) }
private func mulPow5(_ mag: [UInt8], _ k: Int) -> [UInt8] { mulPow(mag, 5, k) }
