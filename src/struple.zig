//! struple — streaming, lexicographically-ordered tuple packing for Zig.
//!
//! A `struple` value is a stream of self-delimiting, typed elements packed into
//! a byte buffer. The defining property:
//!
//!     std.mem.order(u8, pack(a), pack(b)) == the semantic order of a and b
//!
//! i.e. the raw encoded bytes are directly `memcmp`-comparable — drop two packed
//! tuples into any byte-ordered store and they sort correctly with no custom
//! comparator. This is the FoundationDB tuple idea, rebuilt clean in Zig.
//!
//! v2 covers the union of the Python and JavaScript data models: null,
//! undefined, bool, arbitrary-precision integers, float32/64, (decimal —
//! reserved), timestamp, string, bytes, array, map and set.
//!
//! ## How ordering is achieved
//!
//! Every element starts with a one-byte *type code*, assigned so that `memcmp`
//! of the type byte alone gives the cross-type order:
//!
//!     null < undefined < false < true
//!         < negative ints < zero < positive ints
//!         < float32 < float64 < decimal < timestamp
//!         < string < bytes < array < map < set
//!
//! Within a type the payload preserves order under `memcmp`:
//!
//!   * Integers carry their width in the type code (more magnitude -> a
//!     larger/smaller code, so cross-width order is free). Fixed payloads are
//!     big-endian; negatives use excess form (`value + 2^(8n)`). Values beyond
//!     8 bytes use the bracketing big-int codes with an order-preserving,
//!     self-delimiting `[m][n][magnitude]` length-prefix (effectively unbounded).
//!   * Floats use the IEEE-754 total-ordering transform.
//!   * Timestamps are an order-preserving signed i64 (microseconds since the
//!     Unix epoch, UTC).
//!   * Variable-length payloads (string, bytes, array, map, set) are `0x00`
//!     terminated, with real `0x00` escaped as `0x00 0xFF`, so a shorter value
//!     sorts before a longer one that extends it ("app" < "apple").
//!   * Maps and sets are stored in *canonical* order (entries/elements sorted by
//!     their encoded bytes), so equal maps/sets encode identically and compare
//!     correctly. (Insertion order is therefore not preserved — use an array of
//!     pairs if you need that.)
//!
//! Type codes dominate `memcmp`, so an integer and a float never interleave by
//! magnitude. Comparing numbers across representations is the job of a *semantic*
//! comparator, intentionally out of scope here.

const std = @import("std");

// ---------------------------------------------------------------------------
// Type codes
// ---------------------------------------------------------------------------

/// One-byte type tags. The numeric values are load-bearing: their order *is* the
/// cross-type sort order. Gaps are reserved for the future tower (UUID, float128,
/// date/time-only, intervals, ...).
pub const tc = struct {
    /// Terminator / escape sentinel for variable-length framing. Never a type.
    pub const terminator: u8 = 0x00;

    pub const nil: u8 = 0x01; // null (Python None / JS null)
    pub const undef: u8 = 0x02; // JS undefined

    pub const bool_false: u8 = 0x05;
    pub const bool_true: u8 = 0x06;

    // Integers.
    pub const int_neg_big: u8 = 0x0F; // arbitrary-precision negative
    pub const int_neg_min: u8 = 0x10; // widest fixed negative (reserved up to 16 bytes)
    pub const int_neg_max: u8 = 0x1F; // 1-byte fixed negative
    pub const int_zero: u8 = 0x20;
    pub const int_pos_min: u8 = 0x21; // 1-byte fixed positive
    pub const int_pos_max: u8 = 0x30; // widest fixed positive (reserved up to 16 bytes)
    pub const int_pos_big: u8 = 0x31; // arbitrary-precision positive

    pub const float32: u8 = 0x34;
    pub const float64: u8 = 0x35;

    pub const decimal: u8 = 0x38; // RESERVED — not yet implemented

    pub const timestamp: u8 = 0x40;

    pub const string: u8 = 0x48;
    pub const bytes: u8 = 0x49;

    pub const array: u8 = 0x50;
    pub const map: u8 = 0x52;
    pub const set: u8 = 0x54;
};

