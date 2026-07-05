//! Semantic (value-based) ordering over encoded struple streams.
//!
//! `order`/`compare` give the raw `memcmp` order: the type byte dominates, so an
//! integer and a float never interleave by magnitude. `semanticOrder` instead
//! compares by **value** — int, big-int, float32 and float64 all compare by their
//! exact mathematical value, so `int 5 == float 5.0`, `int 2^100 < +inf`, and
//! large integers compare against floats with no precision loss.
//!
//! Cross-type order (when the two values aren't both numbers):
//!
//!     nil < undefined < bool < number < timestamp < uuid < string < bytes
//!         < array < map < set
//!
//! NaN sorts as the greatest number (above `+inf`); `-0.0 == 0.0 == int 0`.
//! Containers recurse element-wise, with a shorter value sorting before a longer
//! one that extends it. Streams compare element-by-element, like `order`.
//!
//! An allocator is required for nested containers and for the (rare) big-int vs
//! float comparison; comparing scalar numbers never allocates.

const std = @import("std");
const struple = @import("struple.zig");

const Reader = struple.Reader;
const Element = struple.Element;
const Kind = struple.Kind;
const BigInt = struple.BigInt;
const Decimal = struple.Decimal;
const DecodeError = struple.DecodeError;
const Order = std.math.Order;
const Allocator = std.mem.Allocator;

pub const SemanticError = DecodeError || Allocator.Error || error{NestingTooDeep};

/// Compare two encoded streams element-by-element by semantic value.
pub fn semanticOrder(allocator: Allocator, a: []const u8, b: []const u8) SemanticError!Order {
    return semanticOrderDepth(allocator, a, b, 0);
}

fn semanticOrderDepth(allocator: Allocator, a: []const u8, b: []const u8, depth: usize) SemanticError!Order {
    // Bound recursion into nested containers so hostile deeply-nested input is
    // rejected rather than overflowing the stack (Item 5).
    if (depth > struple.max_depth) return error.NestingTooDeep;
    var ra = Reader.init(a);
    var rb = Reader.init(b);
    while (true) {
        const ea = try ra.next();
        const eb = try rb.next();
        if (ea == null and eb == null) return .eq;
        if (ea == null) return .lt; // a is a prefix of b
        if (eb == null) return .gt;
        const c = try compareElements(allocator, ea.?, eb.?, depth);
        if (c != .eq) return c;
    }
}

/// Semantic equality — `semanticOrder(...) == .eq`.
pub fn semanticEql(allocator: Allocator, a: []const u8, b: []const u8) SemanticError!bool {
    return (try semanticOrder(allocator, a, b)) == .eq;
}

// ---------------------------------------------------------------------------
// Element-level comparison
// ---------------------------------------------------------------------------

fn classRank(k: Kind) u8 {
    return switch (k) {
        .nil => 0,
        .undef => 1,
        .boolean => 2,
        .int, .big_int, .float32, .float64, .decimal => 3, // unified "number" class
        .timestamp => 4,
        .uuid => 5,
        .string => 6,
        .bytes => 7,
        .array => 8,
        .map => 9,
        .set => 10,
    };
}

fn compareElements(allocator: Allocator, a: Element, b: Element, depth: usize) SemanticError!Order {
    const ra = classRank(a);
    const rb = classRank(b);
    if (ra != rb) return std.math.order(ra, rb);
    return switch (a) {
        .nil, .undef => .eq,
        .boolean => |x| std.math.order(@intFromBool(x), @intFromBool(b.boolean)),
        .int, .big_int, .float32, .float64, .decimal => compareNumbers(allocator, a, b),
        .timestamp => |x| std.math.order(x, b.timestamp),
        .uuid => |x| std.mem.order(u8, &x, &b.uuid),
        // string/bytes content order == framed-byte order (the wire format is
        // built so memcmp of the framed slice already gives content order).
        .string => |x| std.mem.order(u8, x, b.string),
        .bytes => |x| std.mem.order(u8, x, b.bytes),
        .array => |x| semanticOrderContainer(allocator, x, b.array, depth),
        .set => |x| semanticOrderContainer(allocator, x, b.set, depth),
        .map => |x| semanticOrderContainer(allocator, x, b.map, depth),
    };
}

fn semanticOrderContainer(allocator: Allocator, fa: []const u8, fb: []const u8, depth: usize) SemanticError!Order {
    const ia = try struple.unescapeAlloc(allocator, fa);
    defer allocator.free(ia);
    const ib = try struple.unescapeAlloc(allocator, fb);
    defer allocator.free(ib);
    return semanticOrderDepth(allocator, ia, ib, depth + 1);
}

