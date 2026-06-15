//! struple — streaming, lexicographically-ordered tuple packing for Zig.
//!
//! A `struple` value is a stream of self-delimiting, typed elements packed into
//! a byte buffer. The encoding has one defining property:
//!
//!     std.mem.order(u8, pack(a), pack(b)) == the semantic order of a and b
//!
//! i.e. the raw encoded bytes are directly `memcmp`-comparable — drop two packed
//! tuples into any byte-ordered store (RocksDB, LMDB, sled, a sorted array) and
//! they sort correctly with no custom comparator. This is the FoundationDB tuple
//! idea, rebuilt clean in Zig.
//!
//! ## How ordering is achieved
//!
//! Every element starts with a one-byte *type code*. The type codes are assigned
//! so that `memcmp` of the type byte already gives the desired cross-type order:
//!
//!     nil < false < true < negative ints < zero < positive ints
//!         < float32 < float64 < string < bytes < tuple
//!
//! Within a type, the payload is encoded to preserve order under `memcmp`:
//!
//!   * Integers use a variable width carried by the type code (more magnitude ->
//!     more bytes -> a larger/smaller type code, so cross-width order is free).
//!     The payload is big-endian. Negatives are stored in *excess* form
//!     (`value + 2^(8n)`), which is the byte-complement of the magnitude — that
//!     is the one subtlety that makes `-256 < -100 < -1` come out right.
//!
//!   * Floats use the classic IEEE-754 total-ordering transform: flip the sign
//!     bit for positives, flip all bits for negatives, then store big-endian.
//!
//!   * Variable-length payloads (string, bytes, nested tuple) are terminated by
//!     `0x00`, with any real `0x00` byte escaped as `0x00 0xFF`. Because `0x00`
//!     is below every content byte, a shorter value (e.g. "app") sorts before a
//!     longer one that extends it ("apple"). This framing is also what makes the
//!     stream self-delimiting.
//!
//! Note: because type codes dominate, an integer and a float never interleave by
//! magnitude (`int 1000000` sorts below `float 0.5`). Comparing numbers across
//! representations is the job of a *semantic* comparator, which is intentionally
//! out of scope for v1.

const std = @import("std");

// ---------------------------------------------------------------------------
// Type codes
// ---------------------------------------------------------------------------

/// One-byte type tags. The numeric values are load-bearing: their order *is*
/// the cross-type sort order. Gaps are reserved for the future "tower" of types
/// (UUID, decimals, i128, maps, vectors, sets, ...).
pub const tc = struct {
    /// Terminator / escape sentinel for variable-length framing. Never a type.
    pub const terminator: u8 = 0x00;

    pub const nil: u8 = 0x01;
    pub const bool_false: u8 = 0x02;
    pub const bool_true: u8 = 0x03;

    // Integers. Width is carried by the distance from `int_zero`.
    //   0x10..0x1F  negative, widest (most negative) first
    //   0x20        zero
    //   0x21..0x30  positive
    // v1 emits 1..8 byte widths (i64/u64); the outer slots are reserved for i128.
    pub const int_neg_min: u8 = 0x10; // reserved widest negative (16 bytes)
    pub const int_neg_max: u8 = 0x1F; // 1-byte negative
    pub const int_zero: u8 = 0x20;
    pub const int_pos_min: u8 = 0x21; // 1-byte positive
    pub const int_pos_max: u8 = 0x30; // reserved widest positive (16 bytes)

    pub const float32: u8 = 0x31;
    pub const float64: u8 = 0x32;

    pub const string: u8 = 0x40;
    pub const bytes: u8 = 0x41;

    pub const tuple: u8 = 0x60;
};

/// Largest integer width (in bytes) struple v1 will encode/decode. Covers the
/// full range of i64 and u64. Wider slots are reserved for a future i128.
const max_int_bytes: usize = 8;

/// Companion byte written after a literal 0x00 inside variable-length payloads.
const escape: u8 = 0xFF;

pub const EncodeError = std.mem.Allocator.Error || error{IntegerTooLarge};
pub const DecodeError = error{ Truncated, InvalidType, UnsupportedType };

// ---------------------------------------------------------------------------
// Packer — builds an encoded tuple
// ---------------------------------------------------------------------------