/// Largest integer width (in bytes) the *fixed* path uses. Values whose
/// magnitude needs more than this many bytes use the big-int codes. 8 covers all
/// of i64/u64; the 9–16 byte fixed slots stay reserved for a later optimization.
const max_int_bytes: usize = 8;

/// Companion byte written after a literal 0x00 inside variable-length payloads.
const escape_byte: u8 = 0xFF;

pub const EncodeError = std.mem.Allocator.Error;
pub const DecodeError = error{ Truncated, InvalidType, UnsupportedType };

// ---------------------------------------------------------------------------
// Decoded element view
// ---------------------------------------------------------------------------

pub const Kind = enum {
    nil,
    undef,
    boolean,
    int,
    big_int,
    float32,
    float64,
    timestamp,
    string,
    bytes,
    array,
    map,
    set,
};

/// A decoded element. For `string`/`bytes`/`array`/`map`/`set` the slice points
/// into the source buffer and is the *framed* payload (literal `0x00` still
/// appears as `0x00 0xFF`); when it contains no `0x00` it is already the literal
/// content. Use `unescapeAlloc`/`unescapeInto`, then a child `Reader` for
/// containers.
pub const Element = union(Kind) {
    nil,
    undef,
    boolean: bool,
    int: i128, // fixed-width integers (|value| fits 8 bytes)
    big_int: BigInt, // arbitrary-precision integers
    float32: f32,
    float64: f64,
    timestamp: i64, // microseconds since the Unix epoch, UTC
    string: []const u8,
    bytes: []const u8,
    array: []const u8,
    map: []const u8,
    set: []const u8,
};

/// View of an arbitrary-precision integer that did not fit the fixed path.
pub const BigInt = struct {
    negative: bool,
    /// Big-endian magnitude bytes *as stored* — complemented iff `negative`.
    mag_stored: []const u8,

    /// Materialize the normalized big-endian magnitude (un-complemented).
    pub fn magnitudeAlloc(self: BigInt, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        const out = try allocator.alloc(u8, self.mag_stored.len);
        for (self.mag_stored, out) |b, *o| o.* = if (self.negative) ~b else b;
        return out;
    }

    /// The value as an i128 if it fits, else null.
    pub fn toI128(self: BigInt) ?i128 {
        if (self.mag_stored.len > 16) return null;
        var mag: u128 = 0;
        for (self.mag_stored) |b| mag = (mag << 8) | (if (self.negative) ~b else b);
        if (self.negative) {
            const i128_min_mag: u128 = @as(u128, 1) << 127;
            if (mag == i128_min_mag) return std.math.minInt(i128);
            if (mag > i128_min_mag) return null;
            return -@as(i128, @intCast(mag));
        }
        if (mag > std.math.maxInt(i128)) return null;
        return @intCast(mag);
    }
};

// ---------------------------------------------------------------------------
// Packer — builds an encoded tuple
// ---------------------------------------------------------------------------