// ---------------------------------------------------------------------------
// Numbers
// ---------------------------------------------------------------------------

// Rank within the number class: -inf < finite < +inf < NaN.
fn numClass(e: Element) u8 {
    const f: f64 = switch (e) {
        .int, .big_int, .decimal => return 1, // integers and decimals are always finite
        .float32 => |x| x,
        .float64 => |x| x,
        else => unreachable,
    };
    if (std.math.isNan(f)) return 3;
    if (std.math.isPositiveInf(f)) return 2;
    if (std.math.isNegativeInf(f)) return 0;
    return 1;
}

fn compareNumbers(allocator: Allocator, a: Element, b: Element) SemanticError!Order {
    const ca = numClass(a);
    const cb = numClass(b);
    if (ca != cb) return std.math.order(ca, cb);
    if (ca != 1) return .eq; // both -inf, both +inf, or both NaN
    return compareFinite(allocator, a, b);
}

fn isIntKind(e: Element) bool {
    return e == .int or e == .big_int;
}

fn floatVal(e: Element) f64 {
    return switch (e) {
        .float32 => |x| @floatCast(x),
        .float64 => |x| x,
        else => unreachable,
    };
}

fn compareFinite(allocator: Allocator, a: Element, b: Element) SemanticError!Order {
    if (a == .decimal or b == .decimal) return compareWithDecimal(allocator, a, b);
    const ai = isIntKind(a);
    const bi = isIntKind(b);
    if (ai and bi) return compareIntInt(a, b);
    if (!ai and !bi) return std.math.order(floatVal(a), floatVal(b)); // both finite floats
    if (ai) return compareIntFinite(allocator, a, floatVal(b));
    return (try compareIntFinite(allocator, b, floatVal(a))).invert();
}

// -- integer vs integer ------------------------------------------------------

fn intSign(e: Element) i8 {
    return switch (e) {
        .int => |v| if (v > 0) @as(i8, 1) else if (v < 0) @as(i8, -1) else 0,
        .big_int => |bi| if (bi.negative) -1 else 1, // big-ints are never zero
        else => unreachable,
    };
}

fn compareIntInt(a: Element, b: Element) Order {
    if (a == .int and b == .int) return std.math.order(a.int, b.int);

    const sa = intSign(a);
    const sb = intSign(b);
    if (sa != sb) return std.math.order(sa, sb);

    // Same sign. A big-int always has a larger magnitude than a fixed int.
    const ab = (a == .big_int);
    const bb = (b == .big_int);
    if (ab != bb) {
        const big_is_a = ab;
        if (sa > 0) return if (big_is_a) .gt else .lt;
        return if (big_is_a) .lt else .gt;
    }
    // Both big-ints, same sign: compare un-complemented magnitudes.
    return compareBigMag(a.big_int, b.big_int, sa);
}

fn compareBigMag(a: BigInt, b: BigInt, sign: i8) Order {
    var c: Order = .eq;
    if (a.mag_stored.len != b.mag_stored.len) {
        c = std.math.order(a.mag_stored.len, b.mag_stored.len);
    } else {
        for (a.mag_stored, b.mag_stored) |x, y| {
            const xb = if (a.negative) ~x else x;
            const yb = if (b.negative) ~y else y;
            if (xb != yb) {
                c = std.math.order(xb, yb);
                break;
            }
        }
    }
    return if (sign < 0) c.invert() else c;
}

// -- integer vs finite float -------------------------------------------------

fn compareIntFinite(allocator: Allocator, e: Element, f: f64) SemanticError!Order {
    switch (e) {
        .int => |v| return compareI128Finite(v, f),
        .big_int => |bi| return compareBigIntFinite(allocator, bi, f),
        else => unreachable,
    }
}

fn compareI128Finite(value: i128, f: f64) Order {
    if (value == 0) return std.math.order(0, signRank(f));
    // Fast path: integers that round-trip through f64 exactly.
    if (value >= -(1 << 53) and value <= (1 << 53)) {
        return std.math.order(@as(f64, @floatFromInt(value)), f);
    }
    const signI: i8 = if (value > 0) 1 else -1;
    const signF = signRank(f);
    if (signI != signF) return std.math.order(signI, signF);

    const N: u128 = if (value < 0) @as(u128, @intCast(-(value + 1))) + 1 else @intCast(value);
    const d = decompose(@abs(f));
    const c = compareU128ToScaled(N, d.mant, d.exp);
    return if (signI < 0) c.invert() else c;
}