/// Accumulates encoded elements into a growable buffer.
pub const Packer = struct {
    list: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Packer {
        return .{ .list = std.ArrayList(u8).init(allocator) };
    }

    pub fn deinit(self: *Packer) void {
        self.list.deinit();
    }

    /// Drop all elements but keep the allocated capacity.
    pub fn reset(self: *Packer) void {
        self.list.clearRetainingCapacity();
    }

    /// The encoded bytes. Valid until the next mutating call. memcmp-comparable.
    pub fn bytes(self: *const Packer) []const u8 {
        return self.list.items;
    }

    /// Hand ownership of the encoded bytes to the caller.
    pub fn toOwnedSlice(self: *Packer) std.mem.Allocator.Error![]u8 {
        return self.list.toOwnedSlice();
    }

    pub fn appendNil(self: *Packer) EncodeError!void {
        try self.list.append(tc.nil);
    }

    pub fn appendBool(self: *Packer, value: bool) EncodeError!void {
        try self.list.append(if (value) tc.bool_true else tc.bool_false);
    }

    pub fn appendInt(self: *Packer, value: i64) EncodeError!void {
        // Promote to i128 first so that negating i64's minimum is safe.
        try encodeInteger(&self.list, @as(i128, value));
    }

    pub fn appendUint(self: *Packer, value: u64) EncodeError!void {
        if (value == 0) {
            try self.list.append(tc.int_zero);
        } else {
            try encodePositive(&self.list, @as(u128, value));
        }
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

    pub fn appendString(self: *Packer, value: []const u8) EncodeError!void {
        try writeFramed(&self.list, tc.string, value);
    }

    pub fn appendBytes(self: *Packer, value: []const u8) EncodeError!void {
        try writeFramed(&self.list, tc.bytes, value);
    }

    /// Append a nested tuple. `child` is the already-encoded bytes of another
    /// tuple (e.g. `other_packer.bytes()`).
    pub fn appendTuple(self: *Packer, child: []const u8) EncodeError!void {
        try writeFramed(&self.list, tc.tuple, child);
    }

    /// Convenience: dispatch on the Zig type of `value` at comptime.
    pub fn append(self: *Packer, value: anytype) EncodeError!void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .bool => try self.appendBool(value),
            .int => |info| if (info.signedness == .signed)
                try self.appendInt(@intCast(value))
            else
                try self.appendUint(@intCast(value)),
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

pub const Kind = enum { nil, boolean, int, float32, float64, string, bytes, tuple };

/// A decoded element. For `string`/`bytes`/`tuple` the slice points into the
/// source buffer and is the *framed* payload (literal `0x00` bytes still appear
/// as `0x00 0xFF`). When the slice contains no `0x00` it is already the literal
/// content (the common case); otherwise call `unescapeAlloc` / `unescapeInto`.
/// For a nested `tuple`, un-escape the slice (if needed) then feed it to a new
/// `Reader`.
pub const Element = union(Kind) {
    nil,
    boolean: bool,
    int: i128,
    float32: f32,
    float64: f64,
    string: []const u8,
    bytes: []const u8,
    tuple: []const u8,
};

/// A forward, zero-allocation cursor over an encoded tuple.
pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn done(self: *const Reader) bool {
        return self.pos >= self.buf.len;
    }

    /// Returns the next element, or null at end of stream.
    pub fn next(self: *Reader) DecodeError!?Element {
        if (self.pos >= self.buf.len) return null;
        const type_code = self.buf[self.pos];
        self.pos += 1;

        switch (type_code) {
            tc.nil => return .nil,
            tc.bool_false => return .{ .boolean = false },
            tc.bool_true => return .{ .boolean = true },
            tc.int_zero => return .{ .int = 0 },
            0x10...0x1f, 0x21...0x30 => {
                const n: usize = if (type_code < tc.int_zero)
                    tc.int_zero - type_code
                else
                    type_code - tc.int_zero;
                if (n > max_int_bytes) return error.UnsupportedType;
                const payload = try self.take(n);
                return .{ .int = decodeIntPayload(type_code, payload) };
            },
            tc.float32 => {
                const p = try self.take(4);
                return .{ .float32 = decodeF32(p[0..4]) };
            },
            tc.float64 => {
                const p = try self.take(8);
                return .{ .float64 = decodeF64(p[0..8]) };
            },
            tc.string => return .{ .string = try self.takeFramed() },
            tc.bytes => return .{ .bytes = try self.takeFramed() },
            tc.tuple => return .{ .tuple = try self.takeFramed() },
            else => return error.InvalidType,
        }
    }

    fn take(self: *Reader, n: usize) DecodeError![]const u8 {
        if (self.pos + n > self.buf.len) return error.Truncated;
        const slice = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    /// Scans to the framing terminator (`0x00` not followed by `0xFF`), returns
    /// the framed payload (escapes intact), and advances past the terminator.
    fn takeFramed(self: *Reader) DecodeError![]const u8 {
        const start = self.pos;
        var i = self.pos;
        while (i < self.buf.len) {
            if (self.buf[i] == 0x00) {
                if (i + 1 < self.buf.len and self.buf[i + 1] == escape) {
                    i += 2; // escaped literal 0x00
                    continue;
                }
                self.pos = i + 1; // consume terminator
                return self.buf[start..i];
            }
            i += 1;
        }
        return error.Truncated; // ran off the end without a terminator
    }
};

pub fn reader(buf: []const u8) Reader {
    return Reader.init(buf);
}

// ---------------------------------------------------------------------------
// Ordering helpers (documentation-as-code: ordering IS memcmp)
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

/// True if `framed` contains escaped bytes (i.e. needs un-escaping). When false,
/// the framed slice already equals the literal content.
pub fn hasEscapes(framed: []const u8) bool {
    return std.mem.indexOfScalar(u8, framed, 0x00) != null;
}

/// Number of literal bytes a framed payload decodes to.
pub fn unescapedLen(framed: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < framed.len) : (i += 1) {
        n += 1;
        if (framed[i] == 0x00) i += 1; // skip the 0xFF companion
    }
    return n;
}

/// Un-escape `framed` into `out` (which must be at least `unescapedLen` long).
pub fn unescapeInto(framed: []const u8, out: []u8) []u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < framed.len) : (i += 1) {
        out[w] = framed[i];
        w += 1;
        if (framed[i] == 0x00) i += 1; // skip the 0xFF companion
    }
    return out[0..w];
}