pub const Packer = struct {
    list: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Packer {
        return .{ .list = std.ArrayList(u8).init(allocator) };
    }

    pub fn deinit(self: *Packer) void {
        self.list.deinit();
    }

    pub fn reset(self: *Packer) void {
        self.list.clearRetainingCapacity();
    }

    /// The encoded bytes. Valid until the next mutating call. memcmp-comparable.
    pub fn bytes(self: *const Packer) []const u8 {
        return self.list.items;
    }

    pub fn toOwnedSlice(self: *Packer) std.mem.Allocator.Error![]u8 {
        return self.list.toOwnedSlice();
    }

    pub fn appendNil(self: *Packer) EncodeError!void {
        try self.list.append(tc.nil);
    }

    pub fn appendUndefined(self: *Packer) EncodeError!void {
        try self.list.append(tc.undef);
    }

    pub fn appendBool(self: *Packer, value: bool) EncodeError!void {
        try self.list.append(if (value) tc.bool_true else tc.bool_false);
    }

    pub fn appendInt(self: *Packer, value: i64) EncodeError!void {
        try encodeFixedInt(&self.list, @as(i128, value));
    }

    pub fn appendUint(self: *Packer, value: u64) EncodeError!void {
        if (value == 0) try self.list.append(tc.int_zero) else try encodePositive(&self.list, value);
    }

    /// Encode any i128, automatically using the big-int path past 8 bytes.
    pub fn appendI128(self: *Packer, value: i128) EncodeError!void {
        if (value == 0) {
            try self.list.append(tc.int_zero);
            return;
        }
        const negative = value < 0;
        const bits: u128 = @bitCast(value);
        const mag: u128 = if (negative) (~bits +% 1) else bits; // two's-complement magnitude
        var buf: [16]u8 = undefined;
        std.mem.writeInt(u128, &buf, mag, .big);
        var start: usize = 0;
        while (start < 16 and buf[start] == 0) start += 1;
        try self.appendBigInt(negative, buf[start..]);
    }

    /// Encode an arbitrary-precision integer given its sign and big-endian
    /// magnitude bytes (leading zeros are trimmed). Routes through the fixed path
    /// when the magnitude fits in 8 bytes.
    pub fn appendBigInt(self: *Packer, negative: bool, magnitude_be: []const u8) EncodeError!void {
        var mag = magnitude_be;
        while (mag.len > 0 and mag[0] == 0) mag = mag[1..];
        if (mag.len == 0) {
            try self.list.append(tc.int_zero);
            return;
        }
        if (mag.len <= max_int_bytes) {
            const value = readBigEndian(mag);
            if (negative) try encodeNegative(&self.list, value) else try encodePositive(&self.list, value);
            return;
        }
        try self.list.append(if (negative) tc.int_neg_big else tc.int_pos_big);
        try writeBigIntFields(&self.list, mag, negative);
    }

    pub fn appendF32(self: *Packer, value: f32) EncodeError!void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, orderableF32Bits(value), .big);
        try self.list.append(tc.float32);
        try self.list.appendSlice(&buf);
    }

    pub fn appendF64(self: *Packer, value: f64) EncodeError!void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, orderableF64Bits(value), .big);
        try self.list.append(tc.float64);
        try self.list.appendSlice(&buf);
    }

    /// Microseconds since the Unix epoch, UTC.
    pub fn appendTimestamp(self: *Packer, micros: i64) EncodeError!void {
        var buf: [8]u8 = undefined;
        // Flip the sign bit so two's-complement order matches unsigned byte order.
        std.mem.writeInt(u64, &buf, @as(u64, @bitCast(micros)) ^ (@as(u64, 1) << 63), .big);
        try self.list.append(tc.timestamp);
        try self.list.appendSlice(&buf);
    }

    pub fn appendString(self: *Packer, value: []const u8) EncodeError!void {
        try writeFramed(&self.list, tc.string, value);
    }

    pub fn appendBytes(self: *Packer, value: []const u8) EncodeError!void {
        try writeFramed(&self.list, tc.bytes, value);
    }

    /// Append a nested array. `child` is the encoded element stream of another
    /// tuple (e.g. `other_packer.bytes()`).
    pub fn appendArray(self: *Packer, child: []const u8) EncodeError!void {
        try writeFramed(&self.list, tc.array, child);
    }

    /// Append a map. `entries` is a list of `[key_encoding, value_encoding]`
    /// pairs; they are sorted by key into canonical order. (Duplicate keys are
    /// the caller's responsibility.)
    pub fn appendMap(self: *Packer, entries: []const [2][]const u8) EncodeError!void {
        const allocator = self.list.allocator;
        const idx = try allocator.alloc(usize, entries.len);
        defer allocator.free(idx);
        for (idx, 0..) |*x, i| x.* = i;
        std.mem.sort(usize, idx, entries, lessByKey);

        try self.list.append(tc.map);
        for (idx) |i| {
            try writeEscaped(&self.list, entries[i][0]);
            try writeEscaped(&self.list, entries[i][1]);
        }
        try self.list.append(tc.terminator);
    }

    /// Append a set. `elements` (each an element encoding) are sorted and
    /// de-duplicated into canonical order.
    pub fn appendSet(self: *Packer, elements: []const []const u8) EncodeError!void {
        const allocator = self.list.allocator;
        const idx = try allocator.alloc(usize, elements.len);
        defer allocator.free(idx);
        for (idx, 0..) |*x, i| x.* = i;
        std.mem.sort(usize, idx, elements, lessBySlice);

        try self.list.append(tc.set);
        var prev: ?[]const u8 = null;
        for (idx) |i| {
            const e = elements[i];
            if (prev) |p| if (std.mem.eql(u8, p, e)) continue; // skip duplicate
            try writeEscaped(&self.list, e);
            prev = e;
        }
        try self.list.append(tc.terminator);
    }

    /// Convenience: dispatch on the Zig type of `value` at comptime.
    pub fn append(self: *Packer, value: anytype) EncodeError!void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .bool => try self.appendBool(value),
            .int => |info| if (info.bits <= 64)
                (if (info.signedness == .signed)
                    try self.appendInt(@intCast(value))
                else
                    try self.appendUint(@intCast(value)))
            else
                try self.appendI128(@intCast(value)),
            .comptime_int => if (value < 0)
                try self.appendInt(value)
            else
                try self.appendUint(value),
            .float => if (T == f32)
                try self.appendF32(value)
            else
                try self.appendF64(@floatCast(value)),
            .comptime_float => try self.appendF64(value),
            .null => try self.appendNil(),
            .optional => if (value) |v| try self.append(v) else try self.appendNil(),
            else => if (comptime isStringLike(T))
                try self.appendString(value)
            else
                @compileError("struple: cannot append value of type " ++ @typeName(T)),
        }
    }
};

