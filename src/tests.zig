const std = @import("std");
const testing = std.testing;
const struple = @import("struple.zig");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Pack a single value alone and return owned bytes.
fn packOne(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var p = struple.Packer.init(allocator);
    defer p.deinit();
    try p.append(value);
    return p.toOwnedSlice();
}

fn expectBytes(value: anytype, expected: []const u8) !void {
    const got = try packOne(testing.allocator, value);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, expected, got);
}

// ---------------------------------------------------------------------------
// Golden vectors — pin the exact wire format
// ---------------------------------------------------------------------------

test "golden: simple scalars" {
    try expectBytes(null, &.{0x01}); // nil
    try expectBytes(false, &.{0x02});
    try expectBytes(true, &.{0x03});
    try expectBytes(@as(u64, 0), &.{0x20}); // zero
}

test "golden: positive integers" {
    try expectBytes(@as(u64, 1), &.{ 0x21, 0x01 });
    try expectBytes(@as(u64, 255), &.{ 0x21, 0xFF });
    try expectBytes(@as(u64, 256), &.{ 0x22, 0x01, 0x00 });
    try expectBytes(@as(u64, 1000), &.{ 0x22, 0x03, 0xE8 });
    try expectBytes(@as(u64, 0x1_0000_0000), &.{ 0x25, 0x01, 0x00, 0x00, 0x00, 0x00 });
    try expectBytes(@as(u64, 0xFFFF_FFFF_FFFF_FFFF), &.{ 0x28, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
}

test "golden: negative integers (excess form)" {
    try expectBytes(@as(i64, -1), &.{ 0x1F, 0xFF });
    try expectBytes(@as(i64, -100), &.{ 0x1F, 0x9C });
    try expectBytes(@as(i64, -256), &.{ 0x1F, 0x00 });
    try expectBytes(@as(i64, -257), &.{ 0x1E, 0xFE, 0xFF });
    try expectBytes(@as(i64, -65536), &.{ 0x1E, 0x00, 0x00 });
    try expectBytes(@as(i64, std.math.minInt(i64)), &.{ 0x18, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
}

test "golden: floats" {
    try expectBytes(@as(f32, 1.0), &.{ 0x31, 0xBF, 0x80, 0x00, 0x00 });
    try expectBytes(@as(f32, -1.0), &.{ 0x31, 0x40, 0x7F, 0xFF, 0xFF });
    try expectBytes(@as(f64, 1.0), &.{ 0x32, 0xBF, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
}

test "golden: strings and bytes" {
    try expectBytes("", &.{ 0x40, 0x00 });
    try expectBytes("app", &.{ 0x40, 0x61, 0x70, 0x70, 0x00 });
    try expectBytes("apple", &.{ 0x40, 0x61, 0x70, 0x70, 0x6C, 0x65, 0x00 });

    // bytes with an embedded NUL -> escaped 0x00 0xFF
    var p = struple.Packer.init(testing.allocator);
    defer p.deinit();
    try p.appendBytes(&.{ 0x00, 0x01 });
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x00, 0xFF, 0x01, 0x00 }, p.bytes());
}

test "golden: nested tuple" {
    const a = testing.allocator;

    var child = struple.Packer.init(a);
    defer child.deinit();
    try child.appendInt(1);
    try child.appendInt(2);

    var outer = struple.Packer.init(a);
    defer outer.deinit();
    try outer.appendTuple(child.bytes());
    // child = 21 01 21 02 (no 0x00) -> framed directly
    try testing.expectEqualSlices(u8, &.{ 0x60, 0x21, 0x01, 0x21, 0x02, 0x00 }, outer.bytes());

    // a child whose encoding contains 0x00 must be escaped inside the frame
    var child2 = struple.Packer.init(a);
    defer child2.deinit();
    try child2.appendInt(256); // 22 01 00

    outer.reset();
    try outer.appendTuple(child2.bytes());
    try testing.expectEqualSlices(u8, &.{ 0x60, 0x22, 0x01, 0x00, 0xFF, 0x00 }, outer.bytes());
}

// ---------------------------------------------------------------------------
// Round-trip
// ---------------------------------------------------------------------------

test "round-trip: integers" {
    const a = testing.allocator;
    const cases = [_]i64{
        std.math.minInt(i64), -1_000_000_000_000, -65537, -65536, -257, -256,
        -255,                 -100,                -2,     -1,     0,    1,
        2,                    100,                 255,    256,    257,  65535,
        65536,                1_000_000_000_000,   std.math.maxInt(i64),
    };
    for (cases) |v| {
        const buf = try packOne(a, v);
        defer a.free(buf);
        var r = struple.reader(buf);
        const elem = (try r.next()).?;
        try testing.expectEqual(@as(i128, v), elem.int);
        try testing.expect(try r.next() == null);
    }
}

test "round-trip: u64 above i64 max" {
    const a = testing.allocator;
    const v: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    const buf = try packOne(a, v);
    defer a.free(buf);
    var r = struple.reader(buf);
    const elem = (try r.next()).?;
    try testing.expectEqual(@as(i128, v), elem.int);
}

test "round-trip: floats incl. specials" {
    const a = testing.allocator;
    const f64s = [_]f64{
        -std.math.inf(f64), -1e300, -1.5, -1.0, 0.0, 1.0, 1.5, 3.14159, 1e300, std.math.inf(f64),
    };
    for (f64s) |v| {
        const buf = try packOne(a, v);
        defer a.free(buf);
        var r = struple.reader(buf);
        try testing.expectEqual(v, (try r.next()).?.float64);
    }

    // NaN canonicalizes but stays NaN
    const nan_buf = try packOne(a, std.math.nan(f64));
    defer a.free(nan_buf);
    var rn = struple.reader(nan_buf);
    try testing.expect(std.math.isNan((try rn.next()).?.float64));

    // f32 keeps its type code
    const f32s = [_]f32{ -3.5, -1.0, 0.0, 1.0, 2.5 };
    for (f32s) |v| {
        const buf = try packOne(a, v);
        defer a.free(buf);
        var r = struple.reader(buf);
        try testing.expectEqual(v, (try r.next()).?.float32);
    }
}

test "round-trip: -0.0 squashes to +0.0" {
    const a = testing.allocator;
    const neg0 = try packOne(a, @as(f64, -0.0));
    defer a.free(neg0);
    const pos0 = try packOne(a, @as(f64, 0.0));
    defer a.free(pos0);
    try testing.expectEqualSlices(u8, pos0, neg0);
}

test "round-trip: strings and bytes with NULs" {
    const a = testing.allocator;
    const samples = [_][]const u8{
        "", "a", "hello world", &.{ 0x00, 0x00 }, &.{ 0x00, 0xFF, 0x00 }, "tab\tnewline\n",
    };
    for (samples) |s| {
        var p = struple.Packer.init(a);
        defer p.deinit();
        try p.appendString(s);
        var r = struple.reader(p.bytes());
        const elem = (try r.next()).?;
        const got = try struple.unescapeAlloc(a, elem.string);
        defer a.free(got);
        try testing.expectEqualSlices(u8, s, got);
    }
}

test "round-trip: a mixed multi-element tuple" {
    const a = testing.allocator;
    var p = struple.Packer.init(a);
    defer p.deinit();
    try p.append("users");
    try p.append(@as(i64, 12345));
    try p.append(true);
    try p.append(@as(f64, 87.5));
    try p.appendNil();

    var r = struple.reader(p.bytes());
    try testing.expectEqualStrings("users", (try r.next()).?.string);
    try testing.expectEqual(@as(i128, 12345), (try r.next()).?.int);
    try testing.expectEqual(true, (try r.next()).?.boolean);
    try testing.expectEqual(@as(f64, 87.5), (try r.next()).?.float64);
    try testing.expectEqual(struple.Kind.nil, (try r.next()).?);
    try testing.expect(try r.next() == null);
}

test "round-trip: nested tuple recursion" {
    const a = testing.allocator;

    var inner = struple.Packer.init(a);
    defer inner.deinit();
    try inner.append("city");
    try inner.append(@as(i64, 256)); // forces a 0x00 in the child -> escaping

    var outer = struple.Packer.init(a);
    defer outer.deinit();
    try outer.append(@as(i64, 1));
    try outer.appendTuple(inner.bytes());

    var r = struple.reader(outer.bytes());
    try testing.expectEqual(@as(i128, 1), (try r.next()).?.int);

    const nested = (try r.next()).?.tuple;
    const child_bytes = try struple.unescapeAlloc(a, nested);
    defer a.free(child_bytes);
    try testing.expectEqualSlices(u8, inner.bytes(), child_bytes);

    var cr = struple.reader(child_bytes);
    try testing.expectEqualStrings("city", (try cr.next()).?.string);
    try testing.expectEqual(@as(i128, 256), (try cr.next()).?.int);
    try testing.expect(try cr.next() == null);
}

test "round-trip: nested tuple with NUL-bearing string (double escaping)" {
    const a = testing.allocator;

    var inner = struple.Packer.init(a);
    defer inner.deinit();
    try inner.appendString(&.{ 'a', 0x00, 'b' }); // child encoding itself contains 0x00

    var outer = struple.Packer.init(a);
    defer outer.deinit();
    try outer.appendTuple(inner.bytes());

    var r = struple.reader(outer.bytes());
    const nested = (try r.next()).?.tuple;
    const child_bytes = try struple.unescapeAlloc(a, nested);
    defer a.free(child_bytes);
    try testing.expectEqualSlices(u8, inner.bytes(), child_bytes);

    var cr = struple.reader(child_bytes);
    const s = (try cr.next()).?.string;
    const literal = try struple.unescapeAlloc(a, s);
    defer a.free(literal);
    try testing.expectEqualSlices(u8, &.{ 'a', 0x00, 'b' }, literal);
}

// ---------------------------------------------------------------------------
// Ordering — the whole point
// ---------------------------------------------------------------------------

test "ordering: headline cases" {
    const a = testing.allocator;

    // "app" < "apple" (prefix sorts first)
    {
        const app = try packOne(a, "app");
        defer a.free(app);
        const apple = try packOne(a, "apple");
        defer a.free(apple);
        try testing.expectEqual(std.math.Order.lt, struple.order(app, apple));
    }

    // -256 < -100 < -1 (negatives ordered correctly within a width band)
    {
        const n256 = try packOne(a, @as(i64, -256));
        defer a.free(n256);
        const n100 = try packOne(a, @as(i64, -100));
        defer a.free(n100);
        const n1 = try packOne(a, @as(i64, -1));
        defer a.free(n1);
        try testing.expectEqual(std.math.Order.lt, struple.order(n256, n100));
        try testing.expectEqual(std.math.Order.lt, struple.order(n100, n1));
    }
}

test "ordering: a long ascending chain holds under memcmp" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Build a list of encodings that should already be in ascending order.
    var encs = std.ArrayList([]const u8).init(arena);

    const Pack = struct {
        fn int(al: std.mem.Allocator, list: *std.ArrayList([]const u8), v: i64) !void {
            try list.append(try packOne(al, v));
        }
        fn f64v(al: std.mem.Allocator, list: *std.ArrayList([]const u8), v: f64) !void {
            try list.append(try packOne(al, v));
        }
        fn str(al: std.mem.Allocator, list: *std.ArrayList([]const u8), v: []const u8) !void {
            try list.append(try packOne(al, v));
        }
        fn raw(list: *std.ArrayList([]const u8), v: []const u8) !void {
            try list.append(v);
        }
    };

    // nil < false < true
    try encs.append(try packOne(arena, null));
    try encs.append(try packOne(arena, false));
    try encs.append(try packOne(arena, true));

    // negative .. zero .. positive (crosses several width bands)
    const ints = [_]i64{
        std.math.minInt(i64), -65537, -65536, -257, -256, -100, -2, -1,
        0,                    1,      2,      100,  255,  256,  257, 65535,
        65536,                std.math.maxInt(i64),
    };
    for (ints) |v| try Pack.int(arena, &encs, v);

    // floats sort after all ints; ascending values
    const floats = [_]f64{
        -std.math.inf(f64), -1e9, -1.0, 0.0, 1.0, 1e9, std.math.inf(f64), std.math.nan(f64),
    };
    for (floats) |v| try Pack.f64v(arena, &encs, v);

    // strings sort after floats
    const strings = [_][]const u8{ "", "a", "app", "apple", "apply", "b", "banana" };
    for (strings) |v| try Pack.str(arena, &encs, v);

    // bytes sort after strings — build explicitly to include NULs
    {
        const byte_samples = [_][]const u8{
            &.{}, &.{0x00}, &.{ 0x00, 0x00 }, &.{0x01}, &.{0xFF},
        };
        for (byte_samples) |s| {
            var p = struple.Packer.init(arena);
            try p.appendBytes(s);
            try Pack.raw(&encs, try p.toOwnedSlice());
        }
    }

    // tuples sort after bytes
    {
        const empty = try packOne(arena, @as(i64, 0)); // reused builder below
        _ = empty;
        // (), (1), (1,2), (2)
        var t = struple.Packer.init(arena);

        var c0 = struple.Packer.init(arena); // ()
        var p0 = struple.Packer.init(arena);
        try p0.appendTuple(c0.bytes());
        try Pack.raw(&encs, try p0.toOwnedSlice());

        var c1 = struple.Packer.init(arena); // (1)
        try c1.appendInt(1);
        t.reset();
        try t.appendTuple(c1.bytes());
        try Pack.raw(&encs, try t.toOwnedSlice());

        var c12 = struple.Packer.init(arena); // (1,2)
        try c12.appendInt(1);
        try c12.appendInt(2);
        t.reset();
        try t.appendTuple(c12.bytes());
        try Pack.raw(&encs, try t.toOwnedSlice());

        var c2 = struple.Packer.init(arena); // (2)
        try c2.appendInt(2);
        t.reset();
        try t.appendTuple(c2.bytes());
        try Pack.raw(&encs, try t.toOwnedSlice());
    }

    // Every adjacent pair must be strictly ascending under memcmp.
    for (1..encs.items.len) |i| {
        const prev = encs.items[i - 1];
        const cur = encs.items[i];
        if (struple.order(prev, cur) != .lt) {
            std.debug.print("ordering violation at {d}: {x} !< {x}\n", .{ i, prev, cur });
            return error.OrderingViolation;
        }
    }

    // And a shuffled copy, once sorted by bytes, equals the original order.
    const shuffled = try arena.dupe([]const u8, encs.items);
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    prng.random().shuffle([]const u8, shuffled);
    std.mem.sort([]const u8, shuffled, {}, struple.lessThan);
    for (encs.items, shuffled) |want, got| {
        try testing.expectEqualSlices(u8, want, got);
    }
}

test "ordering: empty-prefix bytes with NULs" {
    const a = testing.allocator;
    // "" < "\x00" < "\x00\x00" < "\x01"
    const order = [_][]const u8{ &.{}, &.{0x00}, &.{ 0x00, 0x00 }, &.{0x01} };
    var prev: ?[]u8 = null;
    defer if (prev) |p| a.free(p);
    for (order) |s| {
        var p = struple.Packer.init(a);
        defer p.deinit();
        try p.appendBytes(s);
        const enc = try a.dupe(u8, p.bytes());
        if (prev) |pp| {
            try testing.expectEqual(std.math.Order.lt, struple.order(pp, enc));
            a.free(pp);
        }
        prev = enc;
    }
}

// ---------------------------------------------------------------------------
// Decode error handling
// ---------------------------------------------------------------------------

test "decode: truncated and invalid input" {
    // truncated integer payload
    {
        var r = struple.reader(&.{0x22}); // says 2 payload bytes, none follow
        try testing.expectError(error.Truncated, r.next());
    }
    // unterminated string
    {
        var r = struple.reader(&.{ 0x40, 0x61 });
        try testing.expectError(error.Truncated, r.next());
    }
    // invalid type code
    {
        var r = struple.reader(&.{0x7F});
        try testing.expectError(error.InvalidType, r.next());
    }
}
