//! JSON <-> struple conversion.
//!
//!   fromJson: JSON text  -> struple encoding (one element for the root value)
//!   toJson:   struple bytes -> JSON text (renders the first element)
//!
//! JSON type mapping:
//!   null              <-> nil
//!   true / false      <-> bool
//!   integer number    <-> integer (arbitrary precision — big JSON ints are
//!                          kept losslessly, unlike a JS f64 round-trip)
//!   fractional number <-> float64
//!   string            <-> string
//!   array             <-> array
//!   object            <-> map  (canonical: keys come back sorted)
//!
//! struple types with no JSON equivalent degrade on `toJson`: undefined -> null,
//! timestamp -> number (µs), bytes -> base64 string, set -> array.

const std = @import("std");
const struple = @import("struple.zig");

/// Parse JSON text and return its struple encoding (caller owns the bytes).
pub fn fromJson(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});

    var out = struple.Packer.init(allocator);
    errdefer out.deinit();
    try encodeValue(arena, &out, root);
    return out.toOwnedSlice();
}

/// Render a struple encoding's first element as JSON text (caller owns it).
pub fn toJson(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var r = struple.reader(encoded);
    if (try r.next()) |elem| {
        try writeValue(arena, out.writer(), elem);
    } else {
        try out.appendSlice("null");
    }
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// JSON -> struple
// ---------------------------------------------------------------------------

fn encodeValue(arena: std.mem.Allocator, out: *struple.Packer, value: std.json.Value) !void {
    switch (value) {
        .null => try out.appendNil(),
        .bool => |b| try out.appendBool(b),
        .integer => |i| try out.appendInt(i),
        .float => |f| try out.appendF64(f),
        .number_string => |s| try encodeNumberString(arena, out, s),
        .string => |s| try out.appendString(s),
        .array => |arr| {
            var child = struple.Packer.init(arena);
            for (arr.items) |item| try encodeValue(arena, &child, item);
            try out.appendArray(child.bytes());
        },
        .object => |obj| {
            var entries = std.ArrayList([2][]const u8).init(arena);
            var it = obj.iterator();
            while (it.next()) |kv| {
                var kp = struple.Packer.init(arena);
                try kp.appendString(kv.key_ptr.*);
                var vp = struple.Packer.init(arena);
                try encodeValue(arena, &vp, kv.value_ptr.*);
                try entries.append(.{ kp.bytes(), vp.bytes() });
            }
            try out.appendMap(entries.items);
        },
    }
}

fn encodeNumberString(arena: std.mem.Allocator, out: *struple.Packer, s: []const u8) !void {
    // A fractional/exponent number is a float; otherwise an arbitrary-precision int.
    if (std.mem.indexOfAny(u8, s, ".eE") != null) {
        try out.appendF64(try std.fmt.parseFloat(f64, s));
        return;
    }
    var digits = s;
    var negative = false;
    if (digits.len > 0 and (digits[0] == '-' or digits[0] == '+')) {
        negative = digits[0] == '-';
        digits = digits[1..];
    }
    const mag = try decimalToMagnitude(arena, digits);
    try out.appendBigInt(negative, mag);
}

// ---------------------------------------------------------------------------
// struple -> JSON
// ---------------------------------------------------------------------------

fn writeValue(arena: std.mem.Allocator, writer: anytype, elem: struple.Element) anyerror!void {
    switch (elem) {
        .nil, .undef => try writer.writeAll("null"),
        .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
        .int => |i| try writer.print("{d}", .{i}),
        .big_int => |bi| try writeBigInt(arena, writer, bi),
        .float32 => |f| try writeFloat(writer, f),
        .float64 => |f| try writeFloat(writer, f),
        .timestamp => |t| try writer.print("{d}", .{t}),
        .string => |framed| try writeJsonString(arena, writer, framed),
        .bytes => |framed| try writeBase64(arena, writer, framed),
        .array, .set => |framed| try writeArray(arena, writer, framed),
        .map => |framed| try writeMap(arena, writer, framed),
    }
}

fn writeFloat(writer: anytype, f: anytype) !void {
    if (!std.math.isFinite(f)) {
        try writer.writeAll("null"); // JSON has no inf/nan (matches JSON.stringify)
        return;
    }
    try writer.print("{d}", .{f});
}

fn writeArray(arena: std.mem.Allocator, writer: anytype, framed: []const u8) anyerror!void {
    const content = try struple.unescapeAlloc(arena, framed);
    var r = struple.reader(content);
    try writer.writeByte('[');
    var first = true;
    while (try r.next()) |e| {
        if (!first) try writer.writeByte(',');
        first = false;
        try writeValue(arena, writer, e);
    }
    try writer.writeByte(']');
}

fn writeMap(arena: std.mem.Allocator, writer: anytype, framed: []const u8) anyerror!void {
    const content = try struple.unescapeAlloc(arena, framed);
    var r = struple.reader(content);
    try writer.writeByte('{');
    var first = true;
    while (try r.next()) |k| {
        const v = (try r.next()) orelse return error.MalformedMap;
        if (!first) try writer.writeByte(',');
        first = false;
        // JSON keys must be strings.
        switch (k) {
            .string => |kf| try writeJsonString(arena, writer, kf),
            else => {
                // Non-string key: render its JSON and quote the result.
                var tmp = std.ArrayList(u8).init(arena);
                try writeValue(arena, tmp.writer(), k);
                try writeQuoted(writer, tmp.items);
            },
        }
        try writer.writeByte(':');
        try writeValue(arena, writer, v);
    }
    try writer.writeByte('}');
}

fn writeJsonString(arena: std.mem.Allocator, writer: anytype, framed: []const u8) !void {
    const s = try struple.unescapeAlloc(arena, framed);
    try writeQuoted(writer, s);
}

fn writeQuoted(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0C => try writer.writeAll("\\f"),
        else => if (c < 0x20) try writer.print("\\u{x:0>4}", .{c}) else try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

fn writeBase64(arena: std.mem.Allocator, writer: anytype, framed: []const u8) !void {
    const raw = try struple.unescapeAlloc(arena, framed);
    const enc = std.base64.standard.Encoder;
    const buf = try arena.alloc(u8, enc.calcSize(raw.len));
    try writeQuoted(writer, enc.encode(buf, raw));
}

fn writeBigInt(arena: std.mem.Allocator, writer: anytype, bi: struple.BigInt) !void {
    const mag = try bi.magnitudeAlloc(arena);
    if (bi.negative) try writer.writeByte('-');
    try writer.writeAll(try magnitudeToDecimal(arena, mag));
}

// ---------------------------------------------------------------------------
// Arbitrary-precision decimal <-> big-endian magnitude bytes (self-contained)
// ---------------------------------------------------------------------------

/// Decimal ASCII digits -> normalized big-endian magnitude bytes.
fn decimalToMagnitude(arena: std.mem.Allocator, digits: []const u8) ![]u8 {
    var bytes = std.ArrayList(u8).init(arena); // big-endian, no leading zeros
    for (digits) |ch| {
        if (ch < '0' or ch > '9') return error.InvalidNumber;
        // bytes = bytes * 10 + digit
        var carry: u16 = ch - '0';
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

/// Normalized big-endian magnitude bytes -> decimal ASCII digits.
fn magnitudeToDecimal(arena: std.mem.Allocator, mag: []const u8) ![]u8 {
    if (mag.len == 0) return arena.dupe(u8, "0");
    const work = try arena.dupe(u8, mag);
    var digits = std.ArrayList(u8).init(arena);
    var start: usize = 0;
    while (start < work.len) {
        var rem: u16 = 0;
        for (work[start..]) |*b| {
            const cur = (rem << 8) | b.*;
            b.* = @intCast(cur / 10);
            rem = cur % 10;
        }
        try digits.append(@as(u8, @intCast(rem)) + '0');
        while (start < work.len and work[start] == 0) start += 1;
    }
    std.mem.reverse(u8, digits.items);
    return digits.toOwnedSlice();
}