fn signRank(f: f64) i8 {
    if (f > 0) return 1;
    if (f < 0) return -1;
    return 0; // ±0.0
}

const Decomposed = struct { mant: u64, exp: i32 };

/// Decompose a finite, nonzero magnitude `g = |f|` into `mant * 2^exp`.
fn decompose(g: f64) Decomposed {
    const bits: u64 = @bitCast(g);
    const raw_exp: u64 = (bits >> 52) & 0x7FF;
    const frac: u64 = bits & 0xFFFFFFFFFFFFF;
    if (raw_exp == 0) return .{ .mant = frac, .exp = -1074 }; // subnormal
    return .{ .mant = (@as(u64, 1) << 52) | frac, .exp = @as(i32, @intCast(raw_exp)) - 1075 };
}

/// Compare a u128 `N` to `mant * 2^exp` (both non-negative), exactly.
fn compareU128ToScaled(N: u128, mant: u64, exp: i32) Order {
    const max_u128: u128 = std.math.maxInt(u128);
    if (exp >= 0) {
        const sh: u32 = @intCast(exp);
        if (sh >= 128 or @as(u128, mant) > (max_u128 >> @as(u7, @intCast(sh)))) {
            return .lt; // mant<<exp overflows u128, so it exceeds N
        }
        return std.math.order(N, @as(u128, mant) << @as(u7, @intCast(sh)));
    }
    const sh: u32 = @intCast(-exp);
    if (sh >= 128 or N > (max_u128 >> @as(u7, @intCast(sh)))) {
        return .gt; // N<<sh overflows u128, so N exceeds mant
    }
    return std.math.order(N << @as(u7, @intCast(sh)), @as(u128, mant));
}

fn compareBigIntFinite(allocator: Allocator, bi: BigInt, f: f64) SemanticError!Order {
    const signI: i8 = if (bi.negative) -1 else 1;
    const signF = signRank(f);
    if (signI != signF) return std.math.order(signI, signF);

    const mag = try bi.magnitudeAlloc(allocator); // true (un-complemented) magnitude
    defer allocator.free(mag);
    const d = decompose(@abs(f));
    const c = try compareMagToScaled(allocator, mag, d.mant, d.exp);
    return if (signI < 0) c.invert() else c;
}

/// Compare a big-endian magnitude (non-empty) to `mant * 2^exp`, exactly.
fn compareMagToScaled(allocator: Allocator, mag: []const u8, mant: u64, exp: i32) SemanticError!Order {
    var mant_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &mant_buf, mant, .big);
    const mant_bytes = trimLeadingZeros(&mant_buf);

    if (exp >= 0) {
        const scaled = try shiftLeftBytes(allocator, mant_bytes, @intCast(exp));
        defer allocator.free(scaled);
        return compareMag(mag, scaled);
    }
    const scaled = try shiftLeftBytes(allocator, mag, @intCast(-exp));
    defer allocator.free(scaled);
    return compareMag(scaled, mant_bytes);
}

// ---------------------------------------------------------------------------
// Decimal vs the rest of the number class
// ---------------------------------------------------------------------------

// An exact base-10 value `sign · mag · 10^exp10` (mag big-endian; empty mag == 0).
const B10 = struct { sign: i8, mag: []u8, exp10: i64 };

/// Decompose an int / big-int / decimal into its exact base-10 value (allocates `mag`).
fn numToB10(allocator: Allocator, e: Element) SemanticError!B10 {
    switch (e) {
        .int => |v| {
            if (v == 0) return .{ .sign = 0, .mag = try allocator.alloc(u8, 0), .exp10 = 0 };
            const N: u128 = if (v < 0) @as(u128, @intCast(-(v + 1))) + 1 else @intCast(v);
            var buf: [16]u8 = undefined;
            std.mem.writeInt(u128, &buf, N, .big);
            return .{ .sign = if (v < 0) -1 else 1, .mag = try allocator.dupe(u8, trimLeadingZeros(&buf)), .exp10 = 0 };
        },
        .big_int => |bi| return .{ .sign = if (bi.negative) -1 else 1, .mag = try bi.magnitudeAlloc(allocator), .exp10 = 0 },
        .decimal => |d| {
            if (d.isZero()) return .{ .sign = 0, .mag = try allocator.alloc(u8, 0), .exp10 = 0 };
            const digbuf = try allocator.alloc(u8, d.coeff_stored.len * 2);
            defer allocator.free(digbuf);
            const mag = try decDigitsToMag(allocator, d.coefficientDigits(digbuf));
            return .{ .sign = if (d.negative) -1 else 1, .mag = mag, .exp10 = d.exponent() };
        },
        else => unreachable,
    }
}