fn lessByKey(entries: []const [2][]const u8, l: usize, r: usize) bool {
    return std.mem.lessThan(u8, entries[l][0], entries[r][0]);
}

fn lessBySlice(elements: []const []const u8, l: usize, r: usize) bool {
    return std.mem.lessThan(u8, elements[l], elements[r]);
}

fn isStringLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        .array => |a| a.child == u8,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Reader — streams elements back out (zero-allocation)
// ---------------------------------------------------------------------------

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn done(self: *const Reader) bool {
        return self.pos >= self.buf.len;
    }

    pub fn next(self: *Reader) DecodeError!?Element {
        if (self.pos >= self.buf.len) return null;
        const type_code = self.buf[self.pos];
        self.pos += 1;

        switch (type_code) {
            tc.nil => return .nil,
            tc.undef => return .undef,
            tc.bool_false => return .{ .boolean = false },
            tc.bool_true => return .{ .boolean = true },
            tc.int_zero => return .{ .int = 0 },
            0x10...0x1f, 0x21...0x30 => {
                const n: usize = if (type_code < tc.int_zero)
                    tc.int_zero - type_code
                else
                    type_code - tc.int_zero;
                if (n > max_int_bytes) return error.UnsupportedType; // reserved 9–16 byte slots
                const payload = try self.take(n);
                return .{ .int = decodeIntPayload(type_code, payload) };
            },
            tc.int_neg_big, tc.int_pos_big => {
                const negative = type_code == tc.int_neg_big;
                const m: usize = decodeByte((try self.take(1))[0], negative);
                var n: usize = 0;
                for (try self.take(m)) |b| n = (n << 8) | decodeByte(b, negative);
                const mag = try self.take(n);
                return .{ .big_int = .{ .negative = negative, .mag_stored = mag } };
            },
            tc.float32 => return .{ .float32 = decodeF32((try self.take(4))[0..4]) },
            tc.float64 => return .{ .float64 = decodeF64((try self.take(8))[0..8]) },
            tc.timestamp => {
                const raw = std.mem.readInt(u64, (try self.take(8))[0..8], .big);
                return .{ .timestamp = @bitCast(raw ^ (@as(u64, 1) << 63)) };
            },
            tc.string => return .{ .string = try self.takeFramed() },
            tc.bytes => return .{ .bytes = try self.takeFramed() },
            tc.array => return .{ .array = try self.takeFramed() },
            tc.map => return .{ .map = try self.takeFramed() },
            tc.set => return .{ .set = try self.takeFramed() },
            else => return error.InvalidType,
        }
    }

    /// The type code of the next element without consuming it (null at end).
    pub fn peekType(self: *const Reader) ?u8 {
        return if (self.pos < self.buf.len) self.buf[self.pos] else null;
    }

    /// The remaining unread bytes, as a slice (a valid struple stream).
    pub fn rest(self: *const Reader) []const u8 {
        return self.buf[self.pos..];
    }

    /// The next element's raw bytes (a zero-copy view, itself a valid one-element
    /// struple buffer), advancing the cursor. Null at end of stream.
    pub fn nextView(self: *Reader) DecodeError!?[]const u8 {
        const start = self.pos;
        if ((try self.next()) == null) return null;
        return self.buf[start..self.pos];
    }

    /// Advance past the next element; returns false at end of stream.
    pub fn skip(self: *Reader) DecodeError!bool {
        return (try self.nextView()) != null;
    }

    fn take(self: *Reader, n: usize) DecodeError![]const u8 {
        if (self.pos + n > self.buf.len) return error.Truncated;
        const slice = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    fn takeFramed(self: *Reader) DecodeError![]const u8 {
        const start = self.pos;
        var i = self.pos;
        while (i < self.buf.len) {
            if (self.buf[i] == 0x00) {
                if (i + 1 < self.buf.len and self.buf[i + 1] == escape_byte) {
                    i += 2; // escaped literal 0x00
                    continue;
                }
                self.pos = i + 1; // consume terminator
                return self.buf[start..i];
            }
            i += 1;
        }
        return error.Truncated;
    }
};