/// Allocate and return the literal content of a framed payload.
pub fn unescapeAlloc(allocator: std.mem.Allocator, framed: []const u8) std.mem.Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, unescapedLen(framed));
    return unescapeInto(framed, out);
}

// ---------------------------------------------------------------------------
// Integer encode/decode
// ---------------------------------------------------------------------------

fn encodeInteger(list: *std.ArrayList(u8), value: i128) EncodeError!void {
    if (value == 0) {
        try list.append(tc.int_zero);
    } else if (value > 0) {
        try encodePositive(list, @intCast(value));
    } else {
        try encodeNegative(list, @intCast(-value));
    }
}

/// Encode a positive magnitude (>= 1) as big-endian over the minimal width.
fn encodePositive(list: *std.ArrayList(u8), magnitude: u128) EncodeError!void {
    const n = byteLen(magnitude);
    if (n > max_int_bytes) return error.IntegerTooLarge;
    try list.append(tc.int_zero + @as(u8, @intCast(n)));
    try writeBigEndian(list, magnitude, n);
}

/// Encode a negative value whose magnitude is `magnitude` (>= 1). The payload is
/// `value + 2^(8n)` (excess form) — equivalently the n-byte complement of
/// `magnitude - 1` — so that more-negative values produce smaller bytes.
fn encodeNegative(list: *std.ArrayList(u8), magnitude: u128) EncodeError!void {
    const pos_val = magnitude - 1;
    var n = byteLen(pos_val);
    if (n == 0) n = 1; // value == -1 -> pos_val 0, still needs one byte
    if (n > max_int_bytes) return error.IntegerTooLarge;
    try list.append(tc.int_zero - @as(u8, @intCast(n)));
    const span: u128 = @as(u128, 1) << @intCast(n * 8);
    try writeBigEndian(list, span - magnitude, n);
}

fn decodeIntPayload(type_code: u8, payload: []const u8) i128 {
    const raw = readBigEndian(payload);
    if (type_code > tc.int_zero) {
        return @intCast(raw); // positive
    }
    // negative: value = raw - 2^(8n)
    const span: u128 = @as(u128, 1) << @intCast(payload.len * 8);
    return @as(i128, @intCast(raw)) - @as(i128, @intCast(span));
}

/// Bytes needed to represent `x` (0 for zero).
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
        bits = 0x7fc00000; // canonical positive qNaN
    } else {
        var v = value;
        if (v == 0) v = 0; // squash -0.0 to +0.0
        bits = @bitCast(v);
    }
    // Positive (sign 0): set the high bit. Negative: flip everything.
    return if (bits & 0x80000000 != 0) ~bits else bits ^ 0x80000000;
}

fn orderableF64Bits(value: f64) u64 {
    var bits: u64 = undefined;
    if (std.math.isNan(value)) {
        bits = 0x7ff8000000000000; // canonical positive qNaN
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

fn writeFramed(list: *std.ArrayList(u8), type_code: u8, content: []const u8) EncodeError!void {
    try list.append(type_code);
    for (content) |b| {
        try list.append(b);
        if (b == 0x00) try list.append(escape); // 0x00 -> 0x00 0xFF
    }
    try list.append(tc.terminator);
}

test {
    // Pull the full test suite into `zig build test`.
    _ = @import("tests.zig");
}