fn isExactKind(e: Element) bool {
    return e == .int or e == .big_int or e == .decimal;
}

fn compareWithDecimal(allocator: Allocator, a: Element, b: Element) SemanticError!Order {
    if (isExactKind(a) and isExactKind(b)) {
        const va = try numToB10(allocator, a);
        defer allocator.free(va.mag);
        const vb = try numToB10(allocator, b);
        defer allocator.free(vb.mag);
        if (va.sign != vb.sign) return std.math.order(va.sign, vb.sign);
        if (va.sign == 0) return .eq;
        const c = try compareB10Mag(allocator, va, vb);
        return if (va.sign < 0) c.invert() else c;
    }
    // exactly one side is a finite float
    if (isExactKind(a)) {
        const va = try numToB10(allocator, a);
        defer allocator.free(va.mag);
        return compareB10Float(allocator, va, floatVal(b));
    }
    const vb = try numToB10(allocator, b);
    defer allocator.free(vb.mag);
    return (try compareB10Float(allocator, vb, floatVal(a))).invert();
}

/// Bounds on the base-10 order of magnitude of a nonzero `mag · 10^exp10` value:
/// returns `{lo, hi}` with `|value| ∈ [10^lo, 10^hi)`. Uses byte-length bounds on
/// the base-256 magnitude (`256^(n-1) ≥ 10^(2(n-1))`, `256^n < 10^(3n)`). Lets the
/// comparators reject a far-apart pair without materializing a magnitude scaled by
/// an i32-sized exponent (Item 2 DoS short-circuit).
fn b10OomBounds(v: B10) struct { lo: i64, hi: i64 } {
    const na: i64 = @intCast(trimLeadingZeros(v.mag).len); // ≥ 1 for a nonzero value
    return .{ .lo = v.exp10 + 2 * na - 2, .hi = v.exp10 + 3 * na };
}

/// Compare two same-sign, nonzero base-10 magnitudes (`mag · 10^exp10`), exactly.
fn compareB10Mag(allocator: Allocator, a: B10, b: B10) SemanticError!Order {
    // If the orders of magnitude are disjoint, decide by them — no scaling. When
    // they overlap, `|a.exp10 − b.exp10|` is bounded by the digit counts, so the
    // exact scaling below is cheap (never proportional to the raw exponent).
    const ba = b10OomBounds(a);
    const bb = b10OomBounds(b);
    if (ba.hi <= bb.lo) return .lt;
    if (bb.hi <= ba.lo) return .gt;
    const e = @min(a.exp10, b.exp10);
    const sa = try mulPow10(allocator, a.mag, @intCast(a.exp10 - e));
    defer allocator.free(sa);
    const sb = try mulPow10(allocator, b.mag, @intCast(b.exp10 - e));
    defer allocator.free(sb);
    return compareMag(sa, sb);
}

fn compareB10Float(allocator: Allocator, v: B10, f: f64) SemanticError!Order {
    const sf = signRank(f);
    if (v.sign != sf) return std.math.order(v.sign, sf);
    if (v.sign == 0) return .eq; // both zero
    // Any finite nonzero f64 has |f| ∈ (10^-324, 10^309). If the exact value's
    // order of magnitude is clear of that window, decide without scaling — this is
    // what stops a huge decimal exponent from driving a 2^31-iteration scale (Item 2).
    const bnd = b10OomBounds(v);
    const c: Order = if (bnd.lo >= 310)
        .gt
    else if (bnd.hi <= -325)
        .lt
    else blk: {
        const d = decompose(@abs(f));
        break :blk try compareB10MagToFloat(allocator, v.mag, v.exp10, d.mant, d.exp);
    };
    return if (v.sign < 0) c.invert() else c;
}

/// Compare `mag · 10^exp10` to `mant · 2^e2` (both > 0), exactly. Splits `10^exp10`
/// into `2^exp10 · 5^exp10` and scales both sides up to integers before comparing.
fn compareB10MagToFloat(allocator: Allocator, mag: []const u8, exp10: i64, mant: u64, e2: i32) SemanticError!Order {
    const a_pow2: i64 = @max(@as(i64, 0), @max(-exp10, -@as(i64, e2))); // common 2^ multiplier
    const b_pow5: i64 = @max(@as(i64, 0), -exp10); // common 5^ multiplier

    // LHS' = mag · 5^(exp10 + b_pow5) · 2^(exp10 + a_pow2)
    var lhs = try mulPow5(allocator, mag, @intCast(exp10 + b_pow5));
    {
        const sh = try shiftLeftBytes(allocator, lhs, @intCast(exp10 + a_pow2));
        allocator.free(lhs);
        lhs = sh;
    }
    defer allocator.free(lhs);

    // RHS' = mant · 5^(b_pow5) · 2^(e2 + a_pow2)
    var mant_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &mant_buf, mant, .big);
    var rhs = try mulPow5(allocator, trimLeadingZeros(&mant_buf), @intCast(b_pow5));
    {
        const sh = try shiftLeftBytes(allocator, rhs, @intCast(e2 + a_pow2));
        allocator.free(rhs);
        rhs = sh;
    }
    defer allocator.free(rhs);

    return compareMag(lhs, rhs);
}