pub fn reader(buf: []const u8) Reader {
    return Reader.init(buf);
}

inline fn decodeByte(b: u8, complemented: bool) u8 {
    return if (complemented) ~b else b;
}

// ---------------------------------------------------------------------------
// Ordering helpers (ordering IS memcmp)
// ---------------------------------------------------------------------------

pub fn order(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ---------------------------------------------------------------------------
// Escaping helpers for variable-length payloads
// ---------------------------------------------------------------------------

pub fn hasEscapes(framed: []const u8) bool {
    return std.mem.indexOfScalar(u8, framed, 0x00) != null;
}

pub fn unescapedLen(framed: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < framed.len) : (i += 1) {
        n += 1;
        if (framed[i] == 0x00) i += 1;
    }
    return n;
}

pub fn unescapeInto(framed: []const u8, out: []u8) []u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < framed.len) : (i += 1) {
        out[w] = framed[i];
        w += 1;
        if (framed[i] == 0x00) i += 1;
    }
    return out[0..w];
}

pub fn unescapeAlloc(allocator: std.mem.Allocator, framed: []const u8) std.mem.Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, unescapedLen(framed));
    return unescapeInto(framed, out);
}

// ---------------------------------------------------------------------------
// Integer encode/decode
// ---------------------------------------------------------------------------

fn encodeFixedInt(list: *std.ArrayList(u8), value: i128) EncodeError!void {
    if (value == 0) {
        try list.append(tc.int_zero);
    } else if (value > 0) {
        try encodePositive(list, @intCast(value));
    } else {
        try encodeNegative(list, @intCast(-value));
    }
}

fn encodePositive(list: *std.ArrayList(u8), magnitude: u128) EncodeError!void {
    const n = byteLen(magnitude);
    try list.append(tc.int_zero + @as(u8, @intCast(n)));
    try writeBigEndian(list, magnitude, n);
}

fn encodeNegative(list: *std.ArrayList(u8), magnitude: u128) EncodeError!void {
    const pos_val = magnitude - 1;
    var n = byteLen(pos_val);
    if (n == 0) n = 1;
    try list.append(tc.int_zero - @as(u8, @intCast(n)));
    const span: u128 = @as(u128, 1) << @intCast(n * 8);
    try writeBigEndian(list, span - magnitude, n);
}

