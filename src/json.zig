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
//! decimal -> number (exact decimal literal), timestamp -> number (µs),
//! uuid -> hyphenated string, bytes -> base64 string, set -> array.

const std = @import("std");
const struple = @import("struple.zig");

/// Parse JSON text and return its struple encoding (caller owns the bytes).
pub fn fromJson(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Reject hostile deeply-nested JSON before parsing: the linear bracket-depth
    // scan bounds both std.json's recursive Value parse and encodeValue below,
    // which would otherwise overflow the stack (Item 5).
    try checkJsonDepth(json);

    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});

    var out = struple.Packer.init(allocator);
    errdefer out.deinit();
    try encodeValue(arena, &out, root);
    return out.toOwnedSlice();
}

/// Scan JSON text and reject if `[`/`{` nesting exceeds `struple.max_depth`.
/// Brackets inside string literals (and after `\`) don't count.
fn checkJsonDepth(json: []const u8) !void {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (json) |c| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '[', '{' => {
                depth += 1;
                if (depth > struple.max_depth) return error.NestingTooDeep;
            },
            ']', '}' => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
    }
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
        try writeValue(arena, out.writer(), elem, 0);
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
        .float => |f| {
            if (!std.math.isFinite(f)) return error.NonFiniteNumber;
            try out.appendF64(f);
        },
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
        const f = try std.fmt.parseFloat(f64, s);
        // A JSON number out of f64 range (e.g. 1e999) parses to ±inf; reject it
        // rather than silently encoding an infinity (Item 4).
        if (!std.math.isFinite(f)) return error.NonFiniteNumber;
        try out.appendF64(f);
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

fn writeValue(arena: std.mem.Allocator, writer: anytype, elem: struple.Element, depth: usize) anyerror!void {
    if (depth > struple.max_depth) return error.NestingTooDeep;
    switch (elem) {
        .nil, .undef => try writer.writeAll("null"),
        .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
        .int => |i| try writer.print("{d}", .{i}),
        .big_int => |bi| try writeBigInt(arena, writer, bi),
        .float32 => |f| try writeFloat(writer, @as(f64, f)), // render an f32 by its exact f64 value (cross-port)
        .float64 => |f| try writeFloat(writer, f),
        .decimal => |d| try writeDecimal(arena, writer, d),
        .timestamp => |t| try writer.print("{d}", .{t}),
        .uuid => |u| try writeUuid(writer, u),
        .string => |framed| try writeJsonString(arena, writer, framed),
        .bytes => |framed| try writeBase64(arena, writer, framed),
        .array, .set => |framed| try writeArray(arena, writer, framed, depth),
        .map => |framed| try writeMap(arena, writer, framed, depth),
    }
}

/// Render a float as ECMAScript `Number::toString` — the shortest decimal that
/// round-trips to the same f64, formatted per the ECMA-262 fixed/exponential rules.
/// This is the pinned cross-language float text format (Item 3).
fn writeFloat(writer: anytype, f: f64) !void {
    if (!std.math.isFinite(f)) {
        try writer.writeAll("null"); // JSON has no inf/nan (matches JSON.stringify)
        return;
    }
    if (f == 0) {
        try writer.writeByte('0'); // +0.0 and -0.0 both render "0"
        return;
    }
    // formatFloat(.scientific) yields the shortest significant digits and the
    // base-10 exponent of the most-significant digit: `[-]d[.ddd]e[-]E`.
    var buf: [512]u8 = undefined;
    var s = std.fmt.formatFloat(&buf, f, .{ .mode = .scientific }) catch unreachable;
    if (s[0] == '-') {
        try writer.writeByte('-');
        s = s[1..];
    }
    const epos = std.mem.indexOfScalar(u8, s, 'e').?;
    const exp = std.fmt.parseInt(i32, s[epos + 1 ..], 10) catch unreachable;
    var digbuf: [32]u8 = undefined;
    var k: usize = 0;
    for (s[0..epos]) |c| {
        if (c != '.') {
            digbuf[k] = c;
            k += 1;
        }
    }
    try writeEcmaDigits(writer, digbuf[0..k], exp + 1);
}