// ---------------------------------------------------------------------------
// Magnitude byte helpers
// ---------------------------------------------------------------------------

fn trimLeadingZeros(b: []const u8) []const u8 {
    var s: usize = 0;
    while (s < b.len and b[s] == 0) s += 1;
    return b[s..];
}

fn compareMag(a: []const u8, b: []const u8) Order {
    const ta = trimLeadingZeros(a);
    const tb = trimLeadingZeros(b);
    if (ta.len != tb.len) return std.math.order(ta.len, tb.len);
    return std.mem.order(u8, ta, tb);
}

/// `src << bits` as new big-endian bytes (may carry leading zeros).
fn shiftLeftBytes(allocator: Allocator, src: []const u8, bits: usize) Allocator.Error![]u8 {
    const byte_shift = bits / 8;
    const bit_shift: u3 = @intCast(bits % 8);

    // First: src << bit_shift, into a buffer one byte longer (for the carry).
    const tmp = try allocator.alloc(u8, src.len + 1);
    defer allocator.free(tmp);
    var carry: u16 = 0;
    var i: usize = src.len;
    while (i > 0) {
        i -= 1;
        const cur: u16 = (@as(u16, src[i]) << bit_shift) | carry;
        tmp[i + 1] = @truncate(cur);
        carry = cur >> 8;
    }
    tmp[0] = @truncate(carry);

    // Then: append `byte_shift` zero bytes at the least-significant (right) end.
    const out = try allocator.alloc(u8, tmp.len + byte_shift);
    @memcpy(out[0..tmp.len], tmp);
    @memset(out[tmp.len..], 0);
    return out;
}

/// Decimal digits (each 0–9, most-significant first) -> big-endian base-256 magnitude.
fn decDigitsToMag(allocator: Allocator, digits: []const u8) Allocator.Error![]u8 {
    var bytes = std.ArrayList(u8).init(allocator);
    errdefer bytes.deinit();
    for (digits) |dch| {
        var carry: u16 = dch; // already 0–9
        var i = bytes.items.len;
        while (i > 0) {
            i -= 1;
            const v = @as(u16, bytes.items[i]) * 10 + carry;
            bytes.items[i] = @truncate(v);
            carry = v >> 8;
        }
        while (carry > 0) {
            try bytes.insert(0, @truncate(carry));
            carry >>= 8;
        }
    }
    return bytes.toOwnedSlice();
}

/// `mag · m` (small `m`) as new big-endian bytes, trimmed.
fn mulSmall(allocator: Allocator, mag: []const u8, m: u16) Allocator.Error![]u8 {
    var bytes = std.ArrayList(u8).init(allocator);
    errdefer bytes.deinit();
    try bytes.appendSlice(mag);
    var carry: u32 = 0;
    var i = bytes.items.len;
    while (i > 0) {
        i -= 1;
        const v = @as(u32, bytes.items[i]) * m + carry;
        bytes.items[i] = @truncate(v);
        carry = v >> 8;
    }
    while (carry > 0) {
        try bytes.insert(0, @truncate(carry));
        carry >>= 8;
    }
    // Pre-trimmed inputs + front-inserted carries never yield a leading zero.
    return bytes.toOwnedSlice();
}

fn mulPow(allocator: Allocator, mag: []const u8, base: u16, k: usize) Allocator.Error![]u8 {
    var cur = try allocator.dupe(u8, mag);
    var j: usize = 0;
    while (j < k) : (j += 1) {
        const nx = try mulSmall(allocator, cur, base);
        allocator.free(cur);
        cur = nx;
    }
    return cur;
}

fn mulPow10(allocator: Allocator, mag: []const u8, k: usize) Allocator.Error![]u8 {
    return mulPow(allocator, mag, 10, k);
}

fn mulPow5(allocator: Allocator, mag: []const u8, k: usize) Allocator.Error![]u8 {
    return mulPow(allocator, mag, 5, k);
}
