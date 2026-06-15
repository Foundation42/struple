//! Navigation / query over an encoded struple buffer.
//!
//! A buffer is a stream of elements; these helpers slice and inspect it without
//! decoding values. Everything is zero-copy — results are sub-slices of the
//! input, each itself a valid struple buffer, so it all composes and recurses.
//! Mirrors the reader surface of the original `Tuple.h` (head/tail/at/count/
//! contained-items + `is*` predicates + map helpers).
//!
//! Stream ops (`count`, `at`, `head`, `tail`, `nthRest`, `take`) operate on the
//! buffer's top-level element stream. To descend into an array/map/set, use
//! `containedItems` to get its inner stream, then view that.

const std = @import("std");
const struple = @import("struple.zig");

const Reader = struple.Reader;
const tc = struple.tc;
const DecodeError = struple.DecodeError;
const AllocError = std.mem.Allocator.Error;

pub fn view(bytes: []const u8) View {
    return View.init(bytes);
}

pub const View = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) View {
        return .{ .bytes = bytes };
    }

    pub fn reader(self: View) Reader {
        return Reader.init(self.bytes);
    }

    /// Number of top-level elements.
    pub fn count(self: View) DecodeError!usize {
        var r = self.reader();
        var n: usize = 0;
        while (try r.skip()) n += 1;
        return n;
    }

    /// The element at `index`, as a zero-copy sub-view (null if out of range).
    pub fn at(self: View, index: usize) DecodeError!?[]const u8 {
        var r = self.reader();
        var i: usize = 0;
        while (try r.nextView()) |v| : (i += 1) {
            if (i == index) return v;
        }
        return null;
    }

    /// The first element (null if empty).
    pub fn head(self: View) DecodeError!?[]const u8 {
        return self.at(0);
    }

    /// Everything after the first element (empty if 0 or 1 elements).
    pub fn tail(self: View) DecodeError![]const u8 {
        var r = self.reader();
        _ = try r.nextView();
        return r.rest();
    }

    /// Drop `n` elements; return the remaining stream.
    pub fn nthRest(self: View, n: usize) DecodeError![]const u8 {
        var r = self.reader();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (!(try r.skip())) break;
        }
        return r.rest();
    }

    /// The first `n` elements, as a contiguous sub-view.
    pub fn take(self: View, n: usize) DecodeError![]const u8 {
        var r = self.reader();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (!(try r.skip())) break;
        }
        return self.bytes[0 .. self.bytes.len - r.rest().len];
    }

    /// The type code of the first element (null if empty).
    pub fn headType(self: View) ?u8 {
        return if (self.bytes.len > 0) self.bytes[0] else null;
    }

    pub fn isNil(self: View) bool {
        return self.headType() == tc.nil;
    }
    pub fn isUndefined(self: View) bool {
        return self.headType() == tc.undef;
    }
    pub fn isBool(self: View) bool {
        const t = self.headType() orelse return false;
        return t == tc.bool_false or t == tc.bool_true;
    }
    pub fn isInt(self: View) bool {
        const t = self.headType() orelse return false;
        return t == tc.int_zero or t == tc.int_neg_big or t == tc.int_pos_big or
            (t >= tc.int_neg_min and t <= tc.int_neg_max) or
            (t >= tc.int_pos_min and t <= tc.int_pos_max);
    }
    pub fn isFloat(self: View) bool {
        const t = self.headType() orelse return false;
        return t == tc.float32 or t == tc.float64;
    }
    pub fn isNumber(self: View) bool {
        return self.isInt() or self.isFloat();
    }
    pub fn isTimestamp(self: View) bool {
        return self.headType() == tc.timestamp;
    }
    pub fn isUuid(self: View) bool {
        return self.headType() == tc.uuid;
    }
    pub fn isString(self: View) bool {
        return self.headType() == tc.string;
    }
    pub fn isBytes(self: View) bool {
        return self.headType() == tc.bytes;
    }
    pub fn isArray(self: View) bool {
        return self.headType() == tc.array;
    }
    pub fn isMap(self: View) bool {
        return self.headType() == tc.map;
    }
    pub fn isSet(self: View) bool {
        return self.headType() == tc.set;
    }
    pub fn isContainer(self: View) bool {
        const t = self.headType() orelse return false;
        return t == tc.array or t == tc.map or t == tc.set;
    }

    /// The first element's framed body when it is a container (escapes intact,
    /// zero-copy). Null if the head isn't a container.
    pub fn containerBody(self: View) DecodeError!?[]const u8 {
        if (!self.isContainer()) return null;
        var r = self.reader();
        const e = (try r.next()) orelse return null;
        return switch (e) {
            .array, .map, .set => |b| b,
            else => null,
        };
    }

    /// The container's inner element stream, un-escaped (owned by the caller).
    /// View it with `struple.view`, or a map with `struple.MapView`.
    pub fn containedItems(self: View, allocator: std.mem.Allocator) (DecodeError || AllocError)!?[]u8 {
        const body = (try self.containerBody()) orelse return null;
        return try struple.unescapeAlloc(allocator, body);
    }
};

/// Reads key/value pairs from a map's *inner* stream (the un-escaped body from
/// `View.containedItems`). Keys are in canonical (sorted) order, so `get`
/// early-exits.
pub const MapView = struct {
    inner: []const u8,

    pub fn init(inner: []const u8) MapView {
        return .{ .inner = inner };
    }

    pub fn count(self: MapView) DecodeError!usize {
        return (try View.init(self.inner).count()) / 2;
    }

    pub const Entry = struct { key: []const u8, value: []const u8 };

    pub const Iterator = struct {
        r: Reader,
        pub fn next(self: *Iterator) DecodeError!?Entry {
            const k = (try self.r.nextView()) orelse return null;
            const v = (try self.r.nextView()) orelse return error.Truncated;
            return Entry{ .key = k, .value = v };
        }
    };

    pub fn iterator(self: MapView) Iterator {
        return .{ .r = Reader.init(self.inner) };
    }

    /// Look up `key` (the encoded bytes of a key element, e.g. from packing a
    /// value). Returns the value's encoded bytes, or null. Ordered scan with
    /// early exit thanks to canonical key order.
    pub fn get(self: MapView, key: []const u8) DecodeError!?[]const u8 {
        var it = self.iterator();
        while (try it.next()) |e| {
            switch (std.mem.order(u8, e.key, key)) {
                .eq => return e.value,
                .gt => return null,
                .lt => {},
            }
        }
        return null;
    }
};