fn decodeIntPayload(type_code: u8, payload: []const u8) i128 {
    const raw = readBigEndian(payload);
    if (type_code > tc.int_zero) return @intCast(raw);
    const span: u128 = @as(u128, 1) << @intCast(payload.len * 8);
    return @as(i128, @intCast(raw)) - @as(i128, @intCast(span));
}

/// Write `[m][n][magnitude]` for an arbitrary-precision integer, where `n` is the
/// magnitude byte count and `m` the byte count of `n`. Complement every byte for
/// negatives so larger magnitudes sort earlier.
fn writeBigIntFields(list: *std.ArrayList(u8), mag: []const u8, complement: bool) EncodeError!void {
    const n = mag.len;
    const m = byteLen(n);
    try list.append(if (complement) ~@as(u8, @intCast(m)) else @as(u8, @intCast(m)));
    var i: usize = m;
    while (i > 0) {
        i -= 1;
        const b: u8 = @truncate(n >> @intCast(i * 8));
        try list.append(if (complement) ~b else b);
    }
    for (mag) |b| try list.append(if (complement) ~b else b);
}

fn byteLen(x: u128) usize {
    if (x == 0) return 0;
    const bits: usize = 128 - @clz(x);
    return (bits + 7) / 8;
}

fn writeBigEndian(list: *std.ArrayList(u8), value: u128, n: usize) EncodeError!void {
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        try list.append(@truncate(value >> @intCast(i * 8)));
    }
}

fn readBigEndian(payload: []const u8) u128 {
    var v: u128 = 0;
    for (payload) |b| v = (v << 8) | b;
    return v;
}

// ---------------------------------------------------------------------------
// Float encode/decode (IEEE-754 total ordering)
// ---------------------------------------------------------------------------

fn orderableF32Bits(value: f32) u32 {
    var bits: u32 = undefined;
    if (std.math.isNan(value)) {
        bits = 0x7fc00000;
    } else {
        var v = value;
        if (v == 0) v = 0; // squash -0.0
        bits = @bitCast(v);
    }
    return if (bits & 0x80000000 != 0) ~bits else bits ^ 0x80000000;
}

fn orderableF64Bits(value: f64) u64 {
    var bits: u64 = undefined;
    if (std.math.isNan(value)) {
        bits = 0x7ff8000000000000;
    } else {
        var v = value;
        if (v == 0) v = 0;
        bits = @bitCast(v);
    }
    return if (bits & 0x8000000000000000 != 0) ~bits else bits ^ 0x8000000000000000;
}

fn decodeF32(p: *const [4]u8) f32 {
    var bits = std.mem.readInt(u32, p, .big);
    bits = if (bits & 0x80000000 != 0) bits ^ 0x80000000 else ~bits;
    return @bitCast(bits);
}

fn decodeF64(p: *const [8]u8) f64 {
    var bits = std.mem.readInt(u64, p, .big);
    bits = if (bits & 0x8000000000000000 != 0) bits ^ 0x8000000000000000 else ~bits;
    return @bitCast(bits);
}

// ---------------------------------------------------------------------------
// Variable-length framing
// ---------------------------------------------------------------------------

/// Append `content` with `0x00 -> 0x00 0xFF` escaping (no type code, no terminator).
fn writeEscaped(list: *std.ArrayList(u8), content: []const u8) EncodeError!void {
    for (content) |b| {
        try list.append(b);
        if (b == 0x00) try list.append(escape_byte);
    }
}

fn writeFramed(list: *std.ArrayList(u8), type_code: u8, content: []const u8) EncodeError!void {
    try list.append(type_code);
    try writeEscaped(list, content);
    try list.append(tc.terminator);
}

// ---------------------------------------------------------------------------
// JSON convenience (see json.zig)
// ---------------------------------------------------------------------------

pub const fromJson = @import("json.zig").fromJson;
pub const toJson = @import("json.zig").toJson;

// ---------------------------------------------------------------------------
// Navigation / query (see navigate.zig)
// ---------------------------------------------------------------------------

pub const View = @import("navigate.zig").View;
pub const MapView = @import("navigate.zig").MapView;
pub const view = @import("navigate.zig").view;

test {
    _ = @import("tests.zig");
}