/// Emit shortest significant `digits` as ECMAScript Number::toString, where `n` is
/// the integer-part digit count (`10^(n-1) <= |value| < 10^n`).
fn writeEcmaDigits(writer: anytype, digits: []const u8, n: i32) !void {
    const k: i32 = @intCast(digits.len);
    if (n >= 1 and n <= 21) {
        if (k <= n) { // integer with trailing zeros
            try writer.writeAll(digits);
            var z: i32 = 0;
            while (z < n - k) : (z += 1) try writer.writeByte('0');
        } else { // decimal point inside the digits
            try writer.writeAll(digits[0..@intCast(n)]);
            try writer.writeByte('.');
            try writer.writeAll(digits[@intCast(n)..]);
        }
    } else if (n <= 0 and n > -6) { // 0.00…digits
        try writer.writeAll("0.");
        var z: i32 = 0;
        while (z < -n) : (z += 1) try writer.writeByte('0');
        try writer.writeAll(digits);
    } else { // exponential: d[.ddd]e±(n-1)
        try writer.writeByte(digits[0]);
        if (k > 1) {
            try writer.writeByte('.');
            try writer.writeAll(digits[1..]);
        }
        try writer.writeByte('e');
        const e = n - 1;
        try writer.writeByte(if (e >= 0) '+' else '-');
        try writer.print("{d}", .{@abs(e)});
    }
}

fn writeArray(arena: std.mem.Allocator, writer: anytype, framed: []const u8, depth: usize) anyerror!void {
    const content = try struple.unescapeAlloc(arena, framed);
    var r = struple.reader(content);
    try writer.writeByte('[');
    var first = true;
    while (try r.next()) |e| {
        if (!first) try writer.writeByte(',');
        first = false;
        try writeValue(arena, writer, e, depth + 1);
    }
    try writer.writeByte(']');
}

fn writeMap(arena: std.mem.Allocator, writer: anytype, framed: []const u8, depth: usize) anyerror!void {
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
                try writeValue(arena, tmp.writer(), k, depth + 1);
                try writeQuoted(writer, tmp.items);
            },
        }
        try writer.writeByte(':');
        try writeValue(arena, writer, v, depth + 1);
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

/// Render a decimal as an exact JSON number literal (plain notation, no exponent).
fn writeDecimal(arena: std.mem.Allocator, writer: anytype, d: struple.Decimal) !void {
    if (d.isZero()) {
        try writer.writeByte('0');
        return;
    }
    const digbuf = try arena.alloc(u8, d.coeff_stored.len * 2);
    const digs = d.coefficientDigits(digbuf); // 0–9 values, most-significant first
    const k: i64 = @intCast(digs.len);
    const exp10 = d.exponent(); // value = C · 10^exp10

    if (d.negative) try writer.writeByte('-');

    // Plain notation would pad this many zeros; past the threshold, render in
    // scientific notation so a huge (i32-bounded) exponent can't emit gigabytes.
    const max_plain_pad = 40;
    const pad: i64 = if (exp10 >= 0) exp10 else blk: {
        const pp = k + exp10;
        break :blk if (pp > 0) 0 else -pp;
    };
    if (pad > max_plain_pad) {
        // d1[.d2…dk]e±E, where E = adj_exp − 1 (the power of ten of the MSD − 1).
        try writer.writeByte('0' + digs[0]);
        if (digs.len > 1) {
            try writer.writeByte('.');
            for (digs[1..]) |dd| try writer.writeByte('0' + dd);
        }
        const sci_exp = exp10 + k - 1;
        try writer.writeByte('e');
        try writer.writeByte(if (sci_exp >= 0) '+' else '-');
        try writer.print("{d}", .{@abs(sci_exp)});
        return;
    }

    if (exp10 >= 0) {
        for (digs) |dd| try writer.writeByte('0' + dd);
        var z: i64 = 0;
        while (z < exp10) : (z += 1) try writer.writeByte('0');
        return;
    }
    const point_pos = k + exp10; // number of integer-part digits
    if (point_pos > 0) {
        const pp: usize = @intCast(point_pos);
        for (digs[0..pp]) |dd| try writer.writeByte('0' + dd);
        try writer.writeByte('.');
        for (digs[pp..]) |dd| try writer.writeByte('0' + dd);
    } else {
        try writer.writeAll("0.");
        var z: i64 = point_pos;
        while (z < 0) : (z += 1) try writer.writeByte('0');
        for (digs) |dd| try writer.writeByte('0' + dd);
    }
}

fn writeUuid(writer: anytype, u: [16]u8) !void {
    try writer.writeByte('"');
    for (u, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) try writer.writeByte('-');
        try writer.print("{x:0>2}", .{b});
    }
    try writer.writeByte('"');
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
