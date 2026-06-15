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
const DecodeError = struple.DecodeError;
const Order = std.math.Order;
const Allocator = std.mem.Allocator;

pub const SemanticError = DecodeError || Allocator.Error;

/// Compare two encoded streams element-by-element by semantic value.
pub fn semanticOrder(allocator: Allocator, a: []const u8, b: []const u8) SemanticError!Order {
    var ra = Reader.init(a);
    var rb = Reader.init(b);
    while (true) {
        const ea = try ra.next();
        const eb = try rb.next();
        if (ea == null and eb == null) return .eq;
        if (ea == null) return .lt; // a is a prefix of b
        if (eb == null) return .gt;
        const c = try compareElements(allocator, ea.?, eb.?);
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
        .int, .big_int, .float32, .float64 => 3, // unified "number" class
        .timestamp => 4,
        .uuid => 5,
        .string => 6,
        .bytes => 7,
        .array => 8,
        .map => 9,
        .set => 10,
    };
}

fn compareElements(allocator: Allocator, a: Element, b: Element) SemanticError!Order {
    const ra = classRank(a);
    const rb = classRank(b);
    if (ra != rb) return std.math.order(ra, rb);
    return switch (a) {
        .nil, .undef => .eq,
        .boolean => |x| std.math.order(@intFromBool(x), @intFromBool(b.boolean)),
        .int, .big_int, .float32, .float64 => compareNumbers(allocator, a, b),
        .timestamp => |x| std.math.order(x, b.timestamp),
        .uuid => |x| std.mem.order(u8, &x, &b.uuid),
        // string/bytes content order == framed-byte order (the wire format is
        // built so memcmp of the framed slice already gives content order).
        .string => |x| std.mem.order(u8, x, b.string),
        .bytes => |x| std.mem.order(u8, x, b.bytes),
        .array => |x| semanticOrderContainer(allocator, x, b.array),
        .set => |x| semanticOrderContainer(allocator, x, b.set),
        .map => |x| semanticOrderContainer(allocator, x, b.map),
    };
}

fn semanticOrderContainer(allocator: Allocator, fa: []const u8, fb: []const u8) SemanticError!Order {
    const ia = try struple.unescapeAlloc(allocator, fa);
    defer allocator.free(ia);
    const ib = try struple.unescapeAlloc(allocator, fb);
    defer allocator.free(ib);
    return semanticOrder(allocator, ia, ib);
}

// ---------------------------------------------------------------------------
// Numbers
// ---------------------------------------------------------------------------

// Rank within the number class: -inf < finite < +inf < NaN.
fn numClass(e: Element) u8 {
    const f: f64 = switch (e) {
        .int, .big_int => return 1, // integers are always finite
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
